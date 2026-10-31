import Foundation

/// A macOS app minirun launched on this Mac, for one piece of work. Several Claude sessions can
/// share the Mac, so minirun remembers which pid it started for which repo and branch, and only
/// ever quits its own.
public struct MacAppSession: Codable, Equatable, Sendable {
    /// "mac-" + 6 hex characters (see `MacAppID`). Stays the same across relaunches.
    public var id: String
    /// Who it's for: the workspace label ("owner/app@branch", or the folder for `path`).
    public var label: String?
    /// The app's display name, e.g. "Fetch".
    public var name: String
    public var bundleID: String?
    /// …/Build/Products/Debug/Fetch.app
    public var appPath: String
    /// The executable minirun spawned, inside `appPath`.
    public var executablePath: String
    /// Nil when it isn't running.
    public var pid: Int32?
    /// When the process with `pid` started (from the kernel), so a recycled pid is never taken
    /// for the app. Nil in entries saved by older versions.
    public var processStart: MacProcessStart?
    /// The pid it last ran as, kept after it quits so its logs can still be found by pid.
    public var lastPid: Int32?
    /// When minirun saw it quit.
    public var exitedAt: Date?
    /// Where its stdout and stderr go.
    public var logPath: String?
    public var launchedAt: Date?
    /// When minirun last used it. Idle quitting goes by this.
    public var updatedAt: Date

    public init(id: String, label: String? = nil, name: String, bundleID: String? = nil, appPath: String, executablePath: String,
                pid: Int32? = nil, logPath: String? = nil, launchedAt: Date? = nil, updatedAt: Date = Date(),
                processStart: MacProcessStart? = nil, lastPid: Int32? = nil, exitedAt: Date? = nil) {
        self.id = id
        self.label = label
        self.name = name
        self.bundleID = bundleID
        self.appPath = appPath
        self.executablePath = executablePath
        self.pid = pid
        self.logPath = logPath
        self.launchedAt = launchedAt
        self.updatedAt = updatedAt
        self.processStart = processStart
        self.lastPid = lastPid ?? pid
        self.exitedAt = exitedAt
    }

    public var isRunning: Bool { pid != nil }

    /// The session as tool results show it (list_mac_apps and friends).
    public var json: JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(name),
            "app_path": .string(appPath),
            "running": .bool(isRunning),
            "last_used": .string(Self.iso8601(updatedAt)),
        ]
        if let label { object["reserved_for"] = .string(label) }
        if let bundleID { object["bundle_id"] = .string(bundleID) }
        if let pid { object["pid"] = .number(Double(pid)) }
        if let logPath { object["log_path"] = .string(logPath) }
        if let launchedAt { object["launched_at"] = .string(Self.iso8601(launchedAt)) }
        return .object(object)
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// When a process started, as the kernel reports it (`proc_bsdinfo.pbi_start_tvsec/usec`).
/// Together with the pid it names one process: pids get reused, start times don't repeat.
public struct MacProcessStart: Codable, Equatable, Sendable {
    public var seconds: UInt64
    public var microseconds: UInt64

    public init(seconds: UInt64, microseconds: UInt64) {
        self.seconds = seconds
        self.microseconds = microseconds
    }
}

/// Names Mac apps for the `device` argument, so tools can tell them from simulator UDIDs.
public enum MacAppID {
    public static let prefix = "mac-"

    /// `device` names a Mac app: "mac" (launch a new one) or an id like "mac-3f9a2c".
    /// Simulator UDIDs are hex and dashes, so they never start with "mac-".
    public static func isMacDevice(_ device: String?) -> Bool {
        guard let device = device?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return device == "mac" || (device.hasPrefix(prefix) && device.count > prefix.count)
    }

    /// The id for a workspace label. The same label always gets the same id, in every run of
    /// minirun, so relaunching after a rebuild keeps it.
    public static func forLabel(_ label: String) -> String {
        prefix + hex6(fnv1a(label))
    }

    /// A fresh id, for apps launched without a workspace.
    public static func random() -> String {
        prefix + hex6(UInt64.random(in: 0...UInt64.max))
    }

    /// 64-bit FNV-1a over the UTF-8 bytes. Small and the same everywhere (CryptoKit isn't on Linux).
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    static func hex6(_ value: UInt64) -> String {
        let hex = String(value & 0xff_ffff, radix: 16)
        return String(repeating: "0", count: 6 - hex.count) + hex
    }
}

/// The Mac apps minirun launched, persisted to ~/.config/minirun/mac-apps.json so a restarted
/// `minirun serve` still knows which pids are its own.
///
/// `minirun serve` and one-off `minirun call`s (the smoke test drives a whole session through
/// separate `call` processes) share the file, so every read starts from what's on disk and every
/// change is a read-modify-write of one entry under an exclusive lock on a sidecar lock file,
/// written atomically. Two processes changing different apps never undo each other's changes.
public actor MacAppStore {
    private let url: URL?
    private var sessions: [String: MacAppSession] = [:]
    /// Last-used times not written yet (`touch` saves at most once a minute per app). They're
    /// laid over what's read from disk until the next save.
    private var unsavedTouches: [String: Date] = [:]
    /// When each app's last-used time was last written.
    private var savedTouches: [String: Date] = [:]

    /// `url` nil keeps everything in memory (for tests). A missing or unreadable file starts empty.
    public init(url: URL?) {
        self.url = url
        if let url { sessions = Self.read(url) }
    }

    public static var defaultURL: URL {
        MiniRunConfig.configURL.deletingLastPathComponent().appendingPathComponent("mac-apps.json")
    }

    public func session(_ id: String) -> MacAppSession? {
        refresh()
        return sessions[id.lowercased()]
    }

    /// Every session, most recently used first.
    public func all() -> [MacAppSession] {
        refresh()
        return sessions.values.sorted { ($0.updatedAt, $1.id) > ($1.updatedAt, $0.id) }
    }

    /// The id for `label`: `MacAppID.forLabel(label)`, unless (very rarely) another label already
    /// has that id, in which case the next free one in a stable sequence.
    public func id(forLabel label: String) -> String {
        refresh()
        var candidate = MacAppID.forLabel(label)
        var attempt = 1
        while let other = sessions[candidate], other.label != label {
            candidate = MacAppID.forLabel("\(label)#\(attempt)")
            attempt += 1
        }
        return candidate
    }

    public func upsert(_ session: MacAppSession) {
        var session = session
        session.id = session.id.lowercased()
        unsavedTouches[session.id] = nil
        update { sessions in
            sessions[session.id] = session
            return true
        }
    }

    /// Marks an app as just used. Saved at most once a minute per app.
    public func touch(_ id: String, now: Date = Date()) {
        let id = id.lowercased()
        refresh()
        guard sessions[id] != nil else { return }
        sessions[id]?.updatedAt = now
        unsavedTouches[id] = now
        if savedTouches[id].map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            update { _ in true }
        }
    }

    /// The app with this id quit (or was quit) while it was `pid`: keeps the entry, so its id and
    /// logs stay known, without a pid. Compare-and-clear: if the app was relaunched in the
    /// meantime (its pid is no longer `pid`), nothing changes, so a stale check never forgets a
    /// live app.
    public func markExited(_ id: String, ifPid pid: Int32, at date: Date = Date()) {
        let id = id.lowercased()
        update { sessions in
            guard let current = sessions[id], current.pid == pid else { return false }
            sessions[id]?.pid = nil
            sessions[id]?.lastPid = pid
            sessions[id]?.exitedAt = date
            return true
        }
    }

    public func remove(_ id: String) {
        let id = id.lowercased()
        unsavedTouches[id] = nil
        update { sessions in sessions.removeValue(forKey: id) != nil }
    }

    /// After a restart: keeps the pids that `isAlive` says are still the app minirun launched
    /// (same executable and, when recorded, the same process start time), and clears the rest
    /// (the process ended, or the pid now belongs to something else), so minirun never signals a
    /// stranger.
    public func reconcile(isAlive: (MacAppSession) -> Bool) {
        update { sessions in
            var changed = false
            for (id, session) in sessions {
                guard let pid = session.pid, !isAlive(session) else { continue }
                sessions[id]?.pid = nil
                sessions[id]?.lastPid = pid
                sessions[id]?.exitedAt = session.exitedAt ?? Date()
                changed = true
            }
            return changed
        }
    }

    // MARK: The file

    static func read(_ url: URL) -> [String: MacAppSession] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: MacAppSession].self, from: data)) ?? [:]
    }

    /// Picks up what other minirun processes wrote, keeping this one's unsaved last-used times.
    private func refresh() {
        guard let url else { return }
        sessions = Self.read(url)
        for (id, date) in unsavedTouches {
            guard let current = sessions[id]?.updatedAt else {
                unsavedTouches[id] = nil
                continue
            }
            if date > current { sessions[id]?.updatedAt = date }
        }
    }

    /// Read-modify-write under the file lock. `change` returns whether it changed anything.
    private func update(_ change: (inout [String: MacAppSession]) -> Bool) {
        withFileLock {
            refresh()
            let changed = change(&sessions)
            if changed || !unsavedTouches.isEmpty { save() }
        }
    }

    private func withFileLock(_ body: () -> Void) {
        guard let url else { return body() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        if fd >= 0 { _ = flock(fd, LOCK_EX) }
        defer {
            if fd >= 0 {
                _ = flock(fd, LOCK_UN)
                close(fd)
            }
        }
        body()
    }

    private func save() {
        let now = Date()
        for id in unsavedTouches.keys { savedTouches[id] = now }
        unsavedTouches = [:]
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(sessions) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        // Paths and labels of private repositories.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Decides which idle Mac apps to quit. Pure logic so it can be unit tested anywhere.
public enum IdleMacApps {
    /// Running apps that aren't `busy` (a job or a live view) and haven't been used for
    /// `idleAfter` seconds, least recently used first. `idleAfter` 0 turns idle quitting off.
    public static func plan(_ sessions: [MacAppSession], busy: Set<String>, idleAfter: TimeInterval, now: Date = Date()) -> [String] {
        guard idleAfter > 0 else { return [] }
        return sessions
            .filter { $0.pid != nil && !busy.contains($0.id) && now.timeIntervalSince($0.updatedAt) >= idleAfter }
            .sorted { ($0.updatedAt, $0.id) < ($1.updatedAt, $1.id) }
            .map(\.id)
    }
}
