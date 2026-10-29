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
        let client = RelayClient(url: url, token: token, registry: registry, log: log)
        await client.run()
    }

    @Sendable public static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
    }
}
