import Foundation

/// The relay calls this run of minirun has taken. A result sent just as the connection dropped
/// is lost with it, so after reconnecting the relay asks about the calls it's still waiting on
/// and this answers from here.
public final class CallLedger: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case running
        case finished(ToolResult)
        /// Never received, or finished so long ago that it was forgotten.
        case unknown
    }

    private let lock = NSLock()
    private var running = Set<String>()
    private var finished: [String: (result: ToolResult, at: Date)] = [:]
    /// Longer than the relay waits for a reconnect (a minute) plus the longest reconnect backoff.
    private let keep: TimeInterval

    public init(keep: TimeInterval = 180) {
        self.keep = keep
    }

    public func start(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        running.insert(id)
    }

    public func finish(_ id: String, result: ToolResult, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        running.remove(id)
        // Results can hold screenshots, so only keep them as long as they might be asked for.
        finished = finished.filter { now.timeIntervalSince($0.value.at) < keep }
        finished[id] = (result, now)
    }

    public func state(of id: String, now: Date = Date()) -> State {
        lock.lock()
        defer { lock.unlock() }
        if running.contains(id) { return .running }
        if let entry = finished[id], now.timeIntervalSince(entry.at) < keep { return .finished(entry.result) }
        return .unknown
    }
}
