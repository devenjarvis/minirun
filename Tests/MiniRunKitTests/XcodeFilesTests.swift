import Foundation
import XCTest
@testable import MiniRunKit

final class XcodeFilesTests: XCTestCase {
    private var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "xcodefiles-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func write(_ path: String, _ text: String = "") throws {
        let full = dir + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: full, atomically: true, encoding: .utf8)
    }

    func testSharedSchemesOfAProject() throws {
        try write("App.xcodeproj/xcshareddata/xcschemes/App.xcscheme")
        try write("App.xcodeproj/xcshareddata/xcschemes/AppTests.xcscheme")
        try write("App.xcodeproj/xcshareddata/xcschemes/notes.txt")
        try write("App.xcodeproj/xcuserdata/me.xcuserdatad/xcschemes/Mine.xcscheme")
        XCTAssertEqual(XcodeFiles.sharedSchemes(container: dir + "/App.xcodeproj"), ["App", "AppTests"])
        try write("Bare.xcodeproj/project.pbxproj")
        XCTAssertEqual(XcodeFiles.sharedSchemes(container: dir + "/Bare.xcodeproj"), [], "none shared: ask xcodebuild")
    }

    func testSharedSchemesOfAWorkspaceIncludeItsProjects() throws {
        try write("App.xcworkspace/contents.xcworkspacedata", """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version = "1.0">
           <FileRef location = "group:ios/App.xcodeproj"></FileRef>
           <FileRef location = "container:Pods/Pods.xcodeproj"></FileRef>
           <FileRef location = "group:README.md"></FileRef>
        </Workspace>
        """)
        try write("App.xcworkspace/xcshareddata/xcschemes/All.xcscheme")
        try write("ios/App.xcodeproj/xcshareddata/xcschemes/App.xcscheme")
        try write("Pods/Pods.xcodeproj/xcshareddata/xcschemes/Pods-App.xcscheme")
        XCTAssertEqual(XcodeFiles.sharedSchemes(container: dir + "/App.xcworkspace"), ["All", "App", "Pods-App"])
    }

    func testWorkspaceProjects() {
        let xml = #"<Workspace><FileRef location = "group:a/A.xcodeproj"/><FileRef location="absolute:/x/B.xcodeproj"/><FileRef location = "self:"/></Workspace>"#
        XCTAssertEqual(XcodeFiles.workspaceProjects(xml, workspace: "/w/W.xcworkspace"), ["/w/a/A.xcodeproj", "/x/B.xcodeproj"])
    }

    func testOrphanedDerivedData() throws {
        let root = dir + "/workspaces"
        try write("workspaces/me/app@live/App.xcodeproj/project.pbxproj")
        func folder(_ name: String, project: String?) throws {
            try write("DD/\(name)/Logs/x")
            guard let project else { return }
            let plist = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": project], format: .xml, options: 0)
            FileManager.default.createFile(atPath: dir + "/DD/\(name)/info.plist", contents: plist)
        }
        try folder("App-gone", project: root + "/me/app@gone/App.xcodeproj")
        try folder("App-live", project: root + "/me/app@live/App.xcodeproj")
        try folder("Mine-elsewhere", project: dir + "/elsewhere/Mine.xcodeproj")
        try folder("App-unknown", project: nil)
        XCTAssertEqual(XcodeFiles.orphanedDerivedData(dir + "/DD", workspaceRoot: root), [dir + "/DD/App-gone"])
    }
}
