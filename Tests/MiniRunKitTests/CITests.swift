import XCTest
@testable import MiniRunKit

final class CIRunParseTests: XCTestCase {
    let pullRequest = [
        "GITHUB_REPOSITORY": "you/app", "GITHUB_SHA": "0123456789abcdef0123456789abcdef01234567",
        "GITHUB_HEAD_REF": "feature/login", "GITHUB_REF_NAME": "12/merge",
    ]

    func testAPullRequestBuildsItsCommitInTheBranchsCICheckout() throws {
        let run = try CIRun.parse(["test", "--scheme", "App", "--only-testing", "AppTests/A", "--only-testing", "AppTests/B"], environment: pullRequest)
        XCTAssertEqual(run.tool, "run_tests")
        XCTAssertEqual(run.arguments["repo"], "you/app")
        XCTAssertEqual(run.arguments["ref"], "ci/feature/login")
        XCTAssertEqual(run.arguments["commit"], "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(run.arguments["scheme"], "App")
        XCTAssertEqual(run.arguments["only_testing"], ["AppTests/A", "AppTests/B"])
    }

    func testAPushUsesTheRefName() throws {
        let push = ["GITHUB_REPOSITORY": "you/app", "GITHUB_SHA": "abcdef1", "GITHUB_HEAD_REF": "", "GITHUB_REF_NAME": "main"]
        let run = try CIRun.parse(["build", "--extra-arg", "CODE_SIGNING_ALLOWED=NO", "--timeout", "600"], environment: push)
        XCTAssertEqual(run.tool, "build")
        XCTAssertEqual(run.arguments["ref"], "ci/main")
        XCTAssertEqual(run.arguments["commit"], "abcdef1")
        XCTAssertEqual(run.arguments["extra_args"], ["CODE_SIGNING_ALLOWED=NO"])
        XCTAssertEqual(run.arguments["timeout_seconds"], 600)
    }

    func testAnExplicitRefOrCommitIsKept() throws {
        let ref = try CIRun.parse(["sync", "--ref", "main"], environment: pullRequest)
        XCTAssertEqual(ref.tool, "sync_repo")
        XCTAssertEqual(ref.arguments["ref"], "main")
        XCTAssertNil(ref.arguments["commit"], "--ref alone means that ref's latest")
        let both = try CIRun.parse(["build", "--repo", "them/lib", "--ref", "ci/x", "--commit", "abc1234"], environment: pullRequest)
        XCTAssertEqual(both.arguments["repo"], "them/lib")
        XCTAssertEqual(both.arguments["commit"], "abc1234")
    }

    func testSwiftTestFiltersAndArgs() throws {
        let run = try CIRun.parse([
            "swift-test", "--package", "Packages/Core", "--only-testing", "CoreTests", "--skip-testing", "SlowTests",
            "--args", #"{"stall_seconds": 120, "package": "ignored"}"#,
        ], environment: pullRequest)
        XCTAssertEqual(run.tool, "swift_test")
        XCTAssertEqual(run.arguments["filter"], ["CoreTests"])
        XCTAssertEqual(run.arguments["skip"], ["SlowTests"])
        XCTAssertEqual(run.arguments["stall_seconds"], 120)
        XCTAssertEqual(run.arguments["package"], "Packages/Core", "options win over --args")
    }

    func testMistakes() {
        XCTAssertThrowsError(try CIRun.parse([], environment: pullRequest))
        XCTAssertThrowsError(try CIRun.parse(["deploy"], environment: pullRequest))
        XCTAssertThrowsError(try CIRun.parse(["build", "--wat"], environment: pullRequest))
        XCTAssertThrowsError(try CIRun.parse(["build", "--scheme"], environment: pullRequest), "a flag without its value")
        XCTAssertThrowsError(try CIRun.parse(["build", "--timeout", "soon"], environment: pullRequest))
        XCTAssertThrowsError(try CIRun.parse(["build", "--args", "[1]"], environment: pullRequest))
        XCTAssertThrowsError(try CIRun.parse(["build"], environment: [:]), "no repo outside GitHub Actions")
        XCTAssertThrowsError(try CIRun.parse(["build", "--commit", "--upload-pack=evil"], environment: pullRequest), "never an option for git")
    }

    func testIsCommit() {
        XCTAssertTrue(CIRun.isCommit("abc1234"))
        XCTAssertTrue(CIRun.isCommit("0123456789abcdef0123456789abcdef01234567"))
        XCTAssertFalse(CIRun.isCommit("abc123"))
        XCTAssertFalse(CIRun.isCommit("main"))
        XCTAssertFalse(CIRun.isCommit("-abc1234"))
    }
}

final class CIAnnotationTests: XCTestCase {
    func testCompilerErrorsGetRepositoryPaths() {
        var annotations = CIAnnotations(checkout: "/w/you/app@ci-main-1/")
        XCTAssertEqual(
            annotations.annotate(logLine: "/w/you/app@ci-main-1/Sources/App/Login.swift:12:5: error: cannot find 'x' in scope"),
            "::error file=Sources/App/Login.swift,line=12,col=5::cannot find 'x' in scope"
        )
        XCTAssertNil(annotations.annotate(logLine: "/w/you/app@ci-main-1/Sources/App/Login.swift:12:5: error: cannot find 'x' in scope"), "once each")
        XCTAssertEqual(
            annotations.annotate(logLine: "/Users/me/Library/Developer/X.swift:1:2: warning: 50% done, really"),
            "::warning line=1,col=2::50%25 done, really",
            "outside the checkout: no file"
        )
        XCTAssertNil(annotations.annotate(logLine: "** BUILD FAILED **"))
        XCTAssertNil(annotations.annotate(logLine: "note: error: in a sentence"))
    }

    func testXCTestFailuresHaveNoColumn() {
        var annotations = CIAnnotations(checkout: "/w/you/pkg")
        XCTAssertEqual(
            annotations.annotate(logLine: "/w/you/pkg/Tests/PkgTests/PkgTests.swift:5: error: -[PkgTests.PkgTests testFails] : XCTAssertEqual failed: (\"2\") is not equal to (\"3\") - on purpose"),
            "::error file=Tests/PkgTests/PkgTests.swift,line=5::-[PkgTests.PkgTests testFails] : XCTAssertEqual failed: (\"2\") is not equal to (\"3\") - on purpose"
        )
    }

    func testPathsThroughASymbolicLinkStillMatch() throws {
        // As on macOS, where /var links to /private/var and tools print the real path.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("minirun-link-\(UUID().uuidString.prefix(8))").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: base + "/real/you/pkg", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: base + "/link", withDestinationPath: base + "/real")
        var annotations = CIAnnotations(checkout: base + "/link/you/pkg")
        let real = URL(fileURLWithPath: base + "/real/you/pkg").resolvingSymlinksInPath().path
        XCTAssertEqual(annotations.annotate(logLine: real + "/Tests/T.swift:5: error: boom"), "::error file=Tests/T.swift,line=5::boom")
        XCTAssertEqual(annotations.annotate(logLine: base + "/link/you/pkg/A.swift:1:2: error: too"), "::error file=A.swift,line=1,col=2::too")
    }

    func testFileNamesWithColonsAndCommasAreEscaped() {
        var annotations = CIAnnotations(checkout: "/w")
        XCTAssertEqual(annotations.annotate(logLine: "/w/a:b,c.swift:3:4: error: no"), "::error file=a%3Ab%2Cc.swift,line=3,col=4::no")
    }

    func testFailedTestsAndLimits() {
        var annotations = CIAnnotations(checkout: nil, limit: 2)
        XCTAssertEqual(annotations.annotate(resultLine: "✗ AppTests/LoginTests/testLogin: XCTAssertEqual failed"),
                       "::error title=Test failed::AppTests/LoginTests/testLogin: XCTAssertEqual failed")
        XCTAssertNil(annotations.annotate(resultLine: "Result: Failed — 1 passed"))
        XCTAssertNotNil(annotations.annotate(logLine: "/a.swift:1:1: error: two"))
        XCTAssertNil(annotations.annotate(logLine: "/a.swift:1:1: error: three"), "at most `limit` errors")
        XCTAssertNotNil(annotations.annotate(logLine: "/a.swift:1:1: warning: warnings count on their own"))
    }

    func testJobIDInAToolResult() {
        XCTAssertEqual(ControlProtocol.jobID(in: .text("[job_1a2b3c4d] build you/app is still running (0s so far).")), "job_1a2b3c4d")
        XCTAssertEqual(ControlProtocol.jobID(in: ToolResult([.text("[job_00ff00ff] tests: failed in 3s"), .text("x")], isError: true)), "job_00ff00ff")
        XCTAssertNil(ControlProtocol.jobID(in: .error("Pass `repo` (owner/name) or `path`.")))
        XCTAssertNil(ControlProtocol.jobID(in: .text("[job_nothex!] x")))
    }
}

/// A daemon that runs one job: start_tool starts it, each `job` call moves it along a script.
final class FakeJobCommands: ControlCommands, @unchecked Sendable {
    let snapshot = ServeStatus(version: "t", pid: 1, startedAt: Date(), relay: .init(state: .connected))
    let started = Locked<[String]>([])
    let cancels = Locked<[String]>([])
    let script: Locked<[ControlProtocol.JobReport]>
    let log: String

    init(log: String, script: [ControlProtocol.JobReport]) {
        self.log = log
        self.script = Locked(script)
    }

    func startTool(_ name: String, arguments: [String: JSONValue]) async throws -> ControlProtocol.JobReport {
        started.mutate { $0.append("\(name) \(arguments["ref"]?.stringValue ?? "-")") }
        return ControlProtocol.JobReport(id: "job_00000001", title: "tests you/app@ci/main", status: "running", logPath: log, checkout: "/w/you/app")
    }

    func job(id: String) async throws -> ControlProtocol.JobReport {
        var next: ControlProtocol.JobReport!
        script.mutate { list in next = list.count > 1 ? list.removeFirst() : list[0] }
        return next
    }

    func cancelJob(id: String) async throws -> String {
        cancels.mutate { $0.append(id) }
        script.mutate { $0 = [ControlProtocol.JobReport(id: id, title: "tests you/app@ci/main", status: "cancelled", text: "Cancelled.")] }
        return "Cancelled."
    }

    func status() async -> ServeStatus { snapshot }
    func reloadConfig() async throws -> ConfigReload { ConfigReload() }
    func shutdownSimulator(udid: String) async throws -> String { "" }
    func releaseSimulator(udid: String) async throws -> String { "" }
    func workspaces() async throws -> [WorkspaceInfo] { [] }
    func deleteWorkspace(path: String) async throws -> String { "" }
    func doctor() async -> [DoctorCheck] { [] }
    func listMedia() async throws -> [MediaItem] { [] }
    func deleteMedia(id: String) async throws -> String { "" }
    func deleteAllMedia() async throws -> String { "" }
    func stopRecording(udid: String) async throws -> String { "" }
}

final class CIFollowerTests: XCTestCase {
    var directory = ""

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("minirun-ci-\(UUID().uuidString.prefix(8))").path
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: directory) }

    /// Answers requests the way the socket does, without one.
    func sender(_ commands: ControlCommands) -> CIFollower.Send {
        { request in
            let line = ControlProtocol.encode(request)
            let answer = Locked<String>("")
            let done = DispatchSemaphore(value: 0)
            Task {
                let response = await ControlProtocol.respond(to: line, commands: commands)
                answer.mutate { $0 = response }
                done.signal()
            }
            done.wait()
            return try ControlProtocol.decode(ControlProtocol.Response.self, from: answer.value)
        }
    }

    func testFollowsTheLogAndExitsWithTheJobsStatus() throws {
        let log = directory + "/test.log"
        try "$ xcodebuild test\n/w/you/app/Sources/A.swift:3:1: warning: unused\nhalf a li".write(toFile: log, atomically: true, encoding: .utf8)
        let fake = FakeJobCommands(log: log, script: [
            .init(id: "job_00000001", title: "tests you/app@ci/main", status: "running"),
            .init(id: "job_00000001", title: "tests you/app@ci/main", status: "failed",
                  text: "Scheme App: FAILED\n✗ AppTests/T/testA: boom\nLog: /x"),
        ])
        let lines = Locked<[String]>([])
        let summary = directory + "/summary.md"
        let follower = CIFollower(send: sender(fake), output: { line in lines.mutate { $0.append(line) } }, pollInterval: 0, stepSummary: summary)
        let invocation = try CIRun.parse(["test"], environment: ["GITHUB_REPOSITORY": "you/app", "GITHUB_REF_NAME": "main", "GITHUB_SHA": "abcdef1"])
        let started = try follower.start(invocation)
        XCTAssertEqual(fake.started.value, ["run_tests ci/main"])

        var polls = 0
        let status = follower.follow(started, sleep: { _ in
            polls += 1
            if polls == 1 { try? "ne\n".appendLine(to: log) }
        })
        XCTAssertEqual(status, CIFollower.failed)
        let output = lines.value
        XCTAssertTrue(output.contains("$ xcodebuild test"))
        XCTAssertTrue(output.contains("::warning file=Sources/A.swift,line=3,col=1::unused"))
        XCTAssertTrue(output.contains("half a line"), "a line written in two parts comes out whole")
        XCTAssertTrue(output.contains("::error title=Test failed::AppTests/T/testA: boom"))
        XCTAssertTrue(output.contains { $0.hasPrefix("::error title=minirun failed::Scheme App: FAILED%0A") })
        XCTAssertTrue(try String(contentsOfFile: summary, encoding: .utf8).contains("✗ AppTests/T/testA: boom"))
    }

    func testCancellingCancelsTheJob() throws {
        let fake = FakeJobCommands(log: directory + "/missing.log", script: [.init(id: "job_00000001", title: "t", status: "running")])
        let follower = CIFollower(send: sender(fake), output: { _ in }, pollInterval: 0)
        let started = try follower.start(CIRun.Invocation(tool: "build", arguments: ["repo": "you/app"]))
        var asked = 0
        let status = follower.follow(started, cancelled: { asked += 1; return asked > 2 }, sleep: { _ in })
        XCTAssertEqual(status, CIFollower.failed)
        XCTAssertEqual(fake.cancels.value, ["job_00000001"], "cancelled once")
    }

    func testSucceeds() throws {
        let fake = FakeJobCommands(log: directory + "/none.log", script: [.init(id: "job_00000001", title: "t", status: "succeeded", text: "Built App in 3s.")])
        let follower = CIFollower(send: sender(fake), output: { _ in }, pollInterval: 0)
        XCTAssertEqual(follower.follow(try follower.start(CIRun.Invocation(tool: "build", arguments: [:])), sleep: { _ in }), 0)
    }

    func testAnOldDaemonSaysToUpdate() {
        let old = MinimalControlCommands(snapshot: ServeStatus(version: "t", pid: 1, startedAt: Date(), relay: .init(state: .connected)))
        let follower = CIFollower(send: { request in
            // A version 6 daemon: no start_tool.
            var response = try self.sender(old)(request)
            response.controlVersion = 6
            response.error = "Unknown command start_tool."
            response.ok = false
            return response
        }, output: { _ in })
        XCTAssertThrowsError(try follower.start(CIRun.Invocation(tool: "build", arguments: [:]))) { error in
            XCTAssertTrue(error.localizedDescription.contains("too old"))
        }
        let refusing = CIFollower(send: { _ in throw ToolError("Connection refused") }, output: { _ in })
        XCTAssertThrowsError(try refusing.start(CIRun.Invocation(tool: "build", arguments: [:]))) { error in
            XCTAssertTrue(error.localizedDescription.contains("isn't answering"))
        }
    }

    func testStartToolOnlyRunsCIToolsAndRoundTripsOverTheSocket() async throws {
        let fake = FakeJobCommands(log: "/none", script: [.init(id: "job_00000001", title: "t", status: "succeeded")])
        let path = directory + "/c.sock"
        let server = ControlServer(path: path) { await ControlProtocol.respond(to: $0, commands: fake) }
        try server.start()
        defer { server.stop() }
        func ask(_ request: ControlProtocol.Request) async throws -> ControlProtocol.Response {
            try await Task.detached { try ControlProtocol.send(request, path: path) }.value
        }
        let started = try await ask(.init(command: "start_tool", tool: "run_tests", arguments: ["repo": "you/app", "ref": "ci/main"]))
        XCTAssertTrue(started.ok)
        XCTAssertEqual(started.controlVersion, ControlProtocol.version)
        XCTAssertEqual(started.job?.checkout, "/w/you/app")
        let job = try await ask(.init(command: "job", id: "job_00000001"))
        XCTAssertEqual(job.job?.status, "succeeded")

        let refused = try await ask(.init(command: "start_tool", tool: "run_command", arguments: ["command": "rm -rf ~"]))
        XCTAssertFalse(refused.ok)
        XCTAssertTrue(refused.error?.contains("not run_command") == true)
        let bare = try await ask(.init(command: "start_tool", tool: "build"))
        XCTAssertFalse(bare.ok, "arguments are required")
        XCTAssertEqual(fake.started.value, ["run_tests ci/main"])

        let minimal = MinimalControlCommands(snapshot: fake.snapshot)
        let line = await ControlProtocol.respond(to: ControlProtocol.encode(ControlProtocol.Request(command: "start_tool", tool: "build", arguments: [:])), commands: minimal)
        XCTAssertTrue(line.contains("can't run tools"))
    }
}

private extension String {
    func appendLine(to path: String) throws {
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        _ = try handle.seekToEnd()
        handle.write(Data(utf8))
        try handle.close()
    }
}
