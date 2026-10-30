import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends one HTTP request. Tests swap in a fake; the real one is `URLSessionTransport`.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        // The callback form, because the async one isn't in every Linux Foundation.
        try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()))
                }
            }.resume()
        }
    }
}

/// An error the Cloudflare API reported, with its numeric codes.
public struct CloudflareError: Error, LocalizedError, Sendable, Equatable {
    public var status: Int
    public var codes: [Int]
    public var message: String

    /// The script, service or subdomain doesn't exist (yet).
    public var isNotFound: Bool { status == 404 || codes.contains(where: [10007, 10090].contains) }

    public var errorDescription: String? {
        var text = "Cloudflare said: \(message)"
        if !codes.isEmpty { text += " (code \(codes.map(String.init).joined(separator: ", ")))" }
        if status == 401 || status == 403 || codes.contains(where: [9109, 10000].contains) {
            text += ". Check the API token: it needs Account Settings: Read, Workers Scripts: Edit and Workers KV Storage: Edit"
                + " (the \"Edit Cloudflare Workers\" template has them)."
        }
        return text
    }
}

/// The parts of the Cloudflare API that deploying the minirun Worker needs.
/// https://developers.cloudflare.com/api/ — the same calls `wrangler deploy` makes.
public struct CloudflareAPI: Sendable {
    public struct Account: Equatable, Sendable {
        public var id: String
        public var name: String
    }

    public struct KVNamespace: Equatable, Sendable {
        public var id: String
        public var title: String
    }

    public struct Module: Sendable {
        public var name: String
        public var contentType: String
        public var data: Data

        public init(name: String, contentType: String = "application/javascript+module", data: Data) {
            self.name = name
            self.contentType = contentType
            self.data = data
        }
    }

    public let token: String
    public let base: URL
    public let transport: HTTPTransport

    public init(token: String, base: URL = URL(string: "https://api.cloudflare.com/client/v4")!, transport: HTTPTransport = URLSessionTransport()) {
        self.token = token
        self.base = base
        self.transport = transport
    }

    // MARK: Accounts and workers.dev

    public func accounts() async throws -> [Account] {
        let result = try await call("GET", "/accounts", query: ["per_page": "50"])
        return (result.arrayValue ?? []).compactMap { item in
            guard let id = item["id"]?.stringValue else { return nil }
            return Account(id: id, name: item["name"]?.stringValue ?? id)
        }
    }

    /// The account's workers.dev subdomain ("you" in minirun.you.workers.dev), or nil if it has none yet.
    public func workersSubdomain(account: String) async throws -> String? {
        do {
            return try await call("GET", "/accounts/\(account)/workers/subdomain")["subdomain"]?.stringValue
        } catch let error as CloudflareError where error.isNotFound {
            return nil
        }
    }

    public func registerSubdomain(account: String, _ subdomain: String) async throws -> String {
        let result = try await call("PUT", "/accounts/\(account)/workers/subdomain", json: ["subdomain": .string(subdomain)])
        return result["subdomain"]?.stringValue ?? subdomain
    }

    // MARK: KV

    public func kvNamespaces(account: String) async throws -> [KVNamespace] {
        var namespaces: [KVNamespace] = []
        for page in 1... {
            let result = try await call("GET", "/accounts/\(account)/storage/kv/namespaces", query: ["per_page": "100", "page": String(page)])
            let items = result.arrayValue ?? []
            namespaces += items.compactMap { item in
                item["id"]?.stringValue.map { KVNamespace(id: $0, title: item["title"]?.stringValue ?? "") }
            }
            if items.count < 100 { break }
        }
        return namespaces
    }

    public func createKVNamespace(account: String, title: String) async throws -> KVNamespace {
        let result = try await call("POST", "/accounts/\(account)/storage/kv/namespaces", json: ["title": .string(title)])
        guard let id = result["id"]?.stringValue else { throw ToolError("Cloudflare created the KV namespace but didn't say its id.") }
        return KVNamespace(id: id, title: title)
    }

    // MARK: Scripts

    /// The deployed script's bindings (each with `type` and `name`), or nil if there's no such script.
    public func scriptBindings(account: String, script: String) async throws -> [JSONValue]? {
        do {
            return try await call("GET", "/accounts/\(account)/workers/scripts/\(script)/settings")["bindings"]?.arrayValue ?? []
        } catch let error as CloudflareError where error.isNotFound {
            return nil
        }
    }

    /// The tag of the last Durable Object migration applied to the script, if any.
    public func migrationTag(account: String, script: String) async throws -> String? {
        do {
            return try await call("GET", "/accounts/\(account)/workers/services/\(script)")["default_environment"]?["script"]?["migration_tag"]?.stringValue
        } catch let error as CloudflareError where error.isNotFound {
            return nil
        }
    }

    public func uploadScript(account: String, script: String, metadata: JSONValue, modules: [Module]) async throws {
        var parts = [Multipart.Part(name: "metadata", contentType: "application/json", data: metadata.encoded())]
        parts += modules.map { Multipart.Part(name: $0.name, filename: $0.name, contentType: $0.contentType, data: $0.data) }
        let boundary = "minirun-" + UUID().uuidString
        _ = try await call("PUT", "/accounts/\(account)/workers/scripts/\(script)",
                           body: Multipart.encode(parts, boundary: boundary), contentType: "multipart/form-data; boundary=\(boundary)")
    }

    /// Serves the script at <script>.<subdomain>.workers.dev. Preview URLs stay off.
    public func enableWorkersDev(account: String, script: String) async throws {
        _ = try await call("POST", "/accounts/\(account)/workers/scripts/\(script)/subdomain", json: ["enabled": true, "previews_enabled": false])
    }

    public func secretNames(account: String, script: String) async throws -> Set<String> {
        let result = try await call("GET", "/accounts/\(account)/workers/scripts/\(script)/secrets")
        return Set((result.arrayValue ?? []).compactMap { $0["name"]?.stringValue })
    }

    public func putSecret(account: String, script: String, name: String, value: String) async throws {
        _ = try await call("PUT", "/accounts/\(account)/workers/scripts/\(script)/secrets",
                           json: ["name": .string(name), "text": .string(value), "type": "secret_text"])
    }

    // MARK: Requests

    /// Makes one API call and returns its `result`, or throws the API's errors.
    func call(_ method: String, _ path: String, query: [String: String] = [:], json: JSONValue? = nil,
              body: Data? = nil, contentType: String? = nil) async throws -> JSONValue {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("minirun", forHTTPHeaderField: "User-Agent")
        if let json {
            request.httpBody = json.encoded()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        let (status, data) = try await transport.send(request)
        let envelope = try? JSONValue.parse(data)
        if (200..<300).contains(status), envelope?["success"]?.boolValue != false {
            return envelope?["result"] ?? .null
        }
        let errors = envelope?["errors"]?.arrayValue ?? []
        let message = errors.compactMap { $0["message"]?.stringValue }.joined(separator: "; ")
        throw CloudflareError(
            status: status,
            codes: errors.compactMap { $0["code"]?.intValue },
            message: message.isEmpty ? "HTTP \(status) from \(method) \(path)" : message
        )
    }
}

/// multipart/form-data bodies, for script uploads.
public enum Multipart {
    public struct Part: Sendable {
        public var name: String
        public var filename: String?
        public var contentType: String
        public var data: Data

        public init(name: String, filename: String? = nil, contentType: String, data: Data) {
            self.name = name
            self.filename = filename
            self.contentType = contentType
            self.data = data
        }
    }

    public static func encode(_ parts: [Part], boundary: String) -> Data {
        var body = Data()
        for part in parts {
            var disposition = "form-data; name=\"\(part.name)\""
            if let filename = part.filename { disposition += "; filename=\"\(filename)\"" }
            body.append(Data("--\(boundary)\r\nContent-Disposition: \(disposition)\r\nContent-Type: \(part.contentType)\r\n\r\n".utf8))
            body.append(part.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }
}
