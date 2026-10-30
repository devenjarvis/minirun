import Foundation
import MiniRunKit
import MiniRunSim

/// Keeps a WebSocket open to the Cloudflare relay, runs tool calls that arrive on it, and streams
/// the screen while someone is watching. Reconnects with backoff forever.
public final class RelayClient: NSObject, @unchecked Sendable, URLSessionWebSocketDelegate {
    private let url: URL
    private let token: String
    private let registry: ToolRegistry
    private var session: URLSession!
    private var socket: URLSessionWebSocketTask?
    private var streamer: FrameStreamer!
    private var streamControl: Task<Void, Never>?
    private let touches = TouchQueue()
    /// When the last keep-alive ping went out, to time the round trip to the relay.
    private var pingSentAt: Date?
    private var pingsTimed = 0
    private let log: @Sendable (String) -> Void
    private let stateLock = NSLock()
    private var state: ServeStatus.Relay
    /// Tells the relay this is the same run of minirun when it reconnects.
    private let instance = UUID().uuidString
    private let calls = CallLedger()

    public init(url: URL, token: String, registry: ToolRegistry, log: @escaping @Sendable (String) -> Void) {
        self.url = url
        self.token = token
        self.registry = registry
        self.log = log
        state = ServeStatus.Relay(state: .connecting, host: url.host)
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = .infinity
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        streamer = FrameStreamer(
            registry: registry,
            sendFrame: { [weak self] data in await self?.send(.data(data)) },
            sendText: { [weak self] json in await self?.send(.string(json.encodedString())) }
        )
    }

    /// The connection as of now, for `minirun status`.
    public var relayStatus: ServeStatus.Relay {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state
    }

    private func setState(_ new: ServeStatus.Relay.State, problem: String? = nil) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if state.state != new { state.since = Date() }
        state.state = new
        // Keep the last problem while reconnecting, so status can say why it dropped.
        if new == .connected { state.problem = nil } else if let problem { state.problem = problem }
    }

    /// Runs until the process exits.
    public func run() async {
        var backoff: Double = 1
        while true {
            let connectedAt = Date()
            await connectOnce()
            await streamControl?.value
            await streamer.stop()
            // A finger left down on the simulator would block everything else.
            await touches.releaseAll()
            // Reset the backoff after a connection that lasted a while.
            if Date().timeIntervalSince(connectedAt) > 60 { backoff = 1 }
            log("Relay disconnected; reconnecting in \(Int(backoff))s")
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            backoff = min(30, backoff * 2)
        }
    }

    private func connectOnce() async {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("minirun/\(MiniRun.version)", forHTTPHeaderField: "User-Agent")
        setState(.connecting)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 32 * 1024 * 1024
        socket = task
        task.resume()

        let hello = RelayProtocol.hello(host: Self.hostInfo(), tools: registry.definitions, instance: instance)
        do {
            try await task.send(.string(hello.encodedString()))
        } catch {
            log("Relay connect failed: \(error.localizedDescription)")
            setState(.disconnected, problem: "Couldn't connect: \(error.localizedDescription)")
            return
        }
        log("Connected to relay \(url.host ?? "")")
        setState(.connected)

        // The relay answers pings without running any code, so a ping's round trip is the network
        // distance to wherever Cloudflare placed it. The first few are logged.
        pingsTimed = 0
        let keepAlive = Task { [weak self, weak task] in
            var first = true
            while !Task.isCancelled {
                if !first { try? await Task.sleep(nanoseconds: 20_000_000_000) }
                first = false
                self?.pingSentAt = Date()
                try? await task?.send(.string("ping"))
            }
        }
        defer { keepAlive.cancel() }

        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                if task.closeCode == .policyViolation || task.closeCode.rawValue == 4001 {
                    log("Relay rejected the agent token. Check agentToken in ~/.config/minirun/config.json matches AGENT_TOKEN on the Worker.")
                    setState(.disconnected, problem: "The relay rejected the agent token. Check that agentToken in ~/.config/minirun/config.json matches AGENT_TOKEN on the Worker.")
                } else {
                    setState(.disconnected, problem: "Connection lost: \(error.localizedDescription)")
                }
                return
            }
            switch message {
            case .string(let text):
                if text == "pong" {
                    if let sent = pingSentAt, pingsTimed < 3 {
                        pingsTimed += 1
                        log("Relay round trip: \(Int(Date().timeIntervalSince(sent) * 1000))ms")
                    }
                    pingSentAt = nil
                    continue
                }
                handle(RelayProtocol.decode(text))
            case .data:
                continue
            @unknown default:
                continue
            }
        }
    }

    private func handle(_ incoming: RelayProtocol.Incoming) {
        switch incoming {
        case .call(let id, let tool, let arguments):
            if let id { calls.start(id) }
            Task {
                let result = await registry.call(tool, arguments: arguments)
                if let id {
                    // Kept in case this send is lost to a dropped connection (see .pending).
                    calls.finish(id, result: result)
                    await send(.string(RelayProtocol.result(id: id, result: result).encodedString()))
                } else if result.isError {
                    log("Viewer action \(tool) failed: \(result.content.first.map { "\($0)" } ?? "")")
                }
            }
        case .streams(let requests):
            // Apply stream changes in the order they arrived.
            let previous = streamControl
            let streamer = self.streamer!
            streamControl = Task {
                await previous?.value
                await streamer.set(requests)
            }
        case .ack(let sequence, let key):
            Task { await streamer.ack(sequence, key: key) }
        case .keyframe(let key):
            Task { await streamer.requestKeyframe(key: key) }
        case .pending(let ids):
            Task {
                for id in ids {
                    let result: ToolResult
                    switch calls.state(of: id) {
                    case .running: continue // Its result goes out when it finishes.
                    case .finished(let finished): result = finished
                    case .unknown: result = .error("The Mac never got this call (the connection dropped), so it didn't run. Try again.")
                    }
                    await send(.string(RelayProtocol.result(id: id, result: result).encodedString()))
                }
            }
        case .touch(let udid, let phase, let x, let y):
            guard let phase = SimulatorDriver.TouchPhase(rawValue: phase) else { break }
            let log = self.log
            Task { await touches.add(TouchQueue.Event(udid: udid, phase: phase, x: x, y: y), log: log) }
        case .unknown:
            break
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async {
        try? await socket?.send(message)
    }

    static func hostInfo() -> [String: JSONValue] {
        [
            "name": .string(Host.current().localizedName ?? ProcessInfo.processInfo.hostName),
            "os": .string(ProcessInfo.processInfo.operatingSystemVersionString),
            "minirun": .string(MiniRun.version),
        ]
    }
}

/// Delivers a viewer's live touches to the simulator one at a time, in order. When moves pile up
/// (the simulator is slower than the finger), only the latest of a run of moves is sent.
actor TouchQueue {
    struct Event: Sendable {
        let udid: String
        let phase: SimulatorDriver.TouchPhase
        let x: Double
        let y: Double
    }

    private var pending: [Event] = []
    private var draining = false

    func add(_ event: Event, log: @escaping @Sendable (String) -> Void) async {
        pending.append(event)
        guard !draining else { return }
        draining = true
        while !pending.isEmpty {
            let next = pending.removeFirst()
            if next.phase == .move, let following = pending.first, following.phase == .move, following.udid == next.udid { continue }
            do {
                try await SimulatorDriver.shared.touch(udid: next.udid, phase: next.phase, x: next.x, y: next.y)
            } catch {
                log("Live touch failed: \(error.localizedDescription)")
            }
        }
        draining = false
    }

    func releaseAll() async {
        pending.removeAll()
        await SimulatorDriver.shared.releaseTouches()
    }
}

public enum MiniRun {
    public static let version = "0.1.0"
}
