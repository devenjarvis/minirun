import Foundation
import MiniRunKit

/// Builds and tests projects with `xcodebuild` for a simulator destination.
enum XcodeBuild {
    struct Container {
        /// e.g. ["-workspace", "App.xcworkspace"], or [] for a Swift package directory.
        let flags: [String]
        let description: String
        /// Where xcodebuild has to run: a Swift package's own folder. nil means the checkout.
        var workingDirectory: String? = nil

        var isPackage: Bool { flags.isEmpty }
    }

    struct Options {
        var directory: String
        var project: String?
        var scheme: String?
        var configuration: String = "Debug"
        var udid: String
        var extraArgs: [String] = []
        var log: URL?
        /// Stop xcodebuild if it writes nothing for this long (nil: only the overall timeout).
        var stallTimeout: TimeInterval?
        /// The overall limit.
        var timeout: TimeInterval = 3600
    }

    /// Finds the workspace/project to build in a checkout, preferring an explicit `project` path.
    static func container(in dir: String, project: String?) throws -> Container {
        let fm = FileManager.default
        if let project {
            var full = project.hasPrefix("/") ? project : dir + "/" + project
            while full.count > 1, full.hasSuffix("/") { full.removeLast() }
            guard fm.fileExists(atPath: full) else {
                throw ToolError("No \(project) in \(dir). `project` is relative to the checkout, e.g. \"App.xcodeproj\" or, for a Swift package, its folder like \"Packages/Core\".")
            }
            if full.hasSuffix(".xcworkspace") { return Container(flags: ["-workspace", full], description: project) }
            if full.hasSuffix(".xcodeproj") { return Container(flags: ["-project", full], description: project) }
            // A Swift package: xcodebuild has to run in its folder, so accept the folder or its Package.swift.
            let packageDir = full.hasSuffix("/Package.swift") ? (full as NSString).deletingLastPathComponent : full
            if fm.fileExists(atPath: packageDir + "/Package.swift") {
                let name = relative(packageDir, to: dir)
                return Container(flags: [], description: packageDir == dir ? "Swift package" : "Swift package \(name)", workingDirectory: packageDir)
            }
            throw ToolError("`project` must be an .xcworkspace, an .xcodeproj, or a Swift package folder (or its Package.swift), relative to the checkout.")
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
        let result = try await Shell.check("/usr/bin/xcrun", ["xcodebuild", "-list", "-json"] + container.flags, cwd: container.workingDirectory ?? directory, timeout: 180, what: "xcodebuild -list")
        return (container, XcodeParsing.parseSchemes(Data(result.stdout.utf8)))
    }

    static func resolveScheme(_ options: Options, forTesting: Bool = false) async throws -> (Container, String) {
        let (container, schemes) = try await schemes(directory: options.directory, project: options.project, log: options.log)
        if let scheme = options.scheme {
            guard schemes.isEmpty || schemes.contains(scheme) else {
                throw ToolError("No scheme \"\(scheme)\". Available: \(schemes.joined(separator: ", "))")
            }
            return (container, scheme)
        }
        guard let first = schemes.first else { throw ToolError("\(container.description) has no shared schemes. Pass `scheme`.") }
        if schemes.count > 1 {
            // A package's "<Name>-Package" scheme runs all of its test targets.
            if forTesting, container.isPackage, let all = schemes.first(where: { $0.hasSuffix("-Package") }) { return (container, all) }
            // Prefer a scheme named like the folder, else the first non-test scheme.
            let folder = ((container.workingDirectory ?? options.directory) as NSString).lastPathComponent.lowercased()
            if let match = schemes.first(where: { $0.lowercased() == folder }) { return (container, match) }
            if let app = schemes.first(where: { !$0.lowercased().contains("test") && !$0.contains("-Package") }) { return (container, app) }
        }
        return (container, first)
    }

    static func commonArgs(_ container: Container, scheme: String, options: Options) -> [String] {
        container.flags + [
            "-scheme", scheme,
            "-configuration", options.configuration,
            "-destination", "platform=iOS Simulator,id=\(options.udid)",
            "-derivedDataPath", options.directory + "/.minirun/DerivedData",
            "-skipPackagePluginValidation", "-skipMacroValidation",
        ]
    }

    struct BuildOutput {
        let scheme: String
        let product: XcodeParsing.AppProduct?
        let duration: TimeInterval
        let warnings: [XcodeParsing.BuildIssue]
    }

    static func build(_ options: Options) async throws -> BuildOutput {
        let (container, scheme) = try await resolveScheme(options)
        let args = ["xcodebuild"] + commonArgs(container, scheme: scheme, options: options) + options.extraArgs + ["build"]
        let cwd = container.workingDirectory ?? options.directory
        appendLog(options.log, "$ xcrun " + args.joined(separator: " ") + "\n")
        let result = try await Shell.run("/usr/bin/xcrun", args, cwd: cwd, timeout: options.timeout, stallTimeout: options.stallTimeout, logURL: options.log)
        guard result.succeeded else {
            throw ToolError(failureReport("Build of \(scheme)", result: result, options: options))
        }
        let settings = try await Shell.run(
            "/usr/bin/xcrun",
            ["xcodebuild", "-showBuildSettings", "-json"] + commonArgs(container, scheme: scheme, options: options) + options.extraArgs,
            cwd: cwd, timeout: 300
        )
        let product = XcodeParsing.parseAppProduct(Data(settings.stdout.utf8))
        return BuildOutput(
            scheme: scheme,
            product: product,
            duration: result.duration,
            warnings: XcodeParsing.parseIssues(result.stdout, includeWarnings: true, limit: 200).filter { $0.severity == "warning" }
        )
    }

    struct TestOutput {
        let scheme: String
        let passed: Bool
        let summary: String
        let resultBundle: String
    }

    /// Flags added to `xcodebuild test` unless `extra_args` already set them. Parallel testing runs
    /// on clones of the simulator, outside minirun's reservations, and is a common reason
    /// xcodebuild hangs after building; a time allowance turns a hung test into a failure.
    static func testDefaults(extraArgs: [String]) -> [String] {
        var flags: [String] = []
        if !extraArgs.contains(where: { $0.hasPrefix("-parallel-testing") }) { flags += ["-parallel-testing-enabled", "NO"] }
        if !extraArgs.contains(where: { $0.hasPrefix("-test-timeouts-enabled") || $0.hasPrefix("-default-test-execution-time-allowance") }) {
            flags += ["-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "300"]
        }
        return flags
    }

    static func test(_ options: Options, onlyTesting: [String], skipTesting: [String]) async throws -> TestOutput {
        let (container, scheme) = try await resolveScheme(options, forTesting: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let bundle = options.directory + "/.minirun/results/\(scheme)-\(stamp).xcresult"
        try FileManager.default.createDirectory(atPath: (bundle as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var args = ["xcodebuild"] + commonArgs(container, scheme: scheme, options: options) + ["-resultBundlePath", bundle]
        args += onlyTesting.map { "-only-testing:\($0)" } + skipTesting.map { "-skip-testing:\($0)" }
        args += testDefaults(extraArgs: options.extraArgs) + options.extraArgs + ["test"]
        appendLog(options.log, "$ xcrun " + args.joined(separator: " ") + "\n")
        let result = try await Shell.run(
            "/usr/bin/xcrun", args, cwd: container.workingDirectory ?? options.directory,
            timeout: options.timeout, stallTimeout: options.stallTimeout, logURL: options.log
        )

        var summary = ""
        if FileManager.default.fileExists(atPath: bundle),
           let report = try? await Shell.run("/usr/bin/xcrun", ["xcresulttool", "get", "test-results", "summary", "--path", bundle, "--compact"], timeout: 120),
           report.succeeded {
            summary = summarizeTestResults(report.stdout)
        }
        if result.timedOut {
            // Say so first: a partial result bundle can look like a plain failure.
            summary = [failureReport("Tests for \(scheme)", result: result, options: options), summary].filter { !$0.isEmpty }.joined(separator: "\n\n")
        } else if summary.isEmpty {
            summary = result.succeeded ? "Tests passed." : failureReport("Tests for \(scheme)", result: result, options: options)
        } else if !result.succeeded, !XcodeParsing.parseIssues(result.stdout).isEmpty {
            // Compile errors in test targets don't always show up in the result bundle.
            summary += "\n\nBuild issues:\n" + XcodeParsing.parseIssues(result.stdout).map(\.line).joined(separator: "\n")
        }
        return TestOutput(scheme: scheme, passed: result.succeeded, summary: summary, resultBundle: bundle)
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

    static func failureReport(_ what: String, result: ShellResult, options: Options? = nil) -> String {
        if result.stalled {
            let quiet = options?.stallTimeout.map { " for \(Int($0 / 60)) min" } ?? ""
            return "\(what) stopped: xcodebuild printed nothing\(quiet), so it was treated as hung and stopped, and the simulator is no longer busy. " +
                "This is usually the Mac, not your code (a stuck simulator, test runner or package resolution). " +
                "Pass a larger stall_seconds if the work really is that quiet. Last output:\n" + result.tail(1500)
        }
        if result.timedOut {
            let limit = options.map { " after \(Int($0.timeout / 60)) min" } ?? ""
            return "\(what) timed out\(limit) and was stopped. Last output:\n" + result.tail(1500)
        }
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
