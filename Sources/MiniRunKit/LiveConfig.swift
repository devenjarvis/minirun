import Foundation

/// The settings `minirun serve` runs with, which can change while it runs: `reload_config` on the
/// control socket or a SIGHUP re-reads config.json. Code reads `current` at each use instead of
/// keeping a copy, so most changes apply at once. Observers handle the rest (the relay
/// connection, keeping the Mac awake).
public final class LiveConfig: @unchecked Sendable {
    public typealias Observer = @Sendable (_ old: MiniRunConfig, _ new: MiniRunConfig) -> Void

    private let lock = NSLock()
    private var value: MiniRunConfig
    private var observers: [Observer] = []

    public init(_ config: MiniRunConfig) {
        value = config
    }

    public var current: MiniRunConfig {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// Calls `observer` after each change, with the settings before and after.
    public func observe(_ observer: @escaping Observer) {
        lock.lock()
        observers.append(observer)
        lock.unlock()
    }

    /// Switches to `new` and tells the observers if anything changed.
    @discardableResult
    public func update(_ new: MiniRunConfig) -> ConfigReload {
        lock.lock()
        let old = value
        value = new
        let observers = self.observers
        lock.unlock()
        let reload = ConfigReload.diff(old, new)
        if reload.changed { for observer in observers { observer(old, new) } }
        return reload
    }

    /// Re-reads config.json. A missing or broken file throws and leaves the settings alone.
    @discardableResult
    public func reload(from url: URL = MiniRunConfig.configURL) throws -> ConfigReload {
        update(try MiniRunConfig.read(from: url))
    }
}

/// Which settings a reload changed.
public struct ConfigReload: Codable, Equatable, Sendable {
    /// Settings that make the relay connection start over: the relay URL and the agent token.
    public static let reconnectKeys: Set<String> = ["relayURL", "agentToken"]

    /// Changed settings that took effect at once, by their config.json key.
    public var applied: [String]
    /// Changed settings that make minirun reconnect to the relay.
    public var reconnecting: [String]

    public init(applied: [String] = [], reconnecting: [String] = []) {
        self.applied = applied
        self.reconnecting = reconnecting
    }

    public var changed: Bool { !applied.isEmpty || !reconnecting.isEmpty }

    public static func diff(_ old: MiniRunConfig, _ new: MiniRunConfig) -> ConfigReload {
        // Compare the JSON forms, so a setting added later is covered without listing it here.
        let before = Self.fields(old), after = Self.fields(new)
        let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
        return ConfigReload(
            applied: changed.filter { !reconnectKeys.contains($0) },
            reconnecting: changed.filter { reconnectKeys.contains($0) }
        )
    }

    static func fields(_ config: MiniRunConfig) -> [String: JSONValue] {
        guard let data = try? JSONEncoder().encode(config), let object = try? JSONValue.parse(data).objectValue else { return [:] }
        return object
    }

    /// "Applied idleShutdownMinutes. Reconnecting to the relay for agentToken." Never shows values,
    /// since the token is secret.
    public var summary: String {
        guard changed else { return "Settings reloaded; nothing changed." }
        var parts: [String] = []
        if !applied.isEmpty { parts.append("Applied \(applied.joined(separator: ", ")).") }
        if !reconnecting.isEmpty { parts.append("Reconnecting to the relay for \(reconnecting.joined(separator: ", ")).") }
        return parts.joined(separator: " ")
    }
}
