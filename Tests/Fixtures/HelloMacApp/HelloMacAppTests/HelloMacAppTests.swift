import XCTest

// One trivial test so run_tests has something to run on macOS.
final class HelloMacAppTests: XCTestCase {
    func testArithmetic() {
        XCTAssertEqual(1 + 1, 2)
    }
}
