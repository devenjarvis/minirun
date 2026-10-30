import Foundation

/// The menu bar icon's state.
public enum MenuIcon: String, Equatable, Sendable {
    case connected, connecting, problem, notRunning

    /// The SF Symbol the menu bar app draws.
    public var symbolName: String {
        switch self {
        case .connected: return "iphone"
        case .connecting: return "iphone.radiowaves.left.and.right"
        case .problem: return "exclamationmark.triangle"
        case .notRunning: return "iphone.slash"
        }
    }
}

/// Everything the menu shows, worked out from one status poll. Plain values, so the menu bar app
/// only lays them out, and the logic is tested on Linux.
public struct MenuSnapshot: Equatable, Sendable {
    public struct SimulatorRow: Equatable, Sendable, Identifiable {
        public enum Activity: String, Sendable { case booting, busy, idle }

        public var udid: String
        public var name: String
        public var runtime: String
        public var reservedFor: String?
        public var activity: Activity
        /// "used 3 min ago", or nil if minirun never used it.
        public var lastUsed: String?
        public var viewerURL: String?

        public var id: String { udid }

        /// "iOS 26.0 · reserved for you/app@main · used 2 min ago"
        public var subtitle: String {
            [runtime, reservedFor.map { "reserved for \($0)" } ?? "not reserved", lastUsed].compactMap { $0 }.joined(separator: " · ")
        }
    }

    public struct JobRow: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var status: String
        public var isRunning: Bool
        /// "running for 30s" or "failed in 1m".
        public var detail: String
        public var logPath: String?
    }

    /// Something an action just did, or why it failed.
    public struct Notice: Equatable, Sendable {
        public var text: String
        public var isError: Bool

        public init(_ text: String, isError: Bool = false) {
            self.text = text
            self.isError = isError
        }
    }

    public var icon: MenuIcon
    /// Shown as a badge on the icon while jobs run.
    public var runningJobs: Int
    /// "Connected to minirun.you.workers.dev · 3h"
    public var headline: String
    /// Why the relay or the daemon isn't working, and what to do about it.
    public var problem: String?
    public var fix: String?
    public var daemonRunning: Bool
    /// The daemon answers status but predates the other commands (it needs a restart after an update).
    public var daemonOutdated: Bool
    /// The LaunchAgent is installed, so Start and Restart can work.
    public var canStart: Bool
    public var simulators: [SimulatorRow]
    public var simulatorError: String?
    /// Running jobs, then the most recent finished ones.
    public var jobs: [JobRow]
    public var viewerURL: String?
    /// The URL to add as a custom connector in Claude.
    public var connectorURL: String?
    /// The end of minirun's log, shown while the daemon isn't running.
    public var logTail: String?
    public var notice: Notice?

    /// What a status poll found.
    public enum Poll: Equatable, Sendable {
        /// No poll has finished yet.
        case pending
        case answered(ControlProtocol.Response)
        /// Nothing answered on the control socket.
        case notRunning(String)
    }

    public static let maxJobs = 8

    public static func make(_ poll: Poll, connectorURL: String?, logTail: String?, canStart: Bool, now: Date) -> MenuSnapshot {
        var snapshot = MenuSnapshot(
            icon: .connecting, runningJobs: 0, headline: "Checking minirun…", daemonRunning: false, daemonOutdated: false,
            canStart: canStart, simulators: [], jobs: [], connectorURL: connectorURL
        )
        switch poll {
        case .pending:
            return snapshot
        case .notRunning(let reason):
            snapshot.icon = .notRunning
            if canStart {
                snapshot.headline = "minirun isn't running"
                snapshot.problem = "Nothing answers on the control socket (\(reason))."
                snapshot.fix = "Start it below. If it stops again, the log says why."
                snapshot.logTail = logTail
            } else {
                snapshot.headline = "minirun isn't installed"
                snapshot.problem = "There's no LaunchAgent for minirun serve."
                snapshot.fix = "Run ./scripts/install.sh from the minirun repository."
            }
            return snapshot
        case .answered(let response):
            guard response.ok, let status = response.status else {
                snapshot.icon = .problem
                snapshot.headline = "minirun serve answered with an error"
                snapshot.problem = response.error ?? "It sent no status."
                snapshot.daemonRunning = true
                return snapshot
            }
            snapshot.daemonRunning = true
            snapshot.daemonOutdated = (response.controlVersion ?? 1) < ControlProtocol.version
            apply(status, to: &snapshot, now: now)
            return snapshot
        }
    }

    static func apply(_ status: ServeStatus, to snapshot: inout MenuSnapshot, now: Date) {
        let relay = status.relay
        let host = relay.host ?? "the relay"
        switch relay.state {
        case .connected:
            snapshot.icon = .connected
            snapshot.headline = "Connected to \(host) · \(ServeStatus.duration(now.timeIntervalSince(relay.since)))"
        case .connecting:
            snapshot.icon = relay.problem == nil ? .connecting : .problem
            snapshot.headline = "Connecting to \(host)…"
        case .disconnected:
            snapshot.icon = .problem
            snapshot.headline = "Disconnected from \(host) for \(ServeStatus.duration(now.timeIntervalSince(relay.since)))"
        }
        if relay.state != .connected, let problem = relay.problem {
            snapshot.problem = problem
            snapshot.fix = fix(for: problem)
        }
        snapshot.viewerURL = relay.viewerURL
        snapshot.simulatorError = status.simulatorError
        snapshot.simulators = status.simulators.map { sim in
            SimulatorRow(
                udid: sim.udid, name: sim.name, runtime: sim.runtime, reservedFor: sim.reservedFor,
                activity: sim.booting ? .booting : (sim.busy ? .busy : .idle),
                lastUsed: sim.lastUsed.map { "used " + SimulatorPicker.ago($0, now: now) }, viewerURL: sim.viewerURL
            )
        }
        let running = status.jobs.filter { $0.finishedAt == nil }
        let finished = status.jobs.filter { $0.finishedAt != nil }
        snapshot.runningJobs = running.count
        snapshot.jobs = (running + finished).prefix(max(maxJobs, running.count)).map { job in
            let elapsed = ServeStatus.duration((job.finishedAt ?? now).timeIntervalSince(job.startedAt))
            return JobRow(
                id: job.id, title: job.title, status: job.status, isRunning: job.finishedAt == nil,
                detail: job.finishedAt == nil ? "running for \(elapsed)" : "\(job.status) in \(elapsed)", logPath: job.logPath
            )
        }
    }

    /// What to do about a relay problem.
    static func fix(for problem: String) -> String {
        if problem.contains("agent token") {
            return "Run `minirun worker deploy` to give the Mac and the Worker the same token."
        }
        if problem.contains("No relay configured") {
            return "Run `minirun worker deploy` to set up the Worker."
        }
        return "minirun keeps retrying. Check this Mac's internet connection and that the Worker is deployed (`minirun worker status`)."
    }
}

/// Something the user can do from the menu.
public enum MenuAction: Equatable, Sendable {
    case releaseSimulator(String)
    case shutdownSimulator(String)
    case cancelJob(String)
    /// Start the daemon through launchd.
    case start
    /// Restart the daemon through launchd.
    case restart
}

/// Polls `minirun serve` over the control socket and turns the answers into `MenuSnapshot`s:
/// every 2 seconds while the menu is open, every 15 while it's closed. Also carries out the menu's
/// actions. An actor, so the menu bar app hops to the main thread only to show results.
public actor MenuModel {
    /// The outside world, swapped out in tests.
    public struct Environment: Sendable {
        public var send: @Sendable (ControlProtocol.Request) async throws -> ControlProtocol.Response
        public var connectorURL: @Sendable () -> String?
        public var logTail: @Sendable () -> String?
        public var agentInstalled: @Sendable () -> Bool
        public var kickstart: @Sendable (_ restart: Bool) async throws -> Void
        public var now: @Sendable () -> Date
        /// Waits between polls. Throws when the wait is cancelled.
        public var sleep: @Sendable (TimeInterval) async throws -> Void

        public init(send: @escaping @Sendable (ControlProtocol.Request) async throws -> ControlProtocol.Response,
                    connectorURL: @escaping @Sendable () -> String?, logTail: @escaping @Sendable () -> String?,
                    agentInstalled: @escaping @Sendable () -> Bool, kickstart: @escaping @Sendable (Bool) async throws -> Void,
                    now: @escaping @Sendable () -> Date = { Date() },
                    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
            self.send = send
            self.connectorURL = connectorURL
            self.logTail = logTail
            self.agentInstalled = agentInstalled
            self.kickstart = kickstart
            self.now = now
            self.sleep = sleep
        }

        /// The real control socket, settings files and launchd.
        public static func live() -> Environment {
            Environment(
                send: { request in
                    // The socket calls block, so keep them off the shared threads.
                    try await Task.detached { try ControlProtocol.send(request, timeout: 15) }.value
                },
                connectorURL: { MenuModel.connectorURL(worker: WorkerSettings.load(), config: MiniRunConfig.load()) },
                logTail: { LaunchAgent.tail(lines: 15) },
                agentInstalled: { LaunchAgent.isInstalled },
                kickstart: { restart in try await LaunchAgent.kickstart(restart: restart) }
            )
        }
    }

    public static let openInterval: TimeInterval = 2
    public static let closedInterval: TimeInterval = 15

    private let environment: Environment
    private var onChange: (@Sendable (MenuSnapshot) -> Void)?
    private var loop: Task<Void, Never>?
    private var poll: MenuSnapshot.Poll = .pending
    private var notice: MenuSnapshot.Notice?
    public private(set) var menuOpen = false
    public private(set) var snapshot: MenuSnapshot

    public init(environment: Environment) {
        self.environment = environment
        snapshot = MenuSnapshot.make(.pending, connectorURL: nil, logTail: nil, canStart: false, now: environment.now())
    }

    /// How long to wait before the next poll.
    public var interval: TimeInterval { menuOpen ? Self.openInterval : Self.closedInterval }

    /// Calls `onChange` with each new snapshot, starting with the current one.
    public func observe(_ onChange: @escaping @Sendable (MenuSnapshot) -> Void) {
        self.onChange = onChange
        onChange(snapshot)
    }

    /// Starts polling. Calling it again restarts the wait, polling at once.
    public func start() {
        loop?.cancel()
        loop = Task { await self.run() }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Opening the menu polls at once and then every 2 seconds; closing it slows back down.
    public func setMenuOpen(_ open: Bool) {
        guard open != menuOpen else { return }
        menuOpen = open
        if open, loop != nil { start() }
    }

    private func run() async {
        while !Task.isCancelled {
            await refresh()
            do { try await environment.sleep(interval) } catch { return }
        }
    }

    /// Asks the daemon for its status now.
    public func refresh() async {
        do {
            poll = .answered(try await environment.send(ControlProtocol.Request(command: "status")))
        } catch {
            poll = .notRunning(error.localizedDescription)
        }
        publish()
    }

    /// Carries out a menu action, then polls so the menu shows the result.
    public func perform(_ action: MenuAction) async {
        let request: ControlProtocol.Request
        switch action {
        case .releaseSimulator(let udid): request = ControlProtocol.Request(command: "release_simulator", udid: udid)
        case .shutdownSimulator(let udid): request = ControlProtocol.Request(command: "shutdown_simulator", udid: udid)
        case .cancelJob(let id): request = ControlProtocol.Request(command: "cancel_job", id: id)
        case .start, .restart:
            let restart = action == .restart
            do {
                try await environment.kickstart(restart)
                notice = MenuSnapshot.Notice(restart ? "Restarting minirun…" : "Starting minirun…")
            } catch {
                notice = MenuSnapshot.Notice(error.localizedDescription, isError: true)
            }
            await refresh()
            return
        }
        do {
            let response = try await environment.send(request)
            if response.ok {
                notice = MenuSnapshot.Notice(response.message ?? "Done.")
            } else if response.controlVersion == nil {
                notice = MenuSnapshot.Notice("This minirun serve is older than the app and can't do that. Restart it to update.", isError: true)
            } else {
                notice = MenuSnapshot.Notice(response.error ?? "minirun serve couldn't do that.", isError: true)
            }
        } catch {
            notice = MenuSnapshot.Notice("minirun serve isn't answering: \(error.localizedDescription)", isError: true)
        }
        await refresh()
    }

    /// Clears the last action's message.
    public func dismissNotice() {
        notice = nil
        publish()
    }

    private func publish() {
        var next = MenuSnapshot.make(
            poll, connectorURL: environment.connectorURL(),
            logTail: { if case .notRunning = poll { return environment.logTail() } else { return nil } }(),
            canStart: environment.agentInstalled(), now: environment.now()
        )
        next.notice = notice
        guard next != snapshot else { return }
        snapshot = next
        onChange?(next)
    }

    /// The connector URL for Claude: the Worker's /mcp, from worker.json or else the relay URL.
    public static func connectorURL(worker: WorkerSettings, config: MiniRunConfig) -> String? {
        if let url = worker.workerURL, !url.isEmpty {
            return url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/mcp"
        }
        return config.viewerURL(device: nil).map { $0 + "mcp" }
    }
}
