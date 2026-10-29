import Foundation
import IOKit.pwr_mgt
import MiniRunKit
import MiniRunSim

/// `minirun serve`: load simulator support, keep the Mac awake, and stay connected to the relay.
public enum Server {
    public static func run(config: MiniRunConfig) async throws {
        log("minirun \(MiniRun.version) starting")
        guard let relay = config.relayURL, let url = URL(string: relay), let token = config.agentToken, !token.isEmpty else {
            throw ToolError("No relay configured. Run `minirun setup --relay wss://<worker>/agent --token <AGENT_TOKEN>` first.")
        }
        do {
            try await SimulatorDriver.shared.prepare()
            log("Simulator support loaded")
        } catch {
            // Keep serving: build tools still work, and the error is reported on each simulator call.
            log("Warning: simulator support failed to load: \(error.localizedDescription)")
        }
        var assertion: IOPMAssertionID = 0
        if config.preventSleep {
            let reason = "minirun is serving simulators" as CFString
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertion) == kIOReturnSuccess {
                log("Preventing idle sleep while running")
            }
        }
        defer { if assertion != 0 { IOPMAssertionRelease(assertion) } }

        let registry = ToolRegistry(config: config)
        log("\(registry.definitions.count) tools ready; workspaces at \(config.workspaceRoot)")
        let idleShutdown = Task { await registry.shutDownIdleSimulators(log: { Server.log($0) }) }
        defer { idleShutdown.cancel() }
        let client = RelayClient(url: url, token: token, registry: registry, log: { Server.log($0) })

        let startedAt = Date()
        let control = ControlServer(path: MiniRunConfig.controlSocketURL.path) { line in
            await ControlProtocol.respond(to: line) {
                let local = await registry.status()
                var relay = client.relayStatus
                relay.viewerURL = config.viewerURL(device: nil)
                return ServeStatus(
                    version: MiniRun.version, pid: ProcessInfo.processInfo.processIdentifier, startedAt: startedAt,
                    relay: relay, simulators: local.simulators, simulatorError: local.simulatorError, jobs: local.jobs
                )
            }
        }
        do {
            try control.start()
            log("Answering status requests on \(control.path)")
        } catch {
            // Not fatal: Claude can still reach the Mac; only `minirun status` and the menu bar app can't.
            log("Warning: no control socket: \(error.localizedDescription)")
        }
        defer { control.stop() }

        await client.run()
    }

    public static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
    }
}
