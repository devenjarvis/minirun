import Foundation
import MiniRunKit
import MiniRunMac

/// What the control socket, `minirun status` and the menu bar app need from the registry for
/// macOS apps.
extension ToolRegistry {
    /// The Mac apps minirun launched, for `ServeStatus.macApps`. Busy ones have a job running or
    /// someone watching them live.
    func macAppStatus() async -> [ServeStatus.MacApp] {
        let busy = await activity.busy
        return await refreshedMacApps().map { session in
            ServeStatus.MacApp(session, busy: busy.contains(session.id), viewerURL: config.viewerURL(device: session.id))
        }
    }

    /// This process's macOS app permissions, for `ServeStatus.macPermissions`, the doctor and
    /// host_info. macOS grants them per program, so it names this executable.
    func macPermissionReport() async -> MacPermissionReport? {
        let status = await MacAppDriver.shared.permissions()
        let binary = (Bundle.main.executablePath ?? CommandLine.arguments.first).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        return MacPermissionReport(screenRecording: status.screenRecording, accessibility: status.accessibility, hasDisplay: status.hasDisplay, binaryPath: binary)
    }

    /// `request_mac_permissions`: prompts for Screen Recording and Accessibility as this process,
    /// so System Settings lists the daemon. Returns what to do next, for the user.
    func requestMacPermissions() async throws -> String {
        await MacAppDriver.shared.requestPermissions()
        guard let report = await macPermissionReport() else { throw ToolError("Couldn't read the macOS permissions.") }
        return MacToolSupport.permissionRequestMessage(report)
    }

    /// `quit_mac_app` and terminate_app: quits the Mac app with this id if minirun launched it and
    /// it's running (polite terminate, then force after 5 seconds). Only its recorded pid, and
    /// only while that pid still runs the app's executable.
    func quitMacApp(id: String) async throws -> String {
        guard let session = await macApps.session(id) else { throw ToolError(MacToolSupport.unknownApp(id, known: await refreshedMacApps())) }
        let who = [session.id, session.label].compactMap { $0 }.joined(separator: ", ")
        guard let pid = session.pid, MacAppDriver.isRunning(pid: pid, executablePath: session.executablePath) else {
            await macApps.markExited(session.id)
            return "\(session.name) (\(who)) isn't running."
        }
        await MacAppDriver.shared.terminate(pid: pid, grace: 5, executablePath: session.executablePath)
        await macApps.markExited(session.id)
        await macApps.touch(session.id)
        return "Quit \(session.name) (\(who))."
    }

    /// `activate_mac_app`: brings the Mac app with this id, and its main window, to the front.
    func activateMacApp(id: String) async throws -> String {
        guard let session = await macApps.session(id) else { throw ToolError(MacToolSupport.unknownApp(id, known: await refreshedMacApps())) }
        guard let pid = session.pid, MacAppDriver.isRunning(pid: pid, executablePath: session.executablePath) else {
            throw ToolError(MacToolSupport.notRunning(session))
        }
        let window = try? await MacAppDriver.shared.window(pid: pid, .main)
        await MacAppDriver.shared.bringToFront(pid: pid, window: window)
        return "Brought \(session.name) to the front."
    }
}
