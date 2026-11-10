import Foundation

/// Where each repo + ref is checked out. Every ref gets its own checkout (and its own build
/// products), so two sessions building different branches of one app never share a folder.
public enum WorkspaceNaming {
    /// "owner/app" for the default branch, "owner/app@feature-x" for a ref. Branch names with
    /// characters that aren't safe in a folder name get a short hash so they can't collide.
    public static func directory(slug: String, ref: String?) -> String {
        guard let ref = ref?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty else { return slug }
        var safe = String(ref.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") ? $0 : "-" })
        if safe != ref || safe.hasPrefix(".") { safe += "-" + fnv1a(ref) }
        return slug + "@" + safe
    }

    /// How simulator reservations name a workspace: "owner/app@feature/x", or "owner/app".
    public static func label(slug: String, ref: String?) -> String {
        guard let ref = ref?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty else { return slug }
        return slug + "@" + ref
    }

    /// Under the workspace root. A dot folder, so `WorkspaceInventory` doesn't list it as a checkout.
    public static let mirrorsFolder = ".git-mirrors"

    /// The bare mirror every checkout of a repository is a worktree of:
    /// `<root>/.git-mirrors/<owner>/<name>.git`.
    public static func mirror(root: String, slug: String) -> String {
        var path = root
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path + "/" + mirrorsFolder + "/" + slug + ".git"
    }

    /// A checkout's git folder: `<checkout>/.git` for a clone, or for a worktree, the folder its
    /// `.git` file points to (`gitdir: <mirror>/worktrees/<id>`). `gitFile` is that file's text, nil
    /// when `.git` is a folder.
    public static func gitDirectory(checkout: String, gitFile: String?) -> String {
        guard let gitFile else { return checkout + "/.git" }
        for line in gitFile.split(whereSeparator: \.isNewline) where line.hasPrefix("gitdir:") {
            let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { break }
            return target.hasPrefix("/") ? target : URL(fileURLWithPath: checkout + "/" + target).standardizedFileURL.path
        }
        return checkout + "/.git"
    }

    /// `gitDirectory` read from disk.
    public static func gitDirectory(checkout: String) -> String {
        var isDirectory: ObjCBool = false
        let dotGit = checkout + "/.git"
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory), !isDirectory.boolValue else { return dotGit }
        return gitDirectory(checkout: checkout, gitFile: try? String(contentsOfFile: dotGit, encoding: .utf8))
    }

    static func fnv1a(_ text: String) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return String(format: "%08x", hash)
    }
}

/// Serializes work per key: one build at a time per checkout, one simulator pick at a time.
public final class KeyedLock: Sendable {
    private actor State {
        var held: Set<String> = []
        var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

        func tryAcquire(_ key: String) -> Bool {
            guard !held.contains(key) else { return false }
            held.insert(key)
            return true
        }

        func acquire(_ key: String) async {
            if tryAcquire(key) { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters[key, default: []].append(continuation)
            }
        }

        func release(_ key: String) {
            if var queue = waiters[key], !queue.isEmpty {
                // Hand the lock straight to the next waiter; the key stays held.
                let next = queue.removeFirst()
                waiters[key] = queue.isEmpty ? nil : queue
                next.resume()
            } else {
                held.remove(key)
            }
        }
    }

    private let state = State()

    /// The keys held right now.
    public var held: Set<String> {
        get async { await state.held }
    }

    public init() {}

    /// Runs `body` while holding `key`. `onWait` runs first if someone else holds it.
    public func withLock<T>(_ key: String, onWait: () -> Void = {}, _ body: () async throws -> T) async throws -> T {
        if !(await state.tryAcquire(key)) {
            onWait()
            await state.acquire(key)
        }
        return try await holding(key, body)
    }

    /// Runs `body` while holding `key` if nobody else holds it; returns nil without waiting otherwise.
    public func withLockIfFree<T>(_ key: String, _ body: () async throws -> T) async throws -> T? {
        guard await state.tryAcquire(key) else { return nil }
        return try await holding(key, body)
    }

    private func holding<T>(_ key: String, _ body: () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            await state.release(key)
            return value
        } catch {
            await state.release(key)
            throw error
        }
    }
}

/// A checkout under the workspace root, for the `workspaces` control command.
public struct WorkspaceInfo: Codable, Equatable, Sendable {
    public var path: String
    /// The folder under the root: "owner/app" or "owner/app@ref".
    public var name: String
    public var sizeBytes: Int64
    /// The last sync or build, as far as file times tell.
    public var lastUsed: Date?
    /// A job is using it, so it can't be deleted.
    public var busy: Bool

    public init(path: String, name: String, sizeBytes: Int64, lastUsed: Date?, busy: Bool) {
        self.path = path
        self.name = name
        self.sizeBytes = sizeBytes
        self.lastUsed = lastUsed
        self.busy = busy
    }
}

/// Lists and deletes the checkouts under the workspace root (`<root>/<owner>/<name>[@ref]`).
public enum WorkspaceInventory {
    /// Every checkout, most recently used first. `busy` holds folders jobs are using; a checkout
    /// is busy if one of them is the checkout or inside it. Adding up sizes reads every file, so
    /// `sizes: false` leaves them 0 for callers that only need the dates.
    public static func list(root: String, busy: Set<String> = [], sizes: Bool = true) -> [WorkspaceInfo] {
        let fm = FileManager.default
        let rootPath = standardized(root)
        var found: [WorkspaceInfo] = []
        for owner in directories(in: rootPath) {
            for name in directories(in: rootPath + "/" + owner) {
                let path = rootPath + "/" + owner + "/" + name
                // A worktree keeps FETCH_HEAD and HEAD in its folder under the mirror.
                let git = WorkspaceNaming.gitDirectory(checkout: path)
                let times = [path, path + "/.minirun", git + "/FETCH_HEAD", git + "/HEAD"].compactMap {
                    (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
                }
                found.append(WorkspaceInfo(
                    path: path, name: owner + "/" + name, sizeBytes: sizes ? size(path) : 0, lastUsed: times.max(),
                    busy: isBusy(path, busy: busy)
                ))
            }
        }
        return found.sorted { ($0.lastUsed ?? .distantPast, $1.name) > ($1.lastUsed ?? .distantPast, $0.name) }
    }

    /// The checkout `path` names, checked to be exactly `<root>/<owner>/<name>`, so a delete can
    /// never reach outside the workspace root or take a whole owner folder.
    public static func checkout(_ path: String, root: String) throws -> String {
        let rootPath = standardized(root)
        let target = standardized(path)
        guard target.hasPrefix(rootPath + "/") else { throw ToolError("\(path) isn't inside the workspace folder \(rootPath).") }
        let parts = target.dropFirst(rootPath.count + 1).split(separator: "/")
        guard parts.count == 2, !parts.contains(where: { $0.hasPrefix(".") }) else {
            throw ToolError("\(path) isn't a checkout. Checkouts are folders like \(rootPath)/owner/app.")
        }
        guard FileManager.default.fileExists(atPath: target) else { throw ToolError("No checkout at \(target).") }
        return target
    }

    public static func isBusy(_ checkout: String, busy: Set<String>) -> Bool {
        busy.contains { $0 == checkout || $0.hasPrefix(checkout + "/") }
    }

    /// Deletes the checkout, and its owner folder if that's left empty.
    public static func delete(_ checkout: String) throws {
        let fm = FileManager.default
        try fm.removeItem(atPath: checkout)
        let owner = (checkout as NSString).deletingLastPathComponent
        if (try? fm.contentsOfDirectory(atPath: owner))?.isEmpty == true { try? fm.removeItem(atPath: owner) }
    }

    /// Free space on the volume holding `path`, in bytes, as `df` reports it. Nil if it can't be read.
    public static func freeBytes(at path: String) -> Int64? {
        (try? FileManager.default.attributesOfFileSystem(forPath: path)[.systemFreeSize] as? NSNumber)?.int64Value
    }

    /// "1.2 GB"
    public static func formatSize(_ bytes: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return unit == 0 ? "\(bytes) bytes" : String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, units[unit])
    }

    public static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    static func directories(in path: String) -> [String] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { name in
            var isDirectory: ObjCBool = false
            return !name.hasPrefix(".") && fm.fileExists(atPath: path + "/" + name, isDirectory: &isDirectory) && isDirectory.boolValue
        }.sorted()
    }

    /// Total size of the files under `path`, not following symbolic links.
    static func size(_ path: String) -> Int64 {
        guard let files = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

/// What `minirun serve` deletes by itself, so checkouts don't fill the Mac's disk. Every repo + ref
/// gets its own checkout and build folder (often 1–3 GB), and agents and CI make a new ref for
/// every branch, so without this they pile up.
public enum WorkspaceCleanup {
    /// A checkout used this recently is never deleted to free disk: a session is likely still on it.
    public static let recentUse: TimeInterval = 3600

    /// Checkouts nobody has used for `days` days and no job is using; none when `days` is 0.
    public static func expired(_ list: [WorkspaceInfo], olderThanDays days: Int, now: Date = Date()) -> [WorkspaceInfo] {
        guard days > 0 else { return [] }
        return WorkspaceInventory.stale(list, olderThanDays: days, now: now)
    }

    /// What may go while the disk is low, least recently used first: checkouts no job is using and
    /// nobody used in the last `recentUse`. A checkout whose last use is unknown goes first.
    public static func spare(_ list: [WorkspaceInfo], now: Date = Date()) -> [WorkspaceInfo] {
        let cutoff = now.addingTimeInterval(-recentUse)
        return list
            .filter { !$0.busy && ($0.lastUsed.map { $0 < cutoff } ?? true) }
            .sorted { ($0.lastUsed ?? .distantPast, $0.name) < ($1.lastUsed ?? .distantPast, $1.name) }
    }

    /// Whether `free` bytes is under the `minFreeGB` floor; never when the floor is 0.
    public static func isLow(freeBytes free: Int64?, minFreeGB: Int) -> Bool {
        guard minFreeGB > 0, let free else { return false }
        return free < Int64(minFreeGB) * 1_000_000_000
    }
}
