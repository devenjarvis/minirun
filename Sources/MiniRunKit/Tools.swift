import Foundation

/// An MCP tool exposed by the Mac. The Worker forwards `tools/list` straight from these definitions.
public struct ToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, properties: [String: JSONValue] = [:], required: [String] = []) {
        self.name = name
        self.description = description
        var schema: [String: JSONValue] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false,
        ]
        if !required.isEmpty { schema["required"] = JSONValue(required) }
        self.inputSchema = .object(schema)
    }

    public var json: JSONValue {
        ["name": .string(name), "description": .string(description), "inputSchema": inputSchema]
    }
}

/// Small helpers for writing JSON Schemas tersely.
public enum Schema {
    public static func string(_ description: String, enum values: [String]? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let values { object["enum"] = JSONValue(values) }
        return .object(object)
    }

    public static func number(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["type": "number", "description": .string(description)]
        if let minimum { object["minimum"] = .number(minimum) }
        if let maximum { object["maximum"] = .number(maximum) }
        return .object(object)
    }

    public static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["type": "integer", "description": .string(description)]
        if let minimum { object["minimum"] = JSONValue(minimum) }
        if let maximum { object["maximum"] = JSONValue(maximum) }
        return .object(object)
    }

    public static func boolean(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }

    public static func stringArray(_ description: String) -> JSONValue {
        ["type": "array", "items": ["type": "string"], "description": .string(description)]
    }
}

/// One item of MCP tool output.
public enum ToolContent: Sendable, Equatable {
    case text(String)
    case image(data: Data, mimeType: String)

    public var json: JSONValue {
        switch self {
        case .text(let text):
            return ["type": "text", "text": .string(text)]
        case .image(let data, let mimeType):
            return ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(mimeType)]
        }
    }
}

public struct ToolResult: Sendable, Equatable {
    public var content: [ToolContent]
    public var isError: Bool

    public init(_ content: [ToolContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ text: String) -> ToolResult { ToolResult([.text(text)]) }

    public static func json(_ value: JSONValue) -> ToolResult { ToolResult([.text(value.encodedString(pretty: true))]) }

    public static func error(_ message: String) -> ToolResult { ToolResult([.text(message)], isError: true) }

    public var json: JSONValue {
        ["content": .array(content.map(\.json)), "isError": .bool(isError)]
    }
}

/// An error a tool handler throws to report a problem in plain words back to Claude.
public struct ToolError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Typed access to tool arguments with readable errors.
public struct ToolArguments: Sendable {
    public let raw: [String: JSONValue]

    public init(_ value: JSONValue?) {
        raw = value?.objectValue ?? [:]
    }

    public func string(_ key: String) -> String? {
        guard let value = raw[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    public func requireString(_ key: String) throws -> String {
        guard let value = string(key) else { throw ToolError("Missing required argument `\(key)`.") }
        return value
    }

    /// Raw string, preserving whitespace (for text entry).
    public func rawString(_ key: String) -> String? { raw[key]?.stringValue }

    public func double(_ key: String) -> Double? { raw[key]?.doubleValue }

    public func requireDouble(_ key: String) throws -> Double {
        guard let value = double(key), value.isFinite else { throw ToolError("Missing or invalid number `\(key)`.") }
        return value
    }

    public func int(_ key: String) -> Int? { raw[key]?.intValue }

    public func bool(_ key: String) -> Bool? { raw[key]?.boolValue }

    public func strings(_ key: String) -> [String] {
        if let array = raw[key]?.arrayValue { return array.compactMap(\.stringValue) }
        if let single = string(key) { return [single] }
        return []
    }
}
