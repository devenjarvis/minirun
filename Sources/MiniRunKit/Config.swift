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

    public init(
        relayURL: String? = nil,
        agentToken: String? = nil,
        workspaceRoot: String = MiniRunConfig.defaultWorkspaceRoot,
        defaultDevice: String? = nil,
        allowShell: Bool = false,
        preventSleep: Bool = true,
        gitURLTemplate: String = "https://github.com/{repo}.git",
        idleShutdownMinutes: Int = 30,
        maxBootedSimulators: Int = 4
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

    public static func load() -> MiniRunConfig {
        guard let data = try? Data(contentsOf: configURL), let config = try? JSONDecoder().decode(MiniRunConfig.self, from: data) else {
            return MiniRunConfig()
        }
        return config
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
