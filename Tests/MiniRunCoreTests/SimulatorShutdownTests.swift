import XCTest
@testable import MiniRunSim

/// CoreSimulator calls a display's framebuffer listeners with nil when the simulator shuts down.
/// With frameworks built before scripts/build-frameworks.sh patched the private header that
/// declares that callback, this crashed the whole process (swift_getObjectType on nil in an
/// FBSimulatorControl thunk), taking `minirun serve` down with every session's jobs.
final class SimulatorShutdownTests: XCTestCase {
    /// Shuts the simulator down: give it a throwaway one, e.g. a clone.
    func testShutdownWithAListenerAttachedDoesNotCrash() async throws {
        guard let udid = ProcessInfo.processInfo.environment["MINIRUN_SHUTDOWN_E2E_UDID"] else {
            throw XCTSkip("Set MINIRUN_SHUTDOWN_E2E_UDID to a booted throwaway simulator; the test shuts it down.")
        }
        // Attached as the live view attaches it, and deliberately left attached.
        let capture = try await SimulatorDriver.shared.screenCapture(udid: udid)
        for _ in 0..<50 where capture.currentSurface() == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertNotNil(capture.currentSurface(), "the listener got the screen")

        let shutdown = Process()
        shutdown.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        shutdown.arguments = ["simctl", "shutdown", udid]
        try shutdown.run()
        shutdown.waitUntilExit()
        XCTAssertEqual(shutdown.terminationStatus, 0)

        // The nil callback arrives as the display goes away, and the listener drops its surface.
        // Getting here at all means it didn't crash.
        for _ in 0..<100 where capture.currentSurface() != nil { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertNil(capture.currentSurface(), "CoreSimulator called the listener with nil, and minirun survived it")
        capture.close()
    }
}
