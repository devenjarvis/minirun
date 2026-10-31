import Foundation
import MiniRunKit

/// Screen recordings, at most one per simulator, made by `simctl io <udid> recordVideo`. A
/// recording that stops before stop_recording asks for it (its time ran out, the simulator was
/// shut down, the menu bar app stopped it) keeps its file until stop_recording collects it.
actor ScreenRecordings {
    struct Finished: Sendable {
        let file: URL
        let duration: TimeInterval
        /// Why it stopped before stop_recording, e.g. "it reached the 60 s limit".
        let stoppedEarly: String?
        /// The screen's width in points when the recording started, for sizing the GIF and stills.
        let pointWidth: Double?
        /// Set when no usable video came out.
        let problem: String?
    }

    private struct Active {
        let process: BackgroundProcess
        let file: URL
        let startedAt: Date
        let pointWidth: Double?
        let timer: Task<Void, Never>
    }

    private var active: [String: Active] = [:]
    private var stopping: [String: Task<Finished, Never>] = [:]
    private var finished: [String: Finished] = [:]

    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("minirun-recordings", isDirectory: true)
    }

    /// Simulators recording right now (including ones whose file is being finished).
    var recording: Set<String> { Set(active.keys).union(stopping.keys) }

    /// Starts recording. Fails if this simulator is already recording, or simctl gives up at once.
    func start(udid: String, maxSeconds: Int, pointWidth: Double?) async throws {
        // Run simctl itself rather than through xcrun, so the SIGINT that ends the recording reaches it.
        let found = try await Shell.check("/usr/bin/xcrun", ["--find", "simctl"], timeout: 30, what: "Finding simctl")
        let simctl = found.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // No awaits from here until the recording is listed, so two calls can't both start one.
        guard active[udid] == nil, stopping[udid] == nil else {
            throw ToolError("This simulator is already recording. Call stop_recording first.")
        }
        // A recording nobody collected is replaced.
        if let old = finished.removeValue(forKey: udid) { try? FileManager.default.removeItem(at: old.file) }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let file = Self.directory.appendingPathComponent("\(udid)-\(Int(Date().timeIntervalSince1970)).mp4")
        let process = try BackgroundProcess.start(simctl, ["io", udid, "recordVideo", "--codec=h264", "--force", file.path])
        let timer = Task { [self] in
            try? await Task.sleep(nanoseconds: UInt64(maxSeconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await halt(udid, reason: "it reached the \(maxSeconds) s limit")
        }
        active[udid] = Active(process: process, file: file, startedAt: Date(), pointWidth: pointWidth, timer: timer)

        // simctl says "Recording started" once frames are flowing; a bad UDID makes it exit at once.
        for _ in 0..<30 {
            if !process.isRunning || process.output.contains("Recording started") { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if !process.isRunning {
            timer.cancel()
            active[udid] = nil
            try? FileManager.default.removeItem(at: file)
            throw ToolError("simctl recordVideo stopped at once:\n" + Shell.tail(process.output, limit: 2000))
        }
    }

    /// Stops a recording and keeps its file for stop_recording. Returns false if nothing was recording.
    @discardableResult
    func halt(_ udid: String, reason: String?) async -> Bool {
        if let task = stopping[udid] {
            _ = await task.value
            return true
        }
        guard let recording = active.removeValue(forKey: udid) else { return false }
        recording.timer.cancel()
        let task = Task { [self] () -> Finished in
            let done = await Self.finish(recording, reason: reason)
            self.store(udid, done)
            return done
        }
        stopping[udid] = task
        _ = await task.value
        return true
    }

    private func store(_ udid: String, _ done: Finished) {
        stopping[udid] = nil
        finished[udid] = done
    }

    /// The finished recording for stop_recording, stopping it first if it's still going.
    func collect(_ udid: String) async throws -> Finished {
        await halt(udid, reason: nil)
        guard let done = finished.removeValue(forKey: udid) else {
            throw ToolError("This simulator isn't recording. Call start_recording first.")
        }
        if let problem = done.problem {
            try? FileManager.default.removeItem(at: done.file)
            throw ToolError(problem)
        }
        return done
    }

    /// SIGINT makes simctl finish the file (it writes the index last), so wait for it to exit.
    private static func finish(_ recording: Active, reason: String?) async -> Finished {
        recording.process.interrupt()
        if !(await recording.process.wait(seconds: 20)) {
            recording.process.forceKill()
            await recording.process.wait(seconds: 5)
        }
        let duration = Date().timeIntervalSince(recording.startedAt)
        let size = (try? FileManager.default.attributesOfItem(atPath: recording.file.path)[.size] as? NSNumber)?.intValue ?? 0
        let problem = size > 0 ? nil : "simctl recordVideo didn't write a video:\n" + Shell.tail(recording.process.output, limit: 2000)
        return Finished(file: recording.file, duration: duration, stoppedEarly: reason, pointWidth: recording.pointWidth, problem: problem)
    }
}
