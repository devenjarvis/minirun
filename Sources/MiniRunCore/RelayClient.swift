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
    private let log: @Sendable (String) -> Void
    private let stateLock = NSLock()
    private var state: ServeStatus.Relay

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

        let hello = RelayProtocol.hello(host: Self.hostInfo(), tools: registry.definitions)
        do {
            try await task.send(.string(hello.encodedString()))
        } catch {
            log("Relay connect failed: \(error.localizedDescription)")
            setState(.disconnected, problem: "Couldn't connect: \(error.localizedDescription)")
            return
        }
        log("Connected to relay \(url.host ?? "")")
        setState(.connected)

        let keepAlive = Task { [weak task] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
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
                if text == "pong" { continue }
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
            Task {
                let result = await registry.call(tool, arguments: arguments)
                if let id {
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

public enum MiniRun {
    public static let version = "0.1.0"
}
