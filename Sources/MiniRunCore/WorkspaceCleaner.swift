import Foundation
import MiniRunKit

extension ToolRegistry {
    /// Folders in use by a sync, build or command, standardized like the checkout paths.
    func busyFolders() async -> Set<String> {
        let held = await checkouts.held
        let commands = await commandFolders.busy
        return Set(held.union(commands).map { WorkspaceInventory.standardized($0) })
    }

    /// Deletes the checkout at `path` (which must be `<workspaceRoot>/<owner>/<name>`) unless a job
    /// is using it. Returns its name, "owner/name@ref".
    @discardableResult
    func deleteCheckout(_ path: String) async throws -> String {
        let root = config.workspaceRoot
        let checkout = try WorkspaceInventory.checkout(path, root: root)
        let name = String(checkout.dropFirst(WorkspaceInventory.standardized(root).count + 1))
        let refusal = ToolError("A job is using \(name). Wait for it to finish or cancel it, then delete it.")
        guard !WorkspaceInventory.isBusy(checkout, busy: await busyFolders()) else { throw refusal }
        // Holding the checkout's lock (the key builds use) keeps a sync from starting mid-delete.
        let deleted: Void? = try await checkouts.withLockIfFree(root + "/" + name) {
            try await Task.detached { try WorkspaceInventory.delete(checkout) }.value
        }
        guard deleted != nil else { throw refusal }
        return name
    }

    /// Every 10 minutes (and soon after starting): deletes checkouts unused for
    /// `workspaceCleanupDays`, then, while free disk is under `minFreeDiskGB`, the least recently
    /// used ones (see `WorkspaceCleanup`). Runs until cancelled; re-reads the settings each time.
    public func cleanUpWorkspaces(log: @escaping @Sendable (String) -> Void) async {
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        while !Task.isCancelled {
            await cleanUpWorkspacesOnce(log: log)
            try? await Task.sleep(nanoseconds: 600_000_000_000)
        }
    }

    /// One cleanup pass. `sparing` is a checkout about to be made or used, which is never deleted.
    func cleanUpWorkspacesOnce(sparing: String? = nil, log: @Sendable (String) -> Void) async {
        let config = self.config
        let root = config.workspaceRoot
        let lowBefore = WorkspaceCleanup.isLow(freeBytes: WorkspaceInventory.freeBytes(at: root), minFreeGB: config.minFreeDiskGB)
        guard config.workspaceCleanupDays > 0 || lowBefore else { return }
        let busy = await busyFolders()
        let spared = sparing.map { WorkspaceInventory.standardized($0) }
        let list = await Task.detached { WorkspaceInventory.list(root: root, busy: busy, sizes: false) }.value
            .filter { $0.path != spared }

        // A checkout that turned busy, or is already gone, is left for the next pass.
        var deleted: [String] = []
        let expired = WorkspaceCleanup.expired(list, olderThanDays: config.workspaceCleanupDays)
        for info in expired {
            if let name = try? await deleteCheckout(info.path) { deleted.append(name) }
        }
        if !deleted.isEmpty {
            log("Deleted \(deleted.count) checkout\(deleted.count == 1 ? "" : "s") nobody used for \(config.workspaceCleanupDays) days: \(deleted.joined(separator: ", "))")
        }

        let expiredPaths = Set(expired.map(\.path))
        var freed: [String] = []
        for info in WorkspaceCleanup.spare(list) where !expiredPaths.contains(info.path) {
            let free = WorkspaceInventory.freeBytes(at: root)
            guard WorkspaceCleanup.isLow(freeBytes: free, minFreeGB: config.minFreeDiskGB) else { break }
            if let name = try? await deleteCheckout(info.path) { freed.append(name) }
        }
        if !freed.isEmpty {
            let free = WorkspaceInventory.freeBytes(at: root).map { WorkspaceInventory.formatSize($0) } ?? "unknown"
            log("Free disk was under \(config.minFreeDiskGB) GB: deleted the \(freed.count) least recently used checkout\(freed.count == 1 ? "" : "s") (\(freed.joined(separator: ", "))). Free now: \(free)")
        }
        if lowBefore, WorkspaceCleanup.isLow(freeBytes: WorkspaceInventory.freeBytes(at: root), minFreeGB: config.minFreeDiskGB) {
            log("Free disk is still under \(config.minFreeDiskGB) GB with no unused checkouts left to delete.")
        }
        if !deleted.isEmpty || !freed.isEmpty { await Workspace.pruneWorktrees(root: root) }
        await deleteOrphanedDerivedData(root: root, log: log)
    }

    /// Deletes Xcode's global DerivedData folders for checkouts that are gone (see
    /// `XcodeFiles.orphanedDerivedData`): builds use the checkout's own `.minirun/DerivedData`, but
    /// other xcodebuild calls (and Xcode itself) may have made one there too.
    func deleteOrphanedDerivedData(root: String, log: @Sendable (String) -> Void) async {
        let orphans = await Task.detached { XcodeFiles.orphanedDerivedData(workspaceRoot: root) }.value
        guard !orphans.isEmpty else { return }
        let deleted = await Task.detached { orphans.filter { (try? FileManager.default.removeItem(atPath: $0)) != nil } }.value
        if !deleted.isEmpty {
            log("Deleted \(deleted.count) of Xcode's DerivedData folder\(deleted.count == 1 ? "" : "s") for checkouts that are gone")
        }
    }
}
