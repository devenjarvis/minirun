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
    public let timedOut: Bool
    public let duration: TimeInterval

    public var succeeded: Bool { exitCode == 0 && !timedOut }

    /// Combined output, trimmed to the last `limit` characters.
    public func tail(_ limit: Int = 4000) -> String {
        let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        return Shell.tail(combined, limit: limit)
    }
}

public enum Shell {
    /// Runs a program and waits for it. Output is captured in memory and, if `logURL` is set,
    /// also appended to that file as it arrives.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        cwd: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 120,
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
                // Watchdog: terminate, then kill, if the deadline passes.
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    exit.markTimedOut()
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                        if process.isRunning { kill(pid, SIGKILL) }
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        // Drain whatever is left in the pipes.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let restOut = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? nil
        let restErr = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? nil
        if let restOut, !restOut.isEmpty { collector.append(restOut, isError: false) }
        if let restErr, !restErr.isEmpty { collector.append(restErr, isError: true) }
        collector.close()

        let (out, err) = collector.snapshot()
        return ShellResult(
            exitCode: exit.code,
            stdout: out,
            stderr: err,
            timedOut: exit.timedOut,
            duration: Date().timeIntervalSince(started)
        )
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
    func set(_ code: Int32) { lock.lock(); _code = code; lock.unlock() }
    func markTimedOut() { lock.lock(); _timedOut = true; lock.unlock() }
    var code: Int32 { lock.lock(); defer { lock.unlock() }; return _code }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return _timedOut }
}

/// Thread-safe accumulator for process output.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private let logHandle: FileHandle?

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
        // Keep memory bounded for very chatty builds; the log file keeps everything.
        let cap = 8 * 1024 * 1024
        if stdout.count > cap { stdout = stdout.suffix(cap / 2) }
        if stderr.count > cap { stderr = stderr.suffix(cap / 2) }
        logHandle?.write(data)
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
