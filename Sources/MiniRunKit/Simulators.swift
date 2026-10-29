import Foundation

/// What a booted simulator is being used for. Several Claude sessions can share one Mac, so
/// minirun remembers which repo and branch each simulator belongs to and never guesses between them.
public struct SimulatorClaim: Codable, Equatable, Sendable {
    /// Who the simulator is for: "owner/app@branch" from a build, or a boot_simulator label.
    public var label: String?
    /// The app minirun last installed or launched there.
    public var bundleID: String?
    public var updatedAt: Date

    public init(label: String? = nil, bundleID: String? = nil, updatedAt: Date = Date()) {
        self.label = label
        self.bundleID = bundleID
        self.updatedAt = updatedAt
    }
}

/// Decides which simulator a tool call acts on. Pure logic so it can be unit tested anywhere.
///
/// The rules, in short: a UDID always wins. Without one, a call only proceeds when exactly one
/// simulator could be meant; otherwise it fails with a list of the booted simulators and who each
/// one is reserved for. Builds know their repo and branch, so they find (or boot) their own.
public enum SimulatorPicker {
    public typealias Device = XcodeParsing.SimDevice

    public enum Choice: Equatable, Sendable {
        /// Use this simulator, booting it first if it isn't running.
        case use(Device, note: String? = nil)
        /// Every simulator of the wanted model is busy: create another one like `like`.
        case create(name: String, like: Device, note: String? = nil)
        case failure(String)
    }

    /// Simulators minirun creates are named like "iPhone 17 Pro (minirun 2)".
    public static let cloneMarker = " (minirun "

    /// Picks the simulator for a tool call.
    ///
    /// - Parameters:
    ///   - query: The `device` argument: a UDID or a simulator name.
    ///   - workspace: For builds, the repo and ref being built ("owner/app@branch"). A build without
    ///     `device` uses the simulator reserved for its workspace, or an unreserved booted one, or
    ///     boots a new one rather than taking a simulator reserved for other work.
    public static func target(
        query: String?,
        workspace: String?,
        devices: [Device],
        claims: [String: SimulatorClaim],
        preferredName: String?,
        maxBooted: Int = 4,
        now: Date = Date()
    ) -> Choice {
        let available = devices.filter(\.isAvailable)
        let booted = available.filter(\.isBooted)

        if let query = normalized(query) {
            if let exact = available.first(where: { $0.udid.caseInsensitiveCompare(query) == .orderedSame }) { return .use(exact) }
            let named = available.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
            guard !named.isEmpty else { return .failure(noMatch(query, booted: booted, claims: claims, now: now)) }
            let namedBooted = named.filter(\.isBooted)
            if namedBooted.count > 1 { return .failure(ambiguous(namedBooted, claims: claims, now: now)) }
            if let device = namedBooted.first {
                if let workspace, let owner = claims[device.udid]?.label, owner != workspace {
                    return .failure(
                        "\(device.name) (\(device.udid)) is reserved for \(owner). If that's your work, pass device: \"\(device.udid)\". " +
                        "Otherwise call boot_simulator with device: \"\(device.name)\" and label: \"\(workspace)\" to get a separate one."
                    )
                }
                return .use(device)
            }
            return .use(named[0])
        }

        if let workspace {
            let mine = booted
                .filter { claims[$0.udid]?.label == workspace }
                .sorted { (claims[$0.udid]?.updatedAt ?? .distantPast) > (claims[$1.udid]?.updatedAt ?? .distantPast) }
            if let device = mine.first { return .use(device) }
            let free = booted.filter { claims[$0.udid]?.label == nil }
            if free.count == 1 { return .use(free[0]) }
            if free.count > 1 { return .failure(ambiguous(free, claims: claims, now: now)) }
            if booted.count >= maxBooted {
                return .failure(
                    "\(booted.count) simulators are already running, all reserved for other work:\n\(describe(booted, claims: claims, now: now))\n" +
                    "Pass device with one of these UDIDs to use it, or free one with shutdown_simulator."
                )
            }
            let choice = fresh(query: nil, label: nil, devices: devices, claims: claims, preferredName: preferredName, maxBooted: maxBooted, now: now)
            guard !booted.isEmpty else { return choice }
            let note = "The running simulators are reserved for other work, so \(workspace) gets its own."
            switch choice {
            case .use(let device, _): return .use(device, note: note)
            case .create(let name, let like, _): return .create(name: name, like: like, note: note)
            case .failure: return choice
            }
        }

        switch booted.count {
        case 0:
            guard let device = XcodeParsing.pickDevice(available, query: nil, preferredName: preferredName) else { return .failure(noSimulators) }
            return .use(device)
        case 1:
            return .use(booted[0])
        default:
            return .failure(ambiguous(booted, claims: claims, now: now))
        }
    }

    /// Picks a simulator for boot_simulator: one nobody is using, creating one if every
    /// simulator of the wanted model is already running.
    ///
    /// A UDID returns that simulator. A `label` that already has a booted simulator returns it,
    /// so calling boot_simulator twice with the same label is harmless.
    public static func fresh(
        query: String?,
        label: String?,
        devices: [Device],
        claims: [String: SimulatorClaim],
        preferredName: String?,
        maxBooted: Int = 4,
        now: Date = Date()
    ) -> Choice {
        let available = devices.filter(\.isAvailable)
        let query = normalized(query)
        if let query, let exact = available.first(where: { $0.udid.caseInsensitiveCompare(query) == .orderedSame }) { return .use(exact) }
        if let label, let mine = available.first(where: {
            $0.isBooted && claims[$0.udid]?.label == label && (query == nil || isModel($0.name, query!))
        }) {
            return .use(mine)
        }

        let ios = available.filter { $0.runtime.contains("iOS") }
        let kind: [Device]
        if let query {
            kind = available.filter { isModel($0.name, query) }
            guard !kind.isEmpty else { return .failure("No simulator is named \"\(query)\". Call list_simulators to see the installed ones.") }
        } else {
            let iPhones = ios.filter { $0.name.hasPrefix("iPhone") && !$0.name.contains("SE") }
            let preferred = preferredName.map { name in ios.filter { isModel($0.name, name) } } ?? []
            kind = preferred + (iPhones.isEmpty ? ios : iPhones)
        }
        let booted = available.filter(\.isBooted)
        if booted.count >= maxBooted {
            return .failure(
                "\(booted.count) simulators are already running:\n\(describe(booted, claims: claims, now: now))\n" +
                "Pass device with one of these UDIDs to use it, or free one with shutdown_simulator."
            )
        }
        if let idle = kind.first(where: { !$0.isBooted }) { return .use(idle) }
        guard let model = kind.first(where: { !$0.name.contains(cloneMarker) }) ?? kind.first else { return .failure(noSimulators) }
        let base = baseName(model.name)
        return .create(name: cloneName(base, existing: available.map(\.name)), like: model)
    }

    /// One line per simulator: UDID, name, and who it's reserved for.
    public static func describe(_ devices: [Device], claims: [String: SimulatorClaim], now: Date = Date()) -> String {
        devices.map { device in
            var parts = [claims[device.udid]?.label.map { "reserved for \($0)" } ?? "not reserved"]
            if let claim = claims[device.udid] {
                if let bundle = claim.bundleID { parts.append("last app \(bundle)") }
                parts.append("used \(ago(claim.updatedAt, now: now))")
            }
            return "- \(device.udid)  \(device.name) (\(device.runtimeName)) — " + parts.joined(separator: ", ")
        }.joined(separator: "\n")
    }

    // MARK: Helpers

    static func normalized(_ query: String?) -> String? {
        guard let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              trimmed.lowercased() != "booted" else { return nil }
        return trimmed
    }

    /// True for the model itself and for minirun's copies of it.
    static func isModel(_ name: String, _ model: String) -> Bool {
        name.caseInsensitiveCompare(model) == .orderedSame || name.lowercased().hasPrefix(model.lowercased() + cloneMarker)
    }

    public static func baseName(_ name: String) -> String {
        guard let range = name.range(of: cloneMarker) else { return name }
        return String(name[..<range.lowerBound])
    }

    static func cloneName(_ base: String, existing: [String]) -> String {
        var number = 2
        while existing.contains(base + cloneMarker + "\(number))") { number += 1 }
        return base + cloneMarker + "\(number))"
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86400 { return "\(seconds / 3600) h ago" }
        return "\(seconds / 86400) d ago"
    }

    static func ambiguous(_ booted: [Device], claims: [String: SimulatorClaim], now: Date) -> String {
        "\(booted.count) simulators are booted, so this call needs `device`. Pass the UDID of the one you're working on:\n" +
            describe(booted, claims: claims, now: now) +
            "\nIf none of them is yours, call boot_simulator with label set to your repo and branch (e.g. \"owner/app@my-branch\") to get your own."
    }

    static func noMatch(_ query: String, booted: [Device], claims: [String: SimulatorClaim], now: Date) -> String {
        var text = "No available simulator matches \"\(query)\"."
        if !booted.isEmpty { text += " Booted simulators:\n" + describe(booted, claims: claims, now: now) }
        return text + "\nCall list_simulators to see all of them."
    }

    static let noSimulators = "No iOS simulators are installed. Install an iOS runtime in Xcode > Settings > Components."
}

/// Remembers simulator reservations across restarts of `minirun serve`.
public actor SimulatorClaimStore {
    private let url: URL?
    private var claims: [String: SimulatorClaim] = [:]
    /// Each simulator's last-used time as last written to disk.
    private var saved: [String: Date] = [:]

    public init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            claims = (try? decoder.decode([String: SimulatorClaim].self, from: data)) ?? [:]
        }
        saved = claims.mapValues(\.updatedAt)
    }

    public static var defaultURL: URL {
        MiniRunConfig.configURL.deletingLastPathComponent().appendingPathComponent("simulators.json")
    }

    /// Current claims, dropping any for simulators that are no longer booted.
    public func snapshot(booted: Set<String>) -> [String: SimulatorClaim] {
        let stale = claims.keys.filter { !booted.contains($0) }
        if !stale.isEmpty {
            for udid in stale { claims[udid] = nil }
            save()
        }
        return claims
    }

    /// Reserves a simulator for `label`. Returns the label it was reserved for before, if different.
    @discardableResult
    public func reserve(_ udid: String, for label: String?, now: Date = Date()) -> String? {
        let previous = claims[udid]
        if previous?.label == label, var claim = previous {
            claim.updatedAt = now
            claims[udid] = claim
        } else {
            claims[udid] = SimulatorClaim(label: label, updatedAt: now)
        }
        save()
        guard let old = previous?.label, old != label else { return nil }
        return old
    }

    /// Records the app minirun put on a simulator.
    public func noteApp(_ udid: String, bundleID: String, now: Date = Date()) {
        var claim = claims[udid] ?? SimulatorClaim()
        claim.bundleID = bundleID
        claim.updatedAt = now
        claims[udid] = claim
        save()
    }

    /// Marks a simulator as just used. Idle shutdown goes by this time, so it's saved, at most
    /// once a minute per simulator.
    public func touch(_ udid: String, now: Date = Date()) {
        if claims[udid] == nil { claims[udid] = SimulatorClaim(updatedAt: now) } else { claims[udid]?.updatedAt = now }
        if saved[udid].map({ now.timeIntervalSince($0) >= 60 }) ?? true { save() }
    }

    /// Ends a simulator's reservation but keeps when it was last used, so a free simulator
    /// doesn't look busy.
    public func unreserve(_ udid: String) {
        guard claims[udid]?.label != nil else { return }
        claims[udid]?.label = nil
        save()
    }

    public func release(_ udid: String) {
        guard claims.removeValue(forKey: udid) != nil else { return }
        save()
    }

    private func save() {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(claims) else { return }
        saved = claims.mapValues(\.updatedAt)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Simulators being booted right now. A pick starts the boot while holding the allocation lock and
/// waits for it after letting go, so one simulator's first boot (which can take minutes) doesn't
/// hold up other sessions. Picks treat a booting simulator as booted, and as reserved for whoever
/// is booting it, so nobody else takes it.
public actor SimulatorBoots {
    private var running: [String: Task<Void, Error>] = [:]

    public init() {}

    public var booting: Set<String> { Set(running.keys) }

    public func isBooting(_ udid: String) -> Bool { running[udid] != nil }

    /// Starts `work` for `udid` unless a boot of it is already running, and returns the boot to wait on.
    public func start(_ udid: String, _ work: @escaping @Sendable () async throws -> Void) -> Task<Void, Error> {
        if let task = running[udid] { return task }
        let task = Task {
            do {
                try await work()
            } catch {
                await self.finished(udid)
                throw error
            }
            await self.finished(udid)
        }
        running[udid] = task
        return task
    }

    /// The running boot of `udid`, if there is one.
    public func task(_ udid: String) -> Task<Void, Error>? { running[udid] }

    private func finished(_ udid: String) {
        running[udid] = nil
    }
}

/// Simulators with work in progress (a build or test job, or a live view someone is watching).
/// Idle shutdown leaves these alone however long ago a tool last touched them.
public actor SimulatorActivity {
    private var holds: [String: Int] = [:]

    public init() {}

    public var busy: Set<String> { Set(holds.keys) }

    public func begin(_ udid: String) { holds[udid, default: 0] += 1 }

    public func end(_ udid: String) {
        guard let count = holds[udid] else { return }
        holds[udid] = count > 1 ? count - 1 : nil
    }
}

/// Decides which idle simulators to shut down. Pure logic so it can be unit tested anywhere.
public enum IdleSimulators {
    public enum Action: Equatable, Sendable {
        /// Shut it down (which also ends its reservation).
        case shutdown(String)
        /// Keep it booted as a spare, but free it for other work.
        case unreserve(String)
    }

    /// Booted simulators minirun has used (they have a claim), that aren't busy, and that haven't
    /// been used for `idleAfter` are shut down. If that would leave nothing booted, the most recently
    /// used one stays up with its reservation released, so the next session doesn't wait for a boot.
    /// Simulators minirun never touched (booted by hand, say) are left alone.
    public static func plan(
        booted: [XcodeParsing.SimDevice],
        claims: [String: SimulatorClaim],
        busy: Set<String>,
        idleAfter: TimeInterval,
        now: Date = Date()
    ) -> [Action] {
        guard idleAfter > 0 else { return [] }
        let idle = booted
            .filter { device in
                guard !busy.contains(device.udid), let claim = claims[device.udid] else { return false }
                return now.timeIntervalSince(claim.updatedAt) >= idleAfter
            }
            .sorted { claims[$0.udid]!.updatedAt > claims[$1.udid]!.updatedAt }
        guard let newest = idle.first else { return [] }
        var actions: [Action] = []
        var shut = idle
        if idle.count == booted.count {
            shut.removeFirst()
            if claims[newest.udid]?.label != nil { actions.append(.unreserve(newest.udid)) }
        }
        return actions + shut.map { .shutdown($0.udid) }
    }
}
