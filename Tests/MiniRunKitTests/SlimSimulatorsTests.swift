import XCTest
@testable import MiniRunKit

final class SlimSimulatorsTests: XCTestCase {
    func testTheListLeavesTheBootCriticalServicesOn() {
        XCTAssertEqual(Set(SlimSimulators.services).count, SlimSimulators.services.count, "no duplicates")
        for label in SlimSimulators.required {
            XCTAssertFalse(SlimSimulators.services.contains(label), "\(label) must stay on or the boot never finishes")
            XCTAssertFalse(SlimSimulators.disabled(keep: []).contains(label))
        }
    }

    func testKeptServicesStayOn() {
        let off = SlimSimulators.disabled(keep: SlimSimulators.defaultKeep)
        for label in SlimSimulators.defaultKeep { XCTAssertFalse(off.contains(label), label) }
        XCTAssertEqual(off.count, SlimSimulators.services.count - SlimSimulators.defaultKeep.count)
        XCTAssertEqual(SlimSimulators.disabled(keep: []).count, SlimSimulators.services.count)
    }

    func testFileIsNamedAfterTheSimulator() {
        XCTAssertEqual(
            SlimSimulators.disabledPlistURL(udid: "ABC").path,
            "/private/var/tmp/com.apple.CoreSimulator.SimDevice.ABC/disabled.plist"
        )
    }

    func testPlanWritesTheListWithItsMarker() throws {
        guard case .write(let entries) = SlimSimulators.plan(existing: nil, enabled: true, keep: []) else {
            return XCTFail("a simulator with no file gets one")
        }
        XCTAssertEqual(entries[SlimSimulators.marker], true)
        XCTAssertEqual(entries.count, SlimSimulators.services.count + 1)
        XCTAssertEqual(SlimSimulators.plan(existing: entries, enabled: true, keep: []), .leave, "already right")
    }

    func testPlanKeepsEntriesMinirunDidNotWrite() throws {
        let theirs = ["com.example.daemon": true, "com.apple.newsd": false]
        guard case .write(let entries) = SlimSimulators.plan(existing: theirs, enabled: true, keep: []) else {
            return XCTFail()
        }
        XCTAssertEqual(entries["com.example.daemon"], true)
        XCTAssertEqual(entries["com.apple.newsd"], true, "a file without minirun's marker gets the list added")
        XCTAssertEqual(SlimSimulators.plan(existing: theirs, enabled: false, keep: []), .leave, "not minirun's file")
    }

    func testTurningItOffRemovesOnlyMinirunsEntries() {
        guard case .write(var entries) = SlimSimulators.plan(existing: nil, enabled: true, keep: []) else { return XCTFail() }
        XCTAssertEqual(SlimSimulators.plan(existing: entries, enabled: false, keep: []), .remove)
        entries["com.example.daemon"] = true
        XCTAssertEqual(SlimSimulators.plan(existing: entries, enabled: false, keep: []), .write(["com.example.daemon": true]))
    }

    func testKeepingAServiceLaterSwitchesItBackOn() {
        guard case .write(let entries) = SlimSimulators.plan(existing: nil, enabled: true, keep: []) else { return XCTFail() }
        XCTAssertEqual(entries["com.apple.geod"], true)
        guard case .write(let kept) = SlimSimulators.plan(existing: entries, enabled: true, keep: ["com.apple.geod"]) else { return XCTFail() }
        XCTAssertNil(kept["com.apple.geod"])
    }

    func testRequiredServicesAreSwitchedBackOn() {
        let broken = ["com.apple.nanoregistryd": true, "com.apple.sleepd": true]
        guard case .write(let entries) = SlimSimulators.plan(existing: broken, enabled: true, keep: []) else { return XCTFail() }
        XCTAssertNil(entries["com.apple.nanoregistryd"])
        XCTAssertNil(entries["com.apple.sleepd"])
    }

    func testPrepareWritesReadsAndRemovesTheFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let url = SlimSimulators.disabledPlistURL(udid: "U1", tmp: tmp)

        guard case .write = try SlimSimulators.prepare(udid: "U1", enabled: true, keep: SlimSimulators.defaultKeep, tmp: tmp) else { return XCTFail() }
        let written = try XCTUnwrap(SlimSimulators.read(url))
        XCTAssertEqual(written["com.apple.siriactionsd"], true)
        XCTAssertNil(written["com.apple.geod"])
        XCTAssertEqual(try SlimSimulators.prepare(udid: "U1", enabled: true, keep: SlimSimulators.defaultKeep, tmp: tmp), .leave)

        XCTAssertEqual(try SlimSimulators.prepare(udid: "U1", enabled: false, keep: [], tmp: tmp), .remove)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try SlimSimulators.prepare(udid: "U1", enabled: false, keep: [], tmp: tmp), .leave)
    }

    func testConfigDefaultsToSlimWithTheFrameworkServicesKept() throws {
        let config = try JSONDecoder().decode(MiniRunConfig.self, from: Data("{}".utf8))
        XCTAssertTrue(config.slimSimulators)
        XCTAssertEqual(config.slimSimulatorKeep, SlimSimulators.defaultKeep)
        let off = try JSONDecoder().decode(MiniRunConfig.self, from: Data(#"{"slimSimulators":false,"slimSimulatorKeep":[]}"#.utf8))
        XCTAssertFalse(off.slimSimulators)
        XCTAssertEqual(off.slimSimulatorKeep, [])
        XCTAssertEqual(MiniRunConfig(), config)
    }
}
