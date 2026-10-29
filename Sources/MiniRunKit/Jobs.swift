import Foundation

/// Long-running work (builds, tests, commands) runs as a job so a tool call can return before
/// Claude's request times out. The caller waits up to `wait_seconds`; if the job is still going it
/// gets a job id back and polls with `get_job`.
public actor JobStore {
    public enum Status: String, Sendable { case running, succeeded, failed }

    public struct Job: Sendable {
        public let id: String
        public let title: String
        public let startedAt: Date
        public var finishedAt: Date?
        public var status: Status
        public var result: ToolResult?
        public var logPath: String?
    }

    private var jobs: [String: Job] = [:]
    private struct Waiter { let token: UUID; let continuation: CheckedContinuation<Void, Never> }
    private var waiters: [String: [Waiter]] = [:]
    private var order: [String] = []
    private let maxJobs = 50

    public init() {}

    /// Starts `work` in the background and returns the job id immediately.
    public func start(title: String, logPath: String?, _ work: @escaping @Sendable () async throws -> ToolResult) -> String {
        let id = "job_" + String(UUID().uuidString.prefix(8)).lowercased()
        jobs[id] = Job(id: id, title: title, startedAt: Date(), status: .running, logPath: logPath)
        order.append(id)
        trim()
        Task {
            let result: ToolResult
            do {
                result = try await work()
            } catch {
                result = .error(error.localizedDescription)
            }
            self.finish(id, result: result)
        }
        return id
    }

    private func finish(_ id: String, result: ToolResult) {
        guard var job = jobs[id] else { return }
        job.status = result.isError ? .failed : .succeeded
        job.result = result
        job.finishedAt = Date()
        jobs[id] = job
        for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.continuation.resume() }
    }

    private func trim() {
        while order.count > maxJobs, let oldest = order.first, jobs[oldest]?.status != .running {
            order.removeFirst()
            jobs.removeValue(forKey: oldest)
        }
    }

    public func job(_ id: String) -> Job? { jobs[id] }

    public func list() -> [Job] { order.compactMap { jobs[$0] }.reversed() }

    /// Waits until the job finishes or `seconds` pass, then returns its current state.
    public func wait(_ id: String, seconds: Double) async -> Job? {
        guard let job = jobs[id] else { return nil }
        guard job.status == .running, seconds > 0 else { return job }
        let token = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[id, default: []].append(Waiter(token: token, continuation: continuation))
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                self.timeOut(id, token: token)
            }
        }
        return jobs[id]
    }

    private func timeOut(_ id: String, token: UUID) {
        guard var list = waiters[id], let index = list.firstIndex(where: { $0.token == token }) else { return }
        let waiter = list.remove(at: index)
        waiters[id] = list.isEmpty ? nil : list
        waiter.continuation.resume()
    }

    /// The tool result to hand back for a job: its own result if finished, otherwise a status note.
    public func report(_ id: String, waited seconds: Double) async -> ToolResult {
        guard let job = await wait(id, seconds: seconds) else {
            return .error("No job with id \(id). Jobs are kept in memory and are lost when minirun restarts.")
        }
        if let result = job.result {
            var content = result.content
            content.insert(.text("[\(job.id)] \(job.title): \(job.status.rawValue) in \(Self.format(job.finishedAt!.timeIntervalSince(job.startedAt)))"), at: 0)
            return ToolResult(content, isError: result.isError)
        }
        let elapsed = Date().timeIntervalSince(job.startedAt)
        var text = "[\(job.id)] \(job.title) is still running (\(Self.format(elapsed)) so far). Call get_job with job_id \"\(job.id)\" to wait for it."
        if let logPath = job.logPath, let tail = Self.logTail(logPath) {
            text += "\n\nLatest output:\n" + tail
        }
        return .text(text)
    }

    static func format(_ seconds: TimeInterval) -> String {
        seconds < 90 ? "\(Int(seconds))s" : "\(Int(seconds / 60))m \(Int(seconds) % 60)s"
    }

    static func logTail(_ path: String, lines: Int = 15) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > 16_384 ? size - 16_384 : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
    }
}
