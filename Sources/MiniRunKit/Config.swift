import Foundation

/// Settings stored at `~/.config/minirun/config.json`.
public struct MiniRunConfig: Codable, Sendable, Equatable {
    /// WebSocket URL of the Worker's agent endpoint, e.g. wss://minirun.you.workers.dev/agent
    public var relayURL: String?
    /// Shared secret matching the Worker's AGENT_TOKEN secret.
    public var agentToken: String?
    /// Where repositories are cloned and built.
    public var workspaceRoot: String
    /// Simulator name to boot when nothing is booted, e.g. "iPhone 17 Pro".
    public var defaultDevice: String?
    /// Allows the `run_command` tool (arbitrary shell commands inside workspaces).
    public var allowShell: Bool
    /// Keeps the Mac awake while connected to the relay.
    public var preventSleep: Bool
    /// Clone URL template; `{repo}` becomes "owner/name".
    public var gitURLTemplate: String
    /// Shuts down a simulator nobody has used for this many minutes (0 keeps them running).
    /// The most recently used one stays booted as a spare, with its reservation released.
    public var idleShutdownMinutes: Int
    /// How many simulators minirun keeps booted at once before it asks for one to be freed.
    public var maxBootedSimulators: Int
    /// Lets `screenshot {share}` and `stop_recording` upload to the Worker for PR descriptions.
    public var shareMedia: Bool
    /// How long shared media lives before the Worker's KV deletes it (see `mediaRetentionSeconds`).
    public var mediaRetentionDays: Int
    /// The oldest shared media is deleted before an upload would go over this.
    public var mediaStorageLimitMB: Int
    /// Recordings stop by themselves after this long (see `recordingSecondsLimit`).
    public var maxRecordingSeconds: Int
    /// The largest GIF to embed in a PR; recordings are shrunk to fit.
    public var mediaInlineLimitMB: Int

    public init(
        relayURL: String? = nil,
        agentToken: String? = nil,
        workspaceRoot: String = MiniRunConfig.defaultWorkspaceRoot,
        defaultDevice: String? = nil,
        allowShell: Bool = false,
        preventSleep: Bool = true,
        gitURLTemplate: String = "https://github.com/{repo}.git",
        idleShutdownMinutes: Int = 30,
        maxBootedSimulators: Int = 4,
        shareMedia: Bool = true,
        mediaRetentionDays: Int = 7,
        mediaStorageLimitMB: Int = 500,
        maxRecordingSeconds: Int = 60,
        mediaInlineLimitMB: Int = 5
    ) {
        self.relayURL = relayURL
        self.agentToken = agentToken
        self.workspaceRoot = workspaceRoot
        self.defaultDevice = defaultDevice
        self.allowShell = allowShell
        self.preventSleep = preventSleep
        self.gitURLTemplate = gitURLTemplate
        self.idleShutdownMinutes = idleShutdownMinutes
        self.maxBootedSimulators = maxBootedSimulators
        self.shareMedia = shareMedia
        self.mediaRetentionDays = mediaRetentionDays
        self.mediaStorageLimitMB = mediaStorageLimitMB
        self.maxRecordingSeconds = maxRecordingSeconds
        self.mediaInlineLimitMB = mediaInlineLimitMB
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        relayURL = try c.decodeIfPresent(String.self, forKey: .relayURL)
        agentToken = try c.decodeIfPresent(String.self, forKey: .agentToken)
        workspaceRoot = try c.decodeIfPresent(String.self, forKey: .workspaceRoot) ?? MiniRunConfig.defaultWorkspaceRoot
        defaultDevice = try c.decodeIfPresent(String.self, forKey: .defaultDevice)
        allowShell = try c.decodeIfPresent(Bool.self, forKey: .allowShell) ?? false
        preventSleep = try c.decodeIfPresent(Bool.self, forKey: .preventSleep) ?? true
        gitURLTemplate = try c.decodeIfPresent(String.self, forKey: .gitURLTemplate) ?? "https://github.com/{repo}.git"
        idleShutdownMinutes = try c.decodeIfPresent(Int.self, forKey: .idleShutdownMinutes) ?? 30
        maxBootedSimulators = try c.decodeIfPresent(Int.self, forKey: .maxBootedSimulators) ?? 4
        shareMedia = try c.decodeIfPresent(Bool.self, forKey: .shareMedia) ?? true
        mediaRetentionDays = try c.decodeIfPresent(Int.self, forKey: .mediaRetentionDays) ?? 7
        mediaStorageLimitMB = try c.decodeIfPresent(Int.self, forKey: .mediaStorageLimitMB) ?? 500
        maxRecordingSeconds = try c.decodeIfPresent(Int.self, forKey: .maxRecordingSeconds) ?? 60
        mediaInlineLimitMB = try c.decodeIfPresent(Int.self, forKey: .mediaInlineLimitMB) ?? 5
    }

    // The media settings as minirun uses them, kept within what the Worker and KV accept.
    public static let retentionDaysRange = 1...90
    public static let recordingSecondsRange = 5...300
    /// KV's largest value is 25 MiB.
    public static let inlineLimitMBRange = 1...25

    public var mediaRetentionSeconds: Int {
        min(Self.retentionDaysRange.upperBound, max(Self.retentionDaysRange.lowerBound, mediaRetentionDays)) * 86400
    }

    public var mediaStorageLimitBytes: Int { max(1, mediaStorageLimitMB) * 1_048_576 }

    public var recordingSecondsLimit: Int {
        min(Self.recordingSecondsRange.upperBound, max(Self.recordingSecondsRange.lowerBound, maxRecordingSeconds))
    }

    public var mediaInlineLimitBytes: Int {
        min(Self.inlineLimitMBRange.upperBound, max(Self.inlineLimitMBRange.lowerBound, mediaInlineLimitMB)) * 1_048_576
    }

    public static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    public static var defaultWorkspaceRoot: String { home + "/minirun/workspaces" }
    public static var configURL: URL {
        if let override = ProcessInfo.processInfo.environment["MINIRUN_CONFIG"] { return URL(fileURLWithPath: override) }
        return URL(fileURLWithPath: home + "/.config/minirun/config.json")
    }

    /// Where `minirun serve` answers `minirun status` and the menu bar app.
    public static var controlSocketURL: URL {
        configURL.deletingLastPathComponent().appendingPathComponent("control.sock")
    }

    /// The saved settings, or the defaults if the file is missing or can't be read.
    public static func load() -> MiniRunConfig {
        (try? read()) ?? MiniRunConfig()
    }

    /// The saved settings. Unlike `load()`, a broken file is an error rather than the defaults,
    /// so a reload never swaps working settings for empty ones.
    public static func read(from url: URL = configURL) throws -> MiniRunConfig {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ToolError("Couldn't read \(url.path): \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(MiniRunConfig.self, from: data)
        } catch {
            throw ToolError("\(url.path) isn't valid settings JSON: \(error.localizedDescription)")
        }
    }

    public func save() throws {
        let url = MiniRunConfig.configURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
        // The file holds the agent token.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The browser link for watching a simulator live, derived from the relay URL
    /// (wss://minirun.you.workers.dev/agent -> https://minirun.you.workers.dev/?device=UDID).
    public func viewerURL(device: String?) -> String? {
        guard let relayURL, var components = URLComponents(string: relayURL), let host = components.host, !host.isEmpty else { return nil }
        components.scheme = components.scheme == "ws" ? "http" : "https"
        components.path = "/"
        components.queryItems = device.map { [URLQueryItem(name: "device", value: $0)] }
        return components.string
    }

    /// Where shared media is served, derived from the relay URL like `viewerURL`
    /// (wss://minirun.you.workers.dev/agent -> https://minirun.you.workers.dev).
    public var mediaBaseURL: String? {
        guard let relayURL, var components = URLComponents(string: relayURL), let host = components.host, !host.isEmpty else { return nil }
        components.scheme = components.scheme == "ws" ? "http" : "https"
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.string
    }

    /// Turns "owner/name", a full URL, or an ssh remote into (cloneURL, "owner/name").
    public func resolveRepo(_ repo: String) throws -> (url: String, slug: String) {
        let trimmed = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") || trimmed.hasPrefix("git@") {
            var path = trimmed
            if let range = path.range(of: "://") { path = String(path[range.upperBound...]) }
            if path.hasPrefix("git@") { path = String(path.dropFirst(4)).replacingOccurrences(of: ":", with: "/") }
            let components = path.split(separator: "/").map(String.init)
            guard components.count >= 3 else { throw ToolError("Could not understand repository \(repo).") }
            var name = components[components.count - 1]
            if name.hasSuffix(".git") { name.removeLast(4) }
            return (trimmed, "\(components[components.count - 2])/\(name)")
        }
        let parts = trimmed.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && !$0.contains("..") }) else {
            throw ToolError("Give the repository as owner/name or a full clone URL, not \(repo).")
        }
        let slug = parts.joined(separator: "/")
        return (gitURLTemplate.replacingOccurrences(of: "{repo}", with: slug), slug)
    }
}
