import Foundation

/// Runs `gh` with these arguments and returns what it printed. Tests swap in a fake.
public typealias GHCommand = @Sendable (_ arguments: [String]) async throws -> ShellResult

/// Shared media committed to a branch of the repo itself (docs/github-media-plan.md), so a PR
/// description can embed it with a github.com link. The GitHub tools agents post with strip
/// images hosted anywhere else, and github.com links follow the repo's visibility and don't expire.
///
/// A repo opts in by having the media branch (`pr-media` by default). Uploads go through the REST
/// contents API with the Mac's `gh` sign-in: no checkout or worktree is touched.
public enum GitHubMedia {
    /// `gh` from the daemon, which launchd starts with a bare PATH.
    public static let defaultGH: GHCommand = { arguments in
        let current = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return try await Shell.run("gh", arguments, environment: [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:" + current,
            "NO_COLOR": "1",
            "GH_PROMPT_DISABLED": "1",
        ], timeout: 120)
    }

    // MARK: Names

    /// owner/name, as GitHub allows them.
    public static func isValidRepo(_ repo: String) -> Bool {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.unicodeScalars.allSatisfy { isPlain($0) || $0 == "." || $0 == "_" || $0 == "-" }
        }
    }

    /// A branch name safe to put in a URL path and query without escaping.
    public static func isValidBranch(_ branch: String) -> Bool {
        !branch.isEmpty && branch.count <= 100 && !branch.hasPrefix("/") && !branch.hasSuffix("/") && !branch.contains("..") && !branch.contains("//")
            && branch.unicodeScalars.allSatisfy { isPlain($0) || "._-/".unicodeScalars.contains($0) }
    }

    /// One folder name on the media branch: letters, digits, `.`, `_` and `-`, not starting with a dot.
    public static func isValidFolder(_ folder: String) -> Bool {
        !folder.isEmpty && folder.count <= 100 && !folder.hasPrefix(".")
            && folder.unicodeScalars.allSatisfy { isPlain($0) || "._-".unicodeScalars.contains($0) }
    }

    /// A file name without its extension: lowercase letters, digits and single dashes.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64, !name.hasPrefix("-"), !name.hasSuffix("-"), !name.contains("--") else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// The folder when the agent gives none: the ref with anything unusual turned into dashes.
    public static func defaultFolder(ref: String?) -> String {
        let cleaned = String((ref ?? "").unicodeScalars.map { isPlain($0) || "._-".unicodeScalars.contains($0) ? Character($0) : "-" })
        var folder = cleaned
        while folder.hasPrefix(".") || folder.hasPrefix("-") { folder.removeFirst() }
        folder = String(folder.prefix(100))
        return folder.isEmpty ? "media" : folder
    }

    /// The name when the agent gives none: the caption as a slug, or `<kind>-<hhmmss>`.
    public static func defaultName(caption: String?, kind: MediaItem.Kind, now: Date) -> String {
        if let slug = slug(caption ?? ""), !slug.isEmpty { return slug }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.hour, .minute, .second], from: now)
        return String(format: "%@-%02d%02d%02d", kind.rawValue, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    static func slug(_ text: String) -> String? {
        var out = ""
        for scalar in text.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if !out.isEmpty, !out.hasSuffix("-") {
                out += "-"
            }
            if out.count >= 40 { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? nil : out
    }

    private static func isPlain(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }

    /// The embed that survives the GitHub tools and renders in private repos: a github.com blob
    /// link pinned to the commit, with `?raw=true`.
    public static func embedURL(repo: String, commit: String, path: String) -> String {
        "https://github.com/\(repo)/blob/\(commit)/\(path)?raw=true"
    }

    // MARK: Is the repo set up?

    public enum BranchCheck: Equatable, Sendable {
        case present
        case absent
        /// gh couldn't answer (not installed, not signed in, offline). The text says why.
        case unknown(String)
    }

    public static func checkBranch(repo: String, branch: String, gh: GHCommand) async -> BranchCheck {
        do {
            let result = try await gh(["api", "repos/\(repo)/branches/\(branch)", "--jq", ".name"])
            if result.succeeded { return .present }
            if result.tail().contains("HTTP 404") { return .absent }
            return .unknown(explain(result, repo: repo, writing: false).message)
        } catch {
            return .unknown(ghMissing(error))
        }
    }

    // MARK: Uploading and deleting

    /// Commits `data` to `path` on `branch` (replacing a file already there) and returns the new
    /// commit's SHA. Retries when another upload moved the branch at the same moment.
    public static func upload(
        repo: String, branch: String, path: String, data: Data, message: String,
        gh: GHCommand, attempts: Int = 4, pause: @Sendable (Int) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0) * 1_000_000_000) }
    ) async throws -> String {
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("minirun-media-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: body) }
        var last: ToolError?
        for attempt in 1...max(1, attempts) {
            let existing = try await currentSHA(repo: repo, branch: branch, path: path, gh: gh)
            var object: [String: JSONValue] = ["message": .string(message), "branch": .string(branch), "content": .string(data.base64EncodedString())]
            if let existing { object["sha"] = .string(existing) }
            try JSONEncoder().encode(JSONValue.object(object)).write(to: body)
            let result: ShellResult
            do {
                result = try await gh(["api", "-X", "PUT", "repos/\(repo)/contents/\(path)", "--input", body.path, "--jq", ".commit.sha"])
            } catch {
                throw ToolError(ghMissing(error))
            }
            let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.succeeded, isSHA(sha) { return sha }
            let output = result.tail()
            // 409: the branch moved under us. 422 "sha": someone created the file meanwhile.
            guard result.succeeded == false, output.contains("HTTP 409") || (output.contains("HTTP 422") && output.contains("sha")) else {
                if result.succeeded { throw ToolError("GitHub accepted the upload to \(repo) but gave back no commit: \(Shell.tail(output, limit: 300))") }
                throw explain(result, repo: repo, writing: true)
            }
            last = ToolError("Another upload to the \(branch) branch of \(repo) kept getting in the way. Try again.")
            if attempt < attempts { await pause(attempt * 2) }
        }
        throw last ?? ToolError("Couldn't upload to \(repo).")
    }

    /// Removes the file from the branch tip. Commits that already have it keep it, so pinned
    /// links keep working. A file that's already gone counts as deleted.
    public static func delete(repo: String, branch: String, path: String, gh: GHCommand) async throws {
        guard let sha = try await currentSHA(repo: repo, branch: branch, path: path, gh: gh) else { return }
        let result: ShellResult
        do {
            result = try await gh(["api", "-X", "DELETE", "repos/\(repo)/contents/\(path)",
                                   "-f", "message=Remove PR media \(path)", "-f", "sha=\(sha)", "-f", "branch=\(branch)", "--silent"])
        } catch {
            throw ToolError(ghMissing(error))
        }
        if result.succeeded || result.tail().contains("HTTP 404") { return }
        throw explain(result, repo: repo, writing: true)
    }

    /// The blob SHA of the file on the branch, or nil when there's none.
    static func currentSHA(repo: String, branch: String, path: String, gh: GHCommand) async throws -> String? {
        let result: ShellResult
        do {
            result = try await gh(["api", "repos/\(repo)/contents/\(path)?ref=\(branch)", "--jq", ".sha"])
        } catch {
            throw ToolError(ghMissing(error))
        }
        if result.succeeded {
            let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return isSHA(sha) ? sha : nil
        }
        if result.tail().contains("HTTP 404") { return nil }
        throw explain(result, repo: repo, writing: false)
    }

    static func isSHA(_ text: String) -> Bool {
        text.count >= 40 && text.count <= 64 && text.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    static func ghMissing(_ error: Error) -> String {
        "Couldn't run gh on the Mac (\(error.localizedDescription)). Install it (brew install gh) and sign in with `gh auth login`."
    }

    /// gh's failure as something the agent can act on.
    static func explain(_ result: ShellResult, repo: String, writing: Bool) -> ToolError {
        let output = result.tail()
        if result.exitCode == 127 || output.contains("command not found") || output.contains("No such file or directory") {
            return ToolError("gh isn't installed on the Mac. Ask the user to run `brew install gh` and `gh auth login` there.")
        }
        if output.contains("gh auth login") || output.contains("HTTP 401") || output.contains("not logged in") {
            return ToolError("gh on the Mac isn't signed in to GitHub. Ask the user to run `gh auth login` there.")
        }
        if writing, output.contains("HTTP 403") || output.contains("HTTP 404") {
            return ToolError("The Mac's GitHub account (gh) can't push to \(repo). Ask the user to give it write access, or to sign gh in to an account that has it.")
        }
        if result.timedOut { return ToolError("gh took too long to answer for \(repo). GitHub may be slow; try again.") }
        return ToolError("gh failed for \(repo): \(Shell.tail(output, limit: 400))")
    }
}

/// Which repos have the media branch, remembered for a while so every share doesn't ask GitHub.
public actor GitHubMediaBranches {
    public static let shared = GitHubMediaBranches()

    private var known: [String: (present: Bool, checked: Date)] = [:]
    /// A branch that exists is unlikely to vanish; one that doesn't may be created any minute.
    public static let presentFor: TimeInterval = 600
    public static let absentFor: TimeInterval = 60

    public init() {}

    public func check(repo: String, branch: String, gh: GHCommand, now: Date = Date()) async -> GitHubMedia.BranchCheck {
        let key = repo.lowercased() + "@" + branch
        if let entry = known[key], now.timeIntervalSince(entry.checked) < (entry.present ? Self.presentFor : Self.absentFor) {
            return entry.present ? .present : .absent
        }
        let answer = await GitHubMedia.checkBranch(repo: repo, branch: branch, gh: gh)
        switch answer {
        case .present: known[key] = (true, now)
        case .absent: known[key] = (false, now)
        case .unknown: known[key] = nil
        }
        return answer
    }

    public func forget() { known = [:] }
}

/// What `screenshot {share}` and `stop_recording` take besides the device: the alt text, and
/// where on the media branch the file goes.
public struct MediaShareOptions: Sendable, Equatable {
    public var caption: String?
    public var folder: String?
    public var name: String?

    public init(caption: String? = nil, folder: String? = nil, name: String? = nil) {
        self.caption = caption
        self.folder = folder
        self.name = name
    }

    public init(_ args: ToolArguments) {
        func clean(_ key: String) -> String? {
            let value = args.string(key)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        self.init(caption: clean("caption"), folder: clean("folder"), name: clean("name"))
    }

    /// The schema entries both tools add.
    public static let properties: [String: JSONValue] = [
        "folder": Schema.string("With share, for a repo with a pr-media branch: the folder on that branch, e.g. a ticket id like \"TICKET-0032\". Default: the branch name."),
        "name": Schema.string("With share, for a repo with a pr-media branch: the file name without extension, lowercase with dashes, e.g. \"before\", \"after\" or \"menu-open\". " +
            "Re-using a name replaces the file. Sharing both a \"before\" and an \"after\" in one folder also gives you a before/after table. Default: from the caption."),
    ]
}
