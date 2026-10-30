import Foundation
import IOKit.pwr_mgt
import MiniRunKit
import MiniRunSim

/// `minirun serve`: load simulator support, keep the Mac awake, and stay connected to the relay.
public enum Server {
    public static func run(config: MiniRunConfig) async throws {
        log("minirun \(MiniRun.version) starting")
        guard RelayClient.endpoint(config) != nil else {
            throw ToolError("No relay configured. Run `minirun worker deploy` (or `minirun setup --relay wss://<worker>/agent --token <AGENT_TOKEN>`) first.")
        }
        do {
            try await SimulatorDriver.shared.prepare()
            log("Simulator support loaded")
        } catch {
            // Keep serving: build tools still work, and the error is reported on each simulator call.
            log("Warning: simulator support failed to load: \(error.localizedDescription)")
        }

        let live = LiveConfig(config)
        let awake = SleepAssertion()
        awake.set(config.preventSleep)
        defer { awake.set(false) }
        live.observe { old, new in
            if old.preventSleep != new.preventSleep { awake.set(new.preventSleep) }
        }

        let registry = ToolRegistry(config: live)
        log("\(registry.definitions.count) tools ready; workspaces at \(config.workspaceRoot)")
        let idleShutdown = Task { await registry.shutDownIdleSimulators(log: { Server.log($0) }) }
        defer { idleShutdown.cancel() }
        let client = RelayClient(config: live, registry: registry, log: { Server.log($0) })

        let commands = ServeControl(registry: registry, client: client, startedAt: Date(), log: { Server.log($0) })
        let control = ControlServer(path: MiniRunConfig.controlSocketURL.path) { line in
            await ControlProtocol.respond(to: line, commands: commands)
        }
        do {
            try control.start()
            log("Answering control requests on \(control.path)")
        } catch {
            // Not fatal: Claude can still reach the Mac; only `minirun status` and the menu bar app can't.
            log("Warning: no control socket: \(error.localizedDescription)")
        }
        defer { control.stop() }

        // `kill -HUP` re-reads config.json, for edits made by hand.
        signal(SIGHUP, SIG_IGN)
        let hangup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .global())
        hangup.setEventHandler {
            do {
                Server.log("SIGHUP: \(try live.reload().summary)")
            } catch {
                Server.log("SIGHUP: kept the old settings: \(error.localizedDescription)")
            }
        }
        hangup.resume()
        defer { hangup.cancel() }

        await client.run()
    }

    public static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
    }
}

/// Keeps the Mac from idle sleep while `preventSleep` is on.
final class SleepAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var assertion: IOPMAssertionID = 0

    func set(_ on: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if on, assertion == 0 {
            let reason = "minirun is serving simulators" as CFString
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertion) == kIOReturnSuccess {
                Server.log("Preventing idle sleep while running")
            } else {
                assertion = 0
            }
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
            Server.log("Allowing idle sleep")
        }
    }
}
