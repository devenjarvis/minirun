import Foundation
import MiniRunKit

/// What the control socket, `minirun status` and the menu bar app need from the registry for
/// macOS apps. The bodies are placeholders until the Mac driver (MiniRunMac) is wired in.
extension ToolRegistry {
    /// The Mac apps minirun launched, for `ServeStatus.macApps`: every `MacAppStore` session as
    /// `ServeStatus.MacApp(session, busy:, viewerURL: config.viewerURL(device: session.id))`.
    func macAppStatus() async -> [ServeStatus.MacApp] {
        // TODO(integration): read the registry's MacAppStore, mark busy ones (job or live view).
        []
    }

    /// The daemon's own macOS app permissions, for `ServeStatus.macPermissions` and the doctor's
    /// macPermissions closure. Nil when they can't be read.
    func macPermissionReport() async -> MacPermissionReport? {
        // TODO(integration): from MacAppDriver.shared.permissions(), with binaryPath set to
        // this process's executable (CommandLine.arguments[0] resolved, or Bundle.main.executablePath).
        nil
    }

    /// `request_mac_permissions`: prompts for Screen Recording and Accessibility as this process,
    /// so System Settings lists the daemon. Returns what to do next, for the user.
    func requestMacPermissions() async throws -> String {
        // TODO(integration): MacAppDriver.shared.requestPermissions(), then report what's still
        // missing (the Screen Recording grant only takes effect after minirun serve restarts).
        throw ToolError("macOS app support isn't available in this build of minirun yet.")
    }

    /// `quit_mac_app`: quits the Mac app with this id if minirun launched it and it's running
    /// (polite terminate, then force after a grace period). Never touches other processes.
    func quitMacApp(id: String) async throws -> String {
        // TODO(integration): look the session up in the MacAppStore, MacAppDriver.terminate(pid:),
        // markExited, and say "Quit Fetch (mac-3f9a2c, you/fetch@main)."
        throw ToolError("macOS app support isn't available in this build of minirun yet.")
    }

    /// `activate_mac_app`: brings the Mac app with this id to the front.
    func activateMacApp(id: String) async throws -> String {
        // TODO(integration): NSRunningApplication(processIdentifier:)?.activate() for its pid.
        throw ToolError("macOS app support isn't available in this build of minirun yet.")
    }
}
