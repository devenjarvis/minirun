import Foundation
import MiniRunKit
import MiniRunSim

extension ToolRegistry {
    static let deviceProperty: [String: JSONValue] = [
        "device": Schema.string(
            "UDID of the simulator to act on (a name like \"iPhone 17 Pro\" also works). Other Claude sessions may be using this Mac, " +
            "so once you have a simulator, pass its UDID on every call. If omitted and several simulators are booted, the call fails " +
            "and lists them instead of guessing."
        ),
    ]

    func registerSimulatorTools() {
        let device = Self.deviceProperty

        register(ToolDefinition(
            name: "list_simulators",
            description: "List the iOS simulators installed on the Mac, booted ones first. Booted ones show what they're reserved for (the repo@branch being built there) so you can find yours.",
            properties: ["include_shutdown": Schema.boolean("Include simulators that aren't booted (default true).")]
        )) { [self] args in
            let all = try await Simctl.devices().filter(\.isAvailable)
            let claims = await claimSnapshot(all)
            let shown = args.bool("include_shutdown") == false ? all.filter(\.isBooted) : all
            return .json(.array(shown.prefix(60).map { device -> JSONValue in
                var json = device.json.objectValue ?? [:]
                if device.isBooted, let claim = claims[device.udid] {
                    if let label = claim.label { json["reserved_for"] = .string(label) }
                    if let bundle = claim.bundleID { json["last_app"] = .string(bundle) }
                }
                return .object(json)
            }))
        }

        register(ToolDefinition(
            name: "boot_simulator",
            description: "Get a simulator of your own: boots one that no one else is using (creating a copy if every simulator of that model is busy) " +
                "and reserves it for `label`. Returns its UDID — pass it as `device` on every later call — plus the live view link for the user. " +
                "Calling again with the same label returns the same simulator. build_and_run does this for you if you don't pass device. " +
                "A new simulator's first boot can take a few minutes: if it's still going after wait_seconds you get a job_id for get_job.",
            properties: Self.waitProperty.merging([
                "device": Schema.string("Optional model name (e.g. \"iPhone 17 Pro\", or \"iPad Air 11-inch (M3)\"), or a specific UDID. Defaults to the Mac's default iPhone."),
                "label": Schema.string("What you're working on, as owner/repo@branch (e.g. \"you/app@feature-x\") — the same name builds of that repo and ref use, so they find this simulator."),
            ]) { a, _ in a }
        )) { [self] args in
            let label = args.string("label")
            return await runAsJob(args, title: "boot simulator" + (label.map { " for \($0)" } ?? ""), log: nil) { [self] in
                let (sim, note, wasBooted) = try await allocation.withLock("simulators") { () async throws -> (XcodeParsing.SimDevice, String?, Bool) in
                    let all = try await Simctl.devices()
                    let choice = SimulatorPicker.fresh(
                        query: args.string("device"), label: label, devices: all,
                        claims: await claimSnapshot(all), preferredName: config.defaultDevice
                    )
                    var wasBooted = false
                    if case .use(let device, _) = choice { wasBooted = device.isBooted }
                    let (sim, note) = try await realize(choice, boot: true)
                    if let label { await claims.reserve(sim.udid, for: label) } else { await claims.touch(sim.udid) }
                    return (sim, note, wasBooted)
                }
                await geometry.invalidate(udid: sim.udid)
                var lines = [wasBooted ? "\(sim.name) (\(sim.runtimeName)) is already running." : "Booted \(sim.name) (\(sim.runtimeName))."]
                if let note { lines.append(note) }
                if let label { lines.append("Reserved for \(label).") }
                lines.append(deviceFooter(sim))
                return ToolResult([.text(lines.joined(separator: "\n"))] + ((try? await screenshotContent(udid: sim.udid)) ?? []))
            }
        }

        register(ToolDefinition(
            name: "shutdown_simulator",
            description: "Shut down a simulator and release its reservation. Only shut down your own simulator: others may belong to another session.",
            properties: device,
            required: ["device"]
        )) { [self] args in
            let sim = try await self.device(args, boot: false)
            try await Simctl.shutdown(sim.udid)
            await claims.release(sim.udid)
            await SimulatorDriver.shared.reset(udid: sim.udid)
            await geometry.invalidate(udid: sim.udid)
            return .text("Shut down \(sim.name).")
        }

        register(ToolDefinition(
            name: "screenshot",
            description: "Take a screenshot of the simulator. By default the image is sized so one pixel equals one screen point, matching the coordinates tap, swipe and describe_ui use.",
            properties: device.merging([
                "scale": Schema.number("Optional scale relative to native pixels (0.1–1). Omit to match points.", minimum: 0.1, maximum: 1),
                "quality": Schema.integer("JPEG quality 10–95 (default 70).", minimum: 10, maximum: 95),
            ]) { a, _ in a }
        )) { [self] args in
            let sim = try await self.device(args)
            return ToolResult(try await screenshotContent(udid: sim.udid, scale: args.double("scale"), quality: args.int("quality") ?? 70))
        }

        register(ToolDefinition(
            name: "describe_ui",
            description: "Read the accessibility tree of what's on screen: element types, labels, ids, values and frames in points. Prefer this over guessing coordinates from a screenshot. Pass x and y to describe just the element at that point.",
            properties: device.merging([
                "x": Schema.number("Optional x in points."),
                "y": Schema.number("Optional y in points."),
                "format": Schema.string("\"text\" (compact, default) or \"json\" (full AXe JSON).", enum: ["text", "json"]),
            ]) { a, _ in a }
        )) { [self] args in
            let sim = try await self.device(args)
            let json = try await SimulatorDriver.shared.describeUI(udid: sim.udid, x: args.double("x"), y: args.double("y"))
            if args.string("format") == "json" { return .text(String(decoding: json, as: UTF8.self)) }
            return .text(XcodeParsing.summarizeAccessibility(json))
        }

        register(ToolDefinition(
            name: "tap",
            description: "Tap the screen at x,y (points), or tap an element found by accessibility id, label or value. Set screenshot=true to get the screen afterwards.",
            properties: device.merging([
                "x": Schema.number("X in points."),
                "y": Schema.number("Y in points."),
                "id": Schema.string("Accessibility identifier to tap."),
                "label": Schema.string("Accessibility label to tap."),
                "value": Schema.string("Accessibility value to tap."),
                "wait_seconds": Schema.number("When tapping by id/label/value, keep looking for the element this long (default 2).", minimum: 0, maximum: 30),
                "screenshot": Schema.boolean("Return a screenshot after the tap (default false)."),
            ]) { a, _ in a }
        )) { [self] args in
            let sim = try await self.device(args)
            let query: SimulatorDriver.ElementQuery?
            if let id = args.string("id") { query = .id(id) }
            else if let label = args.string("label") { query = .label(label) }
            else if let value = args.string("value") { query = .value(value) }
            else { query = nil }
            let point = try await SimulatorDriver.shared.tap(
                udid: sim.udid, x: args.double("x"), y: args.double("y"), query: query, wait: args.double("wait_seconds") ?? 2
            )
            return try await afterAction("Tapped (\(Int(point.x)), \(Int(point.y))).", udid: sim.udid, args: args)
        }

        register(ToolDefinition(
            name: "swipe",
            description: "Swipe from one point to another (points). Or pass direction to scroll the middle of the screen: \"up\" scrolls content up (finger moves up).",
            properties: device.merging([
                "from_x": Schema.number("Start x."), "from_y": Schema.number("Start y."),
                "to_x": Schema.number("End x."), "to_y": Schema.number("End y."),
                "direction": Schema.string("Shortcut instead of coordinates.", enum: ["up", "down", "left", "right"]),
                "duration": Schema.number("Seconds (default 0.4).", minimum: 0.05, maximum: 5),
                "screenshot": Schema.boolean("Return a screenshot afterwards."),
            ]) { a, _ in a }
        )) { [self] args in
            let sim = try await self.device(args)
            typealias Point = (x: Double, y: Double)
            let path: (from: Point, to: Point)
            if let direction = args.string("direction") {
                let size = await geometry.pointSize(udid: sim.udid) ?? (width: 402, height: 874)
                let cx = size.width / 2, cy = size.height / 2
                let dx = size.width * 0.3, dy = size.height * 0.3
                switch direction {
                case "up": path = ((cx, cy + dy), (cx, cy - dy))
                case "down": path = ((cx, cy - dy), (cx, cy + dy))
                case "left": path = ((cx + dx, cy), (cx - dx, cy))
                default: path = ((cx - dx, cy), (cx + dx, cy))
                }
            } else {
                path = ((try args.requireDouble("from_x"), try args.requireDouble("from_y")),
                        (try args.requireDouble("to_x"), try args.requireDouble("to_y")))
            }
            let (from, to) = path
            try await SimulatorDriver.shared.swipe(udid: sim.udid, from: from, to: to, duration: args.double("duration") ?? 0.4)
            return try await afterAction("Swiped (\(Int(from.x)),\(Int(from.y))) → (\(Int(to.x)),\(Int(to.y))).", udid: sim.udid, args: args)
        }

        register(ToolDefinition(
            name: "long_press",
            description: "Press and hold at a point, optionally dragging to another point before releasing (for context menus, reordering, sliders).",
            properties: device.merging([
                "x": Schema.number("X in points."), "y": Schema.number("Y in points."),
                "to_x": Schema.number("Optional x to drag to."), "to_y": Schema.number("Optional y to drag to."),
                "duration": Schema.number("Hold time in seconds (default 1).", minimum: 0.1, maximum: 10),
                "screenshot": Schema.boolean("Return a screenshot afterwards."),
            ]) { a, _ in a },
            required: ["x", "y"]
        )) { [self] args in
            let sim = try await self.device(args)
            let start = (x: try args.requireDouble("x"), y: try args.requireDouble("y"))
            let end = (x: args.double("to_x") ?? start.x, y: args.double("to_y") ?? start.y)
            let hold = args.double("duration") ?? 1
            let moving = end.x != start.x || end.y != start.y
            try await SimulatorDriver.shared.drag(udid: sim.udid, from: start, to: end, duration: moving ? 0.5 : 0.01, hold: hold)
            return try await afterAction("Long-pressed (\(Int(start.x)), \(Int(start.y))).", udid: sim.udid, args: args)
        }

        register(ToolDefinition(
            name: "type_text",
            description: "Type text into the focused field using the hardware keyboard (US keyboard characters). Tap the field first. Set submit=true to press Return afterwards.",
            properties: device.merging([
                "text": Schema.string("Text to type."),
                "submit": Schema.boolean("Press Return after typing."),
                "screenshot": Schema.boolean("Return a screenshot afterwards."),
            ]) { a, _ in a },
            required: ["text"]
        )) { [self] args in
            let sim = try await self.device(args)
            guard let text = args.rawString("text") else { throw ToolError("Missing `text`.") }
            try await SimulatorDriver.shared.typeText(udid: sim.udid, text: text)
            if args.bool("submit") == true { try await SimulatorDriver.shared.pressKey(udid: sim.udid, name: "return") }
            return try await afterAction("Typed \(text.count) characters.", udid: sim.udid, args: args)
        }

        register(ToolDefinition(
            name: "press_key",
            description: "Press a keyboard key: return, delete, tab, escape, space, up, down, left, right.",
            properties: device.merging(["key": Schema.string("Key name.")]) { a, _ in a },
            required: ["key"]
        )) { [self] args in
            let sim = try await self.device(args)
            try await SimulatorDriver.shared.pressKey(udid: sim.udid, name: try args.requireString("key"))
            return try await afterAction("Pressed \(args.string("key")!).", udid: sim.udid, args: args)
        }

        register(ToolDefinition(
            name: "press_button",
            description: "Press a hardware button: home (go to the home screen), lock, siri, side-button, apple-pay.",
            properties: device.merging([
                "button": Schema.string("Button.", enum: SimulatorDriver.Button.allCases.map(\.rawValue)),
                "duration": Schema.number("Hold for this many seconds (default: a short press).", minimum: 0, maximum: 10),
                "screenshot": Schema.boolean("Return a screenshot afterwards."),
            ]) { a, _ in a },
            required: ["button"]
        )) { [self] args in
            let sim = try await self.device(args)
            let name = try args.requireString("button")
            guard let button = SimulatorDriver.Button(rawValue: name) else { throw ToolError("Unknown button \(name).") }
            try await SimulatorDriver.shared.pressButton(udid: sim.udid, button: button, duration: args.double("duration"))
            return try await afterAction("Pressed \(name).", udid: sim.udid, args: args)
        }

        register(ToolDefinition(
            name: "open_url",
            description: "Open a URL in the simulator: a web page in Safari, or a deep link / custom scheme into an app.",
            properties: device.merging(["url": Schema.string("URL to open.")]) { a, _ in a },
            required: ["url"]
        )) { [self] args in
            let sim = try await self.device(args)
            try await Simctl.openURL(sim.udid, url: try args.requireString("url"))
            return .text("Opened \(args.string("url")!).")
        }

        register(ToolDefinition(
            name: "set_pasteboard",
            description: "Put text on the simulator's pasteboard (useful for text type_text can't type, like emoji or non-US characters).",
            properties: device.merging(["text": Schema.string("Text to copy.")]) { a, _ in a },
            required: ["text"]
        )) { [self] args in
            let sim = try await self.device(args)
            try await Simctl.setPasteboard(sim.udid, text: args.rawString("text") ?? "")
            return .text("Pasteboard set.")
        }

        register(ToolDefinition(
            name: "configure_simulator",
            description: "Change simulator settings: appearance, simulated location, a clean demo status bar, or app permissions.",
            properties: device.merging([
                "appearance": Schema.string("Light or dark mode.", enum: ["light", "dark"]),
                "latitude": Schema.number("Simulated location latitude (with longitude)."),
                "longitude": Schema.number("Simulated location longitude."),
                "status_bar": Schema.string("\"demo\" for 9:41 / full battery, \"clear\" to restore.", enum: ["demo", "clear"]),
                "permission": Schema.string("Permission service to change, e.g. photos, camera, location, contacts, microphone, all."),
                "permission_action": Schema.string("grant, revoke or reset.", enum: ["grant", "revoke", "reset"]),
                "bundle_id": Schema.string("App the permission applies to."),
            ]) { a, _ in a }
        )) { [self] args in
            let sim = try await self.device(args)
            var done: [String] = []
            if let appearance = args.string("appearance") {
                try await Simctl.setAppearance(sim.udid, dark: appearance == "dark")
                done.append("appearance \(appearance)")
            }
            if let lat = args.double("latitude"), let lon = args.double("longitude") {
                try await Simctl.setLocation(sim.udid, latitude: lat, longitude: lon)
                done.append("location \(lat),\(lon)")
            }
            if let bar = args.string("status_bar") {
                try await Simctl.overrideStatusBar(sim.udid, clear: bar == "clear")
                done.append("status bar \(bar)")
            }
            if let service = args.string("permission") {
                let bundle = try args.requireString("bundle_id")
                let action = args.string("permission_action") ?? "grant"
                try await Simctl.privacy(sim.udid, action: action, service: service, bundleID: bundle)
                done.append("\(action) \(service) for \(bundle)")
            }
            return .text(done.isEmpty ? "Nothing to change." : "Set " + done.joined(separator: ", ") + ".")
        }
    }

    /// Common tail for input tools: a short note, plus a screenshot if asked.
    func afterAction(_ note: String, udid: String, args: ToolArguments) async throws -> ToolResult {
        guard args.bool("screenshot") == true else { return .text(note) }
        try await Task.sleep(nanoseconds: 600_000_000) // let animations settle
        return ToolResult([.text(note)] + (try await screenshotContent(udid: udid)))
    }
}
