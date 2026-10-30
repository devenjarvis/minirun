import Foundation

/// The prebuilt Worker (`worker/dist`): its code plus what the upload needs from wrangler.jsonc.
/// `npm run bundle` in worker/ makes it, so deploying needs no node on the Mac.
public struct WorkerBundle: Sendable {
    public struct Manifest: Codable, Equatable, Sendable {
        public struct DurableObject: Codable, Equatable, Sendable {
            public var binding: String
            public var className: String
        }

        public var name: String
        public var mainModule: String
        /// SHA-256 of the code. Deployed as the MINIRUN_BUNDLE variable, so we can tell what's live.
        public var bundleHash: String
        public var compatibilityDate: String
        public var compatibilityFlags: [String]
        public var observability: JSONValue?
        public var durableObjects: [DurableObject]
        public var kvNamespaces: [String]
        /// Durable Object migrations, oldest first, as wrangler.jsonc lists them (each has a `tag`).
        public var migrations: [JSONValue]
    }

    public var manifest: Manifest
    public var code: Data

    public init(manifest: Manifest, code: Data) {
        self.manifest = manifest
        self.code = code
    }

    public init(directory: URL) throws {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            code = try Data(contentsOf: directory.appendingPathComponent(manifest.mainModule))
        } catch {
            throw ToolError("Couldn't read the Worker bundle in \(directory.path): \(error.localizedDescription)")
        }
    }

    /// Finds the bundle: $MINIRUN_WORKER_BUNDLE, next to an installed binary (~/.minirun/worker,
    /// or Resources/worker in the app), or worker/dist in the checkout the binary was built in.
    public static func locate(executable: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> WorkerBundle {
        if let path = environment["MINIRUN_WORKER_BUNDLE"] {
            return try WorkerBundle(directory: URL(fileURLWithPath: path))
        }
        let binDir = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        var candidates = [
            binDir.deletingLastPathComponent().appendingPathComponent("Resources/worker"),
            binDir.deletingLastPathComponent().appendingPathComponent("worker"),
        ]
        var dir = binDir
        while dir.pathComponents.count > 1 {
            candidates.append(dir.appendingPathComponent("worker/dist"))
            dir = dir.deletingLastPathComponent()
        }
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
            return try WorkerBundle(directory: candidate)
        }
        throw ToolError("Couldn't find the Worker bundle (worker/dist). Reinstall with ./scripts/install.sh, or set MINIRUN_WORKER_BUNDLE.")
    }
}

/// What the Mac remembers about its Worker, in `~/.config/minirun/worker.json` (only your user can read it).
/// The agent token lives in config.json, where `minirun serve` reads it.
public struct WorkerSettings: Codable, Equatable, Sendable {
    public var accountID: String?
    public var scriptName: String?
    public var workerURL: String?
    /// You type this to log in to the viewer and to approve Claude's connector.
    public var ownerPassword: String?
    /// Kept so the Worker can be updated and secrets rotated later. `minirun worker forget` deletes it.
    public var apiToken: String?

    public init(accountID: String? = nil, scriptName: String? = nil, workerURL: String? = nil, ownerPassword: String? = nil, apiToken: String? = nil) {
        self.accountID = accountID
        self.scriptName = scriptName
        self.workerURL = workerURL
        self.ownerPassword = ownerPassword
        self.apiToken = apiToken
    }

    public static var url: URL { MiniRunConfig.configURL.deletingLastPathComponent().appendingPathComponent("worker.json") }
    /// Written by the old `worker/setup.sh`.
    public static var legacyURL: URL { MiniRunConfig.configURL.deletingLastPathComponent().appendingPathComponent("worker.env") }

    /// Loads worker.json, filling gaps from a worker.env that setup.sh left behind.
    public static func load() -> WorkerSettings {
        var settings = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(WorkerSettings.self, from: $0) } ?? WorkerSettings()
        if let legacy = try? String(contentsOf: legacyURL, encoding: .utf8) {
            let values = parseEnvFile(legacy)
            settings.ownerPassword = settings.ownerPassword ?? values["OWNER_PASSWORD"]
            settings.workerURL = settings.workerURL ?? values["WORKER_URL"]
        }
        return settings
    }

    public func save() throws {
        let url = WorkerSettings.url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Create it private before the secrets go in.
        _ = FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try encoder.encode(self).write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Reads KEY='value' lines, as setup.sh wrote them.
    static func parseEnvFile(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "'" || first == "\"", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
    }
}

/// Deploys the Worker with the Cloudflare API: what `worker/setup.sh` and wrangler used to do.
/// Every step is safe to repeat, and an existing deployment (made by setup.sh or by an earlier
/// run) is adopted: same KV namespace, same Durable Object, and secrets kept unless asked.
public struct WorkerDeployer: Sendable {
    public static let passwordSecret = "OWNER_PASSWORD"
    public static let tokenSecret = "AGENT_TOKEN"
    public static let bundleVariable = "MINIRUN_BUNDLE"

    public struct Options: Sendable {
        public var accountID: String?
        /// Registers this workers.dev subdomain if the account has none yet.
        public var subdomain: String?
        public var newPassword = false
        public var newToken = false

        public init(accountID: String? = nil, subdomain: String? = nil, newPassword: Bool = false, newToken: Bool = false) {
            self.accountID = accountID
            self.subdomain = subdomain
            self.newPassword = newPassword
            self.newToken = newToken
        }
    }

    public struct Result: Equatable, Sendable {
        public var accountID: String
        public var workerURL: String
        public var ownerPassword: String
        public var agentToken: String
        public var passwordChanged: Bool
        public var tokenChanged: Bool
        /// True when this created the Worker rather than updating it.
        public var created: Bool

        /// The Mac's relay setting, e.g. wss://minirun.you.workers.dev/agent.
        public var relayURL: String { workerURL.replacingOccurrences(of: "https://", with: "wss://") + "/agent" }
    }

    public let api: CloudflareAPI
    public let bundle: WorkerBundle

    public init(api: CloudflareAPI, bundle: WorkerBundle) {
        self.api = api
        self.bundle = bundle
    }

    /// `password` and `token` are the ones the Mac already has; they're kept if the Worker has them too.
    public func deploy(_ options: Options, password: String?, token: String?, progress: @Sendable (String) -> Void = { _ in }) async throws -> Result {
        let script = bundle.manifest.name

        progress("Checking the API token")
        let account = try WorkerDeployer.pickAccount(try await api.accounts(), requested: options.accountID)

        progress("Looking up the workers.dev subdomain")
        var subdomain = try await api.workersSubdomain(account: account.id)
        if subdomain == nil {
            guard let wanted = options.subdomain else {
                throw ToolError("The Cloudflare account \(account.name) has no workers.dev subdomain yet. Pick one (it becomes https://\(script).<name>.workers.dev) and pass it with --subdomain NAME.")
            }
            progress("Registering \(wanted).workers.dev")
            subdomain = try await api.registerSubdomain(account: account.id, wanted)
        }

        let deployed = try await api.scriptBindings(account: account.id, script: script)
        var kvIDs: [String: String] = [:]
        for binding in bundle.manifest.kvNamespaces {
            progress("Setting up the \(binding) KV namespace")
            kvIDs[binding] = try await kvNamespace(binding, account: account.id, deployed: deployed ?? [])
        }

        progress(deployed == nil ? "Uploading the Worker" : "Updating the Worker")
        let tag = try await api.migrationTag(account: account.id, script: script)
        let metadata = try WorkerDeployer.metadata(bundle.manifest, kvIDs: kvIDs, deployedMigrationTag: tag)
        try await api.uploadScript(account: account.id, script: script, metadata: metadata,
                                   modules: [.init(name: bundle.manifest.mainModule, data: bundle.code)])
        try await api.enableWorkersDev(account: account.id, script: script)

        progress("Setting secrets")
        let existing = try await api.secretNames(account: account.id, script: script)
        let plan = WorkerDeployer.planSecrets(existing: existing, password: password, token: token, options: options)
        let finalPassword = plan.password ?? password!
        let finalToken = plan.token ?? token!
        if let value = plan.password { try await api.putSecret(account: account.id, script: script, name: WorkerDeployer.passwordSecret, value: value) }
        if let value = plan.token { try await api.putSecret(account: account.id, script: script, name: WorkerDeployer.tokenSecret, value: value) }

        return Result(
            accountID: account.id, workerURL: "https://\(script).\(subdomain!).workers.dev",
            ownerPassword: finalPassword, agentToken: finalToken,
            passwordChanged: plan.password != nil, tokenChanged: plan.token != nil, created: deployed == nil
        )
    }

    /// The KV namespace to bind: whatever the live Worker already uses, else one named like
    /// wrangler names them ("minirun-OAUTH_KV", "OAUTH_KV"), else a new one.
    func kvNamespace(_ binding: String, account: String, deployed: [JSONValue]) async throws -> String {
        if let current = deployed.first(where: { $0["type"]?.stringValue == "kv_namespace" && $0["name"]?.stringValue == binding }),
           let id = current["namespace_id"]?.stringValue {
            return id
        }
        let title = "\(bundle.manifest.name)-\(binding)"
        if let existing = WorkerDeployer.pickKVNamespace(try await api.kvNamespaces(account: account), binding: binding, title: title) {
            return existing.id
        }
        return try await api.createKVNamespace(account: account, title: title).id
    }

    // MARK: Decisions (pure, so they're tested without Cloudflare)

    static func pickAccount(_ accounts: [CloudflareAPI.Account], requested: String?) throws -> CloudflareAPI.Account {
        let list = accounts.map { "  \($0.id)  \($0.name)" }.joined(separator: "\n")
        if let requested {
            guard let account = accounts.first(where: { $0.id == requested }) else {
                throw ToolError("This API token can't reach the Cloudflare account \(requested). It can reach:\n\(list)")
            }
            return account
        }
        switch accounts.count {
        case 0: throw ToolError("This API token can't see any Cloudflare account. Give it Account Settings: Read on your account.")
        case 1: return accounts[0]
        default: throw ToolError("This API token can reach several Cloudflare accounts. Pick one with --account ID:\n\(list)")
        }
    }

    static func pickKVNamespace(_ namespaces: [CloudflareAPI.KVNamespace], binding: String, title: String) -> CloudflareAPI.KVNamespace? {
        namespaces.first { $0.title == title } ?? namespaces.first { $0.title == binding } ?? namespaces.first { $0.title.hasSuffix("-" + binding) }
    }

    /// Which migrations to send, the way wrangler decides: none if the Worker is on the newest tag,
    /// the ones after its tag, or all of them for a new Worker (or a tag we don't know).
    static func migrations(_ all: [JSONValue], deployedTag: String?) -> JSONValue? {
        guard let newest = all.last?["tag"]?.stringValue else { return nil }
        func steps(_ list: ArraySlice<JSONValue>) -> JSONValue {
            .array(list.map { migration in .object((migration.objectValue ?? [:]).filter { $0.key != "tag" }) })
        }
        guard let deployedTag else { return ["new_tag": .string(newest), "steps": steps(all[...])] }
        guard let index = all.firstIndex(where: { $0["tag"]?.stringValue == deployedTag }) else {
            return ["old_tag": .string(deployedTag), "new_tag": .string(newest), "steps": steps(all[...])]
        }
        if index == all.count - 1 { return nil }
        return ["old_tag": .string(deployedTag), "new_tag": .string(newest), "steps": steps(all[(index + 1)...])]
    }

    /// The upload's metadata part. Secrets are never sent here, and `keep_bindings` keeps the
    /// ones already set; `planSecrets` decides which to (re)set afterwards.
    static func metadata(_ manifest: WorkerBundle.Manifest, kvIDs: [String: String], deployedMigrationTag: String?) throws -> JSONValue {
        var bindings: [JSONValue] = manifest.durableObjects.map {
            ["type": "durable_object_namespace", "name": .string($0.binding), "class_name": .string($0.className)]
        }
        for binding in manifest.kvNamespaces {
            guard let id = kvIDs[binding] else { throw ToolError("No KV namespace for \(binding).") }
            bindings.append(["type": "kv_namespace", "name": .string(binding), "namespace_id": .string(id)])
        }
        bindings.append(["type": "plain_text", "name": .string(bundleVariable), "text": .string(manifest.bundleHash)])

        var metadata: [String: JSONValue] = [
            "main_module": .string(manifest.mainModule),
            "compatibility_date": .string(manifest.compatibilityDate),
            "compatibility_flags": JSONValue(manifest.compatibilityFlags),
            "bindings": .array(bindings),
            "keep_bindings": ["secret_text", "secret_key"],
        ]
        if let observability = manifest.observability, observability != .null { metadata["observability"] = observability }
        if let migrations = migrations(manifest.migrations, deployedTag: deployedMigrationTag) { metadata["migrations"] = migrations }
        return .object(metadata)
    }

    /// New values for the secrets that need setting: asked to rotate, missing on the Worker, or
    /// unknown to this Mac (a Worker secret can't be read back, so it has to be replaced).
    static func planSecrets(existing: Set<String>, password: String?, token: String?, options: Options) -> (password: String?, token: String?) {
        let newPassword = options.newPassword || password?.isEmpty != false || !existing.contains(passwordSecret)
        let newToken = options.newToken || token?.isEmpty != false || !existing.contains(tokenSecret)
        return (newPassword ? generatePassword() : nil, newToken ? generateToken() : nil)
    }

    /// 20 letters and digits: easy to type on a phone.
    public static func generatePassword() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<20).map { _ in alphabet.randomElement(using: &generator)! })
    }

    /// 32 random bytes as hex, like `openssl rand -hex 32`.
    public static func generateToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
}
