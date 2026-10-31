import Foundation

/// Messages between the Mac (`minirun serve`) and the Cloudflare relay (Durable Object).
///
/// Text frames carry JSON objects with a `type` field. Binary frames carry video:
/// `[kind: UInt8][sequence: UInt32 big-endian][payload]`. Kind 1 is a JPEG frame of the default
/// stream; kind 2 is a JPEG frame of a named stream, with `[keyLength: UInt8][key: UTF-8]` before
/// the JPEG. Kind 3 is an H.264 access unit of a named stream: `[keyLength][key][flags: UInt8]`
/// then Annex B NAL units, where flags bit 0 marks a keyframe (which starts with SPS and PPS).
/// A stream's key is the simulator UDID viewers asked for, or "" for "whichever is booted".
public enum RelayProtocol {
    /// 4 added live touches (`touch` messages). 5 added Mac app streams: picker entries and
    /// `screen` messages with `kind: "mac"`, keyed by the Mac app id.
    public static let version = 5

    public enum FrameKind: UInt8, Sendable {
        case jpeg = 1
        case keyedJPEG = 2
        case keyedH264 = 3
    }

    public enum Codec: String, Sendable {
        case jpeg
        case h264
    }

    /// One stream the relay wants, because at least one viewer is watching it.
    public struct StreamRequest: Equatable, Sendable {
        public let key: String
        public let fps: Int
        public let quality: Int
        public let scale: Double
        /// H.264 when every viewer of the stream can decode it, otherwise JPEG.
        public let codec: Codec

        public init(key: String, fps: Int, quality: Int, scale: Double, codec: Codec = .jpeg) {
            self.key = key
            self.fps = min(30, max(1, fps))
            self.quality = min(95, max(10, quality))
            self.scale = min(1.0, max(0.2, scale))
            self.codec = codec
        }

        init(key: String, json: JSONValue) {
            self.init(
                key: key, fps: json["fps"]?.intValue ?? 12, quality: json["quality"]?.intValue ?? 60, scale: json["scale"]?.doubleValue ?? 0.5,
                codec: json["codec"]?.stringValue.flatMap(Codec.init(rawValue:)) ?? .jpeg
            )
        }
    }

    // MARK: Mac -> relay

    /// `instance` is random per run of `minirun serve`, so the relay can tell a reconnect (which
    /// still has the calls in flight) from a restart (which lost them).
    public static func hello(host: [String: JSONValue], tools: [ToolDefinition], instance: String) -> JSONValue {
        [
            "type": "hello",
            "version": JSONValue(version),
            "instance": .string(instance),
            "host": .object(host),
            "tools": .array(tools.map(\.json)),
        ]
    }

    public static func result(id: String, result: ToolResult) -> JSONValue {
        ["type": "result", "id": .string(id), "result": result.json]
    }

    /// `kind` is "mac" for a Mac app's window, nil for a simulator.
    public static func screen(key: String = "", udid: String, name: String, kind: String? = nil, pointWidth: Double, pointHeight: Double, pixelWidth: Int, pixelHeight: Int) -> JSONValue {
        var message: [String: JSONValue] = [
            "type": "screen",
            "key": .string(key),
            "udid": .string(udid),
            "name": .string(name),
            "pointWidth": .number(pointWidth),
            "pointHeight": .number(pointHeight),
            "pixelWidth": JSONValue(pixelWidth),
            "pixelHeight": JSONValue(pixelHeight),
        ]
        if let kind { message["kind"] = .string(kind) }
        return .object(message)
    }

    public static func streamStatus(_ status: String, key: String = "", message: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["type": "stream_status", "status": .string(status), "key": .string(key)]
        if let message { object["message"] = .string(message) }
        return .object(object)
    }

    /// The booted simulators, for the viewer's simulator picker.
    public static func simulators(_ devices: [JSONValue]) -> JSONValue {
        ["type": "simulators", "devices": .array(devices)]
    }

    public static func encodeFrame(kind: FrameKind, sequence: UInt32, payload: Data) -> Data {
        var data = Data(capacity: payload.count + 5)
        data.append(kind.rawValue)
        withUnsafeBytes(of: sequence.bigEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    /// A JPEG frame for the stream `key` (kind 2).
    public static func encodeFrame(key: String, sequence: UInt32, payload: Data) -> Data {
        encodeKeyedFrame(.keyedJPEG, key: key, sequence: sequence, header: [], payload: payload)
    }

    /// An H.264 access unit (Annex B) for the stream `key` (kind 3).
    public static func encodeVideoFrame(key: String, sequence: UInt32, keyframe: Bool, payload: Data) -> Data {
        encodeKeyedFrame(.keyedH264, key: key, sequence: sequence, header: [keyframe ? 1 : 0], payload: payload)
    }

    private static func encodeKeyedFrame(_ kind: FrameKind, key: String, sequence: UInt32, header: [UInt8], payload: Data) -> Data {
        let keyBytes = Array(key.utf8.prefix(255))
        var data = Data(capacity: payload.count + 6 + keyBytes.count + header.count)
        data.append(kind.rawValue)
        withUnsafeBytes(of: sequence.bigEndian) { data.append(contentsOf: $0) }
        data.append(UInt8(keyBytes.count))
        data.append(contentsOf: keyBytes)
        data.append(contentsOf: header)
        data.append(payload)
        return data
    }

    /// Splits a binary frame. For kind 3 the payload still starts with the flags byte.
    public static func decodeFrame(_ data: Data) -> (kind: UInt8, sequence: UInt32, key: String, payload: Data)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 5 else { return nil }
        let sequence = (UInt32(bytes[1]) << 24) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 8) | UInt32(bytes[4])
        guard bytes[0] == FrameKind.keyedJPEG.rawValue || bytes[0] == FrameKind.keyedH264.rawValue else { return (bytes[0], sequence, "", Data(bytes[5...])) }
        guard bytes.count >= 6, bytes.count >= 6 + Int(bytes[5]) else { return nil }
        let end = 6 + Int(bytes[5])
        return (bytes[0], sequence, String(decoding: bytes[6..<end], as: UTF8.self), Data(bytes[end...]))
    }

    // MARK: relay -> Mac

    public enum Incoming: Equatable, Sendable {
        /// Run a tool. `id` is nil for fire-and-forget input from the viewer.
        case call(id: String?, tool: String, arguments: JSONValue)
        /// The complete set of streams viewers are watching now; empty means stop streaming.
        case streams([StreamRequest])
        /// A viewer of stream `key` finished rendering the frame with this sequence number.
        case ack(sequence: UInt32, key: String)
        /// A viewer of stream `key` needs a keyframe to start (or resume) decoding H.264.
        case keyframe(key: String)
        /// After a reconnect: calls the relay is still waiting on. Answer the finished ones.
        case pending(ids: [String])
        /// One step of a live touch from a viewer, in points: phase is "down", "move" or "up".
        case touch(udid: String, phase: String, x: Double, y: Double)
        /// The relay's answer to `hello`: the Worker's MINIRUN_BUNDLE (the hash of the code it runs),
        /// or nil for a Worker deployed with wrangler. Older Workers don't send it.
        case welcome(bundle: String?)
        case unknown(String)
    }

    public static func decode(_ text: String) -> Incoming {
        guard let message = try? JSONValue.parse(text), let type = message["type"]?.stringValue else {
            return .unknown(text)
        }
        switch type {
        case "call":
            guard let tool = message["tool"]?.stringValue else { return .unknown(text) }
            return .call(id: message["id"]?.stringValue, tool: tool, arguments: message["arguments"] ?? [:])
        case "stream":
            switch message["action"]?.stringValue {
            case "stop":
                return .streams([])
            case "set":
                let list = message["streams"]?.arrayValue ?? []
                return .streams(list.map { StreamRequest(key: $0["udid"]?.stringValue ?? "", json: $0) })
            default:
                // Version 1 relays start a single stream.
                return .streams([StreamRequest(key: message["udid"]?.stringValue ?? "", json: message)])
            }
        case "ack":
            return .ack(sequence: UInt32(clamping: message["seq"]?.intValue ?? 0), key: message["key"]?.stringValue ?? "")
        case "keyframe":
            return .keyframe(key: message["key"]?.stringValue ?? "")
        case "pending":
            return .pending(ids: (message["ids"]?.arrayValue ?? []).compactMap(\.stringValue))
        case "touch":
            guard let udid = message["device"]?.stringValue, let phase = message["phase"]?.stringValue,
                  let x = message["x"]?.doubleValue, let y = message["y"]?.doubleValue else { return .unknown(text) }
            return .touch(udid: udid, phase: phase, x: x, y: y)
        case "welcome":
            return .welcome(bundle: message["bundle"]?.stringValue)
        default:
            return .unknown(text)
        }
    }
}
