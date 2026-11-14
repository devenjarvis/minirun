import XCTest
@testable import MiniRunKit

final class TestDaemonKeeperTests: XCTestCase {
    func testStartsOnScreenOrWhileTheDaemonLives() {
        XCTAssertTrue(TestDaemonKeeper.canStart(.init(owner: "deven", user: "deven", testmanagerdRunning: nil)))
        XCTAssertTrue(TestDaemonKeeper.canStart(.init(owner: "root", user: "deven", testmanagerdRunning: true)),
                      "a running testmanagerd takes new sessions after a switch")
        XCTAssertFalse(TestDaemonKeeper.canStart(.init(owner: "root", user: "deven", testmanagerdRunning: false)),
                       "a new one refuses at the login window, and xcodebuild would wait forever")
        XCTAssertFalse(TestDaemonKeeper.canStart(.init(owner: "chloe", user: "deven", testmanagerdRunning: nil)))
        XCTAssertTrue(TestDaemonKeeper.canStart(nil), "a console that can't be read never blocks")
    }

    func testBackoffGrowsAfterQuickExitsAndResetsAfterAHold() {
        var backoff = TestDaemonKeeper.Backoff()
        XCTAssertEqual(backoff.delay(afterRunOf: 3), 60)
        XCTAssertEqual(backoff.delay(afterRunOf: 3), 120)
        XCTAssertEqual(backoff.delay(afterRunOf: 3), 240)
        for _ in 0..<10 { _ = backoff.delay(afterRunOf: 3) }
        XCTAssertEqual(backoff.delay(afterRunOf: 3), 30 * 60, "capped at 30 minutes")
        XCTAssertEqual(backoff.delay(afterRunOf: 12 * 3600), 5, "a full hold starts again at once")
        XCTAssertEqual(backoff.delay(afterRunOf: 3), 60)
    }

    func testPackageHoldsInTheTestTheMarkerNames() throws {
        let files = TestDaemonKeeper.packageFiles(holdSeconds: 42)
        let test = try XCTUnwrap(files["Tests/MiniRunTestDaemonKeeperTests/HoldTests.swift"])
        XCTAssertTrue(test.contains("Thread.sleep(forTimeInterval: 42)"), test)
        // xcodebuild prints "Test Case '-[MiniRunTestDaemonKeeperTests.HoldTests testHoldTestDaemon]' started."
        XCTAssertTrue(test.contains("func testHoldTestDaemon()"))
        XCTAssertTrue("Test Case '-[MiniRunTestDaemonKeeperTests.HoldTests testHoldTestDaemon]' started.".contains(TestDaemonKeeper.holdingMarker))
        // SwiftPM names a package's all-targets scheme "<name>-Package".
        let manifest = try XCTUnwrap(files["Package.swift"])
        XCTAssertTrue(manifest.contains("name: \"MiniRunTestDaemonKeeper\""))
        XCTAssertEqual(TestDaemonKeeper.scheme, "MiniRunTestDaemonKeeper-Package")
    }

    func testWritePackageOnlyWritesChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keeper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(try TestDaemonKeeper.writePackage(at: directory, holdSeconds: 5))
        XCTAssertFalse(try TestDaemonKeeper.writePackage(at: directory, holdSeconds: 5))
        XCTAssertTrue(try TestDaemonKeeper.writePackage(at: directory, holdSeconds: 6))
    }

    func testArguments() {
        let args = TestDaemonKeeper.arguments(directory: URL(fileURLWithPath: "/k"))
        XCTAssertEqual(Array(args.prefix(6)), ["xcodebuild", "test", "-scheme", "MiniRunTestDaemonKeeper-Package", "-destination", "platform=macOS"])
        XCTAssertTrue(args.contains("/k/DerivedData"))
    }

    func testSettingDefaultsOn() throws {
        XCTAssertTrue(MiniRunConfig().keepTestDaemon)
        XCTAssertTrue(try JSONDecoder().decode(MiniRunConfig.self, from: Data("{}".utf8)).keepTestDaemon)
        XCTAssertFalse(try JSONDecoder().decode(MiniRunConfig.self, from: Data(#"{"keepTestDaemon":false}"#.utf8)).keepTestDaemon)
    }
}
