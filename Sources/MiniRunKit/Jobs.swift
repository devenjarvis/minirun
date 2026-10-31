import Foundation

/// Long-running work (builds, tests, commands) runs as a job so a tool call can return before
/// Claude's request times out. The caller waits up to `wait_seconds`; if the job is still going it
/// gets a job id back and polls with `get_job`.
public actor JobStore {
    public enum Status: String, Sendable { case running, succeeded, failed, cancelled }

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
    /// The work of each running job, so it can be cancelled.
    private var tasks: [String: Task<Void, Never>] = [:]
    private var order: [String] = []
    private let maxJobs = 50

    /// The longest a tool call waits on a job before handing back its id. Claude's MCP client gives
    /// up on a call after about 60 seconds, and the job keeps running when it does, so waiting
    /// longer only loses the job id.
    public static let maxWait: Double = 50

    /// `wait_seconds` as asked, defaulting to 45 and kept within 0...`maxWait`.
    public static func waitSeconds(_ asked: Double?) -> Double {
        min(maxWait, max(0, asked ?? 45))
    }

    /// Where the jobs are written, so they outlive a restart of minirun. nil keeps them in memory only.
    private let recordURL: URL?

    public static var defaultRecordURL: URL {
        MiniRunConfig.configURL.deletingLastPathComponent().appendingPathComponent("jobs.json")
    }

    /// A job as written to disk: its result, cut down to the text.
    struct Record: Codable {
        var id: String
        var title: String
        var startedAt: Date
        var finishedAt: Date?
        var status: String
        var logPath: String?
        var text: String?
        var isError: Bool?
    }

    /// With `recordURL`, loads the jobs a previous run left there. Any that were still running
    /// were cut off by the restart: they're marked failed, so get_job says what happened instead
    /// of "no such job".
    public init(recordURL: URL? = nil, now: Date = Date()) {
        self.recordURL = recordURL
        guard let recordURL, let data = try? Data(contentsOf: recordURL),
              let records = try? Self.decoder.decode([Record].self, from: data) else { return }
        for record in records {
            var job = Job(
                id: record.id, title: record.title, startedAt: record.startedAt, finishedAt: record.finishedAt,
                status: Status(rawValue: record.status) ?? .failed, result: nil, logPath: record.logPath
            )
            if job.status == .running {
                job.status = .failed
                job.finishedAt = now
                job.result = .error(
                    "minirun restarted while this job was running, so it was stopped and its result is lost. " +
                    "Start it again if you still need it." +
                    (record.logPath.map { "\nLog of the run so far: \($0)" } ?? "")
                )
            } else {
                let note = "(Result from before minirun restarted; images aren't kept.)"
                job.result = ToolResult([.text([record.text, note].compactMap { $0 }.joined(separator: "\n"))], isError: record.isError ?? (job.status != .succeeded))
            }
            jobs[job.id] = job
            order.append(job.id)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func save() {
        guard let recordURL else { return }
        let records = order.compactMap { jobs[$0] }.map { job in
            Record(
                id: job.id, title: job.title, startedAt: job.startedAt, finishedAt: job.finishedAt,
                status: job.status.rawValue, logPath: job.logPath,
                text: job.result.map { Self.text(of: $0) }, isError: job.result?.isError
            )
        }
        guard let data = try? Self.encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: recordURL, options: .atomic)
    }

    /// The text of a result, capped so the file stays small.
    static func text(of result: ToolResult) -> String {
        let text = result.content.compactMap { content -> String? in
            if case .text(let text) = content { return text }
            return nil
        }.joined(separator: "\n")
        return Shell.tail(text, limit: 8000)
    }

    /// Starts `work` in the background and returns the job id immediately.
    public func start(title: String, logPath: String?, _ work: @escaping @Sendable () async throws -> ToolResult) -> String {
        let id = "job_" + String(UUID().uuidString.prefix(8)).lowercased()
        jobs[id] = Job(id: id, title: title, startedAt: Date(), status: .running, logPath: logPath)
        order.append(id)
        trim()
        save()
        tasks[id] = Task {
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
        tasks[id] = nil
        // A cancelled job already counts as finished.
        guard var job = jobs[id], job.status == .running else { return }
        job.status = result.isError ? .failed : .succeeded
        job.result = result
        job.finishedAt = Date()
        jobs[id] = job
        save()
        for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.continuation.resume() }
    }

    private func trim() {
        while order.count > maxJobs, let oldest = order.first, jobs[oldest]?.status != .running {
            order.removeFirst()
            jobs.removeValue(forKey: oldest)
        }
    }

    /// Cancels a running job: its task is cancelled, which stops the commands it runs (see
    /// `Shell.run`). The job counts as finished at once, so waiters don't wait for it to unwind.
    @discardableResult
    public func cancel(_ id: String) throws -> Job {
        guard var job = jobs[id] else { throw ToolError("No job with id \(id).") }
        guard job.status == .running else { throw ToolError("\(job.id) (\(job.title)) already \(job.status.rawValue).") }
        tasks.removeValue(forKey: id)?.cancel()
        job.status = .cancelled
        job.finishedAt = Date()
        job.result = .error("Cancelled. Its commands were stopped, so the simulator it used is no longer busy (it stays reserved for the same repo + ref).")
        jobs[id] = job
        save()
        for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.continuation.resume() }
        return job
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
            return .error("No job with id \(id). list_jobs shows the recent ones.")
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

    public static func format(_ seconds: TimeInterval) -> String {
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
