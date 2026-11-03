import XCTest
@testable import MiniRunKit

final class BuildCacheTests: XCTestCase {
    let root = "/Users/me/minirun/workspaces"

    func testSlugOfACheckout() {
        XCTAssertEqual(BuildCache.slug(checkout: root + "/you/app", root: root), "you/app")
        XCTAssertEqual(BuildCache.slug(checkout: root + "/you/app@feature-x", root: root), "you/app")
        XCTAssertEqual(BuildCache.slug(checkout: root + "/you/app@a@b/", root: root + "/"), "you/app")
        // Not a checkout under the root: a path build elsewhere, the root itself, an owner folder,
        // a folder inside a checkout, or the hidden mirrors and caches.
        XCTAssertNil(BuildCache.slug(checkout: "/tmp/you/app", root: root))
        XCTAssertNil(BuildCache.slug(checkout: root, root: root))
        XCTAssertNil(BuildCache.slug(checkout: root + "/you", root: root))
        XCTAssertNil(BuildCache.slug(checkout: root + "/you/app/Packages", root: root))
        XCTAssertNil(BuildCache.slug(checkout: root + "/.git-mirrors/you", root: root))
        XCTAssertNil(BuildCache.slug(checkout: root + "/you/@main", root: root))
        XCTAssertNil(BuildCache.slug(checkout: root + "-other/you/app", root: root))
    }

    func testFolders() {
        XCTAssertEqual(BuildCache.compilationCacheDirectory(root: root + "/", slug: "you/app"), root + "/.cache/compilation/you/app")
        let a = BuildCache.packagesDirectory(root: root, slug: "you/app", resolved: Data("pins A".utf8))
        let b = BuildCache.packagesDirectory(root: root, slug: "you/app", resolved: Data("pins B".utf8))
        XCTAssertTrue(a.hasPrefix(root + "/.cache/packages/you/app/"))
        XCTAssertEqual(a, BuildCache.packagesDirectory(root: root, slug: "you/app", resolved: Data("pins A".utf8)), "same pins, same folder")
        XCTAssertNotEqual(a, b, "different pins, different folders")
        XCTAssertEqual((a as NSString).lastPathComponent.count, 16)
    }

    func testHashIsStable() {
        // FNV-1a 64 test vectors.
        XCTAssertEqual(BuildCache.hash(Data()), "cbf29ce484222325")
        XCTAssertEqual(BuildCache.hash(Data("a".utf8)), "af63dc4c8601ec8c")
    }

    func testResolvedFile() {
        XCTAssertEqual(BuildCache.resolvedFile(container: "/c/App.xcworkspace"), "/c/App.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        XCTAssertEqual(BuildCache.resolvedFile(container: "/c/App.xcodeproj/"), "/c/App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        XCTAssertEqual(BuildCache.resolvedFile(container: "/c/Packages/Core"), "/c/Packages/Core/Package.resolved")
        XCTAssertEqual(BuildCache.resolvedFile(container: "/c/Packages/Core/Package.swift"), "/c/Packages/Core/Package.resolved")
    }

    func testArgumentsLeaveTheCallersChoicesAlone() {
        XCTAssertEqual(BuildCache.arguments(extraArgs: [], packagesDirectory: nil, compilationCacheDirectory: nil), [])
        XCTAssertEqual(
            BuildCache.arguments(extraArgs: [], packagesDirectory: "/p", compilationCacheDirectory: "/c"),
            ["-clonedSourcePackagesDirPath", "/p", "COMPILATION_CACHE_ENABLE_CACHING=YES", "COMPILATION_CACHE_CAS_PATH=/c"]
        )
        XCTAssertEqual(
            BuildCache.arguments(extraArgs: ["-clonedSourcePackagesDirPath", "/mine", "COMPILATION_CACHE_ENABLE_CACHING=NO"],
                                 packagesDirectory: "/p", compilationCacheDirectory: "/c"),
            ["COMPILATION_CACHE_CAS_PATH=/c"]
        )
        XCTAssertEqual(
            BuildCache.arguments(extraArgs: ["COMPILATION_CACHE_CAS_PATH=/x"], packagesDirectory: nil, compilationCacheDirectory: "/c"),
            ["COMPILATION_CACHE_ENABLE_CACHING=YES"]
        )
    }

    func testSettingIsOffUnlessSet() throws {
        XCTAssertFalse(MiniRunConfig().sharedBuildCache)
        XCTAssertFalse(try JSONDecoder().decode(MiniRunConfig.self, from: Data("{}".utf8)).sharedBuildCache)
        XCTAssertTrue(try JSONDecoder().decode(MiniRunConfig.self, from: Data(#"{"sharedBuildCache":true}"#.utf8)).sharedBuildCache)
    }
}

final class WorkspaceMirrorTests: XCTestCase {
    func testMirrorPath() {
        XCTAssertEqual(WorkspaceNaming.mirror(root: "/w/", slug: "you/app"), "/w/.git-mirrors/you/app.git")
    }

    func testGitDirectoryOfACloneAndAWorktree() {
        XCTAssertEqual(WorkspaceNaming.gitDirectory(checkout: "/w/you/app", gitFile: nil), "/w/you/app/.git")
        XCTAssertEqual(
            WorkspaceNaming.gitDirectory(checkout: "/w/you/app@x", gitFile: "gitdir: /w/.git-mirrors/you/app.git/worktrees/app@x\n"),
            "/w/.git-mirrors/you/app.git/worktrees/app@x"
        )
        XCTAssertEqual(
            WorkspaceNaming.gitDirectory(checkout: "/w/you/app@x", gitFile: "gitdir: ../../.git-mirrors/you/app.git/worktrees/app@x"),
            "/w/.git-mirrors/you/app.git/worktrees/app@x"
        )
        XCTAssertEqual(WorkspaceNaming.gitDirectory(checkout: "/w/you/app", gitFile: "garbage"), "/w/you/app/.git")
    }

    func testInventoryReadsAWorktreesFetchTime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minirun-inventory-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        let checkout = root + "/you/app@x", gitDir = WorkspaceNaming.mirror(root: root, slug: "you/app") + "/worktrees/app@x"
        try fm.createDirectory(atPath: checkout, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: gitDir, withIntermediateDirectories: true)
        try "gitdir: \(gitDir)\n".write(toFile: checkout + "/.git", atomically: true, encoding: .utf8)
        let old = Date(timeIntervalSince1970: 1_000_000), fetched = Date(timeIntervalSince1970: 2_000_000_000)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: checkout)
        fm.createFile(atPath: gitDir + "/FETCH_HEAD", contents: Data("x".utf8), attributes: [.modificationDate: fetched])
        try fm.setAttributes([.modificationDate: fetched], ofItemAtPath: gitDir + "/FETCH_HEAD")

        let found = WorkspaceInventory.list(root: root)
        XCTAssertEqual(found.map(\.name), ["you/app@x"], "the mirror is a dot folder, not a checkout")
        XCTAssertEqual(found.first?.lastUsed, fetched)
    }
}
