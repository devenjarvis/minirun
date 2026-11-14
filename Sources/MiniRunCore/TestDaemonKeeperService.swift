import Foundation
import MiniRunKit

/// Runs `TestDaemonKeeper`'s session for `minirun serve` while `keepTestDaemon` is on: starts it
/// when it can, starts it again when it ends, and stops it when serve stops or the setting goes off.
final class TestDaemonKeeperService: @unchecked Sendable {
    private let config: LiveConfig
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var process: BackgroundProcess?
    /// How often to look again when nothing's running.
    private static let checkInterval: UInt64 = 60

    init(config: LiveConfig, log: @escaping @Sendable (String) -> Void) {
        self.config = config
        self.log = log
    }

    func run() async {
        var backoff = TestDaemonKeeper.Backoff()
        var waitingLogged = false
        while !Task.isCancelled {
            guard config.current.keepTestDaemon else {
                try? await Task.sleep(nanoseconds: Self.checkInterval * 1_000_000_000)
                continue
            }
            guard TestDaemonKeeper.canStart(await ConsoleSession.state()) else {
                if !waitingLogged {
                    log("Test daemon keeper: waiting for \(NSUserName()) to be on the Mac's screen (testmanagerd only starts then)")
                    waitingLogged = true
                }
                try? await Task.sleep(nanoseconds: Self.checkInterval * 1_000_000_000)
                continue
            }
            waitingLogged = false
            let started = Date()
            let outcome = await holdOnce()
            guard !Task.isCancelled else { break }
            let delay = backoff.delay(afterRunOf: Date().timeIntervalSince(started))
            log("Test daemon keeper: \(outcome); starting again in \(Self.describe(delay))")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        stop()
    }

    /// One keeper run, from start to exit. Returns how it ended.
    private func holdOnce() async -> String {
        let directory = TestDaemonKeeper.directory
        let process: BackgroundProcess
        do {
            try TestDaemonKeeper.writePackage(at: directory)
            process = try BackgroundProcess.start("/usr/bin/xcrun", TestDaemonKeeper.arguments(directory: directory), currentDirectory: directory)
        } catch {
            return "couldn't start (\(error.localizedDescription))"
        }
        lock.withLock { self.process = process }
        defer { lock.withLock { self.process = nil } }

        // Wait for the session to open, then for the run to end.
        let deadline = Date().addingTimeInterval(TestDaemonKeeper.startTimeout)
        var holding = false
        while process.isRunning, !Task.isCancelled {
            if !holding, process.output.contains(TestDaemonKeeper.holdingMarker) {
                holding = true
                log("Test daemon keeper: holding a test session open so testmanagerd keeps running")
            }
            if !holding, Date() > deadline {
                stop(process)
                return "its test didn't start within \(Self.describe(TestDaemonKeeper.startTimeout)), so it was stopped. Last output:\n" + String(process.output.suffix(1500))
            }
            if !config.current.keepTestDaemon {
                stop(process)
                return "stopped because keepTestDaemon was turned off"
            }
            await process.wait(seconds: holding ? 60 : 5)
        }
        if Task.isCancelled { stop(process); return "stopped" }
        let code = process.exitCode.map(String.init) ?? "?"
        return holding ? "its session ended (exit \(code))" : "exited before its test started (exit \(code)). Last output:\n" + String(process.output.suffix(1500))
    }

    func stop() {
        if let process = lock.withLock({ self.process }) { stop(process) }
    }

    /// SIGINT lets xcodebuild end the test run and its xctest; SIGKILL if it doesn't.
    private func stop(_ process: BackgroundProcess) {
        process.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { process.forceKill() }
    }

    private static func describe(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : "\(Int(seconds / 60)) min"
    }
}
