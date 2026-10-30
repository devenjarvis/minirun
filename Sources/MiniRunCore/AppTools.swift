import Foundation
import MiniRunKit
import MiniRunSim

extension ToolRegistry {
    func registerAppTools() {
        let device = Self.deviceProperty

        register(ToolDefinition(
            name: "install_app",
            description: "Install a .app bundle that's already on the Mac (for example one produced by build).",
            properties: device.merging(["app_path": Schema.string("Absolute path to the .app on the Mac.")]) { a, _ in a },
            required: ["app_path"]
        )) { [self] args in
            let sim = try await self.device(args)
            let path = try args.requireString("app_path")
            try await Simctl.install(sim.udid, appPath: path)
            if let bundle = Bundle(path: path)?.bundleIdentifier { await claims.noteApp(sim.udid, bundleID: bundle) }
            return .text("Installed \(URL(fileURLWithPath: path).lastPathComponent) on \(sim.name) (\(sim.udid)).")
        }

        register(ToolDefinition(
            name: "launch_app",
            description: "Launch an installed app by bundle id (relaunching it if already running) and return a screenshot.",
            properties: device.merging([
                "bundle_id": Schema.string("Bundle identifier, e.g. com.apple.Preferences."),
                "arguments": Schema.stringArray("Launch arguments."),
                "environment": ["type": "object", "additionalProperties": ["type": "string"], "description": "Environment variables for the app."],
            ]) { a, _ in a },
            required: ["bundle_id"]
        )) { [self] args in
            let sim = try await self.device(args)
            let bundle = try args.requireString("bundle_id")
            let env = args.raw["environment"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
            let pid = try await Simctl.launch(sim.udid, bundleID: bundle, arguments: args.strings("arguments"), environment: env)
            // The new app may be landscape-only, which changes how taps map to the screen.
            await SimulatorDriver.shared.forgetCoordinateMapping(udid: sim.udid)
            await claims.noteApp(sim.udid, bundleID: bundle)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            return ToolResult([.text("Launched \(bundle) (pid \(pid)) on \(sim.name) (\(sim.udid)).")] + ((try? await screenshotContent(udid: sim.udid)) ?? []))
        }

        register(ToolDefinition(
            name: "terminate_app",
            description: "Quit a running app.",
            properties: device.merging(["bundle_id": Schema.string("Bundle identifier.")]) { a, _ in a },
            required: ["bundle_id"]
        )) { [self] args in
            let sim = try await self.device(args)
            try await Simctl.terminate(sim.udid, bundleID: try args.requireString("bundle_id"))
            return .text("Terminated \(args.string("bundle_id")!).")
        }

        register(ToolDefinition(
            name: "uninstall_app",
            description: "Remove an app (and its data) from the simulator.",
            properties: device.merging(["bundle_id": Schema.string("Bundle identifier.")]) { a, _ in a },
            required: ["bundle_id"]
        )) { [self] args in
            let sim = try await self.device(args)
            try await Simctl.uninstall(sim.udid, bundleID: try args.requireString("bundle_id"))
            return .text("Uninstalled \(args.string("bundle_id")!).")
        }

        register(ToolDefinition(
            name: "app_logs",
            description: "Read recent log output (print/os_log/NSLog) from the simulator, filtered to an app. Use after reproducing a bug.",
            properties: device.merging([
                "bundle_id": Schema.string("Filter to this app's process."),
                "process": Schema.string("Or filter by process name."),
                "seconds": Schema.integer("How far back to read (default 60).", minimum: 1, maximum: 3600),
                "contains": Schema.string("Only lines containing this text (case-insensitive)."),
            ]) { a, _ in a }
        )) { [self] args in
            let sim = try await self.device(args)
            var process = args.string("process")
            if process == nil, let bundle = args.string("bundle_id") {
                process = await Simctl.executableName(sim.udid, bundleID: bundle)
                if process == nil { throw ToolError("\(bundle) isn't installed on \(sim.name).") }
            }
            let text = try await Simctl.logs(sim.udid, process: process, seconds: args.int("seconds") ?? 60, filter: args.string("contains"))
            return .text(text.isEmpty ? "No matching log lines." : text)
        }

        register(ToolDefinition(
            name: "add_media",
            description: "Add photos or videos (files on the Mac) to the simulator's Photos library.",
            properties: device.merging(["paths": Schema.stringArray("Absolute paths on the Mac.")]) { a, _ in a },
            required: ["paths"]
        )) { [self] args in
            let sim = try await self.device(args)
            let paths = args.strings("paths")
            guard !paths.isEmpty else { throw ToolError("Pass at least one path.") }
            try await Simctl.addMedia(sim.udid, paths: paths)
            return .text("Added \(paths.count) file(s) to Photos.")
        }
    }
}
