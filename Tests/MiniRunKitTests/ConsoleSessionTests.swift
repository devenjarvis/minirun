import XCTest
@testable import MiniRunKit

final class ConsoleSessionTests: XCTestCase {
    func testLoginWindowIsAProblemWithAFix() {
        let problem = ConsoleSession.problem(owner: "root", user: "deven") ?? ""
        XCTAssertTrue(problem.contains("login window"), problem)
        XCTAssertTrue(problem.contains("Disallowing automation at loginwindow"), problem)
        XCTAssertTrue(ConsoleSession.fix(user: "deven").contains("Log in as deven"))

        let other = ConsoleSession.problem(owner: "guest", user: "deven") ?? ""
        XCTAssertTrue(other.hasPrefix("guest has the Mac's screen"), other)
    }

    func testOnScreenOrUnknownIsFine() {
        XCTAssertNil(ConsoleSession.problem(owner: "deven", user: "deven"))
        XCTAssertNil(ConsoleSession.problem(owner: nil, user: "deven"), "a check that can't run never blocks tests")
        XCTAssertNil(ConsoleSession.check(owner: nil, user: "deven"))
    }

    func testOwnerFromStat() async {
        let owner = await ConsoleSession.owner(run: { executable, arguments, _ in
            XCTAssertEqual(executable, "/usr/bin/stat")
            XCTAssertEqual(arguments, ["-f", "%Su", "/dev/console"])
            return ShellResult(exitCode: 0, stdout: "root\n")
        })
        XCTAssertEqual(owner, "root")
        let failed = await ConsoleSession.owner(run: { _, _, _ in ShellResult(exitCode: 1, stdout: "") })
        XCTAssertNil(failed)
    }

    func testDoctorReportsTheLoginWindow() async {
        let doctor = Doctor(run: { executable, _, _ in
            executable == "/usr/bin/stat" ? ShellResult(exitCode: 0, stdout: "root\n") : nil
        }, loadFrameworks: { nil })
        let checks = await doctor.checks(config: MiniRunConfig())
        let console = checks.first { $0.id == "console" }
        XCTAssertEqual(console?.ok, false)
        XCTAssertEqual(console?.optional, false, "iOS tests need it")
        XCTAssertTrue(console?.fix?.contains("automatic login") == true)

        let fine = await Doctor(run: { executable, _, _ in
            executable == "/usr/bin/stat" ? ShellResult(exitCode: 0, stdout: NSUserName() + "\n") : nil
        }, loadFrameworks: { nil }).checks(config: MiniRunConfig())
        XCTAssertEqual(fine.first { $0.id == "console" }?.ok, true)
    }
}
