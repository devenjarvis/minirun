import XCTest
@testable import MiniRunKit

/// Stands in for `gh`: records each call and answers from a script.
final class FakeGH: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [[String]] = []
    /// The JSON bodies sent with --input, read while the file still exists.
    private var bodies: [[String: JSONValue]] = []
    var answer: @Sendable ([String]) -> ShellResult

    init(_ answer: @escaping @Sendable ([String]) -> ShellResult) {
        self.answer = answer
    }

    var calls: [[String]] { lock.withLock { log } }
    var inputs: [[String: JSONValue]] { lock.withLock { bodies } }

    var command: GHCommand {
        { [self] arguments in
            var body: [String: JSONValue]?
            if let index = arguments.firstIndex(of: "--input"), index + 1 < arguments.count,
               let data = FileManager.default.contents(atPath: arguments[index + 1]) {
                body = try? JSONValue.parse(data).objectValue
            }
            lock.withLock {
                log.append(arguments)
                if let body { bodies.append(body) }
            }
            return answer(arguments)
        }
    }

    static func ok(_ stdout: String = "") -> ShellResult { ShellResult(exitCode: 0, stdout: stdout) }
    static func fail(_ stderr: String) -> ShellResult { ShellResult(exitCode: 1, stdout: "", stderr: stderr) }
    static let notFound = fail("gh: Not Found (HTTP 404)")
}

final class GitHubMediaTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000) // 2033-05-18 03:33:20 UTC
    let commit = String(repeating: "c", count: 40)
    let blob = String(repeating: "b", count: 40)

    /// A repo with the branch, where nothing has been uploaded yet.
    func freshRepo() -> FakeGH {
        let commit = self.commit
        return FakeGH { arguments in
            let endpoint = arguments.first { $0.hasPrefix("repos/") } ?? ""
            if endpoint.contains("/branches/") { return FakeGH.ok("pr-media") }
            if arguments.contains("PUT") { return FakeGH.ok(commit) }
            if endpoint.contains("/contents/") { return FakeGH.notFound }
            return FakeGH.fail("unexpected \(arguments)")
        }
    }

    func testNames() {
        XCTAssertTrue(GitHubMedia.isValidRepo("you/app"))
        XCTAssertTrue(GitHubMedia.isValidRepo("you/my.app_2-x"))
        XCTAssertFalse(GitHubMedia.isValidRepo("you"))
        XCTAssertFalse(GitHubMedia.isValidRepo("you/app/x"))
        XCTAssertFalse(GitHubMedia.isValidRepo("you/.."))
        XCTAssertFalse(GitHubMedia.isValidRepo("my label"))

        XCTAssertTrue(GitHubMedia.isValidFolder("TICKET-0032"))
        XCTAssertFalse(GitHubMedia.isValidFolder(".git"))
        XCTAssertFalse(GitHubMedia.isValidFolder("a/b"))
        XCTAssertFalse(GitHubMedia.isValidFolder(""))

        XCTAssertTrue(GitHubMedia.isValidName("after"))
        XCTAssertTrue(GitHubMedia.isValidName("menu-open-2"))
        for bad in ["After", "a--b", "-a", "a-", "a.b", "a b", ""] { XCTAssertFalse(GitHubMedia.isValidName(bad), bad) }

        XCTAssertTrue(GitHubMedia.isValidBranch("pr-media"))
        XCTAssertTrue(GitHubMedia.isValidBranch("media/prs"))
        for bad in ["", "a..b", "/a", "a/", "a b", "a?b"] { XCTAssertFalse(GitHubMedia.isValidBranch(bad), bad) }
    }

    func testDefaults() {
        XCTAssertEqual(GitHubMedia.defaultFolder(ref: "spec/0032-menu bar"), "spec-0032-menu-bar")
        XCTAssertEqual(GitHubMedia.defaultFolder(ref: ".hidden"), "hidden")
        XCTAssertEqual(GitHubMedia.defaultFolder(ref: nil), "media")
        XCTAssertEqual(GitHubMedia.defaultName(caption: "Settings screen, dark mode!", kind: .screenshot, now: now), "settings-screen-dark-mode")
        XCTAssertEqual(GitHubMedia.defaultName(caption: "  ", kind: .screenshot, now: now), "screenshot-033320")
        XCTAssertEqual(GitHubMedia.defaultName(caption: nil, kind: .recording, now: now), "recording-033320")
        XCTAssertEqual(GitHubMedia.embedURL(repo: "you/app", commit: commit, path: "T-1/after.jpg"),
                       "https://github.com/you/app/blob/\(commit)/T-1/after.jpg?raw=true")
    }

    func testConfigKeys() throws {
        let old = try JSONDecoder().decode(MiniRunConfig.self, from: Data("{}".utf8))
        XCTAssertTrue(old.githubMedia)
        XCTAssertEqual(old.mediaBranch, "pr-media")
        let custom = try JSONDecoder().decode(MiniRunConfig.self, from: Data(#"{"githubMedia":false,"githubMediaBranch":"media/prs"}"#.utf8))
        XCTAssertFalse(custom.githubMedia)
        XCTAssertEqual(custom.mediaBranch, "media/prs")
        XCTAssertEqual(MiniRunConfig(githubMediaBranch: "bad branch").mediaBranch, "pr-media")
    }

    func testOldLedgerEntriesAreOnTheWorker() throws {
        let json = #"{"id":"aaaaaaaaaaaaaaaaaaaaaa","kind":"screenshot","files":[{"ext":"jpg","bytes":1}],"createdAt":"2033-05-18T00:00:00Z","expiresAt":"2033-05-25T00:00:00Z","url":"https://w.example/m/a.jpg"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let item = try decoder.decode(MediaItem.self, from: Data(json.utf8))
        XCTAssertNil(item.host)
        XCTAssertFalse(item.isOnGitHub)
    }

    func testDestination() async {
        let branches = GitHubMediaBranches()
        let present = freshRepo()
        var config = MiniRunConfig()
        let github = await MediaSharing.destination(label: "you/app@feature", config: config, branches: branches, gh: present.command)
        XCTAssertEqual(github, .github(repo: "you/app", branch: "pr-media"))

        let untagged = await MediaSharing.destination(label: "my phone", config: config, branches: branches, gh: present.command)
        XCTAssertEqual(untagged, .worker(.untagged))
        let none = await MediaSharing.destination(label: nil, config: config, branches: branches, gh: present.command)
        XCTAssertEqual(none, .worker(.untagged))

        let absent = FakeGH { _ in FakeGH.notFound }
        let noBranch = await MediaSharing.destination(label: "you/other@main", config: config, branches: branches, gh: absent.command)
        XCTAssertEqual(noBranch, .worker(.noBranch(repo: "you/other", branch: "pr-media")))

        let signedOut = FakeGH { _ in FakeGH.fail("To get started with GitHub CLI, please run:  gh auth login") }
        let cant = await MediaSharing.destination(label: "you/third@main", config: config, branches: branches, gh: signedOut.command)
        guard case .worker(.cantCheck(let repo, _, let why)) = cant else { return XCTFail("\(cant)") }
        XCTAssertEqual(repo, "you/third")
        XCTAssertTrue(why.contains("gh auth login"), why)

        config.githubMedia = false
        let off = await MediaSharing.destination(label: "you/app@feature", config: config, branches: branches, gh: present.command)
        XCTAssertEqual(off, .worker(.githubOff))
    }

    func testBranchAnswersAreRemembered() async {
        let branches = GitHubMediaBranches()
        let gh = FakeGH { _ in FakeGH.ok("pr-media") }
        for _ in 0..<3 { _ = await branches.check(repo: "you/app", branch: "pr-media", gh: gh.command, now: now) }
        XCTAssertEqual(gh.calls.count, 1)
        _ = await branches.check(repo: "you/app", branch: "pr-media", gh: gh.command, now: now.addingTimeInterval(GitHubMediaBranches.presentFor + 1))
        XCTAssertEqual(gh.calls.count, 2)

        // A missing branch is asked about again soon: the user may be creating it.
        let missing = FakeGH { _ in FakeGH.notFound }
        _ = await branches.check(repo: "you/new", branch: "pr-media", gh: missing.command, now: now)
        _ = await branches.check(repo: "you/new", branch: "pr-media", gh: missing.command, now: now.addingTimeInterval(30))
        _ = await branches.check(repo: "you/new", branch: "pr-media", gh: missing.command, now: now.addingTimeInterval(GitHubMediaBranches.absentFor + 1))
        XCTAssertEqual(missing.calls.count, 2)

        // Failures aren't remembered.
        let broken = FakeGH { _ in FakeGH.fail("network down") }
        _ = await branches.check(repo: "you/x", branch: "pr-media", gh: broken.command, now: now)
        _ = await branches.check(repo: "you/x", branch: "pr-media", gh: broken.command, now: now)
        XCTAssertEqual(broken.calls.count, 2)
    }

    func testShareCommitsToTheBranchAndReturnsAPinnedEmbed() async throws {
        let gh = freshRepo()
        let ledger = MediaLedger(url: nil)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0x01])
        let text = try await MediaSharing.shareAnywhere(
            kind: .screenshot, files: [.init(ext: "jpg", data: jpeg)], caption: "Menu, open", label: "you/app@spec/0032-menu",
            folder: "TICKET-0032", name: "after", config: MiniRunConfig(), ledger: ledger,
            branches: GitHubMediaBranches(), gh: gh.command, makeUploader: { throw ToolError("the Worker must not be used") }, now: now
        )
        let embed = "https://github.com/you/app/blob/\(commit)/TICKET-0032/after.jpg?raw=true"
        XCTAssertTrue(text.contains("Markdown: ![Menu, open](\(embed))"), text)
        XCTAssertTrue(text.contains("doesn't expire"), text)
        XCTAssertTrue(text.contains("never upload credentials"), text)
        XCTAssertFalse(text.contains("Before/after"), text)

        let put = try XCTUnwrap(gh.calls.first { $0.contains("PUT") })
        XCTAssertTrue(put.contains("repos/you/app/contents/TICKET-0032/after.jpg"), "\(put)")
        let body = try XCTUnwrap(gh.inputs.first)
        XCTAssertEqual(body["branch"]?.stringValue, "pr-media")
        XCTAssertEqual(body["content"]?.stringValue, jpeg.base64EncodedString())
        XCTAssertEqual(body["message"]?.stringValue, "PR media for TICKET-0032: after.jpg")
        XCTAssertNil(body["sha"], "a new file has no sha")

        let items = await ledger.list(now: now)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.host, .github)
        XCTAssertEqual(items.first?.url, embed)
        XCTAssertEqual(items.first?.label, "you/app@spec/0032-menu")
        XCTAssertFalse(items.first!.isExpired(now: now.addingTimeInterval(400 * 86400)))
    }

    func testDefaultsFolderAndNameAndPairsBeforeWithAfter() async throws {
        let gh = freshRepo()
        let ledger = MediaLedger(url: nil)
        func share(_ name: String?, caption: String?) async throws -> String {
            try await MediaSharing.shareAnywhere(
                kind: .screenshot, files: [.init(ext: "jpg", data: Data([1]))], caption: caption, label: "you/app@feature/x",
                folder: nil, name: name, config: MiniRunConfig(), ledger: ledger,
                branches: GitHubMediaBranches(), gh: gh.command, makeUploader: { throw ToolError("no Worker") }, now: now
            )
        }
        let first = try await share(nil, caption: "Empty state")
        XCTAssertTrue(first.contains("feature-x/empty-state.jpg"), first)

        let before = try await share("before", caption: nil)
        XCTAssertFalse(before.contains("Before/after"), before)
        let after = try await share("after", caption: "New look")
        let base = "https://github.com/you/app/blob/\(commit)/feature-x"
        XCTAssertTrue(after.contains("| ![before](\(base)/before.jpg?raw=true) | ![New look](\(base)/after.jpg?raw=true) |"), after)
    }

    func testReplacingAFileSendsItsSHAAndRetriesWhenTheBranchMoves() async throws {
        let commit = self.commit, blob = self.blob
        final class Counter: @unchecked Sendable { var puts = 0; let lock = NSLock() }
        let counter = Counter()
        let gh = FakeGH { arguments in
            if arguments.contains("PUT") {
                let n = counter.lock.withLock { counter.puts += 1; return counter.puts }
                return n == 1 ? FakeGH.fail("gh: is at abc but expected def (HTTP 409)") : FakeGH.ok(commit)
            }
            return FakeGH.ok(blob)
        }
        let pauses = Pauses()
        let sha = try await GitHubMedia.upload(repo: "you/app", branch: "pr-media", path: "T/after.jpg", data: Data([1]), message: "m",
                                               gh: gh.command, pause: { await pauses.add($0) })
        XCTAssertEqual(sha, commit)
        XCTAssertEqual(counter.puts, 2)
        XCTAssertEqual(gh.inputs.map { $0["sha"]?.stringValue }, [blob, blob])
        let waited = await pauses.all
        XCTAssertEqual(waited, [2])
    }

    func testUploadErrorsSayWhatToDo() async {
        func failure(_ answer: ShellResult) async -> String {
            let gh = FakeGH { arguments in arguments.contains("PUT") ? answer : FakeGH.notFound }
            do {
                _ = try await GitHubMedia.upload(repo: "you/app", branch: "pr-media", path: "T/a.jpg", data: Data([1]), message: "m",
                                                 gh: gh.command, pause: { _ in })
                return "no error"
            } catch {
                return error.localizedDescription
            }
        }
        let readOnly = await failure(FakeGH.fail("gh: Resource not accessible by integration (HTTP 403)"))
        XCTAssertTrue(readOnly.contains("can't push to you/app"), readOnly)
        let signedOut = await failure(FakeGH.fail("gh: Bad credentials (HTTP 401)"))
        XCTAssertTrue(signedOut.contains("gh auth login"), signedOut)
        let missing = await failure(ShellResult(exitCode: 127, stdout: "", stderr: "env: gh: No such file or directory"))
        XCTAssertTrue(missing.contains("brew install gh"), missing)
        let busy = await failure(FakeGH.fail("gh: conflict (HTTP 409)"))
        XCTAssertTrue(busy.contains("Try again"), busy)
    }

    func testAFailedGitHubUploadDoesNotFallBackToTheWorker() async {
        let gh = FakeGH { arguments in
            if arguments.contains(where: { $0.contains("/branches/") }) { return FakeGH.ok("pr-media") }
            if arguments.contains("PUT") { return FakeGH.fail("gh: Resource not accessible (HTTP 403)") }
            return FakeGH.notFound
        }
        let ledger = MediaLedger(url: nil)
        do {
            _ = try await MediaSharing.shareAnywhere(
                kind: .screenshot, files: [.init(ext: "jpg", data: Data([1]))], caption: nil, label: "you/app@main",
                folder: nil, name: nil, config: MiniRunConfig(), ledger: ledger,
                branches: GitHubMediaBranches(), gh: gh.command, makeUploader: { throw ToolError("used the Worker") }, now: now
            )
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("can't push"), error.localizedDescription)
        }
        let count = await ledger.list(now: now).count
        XCTAssertEqual(count, 0)
    }

    func testBadFolderOrNameIsRefusedBeforeUploading() async {
        let gh = freshRepo()
        for (folder, name) in [("../x", "after"), ("T-1", "After")] {
            do {
                _ = try await MediaSharing.shareAnywhere(
                    kind: .screenshot, files: [.init(ext: "jpg", data: Data([1]))], caption: nil, label: "you/app@main",
                    folder: folder, name: name, config: MiniRunConfig(), ledger: MediaLedger(url: nil),
                    branches: GitHubMediaBranches(), gh: gh.command, makeUploader: { throw ToolError("no Worker") }, now: now
                )
                XCTFail("accepted \(folder) \(name)")
            } catch {}
        }
        XCTAssertTrue(gh.calls.isEmpty)
    }

    func testRecordingsCommitOnlyTheGIF() async throws {
        let gh = freshRepo()
        let text = try await MediaSharing.shareAnywhere(
            kind: .recording, files: [.init(ext: "mp4", data: Data([1, 2])), .init(ext: "gif", data: Data([3]))], caption: "Onboarding",
            label: "you/app@main", folder: "T-1", name: "flow", config: MiniRunConfig(), ledger: MediaLedger(url: nil),
            branches: GitHubMediaBranches(), gh: gh.command, makeUploader: { throw ToolError("no Worker") }, now: now
        )
        XCTAssertTrue(text.contains("T-1/flow.gif?raw=true"), text)
        XCTAssertEqual(gh.calls.filter { $0.contains("PUT") }.count, 1)
        XCTAssertEqual(gh.inputs.first?["content"]?.stringValue, Data([3]).base64EncodedString())
    }

    func testWorkerShareSaysItWontEmbedAndHowToOptIn() async throws {
        let worker = FakeMediaWorker()
        let gh = FakeGH { _ in FakeGH.notFound }
        let text = try await MediaSharing.shareAnywhere(
            kind: .screenshot, files: [.init(ext: "jpg", data: Data([1]))], caption: nil, label: "you/app@main",
            folder: nil, name: nil, config: MiniRunConfig(relayURL: "wss://w.example/agent", agentToken: "t"), ledger: MediaLedger(url: nil),
            branches: GitHubMediaBranches(), gh: gh.command,
            makeUploader: { MediaUploader(base: URL(string: "https://w.example")!, token: "t", transport: worker) }, now: now
        )
        XCTAssertTrue(text.contains("not github.com"), text)
        XCTAssertTrue(text.contains("plain link"), text)
        XCTAssertFalse(text.contains("Paste the markdown into the PR description"), text)
        XCTAssertTrue(text.contains("you/app needs a `pr-media` branch"), text)
        XCTAssertTrue(text.contains("Ask the user before creating one"), text)
        XCTAssertEqual(worker.requests.count, 1)
    }

    func testDeleteRemovesTheFileFromTheBranch() async throws {
        let blob = self.blob
        let gh = FakeGH { arguments in arguments.contains("DELETE") ? FakeGH.ok() : FakeGH.ok(blob) }
        let ledger = MediaLedger(url: nil)
        let item = MediaItem(id: MediaItem.newID(), kind: .screenshot, files: [.init(ext: "jpg", bytes: 1)], createdAt: now,
                             expiresAt: MediaItem.neverExpires, repo: "you/app", ref: "main", url: "https://github.com/x",
                             host: .github, branch: "pr-media", path: "T-1/after.jpg", commit: commit)
        await ledger.add(item)
        let text = try await MediaSharing.delete(item, config: MiniRunConfig(), ledger: ledger, gh: gh.command)
        XCTAssertTrue(text.contains("keeps working"), text)
        let delete = try XCTUnwrap(gh.calls.first { $0.contains("DELETE") })
        XCTAssertTrue(delete.contains("repos/you/app/contents/T-1/after.jpg"))
        XCTAssertTrue(delete.contains("sha=\(blob)"))
        XCTAssertTrue(delete.contains("branch=pr-media"))
        let left = await ledger.list(now: now)
        XCTAssertTrue(left.isEmpty)
    }

    func testGitHubItemsDontCountTowardTheWorkerCap() async throws {
        let ledger = MediaLedger(url: nil)
        let big = MediaItem(id: MediaItem.newID(), kind: .screenshot, files: [.init(ext: "jpg", bytes: 2 * 1_048_576)], createdAt: now.addingTimeInterval(-60),
                            expiresAt: MediaItem.neverExpires, repo: "you/app", url: "https://github.com/x", host: .github, branch: "pr-media", path: "a/b.jpg", commit: commit)
        await ledger.add(big)
        let worker = FakeMediaWorker()
        let (_, deleted) = try await MediaSharing.share(
            kind: .screenshot, files: [.init(ext: "jpg", data: Data(count: 512 * 1024))], caption: nil, label: "you/app@main",
            config: MiniRunConfig(mediaStorageLimitMB: 1), ledger: ledger,
            uploader: MediaUploader(base: URL(string: "https://w.example")!, token: "t", transport: worker), now: now
        )
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertFalse(worker.requests.contains { $0.httpMethod == "DELETE" })
    }
}

actor Pauses {
    private(set) var all: [Int] = []
    func add(_ seconds: Int) { all.append(seconds) }
}
