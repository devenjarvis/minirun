import Foundation
import MiniRunCore
import MiniRunKit
import MiniRunSim

let usage = """
minirun \(MiniRun.version) — lets Claude build, run and demo iOS apps on this Mac.

Usage:
  minirun serve                         Connect to the relay and serve tools (run by launchd)
  minirun setup --relay URL --token T   Save relay settings to ~/.config/minirun/config.json
        [--device "iPhone 17 Pro"] [--allow-shell] [--workspaces DIR]
  minirun worker deploy                 Deploy or update the Cloudflare Worker (see `minirun worker help`)
  minirun agent install|uninstall       Run `minirun serve` from this binary at login (a LaunchAgent)
  minirun status [--json]               Show what the running `minirun serve` is doing
  minirun reload                        Make the running `minirun serve` re-read config.json
  minirun doctor [--json]               Check Xcode, simulators and the relay settings
  minirun tools                         Print the MCP tool definitions as JSON
  minirun call TOOL ['{"json":"args"}'] Run one tool locally (images are saved to /tmp)
  minirun version
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func option(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

@MainActor
func main() async {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else { print(usage); return }
    var config = MiniRunConfig.load()

    switch command {
    case "serve":
        do { try await Server.run(config: config) } catch { fail(error.localizedDescription) }

    case "setup":
        if let relay = option("--relay", in: args) {
            var normalized = relay.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://")
            if !normalized.hasSuffix("/agent") { normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/agent" }
            config.relayURL = normalized
        }
        if let token = option("--token", in: args) { config.agentToken = token }
        if let device = option("--device", in: args) { config.defaultDevice = device }
        if let dir = option("--workspaces", in: args) { config.workspaceRoot = (dir as NSString).expandingTildeInPath }
        if args.contains("--allow-shell") { config.allowShell = true }
        if args.contains("--no-shell") { config.allowShell = false }
        do { try config.save() } catch { fail("Could not save config: \(error.localizedDescription)") }
        print("Saved \(MiniRunConfig.configURL.path)")
        if let response = try? ControlProtocol.send(ControlProtocol.Request(command: "reload_config")), response.ok, let message = response.message {
            print("minirun serve: \(message)")
        }

    case "worker":
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        do { try await WorkerCommand.live(executable: executable).run(Array(args.dropFirst())) } catch { fail(error.localizedDescription) }

    case "agent":
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
        switch args.dropFirst().first {
        case "install":
            do { try await LaunchAgent.install(program: executable) } catch { fail(error.localizedDescription) }
            print("Installed \(LaunchAgent.plistPath): launchd runs \(executable) serve now and at every login.")
        case "uninstall":
            await LaunchAgent.uninstall()
            print("Removed \(LaunchAgent.plistPath) and stopped minirun serve.")
        default:
            print(LaunchAgent.installedProgram().map { "The LaunchAgent runs \($0.isEmpty ? "(unreadable plist)" : $0) serve." } ?? "No LaunchAgent installed.")
            print("Usage: minirun agent install|uninstall")
        }

    case "status":
        let response: ControlProtocol.Response
        do {
            response = try ControlProtocol.send(ControlProtocol.Request(command: "status"))
        } catch {
            fail(notAnswering(error))
        }
        guard response.ok, let status = response.status else { fail(response.error ?? "minirun serve sent no status.") }
        print(args.contains("--json") ? ControlProtocol.encode(status) : status.summary())

    case "reload":
        let response: ControlProtocol.Response
        do {
            response = try ControlProtocol.send(ControlProtocol.Request(command: "reload_config"))
        } catch {
            fail(notAnswering(error))
        }
        guard response.ok else {
            fail(response.controlVersion == nil
                 ? "This minirun serve is too old to reload its settings. Restart it: \(Doctor.kickstart)"
                 : response.error ?? "minirun serve couldn't reload its settings.")
        }
        print(response.message ?? "Reloaded.")

    case "doctor":
        let doctor = Doctor(
            loadFrameworks: {
                do {
                    try await SimulatorDriver.shared.prepare()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            serveStatus: { try? ControlProtocol.send(ControlProtocol.Request(command: "status")).status }
        )
        let checks = await doctor.checks(config: config)
        print(args.contains("--json") ? ControlProtocol.encode(checks) : Doctor.format(checks))

    case "tools":
        let registry = ToolRegistry(config: config)
        print(JSONValue.array(registry.definitions.map(\.json)).encodedString(pretty: true))

    case "call":
        guard args.count >= 2 else { fail("usage: minirun call TOOL [JSON]") }
        let arguments: JSONValue
        do { arguments = args.count >= 3 ? try JSONValue.parse(args[2]) : [:] } catch { fail("Arguments must be a JSON object.") }
        let registry = ToolRegistry(config: config)
        var result = await registry.call(args[1], arguments: arguments)
        // Poll jobs to completion so scripts get the final answer.
        while let text = result.content.first.flatMap({ (item: ToolContent) -> String? in if case .text(let t) = item { return t } else { return nil } }),
              text.contains("is still running"), let range = text.range(of: #"job_[0-9a-f]{8}"#, options: .regularExpression) {
            result = await registry.call("get_job", arguments: ["job_id": .string(String(text[range])), "wait_seconds": .number(JobStore.maxWait)])
        }
        for item in result.content {
            switch item {
            case .text(let text): print(text)
            case .image(let data, _):
                let path = NSTemporaryDirectory() + "minirun-\(UUID().uuidString.prefix(8)).jpg"
                try? data.write(to: URL(fileURLWithPath: path))
                print("[image saved to \(path)]")
            }
        }
        exit(result.isError ? 1 : 0)

    case "version", "--version", "-v":
        print(MiniRun.version)

    case "help", "--help", "-h":
        print(usage)

    default:
        fail("Unknown command \(command).\n\n\(usage)")
    }
}

func notAnswering(_ error: Error) -> String {
    "minirun serve isn't answering (\(error.localizedDescription))\nStart it with: \(Doctor.kickstart)"
}

await main()
