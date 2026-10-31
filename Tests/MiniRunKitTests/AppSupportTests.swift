import Foundation
import XCTest
@testable import MiniRunKit

final class LaunchAgentTests: XCTestCase {
    func testPlistRunsTheProgramAndReadsBack() throws {
        let program = "/Applications/minirun.app/Contents/Helpers/minirun"
        let plist = LaunchAgent.plist(program: program, log: "/Users/me/Library/Logs/minirun/minirun.log")
        XCTAssertTrue(plist.contains("<string>dev.minirun.agent</string>"))
        XCTAssertTrue(plist.contains("<key>KeepAlive</key><true/>"))
        XCTAssertEqual(LaunchAgent.program(inPlist: plist), program)
        XCTAssertEqual(LaunchAgent.program(inPlist: LaunchAgent.plist(program: "/tmp/a&b/minirun")), "/tmp/a&b/minirun", "escaped for XML")
        XCTAssertNil(LaunchAgent.program(inPlist: "not a plist"))
    }

    func testPlan() {
        let helper = "/Applications/minirun.app/Contents/Helpers/minirun"
        let exists: (String) -> Bool = { $0 != "/gone/minirun" }
        XCTAssertEqual(LaunchAgent.plan(installedProgram: nil, helper: helper, helperIsInstalled: true, exists: exists), .install)
        XCTAssertEqual(LaunchAgent.plan(installedProgram: helper, helper: helper, helperIsInstalled: true, exists: exists), .upToDate)
        XCTAssertEqual(LaunchAgent.plan(installedProgram: LaunchAgent.legacyProgram, helper: helper, helperIsInstalled: true, exists: exists),
                       .repoint(from: LaunchAgent.legacyProgram), "an install.sh install moves into the app")

        // A development build only takes over an install that's broken or the old layout.
        let dev = "/Users/me/minirun/.build/app/Build/Products/Release/minirun.app/Contents/Helpers/minirun"
        XCTAssertEqual(LaunchAgent.plan(installedProgram: helper, helper: dev, helperIsInstalled: false, exists: exists), .leave(other: helper))
        XCTAssertEqual(LaunchAgent.plan(installedProgram: "/gone/minirun", helper: dev, helperIsInstalled: false, exists: exists), .repoint(from: "/gone/minirun"))
        XCTAssertEqual(LaunchAgent.plan(installedProgram: LaunchAgent.legacyProgram, helper: dev, helperIsInstalled: false, exists: exists),
                       .repoint(from: LaunchAgent.legacyProgram))
        XCTAssertEqual(LaunchAgent.plan(installedProgram: "", helper: dev, helperIsInstalled: false, exists: exists), .repoint(from: ""), "an unreadable plist is replaced")
    }

    func testApplicationsFolder() {
        XCTAssertTrue(LaunchAgent.isInApplicationsFolder("/Applications/minirun.app"))
        XCTAssertTrue(LaunchAgent.isInApplicationsFolder(MiniRunConfig.home + "/Applications/minirun.app/"))
        XCTAssertFalse(LaunchAgent.isInApplicationsFolder("/Users/me/Library/Developer/Xcode/DerivedData/x/minirun.app"))
    }

    func testCommandLineToolCommand() {
        let command = CommandLineTool.installCommand(helper: "/Applications/min'run.app/Contents/Helpers/minirun")
        XCTAssertEqual(command, #"mkdir -p '/usr/local/bin' && ln -sf '/Applications/min'\''run.app/Contents/Helpers/minirun' '/usr/local/bin/minirun'"#)
        XCTAssertEqual(CommandLineTool.adminAppleScript(#"echo "hi" \ there"#), #"do shell script "echo \"hi\" \\ there" with administrator privileges"#)
    }
}

final class SettingsFormTests: XCTestCase {
    func testRoundTripAndValidation() {
        let config = MiniRunConfig(relayURL: "wss://h/agent", agentToken: "secret", defaultDevice: "iPhone 17", idleShutdownMinutes: 30)
        var form = SettingsForm(config)
        XCTAssertEqual(form.defaultDevice, "iPhone 17")
        XCTAssertTrue(form.problems.isEmpty)

        form.defaultDevice = " "
        form.idleShutdownMinutes = 0
        form.workspaceRoot = "~/elsewhere"
        let updated = form.applied(to: config)
        XCTAssertNil(updated.defaultDevice, "blank means automatic")
        XCTAssertEqual(updated.idleShutdownMinutes, 0)
        XCTAssertEqual(updated.workspaceRoot, MiniRunConfig.home + "/elsewhere")
        XCTAssertEqual(updated.agentToken, "secret", "the relay settings aren't the form's")

        form.maxBootedSimulators = 0
        form.workspaceRoot = "relative"
        XCTAssertEqual(form.problems.count, 2)
    }

    func testDeviceChoices() {
        func device(_ name: String, _ runtime: String = "com.apple.CoreSimulator.SimRuntime.iOS-26-0") -> XcodeParsing.SimDevice {
            XcodeParsing.SimDevice(udid: name, name: name, state: "Shutdown", runtime: runtime, isAvailable: true)
        }
        let devices = [device("iPad Pro 13-inch (M5)"), device("iPhone 17"), device("iPhone 17 Pro"), device("iPhone SE (3rd generation)"),
                       device("iPhone 17 Pro (minirun 2)"), device("iPhone 17 Pro", "com.apple.CoreSimulator.SimRuntime.iOS-18-0"),
                       device("Apple Watch", "com.apple.CoreSimulator.SimRuntime.watchOS-26-0")]
        XCTAssertEqual(SettingsForm.deviceChoices(devices), ["iPhone 17 Pro", "iPhone 17", "iPad Pro 13-inch (M5)"])
        XCTAssertEqual(SettingsForm.automaticDevice(devices), "iPhone 17 Pro")
    }

    func testStaleWorkspaces() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let list = [
            WorkspaceInfo(path: "/w/a/old", name: "a/old", sizeBytes: 1, lastUsed: now.addingTimeInterval(-40 * 86400), busy: false),
            WorkspaceInfo(path: "/w/a/busy", name: "a/busy", sizeBytes: 1, lastUsed: now.addingTimeInterval(-40 * 86400), busy: true),
            WorkspaceInfo(path: "/w/a/new", name: "a/new", sizeBytes: 1, lastUsed: now.addingTimeInterval(-86400), busy: false),
            WorkspaceInfo(path: "/w/a/unknown", name: "a/unknown", sizeBytes: 1, lastUsed: nil, busy: false),
        ]
        XCTAssertEqual(WorkspaceInventory.stale(list, olderThanDays: 30, now: now).map(\.name), ["a/old"])
    }

    func testDiagnosticsLeaveOutSecrets() {
        let config = MiniRunConfig(relayURL: "wss://h/agent", agentToken: "supersecret")
        let worker = WorkerSettings(accountID: "acc", workerURL: "https://h", ownerPassword: "pw-secret", apiToken: "cf-secret")
        let status = ServeStatus(version: "0.2.0", pid: 7, startedAt: Date(), relay: .init(state: .connected, host: "h", workerBundle: "abcdef0123456789"))
        let report = Diagnostics.report(appVersion: "0.2.0", os: "macOS 26", status: status, config: config, worker: worker,
                                        checks: [DoctorCheck(id: "xcode", title: "Xcode", ok: true, detail: "Xcode 26")])
        for secret in ["supersecret", "pw-secret", "cf-secret"] { XCTAssertFalse(report.contains(secret), secret) }
        XCTAssertTrue(report.contains("<redacted>"))
        XCTAssertTrue(report.contains("worker bundle: abcdef012345"))
        XCTAssertTrue(report.contains("✓ Xcode: Xcode 26"))
    }
}

final class UpdateCheckTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateCheck.isNewer("v0.3.0", than: "0.2.0"))
        XCTAssertTrue(UpdateCheck.isNewer("0.2.1", than: "0.2"))
        XCTAssertTrue(UpdateCheck.isNewer("v1.0.0", than: "0.10.0"))
        XCTAssertFalse(UpdateCheck.isNewer("v0.2.0", than: "0.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer("v0.1.9", than: "0.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer("v0.3.0-beta.1", than: "0.2.0"), "pre-releases don't count")
        XCTAssertFalse(UpdateCheck.isNewer("nightly", than: "0.2.0"))
    }

    func testAsksGitHub() async throws {
        let fake = FakeCloudflare()
        fake.on("GET /repos/devenjarvis/minirun/releases/latest") { _ in
            (200, ["tag_name": "v9.0.0", "html_url": "https://github.com/devenjarvis/minirun/releases/tag/v9.0.0"])
        }
        let release = try await UpdateCheck.newer(than: "0.2.0", transport: fake)
        XCTAssertEqual(release, UpdateCheck.Release(version: "9.0.0", url: "https://github.com/devenjarvis/minirun/releases/tag/v9.0.0"))
        let none = try await UpdateCheck.newer(than: "9.0.0", transport: fake)
        XCTAssertNil(none)
        let noReleases = try await UpdateCheck.newer(than: "0.2.0", repository: "someone/else", transport: fake)
        XCTAssertNil(noReleases, "404: no releases yet")
    }

    func testAppVersionMatchesMiniRunVersion() throws {
        // Walk up from this file to the checkout's App/project.yml.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(contentsOf: root.appendingPathComponent("App/project.yml"), encoding: .utf8)
        XCTAssertTrue(project.contains("MARKETING_VERSION: \"\(MiniRun.version)\""), "App/project.yml's MARKETING_VERSION must be \(MiniRun.version)")
        // mac_status compares it with the version the Mac reports.
        let worker = try String(contentsOf: root.appendingPathComponent("worker/src/version.ts"), encoding: .utf8)
        XCTAssertTrue(worker.contains("export const VERSION = \"\(MiniRun.version)\";"), "worker/src/version.ts's VERSION must be \(MiniRun.version)")
    }
}

final class NotificationRulesTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func status(_ state: ServeStatus.Relay.State, since: TimeInterval, jobs: [ServeStatus.Job] = []) -> ServeStatus {
        ServeStatus(version: "0.2.0", pid: 1, startedAt: now.addingTimeInterval(-9999), relay: .init(state: state, host: "h", since: now.addingTimeInterval(-since)), jobs: jobs)
    }

    func testOutageOncePerOutage() {
        var rules = NotificationRules()
        XCTAssertTrue(rules.notifications(for: status(.disconnected, since: 60), now: now).isEmpty, "not for a short blip")
        let down = rules.notifications(for: status(.disconnected, since: 301), now: now)
        XCTAssertEqual(down.map(\.id), ["relay-down"])
        XCTAssertTrue(rules.notifications(for: status(.disconnected, since: 900), now: now).isEmpty, "once per outage")
        XCTAssertTrue(rules.notifications(for: status(.connected, since: 10), now: now).isEmpty)
        XCTAssertEqual(rules.notifications(for: status(.disconnected, since: 400), now: now).map(\.id), ["relay-down"], "a new outage notifies again")
        XCTAssertTrue(rules.notifications(for: nil, now: now).isEmpty)
    }

    func testFailedJobsAfterTheFirstPoll() {
        var rules = NotificationRules()
        let old = ServeStatus.Job(id: "job_1", title: "build old", status: "failed", startedAt: now, finishedAt: now)
        XCTAssertTrue(rules.notifications(for: status(.connected, since: 1, jobs: [old]), now: now).isEmpty, "old failures aren't replayed")
        let running = ServeStatus.Job(id: "job_2", title: "build you/app", status: "running", startedAt: now)
        XCTAssertTrue(rules.notifications(for: status(.connected, since: 1, jobs: [running, old]), now: now).isEmpty)
        var failed = running
        failed.status = "failed"
        failed.finishedAt = now
        let ok = ServeStatus.Job(id: "job_3", title: "tests", status: "succeeded", startedAt: now, finishedAt: now)
        let posted = rules.notifications(for: status(.connected, since: 1, jobs: [ok, failed, old]), now: now)
        XCTAssertEqual(posted, [AppNotification(id: "job-job_2", title: "Job failed", body: "build you/app")])
        XCTAssertTrue(rules.notifications(for: status(.connected, since: 1, jobs: [ok, failed, old]), now: now).isEmpty)
    }

    func testMenuModelPostsNotifications() async {
        final class Posted: @unchecked Sendable {
            let lock = NSLock()
            var ids: [String] = []
        }
        let posted = Posted()
        let now = self.now
        let replies = [status(.connected, since: 1), status(.disconnected, since: 600)]
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        let model = MenuModel(environment: .init(
            send: { _ in
                defer { counter.value += 1 }
                return ControlProtocol.Response(ok: true, status: replies[min(counter.value, replies.count - 1)])
            },
            connectorURL: { nil }, logTail: { nil }, agentInstalled: { true }, kickstart: { _ in },
            notify: { note in posted.lock.withLock { posted.ids.append(note.id) } },
            now: { now }
        ))
        await model.refresh()
        await model.refresh()
        XCTAssertEqual(posted.lock.withLock { posted.ids }, ["relay-down"])
        let snapshot = await model.snapshot
        XCTAssertEqual(snapshot.relay?.state, .disconnected)
    }
}

final class SetupTests: XCTestCase {
    func testNeeded() {
        XCTAssertTrue(Setup.needed(MiniRunConfig()))
        XCTAssertTrue(Setup.needed(MiniRunConfig(relayURL: "wss://h/agent")))
        XCTAssertFalse(Setup.needed(MiniRunConfig(relayURL: "wss://h/agent", agentToken: "t")))
    }

    func testChecklist() {
        var list = Setup.Checklist()
        list.advance("Checking the API token")
        list.advance("Uploading the Worker")
        XCTAssertEqual(list.rows.map(\.state), [.done, .running])
        list.fail("no permission")
        XCTAssertEqual(list.rows.last?.state, .failed("no permission"))

        var ok = Setup.Checklist()
        ok.advance("a")
        ok.advance("a")
        ok.finish()
        XCTAssertEqual(ok.rows, [.init(title: "a", state: .done)])
    }

    func testClaudeConnected() {
        let opened = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(Setup.claudeConnected(nil, since: opened))
        XCTAssertFalse(Setup.claudeConnected(.init(state: .connected, lastCallAt: opened.addingTimeInterval(-5)), since: opened), "a call from before doesn't count")
        XCTAssertTrue(Setup.claudeConnected(.init(state: .connected, lastCallAt: opened.addingTimeInterval(5)), since: opened))
    }

    func testWorkerOutdated() {
        func snapshot(_ relay: ServeStatus.Relay) -> MenuSnapshot {
            let status = ServeStatus(version: "0.2.0", pid: 1, startedAt: Date(), relay: relay)
            return MenuSnapshot.make(.answered(ControlProtocol.Response(ok: true, status: status)), connectorURL: nil, logTail: nil, canStart: true, now: Date())
        }
        XCTAssertTrue(snapshot(.init(state: .connected, workerBundle: "old")).workerOutdated(bundled: "new"))
        XCTAssertFalse(snapshot(.init(state: .connected, workerBundle: "new")).workerOutdated(bundled: "new"))
        XCTAssertFalse(snapshot(.init(state: .connected)).workerOutdated(bundled: "new"), "unknown isn't out of date")
        XCTAssertFalse(snapshot(.init(state: .connected, workerBundle: "old")).workerOutdated(bundled: nil))
    }

    func testWelcomeMessage() {
        XCTAssertEqual(RelayProtocol.decode(#"{"type":"welcome","bundle":"abc"}"#), .welcome(bundle: "abc"))
        XCTAssertEqual(RelayProtocol.decode(#"{"type":"welcome","bundle":null}"#), .welcome(bundle: nil))
    }
}

final class WorkerManagerTests: XCTestCase {
    var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("minirun-manager-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("MINIRUN_CONFIG", directory.appendingPathComponent("config.json").path, 1)
    }

    override func tearDown() {
        unsetenv("MINIRUN_CONFIG")
        try? FileManager.default.removeItem(at: directory)
    }

    func manager(_ fake: FakeCloudflare, reloaded: @escaping @Sendable () -> Void = {}) -> WorkerManager {
        let manifest = CloudflareFixture.manifest
        var manager = WorkerManager(transport: fake, loadBundle: { WorkerBundle(manifest: manifest, code: Data("x".utf8)) },
                                    reloadServe: { reloaded(); return "reloaded" })
        manager.verifyDelays = [0]
        return manager
    }

    func testDeploySavesEverythingAndReportsProgress() async throws {
        let fake = CloudflareFixture.freshAccount()
        fake.on("GET /login") { _ in (200, JSONValue.null) }
        final class Steps: @unchecked Sendable { let lock = NSLock(); var list: [String] = [] }
        let steps = Steps()
        let deployment = try await manager(fake).deploy(apiToken: "cf", options: .init()) { step in steps.lock.withLock { steps.list.append(step) } }
        XCTAssertTrue(deployment.answering)
        XCTAssertEqual(deployment.serveMessage, "reloaded", "a new relay reaches minirun serve")
        XCTAssertEqual(steps.lock.withLock { steps.list }.last, "Checking that the Worker answers")
        XCTAssertEqual(MiniRunConfig.load().relayURL, "wss://minirun.me.workers.dev/agent")
        XCTAssertEqual(WorkerSettings.load().apiToken, "cf")
    }

    func testRotate() async throws {
        try WorkerSettings(accountID: "acc123", scriptName: "minirun", workerURL: "https://minirun.me.workers.dev", ownerPassword: "old", apiToken: "cf").save()
        try MiniRunConfig(relayURL: "wss://minirun.me.workers.dev/agent", agentToken: "old-token").save()
        let fake = FakeCloudflare()
        fake.on("PUT /accounts/acc123/workers/scripts/minirun/secrets", result: ["name": "x"])
        final class Flag: @unchecked Sendable { var reloaded = false }
        let flag = Flag()

        let password = try await manager(fake).rotate(.password)
        XCTAssertEqual(WorkerSettings.load().ownerPassword, password)
        XCTAssertNotEqual(password, "old")
        XCTAssertEqual(fake.requests("PUT /accounts/acc123/workers/scripts/minirun/secrets").last?.json?["name"], "OWNER_PASSWORD")

        let token = try await manager(fake, reloaded: { flag.reloaded = true }).rotate(.agentToken)
        XCTAssertEqual(MiniRunConfig.load().agentToken, token)
        XCTAssertTrue(flag.reloaded, "minirun serve reconnects with the new token")
        XCTAssertEqual(fake.requests("PUT /accounts/acc123/workers/scripts/minirun/secrets").last?.json?["name"], "AGENT_TOKEN")

        try WorkerManager.forgetToken()
        do {
            try await manager(fake).rotate(.password)
            XCTFail("expected an error without a token")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No saved Cloudflare API token"))
        }
    }

    func testStatus() async throws {
        let fake = FakeCloudflare()
        let none = try await manager(fake).status(apiToken: nil)
        XCTAssertNil(none.workerURL)
        XCTAssertEqual(none.deployed, .unknown)
        XCTAssertFalse(none.outOfDate)

        try WorkerSettings(accountID: "acc123", scriptName: "minirun", workerURL: "https://minirun.me.workers.dev", apiToken: "t").save()
        fake.fail("GET /accounts/acc123/workers/scripts/minirun/settings", status: 404, code: 10007, message: "workers.api.error.script_not_found")
        let missing = try await manager(fake).status(apiToken: nil)
        XCTAssertEqual(missing.deployed, .missing)
        XCTAssertTrue(missing.outOfDate)

        fake.on("GET /accounts/acc123/workers/scripts/minirun/settings", result: ["bindings": [["type": "plain_text", "name": "MINIRUN_BUNDLE", "text": "abc123"]]])
        let current = try await manager(fake).status(apiToken: nil)
        XCTAssertEqual(current.deployed, .bundle("abc123"))
        XCTAssertFalse(current.outOfDate)
    }
}

final class UpdaterTests: XCTestCase {
    let release: JSONValue = [
        "tag_name": "v0.3.0", "html_url": "https://github.com/devenjarvis/minirun/releases/tag/v0.3.0",
        "draft": false, "prerelease": false,
        "assets": [
            ["name": "minirun-0.3.0.zip", "browser_download_url": "https://github.com/dl/minirun-0.3.0.zip",
             "digest": "sha256:ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789"],
            ["name": "minirun-0.3.0.zip.sha256", "browser_download_url": "https://github.com/dl/minirun-0.3.0.zip.sha256"],
        ],
    ]

    func testReadsTheZipAndItsDigest() throws {
        let parsed = try XCTUnwrap(UpdateCheck.release(release, newerThan: "0.2.0", repository: "devenjarvis/minirun"))
        XCTAssertEqual(parsed.version, "0.3.0")
        XCTAssertEqual(parsed.asset?.downloadURL, "https://github.com/dl/minirun-0.3.0.zip")
        XCTAssertEqual(parsed.asset?.sha256, "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789")
        XCTAssertEqual(parsed.asset?.checksumURL, "https://github.com/dl/minirun-0.3.0.zip.sha256")

        var draft = release
        if case .object(var fields) = draft { fields["draft"] = true; draft = .object(fields) }
        XCTAssertNil(UpdateCheck.release(draft, newerThan: "0.2.0", repository: "x/y"))
        XCTAssertNil(UpdateCheck.release(release, newerThan: "0.3.0", repository: "x/y"))
    }

    func testDecide() {
        let ready = UpdateCheck.Release(version: "0.3.0", url: "u", asset: .init(name: "z", downloadURL: "d", sha256: nil, checksumURL: nil))
        let now = Date()
        func status(jobs: [ServeStatus.Job] = [], busy: Bool = false) -> ServeStatus {
            ServeStatus(version: "0.2.0", pid: 1, startedAt: now, relay: .init(state: .connected),
                        simulators: [.init(udid: "A", name: "iPhone", runtime: "iOS 26.0", busy: busy)], jobs: jobs)
        }
        XCTAssertEqual(Updater.decide(release: nil, automatic: true, status: nil, appInstalled: true), .nothing)
        XCTAssertEqual(Updater.decide(release: ready, automatic: true, status: status(), appInstalled: true), .install(ready))
        XCTAssertEqual(Updater.decide(release: ready, automatic: true, status: nil, appInstalled: true), .install(ready), "no daemon: nothing to interrupt")
        let running = ServeStatus.Job(id: "j", title: "build", status: "running", startedAt: now)
        XCTAssertEqual(Updater.decide(release: ready, automatic: true, status: status(jobs: [running]), appInstalled: true), .wait("waiting for 1 running job to finish"))
        XCTAssertEqual(Updater.decide(release: ready, automatic: true, status: status(busy: true), appInstalled: true), .wait("waiting until nobody is using a simulator"))
        guard case .manual = Updater.decide(release: ready, automatic: false, status: status(), appInstalled: true) else { return XCTFail("off means manual") }
        guard case .manual = Updater.decide(release: ready, automatic: true, status: status(), appInstalled: false) else { return XCTFail("dev builds don't update") }
        let noZip = UpdateCheck.Release(version: "0.3.0", url: "u")
        guard case .manual = Updater.decide(release: noZip, automatic: true, status: status(), appInstalled: true) else { return XCTFail("needs a zip") }
    }

    func testChecksumAndBundleChecks() {
        let hex = String(repeating: "a1", count: 32)
        XCTAssertEqual(Updater.checksum(fromShasum: "\(hex.uppercased())  minirun-0.3.0.zip\n"), hex)
        XCTAssertNil(Updater.checksum(fromShasum: "not a hash"))

        let good: [String: Any] = ["CFBundleIdentifier": "dev.minirun.menu", "CFBundleShortVersionString": "0.3.0"]
        XCTAssertNil(Updater.problem(infoPlist: good, expectedVersion: "0.3.0", hasHelper: true))
        XCTAssertNotNil(Updater.problem(infoPlist: good, expectedVersion: "0.4.0", hasHelper: true))
        XCTAssertNotNil(Updater.problem(infoPlist: good, expectedVersion: "0.3.0", hasHelper: false))
        XCTAssertNotNil(Updater.problem(infoPlist: ["CFBundleIdentifier": "com.evil"], expectedVersion: "0.3.0", hasHelper: true))

        XCTAssertTrue(Updater.shouldUpdateWorker(automatic: true, outdated: true, hasToken: true))
        XCTAssertFalse(Updater.shouldUpdateWorker(automatic: true, outdated: true, hasToken: false))
        XCTAssertFalse(Updater.shouldUpdateWorker(automatic: false, outdated: true, hasToken: true))
    }
}
