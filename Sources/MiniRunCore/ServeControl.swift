import Foundation
import MiniRunKit
import MiniRunSim

/// What `minirun serve` does for each control socket command (see `ControlProtocol`). The menu
/// bar app and `minirun status`/`reload`/`doctor` come through here.
struct ServeControl: ControlCommands {
    let registry: ToolRegistry
    let client: RelayClient
    let startedAt: Date
    let log: @Sendable (String) -> Void

    func status() async -> ServeStatus {
        let local = await registry.status()
        var relay = client.relayStatus
        relay.viewerURL = registry.config.viewerURL(device: nil)
        let macApps = await registry.macAppStatus()
        let macPermissions = await registry.macPermissionReport()
        return ServeStatus(
            version: MiniRun.version, pid: ProcessInfo.processInfo.processIdentifier, startedAt: startedAt,
            relay: relay, simulators: local.simulators, simulatorError: local.simulatorError, jobs: local.jobs,
            media: await registry.media.summary(), macApps: macApps, macPermissions: macPermissions
        )
    }

    func reloadConfig() async throws -> ConfigReload {
        let reload = try registry.liveConfig.reload()
        log("Reloaded settings: \(reload.summary)")
        return reload
    }

    func shutdownSimulator(udid: String) async throws -> String {
        let sim = try await registry.device(ToolArguments(["device": .string(udid)]), boot: false)
        let message = try await registry.shutDownSimulator(sim)
        log("\(message) (from the control socket)")
        return message
    }

    func releaseSimulator(udid: String) async throws -> String {
        let (all, claims) = try await registry.simulators()
        guard let sim = all.first(where: { $0.udid.caseInsensitiveCompare(udid) == .orderedSame }) else {
            throw ToolError("No simulator with UDID \(udid).")
        }
        guard let label = claims[sim.udid]?.label else { return "\(sim.name) isn't reserved." }
        await registry.recordings.halt(sim.udid, reason: "the simulator's reservation was released")
        await registry.claims.unreserve(sim.udid)
        log("Released \(sim.name) (\(sim.udid)) from \(label) (from the control socket)")
        return "Released \(sim.name) from \(label). It stays booted for whoever needs one next."
    }

    func cancelJob(id: String) async throws -> String {
        let job = try await registry.jobs.cancel(id)
        log("Cancelled \(job.id) \(job.title) (from the control socket)")
        return "Cancelled \(job.title)."
    }

    func workspaces() async throws -> [WorkspaceInfo] {
        let root = registry.config.workspaceRoot
        let busy = await busyFolders()
        // Adding up sizes reads every file, so keep it off the shared thread pool.
        return await Task.detached { WorkspaceInventory.list(root: root, busy: busy) }.value
    }

    func deleteWorkspace(path: String) async throws -> String {
        let root = registry.config.workspaceRoot
        let checkout = try WorkspaceInventory.checkout(path, root: root)
        let name = String(checkout.dropFirst(WorkspaceInventory.standardized(root).count + 1))
        let refusal = ToolError("A job is using \(name). Wait for it to finish or cancel it, then delete it.")
        guard !WorkspaceInventory.isBusy(checkout, busy: await busyFolders()) else { throw refusal }
        // Holding the checkout's lock (the key builds use) keeps a sync from starting mid-delete.
        let deleted: Void? = try await registry.checkouts.withLockIfFree(root + "/" + name) {
            try await Task.detached { try WorkspaceInventory.delete(checkout) }.value
        }
        guard deleted != nil else { throw refusal }
        log("Deleted the checkout \(checkout) (from the control socket)")
        return "Deleted \(name)."
    }

    func listMedia() async throws -> [MediaItem] {
        await registry.media.list()
    }

    func deleteMedia(id: String) async throws -> String {
        guard let item = await registry.media.item(id) else { throw ToolError("Nothing shared has id \(id); it may have expired.") }
        try await MediaUploader(config: registry.config).delete(id: id)
        await registry.media.remove(id)
        log("Deleted shared \(item.kind.rawValue) \(id) (from the control socket)")
        return "Deleted the \(item.kind.rawValue)" + (item.label.map { " shared for \($0)" } ?? "") + ". GitHub may show a cached copy for a while."
    }

    func deleteAllMedia() async throws -> String {
        let items = await registry.media.list()
        guard !items.isEmpty else { return "Nothing is shared." }
        let uploader = try MediaUploader(config: registry.config)
        var deleted = 0
        var failure: Error?
        for item in items {
            do {
                try await uploader.delete(id: item.id)
                await registry.media.remove(item.id)
                deleted += 1
            } catch {
                failure = error
            }
        }
        log("Deleted \(deleted) of \(items.count) shared items (from the control socket)")
        if let failure { throw ToolError("Deleted \(deleted) of \(items.count). \(failure.localizedDescription)") }
        return "Deleted \(deleted) shared item\(deleted == 1 ? "" : "s"). GitHub may show cached copies for a while."
    }

    func stopRecording(udid: String) async throws -> String {
        guard await registry.recordings.halt(udid, reason: "it was stopped from the menu bar") else {
            throw ToolError("That simulator isn't recording.")
        }
        log("Stopped the recording on \(udid) (from the control socket)")
        return "Stopped the recording. Claude's stop_recording call still gets the video."
    }

    func doctor() async -> [DoctorCheck] {
        await registry.doctorChecks(serveStatus: { await self.status() })
    }

    func requestMacPermissions() async throws -> String {
        let message = try await registry.requestMacPermissions()
        log("Asked macOS for Screen Recording and Accessibility (from the control socket)")
        return message
    }

    func quitMacApp(id: String) async throws -> String {
        let message = try await registry.quitMacApp(id: id)
        log("\(message) (from the control socket)")
        return message
    }

    func activateMacApp(id: String) async throws -> String {
        try await registry.activateMacApp(id: id)
    }

    /// Folders in use by a sync, build or command, standardized like the checkout paths.
    private func busyFolders() async -> Set<String> {
        let held = await registry.checkouts.held
        let commands = await registry.commandFolders.busy
        return Set(held.union(commands).map { WorkspaceInventory.standardized($0) })
    }
}
