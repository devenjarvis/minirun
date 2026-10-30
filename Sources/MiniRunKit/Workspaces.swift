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
    /// is busy if one of them is the checkout or inside it.
    public static func list(root: String, busy: Set<String> = []) -> [WorkspaceInfo] {
        let fm = FileManager.default
        let rootPath = standardized(root)
        var found: [WorkspaceInfo] = []
        for owner in directories(in: rootPath) {
            for name in directories(in: rootPath + "/" + owner) {
                let path = rootPath + "/" + owner + "/" + name
                let times = [path, path + "/.minirun", path + "/.git/FETCH_HEAD", path + "/.git/HEAD"].compactMap {
                    (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
                }
                found.append(WorkspaceInfo(
                    path: path, name: owner + "/" + name, sizeBytes: size(path), lastUsed: times.max(),
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
