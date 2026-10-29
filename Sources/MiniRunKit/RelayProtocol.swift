import Foundation

/// Messages between the Mac (`minirun serve`) and the Cloudflare relay (Durable Object).
///
/// Text frames carry JSON objects with a `type` field. Binary frames carry video:
/// `[kind: UInt8][sequence: UInt32 big-endian][payload]`, where kind 1 is a JPEG frame.
public enum RelayProtocol {
    public static let version = 1

    public enum FrameKind: UInt8, Sendable {
        case jpeg = 1
    }

    // MARK: Mac -> relay

    public static func hello(host: [String: JSONValue], tools: [ToolDefinition]) -> JSONValue {
        [
            "type": "hello",
            "version": JSONValue(version),
            "host": .object(host),
            "tools": .array(tools.map(\.json)),
        ]
    }

    public static func result(id: String, result: ToolResult) -> JSONValue {
        ["type": "result", "id": .string(id), "result": result.json]
    }

    public static func screen(udid: String, name: String, pointWidth: Double, pointHeight: Double, pixelWidth: Int, pixelHeight: Int) -> JSONValue {
        [
            "type": "screen",
            "udid": .string(udid),
            "name": .string(name),
            "pointWidth": .number(pointWidth),
            "pointHeight": .number(pointHeight),
            "pixelWidth": JSONValue(pixelWidth),
            "pixelHeight": JSONValue(pixelHeight),
        ]
    }

    public static func streamStatus(_ status: String, message: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["type": "stream_status", "status": .string(status)]
        if let message { object["message"] = .string(message) }
        return .object(object)
    }

    public static func encodeFrame(kind: FrameKind, sequence: UInt32, payload: Data) -> Data {
        var data = Data(capacity: payload.count + 5)
        data.append(kind.rawValue)
        withUnsafeBytes(of: sequence.bigEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    public static func decodeFrame(_ data: Data) -> (kind: UInt8, sequence: UInt32, payload: Data)? {
        guard data.count >= 5 else { return nil }
        let bytes = [UInt8](data.prefix(5))
        let sequence = (UInt32(bytes[1]) << 24) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 8) | UInt32(bytes[4])
        return (bytes[0], sequence, data.dropFirst(5))
    }

    // MARK: relay -> Mac

    public enum Incoming: Equatable, Sendable {
        /// Run a tool. `id` is nil for fire-and-forget input from the viewer.
        case call(id: String?, tool: String, arguments: JSONValue)
        case streamStart(udid: String?, fps: Int, quality: Int, scale: Double)
        case streamStop
        /// A viewer finished rendering the frame with this sequence number.
        case ack(sequence: UInt32)
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
            if message["action"]?.stringValue == "stop" { return .streamStop }
            let fps = min(30, max(1, message["fps"]?.intValue ?? 12))
            let quality = min(95, max(10, message["quality"]?.intValue ?? 60))
            let scale = min(1.0, max(0.2, message["scale"]?.doubleValue ?? 0.5))
            return .streamStart(udid: message["udid"]?.stringValue, fps: fps, quality: quality, scale: scale)
        case "ack":
            return .ack(sequence: UInt32(clamping: message["seq"]?.intValue ?? 0))
        default:
            return .unknown(text)
        }
    }
}
