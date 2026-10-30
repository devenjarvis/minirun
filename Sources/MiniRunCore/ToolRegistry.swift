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
    /// One simulator pick at a time, so two sessions can't both take the same one. Boots run
    /// outside it (see `SimulatorBoots`).
    let allocation = KeyedLock()
    let boots = SimulatorBoots()
    /// Simulators with a job running or a viewer watching, which idle shutdown leaves alone.
    let activity = SimulatorActivity()
    /// The simulators from the last `simctl list`, so a call naming a booted one by UDID can skip it.
    let knownDevices = KnownDevices()
    /// One sync/build at a time per checkout.
    let checkouts = KeyedLock()
    /// Makes a template after the first copy of a model, so later copies are clones. Only
    /// `minirun serve` does: a one-shot `minirun call` would exit partway through.
    public var makesTemplates = false
    let templateBuilds = TemplateBuilds()
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
        // An exact UDID that's booted (not still booting) needs no picking: skip simctl, which
        // costs ~100ms on every tap from the live view.
        if let query = args.string("device"), let known = await knownDevices[query],
           await SimulatorDriver.shared.isBooted(udid: known.udid), await boots.task(known.udid) == nil {
            await claims.touch(known.udid)
            return known.booted
        }
        let (all, current) = try await simulators()
        let choice = SimulatorPicker.target(
            query: args.string("device"), workspace: nil, devices: all,
            claims: current, preferredName: config.defaultDevice, maxBooted: config.maxBootedSimulators
        )
        let device = try await realize(choice, boot: boot).ready()
        await claims.touch(device.udid)
        return device
    }

    /// The simulator for a build of `workspace` ("owner/app@ref"), reserved for it. Uses the one
    /// already reserved for this workspace, an unreserved booted one, or boots a separate one.
    /// The pick and reservation happen under the allocation lock; waiting for a boot doesn't.
    func workspaceDevice(_ args: ToolArguments, workspace: String) async throws -> (device: XcodeParsing.SimDevice, note: String?) {
        let allocated = try await allocation.withLock("simulators") { () async throws -> Allocation in
            let (all, current) = try await simulators()
            let choice = SimulatorPicker.target(
                query: args.string("device"), workspace: workspace, devices: all,
                claims: current, preferredName: config.defaultDevice, maxBooted: config.maxBootedSimulators
            )
            var allocated = try await realize(choice, boot: true)
            if let previous = await claims.reserve(allocated.device.udid, for: workspace) {
                allocated.note = [allocated.note, "It was reserved for \(previous); it's now reserved for \(workspace)."].compactMap { $0 }.joined(separator: " ")
            }
            return allocated
        }
        let device = try await allocated.ready()
        return (device, allocated.note)
    }

    /// The available simulators and their reservations. A simulator that's still booting shows as
    /// booted, so picks count it as running and its reservation isn't dropped mid-boot.
    func simulators() async throws -> (devices: [XcodeParsing.SimDevice], claims: [String: SimulatorClaim]) {
        // Read the boots first: one that finishes in between then shows as booted either way.
        let booting = await boots.booting
        let listed = try await Simctl.devices().map { booting.contains($0.udid) ? $0.booted : $0 }
        await knownDevices.update(listed)
        let all = listed.filter { !SimulatorPicker.isTemplate($0) }
        let current = await claims.snapshot(booted: Set(all.filter(\.isBooted).map(\.udid)))
        return (all, current)
    }

    /// A simulator handed out by a pick, possibly still booting.
    struct Allocation {
        let device: XcodeParsing.SimDevice
        var note: String?
        let boot: Task<Void, Error>?

        /// Waits for the boot, if there is one, and returns the simulator.
        func ready() async throws -> XcodeParsing.SimDevice {
            try await boot?.value
            return device
        }
    }

    /// Carries out a picker decision: creates the simulator if needed and starts booting it. It
    /// doesn't wait for the boot, so callers can let go of the allocation lock first; call `ready()`
    /// on the result before using the simulator.
    func realize(_ choice: SimulatorPicker.Choice, boot: Bool) async throws -> Allocation {
        switch choice {
        case .failure(let message):
            throw ToolError(message)
        case .use(let device, let note):
            if let running = await boots.task(device.udid) { return Allocation(device: device, note: note, boot: running) }
            guard boot, !device.isBooted else { return Allocation(device: device, note: note, boot: nil) }
            let started = await startBoot(device.udid)
            return Allocation(device: device.booted, note: note, boot: started)
        case .create(let name, let like, let note):
            let udid: String
            var created = "Created \(name)"
            let template = SimulatorPicker.template(for: like, in: await knownDevices.all)
            if let template {
                udid = try await Simctl.clone(template, name: name)
                created += " from the template \(template.name)"
            } else {
                udid = try await Simctl.create(name: name, like: like)
            }
            let device = XcodeParsing.SimDevice(udid: udid, name: name, state: "Booted", runtime: like.runtime, isAvailable: true, deviceType: like.deviceType)
            let fullNote = [note, "\(created) because every \(SimulatorPicker.baseName(like.name)) was in use."].compactMap { $0 }.joined(separator: " ")
            let started = await startBoot(udid)
            if makesTemplates, template == nil {
                // After this copy's first boot, so the two first boots don't compete for the disk.
                Task { [self] in
                    guard (try? await started.value) != nil else { return }
                    await makeTemplate(like: like)
                }
            }
            return Allocation(device: device, note: fullNote, boot: started)
        }
    }

    /// Makes the template for `like`'s model and runtime (see `SimulatorPicker.templateMarker`): a new
    /// simulator, booted once and left to settle for two minutes so its first-run work is saved,
    /// then shut down. It's named as a template only once that's done. Waits for other boots to
    /// finish first, skips if minirun is at `maxBootedSimulators`, and makes one at a time per model.
    func makeTemplate(like: XcodeParsing.SimDevice) async {
        guard let type = like.deviceType else { return }
        let key = type + " " + like.runtime
        guard await templateBuilds.begin(key) else { return }
        defer { Task { await templateBuilds.end(key) } }
        let name = SimulatorPicker.templateName(for: like)
        do {
            // Two first boots at once stall each other (and timed out simctl on GitHub's runners).
            var waits = 0
            while !(await boots.booting.isEmpty) {
                waits += 1
                guard waits <= 180 else { return }
                try await Task.sleep(nanoseconds: 10_000_000_000)
            }
            let listed = try await Simctl.devices()
            let same = listed.filter { SimulatorPicker.isTemplate($0) && $0.deviceType == type && $0.runtime == like.runtime }
            if same.contains(where: { $0.name.hasSuffix(SimulatorPicker.templateMarker) }) { return }
            // Left over from a build that was interrupted: never cloned, so start again.
            for leftover in same {
                try? await Simctl.shutdown(leftover.udid)
                try await Simctl.delete(leftover.udid)
            }
            guard listed.filter({ $0.isBooted }).count < config.maxBootedSimulators else { return }
            Server.log("Making \(name) so later copies of \(SimulatorPicker.baseName(like.name)) boot in about a minute")
            let udid = try await Simctl.create(name: SimulatorPicker.baseName(like.name) + SimulatorPicker.buildingTemplateMarker, like: like)
            do {
                try await Simctl.boot(udid, show: false)
                try await Task.sleep(nanoseconds: 120_000_000_000)
                try await Simctl.shutdown(udid)
                try await Simctl.rename(udid, to: name)
            } catch {
                try? await Simctl.shutdown(udid)
                try? await Simctl.delete(udid)
                throw error
            }
            Server.log("Made \(name) (\(udid))")
        } catch {
            Server.log("Couldn't make \(name): \(error.localizedDescription)")
        }
    }

    private func startBoot(_ udid: String) async -> Task<Void, Error> {
        await boots.start(udid) { [self] in
            try await Simctl.boot(udid)
            await SimulatorDriver.shared.reset(udid: udid)
            await geometry.invalidate(udid: udid)
        }
    }

    /// Runs `body` with the simulator marked busy, so idle shutdown leaves it alone however long a
    /// build or test takes, then counts it as just used.
    func whileUsing<T>(_ udid: String, _ body: () async throws -> T) async throws -> T {
        await activity.begin(udid)
        do {
            let value = try await body()
            await activity.end(udid)
            await claims.touch(udid)
            return value
        } catch {
            await activity.end(udid)
            await claims.touch(udid)
            throw error
        }
    }

    /// Checks every minute for simulators nobody has used in `idleShutdownMinutes` and shuts them
    /// down (see `IdleSimulators.plan`), and deletes copies unused for `deleteCopiesAfterDays`.
    /// Runs until cancelled; returns at once if both are turned off.
    public func shutDownIdleSimulators(log: @escaping @Sendable (String) -> Void) async {
        guard config.idleShutdownMinutes > 0 || config.deleteCopiesAfterDays > 0 else { return }
        if config.idleShutdownMinutes > 0 { log("Shutting down simulators after \(config.idleShutdownMinutes) idle minutes") }
        if config.deleteCopiesAfterDays > 0 { log("Deleting copies of simulators not booted for \(config.deleteCopiesAfterDays) days") }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            do {
                try await shutDownIdleSimulatorsOnce(log: log)
            } catch {
                log("Idle simulator check failed: \(error.localizedDescription)")
            }
        }
    }

    func shutDownIdleSimulatorsOnce(log: @Sendable (String) -> Void) async throws {
        let minutes = config.idleShutdownMinutes
        // Under the allocation lock so a pick can't hand out a simulator while it's shutting down.
        try await allocation.withLock("simulators") { () async throws -> Void in
            let busy = (await activity.busy).union(await boots.booting)
            let (all, current) = try await simulators()
            let booted = all.filter(\.isBooted)
            let names = Dictionary(booted.map { ($0.udid, $0.name) }, uniquingKeysWith: { a, _ in a })
            for action in IdleSimulators.plan(booted: booted, claims: current, busy: busy, idleAfter: Double(minutes) * 60) {
                switch action {
                case .unreserve(let udid):
                    await claims.unreserve(udid)
                    log("Released \(names[udid] ?? udid) (\(udid)): not used for \(minutes) min. Keeping it booted as a spare.")
                case .shutdown(let udid):
                    do {
                        try await Simctl.shutdown(udid)
                    } catch {
                        log("Couldn't shut down idle simulator \(udid): \(error.localizedDescription)")
                        continue
                    }
                    await claims.release(udid)
                    await SimulatorDriver.shared.reset(udid: udid)
                    await geometry.invalidate(udid: udid)
                    log("Shut down \(names[udid] ?? udid) (\(udid)): not used for \(minutes) min.")
                }
            }
            for copy in StaleCopies.plan(devices: all, olderThan: Double(config.deleteCopiesAfterDays) * 86400) {
                do {
                    try await Simctl.delete(copy.udid)
                    log("Deleted \(copy.name) (\(copy.udid)): not booted for \(config.deleteCopiesAfterDays) days.")
                } catch {
                    log("Couldn't delete \(copy.name) (\(copy.udid)): \(error.localizedDescription)")
                }
            }
        }
    }

    /// The booted simulators and recent jobs, for the status snapshot.
    public func status() async -> (simulators: [ServeStatus.Simulator], simulatorError: String?, jobs: [ServeStatus.Job]) {
        let recent = await self.jobs.list().prefix(20).map { ServeStatus.Job($0) }
        let busy = await activity.busy
        let booting = await boots.booting
        do {
            let (all, current) = try await simulators()
            let booted = all.filter(\.isBooted).map { device in
                ServeStatus.Simulator(
                    udid: device.udid, name: device.name, runtime: device.runtimeName,
                    booting: booting.contains(device.udid),
                    reservedFor: current[device.udid]?.label,
                    bundleID: current[device.udid]?.bundleID,
                    lastUsed: current[device.udid]?.updatedAt,
                    busy: busy.contains(device.udid),
                    viewerURL: config.viewerURL(device: device.udid)
                )
            }
            return (booted, nil, recent)
        } catch {
            return ([], error.localizedDescription, recent)
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

/// The templates being made, by model and runtime, so two sessions don't both make one.
actor TemplateBuilds {
    private var running: Set<String> = []

    func begin(_ key: String) -> Bool { running.insert(key).inserted }
    func end(_ key: String) { running.remove(key) }
}

/// The simulators `simctl` listed last, templates included, by UDID.
actor KnownDevices {
    private var devices: [String: XcodeParsing.SimDevice] = [:]
    private(set) var all: [XcodeParsing.SimDevice] = []

    subscript(udid: String) -> XcodeParsing.SimDevice? { devices[udid.uppercased()] }

    func update(_ list: [XcodeParsing.SimDevice]) {
        all = list
        devices = Dictionary(list.map { ($0.udid.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
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
