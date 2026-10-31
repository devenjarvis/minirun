import Foundation

/// Turns a viewer's live touches on a Mac app's window into mouse input. The button only goes
/// down once the pointer has moved a few points (then it's a drag, posted as down, drags, up). A
/// touch that comes up where it went down is a click, which the caller performs as a whole: it
/// presses the control there through Accessibility, since SwiftUI controls ignore clicks posted
/// to the app.
public struct MacLiveMouse: Sendable {
    public struct Event: Equatable, Sendable {
        public let phase: String
        public let x: Double
        public let y: Double

        public init(_ phase: String, _ x: Double, _ y: Double) {
            self.phase = phase
            self.x = x
            self.y = y
        }
    }

    public enum Action: Equatable, Sendable {
        case none
        /// Mouse events to post, in order.
        case post([Event])
        /// A click at this window point.
        case click(x: Double, y: Double)
    }

    /// How far the pointer moves before a press becomes a drag, in points.
    public static let slop = 3.0

    /// Where a button is down but not posted yet, by app id.
    private var pressed: [String: (x: Double, y: Double)] = [:]
    /// Apps whose button is down and posted (a drag in progress).
    private var dragging: Set<String> = []

    public init() {}

    public mutating func step(id: String, phase: String, x: Double, y: Double) -> Action {
        switch phase {
        case "down":
            if dragging.remove(id) != nil { pressed[id] = (x, y); return .post([Event("up", x, y)]) }
            pressed[id] = (x, y)
            return .none
        case "move":
            if dragging.contains(id) { return .post([Event("move", x, y)]) }
            guard let start = pressed[id], abs(x - start.x) >= Self.slop || abs(y - start.y) >= Self.slop else { return .none }
            pressed[id] = nil
            dragging.insert(id)
            return .post([Event("down", start.x, start.y), Event("move", x, y)])
        case "up":
            if dragging.remove(id) != nil { return .post([Event("up", x, y)]) }
            guard let start = pressed.removeValue(forKey: id) else { return .none }
            return .click(x: start.x, y: start.y)
        default:
            return .none
        }
    }
}

/// The parts of the Mac app tools that are plain logic and text: argument parsing, routing and
/// the sentences results are made of. Kept here so they're tested on Linux.
public enum MacToolSupport {
    // MARK: Arguments

    /// The platform a build call asked for. Nil means "detect it from the scheme". A Mac app id as
    /// `device` means macos; a simulator as `device` means ios.
    public static func platform(argument: String?, device: String?) throws -> BuildPlatform? {
        if let argument = argument?.trimmingCharacters(in: .whitespaces).lowercased(), !argument.isEmpty {
            let normalized = ["macos": "macos", "mac": "macos", "osx": "macos", "ios": "ios", "mac-catalyst": "mac-catalyst",
                              "maccatalyst": "mac-catalyst", "catalyst": "mac-catalyst"][argument]
            guard let normalized, let platform = BuildPlatform(rawValue: normalized) else {
                throw ToolError("Unknown platform \(argument). Use ios, macos or mac-catalyst.")
            }
            if platform == .ios, MacAppID.isMacDevice(device) {
                throw ToolError("device \(device!) is a Mac app, but platform is ios. Leave device out to build for a simulator.")
            }
            if platform.isMac, let device, !device.isEmpty, !MacAppID.isMacDevice(device) {
                throw ToolError("device \(device) is a simulator, but platform is \(platform.rawValue). Leave device out (or pass your Mac app id) to build for the Mac.")
            }
            return platform
        }
        if MacAppID.isMacDevice(device) { return .macos }
        if let device, !device.isEmpty { return .ios }
        return nil
    }

    /// The `input` argument of Mac input tools: "pid" (default) or "hid". Nil when not given.
    public static func inputPath(_ argument: String?) throws -> String? {
        guard let value = argument?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return nil }
        guard value == "pid" || value == "hid" else { throw ToolError("Unknown input \(value). Use pid (the default) or hid.") }
        return value
    }

    /// A key and its modifiers for press_key. `key` may be a whole shortcut like "cmd+s" when no
    /// modifiers are passed separately.
    public static func keyAndModifiers(key: String, modifiers: [String]) throws -> (key: String, modifiers: MacKeys.Modifiers) {
        var parsed = try MacKeys.parseModifiers(modifiers)
        if MacKeys.stroke(key) != nil { return (key, parsed) }
        let combo = try MacKeys.parseCombo(key)
        parsed.formUnion(combo.modifiers)
        return (combo.key, parsed)
    }

    /// The scroll for a scroll call: `dx`/`dy` in points, or `direction` (`amount` points, default
    /// 300). Positive dy scrolls down (shows content further down), positive dx right.
    public static func scrollDelta(direction: String?, amount: Double?, dx: Double?, dy: Double?) throws -> (dx: Double, dy: Double) {
        if let direction {
            let distance = abs(amount ?? 300)
            switch direction.lowercased() {
            case "down": return (0, distance)
            case "up": return (0, -distance)
            case "right": return (distance, 0)
            case "left": return (-distance, 0)
            default: throw ToolError("Unknown direction \(direction). Use up, down, left or right.")
            }
        }
        let delta = (dx: dx ?? 0, dy: dy ?? 0)
        guard delta.dx != 0 || delta.dy != 0 else { throw ToolError("Pass dy (positive scrolls down) and/or dx, or direction.") }
        return delta
    }

    /// The menu path for press_menu_item: an array, or one string like "File > New Window".
    public static func menuPath(_ items: [String], text: String?) throws -> [String] {
        var path = items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if path.isEmpty, let text {
            path = text.components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        guard !path.isEmpty else { throw ToolError("Pass path, the menu titles from the menu bar down, e.g. [\"File\", \"New Window\"].") }
        return path
    }

    // MARK: Paths

    /// Where `isolated_home` points CFFIXED_USER_HOME: `<checkout>/.minirun/home` for an app built
    /// in a checkout (its path runs through the checkout's .minirun folder), or else a folder per
    /// Mac app id under `fallbackRoot`.
    public static func isolatedHome(appPath: String, checkout: String? = nil, id: String, fallbackRoot: String) -> String {
        if let checkout { return checkout + "/.minirun/home" }
        if let range = appPath.range(of: "/.minirun/") { return String(appPath[..<range.lowerBound]) + "/.minirun/home" }
        return fallbackRoot + "/" + id
    }

    /// The file a Mac app's stdout and stderr go to. Each launch appends after a marker line.
    public static func logPath(id: String, home: String) -> String {
        home + "/Library/Logs/minirun/apps/\(id).log"
    }

    /// What a Mac app's log file holds since its last launch (the driver writes a
    /// "=== minirun launch …" line before each), keeping the last `limit` characters.
    public static func outputSinceLaunch(_ log: String, limit: Int = 3000) -> String {
        var text = Substring(log)
        if let marker = log.range(of: "=== minirun launch", options: .backwards) {
            text = log[marker.lowerBound...]
            if let newline = text.firstIndex(of: "\n") { text = text[text.index(after: newline)...] } else { text = "" }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? "…" + String(trimmed.suffix(limit)) : trimmed
    }

    /// The app's display name from its .app path: "Fetch" for …/Fetch.app.
    public static func appName(appPath: String, productName: String? = nil) -> String {
        if let productName, !productName.isEmpty { return productName }
        let file = (appPath as NSString).lastPathComponent
        return file.hasSuffix(".app") ? String(file.dropLast(4)) : file
    }

    // MARK: Text

    /// The footer of results that hand out a Mac app id, like `deviceFooter` for simulators.
    public static func footer(name: String, id: String, viewerURL: String?) -> String {
        var text = "Mac app: \(name), id \(id). Pass device: \"\(id)\" on later calls (screenshot, describe_ui, tap, type_text, press_key, app_logs, terminate_app…) so they reach this app."
        if let viewerURL { text += "\nLive view of this app's window for the user: \(viewerURL)" }
        return text
    }

    /// One line per Mac app, for error messages.
    public static func describe(_ sessions: [MacAppSession]) -> String {
        sessions.map { session in
            var line = "\(session.id): \(session.name)"
            if let label = session.label { line += " for \(label)" }
            line += session.isRunning ? " (running, pid \(session.pid!))" : " (not running)"
            return line
        }.joined(separator: "\n")
    }

    /// When `device` doesn't name a Mac app minirun knows.
    public static func unknownApp(_ device: String, known: [MacAppSession]) -> String {
        if device.lowercased() == "mac" {
            return "device \"mac\" only works with launch_app and set_pasteboard. Pass your Mac app id (mac-…) from build_and_run, launch_app or list_mac_apps."
        }
        var text = "No Mac app with id \(device). Build and launch it with build_and_run (platform: \"macos\"), or launch_app with device: \"mac\"."
        if !known.isEmpty { text += "\nMac apps minirun knows:\n" + describe(known) }
        return text
    }

    /// When the app with this id has quit.
    public static func notRunning(_ session: MacAppSession) -> String {
        "\(session.name) (\(session.id)) isn't running. Launch it again with build_and_run, or launch_app with device: \"\(session.id)\"."
    }

    /// The note after a Mac screenshot: its size and the coordinate space tools use.
    public static func screenshotNote(width: Int, height: Int, windowIndex: Int, title: String, pointWidth: Double, pointHeight: Double) -> String {
        var note = "Screenshot of window \(windowIndex) (\"\(title)\"), \(width)x\(height)px. The window is \(Int(pointWidth.rounded()))x\(Int(pointHeight.rounded())) points"
        if abs(Double(width) - pointWidth) < 2 {
            note += "; image pixels equal window points from the window's top-left, title bar included, so use them directly for tap, swipe and scroll."
        } else {
            note += "; tap, swipe and scroll take window points from the window's top-left, title bar included."
        }
        return note
    }

    /// What an input result adds when it went through the HID tap.
    public static func inputNote(_ path: String) -> String {
        path == "hid" ? " Sent through the HID tap: this brought the app to the front and moved the real cursor (put back afterwards)." : ""
    }

    /// When a launched app quit before showing a window. `adHoc` says the build fell back to
    /// ad-hoc signing, which is the usual reason macOS kills an app at launch.
    public static func earlyExit(name: String, exit: String?, adHoc: Bool) -> String {
        var text = "\(name) quit right after launch (\(exit ?? "it exited")) without showing a window."
        if adHoc {
            text += " This build was signed ad hoc because signing with the project's team failed. macOS kills apps whose entitlements need a provisioning profile "
                + "(iCloud, push notifications, app groups with a team prefix…), so those entitlements are the likely cause: leave them out of local builds "
                + "(for example with a Debug-only entitlements file), or set up signing for the team on this Mac."
        }
        text += " Its output is below; app_logs has more."
        return text
    }

    /// The error a simulator-only tool gives for a Mac app, saying what to use instead.
    public static func unsupported(_ tool: String) -> String {
        switch tool {
        case "press_button":
            return "press_button presses simulator hardware buttons. For a Mac app use press_key (e.g. key \"w\" with modifiers [\"command\"]) or press_menu_item."
        case "configure_simulator":
            return "configure_simulator only changes simulators. A Mac app shares the Mac's own settings; pass launch_arguments or environment to build_and_run (or launch_app) to change how it starts."
        case "add_media":
            return "add_media adds to a simulator's Photos library. A Mac app can read files on the Mac directly; open one with open_url and a file:// URL."
        case "install_app":
            return "Mac apps aren't installed: minirun runs them from where they were built. Use launch_app with device: \"mac\" and app_path, or build_and_run."
        case "uninstall_app":
            return "There's nothing to uninstall: minirun runs Mac apps from their build folder. Use terminate_app to quit it."
        case "start_recording", "stop_recording":
            return "Recording isn't supported for Mac apps yet. To show a Mac app in a PR, use screenshot with share: true (a window screenshot, uploaded for the PR description)."
        case "boot_simulator", "shutdown_simulator":
            return "\(tool) is for simulators. Quit a Mac app with terminate_app; launch one with build_and_run or launch_app."
        default:
            return "\(tool) doesn't work with Mac apps."
        }
    }

    /// After request_mac_permissions: what's granted and what the user still has to do.
    public static func permissionRequestMessage(_ report: MacPermissionReport) -> String {
        let binary = report.binaryPath ?? "minirun"
        if report.allGranted { return "Screen Recording and Accessibility are granted to \(binary), so minirun can see and drive macOS apps." }
        var parts: [String] = []
        let permissions = [report.screenRecording ? nil : "Screen Recording", report.accessibility ? nil : "Accessibility"].compactMap { $0 }
        if !permissions.isEmpty {
            parts.append("Asked macOS for \(permissions.joined(separator: " and ")) for \(binary). Turn it on in System Settings → Privacy & Security → \(permissions.joined(separator: " and ")) "
                + "(macOS shows each prompt only once; after that, add it there with +).")
            if !report.screenRecording { parts.append("Then restart minirun serve: the Screen Recording grant only applies to a fresh process.") }
        }
        if !report.hasDisplay {
            parts.append("The Mac also has no active display, so windows can't be captured: log a user in and connect a display or an HDMI dummy plug.")
        }
        return parts.joined(separator: " ")
    }

    /// The `simulators` message entry for a running Mac app, for the viewer's picker.
    public static func pickerEntry(_ session: MacAppSession) -> JSONValue {
        var entry: [String: JSONValue] = [
            "udid": .string(session.id), "kind": "mac", "name": .string(session.name), "state": "Booted",
        ]
        if let label = session.label { entry["reserved_for"] = .string(label) }
        if let bundle = session.bundleID { entry["last_app"] = .string(bundle) }
        return .object(entry)
    }
}
