import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A screenshot or recording shared for a PR description: through the Worker, or committed to the
/// repo's media branch on GitHub. Neither keeps an index; this Mac's ledger (`MediaLedger`) is the only list.
public struct MediaItem: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case screenshot, recording }
    /// Where the files live. Ledgers from before GitHub uploads have no host: the Worker.
    public enum Host: String, Codable, Sendable { case worker, github }

    public struct File: Codable, Equatable, Sendable {
        /// jpg, png, gif or mp4: the file is served at /m/<id>.<ext>.
        public var ext: String
        public var bytes: Int

        public init(ext: String, bytes: Int) {
            self.ext = ext
            self.bytes = bytes
        }
    }

    public var id: String
    public var kind: Kind
    public var files: [File]
    public var createdAt: Date
    public var expiresAt: Date
    public var repo: String?
    public var ref: String?
    public var caption: String?
    /// The page to open: /m/<id>.jpg for a screenshot, the player page /m/<id> for a recording,
    /// or the pinned github.com embed for a GitHub upload.
    public var url: String
    /// Nil means the Worker (older ledgers).
    public var host: Host?
    /// GitHub uploads: the media branch, the file's path on it, and the commit the embed is pinned to.
    public var branch: String?
    public var path: String?
    public var commit: String?

    public init(id: String, kind: Kind, files: [File], createdAt: Date, expiresAt: Date,
                repo: String? = nil, ref: String? = nil, caption: String? = nil, url: String,
                host: Host? = nil, branch: String? = nil, path: String? = nil, commit: String? = nil) {
        self.id = id
        self.kind = kind
        self.files = files
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.repo = repo
        self.ref = ref
        self.caption = caption
        self.url = url
        self.host = host
        self.branch = branch
        self.path = path
        self.commit = commit
    }

    public var isOnGitHub: Bool { host == .github }

    /// GitHub uploads never expire; they're recorded as expiring in the far future.
    public static let neverExpires = Date(timeIntervalSince1970: 32_503_680_000) // 3000-01-01

    public var bytes: Int { files.reduce(0) { $0 + $1.bytes } }

    public func isExpired(now: Date) -> Bool { expiresAt <= now }

    /// "owner/app@branch", the same form as simulator reservations. Nil when untagged.
    public var label: String? { repo.map { WorkspaceNaming.label(slug: $0, ref: ref) } }

    /// Splits a reservation label ("owner/app@branch", or any boot_simulator label) into the repo
    /// and ref an upload is tagged with.
    public static func tag(label: String?) -> (repo: String?, ref: String?) {
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return (nil, nil) }
        guard let at = label.firstIndex(of: "@") else { return (label, nil) }
        let ref = String(label[label.index(after: at)...])
        return (String(label[..<at]), ref.isEmpty ? nil : ref)
    }

    /// A new random id: 16 bytes in base64url, 22 characters. Ids come only from here, never from
    /// an agent, so nobody can guess or pick one.
    public static func newID() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func isValidID(_ id: String) -> Bool {
        id.count == 22 && id.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_" }
    }
}

/// How much is shared, for the status snapshot and the menu.
public struct MediaSummary: Codable, Equatable, Sendable {
    public var count: Int
    public var bytes: Int

    public init(count: Int, bytes: Int) {
        self.count = count
        self.bytes = bytes
    }
}

/// The list of shared media at `~/.config/minirun/media.json`. Read from the file on every call
/// and written back atomically, so a one-off `minirun call` and `minirun serve` see each other's
/// uploads. Entries past their expiry are dropped as they're seen: KV has already deleted them.
public actor MediaLedger {
    private let url: URL?
    /// Used when there's no file (tests).
    private var memory: [MediaItem] = []

    public init(url: URL?) {
        self.url = url
    }

    public static var defaultURL: URL {
        MiniRunConfig.configURL.deletingLastPathComponent().appendingPathComponent("media.json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func load() -> [MediaItem] {
        guard let url else { return memory }
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.decoder.decode([MediaItem].self, from: data)) ?? []
    }

    private func store(_ items: [MediaItem]) {
        guard let url else { memory = items; return }
        guard let data = try? Self.encoder.encode(items) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Drops expired entries and returns the rest, oldest first.
    @discardableResult
    public func pruneExpired(now: Date = Date()) -> [MediaItem] {
        let all = load()
        let live = all.filter { !$0.isExpired(now: now) }
        if live.count != all.count { store(live) }
        return live.sorted { $0.createdAt < $1.createdAt }
    }

    /// The live entries, newest first.
    public func list(now: Date = Date()) -> [MediaItem] {
        pruneExpired(now: now).reversed()
    }

    public func item(_ id: String, now: Date = Date()) -> MediaItem? {
        pruneExpired(now: now).first { $0.id == id }
    }

    public func totalBytes(now: Date = Date()) -> Int {
        pruneExpired(now: now).reduce(0) { $0 + $1.bytes }
    }

    public func summary(now: Date = Date()) -> MediaSummary {
        let live = pruneExpired(now: now)
        return MediaSummary(count: live.count, bytes: live.reduce(0) { $0 + $1.bytes })
    }

    public func add(_ item: MediaItem) {
        var items = load().filter { $0.id != item.id }
        items.append(item)
        store(items)
    }

    @discardableResult
    public func remove(_ id: String) -> MediaItem? {
        var items = load()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = items.remove(at: index)
        store(items)
        return removed
    }

    /// What has to go before an upload of `incoming` bytes, to stay within `limit`.
    public struct CapPlan: Equatable, Sendable {
        /// Oldest first.
        public var delete: [MediaItem]
        /// False when the upload alone is bigger than the limit.
        public var fits: Bool
    }

    /// Picks the oldest entries to delete so that what's left plus `incoming` fits in `limit`.
    public static func planCap(_ items: [MediaItem], incoming: Int, limit: Int) -> CapPlan {
        guard incoming <= limit else { return CapPlan(delete: [], fits: false) }
        var total = items.reduce(0) { $0 + $1.bytes } + incoming
        var delete: [MediaItem] = []
        for item in items.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard total > limit else { break }
            delete.append(item)
            total -= item.bytes
        }
        return CapPlan(delete: delete, fits: true)
    }
}

/// Uploads to and deletes from the Worker's media store over plain HTTPS, with the agent token
/// (the same one the relay connection uses). See "Worker HTTP API" in docs/pr-media-plan.md.
public struct MediaUploader: Sendable {
    public let base: URL
    public let token: String
    public let transport: HTTPTransport

    /// The largest value Workers KV stores.
    public static let maxBytes = 25 * 1_048_576
    public static let maxCaption = 200
    public static let redeployHint = "Redeploy the Worker (Settings → Cloudflare → Update Worker, or `minirun worker deploy`) to enable sharing."

    public init(base: URL, token: String, transport: HTTPTransport = URLSessionTransport()) {
        self.base = base
        self.token = token
        self.transport = transport
    }

    /// The uploader for this Mac's Worker. Fails without a relay URL and agent token.
    public init(config: MiniRunConfig, transport: HTTPTransport = URLSessionTransport()) throws {
        guard let base = config.mediaBaseURL.flatMap(URL.init(string:)), let token = config.agentToken, !token.isEmpty else {
            throw ToolError("Sharing needs the Worker, and this Mac has no relay URL or agent token. Set up minirun first (the menu bar app's Set Up, or `minirun worker deploy`).")
        }
        self.init(base: base, token: token, transport: transport)
    }

    public static func contentType(_ ext: String) -> String {
        switch ext {
        case "jpg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    /// Percent-encoded for the X-Minirun-Caption header, and cut so that even the encoded form
    /// stays within the Worker's 200 characters.
    public static func encodeCaption(_ caption: String) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        allowed.insert(charactersIn: "-._~")
        var cut = String(caption.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxCaption))
        while true {
            let encoded = cut.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            if encoded.count <= maxCaption { return encoded }
            cut.removeLast()
        }
    }

    func endpoint(_ path: String) -> URL {
        base.appendingPathComponent("media").appendingPathComponent(path)
    }

    /// PUT /media/<id>.<ext>. Returns the public URL of the file.
    public func upload(id: String, ext: String, data: Data, expiresIn seconds: Int, caption: String?) async throws -> String {
        guard data.count <= Self.maxBytes else {
            throw ToolError("The \(ext) file is \(WorkspaceInventory.formatSize(Int64(data.count))), over the Worker's 25 MiB limit.")
        }
        var request = URLRequest(url: endpoint("\(id).\(ext)"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.contentType(ext), forHTTPHeaderField: "Content-Type")
        request.setValue(String(seconds), forHTTPHeaderField: "X-Minirun-Expires-In")
        if let caption, !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue(Self.encodeCaption(caption), forHTTPHeaderField: "X-Minirun-Caption")
        }
        request.httpBody = data
        request.timeoutInterval = 120
        let (status, body) = try await send(request)
        guard (200..<300).contains(status) else { throw Self.failure(status, body, what: "Uploading to the Worker") }
        if let object = try? JSONValue.parse(body).objectValue, let url = object["url"]?.stringValue { return url }
        return base.appendingPathComponent("m").appendingPathComponent("\(id).\(ext)").absoluteString
    }

    /// DELETE /media/<id>: all of the item's files. One that's already gone counts as deleted.
    public func delete(id: String) async throws {
        var request = URLRequest(url: endpoint(id))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (status, body) = try await send(request)
        guard (200..<300).contains(status) || status == 404 else { throw Self.failure(status, body, what: "Deleting from the Worker") }
    }

    private func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        do {
            return try await transport.send(request)
        } catch {
            throw ToolError("Couldn't reach the Worker at \(base.absoluteString): \(error.localizedDescription)")
        }
    }

    static func failure(_ status: Int, _ body: Data, what: String) -> ToolError {
        switch status {
        // A Worker from before sharing has no /media route.
        case 404: return ToolError("This Worker can't store media yet. " + redeployHint)
        case 401: return ToolError("The Worker refused this Mac's agent token. Choose Update Worker in Settings → Cloudflare (or run `minirun worker deploy`) to give both the same token.")
        case 413: return ToolError("The file is too big for the Worker (the limit is 25 MiB).")
        default:
            let text = String(decoding: body.prefix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return ToolError("\(what) failed with HTTP \(status)" + (text.isEmpty ? "." : ": \(text)"))
        }
    }
}

/// Markdown ready to paste into a PR description.
public enum MediaMarkdown {
    public static func screenshot(caption: String?, url: String) -> String {
        "![\(alt(caption, fallback: "Screenshot"))](\(url))"
    }

    /// An inline looping GIF that opens the MP4 player page when clicked.
    public static func recording(caption: String?, gifURL: String, pageURL: String) -> String {
        "[![\(alt(caption, fallback: "Recording"))](\(gifURL))](\(pageURL))"
    }

    static func alt(_ caption: String?, fallback: String) -> String {
        let text = (caption ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return fallback }
        return text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }
}

/// The upload flow shared by `screenshot {share}` and `stop_recording`: drop expired entries,
/// delete the oldest to stay under the storage limit, upload, then record it in the ledger.
public enum MediaSharing {
    public static let disabledMessage = "Sharing is turned off on this Mac (menu bar app → Settings → Sharing), so nothing was uploaded. " +
        "Tell the user if they want screenshots or recordings in PR descriptions."

    public struct Upload: Sendable {
        public var ext: String
        public var data: Data

        public init(ext: String, data: Data) {
            self.ext = ext
            self.data = data
        }
    }

    /// Uploads `files` as one item. For a recording, pass the mp4 and the gif. Returns the item
    /// and the old ones deleted to make room.
    public static func share(
        kind: MediaItem.Kind, files: [Upload], caption: String?, label: String?,
        config: MiniRunConfig, ledger: MediaLedger, uploader: MediaUploader, now: Date = Date()
    ) async throws -> (item: MediaItem, deleted: [MediaItem]) {
        guard config.shareMedia else { throw ToolError(disabledMessage) }
        let incoming = files.reduce(0) { $0 + $1.data.count }
        let limit = config.mediaStorageLimitBytes
        let onWorker = await ledger.pruneExpired(now: now).filter { !$0.isOnGitHub }
        let plan = MediaLedger.planCap(onWorker, incoming: incoming, limit: limit)
        guard plan.fits else {
            throw ToolError("This upload is \(WorkspaceInventory.formatSize(Int64(incoming))), more than the whole storage limit "
                + "(\(config.mediaStorageLimitMB) MB, Settings → Sharing). Record a shorter clip or raise the limit.")
        }
        for old in plan.delete {
            try await uploader.delete(id: old.id)
            await ledger.remove(old.id)
        }

        let id = MediaItem.newID()
        let ttl = config.mediaRetentionSeconds
        var urls: [String: String] = [:]
        do {
            for file in files {
                urls[file.ext] = try await uploader.upload(id: id, ext: file.ext, data: file.data, expiresIn: ttl, caption: caption)
            }
        } catch {
            // Don't leave half a recording behind.
            if !urls.isEmpty { try? await uploader.delete(id: id) }
            throw error
        }
        let page: String
        switch kind {
        case .screenshot: page = urls[files.first?.ext ?? "jpg"] ?? ""
        case .recording: page = uploader.base.appendingPathComponent("m").appendingPathComponent(id).absoluteString
        }
        let tag = MediaItem.tag(label: label)
        let item = MediaItem(
            id: id, kind: kind, files: files.map { MediaItem.File(ext: $0.ext, bytes: $0.data.count) },
            createdAt: now, expiresAt: now.addingTimeInterval(TimeInterval(ttl)),
            repo: tag.repo, ref: tag.ref, caption: caption, url: page
        )
        await ledger.add(item)
        return (item, plan.delete)
    }

    /// Why a share went to the Worker rather than GitHub, for the line that says how to change it.
    public enum WorkerReason: Equatable, Sendable {
        /// The caller didn't say (older callers and tests).
        case unspecified
        /// `githubMedia` is off in config.json.
        case githubOff
        /// The simulator or Mac app isn't reserved for an owner/name repo.
        case untagged
        /// The repo has no media branch (or the Mac's gh account can't see it).
        case noBranch(repo: String, branch: String)
        /// gh couldn't say whether the branch exists.
        case cantCheck(repo: String, branch: String, why: String)
    }

    /// What the agent gets back for a Worker share: the link, when it expires, the markdown, and
    /// a plain warning that it won't embed in a PR.
    public static func report(_ item: MediaItem, deleted: [MediaItem] = [], reason: WorkerReason = .unspecified) -> String {
        if item.isOnGitHub { return githubReport(item, pair: nil) }
        let expires = ISO8601DateFormatter.string(from: item.expiresAt, timeZone: TimeZone(identifier: "UTC")!, formatOptions: [.withFullDate])
        var lines = ["Shared: \(item.url) (expires \(expires))"]
        switch item.kind {
        case .screenshot:
            lines.append("Markdown: " + MediaMarkdown.screenshot(caption: item.caption, url: item.url))
        case .recording:
            let gif = item.url + ".gif"
            lines.append("Markdown: " + MediaMarkdown.recording(caption: item.caption, gifURL: gif, pageURL: item.url))
        }
        lines.append("This link is on the user's Worker, not github.com. The GitHub tools turn it into a plain link in a PR description, " +
            "and it expires on \(expires). Use it to check your work or in chat. For a PR, follow the repo's own instructions for embedding media.")
        switch reason {
        case .unspecified: break
        case .githubOff:
            lines.append("Uploading to GitHub is turned off on this Mac (githubMedia in ~/.config/minirun/config.json).")
        case .untagged:
            lines.append("minirun uploads to GitHub only for a simulator or Mac app reserved for an owner/name repo (build_and_run with repo and ref).")
        case .noBranch(let repo, let branch):
            lines.append("To get github.com embeds instead, \(repo) needs a `\(branch)` branch that this Mac's gh account can push to. " +
                "Ask the user before creating one: `git switch --orphan \(branch) && git commit --allow-empty -m \"PR media\" && git push -u origin \(branch)`.")
        case .cantCheck(let repo, let branch, let why):
            lines.append("Couldn't check whether \(repo) has a `\(branch)` branch for github.com embeds: \(why)")
        }
        lines.append("Anyone with the link can see it. To take it back, call delete_media with id \"\(item.id)\".")
        if !deleted.isEmpty {
            lines.append("Deleted the \(deleted.count) oldest shared item\(deleted.count == 1 ? "" : "s") to stay under the storage limit.")
        }
        return lines.joined(separator: "\n")
    }

    /// What the agent gets back for a GitHub upload. With `pair` (a `before` for this `after`, or
    /// the other way round, in the same folder) it adds a ready before/after table.
    public static func githubReport(_ item: MediaItem, pair: MediaItem?) -> String {
        let short = String((item.commit ?? "").prefix(7))
        var lines = ["Uploaded \(item.path ?? "the file") to the \(item.branch ?? "media") branch of \(item.repo ?? "the repo") (commit \(short))."]
        let fallback = item.kind == .screenshot ? "Screenshot" : "Recording"
        lines.append("Markdown: ![\(MediaMarkdown.alt(item.caption, fallback: fallback))](\(item.url))")
        if let pair {
            let (before, after) = GitHubMediaNames.isBefore(item) ? (item, pair) : (pair, item)
            lines.append("Before/after table:")
            lines.append("| Before | After |\n| --- | --- |\n| ![\(MediaMarkdown.alt(before.caption, fallback: "before"))](\(before.url)) | ![\(MediaMarkdown.alt(after.caption, fallback: "after"))](\(after.url)) |")
        }
        lines.append("Paste it into the PR description: github.com images survive the GitHub tools and show for anyone who can see the repo. " +
            "It doesn't expire. It's in the repo's history now: delete_media with id \"\(item.id)\" removes it from the branch, but this pinned link keeps working, " +
            "so never upload credentials or personal data.")
        return lines.joined(separator: "\n")
    }

    /// Commits one file to the repo's media branch and records it.
    public static func shareToGitHub(
        kind: MediaItem.Kind, file: Upload, caption: String?, repo: String, ref: String?, branch: String,
        folder: String, name: String, ledger: MediaLedger, gh: GHCommand, now: Date = Date()
    ) async throws -> MediaItem {
        let path = "\(folder)/\(name).\(file.ext)"
        let commit = try await GitHubMedia.upload(
            repo: repo, branch: branch, path: path, data: file.data, message: "PR media for \(folder): \(name).\(file.ext)", gh: gh
        )
        let item = MediaItem(
            id: MediaItem.newID(), kind: kind, files: [.init(ext: file.ext, bytes: file.data.count)],
            createdAt: now, expiresAt: MediaItem.neverExpires, repo: repo, ref: ref, caption: caption,
            url: GitHubMedia.embedURL(repo: repo, commit: commit, path: path),
            host: .github, branch: branch, path: path, commit: commit
        )
        // A re-upload under the same name replaces the older entry: it's the same file on the branch.
        for old in await ledger.list(now: now) where old.isOnGitHub && old.repo == repo && old.path == path {
            await ledger.remove(old.id)
        }
        await ledger.add(item)
        return item
    }

    /// Where a share should go, and why.
    public enum Destination: Equatable, Sendable {
        case github(repo: String, branch: String)
        case worker(WorkerReason)
    }

    public static func destination(label: String?, config: MiniRunConfig, branches: GitHubMediaBranches, gh: GHCommand) async -> Destination {
        guard config.githubMedia else { return .worker(.githubOff) }
        guard let repo = MediaItem.tag(label: label).repo, GitHubMedia.isValidRepo(repo) else { return .worker(.untagged) }
        let branch = config.mediaBranch
        switch await branches.check(repo: repo, branch: branch, gh: gh) {
        case .present: return .github(repo: repo, branch: branch)
        case .absent: return .worker(.noBranch(repo: repo, branch: branch))
        case .unknown(let why): return .worker(.cantCheck(repo: repo, branch: branch, why: why))
        }
    }

    /// How big a recording's GIF can be on GitHub. A GIF on the media branch is served by
    /// github.com itself, not through GitHub's image proxy, so the Worker's inline limit doesn't
    /// apply; this keeps PRs quick to load. It's the same as GitHub's own limit for GIFs
    /// attached to comments.
    public static let githubGIFLimitBytes = 10 * 1_048_576

    /// The largest GIF to make for a recording headed wherever `destination` would send it.
    public static func gifLimitBytes(
        label: String?, config: MiniRunConfig, branches: GitHubMediaBranches = .shared, gh: GHCommand = GitHubMedia.defaultGH
    ) async -> Int {
        switch await destination(label: label, config: config, branches: branches, gh: gh) {
        case .github: return max(githubGIFLimitBytes, config.mediaInlineLimitBytes)
        case .worker: return config.mediaInlineLimitBytes
        }
    }

    /// `screenshot {share}` and `stop_recording {share}`: to the repo's media branch when it has
    /// one, else to the Worker. Returns the text for the agent. `files` is the jpg for a
    /// screenshot, or the mp4 and gif for a recording (GitHub gets only the gif, which renders inline).
    public static func shareAnywhere(
        kind: MediaItem.Kind, files: [Upload], caption: String?, label: String?, folder: String?, name: String?,
        config: MiniRunConfig, ledger: MediaLedger, branches: GitHubMediaBranches = .shared, gh: GHCommand = GitHubMedia.defaultGH,
        makeUploader: @Sendable () throws -> MediaUploader, now: Date = Date()
    ) async throws -> String {
        guard config.shareMedia else { throw ToolError(disabledMessage) }
        if let folder, !GitHubMedia.isValidFolder(folder) {
            throw ToolError("folder \"\(folder)\" should be one folder name: letters, digits, '.', '_' and '-', not starting with a dot.")
        }
        if let name, !GitHubMedia.isValidName(name) {
            throw ToolError("name \"\(name)\" should be lowercase letters, digits and single dashes, like \"after\" or \"menu-open\".")
        }
        switch await destination(label: label, config: config, branches: branches, gh: gh) {
        case .github(let repo, let branch):
            let ext = kind == .screenshot ? (files.first?.ext ?? "jpg") : "gif"
            guard let file = files.first(where: { $0.ext == ext }) else { throw ToolError("Nothing to upload: no \(ext) file.") }
            let tag = MediaItem.tag(label: label)
            let folder = folder ?? GitHubMedia.defaultFolder(ref: tag.ref)
            let name = name ?? GitHubMedia.defaultName(caption: caption, kind: kind, now: now)
            let item = try await shareToGitHub(
                kind: kind, file: file, caption: caption, repo: repo, ref: tag.ref, branch: branch,
                folder: folder, name: name, ledger: ledger, gh: gh, now: now
            )
            return githubReport(item, pair: await GitHubMediaNames.pair(for: item, in: ledger.list(now: now)))
        case .worker(let reason):
            let (item, deleted) = try await share(
                kind: kind, files: files, caption: caption, label: label,
                config: config, ledger: ledger, uploader: try makeUploader(), now: now
            )
            return report(item, deleted: deleted, reason: reason)
        }
    }

    /// Takes back one shared item, wherever it lives. Returns what to tell the agent.
    public static func delete(_ item: MediaItem, config: MiniRunConfig, ledger: MediaLedger, gh: GHCommand = GitHubMedia.defaultGH) async throws -> String {
        if item.isOnGitHub, let repo = item.repo, let branch = item.branch, let path = item.path {
            try await GitHubMedia.delete(repo: repo, branch: branch, path: path, gh: gh)
            await ledger.remove(item.id)
            return "Removed \(path) from the \(branch) branch of \(repo). The pinned link in any PR keeps working, because the commit it points to still has the file."
        }
        try await MediaUploader(config: config).delete(id: item.id)
        await ledger.remove(item.id)
        return "Deleted \(item.id). Its link no longer works, though GitHub may show a cached copy for a while."
    }
}

/// Before/after pairs on the media branch.
public enum GitHubMediaNames {
    static func split(_ item: MediaItem) -> (folder: String, name: String)? {
        guard let path = item.path, let slash = path.lastIndex(of: "/") else { return nil }
        let file = path[path.index(after: slash)...]
        let name = file.split(separator: ".").first.map(String.init) ?? String(file)
        return (String(path[..<slash]), name)
    }

    static func isBefore(_ item: MediaItem) -> Bool { split(item)?.name == "before" }

    /// The `before` for an `after` (or the reverse) in the same repo and folder, if one was shared.
    public static func pair(for item: MediaItem, in items: [MediaItem]) -> MediaItem? {
        guard item.isOnGitHub, let mine = split(item), mine.name == "before" || mine.name == "after" else { return nil }
        let other = mine.name == "before" ? "after" : "before"
        return items.first { candidate in
            guard candidate.isOnGitHub, candidate.id != item.id, candidate.repo == item.repo, let theirs = split(candidate) else { return false }
            return theirs.folder == mine.folder && theirs.name == other
        }
    }
}
