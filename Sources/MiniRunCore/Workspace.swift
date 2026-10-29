import Foundation
import MiniRunKit

/// Git checkouts that builds run in: `<workspaceRoot>/<owner>/<name>`.
enum Workspace {
    struct Checkout {
        let path: String
        let slug: String
        let commit: String
        let subject: String
    }

    static func path(for slug: String, config: MiniRunConfig) -> String {
        config.workspaceRoot + "/" + slug
    }

    /// Clones or updates `repo` and checks out `ref` (branch, tag or commit; default branch if nil).
    /// Local changes in the checkout are discarded; build output under `.minirun/` is kept.
    static func sync(repo: String, ref: String?, config: MiniRunConfig, log: URL?) async throws -> Checkout {
        let (url, slug) = try config.resolveRepo(repo)
        let dir = path(for: slug, config: config)
        let fm = FileManager.default

        if !fm.fileExists(atPath: dir + "/.git") {
            try fm.createDirectory(atPath: (dir as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dir) { try fm.removeItem(atPath: dir) }
            try await git(["clone", "--filter=blob:none", "--no-checkout", url, dir], cwd: nil, log: log, timeout: 900)
        } else {
            try await git(["remote", "set-url", "origin", url], cwd: dir, log: log)
        }

        let target = ref?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "HEAD"
        try await git(["fetch", "--prune", "--tags", "--force", "origin", target], cwd: dir, log: log, timeout: 900)
        try await git(["checkout", "--force", "--detach", "FETCH_HEAD"], cwd: dir, log: log)
        try await git(["clean", "-ffd", "-e", ".minirun/"], cwd: dir, log: log)
        if fm.fileExists(atPath: dir + "/.gitmodules") {
            try await git(["submodule", "update", "--init", "--recursive", "--force"], cwd: dir, log: log, timeout: 900)
        }
        ensureIgnored(dir)

        let info = try await Shell.check("/usr/bin/git", ["log", "-1", "--format=%H%n%s"], cwd: dir, timeout: 30)
        let lines = info.stdout.split(separator: "\n", maxSplits: 1).map(String.init)
        return Checkout(path: dir, slug: slug, commit: lines.first ?? "", subject: lines.count > 1 ? lines[1] : "")
    }

    @discardableResult
    static func git(_ args: [String], cwd: String?, log: URL?, timeout: TimeInterval = 300) async throws -> ShellResult {
        let result = try await Shell.run(
            "/usr/bin/git", args, cwd: cwd,
            environment: ["GIT_TERMINAL_PROMPT": "0"],
            timeout: timeout, logURL: log
        )
        guard result.succeeded else {
            var message = "git \(args.first ?? "") failed:\n\(result.tail(2000))"
            if result.stderr.contains("Authentication failed") || result.stderr.contains("could not read Username") {
                message += "\n\nThe Mac has no credentials for this repository. On the Mac, run `gh auth login` (and `gh auth setup-git`) or set up an SSH key, then try again."
            }
            throw ToolError(message)
        }
        return result
    }

    /// Resolves the directory for a tool call: an existing workspace by `repo`, or an explicit `path`.
    static func directory(repo: String?, path: String?, config: MiniRunConfig) throws -> String {
        if let path {
            let expanded = (path as NSString).expandingTildeInPath
            let resolved = expanded.hasPrefix("/") ? expanded : config.workspaceRoot + "/" + expanded
            let standardized = URL(fileURLWithPath: resolved).standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: standardized) else { throw ToolError("No such directory: \(standardized)") }
            return standardized
        }
        if let repo {
            let (_, slug) = try config.resolveRepo(repo)
            let dir = self.path(for: slug, config: config)
            guard FileManager.default.fileExists(atPath: dir + "/.git") else {
                throw ToolError("\(slug) isn't checked out yet. Call sync_repo first, or pass `ref` to build so it syncs automatically.")
            }
            return dir
        }
        throw ToolError("Pass `repo` (owner/name) or `path`.")
    }

    /// Makes sure `.minirun/` is git-ignored locally without touching the tracked .gitignore.
    private static func ensureIgnored(_ dir: String) {
        let exclude = dir + "/.git/info/exclude"
        let current = (try? String(contentsOfFile: exclude, encoding: .utf8)) ?? ""
        guard !current.contains(".minirun/") else { return }
        try? FileManager.default.createDirectory(atPath: dir + "/.git/info", withIntermediateDirectories: true)
        try? (current + (current.hasSuffix("\n") || current.isEmpty ? "" : "\n") + ".minirun/\n").write(toFile: exclude, atomically: true, encoding: .utf8)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
