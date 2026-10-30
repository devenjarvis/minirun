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
    /// Restarts `minirun serve` so it picks up a new relay or token. Says what happened, or nil if it isn't installed.
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
            restartServe: { await WorkerCommand.restartLaunchAgent() }
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
            var settings = WorkerSettings.load()
            settings.apiToken = nil
            try settings.save()
            output("Deleted the saved Cloudflare API token. `minirun worker deploy` will ask for one again.")
        default:
            output(WorkerCommand.usage)
        }
    }

    func deploy(_ args: [String]) async throws {
        var settings = WorkerSettings.load()
        var config = MiniRunConfig.load()
        let bundle = try loadBundle()

        let fromEnvironment = environment["MINIRUN_CLOUDFLARE_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
        guard let apiToken = fromEnvironment ?? settings.apiToken ?? askForToken() else {
            throw ToolError("No Cloudflare API token. Set MINIRUN_CLOUDFLARE_TOKEN, or run `minirun worker deploy` in a terminal.\n\n\(WorkerCommand.tokenHelp)")
        }

        let options = WorkerDeployer.Options(
            accountID: Self.option("--account", in: args) ?? settings.accountID,
            subdomain: Self.option("--subdomain", in: args),
            newPassword: args.contains("--new-password"),
            newToken: args.contains("--new-token")
        )
        let deployer = WorkerDeployer(api: CloudflareAPI(token: apiToken, transport: transport), bundle: bundle)
        let output = self.output
        let result = try await deployer.deploy(options, password: settings.ownerPassword, token: config.agentToken) { output("==> \($0)") }

        settings.accountID = result.accountID
        settings.scriptName = bundle.manifest.name
        settings.workerURL = result.workerURL
        settings.ownerPassword = result.ownerPassword
        settings.apiToken = apiToken
        try settings.save()
        try updateLegacyEnvFile(result)

        let relayChanged = config.relayURL != result.relayURL || config.agentToken != result.agentToken
        config.relayURL = result.relayURL
        config.agentToken = result.agentToken
        try config.save()

        output("==> Checking that the Worker answers")
        if await answers(URL(string: result.workerURL + "/login")!) {
            output("\(result.workerURL) is up.")
        } else {
            output("warning: \(result.workerURL) isn't answering yet. A new workers.dev subdomain can take a few minutes to start working.")
        }
        if relayChanged, let restarted = await restartServe() { output(restarted) }

        output("""

        minirun's Worker is \(result.created ? "deployed" : "up to date") (\(bundle.manifest.bundleHash.prefix(12))).

          Claude connector:  \(result.workerURL)/mcp
          Live viewer:       \(result.workerURL)/
          Password:          \(result.ownerPassword)\(result.passwordChanged ? "  (new)" : "")

        Add the connector in Claude: Settings → Connectors → Add custom connector, then approve it with the password.
        Settings saved in \(WorkerSettings.url.path) and \(MiniRunConfig.configURL.path).
        """)
    }

    func status() async throws {
        let settings = WorkerSettings.load()
        let bundle = try? loadBundle()
        guard let url = settings.workerURL else {
            output("No Worker deployed from this Mac yet. Run `minirun worker deploy`.")
            return
        }
        output("Worker:   \(url)")
        output("Account:  \(settings.accountID ?? "unknown (deployed by worker/setup.sh)")")
        output("Bundled:  \(bundle.map { String($0.manifest.bundleHash.prefix(12)) } ?? "not found")")

        let token = environment["MINIRUN_CLOUDFLARE_TOKEN"].flatMap { $0.isEmpty ? nil : $0 } ?? settings.apiToken
        guard let token, let account = settings.accountID, let script = settings.scriptName ?? bundle?.manifest.name else {
            output("Deployed: unknown (no saved API token; run `minirun worker deploy` to adopt this Worker)")
            return
        }
        let bindings = try await CloudflareAPI(token: token, transport: transport).scriptBindings(account: account, script: script)
        guard let bindings else {
            output("Deployed: nothing — the Worker \(script) doesn't exist. Run `minirun worker deploy`.")
            return
        }
        let deployed = WorkerCommand.deployedBundle(bindings)
        output("Deployed: \(deployed.map { String($0.prefix(12)) } ?? "unknown (deployed with wrangler)")")
        if let bundle, deployed != bundle.manifest.bundleHash {
            output("The Worker is out of date. Update it with `minirun worker deploy`.")
        }
    }

    /// The MINIRUN_BUNDLE variable of a deployed Worker: the hash of the code it runs.
    static func deployedBundle(_ bindings: [JSONValue]) -> String? {
        bindings.first { $0["name"]?.stringValue == WorkerDeployer.bundleVariable }?["text"]?.stringValue
    }

    func askForToken() -> String? {
        guard environment["MINIRUN_NO_PROMPT"] == nil else { return nil }
        output(WorkerCommand.tokenHelp)
        let token = readSecret("Cloudflare API token: ")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }

    /// Keeps the old worker.env (which worker/setup.sh reads) in step, if there is one.
    func updateLegacyEnvFile(_ result: WorkerDeployer.Result) throws {
        let url = WorkerSettings.legacyURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let text = "WORKER_URL='\(result.workerURL)'\nOWNER_PASSWORD='\(result.ownerPassword)'\nAGENT_TOKEN='\(result.agentToken)'\n"
        try Data(text.utf8).write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func answers(_ url: URL) async -> Bool {
        for delay in verifyDelays {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            if let (status, _) = try? await transport.send(request), status == 200 { return true }
        }
        return false
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

    /// `launchctl kickstart -k` for the LaunchAgent that install.sh sets up.
    static func restartLaunchAgent() async -> String? {
        #if os(macOS)
        let label = "dev.minirun.agent"
        let plist = MiniRunConfig.home + "/Library/LaunchAgents/\(label).plist"
        guard FileManager.default.fileExists(atPath: plist) else { return nil }
        let result = try? await Shell.run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"], timeout: 30)
        return result?.succeeded == true
            ? "Restarted minirun serve with the new settings."
            : "warning: couldn't restart minirun serve. Run: launchctl kickstart -k gui/$(id -u)/\(label)"
        #else
        return nil
        #endif
    }
}
