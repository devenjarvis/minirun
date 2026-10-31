import Foundation
import MiniRunKit

/// Something making one screen recording into a file.
protocol ScreenRecorder: Sendable {
    /// Stops recording and finishes the file. Returns what went wrong, if the recorder knows.
    func finish() async -> String?
    /// The error when the file came out empty, e.g. with the recorder's output.
    var emptyFileMessage: String { get }
}

/// Screen recordings, at most one per simulator or Mac app: `simctl io <udid> recordVideo` for
/// simulators, ScreenCaptureKit for a Mac app's window. A recording that stops before
/// stop_recording asks for it (its time ran out, the simulator was shut down or the app quit,
/// the menu bar app stopped it) keeps its file until stop_recording collects it.
actor ScreenRecordings {
    struct Finished: Sendable {
        let file: URL
        let duration: TimeInterval
        /// Why it stopped before stop_recording, e.g. "it reached the 60 s limit".
        let stoppedEarly: String?
        /// The screen's (or window's) width in points when the recording started, for sizing the GIF and stills.
        let pointWidth: Double?
        /// Set when no usable video came out.
        let problem: String?
    }

    private struct Active {
        let id: UUID
        let recorder: any ScreenRecorder
        let file: URL
        let startedAt: Date
        let pointWidth: Double?
        let timer: Task<Void, Never>
    }

    private var starting: Set<String> = []
    private var active: [String: Active] = [:]
    private var stopping: [String: Task<Finished, Never>] = [:]
    private var finished: [String: Finished] = [:]

    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("minirun-recordings", isDirectory: true)
    }

    /// Simulator UDIDs and Mac app ids recording right now (including ones starting, or whose file is being finished).
    var recording: Set<String> { Set(active.keys).union(stopping.keys).union(starting) }

    /// Starts recording a simulator. Fails if it's already recording, or simctl gives up at once.
    func start(udid: String, maxSeconds: Int, pointWidth: Double?) async throws {
        // Run simctl itself rather than through xcrun, so the SIGINT that ends the recording reaches it.
        let found = try await Shell.check("/usr/bin/xcrun", ["--find", "simctl"], timeout: 30, what: "Finding simctl")
        let simctl = found.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try await start(key: udid, maxSeconds: maxSeconds, pointWidth: pointWidth) { file, _ in
            try await SimctlRecorder.start(simctl: simctl, udid: udid, file: file)
        }
    }

    /// Starts a recording under `key` (a simulator UDID or Mac app id). `begin` starts the recorder
    /// writing into the file it's given, and gets a function to call with the reason if the
    /// recording stops by itself.
    func start(key: String, maxSeconds: Int, pointWidth: Double?,
               begin: @Sendable (_ file: URL, _ stopped: @escaping @Sendable (String) -> Void) async throws -> any ScreenRecorder) async throws {
        // No awaits from here until the key is in `starting`, so two calls can't both start one.
        guard active[key] == nil, stopping[key] == nil, !starting.contains(key) else {
            throw ToolError("This simulator or app is already recording. Call stop_recording first.")
        }
        starting.insert(key)
        defer { starting.remove(key) }
        // A recording nobody collected is replaced.
        if let old = finished.removeValue(forKey: key) { try? FileManager.default.removeItem(at: old.file) }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let safe = String(key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        let file = Self.directory.appendingPathComponent("\(safe)-\(Int(Date().timeIntervalSince1970)).mp4")
        let id = UUID()
        let stopped: @Sendable (String) -> Void = { [weak self] reason in
            Task { await self?.halt(key, reason: reason, onlyID: id) }
        }
        let recorder: any ScreenRecorder
        do {
            recorder = try await begin(file, stopped)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        let timer = Task { [self] in
            try? await Task.sleep(nanoseconds: UInt64(maxSeconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await halt(key, reason: "it reached the \(maxSeconds) s limit", onlyID: id)
        }
        active[key] = Active(id: id, recorder: recorder, file: file, startedAt: Date(), pointWidth: pointWidth, timer: timer)
    }

    /// Stops a recording and keeps its file for stop_recording. Returns false if nothing was recording.
    @discardableResult
    func halt(_ key: String, reason: String?) async -> Bool {
        await halt(key, reason: reason, onlyID: nil)
    }

    /// With `onlyID`, only stops that recording, not a newer one under the same key.
    private func halt(_ key: String, reason: String?, onlyID: UUID?) async -> Bool {
        if let task = stopping[key] {
            _ = await task.value
            return true
        }
        guard let recording = active[key], onlyID == nil || recording.id == onlyID else { return false }
        active[key] = nil
        recording.timer.cancel()
        let task = Task { [self] () -> Finished in
            let done = await Self.finish(recording, reason: reason)
            self.store(key, done)
            return done
        }
        stopping[key] = task
        _ = await task.value
        return true
    }

    private func store(_ key: String, _ done: Finished) {
        stopping[key] = nil
        finished[key] = done
    }

    /// The finished recording for stop_recording, stopping it first if it's still going.
    func collect(_ key: String) async throws -> Finished {
        await halt(key, reason: nil)
        guard let done = finished.removeValue(forKey: key) else {
            throw ToolError("Nothing is recording here. Call start_recording first.")
        }
        if let problem = done.problem {
            try? FileManager.default.removeItem(at: done.file)
            throw ToolError(problem)
        }
        return done
    }

    private static func finish(_ recording: Active, reason: String?) async -> Finished {
        let error = await recording.recorder.finish()
        let duration = Date().timeIntervalSince(recording.startedAt)
        let size = (try? FileManager.default.attributesOfItem(atPath: recording.file.path)[.size] as? NSNumber)?.intValue ?? 0
        // A recording that went wrong partway may still have a usable file with what came before.
        let problem = size > 0 ? nil : [recording.recorder.emptyFileMessage, error].compactMap { $0 }.joined(separator: "\n")
        return Finished(file: recording.file, duration: duration, stoppedEarly: reason, pointWidth: recording.pointWidth, problem: problem)
    }
}

/// `simctl io <udid> recordVideo`, which SIGINT stops.
struct SimctlRecorder: ScreenRecorder {
    let process: BackgroundProcess

    static func start(simctl: String, udid: String, file: URL) async throws -> SimctlRecorder {
        let process = try BackgroundProcess.start(simctl, ["io", udid, "recordVideo", "--codec=h264", "--force", file.path])
        // simctl says "Recording started" once frames are flowing; a bad UDID makes it exit at once.
        for _ in 0..<30 {
            if !process.isRunning || process.output.contains("Recording started") { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if !process.isRunning {
            throw ToolError("simctl recordVideo stopped at once:\n" + Shell.tail(process.output, limit: 2000))
        }
        return SimctlRecorder(process: process)
    }

    /// SIGINT makes simctl finish the file (it writes the index last), so wait for it to exit.
    func finish() async -> String? {
        process.interrupt()
        if !(await process.wait(seconds: 20)) {
            process.forceKill()
            await process.wait(seconds: 5)
        }
        return nil
    }

    var emptyFileMessage: String { "simctl recordVideo didn't write a video:\n" + Shell.tail(process.output, limit: 2000) }
}
