import AppKit
import MiniRunKit
import ServiceManagement
import UserNotifications

/// Where this copy of the app keeps what it carries.
enum AppPaths {
    /// Contents/Helpers/minirun: the CLI and `minirun serve`. Nil in a build without the daemon.
    static var helper: String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/minirun").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Resources/worker: the prebuilt Worker that Update Worker uploads.
    static var workerBundle: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("worker"),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else { return nil }
        return url
    }

    static var bundledWorkerHash: String? {
        workerBundle.flatMap { try? WorkerBundle(directory: $0) }?.manifest.bundleHash
    }

    /// This copy is installed (in an Applications folder), so it may take over the LaunchAgent.
    static var isInstalled: Bool { LaunchAgent.isInApplicationsFolder(Bundle.main.bundlePath) }

    static var worker: WorkerManager { WorkerManager.live(bundleDirectory: workerBundle) }
}

/// Runs AppleScript, for the admin prompt and for opening Terminal.
enum AppleScript {
    @MainActor
    static func run(_ source: String) throws {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw ToolError("Couldn't build the AppleScript.") }
        script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int
            // -128: the user cancelled the password prompt.
            if number == -128 { throw ToolError("Cancelled.") }
            throw ToolError(error[NSAppleScript.errorMessage] as? String ?? "The AppleScript failed.")
        }
    }

    /// Opens a Terminal window running `command`, for things that need a person at a prompt.
    @MainActor
    static func runInTerminal(_ command: String) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        try run("tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell")
    }
}

/// "Open at login" for the menu bar app itself.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// Posts `NotificationRules`' notifications, when they're turned on in Settings.
enum AppNotifications {
    static let enabledKey = "notificationsEnabled"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    @MainActor
    static func post(_ note: AppNotification) {
        guard enabled else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = note.title
            content.body = note.body
            center.add(UNNotificationRequest(identifier: note.id, content: content, trigger: nil))
        }
    }
}
