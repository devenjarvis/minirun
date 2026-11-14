import Foundation

/// Keeps Xcode's test daemon (testmanagerd) from quitting, so tests keep working after the user
/// switches away from the Mac's screen.
///
/// macOS only starts testmanagerd for the user on the screen (see `ConsoleSession`). One already
/// running keeps serving tests after a switch to another user or the login window, until it
/// quits. Its LaunchAgent has `EnablePressuredExit`: launchd ends it whenever it holds no XPC
/// transactions and memory is tight, as it is during big builds. After that, every test run
/// waits forever until someone comes back to the screen.
///
/// An open test session holds two transactions in testmanagerd ("com.apple.dt.xctest.xctestsession"
/// and "com.apple.testmanangerd.harness-session"), so minirun keeps one open: `xcodebuild test` of
/// a tiny macOS package whose only test sleeps for `holdSeconds`, started again whenever it ends.
/// Other tests run alongside it. It can't stop a deliberate SIGTERM (a restart, logout or Xcode
/// update), since testmanagerd then closes its sessions itself.
public enum TestDaemonKeeper {
    /// How long one keeper run holds its session before it ends and is started again.
    public static let holdSeconds = 12 * 60 * 60
    /// The keeper's test prints its "started" line within this long, or the run is stopped.
    public static let startTimeout: TimeInterval = 10 * 60
    /// The line xcodebuild prints once the keeper's session is open.
    public static let holdingMarker = "testHoldTestDaemon]' started"
    public static let scheme = "MiniRunTestDaemonKeeper-Package"

    /// Where the package and its DerivedData live.
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/minirun/test-daemon-keeper", isDirectory: true)
    }

    /// The package's files, by path relative to `directory`.
    public static func packageFiles(holdSeconds: Int = holdSeconds) -> [String: String] {
        [
            "Package.swift": """
            // swift-tools-version:5.10
            // Written by minirun: keeps Xcode's test daemon running (see TestDaemonKeeper.swift).
            import PackageDescription

            let package = Package(
                name: "MiniRunTestDaemonKeeper",
                platforms: [.macOS(.v14)],
                targets: [
                    .target(name: "MiniRunTestDaemonKeeper"),
                    .testTarget(name: "MiniRunTestDaemonKeeperTests", dependencies: ["MiniRunTestDaemonKeeper"]),
                ]
            )

            """,
            "Sources/MiniRunTestDaemonKeeper/Keeper.swift": "public enum MiniRunTestDaemonKeeper {}\n",
            "Tests/MiniRunTestDaemonKeeperTests/HoldTests.swift": """
            import XCTest

            /// Holds a test session open in testmanagerd so launchd doesn't end it. Stopping it is safe.
            final class HoldTests: XCTestCase {
                func testHoldTestDaemon() {
                    Thread.sleep(forTimeInterval: \(holdSeconds))
                }
            }

            """,
        ]
    }

    /// Writes the package files that differ from what's on disk. Returns whether any changed.
    @discardableResult
    public static func writePackage(at directory: URL = directory, holdSeconds: Int = holdSeconds) throws -> Bool {
        var changed = false
        for (path, contents) in packageFiles(holdSeconds: holdSeconds) {
            let url = directory.appendingPathComponent(path)
            if (try? String(contentsOf: url, encoding: .utf8)) == contents { continue }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            changed = true
        }
        return changed
    }

    /// The `xcodebuild` arguments, run from `directory`.
    public static func arguments(directory: URL = directory) -> [String] {
        ["xcodebuild", "test", "-scheme", scheme, "-destination", "platform=macOS",
         "-derivedDataPath", directory.appendingPathComponent("DerivedData").path,
         "-skipPackagePluginValidation", "-skipMacroValidation"]
    }

    /// Whether a keeper can start now. Off the screen, only while testmanagerd is still running:
    /// a new session reaches it then, but one started with no testmanagerd would wait forever.
    public static func canStart(_ console: ConsoleSession.State?) -> Bool {
        guard let console else { return true }
        return console.onScreen || console.testmanagerdRunning == true
    }

    /// How long to wait before starting again after a run that lasted `ranFor` seconds. A run
    /// that ended quickly (a failed build, say) waits longer each time, up to 30 minutes.
    public struct Backoff: Equatable, Sendable {
        public private(set) var failures = 0

        public init() {}

        public mutating func delay(afterRunOf ranFor: TimeInterval) -> TimeInterval {
            if ranFor >= 10 * 60 {
                failures = 0
                return 5
            }
            failures += 1
            return min(30 * 60, 60 * pow(2, Double(failures - 1)))
        }
    }
}
