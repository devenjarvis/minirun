import Foundation

public enum MiniRun {
    /// The version of minirun: the daemon, the CLI and the menu bar app. Release tags are this with
    /// a "v" in front, and App/project.yml's MARKETING_VERSION and worker/src/version.ts's VERSION
    /// must match it.
    public static let version = "0.2.0"

    /// The GitHub repository releases are published from.
    public static let repository = "devenjarvis/minirun"
}
