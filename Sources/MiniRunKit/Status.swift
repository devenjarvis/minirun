import Foundation

/// What `minirun serve` is doing right now: the relay connection, the booted simulators and the
/// jobs. `minirun status` and the menu bar app read it from the control socket.
public struct ServeStatus: Codable, Equatable, Sendable {
    public struct Relay: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable { case connecting, connected, disconnected }

        public var state: State
        /// The Worker's host, e.g. minirun.you.workers.dev.
        public var host: String?
        /// When `state` last changed.
        public var since: Date
        /// Why the last connection ended, e.g. a rejected agent token.
        public var problem: String?
        /// The live view link for the browser.
        public var viewerURL: String?
        /// The hash of the code the Worker runs (its MINIRUN_BUNDLE), from its reply to hello.
        /// Nil until it replies, and from Workers too old to say.
        public var workerBundle: String?
        /// When Claude last called a tool through the relay (not counting the viewer's input).
        public var lastCallAt: Date?

        public init(state: State, host: String? = nil, since: Date = Date(), problem: String? = nil, viewerURL: String? = nil,
                    workerBundle: String? = nil, lastCallAt: Date? = nil) {
            self.state = state
            self.host = host
            self.since = since
            self.problem = problem
            self.viewerURL = viewerURL
            self.workerBundle = workerBundle
            self.lastCallAt = lastCallAt
        }
    }

    public struct Simulator: Codable, Equatable, Sendable {
        public var udid: String
        public var name: String
        public var runtime: String
        /// Still booting; minirun treats it as booted and reserved for whoever is booting it.
        public var booting: Bool
        /// Who it's reserved for: "owner/app@branch" or a boot_simulator label.
        public var reservedFor: String?
        /// The app minirun last installed or launched there.
        public var bundleID: String?
        /// When minirun last used it. Nil for simulators minirun never touched, which idle
        /// shutdown leaves alone.
        public var lastUsed: Date?
        /// A job is running on it or someone is watching it live.
        public var busy: Bool
        public var viewerURL: String?

        public init(udid: String, name: String, runtime: String, booting: Bool = false, reservedFor: String? = nil,
                    bundleID: String? = nil, lastUsed: Date? = nil, busy: Bool = false, viewerURL: String? = nil) {
            self.udid = udid
            self.name = name
            self.runtime = runtime
            self.booting = booting
            self.reservedFor = reservedFor
            self.bundleID = bundleID
            self.lastUsed = lastUsed
            self.busy = busy
            self.viewerURL = viewerURL
        }
    }

    public struct Job: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var status: String
        public var startedAt: Date
        public var finishedAt: Date?
        public var logPath: String?

        public init(id: String, title: String, status: String, startedAt: Date, finishedAt: Date? = nil, logPath: String? = nil) {
            self.id = id
            self.title = title
            self.status = status
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.logPath = logPath
        }

        public init(_ job: JobStore.Job) {
            self.init(id: job.id, title: job.title, status: job.status.rawValue, startedAt: job.startedAt, finishedAt: job.finishedAt, logPath: job.logPath)
        }
    }

    /// A macOS app minirun launched on this Mac.
    public struct MacApp: Codable, Equatable, Sendable {
        /// The Mac app id, e.g. "mac-3f9a2c": the `device` for tools, and the live view's stream.
        public var id: String
        public var name: String
        public var bundleID: String?
        /// Nil when it isn't running.
        public var pid: Int32?
        public var running: Bool
        /// Who it's for: "owner/app@branch", or the folder for `path`.
        public var reservedFor: String?
        public var lastUsed: Date?
        /// A job is using it or someone is watching it live.
        public var busy: Bool
        public var viewerURL: String?

        public init(id: String, name: String, bundleID: String? = nil, pid: Int32? = nil, running: Bool, reservedFor: String? = nil,
                    lastUsed: Date? = nil, busy: Bool = false, viewerURL: String? = nil) {
            self.id = id
            self.name = name
            self.bundleID = bundleID
            self.pid = pid
            self.running = running
            self.reservedFor = reservedFor
            self.lastUsed = lastUsed
            self.busy = busy
            self.viewerURL = viewerURL
        }

        public init(_ session: MacAppSession, busy: Bool = false, viewerURL: String? = nil) {
            self.init(id: session.id, name: session.name, bundleID: session.bundleID, pid: session.pid, running: session.isRunning,
                      reservedFor: session.label, lastUsed: session.updatedAt, busy: busy, viewerURL: viewerURL)
        }
    }

    public var version: String
    public var pid: Int32
    public var startedAt: Date
    public var relay: Relay
    /// Booted (and booting) simulators.
    public var simulators: [Simulator]
    /// Set when the simulator list couldn't be read, e.g. simctl failed.
    public var simulatorError: String?
    /// Running jobs and the most recent finished ones, newest first.
    public var jobs: [Job]
    /// macOS apps minirun launched, running or not. Empty from daemons older than Mac app support.
    public var macApps: [MacApp]
    /// What macOS lets `minirun serve` do with macOS apps. Nil when unknown (older daemons, or a
    /// daemon that can't read them).
    public var macPermissions: MacPermissionReport?

    public init(version: String, pid: Int32, startedAt: Date, relay: Relay, simulators: [Simulator] = [], simulatorError: String? = nil, jobs: [Job] = [],
                macApps: [MacApp] = [], macPermissions: MacPermissionReport? = nil) {
        self.version = version
        self.pid = pid
        self.startedAt = startedAt
        self.relay = relay
        self.simulators = simulators
        self.simulatorError = simulatorError
        self.jobs = jobs
        self.macApps = macApps
        self.macPermissions = macPermissions
    }

    private enum CodingKeys: String, CodingKey {
        case version, pid, startedAt, relay, simulators, simulatorError, jobs, macApps, macPermissions
    }

    /// Also decodes what older daemons send: they have no `macApps` or `macPermissions`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        pid = try container.decode(Int32.self, forKey: .pid)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        relay = try container.decode(Relay.self, forKey: .relay)
        simulators = try container.decode([Simulator].self, forKey: .simulators)
        simulatorError = try container.decodeIfPresent(String.self, forKey: .simulatorError)
        jobs = try container.decode([Job].self, forKey: .jobs)
        macApps = try container.decodeIfPresent([MacApp].self, forKey: .macApps) ?? []
        macPermissions = try container.decodeIfPresent(MacPermissionReport.self, forKey: .macPermissions)
    }

    /// The text `minirun status` prints.
    public func summary(now: Date = Date()) -> String {
        var lines = ["minirun \(version) serving (pid \(pid), up \(Self.duration(now.timeIntervalSince(startedAt))))"]

        let host = relay.host ?? "the relay"
        switch relay.state {
        case .connected: lines.append("Relay: connected to \(host) for \(Self.duration(now.timeIntervalSince(relay.since)))")
        case .connecting: lines.append("Relay: connecting to \(host)")
        case .disconnected: lines.append("Relay: disconnected from \(host) for \(Self.duration(now.timeIntervalSince(relay.since)))")
        }
        if let problem = relay.problem, relay.state != .connected { lines.append("  \(problem)") }
        if let viewer = relay.viewerURL { lines.append("Live view: \(viewer)") }

        lines.append("")
        if let error = simulatorError {
            lines.append("Simulators: couldn't list them: \(error)")
        } else if simulators.isEmpty {
            lines.append("Simulators: none booted")
        } else {
            lines.append("Simulators:")
            for sim in simulators {
                var parts = [sim.reservedFor.map { "reserved for \($0)" } ?? "not reserved"]
                if sim.booting { parts.insert("booting", at: 0) }
                if sim.busy { parts.append("busy") }
                if let bundle = sim.bundleID { parts.append("last app \(bundle)") }
                if let used = sim.lastUsed { parts.append("used \(SimulatorPicker.ago(used, now: now))") }
                lines.append("  \(sim.name) (\(sim.runtime)) \(sim.udid) — " + parts.joined(separator: ", "))
            }
        }

        if !macApps.isEmpty {
            lines.append("")
            lines.append("Mac apps:")
            for app in macApps {
                var parts = [app.running ? (app.pid.map { "running (pid \($0))" } ?? "running") : "not running"]
                parts.append(app.reservedFor.map { "for \($0)" } ?? "not reserved")
                if app.busy { parts.append("busy") }
                if let used = app.lastUsed { parts.append("used \(SimulatorPicker.ago(used, now: now))") }
                lines.append("  \(app.name) \(app.id)" + (app.bundleID.map { " (\($0))" } ?? "") + " — " + parts.joined(separator: ", "))
            }
        }
        if let missing = macPermissions?.missing, !missing.isEmpty {
            lines.append("")
            lines.append("macOS apps need \(missing.joined(separator: " and ")); run minirun doctor for how. iOS apps don't need them.")
        }

        let running = jobs.filter { $0.status == JobStore.Status.running.rawValue }
        lines.append("")
        if jobs.isEmpty {
            lines.append("Jobs: none yet")
        } else {
            lines.append("Jobs (\(running.count) running):")
            for job in jobs.prefix(10) {
                let elapsed = (job.finishedAt ?? now).timeIntervalSince(job.startedAt)
                let state = job.finishedAt == nil ? "running for \(Self.duration(elapsed))" : "\(job.status) in \(Self.duration(elapsed))"
                lines.append("  \(job.id) \(job.title): \(state)")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 90 { return "\(s)s" }
        if s < 5400 { return "\(s / 60)m" }
        if s < 172_800 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d"
    }
}

/// Messages on the control socket: one JSON request line, one JSON response line.
public enum ControlProtocol {
    /// Goes up when commands are added, so the menu bar app can tell it's talking to an older
    /// daemon. 1 had only `status` and sent no `controlVersion`; 2 added the rest; 3 added the
    /// macOS app commands (request_mac_permissions, quit_mac_app, activate_mac_app).
    public static let version = 3

    public struct Request: Codable, Equatable, Sendable {
        /// One of: status, reload_config, shutdown_simulator, release_simulator, cancel_job,
        /// workspaces, delete_workspace, doctor, request_mac_permissions, quit_mac_app,
        /// activate_mac_app.
        public var command: String
        /// The simulator for shutdown_simulator and release_simulator.
        public var udid: String?
        /// The job for cancel_job, or the Mac app id (mac-…) for quit_mac_app and activate_mac_app.
        public var id: String?
        /// The checkout folder for delete_workspace.
        public var path: String?

        public init(command: String, udid: String? = nil, id: String? = nil, path: String? = nil) {
            self.command = command
            self.udid = udid
            self.id = id
            self.path = path
        }
    }

    public struct Response: Codable, Equatable, Sendable {
        /// The daemon's `ControlProtocol.version`. Nil from a daemon older than version 2.
        public var controlVersion: Int?
        public var ok: Bool
        public var error: String?
        /// What a command did, in a sentence for the user.
        public var message: String?
        public var status: ServeStatus?
        public var reload: ConfigReload?
        public var workspaces: [WorkspaceInfo]?
        public var doctor: [DoctorCheck]?

        public init(ok: Bool, error: String? = nil, message: String? = nil, status: ServeStatus? = nil,
                    reload: ConfigReload? = nil, workspaces: [WorkspaceInfo]? = nil, doctor: [DoctorCheck]? = nil,
                    controlVersion: Int? = ControlProtocol.version) {
            self.controlVersion = controlVersion
            self.ok = ok
            self.error = error
            self.message = message
            self.status = status
            self.reload = reload
            self.workspaces = workspaces
            self.doctor = doctor
        }

        public static func failure(_ message: String) -> Response { Response(ok: false, error: message) }
    }

    public static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding these plain structs can't fail.
        return String(decoding: (try? encoder.encode(value)) ?? Data("{}".utf8), as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(line.utf8))
    }

    /// Answers one request line by calling the matching method on `commands`. A thrown error
    /// becomes `{"ok":false,"error":…}`.
    public static func respond(to line: String, commands: ControlCommands) async -> String {
        let request: Request
        do {
            request = try decode(Request.self, from: line)
        } catch {
            return encode(Response.failure("Expected a JSON request like {\"command\":\"status\"}."))
        }
        func required(_ value: String?, _ name: String) throws -> String {
            guard let value, !value.isEmpty else { throw ToolError("\(request.command) needs \(name).") }
            return value
        }
        do {
            switch request.command {
            case "status":
                return encode(Response(ok: true, status: await commands.status()))
            case "reload_config":
                let reload = try await commands.reloadConfig()
                return encode(Response(ok: true, message: reload.summary, reload: reload))
            case "shutdown_simulator":
                return encode(Response(ok: true, message: try await commands.shutdownSimulator(udid: required(request.udid, "udid"))))
            case "release_simulator":
                return encode(Response(ok: true, message: try await commands.releaseSimulator(udid: required(request.udid, "udid"))))
            case "cancel_job":
                return encode(Response(ok: true, message: try await commands.cancelJob(id: required(request.id, "id"))))
            case "workspaces":
                return encode(Response(ok: true, workspaces: try await commands.workspaces()))
            case "delete_workspace":
                return encode(Response(ok: true, message: try await commands.deleteWorkspace(path: required(request.path, "path"))))
            case "doctor":
                return encode(Response(ok: true, doctor: await commands.doctor()))
            case "request_mac_permissions":
                return encode(Response(ok: true, message: try await commands.requestMacPermissions()))
            case "quit_mac_app":
                return encode(Response(ok: true, message: try await commands.quitMacApp(id: macAppID(required(request.id, "id")))))
            case "activate_mac_app":
                return encode(Response(ok: true, message: try await commands.activateMacApp(id: macAppID(required(request.id, "id")))))
            default:
                return encode(Response.failure("Unknown command \(request.command)."))
            }
        } catch {
            return encode(Response.failure(error.localizedDescription))
        }
    }

    private static func macAppID(_ id: String) throws -> String {
        guard MacAppID.isMacDevice(id), id.lowercased() != "mac" else { throw ToolError("\(id) isn't a Mac app id (they look like mac-3f9a2c).") }
        return id.lowercased()
    }

    /// Sends one request to the running `minirun serve` and decodes the answer. Blocks, so call
    /// it off the main thread. Throws if nothing answers on the socket.
    public static func send(_ request: Request, path: String = MiniRunConfig.controlSocketURL.path, timeout: Int = 10) throws -> Response {
        let line = try ControlSocket.request(path, encode(request), timeout: timeout)
        return try decode(Response.self, from: line)
    }
}

/// What `minirun serve` does for each control command. The daemon implements it; tests fake it.
public protocol ControlCommands: Sendable {
    func status() async -> ServeStatus
    /// Re-reads config.json and applies it.
    func reloadConfig() async throws -> ConfigReload
    /// Shuts the simulator down and drops its reservation. Returns what happened.
    func shutdownSimulator(udid: String) async throws -> String
    /// Drops the simulator's reservation and leaves it booted.
    func releaseSimulator(udid: String) async throws -> String
    func cancelJob(id: String) async throws -> String
    func workspaces() async throws -> [WorkspaceInfo]
    /// Deletes one checkout. Refuses one a job is using.
    func deleteWorkspace(path: String) async throws -> String
    func doctor() async -> [DoctorCheck]
    /// Asks macOS for Screen Recording and Accessibility for `minirun serve` itself, so the prompts
    /// and the System Settings entries name the daemon. Returns what to do next.
    func requestMacPermissions() async throws -> String
    /// Quits a Mac app minirun launched (never anyone else's process).
    func quitMacApp(id: String) async throws -> String
    /// Brings a Mac app minirun launched to the front.
    func activateMacApp(id: String) async throws -> String
}

extension ControlCommands {
    public func requestMacPermissions() async throws -> String { throw ToolError("This minirun serve can't run macOS apps.") }
    public func quitMacApp(id: String) async throws -> String { throw ToolError("This minirun serve can't run macOS apps.") }
    public func activateMacApp(id: String) async throws -> String { throw ToolError("This minirun serve can't run macOS apps.") }
}
