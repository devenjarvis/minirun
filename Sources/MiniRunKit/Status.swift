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

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 90 { return "\(s)s" }
        if s < 5400 { return "\(s / 60)m" }
        if s < 172_800 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d"
    }
}

/// Messages on the control socket: one JSON request line, one JSON response line.
public enum ControlProtocol {
    public struct Request: Codable, Equatable, Sendable {
        /// "status" is the only command so far.
        public var command: String

        public init(command: String) { self.command = command }
    }

    public struct Response: Codable, Equatable, Sendable {
        public var ok: Bool
        public var error: String?
        public var status: ServeStatus?

        public init(ok: Bool, error: String? = nil, status: ServeStatus? = nil) {
            self.ok = ok
            self.error = error
            self.status = status
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

    /// Answers one request line. `status` builds the snapshot; it's only called for "status".
    public static func respond(to line: String, status: @Sendable () async -> ServeStatus) async -> String {
        let request: Request
        do {
            request = try decode(Request.self, from: line)
        } catch {
            return encode(Response.failure("Expected a JSON request like {\"command\":\"status\"}."))
        }
        switch request.command {
        case "status": return encode(Response(ok: true, status: await status()))
        default: return encode(Response.failure("Unknown command \(request.command)."))
        }
    }
}
