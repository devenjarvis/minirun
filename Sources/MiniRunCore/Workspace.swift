import Foundation
import MiniRunKit

/// Git checkouts that builds run in: `<workspaceRoot>/<owner>/<name>` for the default branch and
/// `<workspaceRoot>/<owner>/<name>@<ref>` for each ref, so different branches never share a folder.
enum Workspace {
    struct Checkout {
        let path: String
        let slug: String
        let ref: String?
        let commit: String
        let subject: String

        var label: String { WorkspaceNaming.label(slug: slug, ref: ref) }
    }

    static func path(for slug: String, ref: String?, config: MiniRunConfig) -> String {
        config.workspaceRoot + "/" + WorkspaceNaming.directory(slug: slug, ref: ref)
    }

    /// Git work on one mirror (fetches, checkouts, adding worktrees) writes its shared object
    /// store and tags, so it runs one at a time per mirror.
    private static let mirrors = KeyedLock()

    /// Clones or updates `repo` and checks out `ref` (branch, tag or commit; default branch if nil).
    /// Local changes in the checkout are discarded; build output under `.minirun/` is kept.
    ///
    /// A new checkout is a worktree of the repository's bare mirror (`WorkspaceNaming.mirror`), so
    /// a new ref only downloads what the mirror doesn't have yet. Checkouts made before that are
    /// full clones, and keep working as they are; so does a checkout made when the mirror fails.
    static func sync(repo: String, ref: String?, config: MiniRunConfig, log: URL?) async throws -> Checkout {
        let (url, slug) = try config.resolveRepo(repo)
        let dir = path(for: slug, ref: ref, config: config)
        let mirror = WorkspaceNaming.mirror(root: config.workspaceRoot, slug: slug)
        let fm = FileManager.default

        if !fm.fileExists(atPath: dir + "/.git") {
            do {
                try await mirrors.withLock(mirror) { try await addWorktree(url: url, mirror: mirror, dir: dir, log: log) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                XcodeBuild.appendLog(log, "Couldn't make a worktree of \(mirror) (\(error.localizedDescription)); cloning instead.\n")
                try? fm.removeItem(atPath: dir)
                try fm.createDirectory(atPath: (dir as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try await git(["clone", "--filter=blob:none", "--no-checkout", url, dir], cwd: nil, log: log, timeout: 900)
            }
        } else {
            try await git(["remote", "set-url", "origin", url], cwd: dir, log: log)
        }

        // A worktree shares the mirror's objects and tags with its other worktrees.
        let gitDir = WorkspaceNaming.gitDirectory(checkout: dir)
        let isWorktree = gitDir != dir + "/.git"
        try await mirrors.withLock(isWorktree ? mirror : dir) {
            let target = ref?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "HEAD"
            // FETCH_HEAD is per worktree, so fetches for other refs of the mirror don't replace it.
            try await git(["fetch", "--prune", "--tags", "--force", "origin", target], cwd: dir, log: log, timeout: 900)
            try await git(["checkout", "--force", "--detach", "FETCH_HEAD"], cwd: dir, log: log)
            try await git(["clean", "-ffd", "-e", ".minirun/"], cwd: dir, log: log)
            if fm.fileExists(atPath: dir + "/.gitmodules") {
                try await git(["submodule", "update", "--init", "--recursive", "--force"], cwd: dir, log: log, timeout: 900)
            }
        }
        // Worktrees read info/exclude from the mirror, so one entry there covers all of them.
        ensureIgnored(gitDirectory: isWorktree ? mirror : gitDir)

        let info = try await Shell.check("/usr/bin/git", ["log", "-1", "--format=%H%n%s"], cwd: dir, timeout: 30)
        let lines = info.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", maxSplits: 1).map(String.init)
        return Checkout(path: dir, slug: slug, ref: ref, commit: lines.first ?? "", subject: lines.count > 1 ? lines[1] : "")
    }

    /// Makes `dir` a worktree of the bare mirror, making the mirror first if there isn't one.
    /// The worktree starts with nothing checked out; `sync` fetches and checks out its ref.
    private static func addWorktree(url: String, mirror: String, dir: String, log: URL?) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: mirror + "/HEAD") {
            try await git(["remote", "set-url", "origin", url], cwd: mirror, log: log)
        } else {
            try? fm.removeItem(atPath: mirror)
            try fm.createDirectory(atPath: (mirror as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            XcodeBuild.appendLog(log, "Making the mirror \(mirror); later refs of this repo are checked out from it.\n")
            try await git(["clone", "--bare", "--filter=blob:none", url, mirror], cwd: nil, log: log, timeout: 900)
        }
        // Forget worktrees whose folders are gone (deleted from the menu or by hand), so one can
        // be added at the same path again.
        try await git(["worktree", "prune"], cwd: mirror, log: log)
        if fm.fileExists(atPath: dir) { try fm.removeItem(atPath: dir) }
        try fm.createDirectory(atPath: (dir as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try await git(["worktree", "add", "--detach", "--no-checkout", dir], cwd: mirror, log: log)
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

    /// Resolves the directory for a tool call: an existing checkout of `repo` at `ref`, or an explicit `path`.
    static func directory(repo: String?, ref: String?, path: String?, config: MiniRunConfig) throws -> String {
        if let path {
            let expanded = (path as NSString).expandingTildeInPath
            let resolved = expanded.hasPrefix("/") ? expanded : config.workspaceRoot + "/" + expanded
            var standardized = URL(fileURLWithPath: resolved).standardizedFileURL.path
            // A Swift package is built from its folder: accept a path to its Package.swift too.
            if (standardized as NSString).lastPathComponent == "Package.swift" { standardized = (standardized as NSString).deletingLastPathComponent }
            guard FileManager.default.fileExists(atPath: standardized) else { throw ToolError("No such directory: \(standardized)") }
            return standardized
        }
        if let repo {
            let (_, slug) = try config.resolveRepo(repo)
            let dir = self.path(for: slug, ref: ref, config: config)
            guard FileManager.default.fileExists(atPath: dir + "/.git") else {
                let what = WorkspaceNaming.label(slug: slug, ref: ref)
                throw ToolError("\(what) isn't checked out yet. Call sync_repo with this repo and ref first, or pass `ref` to build so it syncs automatically.")
            }
            return dir
        }
        throw ToolError("Pass `repo` (owner/name) or `path`.")
    }

    /// Makes sure `.minirun/` is git-ignored locally without touching the tracked .gitignore.
    private static func ensureIgnored(gitDirectory: String) {
        let exclude = gitDirectory + "/info/exclude"
        let current = (try? String(contentsOfFile: exclude, encoding: .utf8)) ?? ""
        guard !current.contains(".minirun/") else { return }
        try? FileManager.default.createDirectory(atPath: gitDirectory + "/info", withIntermediateDirectories: true)
        try? (current + (current.hasSuffix("\n") || current.isEmpty ? "" : "\n") + ".minirun/\n").write(toFile: exclude, atomically: true, encoding: .utf8)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
