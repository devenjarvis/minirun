import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Whether Xcode can start tests while the user isn't on the Mac's screen.
///
/// Tests (iOS simulator or macOS) go through the user's testmanagerd. A testmanagerd that starts
/// while the Mac shows the login window logs "Disallowing automation at loginwindow" and exits;
/// launchd starts another 10 s later, and xcodebuild waits for one forever after the build. One
/// that started while the user was on the screen keeps working after a switch to the login window
/// (Fast User Switching, so others can use the Mac), until it quits: launchd ends it when it's idle
/// and memory is tight. So tests work with the user switched away only while that testmanagerd
/// lives, and `TestDaemonKeeper` keeps it from going idle.
public enum ConsoleSession {
    public struct State: Equatable, Sendable {
        /// Who owns /dev/console: the user on the screen, or root at the login window.
        public var owner: String
        /// The user minirun runs as.
        public var user: String
        /// The user's testmanagerd is running. Nil when it can't be told.
        public var testmanagerdRunning: Bool?

        public init(owner: String, user: String, testmanagerdRunning: Bool?) {
            self.owner = owner
            self.user = user
            self.testmanagerdRunning = testmanagerdRunning
        }

        public var onScreen: Bool { owner == user }

        /// Why tests can't start, or nil when they can (or it can't be told, so a check that
        /// can't run never blocks anything).
        public var problem: String? {
            guard !onScreen, testmanagerdRunning == false else { return nil }
            let screen = owner == "root" ? "The Mac is at the login window" : "\(owner) has the Mac's screen"
            return screen + " and Xcode's test daemon (testmanagerd) isn't running. macOS only starts it for the user "
                + "on the screen: started now it refuses (\"Disallowing automation at loginwindow\") and xcodebuild "
                + "would wait forever after the build. One started while \(user) was on the screen keeps working after "
                + "switching users, and minirun keeps it running, but it was stopped (a restart, logout or Xcode update, "
                + "or minirun's keepTestDaemon setting is off). Builds, swift_test and run_command still work."
        }

        /// What to do about `problem`.
        public var fix: String {
            "Switch back to \(user) on the Mac (or through Screen Sharing) for a minute: minirun then starts "
                + "testmanagerd and keeps it running, so tests keep working after you switch users again."
        }

        /// The doctor row.
        public var check: DoctorCheck {
            let title = "Test daemon (for tests)"
            if let problem {
                return DoctorCheck(id: "console", title: title, ok: false, detail: problem, fix: fix)
            }
            if onScreen {
                return DoctorCheck(id: "console", title: title, ok: true, detail: "\(user) is on the screen")
            }
            let screen = owner == "root" ? "the Mac is at the login window" : "\(owner) has the screen"
            return DoctorCheck(id: "console", title: title, ok: true,
                               detail: "\(screen), but testmanagerd is running (minirun keeps it running), so tests work")
        }
    }

    /// Reads the state, or nil when the console owner can't be read.
    public static func state(run: Doctor.Runner = Doctor.shell, user: String = NSUserName()) async -> State? {
        guard let stat = await run("/usr/bin/stat", ["-f", "%Su", "/dev/console"], 10), stat.succeeded else { return nil }
        let owner = stat.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty else { return nil }
        guard owner != user else { return State(owner: owner, user: user, testmanagerdRunning: nil) }
        let service = await run("/bin/launchctl", ["print", "gui/\(getuid())/com.apple.testmanagerd"], 10)
        return State(owner: owner, user: user, testmanagerdRunning: service.flatMap { $0.succeeded ? serviceRunning($0.stdout) : nil })
    }

    /// Whether `launchctl print` output says the service is running: its own `state = running`,
    /// a single tab in (nested blocks have their own `state` lines).
    static func serviceRunning(_ output: String) -> Bool? {
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) where line.hasPrefix("\tstate = ") {
            return line.dropFirst("\tstate = ".count).trimmingCharacters(in: .whitespaces) == "running"
        }
        return nil
    }
}
