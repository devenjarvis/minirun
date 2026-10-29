import Foundation
import MiniRunKit
import MiniRunSim

/// All MCP tools minirun exposes, with their handlers.
public final class ToolRegistry: @unchecked Sendable {
    public typealias Handler = @Sendable (ToolArguments) async throws -> ToolResult

    public struct Tool: Sendable {
        public let definition: ToolDefinition
        public let handler: Handler
    }

    public let config: MiniRunConfig
    public let jobs = JobStore()
    let geometry = ScreenGeometryCache()
    private(set) var tools: [String: Tool] = [:]
    private var order: [String] = []
    let logsDirectory: URL

    public init(config: MiniRunConfig) {
        self.config = config
        logsDirectory = URL(fileURLWithPath: MiniRunConfig.home + "/Library/Logs/minirun/jobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        registerSimulatorTools()
        registerAppTools()
        registerCodeTools()
    }

    public var definitions: [ToolDefinition] { order.compactMap { tools[$0]?.definition } }

    public func call(_ name: String, arguments: JSONValue) async -> ToolResult {
        guard let tool = tools[name] else { return .error("Unknown tool \(name).") }
        do {
            return try await tool.handler(ToolArguments(arguments))
        } catch {
            return .error(error.localizedDescription)
        }
    }

    func register(_ definition: ToolDefinition, _ handler: @escaping Handler) {
        tools[definition.name] = Tool(definition: definition, handler: handler)
        order.append(definition.name)
    }

    func device(_ args: ToolArguments, boot: Bool = true) async throws -> XcodeParsing.SimDevice {
        try await Simctl.resolve(args.string("device"), config: config, boot: boot)
    }

    func newLogURL(_ label: String) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safe = label.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return logsDirectory.appendingPathComponent("\(stamp)-\(String(safe)).log")
    }

    /// Runs `work` as a job and waits `wait_seconds` (default 45) for it before returning.
    func runAsJob(_ args: ToolArguments, title: String, log: URL?, _ work: @escaping @Sendable () async throws -> ToolResult) async -> ToolResult {
        let id = await jobs.start(title: title, logPath: log?.path, work)
        let wait = min(600, max(0, args.double("wait_seconds") ?? 45))
        return await jobs.report(id, waited: wait)
    }

    /// A screenshot sized so image pixels equal screen points, so coordinates can be used directly.
    func screenshotContent(udid: String, scale: Double? = nil, quality: Int = 70) async throws -> [ToolContent] {
        let size = await geometry.pointSize(udid: udid)
        let shot: (data: Data, width: Int, height: Int)
        if let scale {
            shot = try await SimulatorDriver.shared.screenshotJPEG(udid: udid, scale: scale, quality: quality)
        } else if let size {
            shot = try await SimulatorDriver.shared.screenshotJPEG(udid: udid, targetWidth: Int(size.width.rounded()), quality: quality)
        } else {
            shot = try await SimulatorDriver.shared.screenshotJPEG(udid: udid, scale: 0.4, quality: quality)
        }
        var note = "Screenshot \(shot.width)x\(shot.height)px."
        if let size {
            note += " Screen is \(Int(size.width))x\(Int(size.height)) points"
            note += abs(Double(shot.width) - size.width) < 2 ? " — image pixels equal points, so use them directly for tap/swipe." : "."
        }
        return [.image(data: shot.data, mimeType: "image/jpeg"), .text(note)]
    }
}

/// Remembers each simulator's screen size in points (from the accessibility root) and pixels.
actor ScreenGeometryCache {
    private var points: [String: (width: Double, height: Double)] = [:]

    func pointSize(udid: String) async -> (width: Double, height: Double)? {
        if let cached = points[udid] { return cached }
        guard let json = try? await SimulatorDriver.shared.describeUI(udid: udid),
              let size = XcodeParsing.screenPointSize(fromAccessibility: json) else { return nil }
        points[udid] = size
        return size
    }

    func invalidate(udid: String) {
        points[udid] = nil
    }
}
