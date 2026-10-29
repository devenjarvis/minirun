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
    /// Which booted simulator is reserved for which repo and branch.
    let claims = SimulatorClaimStore(url: SimulatorClaimStore.defaultURL)
    /// One simulator pick (and boot) at a time, so two sessions can't both take the same one.
    let allocation = KeyedLock()
    /// One sync/build at a time per checkout.
    let checkouts = KeyedLock()
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

    /// The simulator a tool call acts on: `device` if given, else the only booted one.
    /// Fails with a list of booted simulators rather than guessing when several are running.
    func device(_ args: ToolArguments, boot: Bool = true) async throws -> XcodeParsing.SimDevice {
        let all = try await Simctl.devices()
        let choice = SimulatorPicker.target(
            query: args.string("device"), workspace: nil, devices: all,
            claims: await claimSnapshot(all), preferredName: config.defaultDevice
        )
        let device = try await realize(choice, boot: boot).device
        await claims.touch(device.udid)
        return device
    }

    /// The simulator for a build of `workspace` ("owner/app@ref"), reserved for it. Uses the one
    /// already reserved for this workspace, an unreserved booted one, or boots a separate one.
    func workspaceDevice(_ args: ToolArguments, workspace: String) async throws -> (device: XcodeParsing.SimDevice, note: String?) {
        try await allocation.withLock("simulators") { () async throws -> (device: XcodeParsing.SimDevice, note: String?) in
            let all = try await Simctl.devices()
            let choice = SimulatorPicker.target(
                query: args.string("device"), workspace: workspace, devices: all,
                claims: await claimSnapshot(all), preferredName: config.defaultDevice
            )
            let (device, realizedNote) = try await realize(choice, boot: true)
            var note = realizedNote
            if let previous = await claims.reserve(device.udid, for: workspace) {
                note = [note, "It was reserved for \(previous); it's now reserved for \(workspace)."].compactMap { $0 }.joined(separator: " ")
            }
            return (device, note)
        }
    }

    func claimSnapshot(_ devices: [XcodeParsing.SimDevice]) async -> [String: SimulatorClaim] {
        await claims.snapshot(booted: Set(devices.filter(\.isBooted).map(\.udid)))
    }

    /// Carries out a picker decision: boots the simulator, or creates a new one first.
    func realize(_ choice: SimulatorPicker.Choice, boot: Bool) async throws -> (device: XcodeParsing.SimDevice, note: String?) {
        switch choice {
        case .failure(let message):
            throw ToolError(message)
        case .use(let device, let note):
            guard boot, !device.isBooted else { return (device, note) }
            try await Simctl.boot(device.udid)
            await SimulatorDriver.shared.reset(udid: device.udid)
            await geometry.invalidate(udid: device.udid)
            return (device.booted, note)
        case .create(let name, let like, let note):
            let udid = try await Simctl.create(name: name, like: like)
            try await Simctl.boot(udid)
            let device = XcodeParsing.SimDevice(udid: udid, name: name, state: "Booted", runtime: like.runtime, isAvailable: true, deviceType: like.deviceType)
            return (device, [note, "Created \(name) because every \(SimulatorPicker.baseName(like.name)) was in use."].compactMap { $0 }.joined(separator: " "))
        }
    }

    /// "UDID … — pass it as device" plus the live view link, for results that hand out a simulator.
    func deviceFooter(_ device: XcodeParsing.SimDevice) -> String {
        var text = "Simulator: \(device.name), UDID \(device.udid). Pass device: \"\(device.udid)\" on later calls so they reach this simulator."
        if let link = config.viewerURL(device: device.udid) { text += "\nLive view of this simulator for the user: \(link)" }
        return text
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
            shot = try await SimulatorDriver.shared.screenshotJPEG(udid: udid, scale: 1.0 / 3.0, quality: quality) // 3x screens: ≈ points
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
