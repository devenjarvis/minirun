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
    /// Where its stdout and stderr go.
    public var logPath: String?
    public var launchedAt: Date?
    /// When minirun last used it. Idle quitting goes by this.
    public var updatedAt: Date

    public init(id: String, label: String? = nil, name: String, bundleID: String? = nil, appPath: String, executablePath: String,
                pid: Int32? = nil, logPath: String? = nil, launchedAt: Date? = nil, updatedAt: Date = Date()) {
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
public actor MacAppStore {
    private let url: URL?
    private var sessions: [String: MacAppSession] = [:]
    /// Each app's last-used time as last written to disk.
    private var saved: [String: Date] = [:]

    /// `url` nil keeps everything in memory (for tests and `minirun call`). A missing or unreadable
    /// file starts empty.
    public init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            sessions = (try? decoder.decode([String: MacAppSession].self, from: data)) ?? [:]
        }
        saved = sessions.mapValues(\.updatedAt)
    }

    public static var defaultURL: URL {
        MiniRunConfig.configURL.deletingLastPathComponent().appendingPathComponent("mac-apps.json")
    }

    public func session(_ id: String) -> MacAppSession? { sessions[id.lowercased()] }

    /// Every session, most recently used first.
    public func all() -> [MacAppSession] {
        sessions.values.sorted { ($0.updatedAt, $1.id) > ($1.updatedAt, $0.id) }
    }

    /// The id for `label`: `MacAppID.forLabel(label)`, unless (very rarely) another label already
    /// has that id, in which case the next free one in a stable sequence.
    public func id(forLabel label: String) -> String {
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
        sessions[session.id] = session
        save()
    }

    /// Marks an app as just used. Saved at most once a minute per app.
    public func touch(_ id: String, now: Date = Date()) {
        let id = id.lowercased()
        guard sessions[id] != nil else { return }
        sessions[id]?.updatedAt = now
        if saved[id].map({ now.timeIntervalSince($0) >= 60 }) ?? true { save() }
    }

    /// The app quit (or was quit): keep the entry, so its id and log stay known, without a pid.
    public func markExited(_ id: String) {
        let id = id.lowercased()
        guard sessions[id]?.pid != nil else { return }
        sessions[id]?.pid = nil
        save()
    }

    public func remove(_ id: String) {
        guard sessions.removeValue(forKey: id.lowercased()) != nil else { return }
        save()
    }

    /// After a restart: keeps the pids that `isAlive(pid, executablePath)` says are still the app
    /// minirun launched, and clears the rest (the process ended, or the pid now belongs to
    /// something else), so minirun never signals a stranger.
    public func reconcile(isAlive: (Int32, String) -> Bool) {
        var changed = false
        for (id, session) in sessions {
            guard let pid = session.pid, !isAlive(pid, session.executablePath) else { continue }
            sessions[id]?.pid = nil
            changed = true
        }
        if changed { save() }
    }

    private func save() {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(sessions) else { return }
        saved = sessions.mapValues(\.updatedAt)
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
