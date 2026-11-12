import XCTest
@testable import MiniRunKit

final class ConsoleSessionTests: XCTestCase {
    func testSwitchedAwayBlocksOnlyWithoutATestDaemon() {
        let stopped = ConsoleSession.State(owner: "root", user: "deven", testmanagerdRunning: false)
        let problem = stopped.problem ?? ""
        XCTAssertTrue(problem.hasPrefix("The Mac is at the login window and Xcode's test daemon"), problem)
        XCTAssertTrue(problem.contains("Disallowing automation at loginwindow"), problem)
        XCTAssertTrue(stopped.fix.contains("Switch back to deven"), stopped.fix)
        XCTAssertEqual(stopped.check.ok, false)
        XCTAssertEqual(stopped.check.optional, false, "iOS tests need it")

        let running = ConsoleSession.State(owner: "root", user: "deven", testmanagerdRunning: true)
        XCTAssertNil(running.problem, "a testmanagerd started earlier keeps working after switching users")
        XCTAssertEqual(running.check.ok, true)
        XCTAssertTrue(running.check.detail.contains("testmanagerd is running"), running.check.detail)

        XCTAssertNil(ConsoleSession.State(owner: "root", user: "deven", testmanagerdRunning: nil).problem, "unknown never blocks")
        let other = ConsoleSession.State(owner: "chloe", user: "deven", testmanagerdRunning: false)
        XCTAssertTrue(other.problem?.hasPrefix("chloe has the Mac's screen") == true)
    }

    func testOnScreenIsFine() {
        let state = ConsoleSession.State(owner: "deven", user: "deven", testmanagerdRunning: false)
        XCTAssertNil(state.problem)
        XCTAssertEqual(state.check.ok, true)
    }

    func testServiceRunningReadsTheTopLevelState() {
        let refusing = "gui/502/com.apple.testmanagerd = {\n\tactive count = 0\n\tstate = spawn scheduled\n\n\tprogram = /usr/libexec/testmanagerd\n\tendpoints = {\n\t\t\"com.apple.testmanagerd\" = {\n\t\t\tstate = active\n\t\t}\n\t}\n}"
        XCTAssertEqual(ConsoleSession.serviceRunning(refusing), false)
        XCTAssertEqual(ConsoleSession.serviceRunning("x = {\n\tstate = running\n\tpid = 19607\n}"), true)
        XCTAssertNil(ConsoleSession.serviceRunning("nothing here"))
    }

    func testStateFromTheMac() async {
        let state = await ConsoleSession.state(run: { executable, arguments, _ in
            switch executable {
            case "/usr/bin/stat":
                XCTAssertEqual(arguments, ["-f", "%Su", "/dev/console"])
                return ShellResult(exitCode: 0, stdout: "root\n")
            case "/bin/launchctl":
                XCTAssertTrue(arguments.last?.hasSuffix("/com.apple.testmanagerd") == true)
                return ShellResult(exitCode: 0, stdout: "x = {\n\tstate = spawn scheduled\n}")
            default:
                return nil
            }
        }, user: "deven")
        XCTAssertEqual(state, ConsoleSession.State(owner: "root", user: "deven", testmanagerdRunning: false))

        let failed = await ConsoleSession.state(run: { _, _, _ in ShellResult(exitCode: 1, stdout: "") }, user: "deven")
        XCTAssertNil(failed)
        let noLaunchctl = await ConsoleSession.state(run: { executable, _, _ in
            executable == "/usr/bin/stat" ? ShellResult(exitCode: 0, stdout: "root\n") : nil
        }, user: "deven")
        XCTAssertNil(noLaunchctl?.problem)
    }

    func testDoctorReportsAStoppedTestDaemon() async {
        // Linux CI runs as root, so the login window's owner would be this user there.
        let away = NSUserName() == "root" ? "guest" : "root"
        let doctor = Doctor(run: { executable, _, _ in
            switch executable {
            case "/usr/bin/stat": return ShellResult(exitCode: 0, stdout: away + "\n")
            case "/bin/launchctl": return ShellResult(exitCode: 0, stdout: "x = {\n\tstate = spawn scheduled\n}")
            default: return nil
            }
        }, loadFrameworks: { nil })
        let console = await doctor.checks(config: MiniRunConfig()).first { $0.id == "console" }
        XCTAssertEqual(console?.ok, false)
        XCTAssertTrue(console?.fix?.contains("Switch back to") == true)
    }
}
