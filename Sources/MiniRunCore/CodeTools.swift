import Foundation
import MiniRunKit
import MiniRunMac
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
            description: "Build an app with xcodebuild, for the simulator or (platform macos) the Mac. Pass repo + ref to sync first. Returns errors with file:line on failure, or the .app path and bundle id. " +
                "For iOS without device, it uses the simulator reserved for this repo + ref (see build_and_run). Runs as a job: if it's still going after wait_seconds you get a job_id for get_job.",
            properties: source.merging(device) { a, _ in a }.merging(Self.platformProperty) { a, _ in a }.merging([
                "configuration": Schema.string("Build configuration (default Debug)."),
                "extra_args": Schema.stringArray("Extra xcodebuild arguments, e.g. [\"CODE_SIGNING_ALLOWED=NO\"]."),
            ]) { a, _ in a }.merging(wait) { a, _ in a }
        )) { [self] args in
            let workspace = try workspaceLabel(args)
            _ = try MacToolSupport.platform(argument: args.string("platform"), device: args.string("device"))
            let log = newLogURL("build")
            return await runAsJob(args, title: "build \(workspace)", log: log) { [self] in
                let early = try await self.earlySimulator(args, workspace: workspace)
                return try await self.whileUsingEarly(early) { try await self.withCheckout(args, log: log) { () async throws -> ToolResult in
                    let prepared = try await self.prepareBuild(args, workspace: workspace, log: log, early: early)
                    if let sim = prepared.sim {
                        let output = try await self.whileUsing(sim.udid) { try await XcodeBuild.build(prepared.options) }
                        return .text([self.describe(output, log: log), prepared.note, self.deviceFooter(sim)].compactMap { $0 }.joined(separator: "\n"))
                    }
                    let output = try await XcodeBuild.build(prepared.options)
                    let next = "To run it, call build_and_run with platform: \"\(output.platform.rawValue)\" and the same repo + ref (or path)."
                    return .text([self.describe(output, log: log), next].joined(separator: "\n"))
                } }
            }
        }

        register(ToolDefinition(
            name: "build_and_run",
            description: "The main loop: sync (if ref given), build, install and launch the app on the simulator, then return a screenshot. Errors come back with file:line so you can fix and push again. " +
                "Without device, it uses the simulator reserved for this repo + ref, or reserves one for it (booting a separate simulator if the running ones belong to other work). " +
                "The result names the simulator's UDID: pass it as device to tap, screenshot and the other tools. " +
                "For a macOS app (platform macos, or a scheme that only builds for macOS) it quits the copy it launched last time for this repo + ref (never anyone else's), " +
                "launches the new build on the Mac, waits for its window and returns a screenshot of it plus a Mac app id (mac-…) to pass as device. " +
                "Copies of one app built from different branches run side by side but share its preferences and files; isolated_home separates non-sandboxed apps.",
            properties: source.merging(device) { a, _ in a }.merging(Self.platformProperty) { a, _ in a }.merging(Self.isolatedHomeProperty) { a, _ in a }.merging([
                "configuration": Schema.string("Build configuration (default Debug)."),
                "extra_args": Schema.stringArray("Extra xcodebuild arguments."),
                "launch_arguments": Schema.stringArray("Arguments passed to the app at launch."),
                "environment": ["type": "object", "additionalProperties": ["type": "string"], "description": "Environment variables for the app."],
            ]) { a, _ in a }.merging(wait) { a, _ in a }
        )) { [self] args in
            let workspace = try workspaceLabel(args)
            _ = try MacToolSupport.platform(argument: args.string("platform"), device: args.string("device"))
            let log = newLogURL("build-and-run")
            return await runAsJob(args, title: "build and run \(workspace)", log: log) { [self] in
                let env = args.raw["environment"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
                // Picking (and maybe booting) the simulator happens in the job: a first boot can take
                // minutes. When the build is known to be for iOS that's before taking the checkout.
                let early = try await self.earlySimulator(args, workspace: workspace)
                // Hold the checkout through install (for a Mac app, through launch) so another build can't replace the .app first.
                let built = try await self.whileUsingEarly(early) { try await self.withCheckout(args, log: log) { () async throws -> BuildAndRun in
                    let prepared = try await self.prepareBuild(args, workspace: workspace, log: log, early: early)
                    guard let sim = prepared.sim else {
                        let id = await self.macApps.id(forLabel: workspace)
                        return .mac(try await self.whileUsingMac(id) { () async throws -> ToolResult in
                            let output = try await XcodeBuild.build(prepared.options)
                            guard let product = output.macProduct else {
                                throw ToolError("Built \(output.scheme), but it doesn't produce a Mac app to launch. Use build or run_tests for this scheme.")
                            }
                            var launch = MacLaunch(
                                id: id, label: workspace, name: MacToolSupport.appName(appPath: product.appPath, productName: product.productName),
                                bundleID: product.bundleIdentifier, appPath: product.appPath, executablePath: product.executablePath
                            )
                            launch.arguments = args.strings("launch_arguments")
                            launch.environment = env
                            launch.adHoc = output.notes.contains(XcodeBuild.adHocSigningNote)
                            if args.bool("isolated_home") == true {
                                launch.home = MacToolSupport.isolatedHome(
                                    appPath: product.appPath, checkout: prepared.options.directory, id: id, fallbackRoot: MiniRunConfig.home + "/minirun/mac-homes"
                                )
                            }
                            return try await self.launchMac(launch, intro: [self.describe(output, log: log)])
                        })
                    }
                    return try await self.whileUsing(sim.udid) { () async throws -> BuildAndRun in
                        let output = try await XcodeBuild.build(prepared.options)
                        guard let product = output.product, let bundle = product.bundleIdentifier else {
                            throw ToolError("Built \(output.scheme), but it doesn't produce an iOS app to launch. Use build or run_tests for this scheme.")
                        }
                        try await Simctl.install(sim.udid, appPath: product.appPath)
                        return .simulator(output, bundle: bundle, sim: sim, note: prepared.note)
                    }
                } }
                switch built {
                case .mac(let result):
                    return result
                case .simulator(let output, let bundle, let sim, let note):
                    await self.claims.noteApp(sim.udid, bundleID: bundle)
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
        }

        register(ToolDefinition(
            name: "run_tests",
            description: "Run a scheme's unit/UI tests with xcodebuild on the simulator, or with platform macos on the Mac, and report pass/fail with failure messages. " +
                "For a Swift package in a subfolder, pass project: \"Packages/Core\" (its folder). Packages that build for macOS test faster with swift_test, which needs no simulator. " +
                "If xcodebuild prints nothing for stall_seconds it's treated as hung and stopped, so a stuck run can't hold the simulator (or the Mac). " +
                "Tests run one at a time (no parallel clones or runners) unless extra_args say otherwise. " +
                "macOS test runs go one at a time on the Mac, because UI tests take over its real mouse and keyboard. Runs as a job; cancel_job stops it.",
            properties: source.merging(device) { a, _ in a }.merging(Self.platformProperty) { a, _ in a }.merging([
                "only_testing": Schema.stringArray("Limit to these tests, e.g. [\"AppTests/LoginTests/testValidLogin\"]."),
                "skip_testing": Schema.stringArray("Skip these tests."),
                "configuration": Schema.string("Build configuration (default Debug)."),
                "extra_args": Schema.stringArray("Extra xcodebuild arguments."),
                "timeout_seconds": Schema.integer("Stop the run after this long in all (default 1800).", minimum: 60, maximum: 7200),
                "stall_seconds": Schema.integer("Stop the run if xcodebuild prints nothing for this long (default 300).", minimum: 60, maximum: 3600),
            ]) { a, _ in a }.merging(wait) { a, _ in a }
        )) { [self] args in
            let workspace = try workspaceLabel(args)
            _ = try MacToolSupport.platform(argument: args.string("platform"), device: args.string("device"))
            let log = newLogURL("test")
            return await runAsJob(args, title: "tests \(workspace)", log: log) { [self] in
                let early = try await self.earlySimulator(args, workspace: workspace, forTesting: true)
                return try await self.whileUsingEarly(early) { try await self.withCheckout(args, log: log) { () async throws -> ToolResult in
                    var prepared = try await self.prepareBuild(args, workspace: workspace, log: log, forTesting: true, early: early)
                    prepared.options.timeout = TimeInterval(args.int("timeout_seconds") ?? 1800)
                    prepared.options.stallTimeout = TimeInterval(args.int("stall_seconds") ?? 300)
                    let only = args.strings("only_testing"), skip = args.strings("skip_testing")
                    let output: XcodeBuild.TestOutput
                    let place: String
                    if let sim = prepared.sim {
                        output = try await self.whileUsing(sim.udid) { try await XcodeBuild.test(prepared.options, onlyTesting: only, skipTesting: skip) }
                        place = "\(sim.name) (\(sim.udid))"
                    } else {
                        output = try await self.macTests.withLock("mac-ui-tests", onWait: {
                            XcodeBuild.appendLog(log, "Waiting for another macOS test run to finish: UI tests take over the Mac's mouse and keyboard, so they run one at a time…\n")
                        }) {
                            // Cancelled while waiting its turn: don't start. Either way the lock is let go.
                            try Task.checkCancellation()
                            return try await XcodeBuild.test(prepared.options, onlyTesting: only, skipTesting: skip)
                        }
                        place = "this Mac (\(prepared.options.platform.rawValue))"
                    }
                    var text = "Scheme \(output.scheme): \(output.passed ? "passed" : "FAILED") on \(place)\n\(output.summary)\nResult bundle: \(output.resultBundle)\nLog: \(log.path)"
                    text += output.notes.map { "\n" + $0 }.joined()
                    if let note = prepared.note { text += "\n" + note }
                    return ToolResult([.text(text)], isError: !output.passed)
                } }
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
            return .text("Cancelled \(job.id) (\(job.title)) after \(ran). Its commands are being stopped; the simulator (or Mac app) it used is no longer busy.")
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
            serveStatus: serveStatus,
            macPermissions: { await self.macPermissionReport() }
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

    /// A build ready to run: the checkout synced, the platform decided and, for iOS, the
    /// simulator picked and reserved for the workspace.
    struct PreparedBuild {
        var options: XcodeBuild.Options
        var sim: XcodeParsing.SimDevice?
        var note: String?
    }

    /// A simulator picked before the checkout lock (see `earlySimulator`).
    typealias EarlySimulator = (device: XcodeParsing.SimDevice, note: String?)

    /// What `detectedPlatforms` files a build's platform under: the checkout, project, scheme and
    /// everything else that changes the build settings.
    func platformKey(_ args: ToolArguments, forTesting: Bool) throws -> String {
        let checkout = try checkoutPath(args)
        return [checkout, args.string("project") ?? "", args.string("scheme") ?? "", forTesting ? "test" : "build",
         args.string("configuration") ?? "Debug", args.strings("extra_args").joined(separator: " ")].joined(separator: "\u{1f}")
    }

    /// Before the checkout lock, as builds did before macOS support: picks (and maybe boots) the
    /// workspace's simulator when the build is for iOS, said by `platform` or `device`, or found
    /// for this scheme last time. Otherwise nil, and `prepareBuild` picks one once it knows.
    func earlySimulator(_ args: ToolArguments, workspace: String, forTesting: Bool = false) async throws -> EarlySimulator? {
        var guess = try MacToolSupport.platform(argument: args.string("platform"), device: args.string("device"))
        if guess == nil {
            let key = try platformKey(args, forTesting: forTesting)
            guess = await detectedPlatforms.lastKnown(key)
        }
        guard guess == .ios else { return nil }
        return try await workspaceDevice(args, workspace: workspace)
    }

    /// Runs `body` with the early simulator (if any) marked busy.
    func whileUsingEarly<T>(_ early: EarlySimulator?, _ body: () async throws -> T) async throws -> T {
        guard let early else { return try await body() }
        return try await whileUsing(early.device.udid, body)
    }

    /// Syncs if `ref` was given, decides the platform (from the scheme's build settings unless
    /// `platform` or `device` says, remembered while the project files stay the same) and, for
    /// iOS, uses `early` or picks the workspace's simulator. Mac builds don't pick or reserve a
    /// simulator. Builds get the build stall timeout; `forTesting` picks the scheme the way
    /// run_tests does. Call inside `withCheckout`.
    func prepareBuild(_ args: ToolArguments, workspace: String, log: URL, forTesting: Bool = false, early: EarlySimulator? = nil) async throws -> PreparedBuild {
        let dir = try await sourceDirectory(args, log: log)
        let platform = try MacToolSupport.platform(argument: args.string("platform"), device: args.string("device"))
        var options = XcodeBuild.Options(directory: dir, project: args.string("project"), scheme: args.string("scheme"), platform: platform ?? .ios, log: log)
        options.configuration = args.string("configuration") ?? "Debug"
        options.extraArgs = args.strings("extra_args")
        options.stallTimeout = Self.buildStallSeconds
        if platform == nil {
            let key = try platformKey(args, forTesting: forTesting)
            let fingerprint = XcodeBuild.projectFingerprint(directory: dir, project: args.string("project"))
            if let known = await detectedPlatforms.platform(key, fingerprint: fingerprint) {
                options.platform = known
                XcodeBuild.appendLog(log, "Platform: \(known.rawValue) (found for this scheme before; the project hasn't changed since)\n")
            } else {
                do {
                    options.platform = try await XcodeBuild.detectPlatform(&options, forTesting: forTesting)
                    await detectedPlatforms.record(key, fingerprint: fingerprint, platform: options.platform)
                } catch where options.resolved != nil {
                    // The scheme exists but its settings couldn't be read: build it for iOS, as before.
                    XcodeBuild.appendLog(log, "Couldn't read the build settings to pick a platform (\(error.localizedDescription)); building for iOS.\n")
                }
            }
        }
        guard options.platform == .ios else { return PreparedBuild(options: options) }
        let sim: XcodeParsing.SimDevice, note: String?
        if let early { (sim, note) = early } else { (sim, note) = try await workspaceDevice(args, workspace: workspace) }
        options.udid = sim.udid
        return PreparedBuild(options: options, sim: sim, note: note)
    }

    func describe(_ output: XcodeBuild.BuildOutput, log: URL) -> String {
        var lines = ["Built \(output.scheme) in \(Int(output.duration))s."]
        if let product = output.macProduct {
            lines.append("App (\(output.platform.rawValue)): \(product.appPath)")
            if let bundle = product.bundleIdentifier { lines.append("Bundle id: \(bundle)") }
        } else if let product = output.product {
            lines.append("App: \(product.appPath)")
            if let bundle = product.bundleIdentifier { lines.append("Bundle id: \(bundle)") }
        }
        if !output.warnings.isEmpty {
            lines.append("\(output.warnings.count) warning(s), e.g.:")
            lines += output.warnings.prefix(5).map { "  " + $0.line }
        }
        lines += output.notes
        lines.append("Log: \(log.path)")
        return lines.joined(separator: "\n")
    }
}

/// What build_and_run built, inside the checkout lock: an iOS app installed on a simulator (launched
/// after the lock is let go), or a Mac app's finished result (launched while still holding it).
enum BuildAndRun {
    case simulator(XcodeBuild.BuildOutput, bundle: String, sim: XcodeParsing.SimDevice, note: String?)
    case mac(ToolResult)
}
