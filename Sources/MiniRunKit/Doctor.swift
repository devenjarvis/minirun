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

/// What macOS allows `minirun serve` to do with macOS apps. Read on the Mac by the daemon itself,
/// because permissions are granted per program.
public struct MacPermissionReport: Codable, Equatable, Sendable {
    /// Screen Recording, for window screenshots and the live view.
    public var screenRecording: Bool
    /// Accessibility, for reading the UI and sending clicks and keys.
    public var accessibility: Bool
    /// A display is active, so windows draw and can be captured.
    public var hasDisplay: Bool
    /// The program the permissions belong to, e.g. /Applications/minirun.app/Contents/Helpers/minirun.
    public var binaryPath: String?

    public init(screenRecording: Bool, accessibility: Bool, hasDisplay: Bool, binaryPath: String? = nil) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.hasDisplay = hasDisplay
        self.binaryPath = binaryPath
    }

    public var allGranted: Bool { missing.isEmpty }

    /// What's missing, for a sentence: ["Screen Recording", "Accessibility", "an active display"].
    public var missing: [String] {
        [screenRecording ? nil : "Screen Recording", accessibility ? nil : "Accessibility", hasDisplay ? nil : "an active display"].compactMap { $0 }
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
    /// The running `minirun serve`'s status, or nil if it isn't answering. Leave the closure out
    /// to skip that check, as `minirun serve` does when it runs the checks itself for host_info.
    public var serveStatus: (@Sendable () async -> ServeStatus?)?
    /// The macOS app permissions of `minirun serve`, or nil when they can't be read here. Leave the
    /// closure out to skip those checks.
    public var macPermissions: (@Sendable () async -> MacPermissionReport?)?

    public static let kickstart = "launchctl kickstart -k gui/$(id -u)/\(LaunchAgent.label)"

    public init(run: @escaping Runner = Doctor.shell, loadFrameworks: @escaping @Sendable () async -> String?, serveStatus: (@Sendable () async -> ServeStatus?)? = nil,
                macPermissions: (@Sendable () async -> MacPermissionReport?)? = nil) {
        self.run = run
        self.loadFrameworks = loadFrameworks
        self.serveStatus = serveStatus
        self.macPermissions = macPermissions
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

        if let serveStatus, let status = await serveStatus() {
            let relay = status.relay
            let connected = relay.state == .connected
            let state = connected ? "connected to the relay" : relay.state.rawValue + (relay.problem.map { ": \($0)" } ?? "")
            checks.append(DoctorCheck(
                id: "serve", title: "minirun serve", ok: connected, detail: "running (pid \(status.pid)), \(state)",
                fix: connected ? nil : (relay.problem == nil ? "Wait a few seconds; it reconnects by itself." : "Check the relay URL and agent token, then: minirun worker deploy")
            ))
        } else if serveStatus != nil {
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

        if let macPermissions, let report = await macPermissions() {
            checks += Self.macChecks(report)
        }
        return checks
    }

    /// The doctor check ids for macOS apps. None of them is needed for iOS apps.
    public static let macCheckIDs: [String] = ["screen-recording", "accessibility", "display"]

    /// Screen Recording, Accessibility and Display. They are optional: failing ones are warnings
    /// that say they're only needed for macOS apps, and exactly how to fix them.
    public static func macChecks(_ report: MacPermissionReport) -> [DoctorCheck] {
        let binary = report.binaryPath ?? "/Applications/minirun.app/Contents/Helpers/minirun"
        func grant(_ pane: String, _ use: String) -> String {
            "System Settings → Privacy & Security → \(pane): turn on minirun, or click + and add \(binary). "
                + "Or use Set Up minirun… → macOS apps → Request Access in the menu bar app. "
                + "minirun's builds are ad-hoc signed, so if \(use) stops working after updating minirun, "
                + "remove minirun from the list and add it again, then restart minirun serve."
        }
        return [
            DoctorCheck(
                id: "screen-recording", title: "Screen Recording (for macOS apps)", ok: report.screenRecording,
                detail: report.screenRecording ? "granted" : "not granted; needed for macOS apps only (screenshots and the live view of their windows)",
                fix: report.screenRecording ? nil : grant("Screen Recording", "screenshots"), optional: true
            ),
            DoctorCheck(
                id: "accessibility", title: "Accessibility (for macOS apps)", ok: report.accessibility,
                detail: report.accessibility ? "granted" : "not granted; needed for macOS apps only (describe_ui, tap, typing and menus)",
                fix: report.accessibility ? nil : grant("Accessibility", "tapping or typing"), optional: true
            ),
            DoctorCheck(
                id: "display", title: "Display (for macOS apps)", ok: report.hasDisplay,
                detail: report.hasDisplay ? "active" : "no active display; needed for macOS apps only (their windows can't be captured without one)",
                fix: report.hasDisplay ? nil : "A headless Mac mini needs a logged-in user and a display: turn on automatic login (System Settings → Users & Groups), "
                    + "then connect a display or an HDMI dummy plug.",
                optional: true
            ),
        ]
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
