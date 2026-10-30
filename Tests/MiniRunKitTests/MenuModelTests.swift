import XCTest
@testable import MiniRunKit

final class MenuSnapshotTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func status(_ relay: ServeStatus.Relay) -> ServeStatus {
        ServeStatus(
            version: "0.1.0", pid: 42, startedAt: now.addingTimeInterval(-7200), relay: relay,
            simulators: [
                .init(udid: "SIM-A", name: "iPhone 17 Pro", runtime: "iOS 26.0", reservedFor: "you/app@main",
                      lastUsed: now.addingTimeInterval(-120), busy: true, viewerURL: "https://h/?device=SIM-A"),
                .init(udid: "SIM-B", name: "iPhone 17 Pro (minirun 2)", runtime: "iOS 26.0", booting: true),
                .init(udid: "SIM-C", name: "iPhone 17", runtime: "iOS 26.0"),
            ],
            jobs: [
                .init(id: "job_3", title: "tests you/app@main", status: "running", startedAt: now.addingTimeInterval(-30)),
                .init(id: "job_2", title: "build you/app@feature", status: "cancelled", startedAt: now.addingTimeInterval(-200), finishedAt: now.addingTimeInterval(-190)),
                .init(id: "job_1", title: "sync you/app", status: "running", startedAt: now.addingTimeInterval(-400), logPath: "/logs/sync.log"),
            ]
        )
    }

    func make(_ status: ServeStatus, version: Int? = ControlProtocol.version) -> MenuSnapshot {
        var response = ControlProtocol.Response(ok: true, status: status)
        response.controlVersion = version
        return MenuSnapshot.make(.answered(response), connectorURL: "https://h/mcp", logTail: "old log", canStart: true, now: now)
    }

    func testConnected() {
        let snapshot = make(status(.init(state: .connected, host: "minirun.you.workers.dev", since: now.addingTimeInterval(-3 * 3600), viewerURL: "https://h/")))
        XCTAssertEqual(snapshot.icon, .connected)
        XCTAssertEqual(snapshot.headline, "Connected to minirun.you.workers.dev · 3h 0m")
        XCTAssertNil(snapshot.problem)
        XCTAssertNil(snapshot.logTail, "the log is only for when it isn't running")
        XCTAssertTrue(snapshot.daemonRunning)
        XCTAssertFalse(snapshot.daemonOutdated)
        XCTAssertEqual(snapshot.viewerURL, "https://h/")
        XCTAssertEqual(snapshot.connectorURL, "https://h/mcp")

        XCTAssertEqual(snapshot.simulators.map(\.activity), [.busy, .booting, .idle])
        XCTAssertEqual(snapshot.simulators[0].subtitle, "iOS 26.0 · reserved for you/app@main · used 2 min ago")
        XCTAssertEqual(snapshot.simulators[2].subtitle, "iOS 26.0 · not reserved")

        XCTAssertEqual(snapshot.runningJobs, 2)
        XCTAssertEqual(snapshot.jobs.map(\.id), ["job_3", "job_1", "job_2"], "running jobs first")
        XCTAssertEqual(snapshot.jobs.map(\.detail), ["running for 30s", "running for 6m", "cancelled in 10s"])
        XCTAssertEqual(snapshot.jobs[1].logPath, "/logs/sync.log")
    }

    func testRelayProblemsComeWithAFix() {
        let rejected = make(status(.init(state: .disconnected, host: "h", since: now.addingTimeInterval(-45), problem: "The relay rejected the agent token.")))
        XCTAssertEqual(rejected.icon, .problem)
        XCTAssertEqual(rejected.headline, "Disconnected from h for 45s")
        XCTAssertEqual(rejected.problem, "The relay rejected the agent token.")
        XCTAssertTrue(rejected.fix?.contains("minirun worker deploy") == true)

        let first = make(status(.init(state: .connecting, host: "h", since: now)))
        XCTAssertEqual(first.icon, .connecting)
        XCTAssertEqual(first.headline, "Connecting to h…")
        let retrying = make(status(.init(state: .connecting, host: "h", since: now, problem: "Connection lost: offline")))
        XCTAssertEqual(retrying.icon, .problem, "retrying after a failure is a problem, not a first connect")
        XCTAssertTrue(retrying.fix?.contains("keeps retrying") == true)
    }

    func testOlderDaemonAndErrors() {
        let old = make(status(.init(state: .connected, since: now)), version: nil)
        XCTAssertTrue(old.daemonOutdated)
        XCTAssertEqual(old.headline, "Connected to the relay · 0s")

        let failed = MenuSnapshot.make(.answered(.failure("boom")), connectorURL: nil, logTail: nil, canStart: true, now: now)
        XCTAssertEqual(failed.icon, .problem)
        XCTAssertEqual(failed.problem, "boom")
    }

    func testNotRunning() {
        let stopped = MenuSnapshot.make(.notRunning("Connection refused"), connectorURL: nil, logTail: "last words", canStart: true, now: now)
        XCTAssertEqual(stopped.icon, .notRunning)
        XCTAssertEqual(stopped.headline, "minirun isn't running")
        XCTAssertEqual(stopped.logTail, "last words")
        XCTAssertFalse(stopped.daemonRunning)
        XCTAssertTrue(stopped.canStart)

        let missing = MenuSnapshot.make(.notRunning("No such file"), connectorURL: nil, logTail: "x", canStart: false, now: now)
        XCTAssertEqual(missing.headline, "minirun isn't installed")
        XCTAssertTrue(missing.fix?.contains("install.sh") == true)
        XCTAssertEqual(MenuIcon.notRunning.symbolName, "iphone.slash")
    }

    func testJobListIsCappedButKeepsEveryRunningJob() {
        var many = status(.init(state: .connected, since: now))
        many.jobs = (0..<12).map { .init(id: "job_\($0)", title: "t", status: "succeeded", startedAt: now, finishedAt: now) }
        XCTAssertEqual(make(many).jobs.count, MenuSnapshot.maxJobs)
        many.jobs = (0..<10).map { .init(id: "job_\($0)", title: "t", status: "running", startedAt: now) }
        XCTAssertEqual(make(many).jobs.count, 10)
    }

    func testConnectorURL() {
        XCTAssertEqual(MenuModel.connectorURL(worker: WorkerSettings(workerURL: "https://minirun.me.workers.dev/"), config: MiniRunConfig()), "https://minirun.me.workers.dev/mcp")
        XCTAssertEqual(MenuModel.connectorURL(worker: WorkerSettings(), config: MiniRunConfig(relayURL: "wss://minirun.me.workers.dev/agent")), "https://minirun.me.workers.dev/mcp")
        XCTAssertNil(MenuModel.connectorURL(worker: WorkerSettings(), config: MiniRunConfig()))
    }
}

final class MenuModelTests: XCTestCase {
    /// A daemon to poll: answers from `respond`, or refuses when it's nil.
    final class FakeDaemon: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [ControlProtocol.Request] = []
        private var sleeps: [TimeInterval] = []
        var respond: (@Sendable (ControlProtocol.Request) -> ControlProtocol.Response)?
        var kickstarts: [Bool] = []

        var sent: [String] { lock.withLock { requests.map(\.command) } }
        var waits: [TimeInterval] { lock.withLock { sleeps } }

        func environment() -> MenuModel.Environment {
            MenuModel.Environment(
                send: { request in
                    let answer = self.lock.withLock { () -> (@Sendable (ControlProtocol.Request) -> ControlProtocol.Response)? in
                        self.requests.append(request)
                        return self.respond
                    }
                    guard let answer else { throw ToolError("Connection refused") }
                    return answer(request)
                },
                connectorURL: { "https://h/mcp" },
                logTail: { "the log" },
                agentInstalled: { true },
                kickstart: { restart in self.lock.withLock { self.kickstarts.append(restart) } },
                now: { Date(timeIntervalSince1970: 2_000_000_000) },
                sleep: { seconds in
                    self.lock.withLock { self.sleeps.append(seconds) }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
            )
        }
    }

    static let running: @Sendable (ControlProtocol.Request) -> ControlProtocol.Response = { request in
        switch request.command {
        case "status":
            return ControlProtocol.Response(ok: true, status: ServeStatus(
                version: "0.1.0", pid: 1, startedAt: Date(timeIntervalSince1970: 2_000_000_000),
                relay: .init(state: .connected, host: "h", since: Date(timeIntervalSince1970: 2_000_000_000))
            ))
        case "cancel_job": return .failure("job_1 already succeeded.")
        default: return ControlProtocol.Response(ok: true, message: "Did \(request.command) \(request.udid ?? "").")
        }
    }

    func testPollsSlowlyUntilTheMenuOpens() async throws {
        let daemon = FakeDaemon()
        daemon.respond = Self.running
        let model = MenuModel(environment: daemon.environment())
        let seen = Locked<[MenuIcon]>([])
        await model.observe { snapshot in seen.mutate { $0.append(snapshot.icon) } }

        await model.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(daemon.waits.allSatisfy { $0 == MenuModel.closedInterval })
        XCTAssertEqual(seen.value, [.connecting, .connected], "only changes are published")

        let before = daemon.sent.count
        await model.setMenuOpen(true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThan(daemon.sent.count, before, "opening the menu polls at once")
        XCTAssertEqual(daemon.waits.last, MenuModel.openInterval)
        await model.stop()
    }

    func testDaemonGoingAwayAndActions() async throws {
        let daemon = FakeDaemon()
        let model = MenuModel(environment: daemon.environment())
        await model.refresh()
        var snapshot = await model.snapshot
        XCTAssertEqual(snapshot.icon, .notRunning)
        XCTAssertEqual(snapshot.logTail, "the log")

        await model.perform(.start)
        XCTAssertEqual(daemon.kickstarts, [false])
        snapshot = await model.snapshot
        XCTAssertEqual(snapshot.notice, .init("Starting minirun…"))

        daemon.respond = Self.running
        await model.perform(.shutdownSimulator("SIM-A"))
        snapshot = await model.snapshot
        XCTAssertEqual(snapshot.icon, .connected)
        XCTAssertEqual(snapshot.notice, .init("Did shutdown_simulator SIM-A."))

        await model.perform(.cancelJob("job_1"))
        snapshot = await model.snapshot
        XCTAssertEqual(snapshot.notice, .init("job_1 already succeeded.", isError: true))
        XCTAssertEqual(daemon.sent.suffix(4), ["shutdown_simulator", "status", "cancel_job", "status"], "each action is followed by a poll")

        await model.dismissNotice()
        snapshot = await model.snapshot
        XCTAssertNil(snapshot.notice)

        // A daemon from before controlVersion doesn't know the command.
        daemon.respond = { _ in ControlProtocol.Response(ok: false, error: "Unknown command release_simulator.", controlVersion: nil) }
        await model.perform(.releaseSimulator("SIM-A"))
        snapshot = await model.snapshot
        XCTAssertEqual(snapshot.notice?.isError, true)
        XCTAssertTrue(snapshot.notice?.text.contains("older than the app") == true)
    }
}
