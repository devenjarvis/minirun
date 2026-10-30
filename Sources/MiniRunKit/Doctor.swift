import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One line of `minirun doctor`, and one row of the menu bar app's checklist.
public struct DoctorCheck: Codable, Equatable, Sendable {
    /// Stable name for the check, e.g. "xcode" or "relay".
    public var id: String
    public var title: String
    public var ok: Bool
    public var detail: String
    /// What to do about it, usually a command. Nil when there's nothing to do.
    public var fix: String?
    /// minirun works without it (e.g. GitHub auth for private repositories).
    public var optional: Bool

    public init(id: String, title: String, ok: Bool, detail: String, fix: String? = nil, optional: Bool = false) {
        self.id = id
        self.title = title
        self.ok = ok
        self.detail = detail
        self.fix = fix
        self.optional = optional
    }
}

/// The checks behind `minirun doctor` and the `doctor` control command. The parts that need
/// macOS or the simulator frameworks are passed in, so the logic is tested on Linux.
public struct Doctor: Sendable {
    /// Runs a program and returns its result, or nil if it couldn't be started.
    public typealias Runner = @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) async -> ShellResult?

    public var run: Runner
    /// Loads the simulator frameworks: nil when they load, otherwise the error.
    public var loadFrameworks: @Sendable () async -> String?
    /// The running `minirun serve`'s status, or nil if it isn't answering.
    public var serveStatus: @Sendable () async -> ServeStatus?

    public static let kickstart = "launchctl kickstart -k gui/$(id -u)/\(LaunchAgent.label)"

    public init(run: @escaping Runner = Doctor.shell, loadFrameworks: @escaping @Sendable () async -> String?, serveStatus: @escaping @Sendable () async -> ServeStatus?) {
        self.run = run
        self.loadFrameworks = loadFrameworks
        self.serveStatus = serveStatus
    }

    public static let shell: Runner = { executable, arguments, timeout in
        try? await Shell.run(executable, arguments, timeout: timeout)
    }

    public func checks(config: MiniRunConfig) async -> [DoctorCheck] {
        var checks: [DoctorCheck] = []

        let xcode = await run("/usr/bin/xcrun", ["xcodebuild", "-version"], 60)
        if let xcode, xcode.succeeded {
            checks.append(DoctorCheck(id: "xcode", title: "Xcode", ok: true, detail: xcode.stdout.split(separator: "\n").first.map(String.init) ?? "installed"))
        } else {
            let license = xcode.map { ($0.stdout + $0.stderr).contains("license") } ?? false
            checks.append(DoctorCheck(
                id: "xcode", title: "Xcode", ok: false,
                detail: license ? "the Xcode license hasn't been accepted" : "not found",
                fix: license ? "sudo xcodebuild -license accept" : "Install Xcode, open it once, then run: sudo xcode-select -s /Applications/Xcode.app"
            ))
        }

        if let error = await loadFrameworks() {
            checks.append(DoctorCheck(id: "frameworks", title: "Simulator frameworks", ok: false, detail: error, fix: "Rebuild and reinstall minirun: ./scripts/install.sh"))
        } else {
            checks.append(DoctorCheck(id: "frameworks", title: "Simulator frameworks", ok: true, detail: "loaded"))
        }

        if let list = await run("/usr/bin/xcrun", ["simctl", "list", "devices", "--json"], 60), list.succeeded,
           let devices = try? XcodeParsing.parseDevices(Data(list.stdout.utf8)) {
            let ios = devices.filter { $0.isAvailable && $0.runtime.contains("iOS") }
            let booted = ios.filter(\.isBooted).map(\.name)
            checks.append(DoctorCheck(
                id: "simulators", title: "Simulators", ok: !ios.isEmpty,
                detail: "\(ios.count) iOS simulators" + (booted.isEmpty ? "" : ", booted: \(booted.joined(separator: ", "))"),
                fix: ios.isEmpty ? "Install an iOS runtime: Xcode → Settings → Components" : nil
            ))
        } else {
            checks.append(DoctorCheck(id: "simulators", title: "Simulators", ok: false, detail: "simctl failed", fix: "Check that Xcode is installed and selected: xcode-select -p"))
        }

        if let status = await serveStatus() {
            let relay = status.relay
            let connected = relay.state == .connected
            let state = connected ? "connected to the relay" : relay.state.rawValue + (relay.problem.map { ": \($0)" } ?? "")
            checks.append(DoctorCheck(
                id: "serve", title: "minirun serve", ok: connected, detail: "running (pid \(status.pid)), \(state)",
                fix: connected ? nil : (relay.problem == nil ? "Wait a few seconds; it reconnects by itself." : "Check the relay URL and agent token, then: minirun worker deploy")
            ))
        } else {
            checks.append(DoctorCheck(id: "serve", title: "minirun serve", ok: false, detail: "not running", fix: Self.kickstart))
        }

        checks.append(DoctorCheck(
            id: "relay", title: "Relay URL", ok: config.relayURL != nil, detail: config.relayURL ?? "not set",
            fix: config.relayURL == nil ? "minirun worker deploy" : nil
        ))
        let hasToken = config.agentToken?.isEmpty == false
        checks.append(DoctorCheck(id: "token", title: "Agent token", ok: hasToken, detail: hasToken ? "set" : "not set", fix: hasToken ? nil : "minirun worker deploy"))

        let workspaces = Self.writable(config.workspaceRoot)
        checks.append(DoctorCheck(
            id: "workspaces", title: "Workspaces", ok: workspaces, detail: config.workspaceRoot + (workspaces ? "" : " can't be written"),
            fix: workspaces ? nil : "Pick a folder you own for workspaceRoot in ~/.config/minirun/config.json"
        ))
        checks.append(DoctorCheck(id: "shell", title: "run_command", ok: true, detail: config.allowShell ? "enabled" : "disabled"))

        let gh = await run("gh", ["auth", "status"], 20)
        checks.append(DoctorCheck(
            id: "github", title: "GitHub auth (for private repos)", ok: gh?.succeeded == true,
            detail: gh?.succeeded == true ? "gh is logged in" : "gh isn't logged in",
            fix: gh?.succeeded == true ? nil : "gh auth login && gh auth setup-git", optional: true
        ))
        return checks
    }

    /// Whether `path` is a folder that can be written, or could be created as one.
    static func writable(_ path: String) -> Bool {
        let fm = FileManager.default
        var current = path
        var isDirectory: ObjCBool = false
        while !fm.fileExists(atPath: current, isDirectory: &isDirectory) {
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return false }
            current = parent
        }
        return isDirectory.boolValue && fm.isWritableFile(atPath: current)
    }

    /// The text `minirun doctor` prints.
    public static func format(_ checks: [DoctorCheck]) -> String {
        checks.map { check in
            var line = "\(check.ok ? "✓" : (check.optional ? "-" : "✗")) \(check.title): \(check.detail)"
            if !check.ok, let fix = check.fix { line += "\n    \(check.optional ? "optional: " : "fix: ")\(fix)" }
            return line
        }.joined(separator: "\n")
    }
}

/// The LaunchAgent that runs `minirun serve` (written by scripts/install.sh).
public enum LaunchAgent {
    public static let label = "dev.minirun.agent"
    public static var plistPath: String { MiniRunConfig.home + "/Library/LaunchAgents/\(label).plist" }
    public static var logPath: String { MiniRunConfig.home + "/Library/Logs/minirun/minirun.log" }
    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    /// The `launchctl` arguments that start the daemon, or restart it if `restart` is set.
    public static func kickstartArguments(uid: UInt32, restart: Bool) -> [String] {
        ["kickstart"] + (restart ? ["-k"] : []) + ["gui/\(uid)/\(label)"]
    }

    /// Starts (or restarts) `minirun serve` through launchd. Throws with launchctl's output if it fails.
    public static func kickstart(restart: Bool) async throws {
        guard isInstalled else {
            throw ToolError("minirun serve isn't installed (no \(plistPath)). Run ./scripts/install.sh from the minirun repository.")
        }
        try await Shell.check("/bin/launchctl", kickstartArguments(uid: UInt32(getuid()), restart: restart), timeout: 30, what: "launchctl kickstart")
    }

    /// The last `lines` lines of a log file, or nil if it can't be read.
    public static func tail(_ path: String = logPath, lines: Int = 20) -> String? {
        JobStore.logTail(path, lines: lines)
    }
}
