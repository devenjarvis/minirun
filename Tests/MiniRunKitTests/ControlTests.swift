import XCTest
@testable import MiniRunKit

/// Records control commands and answers them with canned results.
final class FakeControlCommands: ControlCommands, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var snapshot: ServeStatus
    var reload = ConfigReload(applied: ["idleShutdownMinutes"], reconnecting: ["agentToken"])
    var checks = [DoctorCheck(id: "xcode", title: "Xcode", ok: true, detail: "Xcode 26.0")]

    init(status: ServeStatus) { snapshot = status }

    var calls: [String] { lock.withLock { log } }
    private func record(_ call: String) { lock.withLock { log.append(call) } }

    func status() async -> ServeStatus { snapshot }
    func reloadConfig() async throws -> ConfigReload { record("reload"); return reload }
    func shutdownSimulator(udid: String) async throws -> String { record("shutdown \(udid)"); return "Shut down \(udid)." }
    func releaseSimulator(udid: String) async throws -> String { record("release \(udid)"); return "Released \(udid)." }
    func cancelJob(id: String) async throws -> String {
        record("cancel \(id)")
        throw ToolError("\(id) already succeeded.")
    }
    func workspaces() async throws -> [WorkspaceInfo] {
        [WorkspaceInfo(path: "/w/you/app", name: "you/app", sizeBytes: 1234, lastUsed: Date(timeIntervalSince1970: 1_000_000), busy: true)]
    }
    func deleteWorkspace(path: String) async throws -> String { record("delete \(path)"); return "Deleted \(path)." }
    func doctor() async -> [DoctorCheck] { checks }
    var media: [MediaItem] = []
    func listMedia() async throws -> [MediaItem] { media }
    func deleteMedia(id: String) async throws -> String { record("delete media \(id)"); return "Deleted \(id)." }
    func deleteAllMedia() async throws -> String { record("delete all media"); return "Deleted everything." }
    func stopRecording(udid: String) async throws -> String { record("stop recording \(udid)"); return "Stopped \(udid)." }
}

final class ControlCommandTests: XCTestCase {
    let status = ServeStatus(version: "0.1.0", pid: 7, startedAt: Date(timeIntervalSince1970: 1_000_000), relay: .init(state: .connecting, since: Date(timeIntervalSince1970: 1_000_100)))

    func ask(_ commands: ControlCommands, _ request: ControlProtocol.Request) async throws -> ControlProtocol.Response {
        let line = await ControlProtocol.respond(to: ControlProtocol.encode(request), commands: commands)
        XCTAssertFalse(line.contains("\n"), "one response line")
        return try ControlProtocol.decode(ControlProtocol.Response.self, from: line)
    }

    func testEveryCommand() async throws {
        let fake = FakeControlCommands(status: status)
        typealias Request = ControlProtocol.Request

        let status = try await ask(fake, Request(command: "status"))
        XCTAssertEqual(status.status, self.status)
        XCTAssertEqual(status.controlVersion, ControlProtocol.version)

        let reload = try await ask(fake, Request(command: "reload_config"))
        XCTAssertEqual(reload.reload, fake.reload)
        XCTAssertEqual(reload.message, "Applied idleShutdownMinutes. Reconnecting to the relay for agentToken.")

        let shutdown = try await ask(fake, Request(command: "shutdown_simulator", udid: "SIM-A"))
        XCTAssertEqual(shutdown.message, "Shut down SIM-A.")
        let release = try await ask(fake, Request(command: "release_simulator", udid: "SIM-B"))
        XCTAssertEqual(release.message, "Released SIM-B.")
        let delete = try await ask(fake, Request(command: "delete_workspace", path: "/w/you/app"))
        XCTAssertEqual(delete.message, "Deleted /w/you/app.")

        let cancel = try await ask(fake, Request(command: "cancel_job", id: "job_1"))
        XCTAssertFalse(cancel.ok)
        XCTAssertEqual(cancel.error, "job_1 already succeeded.")
        XCTAssertEqual(cancel.controlVersion, ControlProtocol.version, "errors carry the version too")

        let workspaces = try await ask(fake, Request(command: "workspaces"))
        XCTAssertEqual(workspaces.workspaces?.first?.name, "you/app")
        XCTAssertEqual(workspaces.workspaces?.first?.busy, true)
        let doctor = try await ask(fake, Request(command: "doctor"))
        XCTAssertEqual(doctor.doctor, fake.checks)

        fake.media = [MediaItem(id: "AAAAAAAAAAAAAAAAAAAAAA", kind: .screenshot, files: [.init(ext: "jpg", bytes: 10)],
                                createdAt: Date(timeIntervalSince1970: 1_000_000), expiresAt: Date(timeIntervalSince1970: 2_000_000),
                                repo: "you/app", ref: "main", url: "https://h/m/AAAAAAAAAAAAAAAAAAAAAA.jpg")]
        let media = try await ask(fake, Request(command: "list_media"))
        XCTAssertEqual(media.media, fake.media)
        let deleteMedia = try await ask(fake, Request(command: "delete_media", id: "AAAAAAAAAAAAAAAAAAAAAA"))
        XCTAssertEqual(deleteMedia.message, "Deleted AAAAAAAAAAAAAAAAAAAAAA.")
        let deleteAll = try await ask(fake, Request(command: "delete_all_media"))
        XCTAssertEqual(deleteAll.message, "Deleted everything.")
        let stop = try await ask(fake, Request(command: "stop_recording", udid: "SIM-A"))
        XCTAssertEqual(stop.message, "Stopped SIM-A.")
        let missing = try await ask(fake, Request(command: "stop_recording"))
        XCTAssertEqual(missing.error, "stop_recording needs udid.")

        XCTAssertEqual(fake.calls, ["reload", "shutdown SIM-A", "release SIM-B", "delete /w/you/app", "cancel job_1",
                                    "delete media AAAAAAAAAAAAAAAAAAAAAA", "delete all media", "stop recording SIM-A"])
    }

    func testMissingArgumentsAreRefusedBeforeTheyReachTheDaemon() async throws {
        let fake = FakeControlCommands(status: status)
        let shutdown = try await ask(fake, ControlProtocol.Request(command: "shutdown_simulator"))
        XCTAssertEqual(shutdown.error, "shutdown_simulator needs udid.")
        let delete = try await ask(fake, ControlProtocol.Request(command: "delete_workspace", path: ""))
        XCTAssertEqual(delete.error, "delete_workspace needs path.")
        XCTAssertEqual(fake.calls, [])
    }

    func testWireFormat() throws {
        // Requests leave out what they don't use, and an old daemon's reply has no controlVersion.
        XCTAssertEqual(ControlProtocol.encode(ControlProtocol.Request(command: "cancel_job", id: "job_1")), #"{"command":"cancel_job","id":"job_1"}"#)
        let old = try ControlProtocol.decode(ControlProtocol.Response.self, from: #"{"ok":false,"error":"Unknown command doctor."}"#)
        XCTAssertNil(old.controlVersion)
        XCTAssertEqual(ControlProtocol.encode(ControlProtocol.Response(ok: true, message: "hi")), #"{"controlVersion":3,"message":"hi","ok":true}"#)
    }
}

final class ConfigReloadTests: XCTestCase {
    func testDiffSaysWhatAppliesAndWhatReconnects() {
        let old = MiniRunConfig(relayURL: "wss://a/agent", agentToken: "t1")
        XCTAssertFalse(ConfigReload.diff(old, old).changed)
        XCTAssertEqual(ConfigReload.diff(old, old).summary, "Settings reloaded; nothing changed.")

        var new = old
        new.idleShutdownMinutes = 5
        new.allowShell = true
        new.agentToken = "t2"
        new.defaultDevice = "iPhone 17"
        let reload = ConfigReload.diff(old, new)
        XCTAssertEqual(reload.applied, ["allowShell", "defaultDevice", "idleShutdownMinutes"])
        XCTAssertEqual(reload.reconnecting, ["agentToken"])
        XCTAssertFalse(reload.summary.contains("t2"), "never shows the token")
    }

    func testLiveConfigTellsObserversAboutChangesOnly() throws {
        let live = LiveConfig(MiniRunConfig(relayURL: "wss://a/agent", agentToken: "t1"))
        let seen = Locked<[String]>([])
        live.observe { old, new in seen.mutate { $0.append("\(old.maxBootedSimulators)->\(new.maxBootedSimulators)") } }

        live.update(live.current)
        XCTAssertEqual(seen.value, [])
        var more = live.current
        more.maxBootedSimulators = 6
        XCTAssertEqual(live.update(more).applied, ["maxBootedSimulators"])
        XCTAssertEqual(live.current.maxBootedSimulators, 6)
        XCTAssertEqual(seen.value, ["4->6"])
    }

    func testReloadReadsTheFileAndKeepsSettingsIfItIsBroken() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minirun-reload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        let live = LiveConfig(MiniRunConfig(relayURL: "wss://a/agent", agentToken: "t1"))

        try Data(#"{"relayURL":"wss://b/agent","agentToken":"t1","preventSleep":false}"#.utf8).write(to: file)
        let reload = try live.reload(from: file)
        XCTAssertEqual(reload.applied, ["preventSleep"])
        XCTAssertEqual(reload.reconnecting, ["relayURL"])
        XCTAssertEqual(live.current.relayURL, "wss://b/agent")

        try Data("{ not json".utf8).write(to: file)
        XCTAssertThrowsError(try live.reload(from: file)) { XCTAssertTrue($0.localizedDescription.contains("isn't valid settings JSON")) }
        XCTAssertThrowsError(try live.reload(from: directory.appendingPathComponent("missing.json")))
        XCTAssertEqual(live.current.relayURL, "wss://b/agent", "a bad file changes nothing")
    }
}

/// A value shared between a test and @Sendable callbacks.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

final class WorkspaceInventoryTests: XCTestCase {
    var root = ""

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("minirun-ws-\(UUID().uuidString)").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
    }

    func make(_ checkout: String, bytes: Int, modified: Date) throws {
        let path = root + "/" + checkout
        try FileManager.default.createDirectory(atPath: path + "/.git", withIntermediateDirectories: true)
        try Data(count: bytes).write(to: URL(fileURLWithPath: path + "/file"))
        for item in [path + "/.git", path] {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: item)
        }
    }

    func testListsCheckoutsNewestFirstWithSizes() throws {
        try make("you/app", bytes: 1000, modified: Date(timeIntervalSince1970: 1_000))
        try make("you/app@feature-x", bytes: 3000, modified: Date(timeIntervalSince1970: 3_000))
        try make("them/lib", bytes: 10, modified: Date(timeIntervalSince1970: 2_000))
        try FileManager.default.createDirectory(atPath: root + "/.hidden/thing", withIntermediateDirectories: true)

        let list = WorkspaceInventory.list(root: root, busy: [root + "/them/lib/Sources"])
        XCTAssertEqual(list.map(\.name), ["you/app@feature-x", "them/lib", "you/app"])
        XCTAssertEqual(list.map(\.sizeBytes), [3000, 10, 1000])
        XCTAssertEqual(list.map(\.busy), [false, true, false], "a job inside a checkout makes it busy")
        XCTAssertEqual(list[0].lastUsed, Date(timeIntervalSince1970: 3_000))
        XCTAssertEqual(WorkspaceInventory.list(root: root + "/nowhere"), [])
    }

    func testDeleteOnlyTakesCheckouts() throws {
        try make("you/app", bytes: 10, modified: Date())
        try make("you/other", bytes: 10, modified: Date())

        for bad in [root + "/you", root, root + "/../elsewhere/x", root + "/you/app/Sources", "/etc/passwd", root + "/you/missing"] {
            XCTAssertThrowsError(try WorkspaceInventory.checkout(bad, root: root), bad)
        }
        let checkout = try WorkspaceInventory.checkout(root + "/you/../you/app/", root: root)
        XCTAssertEqual(checkout, WorkspaceInventory.standardized(root + "/you/app"))

        try WorkspaceInventory.delete(checkout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkout))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/you"), "the owner still has a checkout")
        try WorkspaceInventory.delete(try WorkspaceInventory.checkout(root + "/you/other", root: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/you"), "an empty owner folder goes too")
    }

    func testFormatSize() {
        XCTAssertEqual(WorkspaceInventory.formatSize(512), "512 bytes")
        XCTAssertEqual(WorkspaceInventory.formatSize(1_500_000), "1.5 MB")
        XCTAssertEqual(WorkspaceInventory.formatSize(23_000_000_000), "23 GB")
    }

    func testLockIfFree() async throws {
        let lock = KeyedLock()
        let inside = try await lock.withLock("a") { () async throws -> Int? in
            let held = await lock.held
            XCTAssertEqual(held, ["a"])
            return try await lock.withLockIfFree("a") { 1 }
        }
        XCTAssertNil(inside, "doesn't wait for a held key")
        let free = try await lock.withLockIfFree("a") { 2 }
        XCTAssertEqual(free, 2)
        let after = await lock.held
        XCTAssertEqual(after, [])
    }
}

final class DoctorTests: XCTestCase {
    static let simctl = """
    {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[
      {"udid":"A","name":"iPhone 17 Pro","state":"Booted","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"},
      {"udid":"B","name":"iPhone 17","state":"Shutdown","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17"}]}}
    """

    func testHealthyMac() async {
        let doctor = Doctor(
            run: { executable, arguments, _ in
                switch (executable, arguments.first) {
                case ("/usr/bin/xcrun", "xcodebuild"): return ShellResult(exitCode: 0, stdout: "Xcode 26.0\nBuild version 17A1")
                case ("/usr/bin/xcrun", "simctl"): return ShellResult(exitCode: 0, stdout: DoctorTests.simctl)
                default: return ShellResult(exitCode: 1, stdout: "", stderr: "You are not logged into any GitHub hosts.")
                }
            },
            loadFrameworks: { nil },
            serveStatus: { ServeStatus(version: "0.1.0", pid: 9, startedAt: Date(), relay: .init(state: .connected, host: "h")) }
        )
        let checks = await doctor.checks(config: MiniRunConfig(relayURL: "wss://h/agent", agentToken: "t", workspaceRoot: NSTemporaryDirectory() + "minirun-doctor"))
        XCTAssertEqual(checks.map(\.id), ["xcode", "frameworks", "simulators", "serve", "relay", "token", "workspaces", "shell", "github"])
        XCTAssertEqual(checks.filter { !$0.ok }.map(\.id), ["github"])
        XCTAssertEqual(checks.first { $0.id == "simulators" }?.detail, "2 iOS simulators, booted: iPhone 17 Pro")
        XCTAssertEqual(checks.first { $0.id == "xcode" }?.detail, "Xcode 26.0")
        XCTAssertTrue(checks.last!.optional)
        XCTAssertTrue(Doctor.format(checks).hasSuffix("- GitHub auth (for private repos): gh isn't logged in\n    optional: gh auth login && gh auth setup-git"))
    }

    func testBrokenMacSaysHowToFixEachThing() async {
        let doctor = Doctor(
            run: { executable, arguments, _ in
                arguments.first == "xcodebuild" ? ShellResult(exitCode: 69, stdout: "", stderr: "You have not agreed to the Xcode license agreements.") : nil
            },
            loadFrameworks: { "dlopen failed" },
            serveStatus: { nil }
        )
        // A workspace root under a file can never be created.
        let file = NSTemporaryDirectory() + "minirun-doctor-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: file, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: file) }
        let checks = await doctor.checks(config: MiniRunConfig(workspaceRoot: file + "/workspaces"))
        let failing = Dictionary(uniqueKeysWithValues: checks.filter { !$0.ok }.map { ($0.id, $0.fix ?? "") })
        XCTAssertEqual(Set(failing.keys), ["xcode", "frameworks", "simulators", "serve", "relay", "token", "workspaces", "github"])
        XCTAssertEqual(failing["xcode"], "sudo xcodebuild -license accept")
        XCTAssertEqual(failing["serve"], "launchctl kickstart -k gui/$(id -u)/dev.minirun.agent")
        XCTAssertEqual(failing["relay"], "minirun worker deploy")
        XCTAssertTrue(checks.allSatisfy { $0.ok || $0.fix != nil }, "every failure says what to do")
        XCTAssertTrue(Doctor.format(checks).contains("✗ Xcode: the Xcode license hasn't been accepted\n    fix: sudo xcodebuild -license accept"))
    }

    func testWithoutServeStatusTheServeCheckIsLeftOut() async {
        // minirun serve runs the checks itself for host_info, where "is serve running" is moot.
        let doctor = Doctor(run: { _, _, _ in nil }, loadFrameworks: { nil })
        let checks = await doctor.checks(config: MiniRunConfig(relayURL: "wss://h/agent", agentToken: "t", workspaceRoot: NSTemporaryDirectory() + "minirun-doctor"))
        XCTAssertEqual(checks.map(\.id), ["xcode", "frameworks", "simulators", "relay", "token", "workspaces", "shell", "github"])
    }

    func testKickstartArguments() {
        XCTAssertEqual(LaunchAgent.kickstartArguments(uid: 501, restart: false), ["kickstart", "gui/501/dev.minirun.agent"])
        XCTAssertEqual(LaunchAgent.kickstartArguments(uid: 501, restart: true), ["kickstart", "-k", "gui/501/dev.minirun.agent"])
    }
}

final class JobCancelTests: XCTestCase {
    func testCancellingAJobStopsItsCommand() async throws {
        let jobs = JobStore()
        let finished = Locked<ShellResult?>(nil)
        let id = await jobs.start(title: "sleepy", logPath: nil) {
            let result = try await Shell.run("/bin/sh", ["-c", "sleep 30; echo done"], timeout: 60)
            finished.mutate { $0 = result }
            return .text("finished")
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let started = Date()
        let cancelled = try await jobs.cancel(id)
        XCTAssertEqual(cancelled.status, .cancelled)
        let report = await jobs.report(id, waited: 5)
        XCTAssertTrue(report.isError)
        XCTAssertTrue(report.content.description.contains("cancelled"), "\(report.content)")

        // The shell and its sleep are gone well before the 30 seconds are up.
        while finished.value == nil, Date().timeIntervalSince(started) < 10 { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        XCTAssertNotEqual(finished.value?.exitCode, 0)
        XCTAssertEqual(finished.value?.stdout, "")
        let job = await jobs.job(id)
        XCTAssertEqual(job?.status, .cancelled, "finishing later doesn't undo the cancel")

        do {
            try await jobs.cancel(id)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already cancelled"), error.localizedDescription)
        }
    }

    func testCancelUnknownJob() async {
        let jobs = JobStore()
        do {
            try await jobs.cancel("job_nope")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "No job with id job_nope.")
        }
    }
}
