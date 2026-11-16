import XCTest
@testable import MiniRunKit

final class SimulatorHandOverTests: XCTestCase {
    func testRepoIsTheLabelBeforeTheRef() {
        XCTAssertEqual(SimulatorHandOver.repo("you/app@main"), "you/app")
        XCTAssertEqual(SimulatorHandOver.repo("you/app@ci/feature@2"), "you/app")
        XCTAssertEqual(SimulatorHandOver.repo("demo"), "demo")
    }

    func testAnotherRepoClearsTheLastSession() {
        let claim = SimulatorClaim(label: "you/app@main", bundleID: "com.you.app")
        XCTAssertEqual(
            SimulatorHandOver.cleanup(previous: claim, to: "you/other@main"),
            .init(bundleID: "com.you.app", from: "you/app@main")
        )
    }

    func testTheSameRepoKeepsItsData() {
        let claim = SimulatorClaim(label: "you/app@main", bundleID: "com.you.app")
        XCTAssertNil(SimulatorHandOver.cleanup(previous: claim, to: "you/app@feature"), "switching branches keeps the app's data")
        XCTAssertNil(SimulatorHandOver.cleanup(previous: claim, to: "you/app@ci/feature"))
    }

    func testAFreedSimulatorRemembersWhoHadIt() async {
        let store = SimulatorClaimStore(url: nil)
        await store.reserve("U1", for: "you/app@main")
        await store.noteApp("U1", bundleID: "com.you.app")
        await store.unreserve("U1")
        let claim = await store.claim("U1")
        XCTAssertNil(claim?.label)
        XCTAssertEqual(claim?.lastLabel, "you/app@main")
        XCTAssertNil(SimulatorHandOver.cleanup(previous: claim, to: "you/app@other"))
        XCTAssertEqual(SimulatorHandOver.cleanup(previous: claim, to: "them/app@main"), .init(bundleID: "com.you.app", from: "you/app@main"))
    }

    func testNothingToClearOnASimulatorNoSessionUsed() {
        XCTAssertNil(SimulatorHandOver.cleanup(previous: nil, to: "you/app@main"))
        XCTAssertNil(SimulatorHandOver.cleanup(previous: SimulatorClaim(), to: "you/app@main"), "only touched, by a tap say")
        XCTAssertEqual(
            SimulatorHandOver.cleanup(previous: SimulatorClaim(bundleID: "com.x"), to: "you/app@main"),
            .init(bundleID: "com.x", from: nil),
            "an app with no known owner is cleared"
        )
    }

    func testForgetAppDropsTheBundleID() async {
        let store = SimulatorClaimStore(url: nil)
        await store.noteApp("U1", bundleID: "com.you.app")
        await store.forgetApp("U1")
        let claim = await store.claim("U1")
        XCTAssertNil(claim?.bundleID)
    }
}
