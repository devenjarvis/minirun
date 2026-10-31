import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The settings window's editable fields, taken from config.json. Saving writes them back onto a
/// fresh read of the file, so a relay URL or token another process just wrote isn't lost.
public struct SettingsForm: Equatable, Sendable {
    /// "" lets minirun pick (the newest Pro iPhone).
    public var defaultDevice: String
    public var idleShutdownMinutes: Int
    public var maxBootedSimulators: Int
    public var workspaceRoot: String
    public var allowShell: Bool
    public var preventSleep: Bool
    public var shareMedia: Bool
    public var mediaRetentionDays: Int
    public var mediaStorageLimitMB: Int
    public var maxRecordingSeconds: Int
    public var mediaInlineLimitMB: Int

    public static let maxBootedRange = 1...16
    public static let idleRange = 0...1440
    public static let retentionChoices = [1, 7, 30, 90]
    /// Workers KV's free plan stores 1 GB.
    public static let storageLimitRange = 10...1000
    public static let recordingRange = MiniRunConfig.recordingSecondsRange
    public static let inlineLimitRange = MiniRunConfig.inlineLimitMBRange

    public init(_ config: MiniRunConfig) {
        defaultDevice = config.defaultDevice ?? ""
        idleShutdownMinutes = config.idleShutdownMinutes
        maxBootedSimulators = config.maxBootedSimulators
        workspaceRoot = config.workspaceRoot
        allowShell = config.allowShell
        preventSleep = config.preventSleep
        shareMedia = config.shareMedia
        mediaRetentionDays = config.mediaRetentionDays
        mediaStorageLimitMB = config.mediaStorageLimitMB
        maxRecordingSeconds = config.maxRecordingSeconds
        mediaInlineLimitMB = config.mediaInlineLimitMB
    }

    /// The Keep for choices, plus a saved value that isn't one of them.
    public var retentionChoices: [Int] {
        Self.retentionChoices.contains(mediaRetentionDays) ? Self.retentionChoices : (Self.retentionChoices + [mediaRetentionDays]).sorted()
    }

    /// What's wrong with the form, for the user. Empty when it can be saved.
    public var problems: [String] {
        var problems: [String] = []
        if !Self.idleRange.contains(idleShutdownMinutes) {
            problems.append("Idle shutdown must be between 0 (never) and \(Self.idleRange.upperBound) minutes.")
        }
        if !Self.maxBootedRange.contains(maxBootedSimulators) {
            problems.append("Keep between \(Self.maxBootedRange.lowerBound) and \(Self.maxBootedRange.upperBound) simulators booted.")
        }
        if !MiniRunConfig.retentionDaysRange.contains(mediaRetentionDays) {
            problems.append("Keep shared media for 1 to 90 days.")
        }
        if !Self.storageLimitRange.contains(mediaStorageLimitMB) {
            problems.append("The storage limit must be between \(Self.storageLimitRange.lowerBound) and \(Self.storageLimitRange.upperBound) MB.")
        }
        if !Self.recordingRange.contains(maxRecordingSeconds) {
            problems.append("The longest recording must be between \(Self.recordingRange.lowerBound) and \(Self.recordingRange.upperBound) seconds.")
        }
        if !Self.inlineLimitRange.contains(mediaInlineLimitMB) {
            problems.append("The largest inline GIF must be between \(Self.inlineLimitRange.lowerBound) and \(Self.inlineLimitRange.upperBound) MB.")
        }
        let root = workspaceRoot.trimmingCharacters(in: .whitespaces)
        if root.isEmpty || !(root.hasPrefix("/") || root.hasPrefix("~")) {
            problems.append("The workspace folder must be a full path, like ~/minirun/workspaces.")
        }
        return problems
    }

    public func applied(to config: MiniRunConfig) -> MiniRunConfig {
        var config = config
        let device = defaultDevice.trimmingCharacters(in: .whitespaces)
        config.defaultDevice = device.isEmpty ? nil : device
        config.idleShutdownMinutes = idleShutdownMinutes
        config.maxBootedSimulators = maxBootedSimulators
        config.workspaceRoot = (workspaceRoot.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        config.allowShell = allowShell
        config.preventSleep = preventSleep
        config.shareMedia = shareMedia
        config.mediaRetentionDays = mediaRetentionDays
        config.mediaStorageLimitMB = mediaStorageLimitMB
        config.maxRecordingSeconds = maxRecordingSeconds
        config.mediaInlineLimitMB = mediaInlineLimitMB
        return config
    }

    /// Saves the form to config.json and asks `minirun serve` to reload it. Returns what happened.
    public func save(send: @Sendable (ControlProtocol.Request) async throws -> ControlProtocol.Response) async throws -> String {
        guard problems.isEmpty else { throw ToolError(problems.joined(separator: " ")) }
        let current = (try? MiniRunConfig.read()) ?? MiniRunConfig.load()
        let updated = applied(to: current)
        try updated.save()
        guard let response = try? await send(ControlProtocol.Request(command: "reload_config")) else {
            return "Saved. minirun serve isn't running; it uses these settings when it starts."
        }
        if response.ok { return response.message ?? "Saved." }
        if response.controlVersion == nil { return "Saved. Restart minirun serve to use them (it's too old to reload)." }
        throw ToolError("Saved, but minirun serve couldn't reload: \(response.error ?? "unknown error")")
    }

    /// Simulator names for the default device picker: iPhones in the order minirun prefers them,
    /// then iPads, each name once.
    public static func deviceChoices(_ devices: [XcodeParsing.SimDevice]) -> [String] {
        let ios = devices.filter { $0.isAvailable && $0.runtime.contains("iOS") && !$0.name.contains(SimulatorPicker.cloneMarker) }
        let phones = XcodeParsing.defaultiPhones(ios).map(\.name)
        let others = ios.map(\.name).filter { !$0.hasPrefix("iPhone") }.sorted()
        var seen = Set<String>()
        return (phones + others).filter { seen.insert($0).inserted }
    }

    /// What "Automatic" picks today.
    public static func automaticDevice(_ devices: [XcodeParsing.SimDevice]) -> String? {
        XcodeParsing.defaultiPhones(devices.filter(\.isAvailable)).first?.name
    }
}

extension WorkspaceInventory {
    /// Checkouts last used more than `days` days ago that no job is using: what "Delete all older
    /// than N days" deletes. A checkout whose last use is unknown is kept.
    public static func stale(_ list: [WorkspaceInfo], olderThanDays days: Int, now: Date = Date()) -> [WorkspaceInfo] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        return list.filter { !$0.busy && ($0.lastUsed.map { $0 < cutoff } ?? false) }
    }
}

/// "Copy diagnostics": versions, the daemon's state, the doctor checks and the settings, with
/// every secret left out, so it can be pasted into an issue.
public enum Diagnostics {
    public static func report(appVersion: String, os: String, status: ServeStatus?, config: MiniRunConfig,
                              worker: WorkerSettings, checks: [DoctorCheck], now: Date = Date()) -> String {
        var lines = ["minirun app \(appVersion) on \(os)"]
        if let status {
            lines.append("minirun serve \(status.version), pid \(status.pid), up \(ServeStatus.duration(now.timeIntervalSince(status.startedAt)))")
            lines.append("relay: \(status.relay.state.rawValue) \(status.relay.host ?? "")" + (status.relay.problem.map { " (\($0))" } ?? ""))
            lines.append("worker bundle: \(status.relay.workerBundle.map { String($0.prefix(12)) } ?? "unknown")")
            lines.append("simulators booted: \(status.simulators.count), jobs running: \(status.jobs.filter { $0.finishedAt == nil }.count)")
        } else {
            lines.append("minirun serve: not answering")
        }
        lines.append("")
        lines.append("config.json:")
        lines.append(redacted(config))
        lines.append("worker.json: url \(worker.workerURL ?? "none"), account \(worker.accountID ?? "none"), "
                     + "API token \(worker.apiToken == nil ? "not saved" : "saved"), password \(worker.ownerPassword == nil ? "not saved" : "saved")")
        if !checks.isEmpty {
            lines.append("")
            lines.append("doctor:")
            lines.append(Doctor.format(checks))
        }
        return lines.joined(separator: "\n")
    }

    /// The settings as JSON with the agent token replaced.
    public static func redacted(_ config: MiniRunConfig) -> String {
        var copy = config
        if let token = copy.agentToken, !token.isEmpty { copy.agentToken = "<redacted>" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(copy)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// Looks for a newer minirun on GitHub Releases. The menu links to it, and the app's updater
/// installs its zip (see `Updater`).
public enum UpdateCheck {
    public struct Release: Equatable, Sendable {
        public var version: String
        /// The release's page on GitHub.
        public var url: String
        /// minirun-<version>.zip, if the release has one.
        public var asset: Asset?

        public init(version: String, url: String, asset: Asset? = nil) {
            self.version = version
            self.url = url
            self.asset = asset
        }
    }

    public struct Asset: Equatable, Sendable {
        public var name: String
        public var downloadURL: String
        /// The zip's SHA-256 (hex), from GitHub's asset digest, if it reports one.
        public var sha256: String?
        /// minirun-<version>.zip.sha256, which the release workflow attaches too.
        public var checksumURL: String?
    }

    /// Whether `tag` ("v0.3.0" or "0.3.0") is a later version than `current`.
    public static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int]? {
            var text = version.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("v") { text.removeFirst() }
            // Pre-releases ("0.3.0-beta.1") don't count as newer.
            guard !text.contains("-") else { return nil }
            let numbers = text.split(separator: ".").map { Int($0) }
            guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
            return numbers.map { $0! }
        }
        guard let new = parts(tag), let old = parts(current) else { return false }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0, b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// The latest release if it's newer than `current`, nil if not (or if there are no releases).
    public static func newer(than current: String, repository: String = MiniRun.repository, transport: HTTPTransport) async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("minirun/\(current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (status, body) = try await transport.send(request)
        if status == 404 { return nil }
        guard status == 200, let json = try? JSONValue.parse(body) else {
            throw ToolError("GitHub answered \(status) when asked for the latest release.")
        }
        return release(json, newerThan: current, repository: repository)
    }

    /// Reads GitHub's release JSON. Nil unless it's a newer, non-draft release.
    static func release(_ json: JSONValue, newerThan current: String, repository: String) -> Release? {
        guard let tag = json["tag_name"]?.stringValue, json["draft"]?.boolValue != true, json["prerelease"]?.boolValue != true,
              isNewer(tag, than: current) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = json["assets"]?.arrayValue ?? []
        func named(_ name: String) -> JSONValue? { assets.first { $0["name"]?.stringValue == name } }
        let zipName = "minirun-\(version).zip"
        var asset: Asset?
        if let zip = named(zipName), let download = zip["browser_download_url"]?.stringValue {
            let digest = zip["digest"]?.stringValue.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }
            asset = Asset(name: zipName, downloadURL: download, sha256: digest,
                          checksumURL: named(zipName + ".sha256")?["browser_download_url"]?.stringValue)
        }
        let url = json["html_url"]?.stringValue ?? "https://github.com/\(repository)/releases/latest"
        return Release(version: version, url: url, asset: asset)
    }
}

/// The decisions behind the app's self-update, kept pure so they're tested on Linux. The app
/// downloads, verifies and swaps the bundle (App/Sources/AppUpdater.swift).
public enum Updater {
    /// How often the app looks for a release while it updates itself.
    public static let checkInterval: TimeInterval = 3600

    public enum Decision: Equatable, Sendable {
        case nothing
        /// Install now.
        case install(UpdateCheck.Release)
        /// Not now; says why, and the app tries again at the next poll.
        case wait(String)
        /// A newer release exists but can't be installed from here; link to it instead.
        case manual(String)
    }

    /// Whether to install `release` now. Updating restarts `minirun serve`, so it waits while a
    /// job runs or someone watches or drives a simulator.
    public static func decide(release: UpdateCheck.Release?, automatic: Bool, status: ServeStatus?, appInstalled: Bool) -> Decision {
        guard let release else { return .nothing }
        guard appInstalled else { return .manual("This copy of minirun isn't in /Applications, so it doesn't update itself.") }
        guard release.asset != nil else { return .manual("minirun \(release.version) has no app download attached.") }
        guard automatic else { return .manual("Automatic updates are off.") }
        if let status {
            let jobs = status.jobs.filter { $0.finishedAt == nil }.count
            if jobs > 0 { return .wait("waiting for \(jobs) running job\(jobs == 1 ? "" : "s") to finish") }
            if status.simulators.contains(where: \.busy) { return .wait("waiting until nobody is using a simulator") }
        }
        return .install(release)
    }

    /// The hash in a `shasum -a 256` line ("<hex>  minirun-0.3.0.zip").
    public static func checksum(fromShasum text: String) -> String? {
        guard let first = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first else { return nil }
        let hex = first.lowercased()
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
    }

    /// What's wrong with an unzipped update, from its Info.plist, or nil if it's the app we expect.
    public static func problem(infoPlist: [String: Any], expectedVersion: String, hasHelper: Bool) -> String? {
        let id = infoPlist["CFBundleIdentifier"] as? String
        guard id == "dev.minirun.menu" else { return "The download isn't the minirun app (bundle id \(id ?? "missing"))." }
        let version = infoPlist["CFBundleShortVersionString"] as? String
        guard version == expectedVersion else { return "The download is version \(version ?? "unknown"), not \(expectedVersion)." }
        guard hasHelper else { return "The download has no Contents/Helpers/minirun." }
        return nil
    }

    /// The Worker should be updated without asking: automatic updates are on, it runs other code
    /// than the app carries, and there's a saved API token to deploy with.
    public static func shouldUpdateWorker(automatic: Bool, outdated: Bool, hasToken: Bool) -> Bool {
        automatic && outdated && hasToken
    }
}

/// A notification the menu bar app posts.
public struct AppNotification: Equatable, Sendable {
    public var id: String
    public var title: String
    public var body: String

    public init(id: String, title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }
}

/// Decides when to notify, from one status poll after another: the relay has been down for a
/// while (once per outage), or a job failed. Nothing from the first poll, so opening the app
/// doesn't replay old failures.
public struct NotificationRules: Sendable {
    public static let outageDelay: TimeInterval = 5 * 60

    private var primed = false
    private var notifiedOutage = false
    private var seenFinished = Set<String>()

    public init() {}

    public mutating func notifications(for status: ServeStatus?, now: Date) -> [AppNotification] {
        guard let status else { return [] }
        var out: [AppNotification] = []

        let relay = status.relay
        if relay.state == .connected {
            notifiedOutage = false
        } else if !notifiedOutage, now.timeIntervalSince(relay.since) >= Self.outageDelay, relay.state == .disconnected {
            notifiedOutage = true
            out.append(AppNotification(
                id: "relay-down", title: "minirun is offline",
                body: "Disconnected from \(relay.host ?? "the relay") for \(ServeStatus.duration(now.timeIntervalSince(relay.since)))."
                    + (relay.problem.map { " \($0)" } ?? " Claude can't reach this Mac.")
            ))
        }

        for job in status.jobs where job.finishedAt != nil && !seenFinished.contains(job.id) {
            seenFinished.insert(job.id)
            if primed && job.status == JobStore.Status.failed.rawValue {
                out.append(AppNotification(id: "job-\(job.id)", title: "Job failed", body: job.title))
            }
        }
        primed = true
        return out
    }
}

/// The steps of the first-run window, and the live checklist it shows while deploying.
public enum Setup {
    /// The first-run window opens when there's no relay to connect to.
    public static func needed(_ config: MiniRunConfig) -> Bool {
        config.relayURL?.isEmpty != false || config.agentToken?.isEmpty != false
    }

    public enum Step: Int, CaseIterable, Sendable {
        case prerequisites, cloudflare, claude, github, macApps, headless

        public var title: String {
            switch self {
            case .prerequisites: return "Check this Mac"
            case .cloudflare: return "Deploy the Worker"
            case .claude: return "Connect Claude"
            case .github: return "GitHub (optional)"
            case .macApps: return "macOS apps (optional)"
            case .headless: return "Running unattended"
            }
        }
    }

    /// The doctor checks the first step shows: the ones that need fixing before anything works.
    public static let prerequisiteChecks: Set<String> = ["xcode", "frameworks", "simulators"]

    /// The doctor checks the macOS apps step shows (Screen Recording, Accessibility, Display).
    public static let macAppChecks: [String] = Doctor.macCheckIDs

    /// The macOS apps step's rows: worked out from the daemon's latest status (polled, so it turns
    /// green soon after a grant), or else its checks from the doctor. Empty when neither says (an
    /// older daemon, or not checked yet).
    public static func macAppRows(checks: [DoctorCheck], permissions: MacPermissionReport?) -> [DoctorCheck] {
        if let permissions { return Doctor.macChecks(permissions) }
        return macAppChecks.compactMap { id in checks.first { $0.id == id } }
    }

    /// Claude has connected: it made a tool call after `since` (when this step opened).
    public static func claudeConnected(_ relay: ServeStatus.Relay?, since: Date) -> Bool {
        guard let call = relay?.lastCallAt else { return false }
        return call >= since
    }

    /// Rows of the deploy checklist. Each progress message starts a row and finishes the one before.
    public struct Checklist: Equatable, Sendable {
        public enum State: Equatable, Sendable { case running, done, failed(String) }

        public struct Row: Equatable, Sendable, Identifiable {
            public var title: String
            public var state: State
            public var id: String { title }
        }

        public private(set) var rows: [Row] = []

        public init() {}

        public mutating func advance(_ title: String) {
            if let last = rows.indices.last, rows[last].state == .running { rows[last].state = .done }
            if let existing = rows.firstIndex(where: { $0.title == title }) {
                rows[existing].state = .running
            } else {
                rows.append(Row(title: title, state: .running))
            }
        }

        public mutating func finish() {
            for index in rows.indices where rows[index].state == .running { rows[index].state = .done }
        }

        public mutating func fail(_ message: String) {
            if let last = rows.indices.last, rows[last].state == .running {
                rows[last].state = .failed(message)
            } else {
                rows.append(Row(title: "Deploy", state: .failed(message)))
            }
        }
    }
}

/// System Settings panes the setup window links to.
public enum SystemSettingsLinks {
    /// Users & Groups, where automatic login is turned on.
    public static let automaticLogin = "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension"
    /// Energy (or Battery on a laptop), where sleep is turned off.
    public static let energy = "x-apple.systempreferences:com.apple.Energy-Settings.extension"
    /// Login Items, where "Open at login" can be checked if it didn't take.
    public static let loginItems = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    /// Privacy & Security → Screen Recording, for macOS app screenshots and the live view.
    public static let screenRecording = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    /// Privacy & Security → Accessibility, for reading and driving macOS apps' UI.
    public static let accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
}
