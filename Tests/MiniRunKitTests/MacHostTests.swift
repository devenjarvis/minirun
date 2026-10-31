import XCTest
@testable import MiniRunKit

final class MacAppIDTests: XCTestCase {
    func testIdsAreStableAndLookLikeMacDevices() {
        let id = MacAppID.forLabel("you/fetch@main")
        XCTAssertEqual(id, MacAppID.forLabel("you/fetch@main"), "the same label always gets the same id")
        XCTAssertNotEqual(id, MacAppID.forLabel("you/fetch@feature"))
        XCTAssertTrue(id.range(of: #"^mac-[0-9a-f]{6}$"#, options: .regularExpression) != nil, id)
        // Pinned, so ids survive across releases (a changed hash would orphan running apps).
        XCTAssertEqual(MacAppID.forLabel(""), "mac-222325")
        XCTAssertEqual(MacAppID.fnv1a("a"), 0xaf63_dc4c_8601_ec8c)

        let random = MacAppID.random()
        XCTAssertTrue(random.range(of: #"^mac-[0-9a-f]{6}$"#, options: .regularExpression) != nil, random)

        XCTAssertTrue(MacAppID.isMacDevice("mac"))
        XCTAssertTrue(MacAppID.isMacDevice("mac-3f9a2c"))
        XCTAssertTrue(MacAppID.isMacDevice("MAC-3F9A2C"))
        XCTAssertFalse(MacAppID.isMacDevice("mac-"))
        XCTAssertFalse(MacAppID.isMacDevice(nil))
        XCTAssertFalse(MacAppID.isMacDevice("A1B2C3D4-0000-1111-2222-333344445555"))
        XCTAssertFalse(MacAppID.isMacDevice("machine"))
    }
}

final class MacAppStoreTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func session(_ id: String, label: String? = nil, pid: Int32? = 100, used: TimeInterval = 0) -> MacAppSession {
        MacAppSession(id: id, label: label, name: "Fetch", bundleID: "dev.you.Fetch", appPath: "/w/Fetch.app",
                      executablePath: "/w/Fetch.app/Contents/MacOS/Fetch", pid: pid, logPath: "/logs/\(id).log",
                      launchedAt: now.addingTimeInterval(-3600), updatedAt: now.addingTimeInterval(-used))
    }

    func temporaryURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("minirun-mac-\(UUID().uuidString)/mac-apps.json")
    }

    func testPersistsAcrossRestarts() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = MacAppStore(url: url)
        await store.upsert(session("mac-aaaaaa", label: "you/fetch@main", used: 10))
        await store.upsert(session("mac-bbbbbb", label: "you/fetch@feature"))
        await store.markExited("mac-aaaaaa", ifPid: 100)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let reopened = MacAppStore(url: url)
        let all = await reopened.all()
        XCTAssertEqual(all.map(\.id), ["mac-bbbbbb", "mac-aaaaaa"], "most recently used first")
        XCTAssertNil(all[1].pid)
        XCTAssertEqual(all[1].label, "you/fetch@main")
        XCTAssertEqual(all[0], session("mac-bbbbbb", label: "you/fetch@feature"))

        await reopened.remove("mac-bbbbbb")
        let left = await MacAppStore(url: url).all().map(\.id)
        XCTAssertEqual(left, ["mac-aaaaaa"])
    }

    func testMissingOrCorruptFileStartsEmpty() async throws {
        let missing = MacAppStore(url: temporaryURL())
        let none = await missing.all()
        XCTAssertTrue(none.isEmpty)

        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        let corrupt = MacAppStore(url: url)
        let empty = await corrupt.all()
        XCTAssertTrue(empty.isEmpty)
        await corrupt.upsert(session("mac-cccccc"))
        let fixed = await MacAppStore(url: url).session("mac-cccccc")
        XCTAssertNotNil(fixed, "the next save replaces the broken file")

        XCTAssertEqual(MacAppStore.defaultURL.lastPathComponent, "mac-apps.json")
        XCTAssertEqual(MacAppStore.defaultURL.deletingLastPathComponent(), MiniRunConfig.configURL.deletingLastPathComponent())
    }

    func testTouchAndCaseInsensitiveIds() async {
        let store = MacAppStore(url: nil)
        await store.upsert(session("MAC-ABCDEF", used: 600))
        await store.touch("mac-abcdef", now: now)
        let touched = await store.session("Mac-AbCdEf")
        XCTAssertEqual(touched?.updatedAt, now)
        await store.touch("mac-000000", now: now)
        let unknown = await store.session("mac-000000")
        XCTAssertNil(unknown, "touch doesn't invent sessions")
    }

    func testReconcileKeepsOnlyOurLivePids() async {
        let store = MacAppStore(url: nil)
        await store.upsert(session("mac-aaaaaa", pid: 100))
        await store.upsert(session("mac-bbbbbb", pid: 200))
        await store.upsert(session("mac-cccccc", pid: nil))
        var asked: [Int32] = []
        // pid 200 is alive but now runs something else.
        await store.reconcile { session in
            let pid = session.pid!, executable = session.executablePath
            asked.append(pid)
            return pid == 100 && executable == "/w/Fetch.app/Contents/MacOS/Fetch"
        }
        XCTAssertEqual(Set(asked), [100, 200], "apps without a pid aren't checked")
        let a = await store.session("mac-aaaaaa")?.pid
        let b = await store.session("mac-bbbbbb")
        XCTAssertEqual(a, 100)
        XCTAssertNil(b?.pid)
        XCTAssertNotNil(b, "the entry stays, marked not running")
    }

    func testMarkExitedOnlyClearsTheGivenPid() async {
        let store = MacAppStore(url: nil)
        await store.upsert(session("mac-aaaaaa", pid: 100))
        // A check that saw the old pid (100) finishes after a relaunch as 200.
        await store.upsert(session("mac-aaaaaa", pid: 200))
        await store.markExited("mac-aaaaaa", ifPid: 100, at: now)
        let relaunched = await store.session("mac-aaaaaa")
        XCTAssertEqual(relaunched?.pid, 200, "a stale pid doesn't clear the new one")
        await store.markExited("mac-aaaaaa", ifPid: 200, at: now)
        let quit = await store.session("mac-aaaaaa")
        XCTAssertNil(quit?.pid)
        XCTAssertEqual(quit?.lastPid, 200, "the last pid is kept for its logs")
        XCTAssertEqual(quit?.exitedAt, now)
    }

    func testProcessesSharingTheFileKeepEachOthersChanges() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // `minirun serve` and a `minirun call`, each with its own copy of the store.
        let serve = MacAppStore(url: url)
        let call = MacAppStore(url: url)
        await serve.upsert(session("mac-aaaaaa", pid: 100))
        let seen = await call.session("mac-aaaaaa")
        XCTAssertEqual(seen?.pid, 100, "a launch by one process is visible to the other")
        await call.upsert(session("mac-bbbbbb", pid: 200))
        await serve.markExited("mac-aaaaaa", ifPid: 100)
        let fromCall = await call.all()
        XCTAssertEqual(Set(fromCall.map(\.id)), ["mac-aaaaaa", "mac-bbbbbb"], "the second writer didn't drop the first one's app")
        XCTAssertNil(fromCall.first { $0.id == "mac-aaaaaa" }?.pid)
        XCTAssertEqual(fromCall.first { $0.id == "mac-bbbbbb" }?.pid, 200)

        // A touch not yet written survives re-reading the file.
        await serve.touch("mac-bbbbbb", now: now)
        await serve.touch("mac-bbbbbb", now: now.addingTimeInterval(5))
        let touched = await serve.session("mac-bbbbbb")
        XCTAssertEqual(touched?.updatedAt, now.addingTimeInterval(5))
    }

    func testDecodesEntriesFromOlderVersions() throws {
        let json = """
        {"mac-aaaaaa": {"id": "mac-aaaaaa", "name": "Fetch", "appPath": "/w/Fetch.app", "executablePath": "/w/Fetch.app/Contents/MacOS/Fetch",
                        "pid": 100, "updatedAt": "2033-05-18T03:33:20Z"}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([String: MacAppSession].self, from: Data(json.utf8))
        XCTAssertEqual(decoded["mac-aaaaaa"]?.pid, 100)
        XCTAssertNil(decoded["mac-aaaaaa"]?.processStart)
        XCTAssertNil(decoded["mac-aaaaaa"]?.exitedAt)

        var withStart = session("mac-bbbbbb")
        withStart.processStart = MacProcessStart(seconds: 1_700_000_000, microseconds: 123_456)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let roundTrip = try decoder.decode(MacAppSession.self, from: encoder.encode(withStart))
        XCTAssertEqual(roundTrip, withStart)
    }

    func testIdForLabelAvoidsCollisions() async {
        let store = MacAppStore(url: nil)
        let id = await store.id(forLabel: "you/fetch@main")
        XCTAssertEqual(id, MacAppID.forLabel("you/fetch@main"))
        await store.upsert(session(id, label: "someone/else@main"))
        let other = await store.id(forLabel: "you/fetch@main")
        XCTAssertNotEqual(other, id)
        XCTAssertEqual(other, MacAppID.forLabel("you/fetch@main#1"))
        await store.upsert(session(other, label: "you/fetch@main"))
        let again = await store.id(forLabel: "you/fetch@main")
        XCTAssertEqual(again, other, "stable once taken")
    }

    func testSessionJSON() {
        let json = session("mac-aaaaaa", label: "you/fetch@main").json
        XCTAssertEqual(json["id"]?.stringValue, "mac-aaaaaa")
        XCTAssertEqual(json["reserved_for"]?.stringValue, "you/fetch@main")
        XCTAssertEqual(json["bundle_id"]?.stringValue, "dev.you.Fetch")
        XCTAssertEqual(json["pid"]?.stringValue, "100")
        XCTAssertEqual(json["running"], .bool(true))
        XCTAssertEqual(json["last_used"]?.stringValue, "2033-05-18T03:33:20Z")
        let stopped = session("mac-bbbbbb", pid: nil).json
        XCTAssertEqual(stopped["running"], .bool(false))
        XCTAssertNil(stopped["pid"])
        XCTAssertNil(stopped["reserved_for"])
    }

    func testIdlePlan() {
        let sessions = [
            session("mac-old", used: 3600),
            session("mac-older", used: 7200),
            session("mac-busy", used: 7200),
            session("mac-fresh", used: 60),
            session("mac-quit", pid: nil, used: 7200),
        ]
        XCTAssertEqual(IdleMacApps.plan(sessions, busy: ["mac-busy"], idleAfter: 1800, now: now), ["mac-older", "mac-old"])
        XCTAssertEqual(IdleMacApps.plan(sessions, busy: [], idleAfter: 3600, now: now), ["mac-busy", "mac-older", "mac-old"])
        XCTAssertEqual(IdleMacApps.plan(sessions, busy: [], idleAfter: 0, now: now), [], "0 turns it off")
    }
}

final class MacDoctorTests: XCTestCase {
    func doctor(_ report: MacPermissionReport?) -> Doctor {
        Doctor(run: { _, _, _ in nil }, loadFrameworks: { nil }, macPermissions: { report })
    }

    func testMacChecksAreOptionalWarningsWithFixes() async {
        let report = MacPermissionReport(screenRecording: false, accessibility: false, hasDisplay: false,
                                         binaryPath: "/Applications/minirun.app/Contents/Helpers/minirun")
        let checks = await doctor(report).checks(config: MiniRunConfig())
        let mac = checks.filter { Doctor.macCheckIDs.contains($0.id) }
        XCTAssertEqual(mac.map(\.id), ["screen-recording", "accessibility", "display"])
        XCTAssertEqual(Array(checks.suffix(3)), mac, "after the iOS checks")
        for check in mac {
            XCTAssertFalse(check.ok)
            XCTAssertTrue(check.optional, "\(check.id) mustn't fail the iOS loop")
            XCTAssertTrue(check.detail.contains("macOS apps only"), check.detail)
        }
        let screen = mac[0].fix ?? ""
        XCTAssertTrue(screen.contains("System Settings → Privacy & Security → Screen Recording"), screen)
        XCTAssertTrue(screen.contains("/Applications/minirun.app/Contents/Helpers/minirun"), screen)
        XCTAssertTrue(screen.contains("ad-hoc signed"), screen)
        XCTAssertTrue(screen.contains("Request Access"), screen)
        XCTAssertTrue(mac[1].fix?.contains("Privacy & Security → Accessibility") == true)
        XCTAssertTrue(mac[2].fix?.contains("HDMI dummy plug") == true)
        XCTAssertTrue(mac[2].fix?.contains("automatic login") == true)
        XCTAssertTrue(Doctor.format(mac).hasPrefix("- Screen Recording (for macOS apps): not granted"))
    }

    func testGrantedAndSkipped() async {
        let granted = await doctor(MacPermissionReport(screenRecording: true, accessibility: true, hasDisplay: true)).checks(config: MiniRunConfig())
        let mac = granted.filter { Doctor.macCheckIDs.contains($0.id) }
        XCTAssertEqual(mac.count, 3)
        XCTAssertTrue(mac.allSatisfy { $0.ok && $0.fix == nil })

        let unknown = await doctor(nil).checks(config: MiniRunConfig())
        XCTAssertFalse(unknown.contains { Doctor.macCheckIDs.contains($0.id) }, "no report, no checks")
        let skipped = await Doctor(run: { _, _, _ in nil }, loadFrameworks: { nil }).checks(config: MiniRunConfig())
        XCTAssertFalse(skipped.contains { Doctor.macCheckIDs.contains($0.id) })
    }

    func testReportMissingAndSetupRows() {
        let report = MacPermissionReport(screenRecording: true, accessibility: false, hasDisplay: false)
        XCTAssertEqual(report.missing, ["Accessibility", "an active display"])
        XCTAssertFalse(report.allGranted)

        let doctorRows = Doctor.macChecks(MacPermissionReport(screenRecording: true, accessibility: true, hasDisplay: true))
        let other = DoctorCheck(id: "xcode", title: "Xcode", ok: true, detail: "26")
        let fromStatus = Setup.macAppRows(checks: [other] + doctorRows, permissions: report)
        XCTAssertEqual(fromStatus.map(\.ok), [true, false, false], "the latest status wins over an older doctor run")
        XCTAssertEqual(Setup.macAppRows(checks: [other] + doctorRows, permissions: nil), doctorRows)
        XCTAssertTrue(Setup.macAppRows(checks: [other], permissions: nil).isEmpty)
        XCTAssertEqual(Setup.Step.macApps.title, "macOS apps (optional)")
        XCTAssertTrue(SystemSettingsLinks.screenRecording.hasSuffix("?Privacy_ScreenCapture"))
        XCTAssertTrue(SystemSettingsLinks.accessibility.hasSuffix("?Privacy_Accessibility"))
    }
}

final class MacStatusTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func status(apps: [ServeStatus.MacApp], permissions: MacPermissionReport? = nil) -> ServeStatus {
        ServeStatus(version: "0.4.0", pid: 7, startedAt: now.addingTimeInterval(-60), relay: .init(state: .connected, host: "h", since: now),
                    macApps: apps, macPermissions: permissions)
    }

    let apps: [ServeStatus.MacApp] = [
        .init(id: "mac-aaaaaa", name: "Fetch", bundleID: "dev.you.Fetch", pid: 4242, running: true, reservedFor: "you/fetch@main",
              lastUsed: Date(timeIntervalSince1970: 2_000_000_000 - 120), busy: true, viewerURL: "https://h/?device=mac-aaaaaa"),
        .init(id: "mac-bbbbbb", name: "Fetch", running: false, reservedFor: "you/fetch@feature",
              lastUsed: Date(timeIntervalSince1970: 2_000_000_000 - 30)),
    ]

    func testRoundTripsAndDecodesOldDaemons() throws {
        let full = status(apps: apps, permissions: MacPermissionReport(screenRecording: true, accessibility: false, hasDisplay: true, binaryPath: "/x/minirun"))
        XCTAssertEqual(try ControlProtocol.decode(ServeStatus.self, from: ControlProtocol.encode(full)), full)

        // What a daemon from before Mac apps sends.
        let old = #"{"version":"0.3.0","pid":7,"startedAt":"2033-05-18T03:33:20Z","relay":{"state":"connected","since":"2033-05-18T03:33:20Z"},"simulators":[],"jobs":[]}"#
        let decoded = try ControlProtocol.decode(ServeStatus.self, from: old)
        XCTAssertEqual(decoded.macApps, [])
        XCTAssertNil(decoded.macPermissions)
        XCTAssertNil(decoded.media)
        XCTAssertEqual(decoded.version, "0.3.0")
        let response = try ControlProtocol.decode(ControlProtocol.Response.self, from: #"{"ok":true,"controlVersion":2,"status":\#(old)}"#)
        XCTAssertEqual(response.status?.macApps, [])
        // A Mac app from a daemon that predates Mac recordings has no "recording".
        let app = #"{"id":"mac-aaaaaa","name":"Fetch","running":true,"busy":false}"#
        XCTAssertFalse(try ControlProtocol.decode(ServeStatus.MacApp.self, from: app).recording)
        var recording = apps[0]
        recording.recording = true
        XCTAssertEqual(try ControlProtocol.decode(ServeStatus.MacApp.self, from: ControlProtocol.encode(recording)), recording)
    }

    func testSessionToStatus() {
        let session = MacAppSession(id: "mac-aaaaaa", label: "you/fetch@main", name: "Fetch", bundleID: "dev.you.Fetch",
                                    appPath: "/w/Fetch.app", executablePath: "/w/Fetch.app/Contents/MacOS/Fetch", pid: 4242, updatedAt: now)
        let app = ServeStatus.MacApp(session, busy: true, viewerURL: "https://h/?device=mac-aaaaaa")
        XCTAssertEqual(app, .init(id: "mac-aaaaaa", name: "Fetch", bundleID: "dev.you.Fetch", pid: 4242, running: true,
                                  reservedFor: "you/fetch@main", lastUsed: now, busy: true, viewerURL: "https://h/?device=mac-aaaaaa"))
    }

    func testSummaryListsMacApps() {
        let text = status(apps: apps, permissions: MacPermissionReport(screenRecording: false, accessibility: true, hasDisplay: true)).summary(now: now)
        XCTAssertTrue(text.contains("Mac apps:\n  Fetch mac-aaaaaa (dev.you.Fetch) — running (pid 4242), for you/fetch@main, busy, used 2 min ago\n"
                                    + "  Fetch mac-bbbbbb — not running, for you/fetch@feature, used "), text)
        XCTAssertTrue(text.contains("macOS apps need Screen Recording; run minirun doctor for how."), text)

        let plain = status(apps: []).summary(now: now)
        XCTAssertFalse(plain.contains("Mac apps"), "nothing about Mac apps until there are some")
        XCTAssertFalse(plain.contains("macOS apps need"))
    }
}

final class MacControlTests: XCTestCase {
    final class Commands: ControlCommands, @unchecked Sendable {
        let calls = Locked<[String]>([])
        func status() async -> ServeStatus { ServeStatus(version: "0", pid: 1, startedAt: Date(), relay: .init(state: .connected)) }
        func reloadConfig() async throws -> ConfigReload { ConfigReload(applied: [], reconnecting: []) }
        func shutdownSimulator(udid: String) async throws -> String { "" }
        func releaseSimulator(udid: String) async throws -> String { "" }
        func cancelJob(id: String) async throws -> String { "" }
        func workspaces() async throws -> [WorkspaceInfo] { [] }
        func deleteWorkspace(path: String) async throws -> String { "" }
        func listMedia() async throws -> [MediaItem] { [] }
        func deleteMedia(id: String) async throws -> String { "" }
        func deleteAllMedia() async throws -> String { "" }
        func stopRecording(udid: String) async throws -> String { "" }
        func doctor() async -> [DoctorCheck] { [] }
        func requestMacPermissions() async throws -> String { calls.mutate { $0.append("request") }; return "Asked macOS." }
        func quitMacApp(id: String) async throws -> String { calls.mutate { $0.append("quit \(id)") }; return "Quit \(id)." }
        func activateMacApp(id: String) async throws -> String { calls.mutate { $0.append("activate \(id)") }; return "Brought \(id) to the front." }
    }

    func ask(_ commands: ControlCommands, _ request: ControlProtocol.Request) async throws -> ControlProtocol.Response {
        try ControlProtocol.decode(ControlProtocol.Response.self, from: await ControlProtocol.respond(to: ControlProtocol.encode(request), commands: commands))
    }

    func testMacCommands() async throws {
        XCTAssertGreaterThanOrEqual(ControlProtocol.version, 4)
        let commands = Commands()
        let request = try await ask(commands, .init(command: "request_mac_permissions"))
        XCTAssertEqual(request.message, "Asked macOS.")
        let quit = try await ask(commands, .init(command: "quit_mac_app", id: "MAC-AAAAAA"))
        XCTAssertEqual(quit.message, "Quit mac-aaaaaa.")
        let activate = try await ask(commands, .init(command: "activate_mac_app", id: "mac-bbbbbb"))
        XCTAssertTrue(activate.ok)
        XCTAssertEqual(commands.calls.value, ["request", "quit mac-aaaaaa", "activate mac-bbbbbb"])

        let missing = try await ask(commands, .init(command: "quit_mac_app"))
        XCTAssertEqual(missing.error, "quit_mac_app needs id.")
        let simulator = try await ask(commands, .init(command: "quit_mac_app", id: "A1B2-C3D4"))
        XCTAssertEqual(simulator.error, "A1B2-C3D4 isn't a Mac app id (they look like mac-3f9a2c).")
        XCTAssertEqual(commands.calls.value.count, 3, "bad ids never reach the daemon")
    }

    func testDaemonsWithoutMacSupportSaySo() async throws {
        let response = try await ask(FakeControlCommands(status: ServeStatus(version: "0", pid: 1, startedAt: Date(), relay: .init(state: .connected))),
                                     .init(command: "request_mac_permissions"))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "This minirun serve can't run macOS apps.")
    }
}

final class MacMenuTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testRows() {
        let status = ServeStatus(
            version: "0.4.0", pid: 1, startedAt: now, relay: .init(state: .connected, since: now),
            macApps: [
                .init(id: "mac-stopped", name: "Fetch", running: false, reservedFor: "you/fetch@old", lastUsed: now.addingTimeInterval(-10)),
                .init(id: "mac-idle", name: "Fetch", pid: 2, running: true, reservedFor: "you/fetch@feature", lastUsed: now.addingTimeInterval(-600)),
                .init(id: "mac-busy", name: "Edition", bundleID: "dev.you.Edition", pid: 3, running: true, reservedFor: "you/edition@main",
                      lastUsed: now.addingTimeInterval(-120), busy: true, viewerURL: "https://h/?device=mac-busy"),
                .init(id: "mac-anon", name: "TextEdit", pid: 4, running: true),
            ],
            macPermissions: MacPermissionReport(screenRecording: true, accessibility: true, hasDisplay: true)
        )
        let snapshot = MenuSnapshot.make(.answered(ControlProtocol.Response(ok: true, status: status)), connectorURL: nil, logTail: nil, canStart: true, now: now)
        XCTAssertEqual(snapshot.macApps.map(\.id), ["mac-busy", "mac-idle", "mac-anon", "mac-stopped"], "running first, then by last use")
        XCTAssertEqual(snapshot.macApps.map(\.activity), [.busy, .idle, .idle, .notRunning])
        XCTAssertEqual(snapshot.macApps[0].subtitle, "for you/edition@main · used 2 min ago")
        XCTAssertEqual(snapshot.macApps[0].viewerURL, "https://h/?device=mac-busy")
        XCTAssertEqual(snapshot.macApps[2].subtitle, "not reserved")
        XCTAssertFalse(snapshot.macApps[3].isRunning)
        XCTAssertEqual(MenuSnapshot.MacAppRow.Activity.notRunning.rawValue, "not running")
        XCTAssertEqual(snapshot.macPermissions?.allGranted, true)
        XCTAssertFalse(snapshot.recording)

        var recording = status
        recording.macApps[1].recording = true
        let shown = MenuSnapshot.make(.answered(ControlProtocol.Response(ok: true, status: recording)), connectorURL: nil, logTail: nil, canStart: true, now: now)
        XCTAssertTrue(shown.recording, "a Mac app recording shows in the menu bar icon")
        XCTAssertEqual(shown.macApps.filter(\.recording).map(\.id), ["mac-idle"])
    }

    func testActions() async {
        let daemon = MenuModelTests.FakeDaemon()
        let seen = Locked<[ControlProtocol.Request]>([])
        daemon.respond = { request in
            seen.mutate { $0.append(request) }
            switch request.command {
            case "status": return ControlProtocol.Response(ok: true, status: ServeStatus(version: "0", pid: 1, startedAt: Date(), relay: .init(state: .connected)))
            case "quit_mac_app": return .failure("mac-aaaaaa isn't running.")
            default: return ControlProtocol.Response(ok: true, message: "Did \(request.command).")
            }
        }
        let model = MenuModel(environment: daemon.environment())
        await model.perform(.activateMacApp("mac-aaaaaa"))
        var snapshot = await model.snapshot
        XCTAssertEqual(snapshot.notice, .init("Did activate_mac_app."))
        await model.perform(.quitMacApp("mac-aaaaaa"))
        snapshot = await model.snapshot
        XCTAssertEqual(snapshot.notice, .init("mac-aaaaaa isn't running.", isError: true))
        await model.perform(.requestMacPermissions)
        let sent = seen.value.filter { $0.command != "status" }
        XCTAssertEqual(sent, [
            .init(command: "activate_mac_app", id: "mac-aaaaaa"),
            .init(command: "quit_mac_app", id: "mac-aaaaaa"),
            .init(command: "request_mac_permissions"),
        ])

        // A daemon from before Mac apps answers with its version but doesn't know the command.
        daemon.respond = { _ in ControlProtocol.Response(ok: false, error: "Unknown command quit_mac_app.", controlVersion: 3) }
        await model.perform(.quitMacApp("mac-aaaaaa"))
        snapshot = await model.snapshot
        XCTAssertTrue(snapshot.notice?.text.contains("older than the app") == true, snapshot.notice?.text ?? "")
    }
}
