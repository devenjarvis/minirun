import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `minirun worker …`: deploys and manages the Cloudflare Worker from the Mac, with no node or wrangler.
public struct WorkerCommand: Sendable {
    public static let usage = """
    Usage:
      minirun worker deploy [--account ID] [--subdomain NAME] [--new-password] [--new-token]
                                       Deploy or update the Worker, then point this Mac at it
      minirun worker status            Show the Worker and whether it runs the bundled version
      minirun worker password          Print the password for the viewer and Claude's connector
      minirun worker forget-token      Delete the saved Cloudflare API token

    The Cloudflare API token comes from $MINIRUN_CLOUDFLARE_TOKEN, the one saved by an earlier
    deploy, or a prompt.
    """

    static let tokenHelp = """
    minirun deploys its Worker with a Cloudflare API token (the free plan is fine):
      1. Open https://dash.cloudflare.com/profile/api-tokens and choose Create Token.
      2. Use the "Edit Cloudflare Workers" template. Under Account Resources pick your account;
         Zone Resources don't matter to minirun.
      3. Create it and paste it below. It's saved in ~/.config/minirun/worker.json, which only
         your user can read, so later updates don't ask again (`minirun worker forget-token` deletes it).
    """

    public var environment: [String: String]
    public var transport: HTTPTransport
    public var loadBundle: @Sendable () throws -> WorkerBundle
    public var output: @Sendable (String) -> Void
    /// Asks for a secret without echoing it; nil if there's no one to ask.
    public var readSecret: @Sendable (String) -> String?
    /// Makes `minirun serve` pick up a new relay or token (reload, or restart if that fails). Says
    /// what happened, or nil if it isn't installed.
    public var restartServe: @Sendable () async -> String?
    /// Waits between checks that the new Worker answers.
    public var verifyDelays: [TimeInterval] = [0, 2, 4, 8, 15, 30]

    public init(environment: [String: String], transport: HTTPTransport, loadBundle: @escaping @Sendable () throws -> WorkerBundle,
                output: @escaping @Sendable (String) -> Void, readSecret: @escaping @Sendable (String) -> String?,
                restartServe: @escaping @Sendable () async -> String?) {
        self.environment = environment
        self.transport = transport
        self.loadBundle = loadBundle
        self.output = output
        self.readSecret = readSecret
        self.restartServe = restartServe
    }

    /// The real thing, for the `minirun` binary at `executable`.
    public static func live(executable: URL) -> WorkerCommand {
        WorkerCommand(
            environment: ProcessInfo.processInfo.environment,
            transport: URLSessionTransport(),
            loadBundle: { try WorkerBundle.locate(executable: executable) },
            output: { print($0) },
            readSecret: { prompt in WorkerCommand.readHidden(prompt) },
            restartServe: { await WorkerCommand.reloadServe() }
        )
    }

    public func run(_ args: [String]) async throws {
        switch args.first {
        case "deploy": try await deploy(args)
        case "status": try await status()
        case "password":
            guard let password = WorkerSettings.load().ownerPassword else { throw ToolError("No password saved yet. Run `minirun worker deploy`.") }
            output(password)
        case "forget-token":
            try WorkerManager.forgetToken()
            output("Deleted the saved Cloudflare API token. `minirun worker deploy` will ask for one again.")
        default:
            output(WorkerCommand.usage)
        }
    }

    var manager: WorkerManager {
        var manager = WorkerManager(transport: transport, loadBundle: loadBundle, reloadServe: restartServe)
        manager.verifyDelays = verifyDelays
        return manager
    }

    func deploy(_ args: [String]) async throws {
        let settings = WorkerSettings.load()
        let fromEnvironment = environment["MINIRUN_CLOUDFLARE_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
        guard let apiToken = fromEnvironment ?? settings.apiToken ?? askForToken() else {
            throw ToolError("No Cloudflare API token. Set MINIRUN_CLOUDFLARE_TOKEN, or run `minirun worker deploy` in a terminal.\n\n\(WorkerCommand.tokenHelp)")
        }

        let options = WorkerDeployer.Options(
            accountID: Self.option("--account", in: args),
            subdomain: Self.option("--subdomain", in: args),
            newPassword: args.contains("--new-password"),
            newToken: args.contains("--new-token")
        )
        let output = self.output
        let deployment = try await manager.deploy(apiToken: apiToken, options: options) { output("==> \($0)") }
        let result = deployment.result

        if deployment.answering {
            output("\(result.workerURL) is up.")
        } else {
            output("warning: \(result.workerURL) isn't answering yet. A new workers.dev subdomain can take a few minutes to start working.")
        }
        if let message = deployment.serveMessage { output(message) }

        output("""

        minirun's Worker is \(result.created ? "deployed" : "up to date") (\(deployment.bundleHash.prefix(12))).

          Claude connector:  \(result.workerURL)/mcp
          Live viewer:       \(result.workerURL)/
          Password:          \(result.ownerPassword)\(result.passwordChanged ? "  (new)" : "")

        Add the connector in Claude: Settings → Connectors → Add custom connector, then approve it with the password.
        Settings saved in \(WorkerSettings.url.path) and \(MiniRunConfig.configURL.path).
        """)
    }

    func status() async throws {
        let token = environment["MINIRUN_CLOUDFLARE_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
        let status = try await manager.status(apiToken: token)
        guard let url = status.workerURL else {
            output("No Worker deployed from this Mac yet. Run `minirun worker deploy`.")
            return
        }
        output("Worker:   \(url)")
        output("Account:  \(status.accountID ?? "unknown (deployed by worker/setup.sh)")")
        output("Bundled:  \(status.bundled.map { String($0.prefix(12)) } ?? "not found")")
        switch status.deployed {
        case .unknown:
            output("Deployed: unknown (no saved API token; run `minirun worker deploy` to adopt this Worker)")
        case .missing:
            output("Deployed: nothing — the Worker doesn't exist. Run `minirun worker deploy`.")
        case .bundle(let hash):
            output("Deployed: \(hash.map { String($0.prefix(12)) } ?? "unknown (deployed with wrangler)")")
            if status.outOfDate { output("The Worker is out of date. Update it with `minirun worker deploy`.") }
        }
    }

    func askForToken() -> String? {
        guard environment["MINIRUN_NO_PROMPT"] == nil else { return nil }
        output(WorkerCommand.tokenHelp)
        let token = readSecret("Cloudflare API token: ")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }

    static func option(_ name: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    /// Reads a line from the terminal with echo off. Nil when stdin isn't a terminal.
    static func readHidden(_ prompt: String) -> String? {
        guard isatty(STDIN_FILENO) == 1 else { return nil }
        FileHandle.standardOutput.write(Data(prompt.utf8))
        var original = termios()
        tcgetattr(STDIN_FILENO, &original)
        var silent = original
        silent.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &silent)
        defer {
            tcsetattr(STDIN_FILENO, TCSANOW, &original)
            print("")
        }
        return readLine()
    }

    /// Points the running `minirun serve` at the new relay settings: asks it to reload its config
    /// over the control socket, and restarts the LaunchAgent if it doesn't answer.
    static func reloadServe() async -> String? {
        if let response = try? ControlProtocol.send(ControlProtocol.Request(command: "reload_config")) {
            if response.ok { return "minirun serve reloaded its settings and is reconnecting to the new Worker." }
            if response.controlVersion != nil {
                return "warning: minirun serve couldn't reload its settings: \(response.error ?? "unknown error")"
            }
            // An older daemon without reload_config: restart it instead.
        }
        return await restartLaunchAgent()
    }

    /// `launchctl kickstart -k` for the LaunchAgent that install.sh sets up.
    static func restartLaunchAgent() async -> String? {
        #if os(macOS)
        guard LaunchAgent.isInstalled else { return nil }
        do {
            try await LaunchAgent.kickstart(restart: true)
            return "Restarted minirun serve with the new settings."
        } catch {
            return "warning: couldn't restart minirun serve. Run: \(Doctor.kickstart)"
        }
        #else
        return nil
        #endif
    }
}
