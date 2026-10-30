import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Deploys, inspects and rotates the Worker, and keeps this Mac's settings in step: worker.json,
/// config.json, the old worker.env, and the running `minirun serve`. `minirun worker …` and the
/// menu bar app's setup and settings windows both go through here.
public struct WorkerManager: Sendable {
    public var transport: HTTPTransport
    public var loadBundle: @Sendable () throws -> WorkerBundle
    /// Makes `minirun serve` pick up a new relay or token. Says what happened, or nil if it isn't installed.
    public var reloadServe: @Sendable () async -> String?
    /// Waits between checks that the new Worker answers.
    public var verifyDelays: [TimeInterval] = [0, 2, 4, 8, 15, 30]

    public init(transport: HTTPTransport, loadBundle: @escaping @Sendable () throws -> WorkerBundle,
                reloadServe: @escaping @Sendable () async -> String?) {
        self.transport = transport
        self.loadBundle = loadBundle
        self.reloadServe = reloadServe
    }

    /// How to make a Cloudflare API token, for the CLI prompt and the setup window.
    public static let tokenSteps = [
        "Open the Cloudflare dashboard's API Tokens page and choose Create Token.",
        "Use the \"Edit Cloudflare Workers\" template. Under Account Resources pick your account; Zone Resources don't matter to minirun.",
        "Create it and paste it here. It's saved in ~/.config/minirun/worker.json, which only your user can read, so later updates don't ask again.",
    ]
    public static let tokenPage = "https://dash.cloudflare.com/profile/api-tokens"

    // MARK: Deploy

    public struct Deployment: Equatable, Sendable {
        public var result: WorkerDeployer.Result
        public var bundleHash: String
        /// GET /login answered 200.
        public var answering: Bool
        /// What `minirun serve` did about a changed relay or token, if anything.
        public var serveMessage: String?
    }

    /// Deploys or updates the Worker with `apiToken`, saves the settings it ends up with, and
    /// points `minirun serve` at it.
    public func deploy(apiToken: String, options: WorkerDeployer.Options, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Deployment {
        var settings = WorkerSettings.load()
        var config = MiniRunConfig.load()
        let bundle = try loadBundle()
        var options = options
        options.accountID = options.accountID ?? settings.accountID

        let deployer = WorkerDeployer(api: CloudflareAPI(token: apiToken, transport: transport), bundle: bundle)
        let result = try await deployer.deploy(options, password: settings.ownerPassword, token: config.agentToken, progress: progress)

        settings.accountID = result.accountID
        settings.scriptName = bundle.manifest.name
        settings.workerURL = result.workerURL
        settings.ownerPassword = result.ownerPassword
        settings.apiToken = apiToken
        try settings.save()
        try Self.updateLegacyEnvFile(workerURL: result.workerURL, password: result.ownerPassword, token: result.agentToken)

        let relayChanged = config.relayURL != result.relayURL || config.agentToken != result.agentToken
        config.relayURL = result.relayURL
        config.agentToken = result.agentToken
        try config.save()

        progress("Checking that the Worker answers")
        let answering = await answers(URL(string: result.workerURL + "/login")!)
        let serveMessage = relayChanged ? await reloadServe() : nil
        return Deployment(result: result, bundleHash: bundle.manifest.bundleHash, answering: answering, serveMessage: serveMessage)
    }

    // MARK: Status

    public struct Status: Equatable, Sendable {
        public enum Deployed: Equatable, Sendable {
            /// The MINIRUN_BUNDLE the Worker runs, or nil for one deployed with wrangler.
            case bundle(String?)
            /// There's no such Worker on the account.
            case missing
            /// Can't ask Cloudflare: no saved API token or account.
            case unknown
        }

        public var workerURL: String?
        public var accountID: String?
        /// The hash of the Worker this copy of minirun carries, or nil if it can't find it.
        public var bundled: String?
        public var deployed: Deployed

        /// The Worker runs something other than the bundled code.
        public var outOfDate: Bool {
            guard let bundled else { return false }
            switch deployed {
            case .bundle(let hash): return hash != bundled
            case .missing: return true
            case .unknown: return false
            }
        }
    }

    /// What's deployed, asking Cloudflare when there's a token to ask with.
    public func status(apiToken: String?) async throws -> Status {
        let settings = WorkerSettings.load()
        let bundle = try? loadBundle()
        var status = Status(workerURL: settings.workerURL, accountID: settings.accountID, bundled: bundle?.manifest.bundleHash, deployed: .unknown)
        guard settings.workerURL != nil, let token = apiToken ?? settings.apiToken, let account = settings.accountID,
              let script = settings.scriptName ?? bundle?.manifest.name else { return status }
        let bindings = try await CloudflareAPI(token: token, transport: transport).scriptBindings(account: account, script: script)
        status.deployed = bindings.map { .bundle(Self.deployedBundle($0)) } ?? .missing
        return status
    }

    /// The MINIRUN_BUNDLE variable of a deployed Worker: the hash of the code it runs.
    static func deployedBundle(_ bindings: [JSONValue]) -> String? {
        bindings.first { $0["name"]?.stringValue == WorkerDeployer.bundleVariable }?["text"]?.stringValue
    }

    // MARK: Accounts

    /// The accounts the token can reach, for the setup window's picker.
    public func accounts(apiToken: String) async throws -> [CloudflareAPI.Account] {
        try await CloudflareAPI(token: apiToken, transport: transport).accounts()
    }

    /// The account's workers.dev subdomain, or nil if it needs one before the first deploy.
    public func subdomain(apiToken: String, account: String) async throws -> String? {
        try await CloudflareAPI(token: apiToken, transport: transport).workersSubdomain(account: account)
    }

    // MARK: Rotation

    public enum Secret: String, Sendable {
        case password, agentToken
    }

    /// Sets a new owner password or agent token on the Worker and saves it here. A new agent token
    /// reaches `minirun serve` with a reload, so it reconnects with it. Returns the new value.
    @discardableResult
    public func rotate(_ secret: Secret, apiToken: String? = nil) async throws -> String {
        var settings = WorkerSettings.load()
        guard let token = apiToken ?? settings.apiToken else {
            throw ToolError("No saved Cloudflare API token. Deploy the Worker from this Mac first (Update Worker, or `minirun worker deploy`).")
        }
        guard let account = settings.accountID, let workerURL = settings.workerURL else {
            throw ToolError("This Mac doesn't know which Worker to change. Deploy it from here first.")
        }
        let script = settings.scriptName ?? (try? loadBundle())?.manifest.name ?? "minirun"
        let api = CloudflareAPI(token: token, transport: transport)
        var config = MiniRunConfig.load()
        switch secret {
        case .password:
            let value = WorkerDeployer.generatePassword()
            try await api.putSecret(account: account, script: script, name: WorkerDeployer.passwordSecret, value: value)
            settings.ownerPassword = value
            try settings.save()
            try Self.updateLegacyEnvFile(workerURL: workerURL, password: value, token: config.agentToken ?? "")
            return value
        case .agentToken:
            let value = WorkerDeployer.generateToken()
            try await api.putSecret(account: account, script: script, name: WorkerDeployer.tokenSecret, value: value)
            config.agentToken = value
            try config.save()
            try Self.updateLegacyEnvFile(workerURL: workerURL, password: settings.ownerPassword ?? "", token: value)
            _ = await reloadServe()
            return value
        }
    }

    /// Deletes the saved Cloudflare API token. Deploying again asks for one.
    public static func forgetToken() throws {
        var settings = WorkerSettings.load()
        settings.apiToken = nil
        try settings.save()
    }

    // MARK: Helpers

    /// Keeps the old worker.env (which worker/setup.sh reads) in step, if there is one.
    static func updateLegacyEnvFile(workerURL: String, password: String, token: String) throws {
        let url = WorkerSettings.legacyURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let text = "WORKER_URL='\(workerURL)'\nOWNER_PASSWORD='\(password)'\nAGENT_TOKEN='\(token)'\n"
        try Data(text.utf8).write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func answers(_ url: URL) async -> Bool {
        for delay in verifyDelays {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            if let (status, _) = try? await transport.send(request), status == 200 { return true }
        }
        return false
    }
}
