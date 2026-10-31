import Foundation
import MiniRunKit
import MiniRunMac

/// macOS apps: the tools only they have (list_mac_apps, list_windows, scroll, press_menu_item),
/// and the Mac branches of the shared tools, taken when `device` is a Mac app id ("mac-…").
extension ToolRegistry {
    static let macProperties: [String: JSONValue] = [
        "window": Schema.string("Mac apps: which window, as an index from list_windows or part of its title. Default: the main window."),
        "input": Schema.string(
            "Mac apps: how clicks and keys reach the app. \"pid\" (default) posts them to the app without moving the cursor or needing it in front. " +
                "\"hid\" brings the app to the front and uses the real cursor and keyboard, for apps that ignore pid events.",
            enum: ["pid", "hid"]
        ),
    ]

    static let platformProperty: [String: JSONValue] = [
        "platform": Schema.string(
            "ios (a simulator), macos (a Mac app, run on the Mac itself) or mac-catalyst. Omitted: macos if device is a Mac app id or the scheme " +
                "only builds for macOS, otherwise ios.",
            enum: BuildPlatform.allCases.map(\.rawValue)
        ),
    ]

    static let isolatedHomeProperty: [String: JSONValue] = [
        "isolated_home": Schema.boolean(
            "Mac apps: run with CFFIXED_USER_HOME set to <checkout>/.minirun/home, so a non-sandboxed app gets its own preferences and files " +
                "instead of sharing them with other copies of it on this Mac."
        ),
    ]

    func registerMacTools() {
        let mac = Self.macProperties
        let app: [String: JSONValue] = ["device": Schema.string("The Mac app id (mac-…) from build_and_run, launch_app or list_mac_apps.")]

        register(ToolDefinition(
            name: "list_mac_apps",
            description: "List the macOS apps minirun launched on this Mac: id, name, bundle id, pid, whether it's running, who it's for (repo@branch), when it was last used, and its windows. " +
                "Other sessions' apps are listed too: only use and quit your own.",
            properties: [:]
        )) { [self] _ in
            let sessions = await refreshedMacApps()
            guard !sessions.isEmpty else { return .text("No Mac apps yet. build_and_run with platform: \"macos\" builds and launches one.") }
            var list: [JSONValue] = []
            for session in sessions {
                var json = session.json.objectValue ?? [:]
                if let pid = session.pid {
                    json["windows"] = .array(await MacAppDriver.shared.windows(pid: pid).map { .string($0.summary) })
                    if let link = config.viewerURL(device: session.id) { json["live_view"] = .string(link) }
                }
                list.append(.object(json))
            }
            return .json(.array(list))
        }

        register(ToolDefinition(
            name: "list_windows",
            description: "List a Mac app's windows: index, title, size and position in points, and whether each is main, key, minimized or on screen. " +
                "Pass an index or title as window to screenshot, describe_ui, tap and the other tools.",
            properties: app,
            required: ["device"]
        )) { [self] args in
            let session = try await macApp(args)
            let windows = await MacAppDriver.shared.windows(pid: session.pid!)
            let permissions = await MacAppDriver.shared.permissions()
            // Without Screen Recording macOS hides other apps' window titles from minirun;
            // Accessibility can still read them, so only both missing means no titles at all.
            let titleNote = permissions.screenRecording ? nil
                : "minirun has no Screen Recording permission, so macOS hides window titles from it" +
                    (permissions.accessibility ? "; they're read through Accessibility instead, and may be empty for some windows." : ", and they may show as empty.")
            guard !windows.isEmpty else { return .text(["\(session.name) has no windows right now.", titleNote].compactMap { $0 }.joined(separator: "\n")) }
            let lines = windows.map { window in
                var line = window.summary + " at (\(Int(window.frame.x)), \(Int(window.frame.y))) on the screen"
                if window.isKey { line += ", key (has keyboard focus)" }
                return line
            }
            let text = lines.joined(separator: "\n") + "\nTools take window points from a window's top-left corner, title bar included."
            return .text([text, titleNote].compactMap { $0 }.joined(separator: "\n"))
        }

        register(ToolDefinition(
            name: "scroll",
            description: "Mac apps: scroll with the scroll wheel at a window point (default: the window's center), by dx/dy points or in a direction. " +
                "Positive dy (or direction down) shows content further down. On a simulator, use swipe.",
            properties: app.merging(mac) { a, _ in a }.merging([
                "x": Schema.number("X in window points."),
                "y": Schema.number("Y in window points."),
                "dx": Schema.number("Points to scroll right (negative: left)."),
                "dy": Schema.number("Points to scroll down (negative: up)."),
                "direction": Schema.string("Instead of dx/dy.", enum: ["up", "down", "left", "right"]),
                "amount": Schema.number("Points to scroll with direction (default 300).", minimum: 1, maximum: 10000),
                "screenshot": Schema.boolean("Return a screenshot afterwards."),
            ]) { a, _ in a },
            required: ["device"]
        )) { [self] args in
            guard MacAppID.isMacDevice(args.string("device")) else { throw ToolError("scroll works with Mac apps. On a simulator, use swipe.") }
            let session = try await macApp(args)
            let delta = try MacToolSupport.scrollDelta(direction: args.string("direction"), amount: args.double("amount"), dx: args.double("dx"), dy: args.double("dy"))
            let path = try await MacAppDriver.shared.scroll(
                pid: session.pid!, window: macWindow(args), x: args.double("x"), y: args.double("y"), dx: delta.dx, dy: delta.dy, path: try macInput(args)
            )
            return try await afterMacAction("Scrolled by (\(Int(delta.dx)), \(Int(delta.dy))) points." + MacToolSupport.inputNote(path.rawValue), session: session, args: args)
        }

        register(ToolDefinition(
            name: "press_menu_item",
            description: "Mac apps: pick an item from the app's menu bar by its path, e.g. [\"File\", \"New Window\"]. Titles match case-insensitively, " +
                "exactly or by their start, ignoring a trailing \"…\". On a miss it lists the menus there are. Uses Accessibility, so no mouse is needed.",
            properties: app.merging([
                "path": Schema.stringArray("Menu titles from the menu bar down, e.g. [\"Edit\", \"Find\", \"Find…\"]."),
                "screenshot": Schema.boolean("Return a screenshot afterwards."),
            ]) { a, _ in a },
            required: ["device", "path"]
        )) { [self] args in
            let session = try await macApp(args)
            let path = try MacToolSupport.menuPath(args.strings("path"), text: args.string("path"))
            let picked = try await MacAppDriver.shared.pressMenuItem(pid: session.pid!, path: path)
            return try await afterMacAction("Picked \(picked).", session: session, args: args)
        }
    }

    // MARK: Sessions

    /// The Mac app `device` names, marked as just used. With `running`, it must be running.
    func macApp(_ args: ToolArguments, running: Bool = true) async throws -> MacAppSession {
        let device = args.string("device") ?? ""
        guard var session = await macApps.session(device) else {
            throw ToolError(MacToolSupport.unknownApp(device, known: await refreshedMacApps()))
        }
        if let pid = session.pid, !MacAppDriver.isRunning(session) {
            // Only if it's still that pid: a relaunch in the meantime has a new one.
            await macApps.markExited(session.id, ifPid: pid)
            session.pid = nil
        }
        if running, session.pid == nil { throw ToolError(MacToolSupport.notRunning(session)) }
        await macApps.touch(session.id)
        return session
    }

    /// Every Mac app minirun knows, with the ones that have quit marked so.
    func refreshedMacApps() async -> [MacAppSession] {
        for session in await macApps.all() {
            if let pid = session.pid, !MacAppDriver.isRunning(session) {
                await macApps.markExited(session.id, ifPid: pid)
            }
        }
        return await macApps.all()
    }

    /// The window a call acts on. A call from the live view without a window goes to the
    /// window the view is showing, not whichever is main by now.
    func macWindow(_ args: ToolArguments) -> MacWindowSelector {
        if args.string("window") == nil, Self.fromViewer, let device = args.string("device"), let shown = streamedMacWindows[device] {
            return .id(shown)
        }
        return MacWindowSelector.parse(args.string("window"))
    }

    /// The input path a call asks for. Calls from the live view always get the default (pid):
    /// a viewer never moves the Mac's real cursor or types through the HID tap.
    func macInput(_ args: ToolArguments) throws -> MacInputPath? {
        if Self.fromViewer { return nil }
        return try MacToolSupport.inputPath(args.string("input")).flatMap(MacInputPath.init(rawValue:))
    }

    /// Runs `body` with the Mac app marked busy (so idle quitting leaves it alone), then counts it as just used.
    func whileUsingMac<T>(_ id: String, _ body: () async throws -> T) async throws -> T {
        await activity.begin(id)
        do {
            let value = try await body()
            await activity.end(id)
            await macApps.touch(id)
            return value
        } catch {
            await activity.end(id)
            await macApps.touch(id)
            throw error
        }
    }

    // MARK: Launching

    /// What launchMac starts.
    struct MacLaunch {
        var id: String
        var label: String?
        var name: String
        var bundleID: String?
        var appPath: String
        var executablePath: String
        var arguments: [String] = []
        var environment: [String: String] = [:]
        /// CFFIXED_USER_HOME for the app, created if missing.
        var home: String?
        /// Says the build fell back to ad-hoc signing.
        var adHoc = false
    }

    /// Quits the app this id launched before (that pid only, never anyone else's), launches the
    /// new one with its output going to the id's log file, waits for a window, and returns a
    /// screenshot plus the id to pass as device. `intro` goes first in the result.
    func launchMac(_ launch: MacLaunch, intro: [String]) async throws -> ToolResult {
        // One launch or quit per app id at a time, so build_and_run and launch_app for the same
        // id can't both spawn a copy (leaving one untracked).
        let pid = try await macLaunches.withLock(launch.id) { () async throws -> Int32 in
            try await spawnMac(launch)
        }
        return try await finishMacLaunch(launch, pid: pid, intro: intro)
    }

    /// Quits the copy this id launched before, then spawns the new one and records it. Call
    /// while holding `macLaunches` for the id.
    private func spawnMac(_ launch: MacLaunch) async throws -> Int32 {
        if let previous = await macApps.session(launch.id), let pid = previous.pid {
            await MacAppDriver.shared.terminate(pid: pid, grace: 5, executablePath: previous.executablePath, start: previous.processStart)
            await macApps.markExited(launch.id, ifPid: pid)
        }
        var environment = launch.environment
        if let home = launch.home {
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
            environment["CFFIXED_USER_HOME"] = home
        }
        let logPath = MacToolSupport.logPath(id: launch.id, home: MiniRunConfig.home)
        let pid = try await MacAppDriver.shared.launch(executablePath: launch.executablePath, arguments: launch.arguments, environment: environment, logURL: URL(fileURLWithPath: logPath))
        let now = Date()
        await macApps.upsert(MacAppSession(
            id: launch.id, label: launch.label, name: launch.name, bundleID: launch.bundleID, appPath: launch.appPath,
            executablePath: launch.executablePath, pid: pid, logPath: logPath, launchedAt: now, updatedAt: now,
            processStart: MacAppDriver.processStart(pid: pid)
        ))
        return pid
    }

    /// Waits for the window of the copy just launched as `pid` and builds the result.
    private func finishMacLaunch(_ launch: MacLaunch, pid: Int32, intro: [String]) async throws -> ToolResult {
        let logPath = MacToolSupport.logPath(id: launch.id, home: MiniRunConfig.home)
        let shown = await MacAppDriver.shared.waitForWindow(pid: pid, timeout: 15)
        if !shown, !MacAppDriver.isRunning(pid: pid, executablePath: launch.executablePath) {
            let exit = await MacAppDriver.shared.exitDescription(pid: pid)
            await macApps.markExited(launch.id, ifPid: pid)
            let output = MacToolSupport.outputSinceLaunch((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "")
            let text = intro + [MacToolSupport.earlyExit(name: launch.name, exit: exit, adHoc: launch.adHoc), output.isEmpty ? "(It printed nothing.)" : output, "Log: \(logPath)"]
            return ToolResult([.text(text.joined(separator: "\n"))], isError: true)
        }
        var lines = intro
        var launched = "Launched \(launch.name) (pid \(pid))"
        if let home = launch.home { launched += " with its home folder at \(home)" }
        lines.append(launched + ".")
        if !shown {
            if await MacAppDriver.shared.permissions().hasDisplay {
                lines.append("No window appeared within 15 seconds. It may still be starting, be waiting on something, or have no window (a menu bar app). app_logs shows its output.")
            } else {
                lines.append("No window appeared within 15 seconds, and this Mac has no active display (it's asleep, locked with the screen off, or headless), so apps can't show windows on it. Wake the Mac or connect a display (or a dummy HDMI plug), then launch again.")
            }
        }
        lines.append(MacToolSupport.footer(name: launch.name, id: launch.id, viewerURL: config.viewerURL(device: launch.id)))
        var content: [ToolContent] = [.text(lines.joined(separator: "\n"))]
        if shown, let session = await macApps.session(launch.id) {
            do {
                content += try await macScreenshotContent(session)
            } catch {
                content.append(.text("No screenshot: \(error.localizedDescription)"))
            }
        }
        return ToolResult(content)
    }

    // MARK: Seeing

    /// A screenshot of one window, sized so image pixels equal window points by default.
    func macScreenshotContent(_ session: MacAppSession, window: MacWindowSelector = .main, scale: Double? = nil, quality: Int = 70) async throws -> [ToolContent] {
        guard let pid = session.pid else { throw ToolError(MacToolSupport.notRunning(session)) }
        let shot = try await MacAppDriver.shared.screenshotJPEG(pid: pid, window: window, scale: scale, quality: quality)
        let note = MacToolSupport.screenshotNote(
            width: shot.width, height: shot.height, windowIndex: shot.window.index, title: shot.window.title,
            pointWidth: shot.window.frame.width, pointHeight: shot.window.frame.height
        )
        return [.image(data: shot.data, mimeType: "image/jpeg"), .text(note)]
    }

    /// Common tail for Mac input tools: a short note, plus a screenshot of the window if asked.
    func afterMacAction(_ note: String, session: MacAppSession, args: ToolArguments) async throws -> ToolResult {
        guard args.bool("screenshot") == true else { return .text(note) }
        try await Task.sleep(nanoseconds: 400_000_000) // let animations settle
        return ToolResult([.text(note)] + (try await macScreenshotContent(session, window: macWindow(args))))
    }

    // MARK: Mac branches of the shared tools

    func macScreenshot(_ args: ToolArguments) async throws -> ToolResult {
        let session = try await macApp(args)
        var content = try await macScreenshotContent(session, window: macWindow(args), scale: args.double("scale"), quality: args.int("quality") ?? 70)
        if args.bool("share") == true {
            content.append(.text(await shareMacScreenshot(session, window: macWindow(args), options: MediaShareOptions(args))))
        }
        return ToolResult(content)
    }

    func macDescribeUI(_ args: ToolArguments) async throws -> ToolResult {
        let session = try await macApp(args)
        var point: (x: Double, y: Double)?
        if let x = args.double("x"), let y = args.double("y") { point = (x, y) }
        let json = try await MacAppDriver.shared.describeUI(pid: session.pid!, window: macWindow(args), includeMenus: args.bool("include_menus") == true, at: point)
        if args.string("format") == "json" { return .text(String(decoding: json, as: UTF8.self)) }
        return .text("Frames are window points from the window's top-left, title bar included.\n" + XcodeParsing.summarizeAccessibility(json))
    }

    func macTap(_ args: ToolArguments) async throws -> ToolResult {
        let session = try await macApp(args)
        let pid = session.pid!
        let button = try macButton(args)
        let count = args.int("count") ?? 1
        let query: MacElementQuery?
        if let id = args.string("id") { query = .id(id) }
        else if let label = args.string("label") { query = .label(label) }
        else if let value = args.string("value") { query = .value(value) }
        else { query = nil }
        if let query {
            guard button == .left, count == 1 else {
                throw ToolError("Right and double clicks need x and y. describe_ui gives the element's frame.")
            }
            let point = try await MacAppDriver.shared.press(pid: pid, window: macWindow(args), query: query, wait: args.double("wait_seconds") ?? 2)
            return try await afterMacAction("Pressed the element at (\(Int(point.x)), \(Int(point.y))).", session: session, args: args)
        }
        let x = try args.requireDouble("x"), y = try args.requireDouble("y")
        let input = try macInput(args)
        let chosen: MacInputPath
        if let input { chosen = input } else { chosen = await MacAppDriver.shared.inputPath(pid: pid) }
        // Clicks posted to the pid don't work on SwiftUI controls, so a plain click on a button or
        // text field presses (or focuses) it through Accessibility instead.
        if chosen == .pid, button == .left, count == 1,
           let pressed = try await MacAppDriver.shared.pressElement(pid: pid, window: macWindow(args), x: x, y: y) {
            return try await afterMacAction("Pressed \(pressed) at (\(Int(x)), \(Int(y))) through Accessibility.", session: session, args: args)
        }
        let path = try await MacAppDriver.shared.click(pid: pid, window: macWindow(args), x: x, y: y, button: button, count: count, path: input)
        let what = count >= 2 ? "Double-clicked" : (button == .right ? "Right-clicked" : "Clicked")
        return try await afterMacAction("\(what) (\(Int(x)), \(Int(y))).\(MacToolSupport.inputNote(path.rawValue))", session: session, args: args)
    }

    func macButton(_ args: ToolArguments) throws -> MacMouseButton {
        guard let name = args.string("button") else { return .left }
        guard let button = MacMouseButton(rawValue: name.lowercased()) else { throw ToolError("Unknown button \(name). Use left or right.") }
        return button
    }

    func macSwipe(_ args: ToolArguments) async throws -> ToolResult {
        let session = try await macApp(args)
        let pid = session.pid!
        typealias Point = (x: Double, y: Double)
        let line: (from: Point, to: Point)
        if let direction = args.string("direction") {
            let frame = try await MacAppDriver.shared.window(pid: pid, macWindow(args)).frame
            let cx = frame.width / 2, cy = frame.height / 2, dx = frame.width * 0.3, dy = frame.height * 0.3
            switch direction {
            case "up": line = ((cx, cy + dy), (cx, cy - dy))
            case "down": line = ((cx, cy - dy), (cx, cy + dy))
            case "left": line = ((cx + dx, cy), (cx - dx, cy))
            default: line = ((cx - dx, cy), (cx + dx, cy))
            }
        } else {
            line = ((try args.requireDouble("from_x"), try args.requireDouble("from_y")),
                    (try args.requireDouble("to_x"), try args.requireDouble("to_y")))
        }
        let (from, to) = line
        let path = try await MacAppDriver.shared.drag(pid: pid, window: macWindow(args), from: from, to: to, duration: args.double("duration") ?? 0.4, path: try macInput(args))
        return try await afterMacAction(
            "Dragged (\(Int(from.x)),\(Int(from.y))) → (\(Int(to.x)),\(Int(to.y))) with the mouse.\(MacToolSupport.inputNote(path.rawValue)) To scroll, use scroll.",
            session: session, args: args
        )
    }

    func macLongPress(_ args: ToolArguments) async throws -> ToolResult {
        let session = try await macApp(args)
        let start = (x: try args.requireDouble("x"), y: try args.requireDouble("y"))
        let end = (x: args.double("to_x") ?? start.x, y: args.double("to_y") ?? start.y)
        let moving = end.x != start.x || end.y != start.y
        let path = try await MacAppDriver.shared.drag(
            pid: session.pid!, window: macWindow(args), from: start, to: end, duration: moving ? 0.5 : 0.01, hold: args.double("duration") ?? 1, path: try macInput(args)
        )
        return try await afterMacAction("Held the mouse down at (\(Int(start.x)), \(Int(start.y))).\(MacToolSupport.inputNote(path.rawValue))", session: session, args: args)
    }

    func macTypeText(_ args: ToolArguments) async throws -> ToolResult {
        let session = try await macApp(args)
        guard let text = args.rawString("text") else { throw ToolError("Missing `text`.") }
        let input = try macInput(args)
        let path = try await MacAppDriver.shared.typeText(pid: session.pid!, text: text, path: input)
        if args.bool("submit") == true { _ = try await MacAppDriver.shared.pressKey(pid: session.pid!, key: "return", path: input) }
        return try await afterMacAction("Typed \(text.count) characters.\(MacToolSupport.inputNote(path.rawValue))", session: session, args: args)
    }

    func macPressKey(_ args: ToolArguments) async throws -> ToolResult {
        let session = try await macApp(args)
        let (key, modifiers) = try MacToolSupport.keyAndModifiers(key: try args.requireString("key"), modifiers: args.strings("modifiers"))
        let path = try await MacAppDriver.shared.pressKey(pid: session.pid!, key: key, modifiers: modifiers, path: try macInput(args))
        let combo = (modifiers.names + [key]).joined(separator: "+")
        return try await afterMacAction("Pressed \(combo).\(MacToolSupport.inputNote(path.rawValue))", session: session, args: args)
    }

    func macLaunchApp(_ args: ToolArguments) async throws -> ToolResult {
        let device = args.string("device") ?? "mac"
        var id: String, label: String?
        var appPath = args.string("app_path").map { ($0 as NSString).expandingTildeInPath }
        if let bundle = args.string("bundle_id"), appPath == nil {
            guard let found = await MacAppDriver.shared.appPath(forBundleID: bundle) else {
                throw ToolError("No app with bundle id \(bundle) is installed where macOS can find it. Pass app_path instead.")
            }
            appPath = found
        }
        if device.lowercased() == "mac" {
            id = MacAppID.random()
            while await macApps.session(id) != nil { id = MacAppID.random() }
        } else {
            guard let existing = await macApps.session(device) else { throw ToolError(MacToolSupport.unknownApp(device, known: await refreshedMacApps())) }
            id = existing.id
            label = existing.label
            if appPath == nil { appPath = existing.appPath }
        }
        guard let appPath else { throw ToolError("Pass app_path (a .app on the Mac) or bundle_id to launch a Mac app.") }
        guard let bundle = Bundle(path: appPath), let executable = bundle.executablePath else {
            throw ToolError("\(appPath) isn't an app bundle with an executable.")
        }
        let name = MacToolSupport.appName(appPath: appPath, productName: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
        var launch = MacLaunch(id: id, label: label, name: name, bundleID: bundle.bundleIdentifier, appPath: appPath, executablePath: executable)
        launch.arguments = args.strings("arguments")
        launch.environment = args.raw["environment"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
        if args.bool("isolated_home") == true {
            launch.home = MacToolSupport.isolatedHome(appPath: appPath, id: id, fallbackRoot: MiniRunConfig.home + "/minirun/mac-homes")
        }
        return try await whileUsingMac(id) { try await launchMac(launch, intro: []) }
    }

    func macTerminate(_ args: ToolArguments) async throws -> ToolResult {
        .text(try await quitMacApp(id: args.string("device") ?? ""))
    }

    func macAppLogs(_ args: ToolArguments) async throws -> ToolResult {
        let session = try await macApp(args, running: false)
        // A quit app's log lines are found by the pid it had, between its launch and when it
        // quit; never by process name, which other branches' copies of the app share.
        let pid = session.pid ?? session.lastPid
        let until = session.pid == nil ? (session.exitedAt ?? Date()) : nil
        let text = try await MacAppDriver.shared.logs(
            pid: pid, capturedLog: session.logPath.map { URL(fileURLWithPath: $0) },
            since: session.launchedAt, until: until, seconds: args.int("seconds") ?? 300, filter: args.string("contains")
        )
        return .text(text)
    }

    func macOpenURL(_ args: ToolArguments) async throws -> ToolResult {
        let session = try await macApp(args)
        let url = try args.requireString("url")
        let how = try await MacAppDriver.shared.openURL(url, pid: session.pid!, bundleID: session.bundleID, appPath: session.appPath)
        return .text("Opened \(url) in \(session.name) \(how).")
    }

    func macSetPasteboard(_ args: ToolArguments) async throws -> ToolResult {
        await MacAppDriver.shared.setPasteboard(args.rawString("text") ?? "")
        return .text("Set the Mac's pasteboard. It's shared by every app and session on this Mac, so paste soon (command+v with press_key).")
    }

    // MARK: Live view

    /// One step of a viewer's live mouse gesture on a Mac app's window. The button goes down only
    /// once the pointer moves (a drag); a click without movement presses the control under it
    /// through Accessibility, since SwiftUI controls ignore clicks posted to the app, and is posted
    /// as a click only where there's no control.
    func macMouse(id: String, phase: String, x: Double, y: Double) async throws {
        guard let session = await macApps.session(id), let pid = session.pid else { throw ToolError("No running Mac app with id \(id).") }
        // Like every other path: the recorded pid must still be the app minirun launched.
        guard MacAppDriver.isRunning(session) else {
            await macApps.markExited(session.id, ifPid: pid)
            throw ToolError(MacToolSupport.notRunning(session))
        }
        await macApps.touch(id)
        // The window the viewer is looking at, not whichever is main by now.
        let window = streamedMacWindows[id].map { MacWindowSelector.id($0) } ?? .main
        switch await liveMouse.step(id: id, phase: phase, x: x, y: y) {
        case .none:
            break
        case .post(let events):
            for event in events { try await MacAppDriver.shared.mouse(pid: pid, window: window, phase: event.phase, x: event.x, y: event.y) }
        case .click(let x, let y):
            if try await MacAppDriver.shared.pressElement(pid: pid, window: window, x: x, y: y) == nil {
                try await MacAppDriver.shared.mouse(pid: pid, window: window, phase: "down", x: x, y: y)
                try await MacAppDriver.shared.mouse(pid: pid, window: window, phase: "up", x: x, y: y)
            }
        }
    }

    /// Where viewers' live mouse gestures on Mac apps are (see `MacLiveMouse`).
    actor LiveMouse {
        private var state = MacLiveMouse()
        func step(id: String, phase: String, x: Double, y: Double) -> MacLiveMouse.Action { state.step(id: id, phase: phase, x: x, y: y) }
        func reset() { state = MacLiveMouse() }
    }

    /// Running Mac apps as `simulators` message entries, for the viewer's picker.
    func macPickerEntries() async -> [JSONValue] {
        await refreshedMacApps().filter(\.isRunning).map(MacToolSupport.pickerEntry)
    }

    // MARK: Idle quitting

    /// Quits Mac apps minirun launched that nobody has used for `idleShutdownMinutes` (see
    /// `IdleMacApps.plan`). A running job or an open live view counts as use.
    func quitIdleMacAppsOnce(log: @Sendable (String) -> Void) async {
        let minutes = config.idleShutdownMinutes
        let sessions = await refreshedMacApps()
        let busy = await activity.busy
        for id in IdleMacApps.plan(sessions, busy: busy, idleAfter: Double(minutes) * 60) {
            guard let planned = sessions.first(where: { $0.id == id }), let plannedPid = planned.pid else { continue }
            let quit = try? await macLaunches.withLock(id) { () async -> MacAppSession? in
                // Look again under the lock: it may have been relaunched, used or quit since the plan.
                guard let session = await macApps.session(id), let pid = session.pid, pid == plannedPid,
                      session.updatedAt <= planned.updatedAt, !(await activity.busy).contains(id) else { return nil }
                await MacAppDriver.shared.terminate(pid: pid, grace: 5, executablePath: session.executablePath, start: session.processStart)
                await macApps.markExited(id, ifPid: pid)
                return session
            }
            guard let session = quit ?? nil else { continue }
            log("Quit \(session.name) (\(id)\(session.label.map { ", \($0)" } ?? "")): not used for \(minutes) min.")
        }
    }
}
