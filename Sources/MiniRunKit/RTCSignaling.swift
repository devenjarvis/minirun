import Foundation

/// WebRTC signaling (protocol 6). The relay passes JSON `rtc` messages between one viewer and the
/// Mac, adding the viewer's id, and the Mac sends video and takes input over a peer connection
/// with that viewer. See docs/live-view-latency-plan.md, "Shared contract (protocol 6)".
///
/// The Mac makes the offer, with one sendonly video track and two data channels: "touch"
/// (unordered, no retransmits) for touch moves, and "input" (reliable) for everything else.
extension RelayProtocol {
    /// A STUN or TURN server, as in the browser's `RTCIceServer`.
    public struct IceServer: Equatable, Sendable {
        public let urls: [String]
        public let username: String?
        public let credential: String?

        public init(urls: [String], username: String? = nil, credential: String? = nil) {
            self.urls = urls
            self.username = username
            self.credential = credential
        }

        /// `urls` may be one string or a list, as in the browser.
        init?(_ json: JSONValue) {
            let urls: [String]
            if let one = json["urls"]?.stringValue, json["urls"]?.arrayValue == nil {
                urls = [one]
            } else {
                urls = (json["urls"]?.arrayValue ?? []).compactMap(\.stringValue)
            }
            guard !urls.isEmpty else { return nil }
            self.init(urls: urls, username: json["username"]?.stringValue, credential: json["credential"]?.stringValue)
        }
    }

    /// A viewer asking for a peer connection to the stream `key`.
    public struct RTCStart: Equatable, Sendable {
        public let viewer: String
        /// The stream key, as for `stream` messages: a simulator UDID, a Mac app id, or "" for
        /// "whichever simulator is booted".
        public let key: String
        public let fps: Int
        public let quality: Int
        public let scale: Double
        public let iceServers: [IceServer]

        public init(viewer: String, key: String, fps: Int, quality: Int, scale: Double, iceServers: [IceServer]) {
            // The same limits as WebSocket streams.
            let stream = StreamRequest(key: key, fps: fps, quality: quality, scale: scale)
            self.viewer = viewer
            self.key = key
            self.fps = stream.fps
            self.quality = stream.quality
            self.scale = stream.scale
            self.iceServers = iceServers
        }
    }

    /// One trickled ICE candidate. A nil `candidate` means the other side has no more.
    public struct RTCCandidate: Equatable, Sendable {
        public let candidate: String?
        public let sdpMid: String?
        public let sdpMLineIndex: Int?

        public init(candidate: String?, sdpMid: String?, sdpMLineIndex: Int?) {
            self.candidate = candidate
            self.sdpMid = sdpMid
            self.sdpMLineIndex = sdpMLineIndex
        }
    }

    /// An `rtc` message from the relay to the Mac. Each carries the viewer id the relay gave the
    /// viewer's socket.
    public enum RTCSignal: Equatable, Sendable {
        case start(RTCStart)
        case answer(viewer: String, sdp: String)
        case candidate(viewer: String, RTCCandidate)
        /// The viewer left, switched to another device, or fell back to the WebSocket stream.
        case stop(viewer: String)

        public var viewer: String {
            switch self {
            case .start(let start): start.viewer
            case .answer(let viewer, _), .candidate(let viewer, _), .stop(let viewer): viewer
            }
        }

        /// Nil for a malformed message or one without a viewer id.
        init?(_ message: JSONValue) {
            guard let viewer = message["viewer"]?.stringValue, !viewer.isEmpty else { return nil }
            switch message["action"]?.stringValue {
            case "start":
                self = .start(RTCStart(
                    viewer: viewer, key: message["key"]?.stringValue ?? "",
                    fps: message["fps"]?.intValue ?? 30, quality: message["quality"]?.intValue ?? 60,
                    scale: message["scale"]?.doubleValue ?? 1,
                    iceServers: (message["iceServers"]?.arrayValue ?? []).compactMap(IceServer.init)
                ))
            case "answer":
                guard let sdp = message["sdp"]?.stringValue else { return nil }
                self = .answer(viewer: viewer, sdp: sdp)
            case "candidate":
                let candidate = message["candidate"].flatMap { $0 == .null ? nil : $0.stringValue }
                self = .candidate(viewer: viewer, RTCCandidate(
                    candidate: candidate, sdpMid: message["sdpMid"]?.stringValue, sdpMLineIndex: message["sdpMLineIndex"]?.intValue
                ))
            case "stop":
                self = .stop(viewer: viewer)
            default:
                return nil
            }
        }
    }

    // MARK: Mac -> relay -> viewer

    public static func rtcOffer(viewer: String, sdp: String) -> JSONValue {
        ["type": "rtc", "action": "offer", "viewer": .string(viewer), "sdp": .string(sdp)]
    }

    public static func rtcCandidate(viewer: String, _ candidate: RTCCandidate) -> JSONValue {
        [
            "type": "rtc", "action": "candidate", "viewer": .string(viewer),
            "candidate": candidate.candidate.map(JSONValue.string) ?? .null,
            "sdpMid": candidate.sdpMid.map(JSONValue.string) ?? .null,
            "sdpMLineIndex": candidate.sdpMLineIndex.map { JSONValue($0) } ?? .null,
        ]
    }

    /// The Mac gave up on the viewer's peer connection (it failed or never connected).
    public static func rtcStop(viewer: String) -> JSONValue {
        ["type": "rtc", "action": "stop", "viewer": .string(viewer)]
    }

    /// The Mac can't stream to the viewer over WebRTC; the viewer falls back to the WebSocket stream.
    public static func rtcError(viewer: String, message: String) -> JSONValue {
        ["type": "rtc", "action": "error", "viewer": .string(viewer), "message": .string(message)]
    }

    // MARK: Data channels

    /// The data channels' labels.
    public enum RTCChannel: String, Sendable {
        /// Unordered, no retransmits: touch moves, where only the latest matters.
        case touch
        /// Ordered and reliable: touch down and up, input, probes, and the Mac's messages.
        case input
    }

    /// Tools a viewer may call (fire-and-forget input). The same list as `VIEWER_TOOLS` in
    /// worker/src/relay.ts, which enforces it for input that goes through the relay.
    public static let viewerTools: Set<String> = [
        "tap", "swipe", "long_press", "type_text", "press_key", "press_button", "open_url",
        "scroll", "press_menu_item",
    ]

    /// A message from a viewer on a data channel.
    public enum ViewerMessage: Equatable, Sendable {
        /// One step of a live touch, in points.
        case touch(phase: String, x: Double, y: Double)
        case input(tool: String, arguments: JSONValue)
        /// Echoed back unchanged, so the viewer can time the round trip.
        case probe(t: JSONValue)
        case unknown
    }

    /// Parses a data channel message. The "touch" channel carries bare `{phase, x, y}`; the "input"
    /// channel carries messages with a `type`. Touches with an unknown phase or coordinates that
    /// aren't finite numbers are dropped, as the relay drops them.
    public static func viewerMessage(_ text: String, channel: RTCChannel) -> ViewerMessage {
        guard let message = try? JSONValue.parse(text), message.objectValue != nil else { return .unknown }
        let type = channel == .touch ? "touch" : message["type"]?.stringValue
        switch type {
        case "touch":
            guard let phase = message["phase"]?.stringValue, ["down", "move", "up"].contains(phase),
                  case .number(let x)? = message["x"], case .number(let y)? = message["y"],
                  x.isFinite, y.isFinite else { return .unknown }
            return .touch(phase: phase, x: x, y: y)
        case "input":
            guard let tool = message["tool"]?.stringValue else { return .unknown }
            return .input(tool: tool, arguments: message["arguments"] ?? [:])
        case "probe":
            return .probe(t: message["t"] ?? .null)
        default:
            return .unknown
        }
    }

    /// The arguments for a viewer's tool call, made safe as the relay does for input it passes on:
    /// nil for a tool viewers may not call; otherwise without `input` (a viewer never picks the
    /// HID path, which moves the Mac's real cursor and types into whatever is in front) or
    /// `window`, and with `device` set to the stream the viewer is watching.
    public static func viewerArguments(tool: String, arguments: JSONValue, device: String) -> JSONValue? {
        guard viewerTools.contains(tool) else { return nil }
        var safe = arguments.objectValue ?? [:]
        safe["input"] = nil
        safe["window"] = nil
        safe["device"] = .string(device)
        return .object(safe)
    }

    public static func probeEcho(t: JSONValue) -> JSONValue {
        ["type": "probe", "t": t]
    }
}
