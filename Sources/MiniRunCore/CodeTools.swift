import Foundation
import MiniRunKit
import MiniRunSim

extension ToolRegistry {
    static let sourceProperties: [String: JSONValue] = [
        "repo": Schema.string("GitHub repository as owner/name (or a clone URL). It's cloned on the Mac under ~/minirun/workspaces."),
        "ref": Schema.string(
            "Branch, tag or commit to check out first. Push your changes, then pass your branch here so the Mac builds exactly that. " +
            "Each repo + ref has its own checkout and build folder on the Mac, so sessions on different branches don't collide: " +
            "pass the same ref on every call for this work. Prefer a branch name over a commit SHA, which gets a fresh checkout."
        ),
        "path": Schema.string("Instead of repo: a folder on the Mac (absolute, or relative to the workspaces folder). Rarely needed: with repo + ref, use project to pick a package or project inside the checkout."),
        "project": Schema.string(
            "What to build inside the checkout, relative to its top: an .xcworkspace, an .xcodeproj, or a Swift package's folder " +
            "(e.g. \"Packages/Core\"; its Package.swift works too). Found automatically at the top level (or one folder down) if omitted. " +
            "A project.yml is run through XcodeGen first."
        ),
        "scheme": Schema.string("Scheme to build. Picked automatically if omitted; see list_schemes."),
    ]

    /// How long a build may print nothing before it's treated as hung.
    static let buildStallSeconds: TimeInterval = 900

    static let waitProperty: [String: JSONValue] = [
        "wait_seconds": Schema.number(
            "How long to wait for the job before returning a job id to poll (default 45, max \(Int(JobStore.maxWait)), under the client's request timeout). " +
                "Call get_job again to keep waiting.",
            minimum: 0, maximum: JobStore.maxWait
        ),
    ]

    func registerCodeTools() {
        let device = Self.deviceProperty
        let source = Self.sourceProperties
        let wait = Self.waitProperty

        register(ToolDefinition(
            name: "host_info",
            description: "Describe the Mac: minirun, macOS and Xcode versions, installed simulator runtimes, free disk space, checked-out repositories, and setup checks (Xcode license, simulator frameworks, relay, GitHub auth…) with how to fix any that fail. Call it when builds or simulators fail for reasons that aren't in your code.",
            properties: [:]
        )) { [self] _ in
            async let xcode = Shell.run("/usr/bin/xcrun", ["xcodebuild", "-version"], timeout: 60)
            async let runtimes = Shell.run("/usr/bin/xcrun", ["simctl", "list", "runtimes"], timeout: 60)
            async let checks = doctorChecks(serveStatus: nil)
            let os = ProcessInfo.processInfo.operatingSystemVersionString
            let free = (try? FileManager.default.attributesOfFileSystem(forPath: MiniRunConfig.home)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            let repos = (try? FileManager.default.contentsOfDirectory(atPath: config.workspaceRoot))?.flatMap { owner in
                ((try? FileManager.default.contentsOfDirectory(atPath: config.workspaceRoot + "/" + owner)) ?? []).map { "\(owner)/\($0)" }
            } ?? []
            let snapshot = try? await simulators()
            let devices = snapshot?.devices ?? [], claims = snapshot?.claims ?? [:]
            let booted = devices.filter(\.isBooted)
            let text = """
            minirun: \(MiniRun.version)
            macOS: \(os)
            Xcode: \((try? await xcode)?.stdout.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) ?? "not found")
            Free disk: \(free / 1_000_000_000) GB
            Shell commands (run_command): \(config.allowShell ? "enabled" : "disabled — set allowShell in ~/.config/minirun/config.json. swift_test runs package tests without it")
            Workspaces (\(config.workspaceRoot)): \(repos.isEmpty ? "none" : repos.sorted().joined(separator: ", "))
            Booted simulators: \(booted.isEmpty ? "none" : "\n" + SimulatorPicker.describe(booted, claims: claims))

            Checks:
            \(Doctor.format(await checks))

            \((try? await runtimes)?.stdout ?? "")
            """
            return .text(text)
        }

        register(ToolDefinition(
            name: "sync_repo",
            description: "Clone or update a GitHub repository on the Mac and check out a branch, tag or commit. Each repo + ref has its own checkout. Uncommitted changes in that checkout are discarded.",
            properties: [
                "repo": Schema.string("owner/name or clone URL."),
                "ref": Schema.string("Branch, tag or commit (default: the default branch). Each ref gets its own checkout; pass the same ref to later calls."),
            ].merging(wait) { a, _ in a },
            required: ["repo"]
        )) { [self] args in
            let repo = try args.requireString("repo")
            let ref = args.string("ref")
            let workspace = try workspaceLabel(args)
            let log = newLogURL("sync")
            return await runAsJob(args, title: "sync \(workspace)", log: log) { [self] in
                let checkout = try await self.withCheckout(args, log: log) {
                    try await Workspace.sync(repo: repo, ref: ref, config: self.config, log: log)
                }
                return .text("\(checkout.label) at \(checkout.commit.prefix(10)) “\(checkout.subject)”\nPath: \(checkout.path)")
            }
        }

        register(ToolDefinition(
            name: "list_schemes",
            description: "List the Xcode schemes in a checked-out repository.",
            properties: ["repo": source["repo"]!, "ref": source["ref"]!, "path": source["path"]!, "project": source["project"]!]
        )) { [self] args in
            let dir = try Workspace.directory(repo: args.string("repo"), ref: args.string("ref"), path: args.string("path"), config: config)
            let (container, schemes) = try await XcodeBuild.schemes(directory: dir, project: args.string("project"))
            return .text("\(container.description): \(schemes.isEmpty ? "no shared schemes" : schemes.joined(separator: ", "))")
        }

        register(ToolDefinition(
            name: "build",
            description: "Build an app for the simulator with xcodebuild. Pass repo + ref to sync first. Returns errors with file:line on failure, or the .app path and bundle id. Without device, it uses the simulator reserved for this repo + ref (see build_and_run). Runs as a job: if it's still going after wait_seconds you get a job_id for get_job.",
            properties: source.merging(device) { a, _ in a }.merging([
                "configuration": Schema.string("Build configuration (default Debug)."),
                "extra_args": Schema.stringArray("Extra xcodebuild arguments, e.g. [\"CODE_SIGNING_ALLOWED=NO\"]."),
            ]) { a, _ in a }.merging(wait) { a, _ in a }
        )) { [self] args in
            let workspace = try workspaceLabel(args)
            let log = newLogURL("build")
            return await runAsJob(args, title: "build \(workspace)", log: log) { [self] in
                let (sim, note) = try await self.workspaceDevice(args, workspace: workspace)
                let output = try await self.whileUsing(sim.udid) {
                    try await self.withCheckout(args, log: log) { try await self.buildApp(args, udid: sim.udid, log: log) }
                }
                return .text([self.describe(output, log: log), note, self.deviceFooter(sim)].compactMap { $0 }.joined(separator: "\n"))
            }
        }

        register(ToolDefinition(
            name: "build_and_run",
            description: "The main loop: sync (if ref given), build, install and launch the app on the simulator, then return a screenshot. Errors come back with file:line so you can fix and push again. " +
                "Without device, it uses the simulator reserved for this repo + ref, or reserves one for it (booting a separate simulator if the running ones belong to other work). " +
                "The result names the simulator's UDID: pass it as device to tap, screenshot and the other tools.",
            properties: source.merging(device) { a, _ in a }.merging([
                "configuration": Schema.string("Build configuration (default Debug)."),
                "extra_args": Schema.stringArray("Extra xcodebuild arguments."),
                "launch_arguments": Schema.stringArray("Arguments passed to the app at launch."),
                "environment": ["type": "object", "additionalProperties": ["type": "string"], "description": "Environment variables for the app."],
            ]) { a, _ in a }.merging(wait) { a, _ in a }
        )) { [self] args in
            let workspace = try workspaceLabel(args)
            let log = newLogURL("build-and-run")
            return await runAsJob(args, title: "build and run \(workspace)", log: log) { [self] in
                // Picking (and maybe booting) the simulator happens in the job: a first boot can take minutes.
                let (sim, note) = try await self.workspaceDevice(args, workspace: workspace)
                // Hold the checkout through install so another build can't replace the .app first.
                let (output, bundle) = try await self.whileUsing(sim.udid) {
                    try await self.withCheckout(args, log: log) { () async throws -> (XcodeBuild.BuildOutput, String) in
                        let output = try await self.buildApp(args, udid: sim.udid, log: log)
                        guard let product = output.product, let bundle = product.bundleIdentifier else {
                            throw ToolError("Built \(output.scheme), but it doesn't produce an iOS app to launch. Use build or run_tests for this scheme.")
                        }
                        try await Simctl.install(sim.udid, appPath: product.appPath)
                        return (output, bundle)
                    }
                }
                await self.claims.noteApp(sim.udid, bundleID: bundle)
                let env = args.raw["environment"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
                let pid = try await Simctl.launch(sim.udid, bundleID: bundle, arguments: args.strings("launch_arguments"), environment: env)
                // The new app may be landscape-only, which changes how taps map to the screen.
                await SimulatorDriver.shared.forgetCoordinateMapping(udid: sim.udid)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let summary = [self.describe(output, log: log), "Installed and launched \(bundle) on \(sim.name) (pid \(pid)).", note, self.deviceFooter(sim)]
                var content: [ToolContent] = [.text(summary.compactMap { $0 }.joined(separator: "\n"))]
                content += (try? await self.screenshotContent(udid: sim.udid)) ?? []
                return ToolResult(content)
            }
        }

        register(ToolDefinition(
            name: "run_tests",
            description: "Run a scheme's unit/UI tests on the simulator with xcodebuild and report pass/fail with failure messages. " +
                "For a Swift package in a subfolder, pass project: \"Packages/Core\" (its folder). Packages that build for macOS test faster with swift_test, which needs no simulator. " +
                "If xcodebuild prints nothing for stall_seconds it's treated as hung and stopped, so a stuck run can't hold the simulator. " +
                "Tests run one at a time on this simulator (no parallel clones) unless extra_args say otherwise. Runs as a job; cancel_job stops it.",
            properties: source.merging(device) { a, _ in a }.merging([
                "only_testing": Schema.stringArray("Limit to these tests, e.g. [\"AppTests/LoginTests/testValidLogin\"]."),
                "skip_testing": Schema.stringArray("Skip these tests."),
                "configuration": Schema.string("Build configuration (default Debug)."),
                "extra_args": Schema.stringArray("Extra xcodebuild arguments."),
                "timeout_seconds": Schema.integer("Stop the run after this long in all (default 1800).", minimum: 60, maximum: 7200),
                "stall_seconds": Schema.integer("Stop the run if xcodebuild prints nothing for this long (default 300).", minimum: 60, maximum: 3600),
            ]) { a, _ in a }.merging(wait) { a, _ in a }
        )) { [self] args in
            let workspace = try workspaceLabel(args)
            let log = newLogURL("test")
            return await runAsJob(args, title: "tests \(workspace)", log: log) { [self] in
                let (sim, note) = try await self.workspaceDevice(args, workspace: workspace)
                let output = try await self.whileUsing(sim.udid) {
                    try await self.withCheckout(args, log: log) { () async throws -> XcodeBuild.TestOutput in
                        let dir = try await self.sourceDirectory(args, log: log)
                        var options = XcodeBuild.Options(directory: dir, project: args.string("project"), scheme: args.string("scheme"), udid: sim.udid, log: log)
                        options.configuration = args.string("configuration") ?? "Debug"
                        options.extraArgs = args.strings("extra_args")
                        options.timeout = TimeInterval(args.int("timeout_seconds") ?? 1800)
                        options.stallTimeout = TimeInterval(args.int("stall_seconds") ?? 300)
                        return try await XcodeBuild.test(options, onlyTesting: args.strings("only_testing"), skipTesting: args.strings("skip_testing"))
                    }
                }
                var text = "Scheme \(output.scheme): \(output.passed ? "passed" : "FAILED") on \(sim.name) (\(sim.udid))\n\(output.summary)\nResult bundle: \(output.resultBundle)\nLog: \(log.path)"
                if let note { text += "\n" + note }
                return ToolResult([.text(text)], isError: !output.passed)
            }
        }

        register(ToolDefinition(
            name: "swift_test",
            description: "Run a Swift package's tests on the Mac itself with `swift test` — no simulator, so it's quicker and never waits for one. " +
                "Use it for packages that build for macOS; code that needs iOS goes through run_tests. Pass repo + ref, and package for a package in a subfolder. " +
                "Reports totals and each failure with file:line. Stopped if it prints nothing for stall_seconds. Runs as a job; cancel_job stops it.",
            properties: [
                "repo": source["repo"]!, "ref": source["ref"]!, "path": source["path"]!,
                "package": Schema.string("The package's folder inside the checkout, e.g. \"Packages/Core\" (default: the top of the checkout). Its Package.swift works too."),
                "filter": Schema.stringArray("Only run tests matching these (swift test --filter), e.g. [\"CoreTests.ParserTests\"]."),
                "skip": Schema.stringArray("Skip tests matching these (swift test --skip)."),
                "timeout_seconds": Schema.integer("Stop after this long in all (default 1200).", minimum: 60, maximum: 7200),
                "stall_seconds": Schema.integer("Stop if it prints nothing for this long (default 300).", minimum: 60, maximum: 3600),
            ].merging(wait) { a, _ in a }
        )) { [self] args in
            let workspace = try workspaceLabel(args)
            let log = newLogURL("swift-test")
            let timeout = TimeInterval(args.int("timeout_seconds") ?? 1200)
            let stall = TimeInterval(args.int("stall_seconds") ?? 300)
            return await runAsJob(args, title: "swift test \(workspace)" + (args.string("package").map { " (\($0))" } ?? ""), log: log) { [self] in
                try await self.withCheckout(args, log: log) { () async throws -> ToolResult in
                    let root = try await self.sourceDirectory(args, log: log)
                    let dir = try Self.packageDirectory(root: root, package: args.string("package"))
                    var arguments = ["test", "--package-path", dir]
                    for pattern in args.strings("filter") { arguments += ["--filter", pattern] }
                    for pattern in args.strings("skip") { arguments += ["--skip", pattern] }
                    XcodeBuild.appendLog(log, "$ swift " + arguments.joined(separator: " ") + "\n")
                    let result = try await Shell.run("/usr/bin/xcrun", ["swift"] + arguments, cwd: dir, timeout: timeout, stallTimeout: stall, logURL: log)
                    let summary = SwiftTestReport.summarize(result, stallTimeout: stall, timeout: timeout)
                    return ToolResult([.text("\(summary)\nPackage: \(dir)\nLog: \(log.path)")], isError: !result.succeeded)
                }
            }
        }

        register(ToolDefinition(
            name: "cancel_job",
            description: "Stop a running job (build, tests, command, boot) and the commands it started, so its simulator and checkout are free again. " +
                "Use it when a job is stuck or no longer needed. Only cancel your own jobs: others may belong to another session.",
            properties: ["job_id": Schema.string("Job id from an earlier call or list_jobs.")],
            required: ["job_id"]
        )) { [self] args in
            let job = try await jobs.cancel(try args.requireString("job_id"))
            let ran = JobStore.format(Date().timeIntervalSince(job.startedAt))
            return .text("Cancelled \(job.id) (\(job.title)) after \(ran). Its commands are being stopped; the simulator it used is no longer busy.")
        }

        register(ToolDefinition(
            name: "run_command",
            description: "Run a shell command on the Mac inside a checked-out repository (e.g. swift test, fastlane, pod install). Disabled unless allowShell is set in the Mac's config. Runs as a job.",
            properties: [
                "command": Schema.string("Command line, run with /bin/zsh -lc."),
                "repo": source["repo"]!, "ref": source["ref"]!, "path": source["path"]!,
                "timeout_seconds": Schema.integer("Kill the command after this long (default 900).", minimum: 1, maximum: 7200),
            ].merging(wait) { a, _ in a },
            required: ["command"]
        )) { [self] args in
            guard config.allowShell else {
                throw ToolError("run_command is disabled on this Mac. To enable it, set \"allowShell\": true in ~/.config/minirun/config.json and run `minirun reload` (or turn it on from the menu bar app).")
            }
            let command = try args.requireString("command")
            let dir = try Workspace.directory(
                repo: args.string("repo"), ref: args.string("ref"),
                path: args.string("path") ?? (args.string("repo") == nil ? config.workspaceRoot : nil), config: config
            )
            let timeout = TimeInterval(args.int("timeout_seconds") ?? 900)
            let log = newLogURL("command")
            return await runAsJob(args, title: "$ \(command.prefix(60))", log: log) { [self] in
                await commandFolders.begin(dir)
                let result: ShellResult
                do {
                    result = try await Shell.run("/bin/zsh", ["-lc", command], cwd: dir, timeout: timeout, logURL: log)
                } catch {
                    await commandFolders.end(dir)
                    throw error
                }
                await commandFolders.end(dir)
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
            await jobs.report(try args.requireString("job_id"), waited: JobStore.waitSeconds(args.double("wait_seconds")))
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
            let now = Date()
            return .text(list.map { job in
                let took = JobStore.format((job.finishedAt ?? now).timeIntervalSince(job.startedAt))
                return "\(job.id)  \(job.status.rawValue)\(job.status == .running ? " for \(took)" : "")  \(job.title)  started \(job.startedAt.formatted(date: .omitted, time: .standard))"
            }.joined(separator: "\n"))
        }
    }

    // MARK: Helpers

    /// The folder of the Swift package `package` names inside `root` (or `root` itself).
    static func packageDirectory(root: String, package: String?) throws -> String {
        guard var package, !package.isEmpty else {
            guard FileManager.default.fileExists(atPath: root + "/Package.swift") else {
                throw ToolError("No Package.swift at the top of \(root). Pass package with the package's folder, e.g. \"Packages/Core\".")
            }
            return root
        }
        if (package as NSString).lastPathComponent == "Package.swift" { package = (package as NSString).deletingLastPathComponent }
        let dir = URL(fileURLWithPath: package.hasPrefix("/") ? package : root + "/" + package).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: dir + "/Package.swift") else {
            throw ToolError("No Package.swift in \(dir). package is the package's folder relative to the checkout, e.g. \"Packages/Core\".")
        }
        return dir
    }

    /// The checks behind `minirun doctor`. host_info leaves out `serveStatus`: it's minirun serve
    /// answering, so that check would only say it's running.
    func doctorChecks(serveStatus: (@Sendable () async -> ServeStatus?)?) async -> [DoctorCheck] {
        let doctor = Doctor(
            loadFrameworks: {
                do {
                    try await SimulatorDriver.shared.prepare()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            serveStatus: serveStatus
        )
        return await doctor.checks(config: config)
    }

    /// Names the work a call is for: "owner/app@ref" (or "owner/app"), or the folder for `path`.
    /// Simulator reservations and checkout locks use this name.
    func workspaceLabel(_ args: ToolArguments) throws -> String {
        if let repo = args.string("repo") { return WorkspaceNaming.label(slug: try config.resolveRepo(repo).slug, ref: args.string("ref")) }
        if args.string("path") != nil { return try checkoutPath(args) }
        throw ToolError("Pass `repo` (owner/name) or `path`.")
    }

    /// The folder a call's checkout lives in (whether or not it exists yet).
    func checkoutPath(_ args: ToolArguments) throws -> String {
        if let repo = args.string("repo") { return Workspace.path(for: try config.resolveRepo(repo).slug, ref: args.string("ref"), config: config) }
        return try Workspace.directory(repo: nil, ref: nil, path: args.string("path"), config: config)
    }

    /// Runs `body` while no other sync or build uses the same checkout.
    func withCheckout<T>(_ args: ToolArguments, log: URL, _ body: () async throws -> T) async throws -> T {
        let path = try checkoutPath(args)
        return try await checkouts.withLock(path, onWait: {
            XcodeBuild.appendLog(log, "Waiting for another job using \(path) to finish…\n")
        }) {
            // Cancelled while waiting its turn: don't start.
            try Task.checkCancellation()
            return try await body()
        }
    }

    /// Syncs if `ref` was given, then returns the directory to build in. Call inside `withCheckout`.
    func sourceDirectory(_ args: ToolArguments, log: URL) async throws -> String {
        if let repo = args.string("repo") {
            let existing = Workspace.path(for: try config.resolveRepo(repo).slug, ref: args.string("ref"), config: config)
            guard args.string("ref") != nil || !FileManager.default.fileExists(atPath: existing + "/.git") else { return existing }
            let checkout = try await Workspace.sync(repo: repo, ref: args.string("ref"), config: config, log: log)
            XcodeBuild.appendLog(log, "Checked out \(checkout.slug) at \(checkout.commit)\n")
            return checkout.path
        }
        return try Workspace.directory(repo: nil, ref: nil, path: args.string("path"), config: config)
    }

    /// Syncs and builds. Call inside `withCheckout`.
    func buildApp(_ args: ToolArguments, udid: String, log: URL) async throws -> XcodeBuild.BuildOutput {
        let dir = try await sourceDirectory(args, log: log)
        var options = XcodeBuild.Options(directory: dir, project: args.string("project"), scheme: args.string("scheme"), udid: udid, log: log)
        options.configuration = args.string("configuration") ?? "Debug"
        options.extraArgs = args.strings("extra_args")
        options.stallTimeout = Self.buildStallSeconds
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
