import Foundation

/// `minirun ci`: runs a build or test for a GitHub Actions job through the running `minirun
/// serve`, so CI shares its checkouts, build folders, simulator reservations and limits instead
/// of running its own xcodebuild in the runner's `_work` folder.
///
/// The job runs in the daemon (the `start_tool` control command); this side follows its log,
/// turns compiler errors and test failures into GitHub annotations, and exits with its status.
/// Kept in MiniRunKit, with the daemon behind `send`, so it's tested on Linux.
public enum CIRun {
    /// `minirun ci <command>` → the tool it runs.
    public static let commands: [(command: String, tool: String)] = [
        ("build", "build"), ("test", "run_tests"), ("swift-test", "swift_test"), ("sync", "sync_repo"),
    ]

    public static let usage = """
    Usage: minirun ci build|test|swift-test|sync [options]

    Runs the tool in the running `minirun serve` and follows it: its log streams here, compiler
    errors and test failures become GitHub annotations, and the exit status is the job's.
    Cancelling (SIGINT/SIGTERM, as GitHub does) cancels the job and frees its simulator.

    In a GitHub Actions job, --repo defaults to GITHUB_REPOSITORY, and without --ref or --commit
    the job builds GITHUB_SHA in the checkout "ci/<branch>" (GITHUB_HEAD_REF for a pull request,
    else GITHUB_REF_NAME), which stays warm from one run to the next.

    Options:
      --repo OWNER/NAME        --ref REF            --commit SHA
      --scheme NAME            --project PATH       --package PATH (swift-test)
      --configuration NAME     --platform ios|macos|mac-catalyst
      --extra-arg ARG          (repeatable) an extra xcodebuild argument
      --only-testing ID        (repeatable) for test; for swift-test, a --filter
      --skip-testing ID        (repeatable) for test; for swift-test, a --skip
      --timeout SECONDS        --stall SECONDS
      --args JSON              more tool arguments, as a JSON object; the options above win
    """

    public struct Invocation: Equatable, Sendable {
        public var tool: String
        public var arguments: [String: JSONValue]
    }

    /// Reads `minirun ci <command> [options]` (`argv` starts at the command) and fills in what
    /// the GitHub Actions environment says.
    public static func parse(_ argv: [String], environment: [String: String]) throws -> Invocation {
        guard let command = argv.first, let tool = commands.first(where: { $0.command == command })?.tool else {
            throw ToolError("Pass one of: \(commands.map(\.command).joined(separator: ", ")).\n\n\(usage)")
        }
        var args: [String: JSONValue] = [:]
        var lists: [String: [String]] = [:]
        var index = 1
        func value(_ flag: String) throws -> String {
            guard index + 1 < argv.count else { throw ToolError("\(flag) needs a value.") }
            index += 1
            return argv[index]
        }
        func integer(_ flag: String) throws -> JSONValue {
            let text = try value(flag)
            guard let number = Int(text), number > 0 else { throw ToolError("\(flag) needs a number of seconds, not \(text).") }
            return .number(Double(number))
        }
        var base: [String: JSONValue] = [:]
        let tests = tool == "swift_test" ? (only: "filter", skip: "skip") : (only: "only_testing", skip: "skip_testing")
        while index < argv.count {
            let flag = argv[index]
            switch flag {
            case "--repo": args["repo"] = .string(try value(flag))
            case "--ref": args["ref"] = .string(try value(flag))
            case "--commit": args["commit"] = .string(try value(flag))
            case "--scheme": args["scheme"] = .string(try value(flag))
            case "--project": args["project"] = .string(try value(flag))
            case "--package": args["package"] = .string(try value(flag))
            case "--configuration": args["configuration"] = .string(try value(flag))
            case "--platform": args["platform"] = .string(try value(flag))
            case "--extra-arg": lists["extra_args", default: []].append(try value(flag))
            case "--only-testing": lists[tests.only, default: []].append(try value(flag))
            case "--skip-testing": lists[tests.skip, default: []].append(try value(flag))
            case "--timeout": args["timeout_seconds"] = try integer(flag)
            case "--stall": args["stall_seconds"] = try integer(flag)
            case "--args":
                let text = try value(flag)
                guard let object = (try? JSONValue.parse(text))?.objectValue else { throw ToolError("--args must be a JSON object.") }
                base.merge(object) { _, new in new }
            case "-h", "--help": throw ToolError(usage)
            default: throw ToolError("Unknown option \(flag).\n\n\(usage)")
            }
            index += 1
        }
        for (key, values) in lists { args[key] = .array(values.map(JSONValue.string)) }
        var merged = base.merging(args) { _, flag in flag }

        if merged["repo"] == nil, let repo = environment["GITHUB_REPOSITORY"].flatMap(nonEmpty) { merged["repo"] = .string(repo) }
        guard merged["repo"]?.stringValue.flatMap(nonEmpty) != nil else {
            throw ToolError("Pass --repo owner/name (GITHUB_REPOSITORY isn't set, so this isn't a GitHub Actions job).")
        }
        if merged["ref"] == nil, merged["commit"] == nil, let ref = defaultRef(environment) {
            merged["ref"] = .string(ref)
            if let sha = environment["GITHUB_SHA"].flatMap(nonEmpty) { merged["commit"] = .string(sha) }
        }
        if let commit = merged["commit"]?.stringValue, !isCommit(commit) {
            throw ToolError("--commit must be a commit SHA (hex), not \(commit).")
        }
        return Invocation(tool: tool, arguments: merged)
    }

    /// "ci/<branch>": its own checkout and simulator, apart from Claude's sessions on the same
    /// branch, and the same one on every run of that branch, so its build folder stays warm.
    public static func defaultRef(_ environment: [String: String]) -> String? {
        guard let branch = environment["GITHUB_HEAD_REF"].flatMap(nonEmpty) ?? environment["GITHUB_REF_NAME"].flatMap(nonEmpty) else { return nil }
        return "ci/" + branch
    }

    /// 7 to 64 hex digits: what `commit` accepts, so it can never be read as an option by git.
    public static func isCommit(_ text: String) -> Bool {
        (7...64).contains(text.count) && text.allSatisfy(\.isHexDigit)
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// GitHub workflow commands (`::error file=…::message`) for a CI run's output.
public struct CIAnnotations {
    /// The checkout the job builds in, so errors get paths relative to the repository.
    public var checkout: String?
    public var limit = 50
    private var emitted: Set<String> = []
    private var counts: [String: Int] = [:]

    public init(checkout: String?, limit: Int = 50) {
        self.checkout = checkout
        self.limit = limit
    }

    /// The annotation for one line of the job's log, if it's a compiler error or warning, once
    /// per distinct one and at most `limit` of each kind.
    public mutating func annotate(logLine line: String) -> String? {
        guard let issue = Self.issue(line) else { return nil }
        var properties: [String] = []
        if let file = relative(issue.file) { properties.append("file=" + Self.escapeProperty(file)) }
        properties.append("line=\(issue.line)")
        if let column = issue.column { properties.append("col=\(column)") }
        return emit(issue.severity, properties: properties, message: issue.message)
    }

    /// The annotation for one line of the job's final result: a failed test ("✗ name: why").
    public mutating func annotate(resultLine line: String) -> String? {
        guard line.hasPrefix("✗ ") else { return nil }
        return emit("error", properties: ["title=Test failed"], message: String(line.dropFirst(2)))
    }

    private mutating func emit(_ severity: String, properties: [String], message: String) -> String? {
        let text = "::\(severity) \(properties.joined(separator: ","))::\(Self.escapeData(message))"
        guard counts[severity, default: 0] < limit, emitted.insert(text).inserted else { return nil }
        counts[severity, default: 0] += 1
        return text
    }

    private func relative(_ file: String) -> String? {
        guard let checkout else { return file }
        var root = checkout
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        guard file.hasPrefix(root + "/") else { return nil }
        return String(file.dropFirst(root.count + 1))
    }

    struct Issue: Equatable {
        var file: String
        var line: Int
        var column: Int?
        var severity: String
        var message: String
    }

    /// "/path/File.swift:12:5: error: message" (clang and swiftc), or without the column
    /// ("/path/FileTests.swift:12: error: -[Tests testX] : …", XCTest on macOS).
    static func issue(_ line: String) -> Issue? {
        for severity in ["error", "warning"] {
            guard let marker = line.range(of: ": \(severity): ") else { continue }
            let location = line[..<marker.lowerBound].split(separator: ":", omittingEmptySubsequences: false)
            guard location.count >= 2, location[0].hasPrefix("/"), let last = Int(location[location.count - 1]) else { continue }
            let message = String(line[marker.upperBound...])
            if location.count >= 3, let lineNumber = Int(location[location.count - 2]) {
                let file = location[0..<(location.count - 2)].joined(separator: ":")
                return Issue(file: file, line: lineNumber, column: last, severity: severity, message: message)
            }
            let file = location[0..<(location.count - 1)].joined(separator: ":")
            return Issue(file: file, line: last, column: nil, severity: severity, message: message)
        }
        return nil
    }

    static func escapeData(_ text: String) -> String {
        text.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "\r", with: "%0D").replacingOccurrences(of: "\n", with: "%0A")
    }

    static func escapeProperty(_ text: String) -> String {
        escapeData(text).replacingOccurrences(of: ":", with: "%3A").replacingOccurrences(of: ",", with: "%2C")
    }
}

/// Follows a job `minirun serve` runs: prints its log as it grows (with annotations) and then its
/// result. The daemon is behind `send`, so tests can stand in for it.
public struct CIFollower {
    public typealias Send = (ControlProtocol.Request) throws -> ControlProtocol.Response

    let send: Send
    let output: (String) -> Void
    let pollInterval: TimeInterval
    let stepSummary: String?

    public init(send: @escaping Send, output: @escaping (String) -> Void, pollInterval: TimeInterval = 1, stepSummary: String? = nil) {
        self.send = send
        self.output = output
        self.pollInterval = pollInterval
        self.stepSummary = stepSummary
    }

    /// Exit status: 0 when the job succeeded, 1 when it failed or was cancelled, 3 when
    /// `minirun serve` can't run it.
    public static let failed: Int32 = 1, unavailable: Int32 = 3

    /// Starts the job. Throws with what to do when the daemon is missing or too old.
    public func start(_ invocation: CIRun.Invocation) throws -> ControlProtocol.JobReport {
        let response: ControlProtocol.Response
        do {
            response = try send(ControlProtocol.Request(command: "start_tool", tool: invocation.tool, arguments: .object(invocation.arguments)))
        } catch {
            throw ToolError("minirun serve isn't answering (\(error.localizedDescription)). Is it running on this Mac, as the runner's user?")
        }
        guard response.ok, let job = response.job else {
            if (response.controlVersion ?? 0) < ControlProtocol.startToolVersion {
                throw ToolError("This Mac's minirun serve is too old to run CI jobs. Update minirun (the menu bar app does it), then run the job again.")
            }
            throw ToolError(response.error ?? "minirun serve didn't start the job.")
        }
        return job
    }

    /// Follows the job until it finishes and returns the exit status. `cancelled` is checked
    /// between polls; once it's true the job is cancelled and followed to its end.
    public func follow(_ started: ControlProtocol.JobReport, cancelled: () -> Bool = { false }, sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> Int32 {
        var annotations = CIAnnotations(checkout: started.checkout)
        var tail = LogTail(path: started.logPath)
        output("minirun: \(started.title) (\(started.id))" + (started.checkout.map { " in \($0)" } ?? ""))
        var job = started
        var askedToCancel = false
        var misses = 0
        while job.status == "running" {
            if cancelled(), !askedToCancel {
                askedToCancel = true
                output("minirun: cancelling \(job.id)")
                _ = try? send(ControlProtocol.Request(command: "cancel_job", id: job.id))
            }
            for line in tail.read() { print(line, &annotations) }
            sleep(pollInterval)
            do {
                let response = try send(ControlProtocol.Request(command: "job", id: job.id))
                guard response.ok, let next = response.job else {
                    output("::error title=minirun::\(CIAnnotations.escapeData(response.error ?? "minirun serve lost the job."))")
                    return Self.unavailable
                }
                job = next
                misses = 0
            } catch {
                // minirun serve restarting: its jobs are written down, so ask again a few times.
                misses += 1
                if misses > 30 {
                    output("::error title=minirun::minirun serve stopped answering: \(CIAnnotations.escapeData(error.localizedDescription))")
                    return Self.unavailable
                }
            }
        }
        for line in tail.read(final: true) { print(line, &annotations) }

        let text = job.text ?? ""
        output("minirun: \(job.title) \(job.status)")
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            output(String(line))
            if let annotation = annotations.annotate(resultLine: String(line)) { output(annotation) }
        }
        if job.status != "succeeded", !text.isEmpty {
            output("::error title=minirun \(job.status)::\(CIAnnotations.escapeData(String(text.prefix(900))))")
        }
        if let stepSummary {
            let summary = "### minirun: \(job.title) \(job.status)\n\n```\n\(text)\n```\n"
            if let handle = FileHandle(forWritingAtPath: stepSummary) {
                _ = try? handle.seekToEnd()
                handle.write(Data(summary.utf8))
                try? handle.close()
            } else {
                try? summary.write(toFile: stepSummary, atomically: true, encoding: .utf8)
            }
        }
        return job.status == "succeeded" ? 0 : Self.failed
    }

    private func print(_ line: String, _ annotations: inout CIAnnotations) {
        output(line)
        if let annotation = annotations.annotate(logLine: line) { output(annotation) }
    }

    /// Reads the lines added to a file since the last read, holding back a partial last line.
    struct LogTail {
        let path: String?
        var offset: UInt64 = 0
        var partial = Data()

        init(path: String?) { self.path = path }

        mutating func read(final: Bool = false) -> [String] {
            guard let path, let handle = FileHandle(forReadingAtPath: path) else { return [] }
            defer { try? handle.close() }
            try? handle.seek(toOffset: offset)
            let data = (try? handle.readToEnd()) ?? Data()
            offset += UInt64(data.count)
            partial.append(data)
            var lines: [String] = []
            while let newline = partial.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(String(decoding: partial[partial.startIndex..<newline], as: UTF8.self))
                partial = Data(partial[partial.index(after: newline)...])
            }
            if final, !partial.isEmpty {
                lines.append(String(decoding: partial, as: UTF8.self))
                partial = Data()
            }
            return lines
        }
    }
}
