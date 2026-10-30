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

        public init(state: State, host: String? = nil, since: Date = Date(), problem: String? = nil, viewerURL: String? = nil) {
            self.state = state
            self.host = host
            self.since = since
            self.problem = problem
            self.viewerURL = viewerURL
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

    public init(version: String, pid: Int32, startedAt: Date, relay: Relay, simulators: [Simulator] = [], simulatorError: String? = nil, jobs: [Job] = []) {
        self.version = version
        self.pid = pid
        self.startedAt = startedAt
        self.relay = relay
        self.simulators = simulators
        self.simulatorError = simulatorError
        self.jobs = jobs
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
    /// daemon. 1 had only `status` and sent no `controlVersion`; 2 added the rest.
    public static let version = 2

    public struct Request: Codable, Equatable, Sendable {
        /// One of: status, reload_config, shutdown_simulator, release_simulator, cancel_job,
        /// workspaces, delete_workspace, doctor.
        public var command: String
        /// The simulator for shutdown_simulator and release_simulator.
        public var udid: String?
        /// The job for cancel_job.
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
            default:
                return encode(Response.failure("Unknown command \(request.command)."))
            }
        } catch {
            return encode(Response.failure(error.localizedDescription))
        }
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
}
