import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ShellResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    /// Stopped for running too long, or (see `stalled`) for going quiet too long.
    public let timedOut: Bool
    /// Stopped because it wrote no output for the stall timeout. `timedOut` is set too.
    public let stalled: Bool
    public let duration: TimeInterval

    public init(exitCode: Int32, stdout: String, stderr: String = "", timedOut: Bool = false, stalled: Bool = false, duration: TimeInterval = 0) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut || stalled
        self.stalled = stalled
        self.duration = duration
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut }

    /// Combined output, trimmed to the last `limit` characters.
    public func tail(_ limit: Int = 4000) -> String {
        let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        return Shell.tail(combined, limit: limit)
    }
}

public enum Shell {
    /// Runs a program and waits for it. Output is captured in memory and, if `logURL` is set,
    /// also appended to that file as it arrives. Cancelling the calling task stops the program.
    /// With `stallTimeout`, the program is also stopped once it has written nothing for that long:
    /// a hung xcodebuild otherwise holds its simulator until the overall `timeout`.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        cwd: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 120,
        stallTimeout: TimeInterval? = nil,
        logURL: URL? = nil,
        stdin: Data? = nil
    ) async throws -> ShellResult {
        let process = Process()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let stdin {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            stdinPipe.fileHandleForWriting.write(stdin)
            try? stdinPipe.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let collector = OutputCollector(logURL: logURL)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.append(data, isError: false) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.append(data, isError: true) }
        }

        let started = Date()
        let exit = ExitBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { finished in
                    ChildProcessLedger.shared.remove(finished.processIdentifier)
                    exit.set(finished.terminationStatus)
                    continuation.resume()
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                // Only long-running work is worth recording (builds, tests, commands); the quick
                // simctl calls behind taps and screenshots would just rewrite the file.
                if timeout > 120 {
                    ChildProcessLedger.shared.add(process.processIdentifier, names: ChildProcessLedger.names(executable: executable, arguments: arguments))
                }
                // Cancelled before the program started: onCancel found nothing to stop.
                if Task.isCancelled { stop(process) }
                // Watchdog: terminate, then kill, if the deadline passes.
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    exit.markTimedOut()
                    stop(process)
                }
                if let stallTimeout, stallTimeout > 0 {
                    watchForStall(process, collector: collector, exit: exit, after: stallTimeout)
                }
            }
        } onCancel: {
            stop(process)
        }

        // Let the readability handlers drain what's buffered. Don't block on EOF: a child the
        // command left running (or a daemon it spawned) can hold the pipe open indefinitely.
        var lastCount = -1
        for _ in 0..<20 {
            let count = collector.byteCount
            if count == lastCount { break }
            lastCount = count
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        collector.close()

        let (out, err) = collector.snapshot()
        return ShellResult(
            exitCode: exit.code,
            stdout: out,
            stderr: err,
            timedOut: exit.timedOut,
            stalled: exit.stalled,
            duration: Date().timeIntervalSince(started)
        )
    }

    /// Checks every few seconds whether `process` has gone `seconds` without output, and stops it
    /// if so. Ends when the process does.
    private static func watchForStall(_ process: Process, collector: OutputCollector, exit: ExitBox, after seconds: TimeInterval) {
        let interval = min(10, max(1, seconds / 6))
        DispatchQueue.global().asyncAfter(deadline: .now() + interval) {
            guard process.isRunning else { return }
            if Date().timeIntervalSince(collector.lastOutputAt) >= seconds {
                exit.markStalled()
                stop(process)
            } else {
                watchForStall(process, collector: collector, exit: exit, after: seconds)
            }
        }
    }

    /// Terminates a running program and its direct children (e.g. the command a shell is
    /// running), then kills it if it's still there 5 seconds later. Returns at once; the work
    /// happens on another thread.
    static func stop(_ process: Process) {
        DispatchQueue.global().async {
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            // Pause the program while its children go: a shell would otherwise run its next
            // command, and once it exits its children belong to launchd where -P can't find them.
            kill(pid, SIGSTOP)
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = ["-TERM", "-P", String(pid)]
            if (try? pkill.run()) != nil { pkill.waitUntilExit() }
            process.terminate()
            kill(pid, SIGCONT)
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    /// Convenience: run and throw a readable error unless it succeeds.
    @discardableResult
    public static func check(
        _ executable: String,
        _ arguments: [String],
        cwd: String? = nil,
        timeout: TimeInterval = 120,
        what: String? = nil
    ) async throws -> ShellResult {
        let result = try await run(executable, arguments, cwd: cwd, timeout: timeout)
        guard result.succeeded else {
            let label = what ?? ([executable] + arguments).joined(separator: " ")
            let reason = result.timedOut ? "timed out after \(Int(timeout))s" : "exited with code \(result.exitCode)"
            throw ToolError("\(label) \(reason):\n\(result.tail(3000))")
        }
        return result
    }

    public static func tail(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return "…" + String(text.suffix(limit))
    }
}

final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _code: Int32 = -1
    private var _timedOut = false
    private var _stalled = false
    func set(_ code: Int32) { lock.lock(); _code = code; lock.unlock() }
    func markTimedOut() { lock.lock(); _timedOut = true; lock.unlock() }
    func markStalled() { lock.lock(); _stalled = true; lock.unlock() }
    var code: Int32 { lock.lock(); defer { lock.unlock() }; return _code }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return _timedOut }
    var stalled: Bool { lock.lock(); defer { lock.unlock() }; return _stalled }
}

/// Thread-safe accumulator for process output.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private let logHandle: FileHandle?
    private var _lastOutputAt = Date()

    init(logURL: URL?) {
        if let logURL {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: logURL)
            _ = try? logHandle?.seekToEnd()
        } else {
            logHandle = nil
        }
    }

    func append(_ data: Data, isError: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isError { stderr.append(data) } else { stdout.append(data) }
        _lastOutputAt = Date()
        // Keep memory bounded for very chatty builds; the log file keeps everything.
        let cap = 8 * 1024 * 1024
        if stdout.count > cap { stdout = stdout.suffix(cap / 2) }
        if stderr.count > cap { stderr = stderr.suffix(cap / 2) }
        logHandle?.write(data)
    }

    /// When the program last wrote anything (or started, if it hasn't yet).
    var lastOutputAt: Date {
        lock.lock()
        defer { lock.unlock() }
        return _lastOutputAt
    }

    var byteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stdout.count + stderr.count
    }

    func snapshot() -> (String, String) {
        lock.lock()
        defer { lock.unlock() }
        return (String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
    }

    func close() {
        try? logHandle?.close()
    }
}
