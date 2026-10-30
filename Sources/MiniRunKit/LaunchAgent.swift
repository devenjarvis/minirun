import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The LaunchAgent that runs `minirun serve`: a plain plist in ~/Library/LaunchAgents, written by
/// `minirun agent install` (which install.sh and the menu bar app run). launchd starts it at login
/// and restarts it if it crashes.
public enum LaunchAgent {
    public static let label = "dev.minirun.agent"
    public static var plistPath: String { MiniRunConfig.home + "/Library/LaunchAgents/\(label).plist" }
    public static var logPath: String { MiniRunConfig.home + "/Library/Logs/minirun/minirun.log" }
    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }
    /// Where install.sh put the daemon before the menu bar app carried it.
    public static var legacyProgram: String { MiniRunConfig.home + "/.minirun/bin/minirun" }
    /// launchd starts the daemon with a bare PATH; Homebrew's tools (git, gh, xcodegen) live here.
    public static let path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// The `launchctl` arguments that start the daemon, or restart it if `restart` is set.
    public static func kickstartArguments(uid: UInt32, restart: Bool) -> [String] {
        ["kickstart"] + (restart ? ["-k"] : []) + ["gui/\(uid)/\(label)"]
    }

    /// Starts (or restarts) `minirun serve` through launchd. Throws with launchctl's output if it fails.
    public static func kickstart(restart: Bool) async throws {
        guard isInstalled else {
            throw ToolError("minirun serve isn't installed (no \(plistPath)). Open the minirun app, or run ./scripts/install.sh from the minirun repository.")
        }
        try await Shell.check("/bin/launchctl", kickstartArguments(uid: UInt32(getuid()), restart: restart), timeout: 30, what: "launchctl kickstart")
    }

    /// The last `lines` lines of a log file, or nil if it can't be read.
    public static func tail(_ path: String = logPath, lines: Int = 20) -> String? {
        JobStore.logTail(path, lines: lines)
    }

    // MARK: The plist

    /// The LaunchAgent plist that runs `program serve`.
    public static func plist(program: String, log: String = logPath) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array><string>\(xmlEscaped(program))</string><string>serve</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>ThrottleInterval</key><integer>10</integer>
          <key>ProcessType</key><string>Interactive</string>
          <key>EnvironmentVariables</key><dict>
            <key>PATH</key><string>\(path)</string>
          </dict>
          <key>StandardOutPath</key><string>\(xmlEscaped(log))</string>
          <key>StandardErrorPath</key><string>\(xmlEscaped(log))</string>
        </dict>
        </plist>

        """
    }

    /// The program an installed plist runs (the first of its ProgramArguments), or nil if it can't be read.
    public static func program(inPlist text: String) -> String? {
        guard let object = try? PropertyListSerialization.propertyList(from: Data(text.utf8), options: [], format: nil),
              let dict = object as? [String: Any], let arguments = dict["ProgramArguments"] as? [String] else { return nil }
        return arguments.first
    }

    static func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: Installing

    /// What to do about the LaunchAgent so it runs `helper`.
    public enum Plan: Equatable, Sendable {
        /// It already runs this helper.
        case upToDate
        /// There's no LaunchAgent yet.
        case install
        /// It runs another copy of minirun (an old install, or a copy that's gone). Point it here.
        case repoint(from: String)
        /// It runs another copy that still exists, and this app isn't installed in an Applications
        /// folder (a development build, say), so leave it alone.
        case leave(other: String)
    }

    /// Decides what the menu bar app does at launch. `installedProgram` is what the current plist
    /// runs (nil if there's no plist; "" if it can't be read). A copy of the app outside an
    /// Applications folder never takes over a working install, so running a build from Xcode
    /// doesn't repoint the daemon at a build folder.
    public static func plan(installedProgram: String?, helper: String, helperIsInstalled: Bool,
                            exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> Plan {
        guard let installed = installedProgram else { return .install }
        let current = standardized(installed), wanted = standardized(helper)
        if current == wanted { return .upToDate }
        if helperIsInstalled || current.isEmpty || !exists(current) || current == standardized(legacyProgram) {
            return .repoint(from: installed)
        }
        return .leave(other: installed)
    }

    /// Whether an app bundle lives in /Applications or ~/Applications, where an install belongs.
    public static func isInApplicationsFolder(_ bundlePath: String) -> Bool {
        let parent = (standardized(bundlePath) as NSString).deletingLastPathComponent
        return parent == "/Applications" || parent == standardized(MiniRunConfig.home + "/Applications")
    }

    static func standardized(_ path: String) -> String {
        path.isEmpty ? "" : URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    /// The program the installed plist runs: nil if there's no plist, "" if it can't be read.
    public static func installedProgram() -> String? {
        guard let text = try? String(contentsOfFile: plistPath, encoding: .utf8) else { return nil }
        return program(inPlist: text) ?? ""
    }

    /// Writes the plist for `program` and (re)loads it, so launchd starts `program serve` now and
    /// at every login. Keeps settings and workspaces; only the plist changes.
    public static func install(program: String) async throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(plist(program: program).utf8).write(to: URL(fileURLWithPath: plistPath), options: .atomic)
        let domain = "gui/\(getuid())"
        // Not loaded is fine: bootout fails then, and bootstrap loads it fresh.
        _ = try? await Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], timeout: 30)
        try await bootstrap(domain)
    }

    /// bootstrap right after bootout can fail with "Input/output error" while launchd is still
    /// tearing the old job down, so it's retried for a few seconds.
    static func bootstrap(_ domain: String) async throws {
        var last: Error?
        for attempt in 0..<5 {
            if attempt > 0 { try await Task.sleep(nanoseconds: 1_000_000_000) }
            do {
                try await Shell.check("/bin/launchctl", ["bootstrap", domain, plistPath], timeout: 30, what: "launchctl bootstrap")
                return
            } catch {
                last = error
            }
        }
        throw last ?? ToolError("launchctl bootstrap failed.")
    }

    /// Stops the daemon and removes its plist.
    public static func uninstall() async {
        _ = try? await Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], timeout: 30)
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    /// Makes the LaunchAgent run `helper` if `plan` says so. Returns what it did for the user, or
    /// nil if nothing needed doing.
    public static func ensure(helper: String, helperIsInstalled: Bool) async throws -> String? {
        switch plan(installedProgram: installedProgram(), helper: helper, helperIsInstalled: helperIsInstalled) {
        case .upToDate, .leave:
            return nil
        case .install:
            try await install(program: helper)
            return "Started minirun serve. It runs at login from now on."
        case .repoint(let old):
            try await install(program: helper)
            let legacy = standardized(old) == standardized(legacyProgram)
            return legacy
                ? "minirun serve now runs from the app. The old copy in ~/.minirun/bin isn't used any more; delete it if you like."
                : "minirun serve now runs from this copy of the app."
        }
    }
}

/// The `minirun` command line tool: a symbolic link to the app's helper.
public enum CommandLineTool {
    public static let linkPath = "/usr/local/bin/minirun"

    /// Where the link points now, or nil if there's none.
    public static func currentTarget(_ path: String = linkPath) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    /// The shell command that makes the link. /usr/local/bin belongs to root on a fresh Mac, so it
    /// runs with an admin prompt.
    public static func installCommand(helper: String, link: String = linkPath) -> String {
        let dir = (link as NSString).deletingLastPathComponent
        return "mkdir -p \(shellQuoted(dir)) && ln -sf \(shellQuoted(helper)) \(shellQuoted(link))"
    }

    /// AppleScript that runs `command` as an administrator, asking for the password.
    public static func adminAppleScript(_ command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    public static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
