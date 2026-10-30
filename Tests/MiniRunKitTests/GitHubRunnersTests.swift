import Foundation
import XCTest
@testable import MiniRunKit

final class GitHubRunnersTests: XCTestCase {
    func testInstalledReadsWhatTheScriptLeft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runners-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default

        // A full install: repo, registration (with a BOM, as config.sh writes it) and service.
        let full = root + "/you-app"
        try fm.createDirectory(atPath: full, withIntermediateDirectories: true)
        try "you/app\n".write(toFile: full + "/.minirun-repo", atomically: true, encoding: .utf8)
        var runner = Data([0xEF, 0xBB, 0xBF])
        runner.append(Data(#"{"agentId": 12, "agentName": "mini-minirun", "gitHubUrl": "https://github.com/you/app"}"#.utf8))
        fm.createFile(atPath: full + "/.runner", contents: runner)
        try "/Users/me/Library/LaunchAgents/actions.runner.you-app.mini-minirun.plist\n".write(toFile: full + "/.service", atomically: true, encoding: .utf8)

        // An interrupted install: extracted, never registered.
        let partial = root + "/you-other"
        try fm.createDirectory(atPath: partial, withIntermediateDirectories: true)
        try "you/other".write(toFile: partial + "/.minirun-repo", atomically: true, encoding: .utf8)

        fm.createFile(atPath: root + "/stray-file", contents: Data())

        let runners = GitHubRunners.installed(root: root)
        XCTAssertEqual(runners.map(\.repo), ["you/app", "you/other"])
        XCTAssertEqual(runners[0].name, "mini-minirun")
        XCTAssertEqual(runners[0].serviceLabel, "actions.runner.you-app.mini-minirun")
        XCTAssertTrue(runners[0].configured)
        XCTAssertFalse(runners[1].configured)
        XCTAssertEqual(runners[1].badge, .broken)
        XCTAssertFalse(runners[1].canStart)
        XCTAssertEqual(GitHubRunners.installed(root: root + "/missing"), [])
    }

    func testLaunchctlState() {
        let output = "gui/501/actions.runner.x = {\n\tactive count = 1\n\tstate = running\n\n\tendpoints = {\n\t\tstate = waiting\n\t}\n}\n"
        XCTAssertEqual(GitHubRunners.service(launchctlExitCode: 0, output: output), .running)
        XCTAssertEqual(GitHubRunners.service(launchctlExitCode: 0, output: "\tstate = not running\n"), .stopped)
        XCTAssertEqual(GitHubRunners.service(launchctlExitCode: 0, output: "\tstate = spawn scheduled\n"), .other("spawn scheduled"))
        XCTAssertEqual(GitHubRunners.service(launchctlExitCode: 113, output: "Could not find service"), .stopped, "not loaded")
    }

    func testRemoteMatchesByName() {
        let json = Data(#"{"total_count": 2, "runners": [{"id": 1, "name": "other-mac", "status": "online", "busy": true}, {"id": 2, "name": "mini-minirun", "status": "online", "busy": false}]}"#.utf8)
        XCTAssertEqual(GitHubRunners.remote(named: "mini-minirun", in: json), .init(online: true, busy: false))
        XCTAssertNil(GitHubRunners.remote(named: "gone", in: json))
        XCTAssertNil(GitHubRunners.remote(named: "mini-minirun", in: Data("not json".utf8)))
    }

    func testBadgeAndActions() {
        var runner = GitHubRunner(repo: "you/app", directory: "/r/you-app", configured: true, name: "mini-minirun", serviceLabel: "actions.runner.x")
        runner.service = .running
        XCTAssertEqual(runner.badge, .running, "running, GitHub not asked yet")
        runner.remote = .init(online: true, busy: true)
        XCTAssertEqual(runner.badge, .busy)
        XCTAssertEqual(runner.detail, "mini-minirun · service running · GitHub: online, running a job")
        XCTAssertTrue(runner.canStop)
        XCTAssertFalse(runner.canStart)
        runner.remote = .init(online: false, busy: false)
        XCTAssertEqual(runner.badge, .offline)
        runner.service = .stopped
        XCTAssertEqual(runner.badge, .stopped)
        XCTAssertTrue(runner.canStart)
        XCTAssertFalse(runner.canStop)
        runner.service = .none
        XCTAssertEqual(runner.badge, .broken)
        XCTAssertEqual(runner.settingsURL, "https://github.com/you/app/settings/actions/runners")
        XCTAssertEqual(runner.diagnosticsPath, "/r/you-app/_diag")
    }

    func testRepoInput() {
        XCTAssertEqual(GitHubRunners.normalizeRepo(" you/app "), "you/app")
        XCTAssertEqual(GitHubRunners.normalizeRepo("https://github.com/you/app.git"), "you/app")
        XCTAssertEqual(GitHubRunners.normalizeRepo("github.com/you/app/"), "you/app")
        XCTAssertTrue(GitHubRunners.isValidRepo("you/my.app-2"))
        XCTAssertFalse(GitHubRunners.isValidRepo("you"))
        XCTAssertFalse(GitHubRunners.isValidRepo("you/app; rm -rf ~"))
        XCTAssertFalse(GitHubRunners.isValidRepo("you/app/extra"))
    }

    func testCommands() {
        XCTAssertEqual(GitHubRunners.Command.install(repo: "you/app", allowPublic: false).arguments, ["install", "you/app"])
        XCTAssertEqual(GitHubRunners.Command.install(repo: "you/app", allowPublic: true).arguments, ["install", "you/app", "--allow-public"])
        XCTAssertEqual(GitHubRunners.Command.uninstall(repo: "you/app").arguments, ["uninstall", "you/app"])
        XCTAssertEqual(GitHubRunners.Command.stop(repo: "you/app").repo, "you/app")
    }

    func testSuggestedCommand() {
        let output = "==> Checking you/app\nerror: gh isn't logged in to github.com.\nRun: gh auth login --scopes repo\nYou are not logged in"
        XCTAssertEqual(GitHubRunners.suggestedCommand(in: output), "gh auth login --scopes repo")
        XCTAssertEqual(GitHubRunners.suggestedCommand(in: "error: gh isn't installed. Run: brew install gh && gh auth login"), nil, "only whole lines")
        XCTAssertNil(GitHubRunners.suggestedCommand(in: "Run: rm -rf ~"), "only gh and brew")
    }
}
