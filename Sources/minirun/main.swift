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
  minirun status [--json]               Show what the running `minirun serve` is doing
  minirun doctor                        Check Xcode, simulators and the relay settings
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

    case "status":
        let response: ControlProtocol.Response
        do {
            response = try serveStatus()
        } catch {
            fail("minirun serve isn't answering (\(error.localizedDescription))\nStart it with: launchctl kickstart -k gui/$(id -u)/dev.minirun.agent")
        }
        guard response.ok, let status = response.status else { fail(response.error ?? "minirun serve sent no status.") }
        print(args.contains("--json") ? ControlProtocol.encode(status) : status.summary())

    case "doctor":
        await doctor(config)

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
            result = await registry.call("get_job", arguments: ["job_id": .string(String(text[range])), "wait_seconds": 600])
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

/// Asks the running `minirun serve` for its status over the control socket.
func serveStatus() throws -> ControlProtocol.Response {
    let line = try ControlSocket.request(MiniRunConfig.controlSocketURL.path, ControlProtocol.encode(ControlProtocol.Request(command: "status")))
    return try ControlProtocol.decode(ControlProtocol.Response.self, from: line)
}

@MainActor
func doctor(_ config: MiniRunConfig) async {
    func check(_ label: String, _ ok: Bool, _ detail: String) { print("\(ok ? "✓" : "✗") \(label): \(detail)") }

    let xcode = try? await Shell.run("/usr/bin/xcrun", ["xcodebuild", "-version"], timeout: 60)
    check("Xcode", xcode?.succeeded == true, xcode?.stdout.split(separator: "\n").first.map(String.init) ?? "not found — install Xcode and run `sudo xcode-select -s /Applications/Xcode.app`")

    do {
        try await SimulatorDriver.shared.prepare()
        check("Simulator frameworks", true, "loaded")
    } catch {
        check("Simulator frameworks", false, error.localizedDescription)
    }

    if let list = try? await Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "--json"], timeout: 60),
       let devices = try? XcodeParsing.parseDevices(Data(list.stdout.utf8)) {
        let ios = devices.filter { $0.isAvailable && $0.runtime.contains("iOS") }
        let booted = ios.filter(\.isBooted).map(\.name)
        check("Simulators", !ios.isEmpty, "\(ios.count) iOS simulators" + (booted.isEmpty ? "" : ", booted: \(booted.joined(separator: ", "))"))
    } else {
        check("Simulators", false, "simctl failed")
    }

    if let status = try? serveStatus().status {
        let relay = status.relay.state == .connected ? "connected to the relay" : "\(status.relay.state.rawValue)" + (status.relay.problem.map { ": \($0)" } ?? "")
        check("minirun serve", status.relay.state == .connected, "running (pid \(status.pid)), \(relay)")
    } else {
        check("minirun serve", false, "not running — launchctl kickstart -k gui/$(id -u)/dev.minirun.agent")
    }
    check("Relay URL", config.relayURL != nil, config.relayURL ?? "not set — run minirun setup")
    check("Agent token", config.agentToken?.isEmpty == false, config.agentToken == nil ? "not set" : "set")
    check("Workspaces", true, config.workspaceRoot)
    check("run_command", true, config.allowShell ? "enabled" : "disabled")

    let gh = try? await Shell.run("gh", ["auth", "status"], timeout: 20)
    check("GitHub auth (for private repos)", gh?.succeeded == true, gh?.succeeded == true ? "gh is logged in" : "optional: run `gh auth login && gh auth setup-git`")
}

await main()
