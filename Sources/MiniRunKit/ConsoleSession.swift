import Foundation

/// Whose session has the Mac's screen. Xcode only runs tests (iOS simulator or macOS) for the
/// user on the screen: while the Mac shows the login window, testmanagerd logs "Disallowing
/// automation at loginwindow" and exits, and xcodebuild waits for it forever after the build.
/// That happens when the logged-in user is switched away from (fast user switching, or a Screen
/// Sharing session that ended at the login window), even though builds keep working.
public enum ConsoleSession {
    /// Who owns /dev/console: the user on the screen, or root at the login window. Nil when it
    /// can't be told.
    public static func owner(run: Doctor.Runner = Doctor.shell) async -> String? {
        guard let result = await run("/usr/bin/stat", ["-f", "%Su", "/dev/console"], 10), result.succeeded else { return nil }
        let owner = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return owner.isEmpty ? nil : owner
    }

    /// Why tests can't run for `user` while `owner` has the screen, or nil when they can (or
    /// when the owner isn't known, so a check that can't run never blocks anything).
    public static func problem(owner: String?, user: String) -> String? {
        guard let owner, owner != user else { return nil }
        let screen = owner == "root"
            ? "The Mac is at the login window (\(user) is logged in, but not on the screen)"
            : "\(owner) has the Mac's screen, not \(user) (fast user switching)"
        return screen + ", so macOS won't let Xcode start the test runner: testmanagerd refuses "
            + "(\"Disallowing automation at loginwindow\") and xcodebuild waits forever after the build. "
            + "Builds, swift_test and run_command still work."
    }

    /// What to do about `problem`.
    public static func fix(user: String) -> String {
        "Log in as \(user) at the Mac, or through Screen Sharing, so \(user)'s desktop is on the screen. "
            + "Keep automatic login on (System Settings → Users & Groups) so a restart comes back to it, "
            + "and don't end Screen Sharing with Log Out or Switch User."
    }

    /// The doctor check, or nil when the owner isn't known.
    public static func check(owner: String?, user: String) -> DoctorCheck? {
        guard let owner else { return nil }
        if let problem = problem(owner: owner, user: user) {
            return DoctorCheck(id: "console", title: "Logged in on screen (for tests)", ok: false, detail: problem, fix: fix(user: user))
        }
        return DoctorCheck(id: "console", title: "Logged in on screen (for tests)", ok: true, detail: "\(user)")
    }
}
