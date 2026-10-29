import Foundation
import MiniRunKit
import MiniRunSim

extension ToolRegistry {
    static let sourceProperties: [String: JSONValue] = [
        "repo": Schema.string("GitHub repository as owner/name (or a clone URL). It's cloned on the Mac under ~/minirun/workspaces."),
        "ref": Schema.string("Branch, tag or commit to check out first. Push your changes, then pass the branch here so the Mac builds exactly that."),
        "path": Schema.string("Instead of repo: a directory on the Mac (absolute, or relative to the workspaces folder)."),
        "project": Schema.string("Optional .xcworkspace / .xcodeproj / Package.swift path inside the checkout. Found automatically if omitted."),
        "scheme": Schema.string("Scheme to build. Picked automatically if omitted; see list_schemes."),
    ]

    static let waitProperty: [String: JSONValue] = [
        "wait_seconds": Schema.number("How long to wait for the job before returning a job id to poll (default 45, max 600).", minimum: 0, maximum: 600),
    ]

    func registerCodeTools() {
        let device = Self.deviceProperty
        let source = Self.sourceProperties
        let wait = Self.waitProperty

        register(ToolDefinition(
            name: "host_info",
            description: "Describe the Mac: macOS and Xcode versions, installed simulator runtimes, free disk space, and checked-out repositories.",
            properties: [:]
        )) { [self] _ in
            async let xcode = Shell.run("/usr/bin/xcrun", ["xcodebuild", "-version"], timeout: 60)
            async let runtimes = Shell.run("/usr/bin/xcrun", ["simctl", "list", "runtimes"], timeout: 60)
            let os = ProcessInfo.processInfo.operatingSystemVersionString
            let free = (try? FileManager.default.attributesOfFileSystem(forPath: MiniRunConfig.home)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            let repos = (try? FileManager.default.contentsOfDirectory(atPath: config.workspaceRoot))?.flatMap { owner in
                ((try? FileManager.default.contentsOfDirectory(atPath: config.workspaceRoot + "/" + owner)) ?? []).map { "\(owner)/\($0)" }
            } ?? []
            let text = """
            macOS: \(os)
            Xcode: \((try? await xcode)?.stdout.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) ?? "not found")
            Free disk: \(free / 1_000_000_000) GB
            Shell commands (run_command): \(config.allowShell ? "enabled" : "disabled — set allowShell in ~/.config/minirun/config.json")
            Workspaces (\(config.workspaceRoot)): \(repos.isEmpty ? "none" : repos.sorted().joined(separator: ", "))

            \((try? await runtimes)?.stdout ?? "")
            """
            return .text(text)
        }

        register(ToolDefinition(
            name: "sync_repo",
            description: "Clone or update a GitHub repository on the Mac and check out a branch, tag or commit. Uncommitted changes in the Mac's checkout are discarded.",
            properties: [
                "repo": Schema.string("owner/name or clone URL."),
                "ref": Schema.string("Branch, tag or commit (default: the default branch)."),
            ].merging(wait) { a, _ in a },
            required: ["repo"]
        )) { [self] args in
            let repo = try args.requireString("repo")
            let ref = args.string("ref")
            let log = newLogURL("sync")
            return await runAsJob(args, title: "sync \(repo)", log: log) { [config] in
                let checkout = try await Workspace.sync(repo: repo, ref: ref, config: config, log: log)
                return .text("\(checkout.slug) at \(checkout.commit.prefix(10)) “\(checkout.subject)”\nPath: \(checkout.path)")
            }
        }

        register(ToolDefinition(
            name: "list_schemes",
            description: "List the Xcode schemes in a checked-out repository.",
            properties: ["repo": source["repo"]!, "path": source["path"]!, "project": source["project"]!]
        )) { [self] args in
            let dir = try Workspace.directory(repo: args.string("repo"), path: args.string("path"), config: config)
            let (container, schemes) = try await XcodeBuild.schemes(directory: dir, project: args.string("project"))
            return .text("\(container.description): \(schemes.isEmpty ? "no shared schemes" : schemes.joined(separator: ", "))")
        }

        register(ToolDefinition(
            name: "build",
            description: "Build an app for the simulator with xcodebuild. Pass repo + ref to sync first. Returns errors with file:line on failure, or the .app path and bundle id. Runs as a job: if it's still going after wait_seconds you get a job_id for get_job.",
            properties: source.merging(device) { a, _ in a }.merging([
                "configuration": Schema.string("Build configuration (default Debug)."),
                "extra_args": Schema.stringArray("Extra xcodebuild arguments, e.g. [\"CODE_SIGNING_ALLOWED=NO\"]."),
            ]) { a, _ in a }.merging(wait) { a, _ in a }
        )) { [self] args in
            let sim = try await self.device(args)
            let log = newLogURL("build")
            return await runAsJob(args, title: "build", log: log) { [self] in
                let output = try await self.buildApp(args, udid: sim.udid, log: log)
                return .text(self.describe(output, log: log))
            }
        }

        register(ToolDefinition(
            name: "build_and_run",
            description: "The main loop: sync (if ref given), build, install and launch the app on the simulator, then return a screenshot. Errors come back with file:line so you can fix and push again.",
            properties: source.merging(device) { a, _ in a }.merging([
                "configuration": Schema.string("Build configuration (default Debug)."),
                "extra_args": Schema.stringArray("Extra xcodebuild arguments."),
                "launch_arguments": Schema.stringArray("Arguments passed to the app at launch."),
                "environment": ["type": "object", "additionalProperties": ["type": "string"], "description": "Environment variables for the app."],
            ]) { a, _ in a }.merging(wait) { a, _ in a }
        )) { [self] args in
            let sim = try await self.device(args)
            let log = newLogURL("build-and-run")
            return await runAsJob(args, title: "build and run", log: log) { [self] in
                let output = try await self.buildApp(args, udid: sim.udid, log: log)
                guard let product = output.product, let bundle = product.bundleIdentifier else {
                    throw ToolError("Built \(output.scheme), but it doesn't produce an iOS app to launch. Use build or run_tests for this scheme.")
                }
                try await Simctl.install(sim.udid, appPath: product.appPath)
                let env = args.raw["environment"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
                let pid = try await Simctl.launch(sim.udid, bundleID: bundle, arguments: args.strings("launch_arguments"), environment: env)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                var content: [ToolContent] = [.text(self.describe(output, log: log) + "\nInstalled and launched on \(sim.name) (pid \(pid)).")]
                content += (try? await self.screenshotContent(udid: sim.udid)) ?? []
                return ToolResult(content)
            }
        }

        register(ToolDefinition(
            name: "run_tests",
            description: "Run a scheme's unit/UI tests on the simulator and report pass/fail with failure messages. Runs as a job.",
            properties: source.merging(device) { a, _ in a }.merging([
                "only_testing": Schema.stringArray("Limit to these tests, e.g. [\"AppTests/LoginTests/testValidLogin\"]."),
                "skip_testing": Schema.stringArray("Skip these tests."),
                "configuration": Schema.string("Build configuration (default Debug)."),
                "extra_args": Schema.stringArray("Extra xcodebuild arguments."),
            ]) { a, _ in a }.merging(wait) { a, _ in a }
        )) { [self] args in
            let sim = try await self.device(args)
            let log = newLogURL("test")
            return await runAsJob(args, title: "tests", log: log) { [self] in
                let dir = try await self.sourceDirectory(args, log: log)
                var options = XcodeBuild.Options(directory: dir, project: args.string("project"), scheme: args.string("scheme"), udid: sim.udid, log: log)
                options.configuration = args.string("configuration") ?? "Debug"
                options.extraArgs = args.strings("extra_args")
                let output = try await XcodeBuild.test(options, onlyTesting: args.strings("only_testing"), skipTesting: args.strings("skip_testing"))
                let text = "Scheme \(output.scheme): \(output.passed ? "passed" : "FAILED")\n\(output.summary)\nResult bundle: \(output.resultBundle)\nLog: \(log.path)"
                return ToolResult([.text(text)], isError: !output.passed)
            }
        }

        register(ToolDefinition(
            name: "run_command",
            description: "Run a shell command on the Mac inside a checked-out repository (e.g. swift test, fastlane, pod install). Disabled unless allowShell is set in the Mac's config. Runs as a job.",
            properties: [
                "command": Schema.string("Command line, run with /bin/zsh -lc."),
                "repo": source["repo"]!, "path": source["path"]!,
                "timeout_seconds": Schema.integer("Kill the command after this long (default 900).", minimum: 1, maximum: 7200),
            ].merging(wait) { a, _ in a },
            required: ["command"]
        )) { [self] args in
            guard config.allowShell else {
                throw ToolError("run_command is disabled on this Mac. To enable it, set \"allowShell\": true in ~/.config/minirun/config.json and restart minirun.")
            }
            let command = try args.requireString("command")
            let dir = try Workspace.directory(repo: args.string("repo"), path: args.string("path") ?? (args.string("repo") == nil ? config.workspaceRoot : nil), config: config)
            let timeout = TimeInterval(args.int("timeout_seconds") ?? 900)
            let log = newLogURL("command")
            return await runAsJob(args, title: "$ \(command.prefix(60))", log: log) {
                let result = try await Shell.run("/bin/zsh", ["-lc", command], cwd: dir, timeout: timeout, logURL: log)
                let status = result.timedOut ? "timed out" : "exit \(result.exitCode)"
                return ToolResult([.text("\(status)\n\(result.tail(8000))")], isError: !result.succeeded)
            }
        }

        register(ToolDefinition(
            name: "get_job",
            description: "Wait for a build/test/command job and get its result, or its latest output if it's still running.",
            properties: ["job_id": Schema.string("Job id from an earlier call.")].merging(wait) { a, _ in a },
            required: ["job_id"]
        )) { [self] args in
            await jobs.report(try args.requireString("job_id"), waited: min(600, max(0, args.double("wait_seconds") ?? 45)))
        }

        register(ToolDefinition(
            name: "job_log",
            description: "Read the full log of a job (e.g. the complete xcodebuild output), optionally filtered.",
            properties: [
                "job_id": Schema.string("Job id."),
                "lines": Schema.integer("Number of lines from the end (default 200).", minimum: 1, maximum: 5000),
                "contains": Schema.string("Only lines containing this text."),
            ],
            required: ["job_id"]
        )) { [self] args in
            guard let job = await jobs.job(try args.requireString("job_id")), let path = job.logPath,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw ToolError("No log for that job.")
            }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if let needle = args.string("contains")?.lowercased() { lines = lines.filter { $0.lowercased().contains(needle) } }
            return .text(lines.suffix(args.int("lines") ?? 200).joined(separator: "\n"))
        }

        register(ToolDefinition(
            name: "list_jobs",
            description: "List recent jobs and their status.",
            properties: [:]
        )) { [self] _ in
            let list = await jobs.list()
            guard !list.isEmpty else { return .text("No jobs yet.") }
            return .text(list.map { "\($0.id)  \($0.status.rawValue)  \($0.title)  started \($0.startedAt.formatted(date: .omitted, time: .standard))" }.joined(separator: "\n"))
        }
    }

    // MARK: Helpers

    /// Syncs if `ref` was given, then returns the directory to build in.
    func sourceDirectory(_ args: ToolArguments, log: URL) async throws -> String {
        if let repo = args.string("repo"), args.string("ref") != nil || !FileManager.default.fileExists(atPath: Workspace.path(for: try config.resolveRepo(repo).slug, config: config) + "/.git") {
            let checkout = try await Workspace.sync(repo: repo, ref: args.string("ref"), config: config, log: log)
            XcodeBuild.appendLog(log, "Checked out \(checkout.slug) at \(checkout.commit)\n")
            return checkout.path
        }
        return try Workspace.directory(repo: args.string("repo"), path: args.string("path"), config: config)
    }

    func buildApp(_ args: ToolArguments, udid: String, log: URL) async throws -> XcodeBuild.BuildOutput {
        let dir = try await sourceDirectory(args, log: log)
        var options = XcodeBuild.Options(directory: dir, project: args.string("project"), scheme: args.string("scheme"), udid: udid, log: log)
        options.configuration = args.string("configuration") ?? "Debug"
        options.extraArgs = args.strings("extra_args")
        return try await XcodeBuild.build(options)
    }

    func describe(_ output: XcodeBuild.BuildOutput, log: URL) -> String {
        var lines = ["Built \(output.scheme) in \(Int(output.duration))s."]
        if let product = output.product {
            lines.append("App: \(product.appPath)")
            if let bundle = product.bundleIdentifier { lines.append("Bundle id: \(bundle)") }
        }
        if !output.warnings.isEmpty {
            lines.append("\(output.warnings.count) warning(s), e.g.:")
            lines += output.warnings.prefix(5).map { "  " + $0.line }
        }
        lines.append("Log: \(log.path)")
        return lines.joined(separator: "\n")
    }
}
