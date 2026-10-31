import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit
import MiniRunKit

/// One of a Mac app's windows. `index` is what tools call it: the main window is 0, then the
/// others front to back.
public struct MacWindowInfo: Sendable, Equatable {
    public let index: Int
    public let windowID: UInt32
    public let title: String
    /// Global points, top-left origin.
    public let frame: MacRect
    public let isMain: Bool
    /// Has keyboard focus within the app.
    public let isKey: Bool
    public let isMinimized: Bool
    public let isOnScreen: Bool

    public init(index: Int, windowID: UInt32, title: String, frame: MacRect, isMain: Bool, isKey: Bool = false, isMinimized: Bool, isOnScreen: Bool) {
        self.index = index
        self.windowID = windowID
        self.title = title
        self.frame = frame
        self.isMain = isMain
        self.isKey = isKey
        self.isMinimized = isMinimized
        self.isOnScreen = isOnScreen
    }

    /// `0: "Untitled" 800x600` (plus "main", "minimized", "off screen").
    public var summary: String {
        var text = "\(index): \"\(title)\" \(Int(frame.width))x\(Int(frame.height))"
        if isMain { text += " main" }
        if isMinimized { text += " minimized" } else if !isOnScreen { text += " off screen" }
        return text
    }
}

public enum MacWindowSelector: Sendable, Equatable {
    case main
    case index(Int)
    /// Case-insensitive: an exact title, else a substring.
    case title(String)

    /// From a tool argument: nil or "main" is the main window, digits an index, anything else a title.
    public static func parse(_ text: String?) -> MacWindowSelector {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty, text.lowercased() != "main" else { return .main }
        if let index = Int(text), index >= 0 { return .index(index) }
        return .title(text)
    }
}

public enum MacElementQuery: Sendable, Equatable {
    case id(String)
    case label(String)
    case value(String)
}

public enum MacMouseButton: String, Sendable, CaseIterable {
    case left, right
}

/// Drives native macOS apps on this Mac: launches them as plain processes (so two checkouts of
/// one app can run side by side), captures their windows with ScreenCaptureKit, reads and
/// presses their UI through Accessibility, and posts input events to their pid.
///
/// Every call acts on one pid, which the caller tracks per session; nothing here looks for an
/// app by name or bundle id, so one session never touches another's app.
@MainActor
public final class MacAppDriver {
    public static let shared = MacAppDriver()
    public typealias DriverError = MacDriverError

    /// Per-app input path overrides (see `MacInputPath`); `.pid` otherwise.
    private var inputPaths: [Int32: MacInputPath] = [:]
    /// Where each app's live mouse button is held down, so it can be released.
    private var heldMice: [Int32: MacInputTarget] = [:]
    private let exits = ExitRecorder()

    private init() {
        // Opens this process's window server connection, which ScreenCaptureKit expects.
        _ = CGMainDisplayID()
    }

    // MARK: Permissions

    public func permissions() -> MacPermissionStatus {
        MacPermissions.status()
    }

    /// Shows the system prompts for missing permissions, as this process.
    public func requestPermissions() {
        MacPermissions.request()
    }

    // MARK: Lifecycle

    /// Starts an app's executable as a new process in its own process group, with stdout and
    /// stderr appended to `logURL` (after a `=== minirun launch` marker line). `environment` is
    /// merged over this process's environment, minus minirun's and the dynamic loader's variables.
    /// Spawning the executable directly, not through LaunchServices, lets two builds with the
    /// same bundle id run at once. Returns the pid.
    public func launch(executablePath: String, arguments: [String] = [], environment: [String: String] = [:], logURL: URL) throws -> Int32 {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw DriverError("No executable at \(executablePath). Build the app first.")
        }
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw DriverError("Couldn't open the log file \(logURL.path): \(String(cString: strerror(errno))).") }
        defer { close(fd) }
        let marker = "\n\(Self.launchMarker) \(ISO8601DateFormatter().string(from: Date())) \(executablePath) ===\n"
        _ = marker.withCString { write(fd, $0, strlen($0)) }

        var env = ProcessInfo.processInfo.environment.filter { key, _ in
            !(key.hasPrefix("DYLD_") || key.hasPrefix("MINIRUN_") || key.hasPrefix("XPC_") || key == "__CFBundleIdentifier")
        }
        env.merge(environment) { _, new in new }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own process group, so stopping minirun's launchd job doesn't take the app with it;
        // only the descriptors set up below are inherited; default signal handling.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fd, 1)
        posix_spawn_file_actions_adddup2(&actions, fd, 2)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executablePath] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executablePath, &actions, &attributes, argv, envp)
        guard status == 0 else {
            throw DriverError("Couldn't start \(executablePath): \(String(cString: strerror(status))).")
        }
        // Reap it when it exits, and remember how.
        let child = pid
        let exits = self.exits
        exits.clear(child)
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(child, &status, 0) == -1 && errno == EINTR {}
            exits.record(child, status: status)
        }
        return child
    }

    static let launchMarker = "=== minirun launch"

    /// How a process this driver launched ended, e.g. "exited with status 1" or "killed by
    /// signal 11 (SIGSEGV)". Nil while it runs, or if it wasn't launched by this daemon.
    public func exitDescription(pid: Int32) -> String? {
        exits.description(pid)
    }

    /// The installed app for a bundle id, from LaunchServices.
    public func appPath(forBundleID bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
    }

    /// Waits until the app shows a window on screen. With `activate`, it's brought to the front
    /// once it has checked in with the window server. False if it exited or the time ran out.
    public func waitForWindow(pid: Int32, timeout: TimeInterval, activate: Bool = true) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var activated = false
        while true {
            guard isRunning(pid: pid, executablePath: nil) else { return false }
            if activate && !activated, let app = NSRunningApplication(processIdentifier: pid) {
                _ = app.activate(options: [.activateAllWindows])
                activated = true
            }
            let windows = await Self.readWindowsDetached(pid)
            if windows.contains(where: { $0.isOnScreen }) {
                if activate { bringToFront(pid: pid, window: windows.first { $0.isOnScreen }) }
                return true
            }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Quits the app: a polite terminate (it may save, or ask to), then after `grace` seconds a
    /// SIGKILL to it and its process group. Given `executablePath`, a pid that now belongs to
    /// some other program is left alone.
    public func terminate(pid: Int32, grace: TimeInterval = 5, executablePath: String? = nil) async {
        guard isRunning(pid: pid, executablePath: executablePath) else { return }
        let group = getpgid(pid)
        let app = NSRunningApplication(processIdentifier: pid)
        if app?.terminate() != true { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(max(0, grace))
        while Date() < deadline {
            if !isRunning(pid: pid, executablePath: executablePath) { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard isRunning(pid: pid, executablePath: executablePath) else { return }
        _ = app?.forceTerminate()
        kill(pid, SIGKILL)
        // Helpers it started, if it leads its own group (as apps launched here do).
        if group == pid { kill(-group, SIGKILL) }
        heldMice[pid] = nil
        inputPaths[pid] = nil
    }

    /// Whether `pid` is alive and, given `executablePath`, still running that executable (so a
    /// recycled pid isn't mistaken for the app).
    public func isRunning(pid: Int32, executablePath: String?) -> Bool {
        Self.isRunning(pid: pid, executablePath: executablePath)
    }

    public nonisolated static func isRunning(pid: Int32, executablePath: String?) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard let executablePath else { return true }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let actual = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
        return canonical(actual) == canonical(executablePath)
    }

    // MARK: Windows

    /// The app's windows: the main window first, then the rest front to back. Minimized
    /// windows are included when Accessibility is granted (they're how they're found).
    public func windows(pid: Int32) -> [MacWindowInfo] {
        Self.readWindows(pid)
    }

    nonisolated static func readWindowsDetached(_ pid: Int32) async -> [MacWindowInfo] {
        await Task.detached { Self.readWindows(pid) }.value
    }

    nonisolated static func readWindows(_ pid: Int32) -> [MacWindowInfo] {
        let list = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        struct Entry { let id: UInt32; let frame: MacRect; let onScreen: Bool; let name: String? }
        let entries: [Entry] = list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 1, rect.height > 1 else { return nil }
            return Entry(
                id: id, frame: MacRect(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height)),
                onScreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                name: info[kCGWindowName as String] as? String
            )
        }
        let accessible = MacAccessibility.windows(pid: pid)
        func axState(for entry: Entry) -> MacAccessibility.WindowState? {
            guard let accessible else { return nil }
            return accessible.first { $0.windowID == entry.id } ?? accessible.first { candidate in
                guard candidate.windowID == nil, let frame = candidate.frame else { return false }
                return abs(frame.x - entry.frame.x) < 1 && abs(frame.y - entry.frame.y) < 1
                    && abs(frame.width - entry.frame.width) < 1 && abs(frame.height - entry.frame.height) < 1
            }
        }
        var found: [(entry: Entry, state: MacAccessibility.WindowState?)] = entries.compactMap { entry in
            let state = axState(for: entry)
            // Off-screen windows Accessibility doesn't know are internal (or on another Space).
            if !entry.onScreen && state == nil { return nil }
            return (entry, state)
        }
        if let main = found.firstIndex(where: { $0.state?.isMain == true }), main > 0 {
            found.insert(found.remove(at: main), at: 0)
        }
        return found.enumerated().map { index, item in
            MacWindowInfo(
                index: index, windowID: item.entry.id,
                title: item.state?.title.nilIfEmpty ?? item.entry.name ?? "",
                frame: item.entry.frame,
                isMain: item.state?.isMain ?? false, isKey: item.state?.isFocused ?? false,
                isMinimized: item.state?.isMinimized ?? false, isOnScreen: item.entry.onScreen
            )
        }
    }

    nonisolated static func resolve(_ selector: MacWindowSelector, in windows: [MacWindowInfo], pid: Int32) throws -> MacWindowInfo {
        guard !windows.isEmpty else {
            if !isRunning(pid: pid, executablePath: nil) { throw MacDriverError("The app (pid \(pid)) isn't running. Launch it again.") }
            throw MacDriverError("The app (pid \(pid)) has no windows open. It may still be starting, have only a menu bar, or have its windows on another Space.")
        }
        let available = "Windows: " + windows.map(\.summary).joined(separator: "; ") + "."
        switch selector {
        case .main:
            if let window = windows.first(where: { $0.isMain && $0.isOnScreen }) ?? windows.first(where: { $0.isOnScreen }) { return window }
            throw MacDriverError("None of the app's windows is on screen (minimized or on another Space). \(available)")
        case .index(let index):
            if let window = windows.first(where: { $0.index == index }) { return window }
            throw MacDriverError("No window \(index). \(available)")
        case .title(let title):
            if let window = windows.first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame })
                ?? windows.first(where: { $0.title.range(of: title, options: .caseInsensitive) != nil }) { return window }
            throw MacDriverError("No window titled \"\(title)\". \(available)")
        }
    }

    /// The window a call acts on.
    public func window(pid: Int32, _ selector: MacWindowSelector) async throws -> MacWindowInfo {
        try Self.resolve(selector, in: await Self.readWindowsDetached(pid), pid: pid)
    }

    /// Activates the app and raises the window (or its main window).
    public func bringToFront(pid: Int32, window: MacWindowInfo?) {
        _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
        if let window { MacAccessibility.raise(pid: pid, windowID: window.windowID, frame: window.frame) }
    }

    // MARK: Seeing

    /// A JPEG of one window (shadow excluded, title bar included), even when other windows cover
    /// it. By default 1 image pixel = 1 window point; `scale` is image pixels per point.
    public func screenshotJPEG(pid: Int32, window selector: MacWindowSelector = .main, scale: Double? = nil, quality: Int = 75) async throws
        -> (data: Data, width: Int, height: Int, window: MacWindowInfo) {
        try MacPermissions.requireScreenRecording(for: "take screenshots of Mac app windows")
        let window = try await self.window(pid: pid, selector)
        if window.isMinimized { throw DriverError("Window \(window.index) is minimized, so there's nothing to capture.") }
        let shot = try await Self.capture(windowID: window.windowID, points: (window.frame.width, window.frame.height), scale: scale, quality: quality)
        return (shot.data, shot.width, shot.height, window)
    }

    nonisolated static func shareableWindow(_ windowID: UInt32) async throws -> SCWindow {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            if !CGPreflightScreenCaptureAccess() { throw MacPermissions.missing("Screen Recording", for: "see Mac app windows") }
            throw MacDriverError("ScreenCaptureKit couldn't list windows: \(error.localizedDescription)")
        }
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw MacDriverError("ScreenCaptureKit can't see window \(windowID). It may have just closed; call list_windows.")
        }
        return window
    }

    nonisolated static func capture(windowID: UInt32, points: (width: Double, height: Double), scale: Double?, quality: Int) async throws -> (data: Data, width: Int, height: Int) {
        let window = try await shareableWindow(windowID)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let rect = filter.contentRect
        let size = rect.width > 0 && rect.height > 0 ? (Double(rect.width), Double(rect.height)) : points
        let pixels = MacGeometry.capturePixels(points: size, backingScale: Double(filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.width = pixels.width
        configuration.height = pixels.height
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        let image: CGImage = try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: MacDriverError("Couldn't capture the window: \(error?.localizedDescription ?? "no image")."))
                }
            }
        }
        let output = MacGeometry.imageSize(points: size, scale: scale)
        let resized = MacImage.resized(image, width: output.width, height: output.height) ?? image
        return (try MacImage.jpeg(resized, quality: quality), resized.width, resized.height)
    }

    /// An H.264 encoder fed by a ScreenCaptureKit stream of one window. `scale` is relative to
    /// the window's pixels; `bitrate` gets the encoded size.
    public func windowEncoder(pid: Int32, window selector: MacWindowSelector = .main, scale: Double, fps: Int,
                              bitrate: @escaping @Sendable (_ width: Int, _ height: Int) -> Int) async throws -> MacWindowEncoder {
        try MacPermissions.requireScreenRecording(for: "stream Mac app windows")
        let window = try await self.window(pid: pid, selector)
        return try await Self.makeEncoder(windowID: window.windowID, scale: scale, fps: fps, bitrate: bitrate)
    }

    nonisolated static func makeEncoder(windowID: UInt32, scale: Double, fps: Int, bitrate: @escaping @Sendable (Int, Int) -> Int) async throws -> MacWindowEncoder {
        let window = try await shareableWindow(windowID)
        let encoder = MacWindowEncoder(window: window, scale: scale, fps: fps, bitrate: bitrate)
        try await encoder.start()
        return encoder
    }

    // MARK: Accessibility

    /// The window's accessibility tree as AXe-shaped JSON (an array of root nodes; see
    /// `XcodeParsing.summarizeAccessibility`), with frames in window points. With
    /// `includeMenus`, the menu bar's tree follows the window's (without frames). With `point`,
    /// just the element there and its descendants.
    public func describeUI(pid: Int32, window selector: MacWindowSelector = .main, includeMenus: Bool = false, at point: (x: Double, y: Double)? = nil) async throws -> Data {
        try MacPermissions.requireAccessibility(for: "read Mac app UI")
        let window = try await self.window(pid: pid, selector)
        let windowID = window.windowID, frame = window.frame
        return try await Task.detached {
            try MacAccessibility.describe(pid: pid, windowID: windowID, frame: frame, includeMenus: includeMenus, at: point)
        }.value
    }

    /// Presses the element matching `query` (an exact id; or a label or value, exact then
    /// substring, case-insensitive), retrying for up to `wait` seconds while it doesn't exist.
    /// Uses the AXPress action, which needs no mouse or focus; text fields are focused instead;
    /// elements with no press action get a click at their center. Returns the center, in window points.
    public func press(pid: Int32, window selector: MacWindowSelector = .main, query: MacElementQuery, wait: TimeInterval = 0) async throws -> (x: Double, y: Double) {
        try MacPermissions.requireAccessibility(for: "press buttons in Mac apps")
        let deadline = Date().addingTimeInterval(max(0, wait))
        while true {
            let window = try await self.window(pid: pid, selector)
            let windowID = window.windowID, frame = window.frame
            let outcome = try await Task.detached {
                try MacAccessibility.press(pid: pid, windowID: windowID, frame: frame, query: query)
            }.value
            switch outcome {
            case .pressed(let x, let y)?:
                return (x, y)
            case .click(let x, let y)?:
                try await click(pid: pid, window: .index(window.index), x: x, y: y)
                return (x, y)
            case nil:
                if Date() >= deadline {
                    let what: String
                    switch query {
                    case .id(let id): what = "id \"\(id)\""
                    case .label(let label): what = "label \"\(label)\""
                    case .value(let value): what = "value \"\(value)\""
                    }
                    throw DriverError("No element with \(what) in window \(window.index) (\"\(window.title)\"). Call describe_ui to see what's there, or pass wait to give it time to appear.")
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// Picks a menu bar item by its title path, e.g. ["File", "New Window"]. Titles match
    /// case-insensitively, exactly or by prefix, ignoring a trailing "…". Returns the path pressed,
    /// like "File > New Window".
    public func pressMenuItem(pid: Int32, path: [String]) async throws -> String {
        let titles = try await Task.detached { try MacAccessibility.pressMenuItem(pid: pid, path: path) }.value
        return titles.joined(separator: " > ")
    }

    // MARK: Input

    /// Makes later input to this app go through `path` (nil restores the default, `.pid`).
    public func setInputPath(_ path: MacInputPath?, pid: Int32) {
        inputPaths[pid] = path
    }

    public func inputPath(pid: Int32) -> MacInputPath {
        inputPaths[pid] ?? .pid
    }

    /// Runs `body` against the window on the chosen path. The HID path brings the app forward,
    /// holds the global input lock, and puts the cursor back afterwards.
    private func withInput(pid: Int32, window: MacWindowInfo?, path: MacInputPath?, _ body: (MacInputTarget) async -> Void) async throws -> MacInputPath {
        try MacPermissions.requireAccessibility(for: "send clicks and keys to Mac apps")
        guard isRunning(pid: pid, executablePath: nil) else { throw DriverError("The app (pid \(pid)) isn't running. Launch it again.") }
        let chosen = path ?? inputPath(pid: pid)
        let target = MacInputTarget(pid: pid, windowID: window?.windowID ?? 0, frame: window?.frame ?? MacRect(x: 0, y: 0, width: 0, height: 0), path: chosen)
        switch chosen {
        case .pid:
            await body(target)
        case .hid:
            await MacInputLock.shared.lock()
            let cursor = CGEvent(source: nil)?.location
            bringToFront(pid: pid, window: window)
            await MacInput.pause(0.2)
            await body(target)
            if let cursor { CGWarpMouseCursorPosition(cursor) }
            await MacInputLock.shared.unlock()
        }
        return chosen
    }

    private func checkInside(_ window: MacWindowInfo, _ x: Double, _ y: Double) throws {
        guard MacGeometry.contains(window.frame, windowPoint: (x, y)) else {
            throw DriverError("(\(Int(x)), \(Int(y))) is outside window \(window.index), which is \(Int(window.frame.width))x\(Int(window.frame.height)) points (origin at its top-left, title bar included).")
        }
    }

    /// Clicks a window point. `count` 2 is a double click. Returns the path the events took.
    @discardableResult
    public func click(pid: Int32, window selector: MacWindowSelector = .main, x: Double, y: Double, button: MacMouseButton = .left, count: Int = 1, path: MacInputPath? = nil) async throws -> MacInputPath {
        let window = try await self.window(pid: pid, selector)
        try checkInside(window, x, y)
        return try await withInput(pid: pid, window: window, path: path) { target in
            await MacInput.click((x, y), button: button, count: count, target: target)
        }
    }

    /// Drags with the left button: down at `from`, held `hold` seconds, moved to `to` over `duration`, up.
    @discardableResult
    public func drag(pid: Int32, window selector: MacWindowSelector = .main, from start: (x: Double, y: Double), to end: (x: Double, y: Double),
                     duration: Double = 0.3, hold: Double = 0, path: MacInputPath? = nil) async throws -> MacInputPath {
        let window = try await self.window(pid: pid, selector)
        try checkInside(window, start.x, start.y)
        return try await withInput(pid: pid, window: window, path: path) { target in
            await MacInput.drag(from: start, to: end, duration: duration, hold: hold, target: target)
        }
    }

    /// One step of a live mouse gesture from the viewer: "down", then any "move"s, then "up".
    /// Always posted to the pid (never the HID tap) so a viewer can't move the real cursor.
    public func mouse(pid: Int32, window selector: MacWindowSelector = .main, phase: String, x: Double, y: Double) async throws {
        switch phase {
        case "down":
            try MacPermissions.requireAccessibility(for: "send clicks to Mac apps")
            let window = try await self.window(pid: pid, selector)
            let target = MacInputTarget(pid: pid, windowID: window.windowID, frame: window.frame, path: .pid)
            let source = MacInput.source()
            let point = MacInput.global((x, y), in: target)
            MacInput.mouse(.mouseMoved, at: point, button: .left, target: target, source: source)
            MacInput.mouse(.leftMouseDown, at: point, button: .left, target: target, source: source)
            heldMice[pid] = target
        case "move":
            guard let target = heldMice[pid] else { return }
            MacInput.mouse(.leftMouseDragged, at: MacInput.global((x, y), in: target), button: .left, target: target, source: MacInput.source())
        case "up":
            guard let target = heldMice.removeValue(forKey: pid) else { return }
            MacInput.mouse(.leftMouseUp, at: MacInput.global((x, y), in: target), button: .left, target: target, source: MacInput.source())
        default:
            throw DriverError("Unknown mouse phase \(phase); use down, move or up.")
        }
    }

    /// Lifts any live mouse button still held, e.g. when the viewer that pressed it goes away.
    public func releaseMouse() {
        for (_, target) in heldMice {
            let point = CGPoint(x: target.frame.midX, y: target.frame.midY)
            MacInput.mouse(.leftMouseUp, at: point, button: .left, target: target, source: MacInput.source())
        }
        heldMice.removeAll()
    }

    /// Scrolls at a window point (default: the window's center). Positive `dy` moves further
    /// down the content, positive `dx` further right.
    @discardableResult
    public func scroll(pid: Int32, window selector: MacWindowSelector = .main, x: Double? = nil, y: Double? = nil, dx: Double, dy: Double, path: MacInputPath? = nil) async throws -> MacInputPath {
        let window = try await self.window(pid: pid, selector)
        let point = (x: x ?? window.frame.width / 2, y: y ?? window.frame.height / 2)
        try checkInside(window, point.x, point.y)
        return try await withInput(pid: pid, window: window, path: path) { target in
            await MacInput.scroll(at: point, dx: dx, dy: dy, target: target)
        }
    }

    /// Types text into whatever has keyboard focus in the app. Any characters work, emoji included.
    @discardableResult
    public func typeText(pid: Int32, text: String, path: MacInputPath? = nil) async throws -> MacInputPath {
        let window = try? await self.window(pid: pid, .main)
        return try await withInput(pid: pid, window: window, path: path) { target in
            await MacInput.type(text, target: target)
        }
    }

    /// Presses a key (`return`, `f5`, `a`, `?`) with modifiers. Uppercase letters and shifted
    /// symbols add shift.
    @discardableResult
    public func pressKey(pid: Int32, key: String, modifiers: MacKeys.Modifiers = [], path: MacInputPath? = nil) async throws -> MacInputPath {
        guard let stroke = MacKeys.stroke(key) else {
            throw DriverError("Unknown key \(key). Use a letter, digit, punctuation, or one of: \(MacKeys.namedKeys.joined(separator: ", ")).")
        }
        let window = try? await self.window(pid: pid, .main)
        return try await withInput(pid: pid, window: window, path: path) { target in
            await MacInput.key(stroke.code, modifiers: modifiers.union(stroke.modifiers), target: target)
        }
    }

    // MARK: Other

    /// Opens a URL with the app at `appPath`, through LaunchServices, without bringing it forward.
    public func openURL(_ url: String, appPath: String) async throws {
        guard let parsed = URL(string: url), parsed.scheme != nil else { throw DriverError("\(url) isn't a URL (it needs a scheme, like https:// or myapp://).") }
        try await Self.openWith(parsed, appPath: appPath)
    }

    nonisolated static func openWith(_ url: URL, appPath: String) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: appPath), configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: MacDriverError("Couldn't open \(url.absoluteString) with \(appPath): \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Sets the Mac's pasteboard, which every app and session on this Mac shares.
    public func setPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The app's output: what it printed to stdout/stderr since its last launch (from
    /// `capturedLog`), then unified logging for the pid (or, with no pid, the process name) over
    /// the last `seconds` (or since `since`, if sooner). Lines are filtered by `filter`
    /// (case-insensitive) and each part keeps its newest `maxBytes`.
    public func logs(pid: Int32?, processName: String, capturedLog: URL?, since: Date? = nil, seconds: Int = 300, filter: String? = nil, maxBytes: Int = 40_000) async throws -> String {
        func keep(_ lines: [Substring]) -> String {
            let filtered = filter.map { term in lines.filter { $0.range(of: term, options: .caseInsensitive) != nil } } ?? lines
            return Shell.tail(filtered.joined(separator: "\n"), limit: maxBytes)
        }
        var parts: [String] = []
        if let capturedLog {
            let text = Self.readTail(capturedLog, bytes: 2_000_000)
            let sinceLaunch = text.range(of: Self.launchMarker, options: .backwards).map { range in
                text[range.lowerBound...].split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? ""
            } ?? text
            let output = keep(sinceLaunch.split(separator: "\n", omittingEmptySubsequences: false))
            parts.append("--- stdout/stderr since launch ---\n" + (output.isEmpty ? "(nothing\(filter == nil ? "" : " matching"))" : output))
        }
        var window = max(1, seconds)
        if let since { window = min(window, max(1, Int((-since.timeIntervalSinceNow).rounded(.up)))) }
        let predicate = pid.map { "processIdentifier == \($0)" }
            ?? "process == \"\(processName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        let result = try await Shell.run("/usr/bin/log", ["show", "--style", "compact", "--last", "\(window)s", "--predicate", predicate], timeout: 45)
        if result.succeeded {
            // The first line is a column header.
            let lines = result.stdout.split(separator: "\n").filter { !$0.hasPrefix("Timestamp") }
            let output = keep(lines)
            parts.append("--- unified log, last \(window)s ---\n" + (output.isEmpty ? "(nothing\(filter == nil ? "" : " matching"))" : output))
        } else {
            parts.append("--- unified log ---\n(log show failed: \(result.timedOut ? "timed out" : result.tail(500)))")
        }
        if let pid, let exit = exitDescription(pid: pid) { parts.append("The app \(exit).") }
        return parts.joined(separator: "\n\n")
    }

    nonisolated static func readTail(_ url: URL, bytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// How each launched process exited, recorded by its reaper thread.
final class ExitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [Int32: Int32] = [:]

    func clear(_ pid: Int32) {
        lock.lock()
        statuses[pid] = nil
        lock.unlock()
    }

    func record(_ pid: Int32, status: Int32) {
        lock.lock()
        statuses[pid] = status
        lock.unlock()
    }

    func description(_ pid: Int32) -> String? {
        lock.lock()
        let status = statuses[pid]
        lock.unlock()
        guard let status else { return nil }
        let signal = status & 0x7f
        if signal == 0 { return "exited with status \((status >> 8) & 0xff)" }
        let name = String(cString: strsignal(signal))
        return "was killed by signal \(signal) (\(name))"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
