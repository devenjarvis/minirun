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
        let recording = await recordings.recording
        return await refreshedMacApps().map { session in
            ServeStatus.MacApp(session, busy: busy.contains(session.id), viewerURL: config.viewerURL(device: session.id),
                               recording: recording.contains(session.id))
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
        // Under the app's launch lock, so a launch for this id can't start a copy in between.
        return try await macLaunches.withLock(session.id) { () async throws -> String in
            // Read it again inside the lock: a launch that just finished has a new pid.
            let current = await macApps.session(session.id) ?? session
            guard let pid = current.pid, MacAppDriver.isRunning(current) else {
                if let pid = current.pid { await macApps.markExited(current.id, ifPid: pid) }
                return "\(current.name) (\(who)) isn't running."
            }
            await recordings.halt(current.id, reason: "the app was quit")
            await MacAppDriver.shared.terminate(pid: pid, grace: 5, executablePath: current.executablePath, start: current.processStart)
            await macApps.markExited(current.id, ifPid: pid)
            await macApps.touch(current.id)
            return "Quit \(current.name) (\(who))."
        }
    }

    /// `activate_mac_app`: brings the Mac app with this id, and its main window, to the front.
    func activateMacApp(id: String) async throws -> String {
        guard let session = await macApps.session(id) else { throw ToolError(MacToolSupport.unknownApp(id, known: await refreshedMacApps())) }
        guard let pid = session.pid, MacAppDriver.isRunning(session) else {
            throw ToolError(MacToolSupport.notRunning(session))
        }
        let window = try? await MacAppDriver.shared.window(pid: pid, .main)
        // Takes the global input lock, so it can't take the front in the middle of HID input.
        await MacAppDriver.shared.bringToFront(pid: pid, window: window)
        return "Brought \(session.name) to the front."
    }

    /// `forget_mac_app`: drops a stopped Mac app from the list. A running one has to be quit first.
    func forgetMacApp(id: String) async throws -> String {
        guard let session = await macApps.session(id) else { throw ToolError(MacToolSupport.unknownApp(id, known: await refreshedMacApps())) }
        return try await macLaunches.withLock(session.id) { () async throws -> String in
            let current = await refreshedMacApps().first { $0.id == session.id } ?? session
            guard !current.isRunning else { throw ToolError("\(current.name) (\(current.id)) is running. Quit it first.") }
            await macApps.forgetStopped([current.id])
            return "Forgot \(current.name) (\(current.id))."
        }
    }

    /// `forget_stopped_mac_apps`: drops every Mac app that isn't running from the list.
    func forgetStoppedMacApps() async -> String {
        let busy = (await activity.busy).union(await recordings.recording)
        let stopped = await refreshedMacApps().filter { !$0.isRunning && !busy.contains($0.id) }.map(\.id)
        let forgotten = await macApps.forgetStopped(stopped)
        switch forgotten.count {
        case 0: return "No stopped Mac apps to forget."
        case 1: return "Forgot 1 stopped Mac app."
        default: return "Forgot \(forgotten.count) stopped Mac apps."
        }
    }
}
