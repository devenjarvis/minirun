import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Self-hosted GitHub Actions runners that `scripts/github-runner.sh` installed on this Mac, one per
/// repository in `~/.minirun/github-runner/<owner>-<repo>/`. The script does the installing,
/// starting, stopping and removing; this reads what it left behind (plus launchd's and GitHub's
/// view) so the menu bar app can show it. Plain values and parsers, tested on Linux.
public struct GitHubRunner: Equatable, Sendable, Identifiable {
    /// The runner's LaunchAgent, as launchd reports it.
    public enum Service: Equatable, Sendable {
        case running
        /// Installed but not loaded, or loaded and not running.
        case stopped
        /// `svc.sh install` never ran (an interrupted install).
        case none
        /// Another launchd state, such as "waiting" or "spawn scheduled".
        case other(String)
    }

    /// The runner as GitHub sees it. Nil when gh couldn't say.
    public struct Remote: Equatable, Sendable {
        public var online: Bool
        public var busy: Bool

        public init(online: Bool, busy: Bool) {
            self.online = online
            self.busy = busy
        }
    }

    public var repo: String
    public var directory: String
    /// `config.sh` registered it (`.runner` exists).
    public var configured: Bool
    /// The name it registered as, e.g. "mac-mini-minirun".
    public var name: String?
    public var serviceLabel: String?
    public var service: Service
    public var remote: Remote?

    public var id: String { directory }

    public init(repo: String, directory: String, configured: Bool, name: String?, serviceLabel: String?,
                service: Service = .none, remote: Remote? = nil) {
        self.repo = repo
        self.directory = directory
        self.configured = configured
        self.name = name
        self.serviceLabel = serviceLabel
        self.service = service
        self.remote = remote
    }

    /// Where the runner writes its own logs.
    public var diagnosticsPath: String { directory + "/_diag" }

    /// The repository's runner list on GitHub.
    public var settingsURL: String { "https://github.com/\(repo)/settings/actions/runners" }

    /// A one-word state for a badge: busy, idle, offline, stopped or broken.
    public var badge: Badge {
        guard configured else { return .broken }
        switch service {
        case .none: return .broken
        case .stopped: return .stopped
        case .running, .other:
            guard let remote else { return service == .running ? .running : .starting }
            if !remote.online { return .offline }
            return remote.busy ? .busy : .idle
        }
    }

    public enum Badge: String, Sendable {
        case busy, idle, offline, stopped, starting, running, broken
    }

    /// "service running · GitHub: online, idle"
    public var detail: String {
        guard configured else { return "not registered: an install was interrupted. Remove it and add it again." }
        let service: String
        switch self.service {
        case .running: service = "service running"
        case .stopped: service = "service stopped"
        case .none: service = "no service installed"
        case .other(let state): service = "service \(state)"
        }
        let github = remote.map { "GitHub: " + ($0.online ? "online" : "offline") + ($0.busy ? ", running a job" : ", idle") } ?? "GitHub: unknown"
        return [name, service, github].compactMap { $0 }.joined(separator: " · ")
    }

    public var canStart: Bool { configured && serviceLabel != nil && service != .running }
    public var canStop: Bool { configured && serviceLabel != nil && service != .stopped && service != .none }
}

public enum GitHubRunners {
    /// Where the script installs runners.
    public static var root: String { MiniRunConfig.home + "/.minirun/github-runner" }

    /// The labels a workflow targets this Mac with.
    public static let runsOn = "runs-on: [self-hosted, macOS, minirun]"

    /// The script exits with this when it refuses a public repository without `--allow-public`.
    public static let publicRefusalExitCode: Int32 = 3

    /// Why a public repository needs a second look, shown before registering anyway.
    public static func publicWarning(_ repo: String) -> String {
        """
        \(repo) is public. A self-hosted runner runs workflow code from pull requests on this Mac, as you, \
        with access to your files, your gh login and minirun's secrets in ~/.config/minirun. Anyone can open \
        a pull request from a fork.

        Before registering, set the repository's Settings → Actions → General → "Fork pull request workflows \
        from outside collaborators" to "Require approval for all outside collaborators" (or stricter), and \
        read fork pull requests before approving their workflow runs.
        """
    }

    public static func isValidRepo(_ repo: String) -> Bool {
        repo.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
    }

    /// "github.com/owner/repo", "https://github.com/owner/repo.git" or " owner/repo " → "owner/repo".
    public static func normalizeRepo(_ input: String) -> String {
        var repo = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "github.com/", "www.github.com/"] where repo.lowercased().hasPrefix(prefix) {
            repo = String(repo.dropFirst(prefix.count))
        }
        while repo.hasSuffix("/") { repo.removeLast() }
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        return repo
    }

    /// The runners installed under `root`, without launchd's or GitHub's view.
    public static func installed(root: String = GitHubRunners.root, fileManager: FileManager = .default) -> [GitHubRunner] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }
        return names.sorted().compactMap { name -> GitHubRunner? in
            let dir = root + "/" + name
            var isDir: ObjCBool = false
            guard !name.hasPrefix("."), fileManager.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return nil }
            let repo = read(dir + "/.minirun-repo") ?? name
            let runnerFile = fileManager.contents(atPath: dir + "/.runner")
            return GitHubRunner(
                repo: repo, directory: dir, configured: runnerFile != nil,
                name: runnerFile.flatMap(agentName), serviceLabel: read(dir + "/.service").map(serviceLabel)
            )
        }
    }

    /// The name in the runner's `.runner` file, which config.sh writes as JSON (often with a BOM).
    public static func agentName(_ data: Data) -> String? {
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["agentName"] as? String
    }

    /// svc.sh saves the LaunchAgent's plist path in `.service`; the label is its file name.
    public static func serviceLabel(_ plistPath: String) -> String {
        let file = (plistPath as NSString).lastPathComponent
        return file.hasSuffix(".plist") ? String(file.dropLast(6)) : file
    }

    /// The top-level `state = …` line of `launchctl print gui/<uid>/<label>`. A failed print
    /// (exit code non-zero) means the service isn't loaded.
    public static func service(launchctlExitCode: Int32, output: String) -> GitHubRunner.Service {
        guard launchctlExitCode == 0 else { return .stopped }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) where line.hasPrefix("\tstate = ") {
            let state = line.dropFirst("\tstate = ".count).trimmingCharacters(in: .whitespaces)
            switch state {
            case "running": return .running
            case "not running": return .stopped
            default: return .other(state)
            }
        }
        return .stopped
    }

    /// GitHub's view of the runner named `name`, from `gh api repos/<repo>/actions/runners`.
    public static func remote(named name: String, in json: Data) -> GitHubRunner.Remote? {
        struct List: Decodable {
            struct Runner: Decodable { var name: String; var status: String; var busy: Bool }
            var runners: [Runner]
        }
        guard let list = try? JSONDecoder().decode(List.self, from: json),
              let runner = list.runners.first(where: { $0.name == name }) else { return nil }
        return GitHubRunner.Remote(online: runner.status == "online", busy: runner.busy)
    }

    /// The command a failed script run suggests ("Run: gh auth login --scopes repo"), so the app
    /// can offer to run it in Terminal.
    public static func suggestedCommand(in output: String) -> String? {
        for line in output.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Run: ") {
                let command = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if command.hasPrefix("gh ") || command.hasPrefix("brew ") { return command }
            }
        }
        return nil
    }

    /// PATH for gh and the script when launched from the app, which inherits launchd's short PATH.
    public static var searchPath: String {
        let current = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return "/opt/homebrew/bin:/usr/local/bin:" + current
    }

    // MARK: Live

    /// The installed runners with launchd's state and, unless `remote` is false, GitHub's.
    public static func status(root: String = GitHubRunners.root, remote: Bool = true) async -> [GitHubRunner] {
        var runners = installed(root: root)
        let uid = String(getuid())
        for index in runners.indices {
            if let label = runners[index].serviceLabel,
               let result = try? await Shell.run("/bin/launchctl", ["print", "gui/\(uid)/\(label)"], timeout: 10) {
                runners[index].service = service(launchctlExitCode: result.exitCode, output: result.stdout)
            }
            if remote, runners[index].configured, let name = runners[index].name,
               let result = try? await Shell.run("gh", ["api", "repos/\(runners[index].repo)/actions/runners?per_page=100"],
                                                 environment: ["PATH": searchPath], timeout: 20),
               result.succeeded {
                runners[index].remote = self.remote(named: name, in: Data(result.stdout.utf8))
            }
        }
        return runners
    }

    /// What the script can be asked to do.
    public enum Command: Equatable, Sendable {
        case install(repo: String, allowPublic: Bool)
        case uninstall(repo: String)
        case start(repo: String)
        case stop(repo: String)

        public var arguments: [String] {
            switch self {
            case .install(let repo, let allowPublic): return ["install", repo] + (allowPublic ? ["--allow-public"] : [])
            case .uninstall(let repo): return ["uninstall", repo]
            case .start(let repo): return ["start", repo]
            case .stop(let repo): return ["stop", repo]
            }
        }

        public var repo: String {
            switch self {
            case .install(let repo, _), .uninstall(let repo), .start(let repo), .stop(let repo): return repo
            }
        }

        /// Downloading and registering can take a few minutes on a slow connection.
        public var timeout: TimeInterval {
            if case .install = self { return 900 }
            return 120
        }
    }

    /// Runs `script` (github-runner.sh) for `command`, appending its output to `logURL` as it comes.
    public static func run(script: String, _ command: Command, logURL: URL? = nil) async throws -> ShellResult {
        try await Shell.run("/bin/bash", [script] + command.arguments,
                            environment: ["PATH": searchPath, "NO_COLOR": "1"], timeout: command.timeout, logURL: logURL)
    }

    private static func read(_ path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
