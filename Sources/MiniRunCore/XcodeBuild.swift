import Foundation
import MiniRunKit

/// Builds and tests projects with `xcodebuild` for a simulator or the Mac.
enum XcodeBuild {
    struct Container {
        /// e.g. ["-workspace", "App.xcworkspace"], or [] for a Swift package directory.
        let flags: [String]
        let description: String
    }

    struct Options {
        var directory: String
        var project: String?
        var scheme: String?
        var configuration: String = "Debug"
        /// The simulator to build for; required to test on .ios.
        var udid: String?
        var platform: BuildPlatform = .ios
        var extraArgs: [String] = []
        var log: URL?
        /// The container and scheme once found, so later steps don't run XcodeGen and
        /// `xcodebuild -list` again.
        var resolved: (container: Container, scheme: String)?
    }

    /// Finds the workspace/project to build in a checkout, preferring an explicit `project` path.
    static func container(in dir: String, project: String?) throws -> Container {
        let fm = FileManager.default
        if let project {
            let full = project.hasPrefix("/") ? project : dir + "/" + project
            guard fm.fileExists(atPath: full) else { throw ToolError("No \(project) in \(dir).") }
            if full.hasSuffix(".xcworkspace") { return Container(flags: ["-workspace", full], description: project) }
            if full.hasSuffix(".xcodeproj") { return Container(flags: ["-project", full], description: project) }
            if full.hasSuffix("Package.swift") { return Container(flags: [], description: "Swift package") }
            throw ToolError("`project` must point to an .xcworkspace, .xcodeproj or Package.swift.")
        }

        // Search the top level, then one level down (monorepos often keep the app in ios/ or App/).
        for depth in 0...1 {
            let candidates = (try? listDirectories(dir, depth: depth)) ?? []
            let workspaces = candidates.filter { $0.hasSuffix(".xcworkspace") && !$0.contains(".xcodeproj/") }.sorted()
            if let ws = workspaces.first { return Container(flags: ["-workspace", ws], description: relative(ws, to: dir)) }
            let projects = candidates.filter { $0.hasSuffix(".xcodeproj") }.sorted()
            if let proj = projects.first { return Container(flags: ["-project", proj], description: relative(proj, to: dir)) }
            if depth == 0, fm.fileExists(atPath: dir + "/Package.swift") { return Container(flags: [], description: "Swift package") }
        }
        throw ToolError("No .xcworkspace, .xcodeproj or Package.swift found in \(dir). Pass `project` to point at one.")
    }

    /// Runs XcodeGen when the checkout has a project.yml (top level, then one level down), so a
    /// repo that doesn't commit its generated .xcodeproj builds as it is. Runs on every build: a
    /// project generated for an earlier commit is gitignored, so syncing leaves it behind, stale.
    static func generateProject(in dir: String, log: URL?) async throws {
        guard let spec = xcodeGenSpec(in: dir) else { return }
        let specDir = (spec as NSString).deletingLastPathComponent
        appendLog(log, "$ xcodegen generate (in \(specDir))\n")
        let result = try await Shell.run("xcodegen", ["generate", "--quiet"], cwd: specDir, timeout: 300, logURL: log)
        if result.exitCode == 127 {
            // /usr/bin/env couldn't find it. A committed project may still build.
            appendLog(log, "XcodeGen isn't installed; building without regenerating the project.\n")
            guard (try? container(in: dir, project: nil)) != nil else {
                throw ToolError("Found \(relative(spec, to: dir)) but XcodeGen isn't installed on the Mac, so there's no project to build. Install it with `brew install xcodegen`.")
            }
            return
        }
        guard result.succeeded else { throw ToolError(failureReport("xcodegen generate for \(relative(spec, to: dir))", result: result)) }
    }

    private static func xcodeGenSpec(in dir: String) -> String? {
        for depth in 0...1 {
            let candidates = (try? listDirectories(dir, depth: depth)) ?? []
            if let spec = candidates.filter({ ($0 as NSString).lastPathComponent == "project.yml" }).sorted().first { return spec }
        }
        return nil
    }

    private static func listDirectories(_ dir: String, depth: Int) throws -> [String] {
        let top = try FileManager.default.contentsOfDirectory(atPath: dir).filter { !$0.hasPrefix(".") }.map { dir + "/" + $0 }
        if depth == 0 { return top }
        return top.flatMap { sub -> [String] in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sub, isDirectory: &isDir), isDir.boolValue,
                  !sub.hasSuffix(".xcodeproj"), !sub.hasSuffix(".xcworkspace"),
                  !["Pods", "node_modules", "build", "DerivedData"].contains((sub as NSString).lastPathComponent) else { return [] }
            return ((try? FileManager.default.contentsOfDirectory(atPath: sub)) ?? []).map { sub + "/" + $0 }
        }
    }

    private static func relative(_ path: String, to dir: String) -> String {
        path.hasPrefix(dir + "/") ? String(path.dropFirst(dir.count + 1)) : path
    }

    static func schemes(directory: String, project: String?, log: URL? = nil) async throws -> (Container, [String]) {
        try await generateProject(in: directory, log: log)
        let container = try container(in: directory, project: project)
        let result = try await Shell.check("/usr/bin/xcrun", ["xcodebuild", "-list", "-json"] + container.flags, cwd: directory, timeout: 180, what: "xcodebuild -list")
        return (container, XcodeParsing.parseSchemes(Data(result.stdout.utf8)))
    }

    static func resolveScheme(_ options: Options) async throws -> (Container, String) {
        if let resolved = options.resolved { return resolved }
        let (container, schemes) = try await schemes(directory: options.directory, project: options.project, log: options.log)
        if let scheme = options.scheme {
            guard schemes.isEmpty || schemes.contains(scheme) else {
                throw ToolError("No scheme \"\(scheme)\". Available: \(schemes.joined(separator: ", "))")
            }
            return (container, scheme)
        }
        guard let first = schemes.first else { throw ToolError("\(container.description) has no shared schemes. Pass `scheme`.") }
        if schemes.count > 1 {
            // Prefer a scheme named like the folder, else the first non-test scheme.
            let folder = (options.directory as NSString).lastPathComponent.lowercased()
            if let match = schemes.first(where: { $0.lowercased() == folder }) { return (container, match) }
            if let app = schemes.first(where: { !$0.lowercased().contains("test") && !$0.contains("-Package") }) { return (container, app) }
        }
        return (container, first)
    }

    /// The flags every build, test and settings call shares. Simulator and Mac products land in
    /// different folders under the same derived data (Debug-iphonesimulator, Debug, Debug-maccatalyst).
    static func baseArgs(_ container: Container, scheme: String, options: Options) -> [String] {
        container.flags + [
            "-scheme", scheme,
            "-configuration", options.configuration,
            "-derivedDataPath", options.directory + "/.minirun/DerivedData",
            "-skipPackagePluginValidation", "-skipMacroValidation",
        ]
    }

    static func commonArgs(_ container: Container, scheme: String, options: Options) -> [String] {
        baseArgs(container, scheme: scheme, options: options) + ["-destination", options.platform.destination(udid: options.udid)]
    }

    /// Picks ios or macos for the scheme from its build settings, read without a destination:
    /// macos only when the app supports macOS and not iOS. Keeps the scheme it found in `options`.
    static func detectPlatform(_ options: inout Options) async throws -> BuildPlatform {
        let (container, scheme) = try await resolveScheme(options)
        options.resolved = (container, scheme)
        let settings = try await Shell.check(
            "/usr/bin/xcrun",
            ["xcodebuild", "-showBuildSettings", "-json"] + baseArgs(container, scheme: scheme, options: options) + options.extraArgs,
            cwd: options.directory, timeout: 300, what: "xcodebuild -showBuildSettings"
        )
        let platform = BuildPlatform.detect(fromBuildSettings: Data(settings.stdout.utf8))
        appendLog(options.log, "Platform for \(scheme): \(platform.rawValue)\n")
        return platform
    }

    /// Build settings that sign "to run locally" instead of with a team's identity and profile.
    static let adHocSigningArgs = ["CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "PROVISIONING_PROFILE_SPECIFIER="]

    static let adHocSigningNote = "Signing with the project's team failed on this Mac, so minirun built it again signed to run locally (ad hoc). Entitlements that need a provisioning profile, like iCloud and push notifications, won't work in this build."

    /// Runs an xcodebuild action. If it fails on code signing, and the caller didn't set signing
    /// themselves, runs it once more with ad-hoc signing. Returns the extra args it ended up using.
    static func runSigningFallback(_ args: (_ extra: [String]) -> [String], options: Options, timeout: TimeInterval) async throws -> (ShellResult, extra: [String], notes: [String]) {
        var extra = options.extraArgs
        var argv = args(extra)
        appendLog(options.log, "$ xcrun " + argv.joined(separator: " ") + "\n")
        var result = try await Shell.run("/usr/bin/xcrun", argv, cwd: options.directory, timeout: timeout, logURL: options.log)
        guard !result.succeeded, !result.timedOut,
              !options.extraArgs.contains(where: { $0.hasPrefix("CODE_SIGN") }),
              XcodeParsing.isSigningFailure(result.stdout + "\n" + result.stderr) else { return (result, extra, []) }
        appendLog(options.log, "\nThe build failed on code signing. Building again with ad-hoc signing (\(adHocSigningArgs.joined(separator: " "))).\n")
        extra += adHocSigningArgs
        argv = args(extra)
        appendLog(options.log, "$ xcrun " + argv.joined(separator: " ") + "\n")
        result = try await Shell.run("/usr/bin/xcrun", argv, cwd: options.directory, timeout: timeout, logURL: options.log)
        return (result, extra, [adHocSigningNote])
    }

    struct BuildOutput {
        let scheme: String
        let platform: BuildPlatform
        let product: XcodeParsing.AppProduct?
        /// The app and its executable, for .macos and .macCatalyst builds.
        let macProduct: XcodeParsing.MacAppProduct?
        let duration: TimeInterval
        let warnings: [XcodeParsing.BuildIssue]
        /// Things to tell the caller, like a fall back to ad-hoc signing.
        let notes: [String]
    }

    static func build(_ options: Options) async throws -> BuildOutput {
        let (container, scheme) = try await resolveScheme(options)
        let common = commonArgs(container, scheme: scheme, options: options)
        let (result, extra, notes) = try await runSigningFallback({ ["xcodebuild"] + common + $0 + ["build"] }, options: options, timeout: 3600)
        guard result.succeeded else {
            throw ToolError(failureReport("Build of \(scheme)", result: result) + (notes.isEmpty ? "" : "\n(This was the second try, with ad-hoc signing.)"))
        }
        let settings = try await Shell.run(
            "/usr/bin/xcrun",
            ["xcodebuild", "-showBuildSettings", "-json"] + common + extra,
            cwd: options.directory, timeout: 300
        )
        let json = Data(settings.stdout.utf8)
        return BuildOutput(
            scheme: scheme,
            platform: options.platform,
            product: XcodeParsing.parseAppProduct(json),
            macProduct: options.platform.isMac ? XcodeParsing.parseMacAppProduct(json, scheme: scheme) : nil,
            duration: result.duration,
            warnings: XcodeParsing.parseIssues(result.stdout, includeWarnings: true, limit: 200).filter { $0.severity == "warning" },
            notes: notes
        )
    }

    struct TestOutput {
        let scheme: String
        let passed: Bool
        let summary: String
        let resultBundle: String
        let notes: [String]
    }

    static func test(_ options: Options, onlyTesting: [String], skipTesting: [String]) async throws -> TestOutput {
        if options.platform == .ios, options.udid == nil { throw ToolError("Tests on iOS need a simulator.") }
        let (container, scheme) = try await resolveScheme(options)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let bundle = options.directory + "/.minirun/results/\(scheme)-\(stamp).xcresult"
        try FileManager.default.createDirectory(atPath: (bundle as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let common = commonArgs(container, scheme: scheme, options: options)
        let filters = onlyTesting.map { "-only-testing:\($0)" } + skipTesting.map { "-skip-testing:\($0)" }
        let (result, _, notes) = try await runSigningFallback({ extra in
            // A retry writes to the same bundle path, which xcodebuild refuses if it exists.
            try? FileManager.default.removeItem(atPath: bundle)
            return ["xcodebuild"] + common + ["-resultBundlePath", bundle] + filters + extra + ["test"]
        }, options: options, timeout: 5400)

        var summary = ""
        if FileManager.default.fileExists(atPath: bundle),
           let report = try? await Shell.run("/usr/bin/xcrun", ["xcresulttool", "get", "test-results", "summary", "--path", bundle, "--compact"], timeout: 120),
           report.succeeded {
            summary = summarizeTestResults(report.stdout)
        }
        if summary.isEmpty {
            summary = result.succeeded ? "Tests passed." : failureReport("Tests for \(scheme)", result: result)
        } else if !result.succeeded, !XcodeParsing.parseIssues(result.stdout).isEmpty {
            // Compile errors in test targets don't always show up in the result bundle.
            summary += "\n\nBuild issues:\n" + XcodeParsing.parseIssues(result.stdout).map(\.line).joined(separator: "\n")
        }
        return TestOutput(scheme: scheme, passed: result.succeeded, summary: summary, resultBundle: bundle, notes: notes)
    }

    /// Turns `xcresulttool get test-results summary` JSON into a short report.
    static func summarizeTestResults(_ json: String) -> String {
        guard let root = try? JSONValue.parse(json) else { return "" }
        var lines: [String] = []
        let result = root["result"]?.stringValue ?? "Unknown"
        let total = root["totalTestCount"]?.intValue ?? 0
        let passed = root["passedTests"]?.intValue ?? 0
        let failed = root["failedTests"]?.intValue ?? 0
        let skipped = root["skippedTests"]?.intValue ?? 0
        lines.append("Result: \(result) — \(passed) passed, \(failed) failed, \(skipped) skipped (\(total) total)")
        if let device = root["devicesAndConfigurations"]?.arrayValue?.first?["device"],
           let name = device["deviceName"]?.stringValue {
            lines.append("Device: \(name) \(device["osVersion"]?.stringValue ?? "")")
        }
        for failure in (root["testFailures"]?.arrayValue ?? []).prefix(30) {
            let name = failure["testIdentifierString"]?.stringValue ?? failure["testName"]?.stringValue ?? "?"
            let text = failure["failureText"]?.stringValue ?? ""
            lines.append("✗ \(name): \(text)")
        }
        return lines.joined(separator: "\n")
    }

    static func failureReport(_ what: String, result: ShellResult) -> String {
        if result.timedOut { return "\(what) timed out." }
        let issues = XcodeParsing.parseIssues(result.stdout + "\n" + result.stderr)
        if issues.isEmpty {
            return "\(what) failed (exit \(result.exitCode)). Last output:\n" + result.tail(4000)
        }
        return "\(what) failed with \(issues.count) error(s):\n" + issues.map(\.line).joined(separator: "\n")
    }

    static func appendLog(_ url: URL?, _ text: String) {
        guard let url else { return }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        handle.write(Data(text.utf8))
    }
}
