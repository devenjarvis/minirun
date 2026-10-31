import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MiniRunKit

/// A stand-in for api.cloudflare.com: answers "METHOD /path" from a table and records every request.
final class FakeCloudflare: HTTPTransport, @unchecked Sendable {
    struct Sent {
        var method: String
        var path: String
        var query: String?
        var contentType: String?
        var body: Data
        var json: JSONValue? { try? JSONValue.parse(body) }
    }

    private let lock = NSLock()
    private var routes: [String: (Sent) -> (Int, JSONValue)] = [:]
    private(set) var sent: [Sent] = []

    func on(_ route: String, status: Int = 200, result: JSONValue = .null) {
        on(route) { _ in (status, ["success": .bool((200..<300).contains(status)), "errors": [], "result": result]) }
    }

    func fail(_ route: String, status: Int, code: Int, message: String) {
        on(route) { _ in (status, ["success": false, "errors": [["code": .number(Double(code)), "message": .string(message)]], "result": nil]) }
    }

    func on(_ route: String, _ handler: @escaping (Sent) -> (Int, JSONValue)) {
        lock.lock()
        routes[route] = handler
        lock.unlock()
    }

    func requests(_ route: String) -> [Sent] {
        lock.lock()
        defer { lock.unlock() }
        return sent.filter { "\($0.method) \($0.path)" == route }
    }

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let url = request.url!
        let path = url.path.replacingOccurrences(of: "/client/v4", with: "")
        let entry = Sent(method: request.httpMethod ?? "GET", path: path, query: url.query,
                         contentType: request.value(forHTTPHeaderField: "Content-Type"), body: request.httpBody ?? Data())
        let handler = lock.withLock {
            sent.append(entry)
            return routes["\(entry.method) \(path)"]
        }
        guard let handler else {
            let missing: JSONValue = ["success": false, "errors": [["code": 7003, "message": .string("No route for \(entry.method) \(path)")]]]
            return (404, missing.encoded())
        }
        let (status, body) = handler(entry)
        return (status, body.encoded())
    }
}

/// A Cloudflare account with a workers.dev subdomain and nothing deployed yet.
enum CloudflareFixture {
    static let account = "acc123"
    static let manifest = WorkerBundle.Manifest(
        name: "minirun", mainModule: "index.js", bundleHash: "abc123",
        compatibilityDate: "2026-10-01", compatibilityFlags: ["nodejs_compat"], observability: ["enabled": true],
        durableObjects: [.init(binding: "MAC_RELAY", className: "MacRelay")], kvNamespaces: ["OAUTH_KV"],
        migrations: [["tag": "v1", "new_sqlite_classes": ["MacRelay"]]]
    )

    /// Answers the calls every deploy makes.
    static func freshAccount() -> FakeCloudflare {
        let fake = FakeCloudflare()
        fake.on("GET /accounts", result: [["id": .string(account), "name": "Me"]])
        fake.on("GET /accounts/\(account)/workers/subdomain", result: ["subdomain": "me"])
        fake.fail("GET /accounts/\(account)/workers/scripts/minirun/settings", status: 404, code: 10007, message: "workers.api.error.script_not_found")
        fake.on("GET /accounts/\(account)/storage/kv/namespaces", result: [["id": "other", "title": "something-else"]])
        fake.on("POST /accounts/\(account)/storage/kv/namespaces", result: ["id": "kv-new"])
        fake.fail("GET /accounts/\(account)/workers/services/minirun", status: 404, code: 10090, message: "workers.api.error.service_not_found")
        fake.on("PUT /accounts/\(account)/workers/scripts/minirun", result: ["id": "minirun"])
        fake.on("POST /accounts/\(account)/workers/scripts/minirun/subdomain", result: ["enabled": true])
        fake.on("GET /accounts/\(account)/workers/scripts/minirun/secrets", result: [])
        fake.on("PUT /accounts/\(account)/workers/scripts/minirun/secrets", result: nil)
        return fake
    }
}

final class WorkerDeployTests: XCTestCase {
    let account = CloudflareFixture.account
    let manifest = CloudflareFixture.manifest

    func deployer(_ fake: FakeCloudflare) -> WorkerDeployer {
        WorkerDeployer(api: CloudflareAPI(token: "cf-token", transport: fake), bundle: WorkerBundle(manifest: manifest, code: Data("export default {}".utf8)))
    }

    func freshAccount() -> FakeCloudflare { CloudflareFixture.freshAccount() }

    func testFirstDeployCreatesEverything() async throws {
        let fake = freshAccount()
        let result = try await deployer(fake).deploy(.init(), password: nil, token: nil)

        XCTAssertTrue(result.created)
        XCTAssertEqual(result.workerURL, "https://minirun.me.workers.dev")
        XCTAssertEqual(result.relayURL, "wss://minirun.me.workers.dev/agent")
        XCTAssertEqual(result.ownerPassword.count, 20)
        XCTAssertEqual(result.agentToken.count, 64)
        XCTAssertTrue(result.passwordChanged && result.tokenChanged)

        XCTAssertEqual(fake.requests("POST /accounts/\(account)/storage/kv/namespaces").first?.json, ["title": "minirun-OAUTH_KV"])

        let upload = try XCTUnwrap(fake.requests("PUT /accounts/\(account)/workers/scripts/minirun").first)
        XCTAssertTrue(upload.contentType?.hasPrefix("multipart/form-data; boundary=minirun-") == true)
        let body = String(decoding: upload.body, as: UTF8.self)
        XCTAssertTrue(body.contains("Content-Disposition: form-data; name=\"index.js\"; filename=\"index.js\"\r\nContent-Type: application/javascript+module\r\n\r\nexport default {}\r\n"))
        XCTAssertTrue(body.contains(#""namespace_id":"kv-new""#))
        XCTAssertTrue(body.contains(#""migrations":{"new_tag":"v1","steps":[{"new_sqlite_classes":["MacRelay"]}]}"#))

        XCTAssertEqual(fake.requests("POST /accounts/\(account)/workers/scripts/minirun/subdomain").first?.json, ["enabled": true, "previews_enabled": false])
        let secrets = fake.requests("PUT /accounts/\(account)/workers/scripts/minirun/secrets").compactMap(\.json)
        XCTAssertEqual(secrets.map { $0["name"] }, ["OWNER_PASSWORD", "AGENT_TOKEN"])
        XCTAssertEqual(secrets.first?["text"]?.stringValue, result.ownerPassword)
        XCTAssertEqual(secrets.last?["text"]?.stringValue, result.agentToken)
        XCTAssertEqual(secrets.first?["type"], "secret_text")
        XCTAssertEqual(fake.sent.first?.query, "per_page=50")
    }

    func testRedeployKeepsTheLiveWorkersNamespaceMigrationAndSecrets() async throws {
        let fake = freshAccount()
        fake.on("GET /accounts/\(account)/workers/scripts/minirun/settings", result: ["bindings": [
            ["type": "kv_namespace", "name": "OAUTH_KV", "namespace_id": "kv-live"],
            ["type": "secret_text", "name": "OWNER_PASSWORD"],
        ]])
        fake.on("GET /accounts/\(account)/workers/services/minirun", result: ["default_environment": ["script": ["migration_tag": "v1"]]])
        fake.on("GET /accounts/\(account)/workers/scripts/minirun/secrets", result: [["name": "OWNER_PASSWORD"], ["name": "AGENT_TOKEN"]])

        let result = try await deployer(fake).deploy(.init(), password: "known-password", token: "known-token")
        XCTAssertFalse(result.created)
        XCTAssertEqual(result.ownerPassword, "known-password")
        XCTAssertEqual(result.agentToken, "known-token")
        XCTAssertFalse(result.passwordChanged || result.tokenChanged)
        XCTAssertTrue(fake.requests("PUT /accounts/\(account)/workers/scripts/minirun/secrets").isEmpty)
        XCTAssertTrue(fake.requests("GET /accounts/\(account)/storage/kv/namespaces").isEmpty, "the live binding wins; no search")

        let body = String(decoding: try XCTUnwrap(fake.requests("PUT /accounts/\(account)/workers/scripts/minirun").first).body, as: UTF8.self)
        XCTAssertTrue(body.contains(#""namespace_id":"kv-live""#))
        XCTAssertFalse(body.contains("migrations"), "already on the newest migration")
        XCTAssertTrue(body.contains(#""keep_bindings":["secret_text","secret_key"]"#))
    }

    func testRedeployAddsTheMediaNamespaceNextToTheLiveOne() async throws {
        let fake = freshAccount()
        fake.on("GET /accounts/\(account)/workers/scripts/minirun/settings", result: ["bindings": [
            ["type": "kv_namespace", "name": "OAUTH_KV", "namespace_id": "kv-live"],
        ]])
        fake.on("GET /accounts/\(account)/workers/services/minirun", result: ["default_environment": ["script": ["migration_tag": "v1"]]])
        var twoNamespaces = manifest
        twoNamespaces.kvNamespaces = ["OAUTH_KV", "MEDIA_KV"]
        let deployer = WorkerDeployer(api: CloudflareAPI(token: "cf-token", transport: fake), bundle: WorkerBundle(manifest: twoNamespaces, code: Data("export default {}".utf8)))

        _ = try await deployer.deploy(.init(), password: "known-password", token: "known-token")
        XCTAssertEqual(fake.requests("POST /accounts/\(account)/storage/kv/namespaces").map(\.json), [["title": "minirun-MEDIA_KV"]])

        let metadata = try WorkerDeployer.metadata(twoNamespaces, kvIDs: ["OAUTH_KV": "kv-live", "MEDIA_KV": "kv-new"], deployedMigrationTag: "v1")
        let kv = (metadata["bindings"]?.arrayValue ?? []).filter { $0["type"]?.stringValue == "kv_namespace" }
        XCTAssertEqual(kv, [
            ["type": "kv_namespace", "name": "OAUTH_KV", "namespace_id": "kv-live"],
            ["type": "kv_namespace", "name": "MEDIA_KV", "namespace_id": "kv-new"],
        ])
        let body = String(decoding: try XCTUnwrap(fake.requests("PUT /accounts/\(account)/workers/scripts/minirun").first).body, as: UTF8.self)
        XCTAssertTrue(body.contains(#"{"name":"OAUTH_KV","namespace_id":"kv-live","type":"kv_namespace"}"#), body)
        XCTAssertTrue(body.contains(#"{"name":"MEDIA_KV","namespace_id":"kv-new","type":"kv_namespace"}"#), body)
    }

    func testRotatingTheTokenOnlyReplacesTheToken() async throws {
        let fake = freshAccount()
        fake.on("GET /accounts/\(account)/workers/scripts/minirun/secrets", result: [["name": "OWNER_PASSWORD"], ["name": "AGENT_TOKEN"]])
        let result = try await deployer(fake).deploy(.init(newToken: true), password: "pw", token: "old")
        XCTAssertEqual(result.ownerPassword, "pw")
        XCTAssertNotEqual(result.agentToken, "old")
        XCTAssertEqual(fake.requests("PUT /accounts/\(account)/workers/scripts/minirun/secrets").compactMap { $0.json?["name"] }, ["AGENT_TOKEN"])
    }

    func testMissingSubdomainNeedsAName() async throws {
        let fake = freshAccount()
        fake.fail("GET /accounts/\(account)/workers/subdomain", status: 404, code: 10007, message: "This account doesn't have a workers.dev subdomain")
        do {
            _ = try await deployer(fake).deploy(.init(), password: nil, token: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("--subdomain"), error.localizedDescription)
        }
        XCTAssertTrue(fake.requests("PUT /accounts/\(account)/workers/scripts/minirun").isEmpty)

        fake.on("PUT /accounts/\(account)/workers/subdomain", result: ["subdomain": "mine"])
        let result = try await deployer(fake).deploy(.init(subdomain: "mine"), password: nil, token: nil)
        XCTAssertEqual(fake.requests("PUT /accounts/\(account)/workers/subdomain").first?.json, ["subdomain": "mine"])
        XCTAssertEqual(result.workerURL, "https://minirun.mine.workers.dev")
    }

    func testPermissionErrorsSayWhatTheTokenNeeds() async throws {
        let fake = FakeCloudflare()
        fake.fail("GET /accounts", status: 403, code: 10000, message: "Authentication error")
        do {
            _ = try await deployer(fake).deploy(.init(), password: nil, token: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Workers KV Storage: Edit"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("code 10000"), error.localizedDescription)
        }
    }

    func testAccountChoice() throws {
        let accounts = [CloudflareAPI.Account(id: "a", name: "Personal"), CloudflareAPI.Account(id: "b", name: "Work")]
        XCTAssertThrowsError(try WorkerDeployer.pickAccount(accounts, requested: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("--account"))
            XCTAssertTrue(error.localizedDescription.contains("b  Work"))
        }
        XCTAssertEqual(try WorkerDeployer.pickAccount(accounts, requested: "b").name, "Work")
        XCTAssertThrowsError(try WorkerDeployer.pickAccount(accounts, requested: "c"))
        XCTAssertEqual(try WorkerDeployer.pickAccount(Array(accounts.prefix(1)), requested: nil).id, "a")
        XCTAssertThrowsError(try WorkerDeployer.pickAccount([], requested: nil))
    }

    func testKVNamespaceAdoption() {
        let namespaces = [CloudflareAPI.KVNamespace(id: "1", title: "other-OAUTH_KV"), CloudflareAPI.KVNamespace(id: "2", title: "minirun-OAUTH_KV")]
        XCTAssertEqual(WorkerDeployer.pickKVNamespace(namespaces, binding: "OAUTH_KV", title: "minirun-OAUTH_KV")?.id, "2")
        XCTAssertEqual(WorkerDeployer.pickKVNamespace(Array(namespaces.prefix(1)), binding: "OAUTH_KV", title: "minirun-OAUTH_KV")?.id, "1")
        XCTAssertNil(WorkerDeployer.pickKVNamespace([.init(id: "3", title: "SESSIONS")], binding: "OAUTH_KV", title: "minirun-OAUTH_KV"))
    }

    func testMigrations() {
        let all: [JSONValue] = [["tag": "v1", "new_sqlite_classes": ["A"]], ["tag": "v2", "renamed_classes": [["from": "A", "to": "B"]]]]
        XCTAssertEqual(WorkerDeployer.migrations(all, deployedTag: nil),
                       ["new_tag": "v2", "steps": [["new_sqlite_classes": ["A"]], ["renamed_classes": [["from": "A", "to": "B"]]]]])
        XCTAssertEqual(WorkerDeployer.migrations(all, deployedTag: "v1"),
                       ["old_tag": "v1", "new_tag": "v2", "steps": [["renamed_classes": [["from": "A", "to": "B"]]]]])
        XCTAssertNil(WorkerDeployer.migrations(all, deployedTag: "v2"))
        XCTAssertEqual(WorkerDeployer.migrations(all, deployedTag: "v0")?["old_tag"], "v0")
        XCTAssertNil(WorkerDeployer.migrations([], deployedTag: nil))
    }

    func testSecretPlan() {
        let both: Set<String> = ["OWNER_PASSWORD", "AGENT_TOKEN"]
        var plan = WorkerDeployer.planSecrets(existing: both, password: "p", token: "t", options: .init())
        XCTAssertNil(plan.password)
        XCTAssertNil(plan.token)
        // The Mac lost the password (no worker.env): it can't be read back, so it's replaced.
        plan = WorkerDeployer.planSecrets(existing: both, password: nil, token: "t", options: .init())
        XCTAssertNotNil(plan.password)
        XCTAssertNil(plan.token)
        // The Worker lost the token.
        plan = WorkerDeployer.planSecrets(existing: ["OWNER_PASSWORD"], password: "p", token: "t", options: .init())
        XCTAssertNil(plan.password)
        XCTAssertNotNil(plan.token)
        plan = WorkerDeployer.planSecrets(existing: both, password: "p", token: "t", options: .init(newPassword: true))
        XCTAssertNotNil(plan.password)
        XCTAssertNil(plan.token)
    }

    func testGeneratedSecrets() {
        let password = WorkerDeployer.generatePassword()
        XCTAssertEqual(password.count, 20)
        XCTAssertTrue(password.allSatisfy { $0.isLetter || $0.isNumber })
        XCTAssertNotEqual(password, WorkerDeployer.generatePassword())
        let token = WorkerDeployer.generateToken()
        XCTAssertEqual(token.count, 64)
        XCTAssertTrue(token.allSatisfy(\.isHexDigit))
    }

    func testMultipart() {
        let body = Multipart.encode([
            .init(name: "metadata", contentType: "application/json", data: Data("{}".utf8)),
            .init(name: "a.js", filename: "a.js", contentType: "application/javascript+module", data: Data("x".utf8)),
        ], boundary: "B")
        XCTAssertEqual(String(decoding: body, as: UTF8.self),
                       "--B\r\nContent-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json\r\n\r\n{}\r\n"
                       + "--B\r\nContent-Disposition: form-data; name=\"a.js\"; filename=\"a.js\"\r\nContent-Type: application/javascript+module\r\n\r\nx\r\n--B--\r\n")
    }

    func testLegacyEnvFile() {
        let values = WorkerSettings.parseEnvFile("WORKER_URL='https://minirun.me.workers.dev'\nOWNER_PASSWORD='p4ss'\nAGENT_TOKEN=\"abc\"\n")
        XCTAssertEqual(values, ["WORKER_URL": "https://minirun.me.workers.dev", "OWNER_PASSWORD": "p4ss", "AGENT_TOKEN": "abc"])
    }

    func testLocatesTheCommittedBundle() throws {
        // The test binary lives under .build/, inside the checkout, so the search finds worker/dist.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fakeBinary = root.appendingPathComponent(".build/debug/minirun")
        let bundle = try WorkerBundle.locate(executable: fakeBinary, environment: [:])
        XCTAssertEqual(bundle.manifest.name, "minirun")
        XCTAssertEqual(bundle.manifest.kvNamespaces, ["OAUTH_KV", "MEDIA_KV"])
        XCTAssertEqual(bundle.manifest.durableObjects.first?.className, "MacRelay")
        XCTAssertEqual(bundle.manifest.bundleHash.count, 64)
        XCTAssertFalse(bundle.code.isEmpty)

        XCTAssertThrowsError(try WorkerBundle.locate(executable: URL(fileURLWithPath: "/nowhere/bin/minirun"), environment: [:]))
    }
}

final class WorkerCommandTests: XCTestCase {
    var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("minirun-worker-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("MINIRUN_CONFIG", directory.appendingPathComponent("config.json").path, 1)
    }

    override func tearDown() {
        unsetenv("MINIRUN_CONFIG")
        try? FileManager.default.removeItem(at: directory)
    }

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var text: String { lock.withLock { lines.joined(separator: "\n") } }
    }

    func command(_ fake: FakeCloudflare, lines: Lines, environment: [String: String] = [:], token: String? = nil) -> WorkerCommand {
        let manifest = CloudflareFixture.manifest
        var command = WorkerCommand(
            environment: environment, transport: fake,
            loadBundle: { WorkerBundle(manifest: manifest, code: Data("export default {}".utf8)) },
            output: { lines.append($0) }, readSecret: { _ in token }, restartServe: { "restarted" }
        )
        command.verifyDelays = [0]
        return command
    }

    func testDeployAdoptsSetupShAndSavesSettings() async throws {
        // What worker/setup.sh and `minirun setup` left behind.
        try Data("WORKER_URL='https://minirun.me.workers.dev'\nOWNER_PASSWORD='old-pw'\nAGENT_TOKEN='old-token'\n".utf8)
            .write(to: WorkerSettings.legacyURL)
        try MiniRunConfig(relayURL: "wss://minirun.me.workers.dev/agent", agentToken: "old-token").save()

        let fake = CloudflareFixture.freshAccount()
        fake.on("GET /accounts/acc123/workers/scripts/minirun/secrets", result: [["name": "OWNER_PASSWORD"], ["name": "AGENT_TOKEN"]])
        fake.on("GET /login") { _ in (200, JSONValue.null) }
        let lines = Lines()
        try await command(fake, lines: lines, token: "pasted-token").run(["deploy"])

        let settings = WorkerSettings.load()
        XCTAssertEqual(settings.ownerPassword, "old-pw", "secrets the Mac knows are kept")
        XCTAssertEqual(settings.apiToken, "pasted-token")
        XCTAssertEqual(settings.accountID, "acc123")
        XCTAssertEqual(MiniRunConfig.load().agentToken, "old-token")
        XCTAssertTrue(lines.text.contains("Edit Cloudflare Workers"), "explains how to make a token before asking")
        XCTAssertTrue(lines.text.contains("https://minirun.me.workers.dev is up."))
        XCTAssertTrue(lines.text.contains("Password:          old-pw\n"))
        XCTAssertFalse(lines.text.contains("restarted"), "nothing changed for minirun serve")
        let attributes = try FileManager.default.attributesOfItem(atPath: WorkerSettings.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        // A rotated token reaches config.json, worker.env and minirun serve.
        let again = Lines()
        try await command(fake, lines: again).run(["deploy", "--new-token"])
        let newToken = try XCTUnwrap(MiniRunConfig.load().agentToken)
        XCTAssertNotEqual(newToken, "old-token")
        XCTAssertTrue(try String(contentsOf: WorkerSettings.legacyURL, encoding: .utf8).contains("AGENT_TOKEN='\(newToken)'"))
        XCTAssertTrue(again.text.contains("restarted"))
        XCTAssertFalse(again.text.contains("Edit Cloudflare Workers"), "uses the saved API token")
    }

    func testDeployWithoutATokenExplainsHowToGetOne() async throws {
        do {
            try await command(FakeCloudflare(), lines: Lines(), environment: ["MINIRUN_NO_PROMPT": "1"]).run(["deploy"])
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("MINIRUN_CLOUDFLARE_TOKEN"))
            XCTAssertTrue(error.localizedDescription.contains("dash.cloudflare.com/profile/api-tokens"))
        }
    }

    func testStatusComparesTheDeployedBundle() async throws {
        try WorkerSettings(accountID: "acc123", scriptName: "minirun", workerURL: "https://minirun.me.workers.dev", apiToken: "t").save()
        let fake = FakeCloudflare()
        fake.on("GET /accounts/acc123/workers/scripts/minirun/settings", result: ["bindings": [["type": "plain_text", "name": "MINIRUN_BUNDLE", "text": "0123456789abcdef"]]])
        let lines = Lines()
        try await command(fake, lines: lines).run(["status"])
        XCTAssertTrue(lines.text.contains("Deployed: 0123456789ab"))
        XCTAssertTrue(lines.text.contains("out of date"))

        fake.on("GET /accounts/acc123/workers/scripts/minirun/settings", result: ["bindings": [["type": "plain_text", "name": "MINIRUN_BUNDLE", "text": "abc123"]]])
        let current = Lines()
        try await command(fake, lines: current).run(["status"])
        XCTAssertFalse(current.text.contains("out of date"))
    }
}
