import AppKit
import MiniRunKit
import SwiftUI

/// What the settings window shows and does. Fields map to config.json keys; saving writes the
/// file and sends `reload_config`, so `minirun serve` uses them at once.
@MainActor
@Observable
final class SettingsStore {
    let menu: MenuStore

    /// The form as saved, and as edited.
    private(set) var saved: SettingsForm
    var form: SettingsForm
    /// The result of the last action, or why it failed.
    private(set) var message: String?
    private(set) var messageIsError = false
    /// An action is running; buttons wait for it.
    private(set) var working = false

    // Simulators
    private(set) var deviceChoices: [String] = []
    private(set) var automaticDevice: String?

    // Workspaces
    private(set) var workspaces: [WorkspaceInfo] = []
    private(set) var workspacesError: String?
    var staleDays = 30

    // Diagnostics
    private(set) var checks: [DoctorCheck] = []
    private(set) var checksError: String?
    private(set) var checking = false

    // Cloudflare
    private(set) var workerStatus: WorkerManager.Status?
    private(set) var workerStatusError: String?
    private(set) var deploySteps = Setup.Checklist()
    var apiToken = ""
    private(set) var hasSavedToken = WorkerSettings.load().apiToken != nil

    // General
    private(set) var openAtLogin = LoginItem.isEnabled
    private(set) var commandLineTool = CommandLineTool.currentTarget()
    private(set) var notificationsEnabled = AppNotifications.enabled

    init(menu: MenuStore) {
        self.menu = menu
        let form = SettingsForm(MiniRunConfig.load())
        saved = form
        self.form = form
    }

    var hasChanges: Bool { form != saved }

    // MARK: Saving

    func save() {
        run { [form] in
            let message = try await form.save(send: { request in try await self.menu.send(request) })
            self.saved = SettingsForm(MiniRunConfig.load())
            self.form = self.saved
            self.menu.configChanged()
            return message
        }
    }

    func revert() {
        form = saved
    }

    /// Re-reads config.json, e.g. after setup changed it.
    func reload() {
        saved = SettingsForm(MiniRunConfig.load())
        form = saved
        hasSavedToken = WorkerSettings.load().apiToken != nil
        openAtLogin = LoginItem.isEnabled
        commandLineTool = CommandLineTool.currentTarget()
    }

    // MARK: General

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
            openAtLogin = LoginItem.isEnabled
            say(enabled ? "minirun opens at login." : "minirun no longer opens at login.")
        } catch {
            openAtLogin = LoginItem.isEnabled
            say("Couldn't change Open at login: \(error.localizedDescription). Add minirun in System Settings → General → Login Items instead.", error: true)
        }
    }

    func setNotifications(_ enabled: Bool) {
        AppNotifications.enabled = enabled
        notificationsEnabled = enabled
    }

    func installCommandLineTool() {
        guard let helper = AppPaths.helper else {
            say("This copy of the app doesn't carry the minirun command. Build it with ./scripts/install.sh.", error: true)
            return
        }
        do {
            try AppleScript.run(CommandLineTool.adminAppleScript(CommandLineTool.installCommand(helper: helper)))
            commandLineTool = CommandLineTool.currentTarget()
            say("Installed \(CommandLineTool.linkPath). Try `minirun status` in a terminal.")
        } catch {
            say("Couldn't install the command line tool: \(error.localizedDescription)", error: true)
        }
    }

    // MARK: Simulators

    func loadDevices() {
        Task {
            guard let result = try? await Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "--json"], timeout: 60), result.succeeded,
                  let devices = try? XcodeParsing.parseDevices(Data(result.stdout.utf8)) else {
                deviceChoices = []
                return
            }
            deviceChoices = SettingsForm.deviceChoices(devices)
            automaticDevice = SettingsForm.automaticDevice(devices)
        }
    }

    // MARK: Workspaces

    func chooseWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.directoryURL = URL(fileURLWithPath: form.workspaceRoot)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { form.workspaceRoot = url.path }
    }

    func loadWorkspaces() {
        Task {
            do {
                let response = try await menu.send(ControlProtocol.Request(command: "workspaces"))
                guard response.ok, let list = response.workspaces else { throw ToolError(response.error ?? "minirun serve sent no list.") }
                workspaces = list
                workspacesError = nil
            } catch {
                workspacesError = "Couldn't list checkouts: \(error.localizedDescription)"
            }
        }
    }

    var staleWorkspaces: [WorkspaceInfo] { WorkspaceInventory.stale(workspaces, olderThanDays: staleDays) }

    func delete(_ checkouts: [WorkspaceInfo]) {
        run {
            var deleted = 0
            var failures: [String] = []
            for checkout in checkouts {
                let response = try await self.menu.send(ControlProtocol.Request(command: "delete_workspace", path: checkout.path))
                if response.ok { deleted += 1 } else { failures.append(response.error ?? checkout.name) }
            }
            self.loadWorkspaces()
            if !failures.isEmpty { throw ToolError(failures.joined(separator: "\n")) }
            return deleted == 1 ? "Deleted \(checkouts[0].name)." : "Deleted \(deleted) checkouts."
        }
    }

    // MARK: Diagnostics

    func runDoctor() {
        checking = true
        Task {
            do {
                checks = try await AppDoctor.checks(helper: AppPaths.helper, send: { request in try await self.menu.send(request) })
                checksError = nil
            } catch {
                checksError = error.localizedDescription
            }
            checking = false
        }
    }

    func runInTerminal(_ command: String) {
        do {
            try AppleScript.runInTerminal(command)
        } catch {
            say("Couldn't open Terminal: \(error.localizedDescription)", error: true)
        }
    }

    func copyDiagnostics() {
        Task {
            let response = try? await menu.send(ControlProtocol.Request(command: "status"))
            let report = Diagnostics.report(
                appVersion: MiniRun.version, os: ProcessInfo.processInfo.operatingSystemVersionString, status: response?.status,
                config: MiniRunConfig.load(), worker: WorkerSettings.load(), checks: checks
            )
            menu.copy(report, note: "Copied diagnostics (no secrets).")
            say("Copied diagnostics. Secrets are left out.")
        }
    }

    // MARK: Cloudflare

    func loadWorkerStatus() {
        Task {
            do {
                workerStatus = try await AppPaths.worker.status(apiToken: nil)
                workerStatusError = nil
            } catch {
                workerStatusError = error.localizedDescription
            }
        }
    }

    /// Deploys the bundled Worker with the saved token, or the one typed in.
    func updateWorker() {
        let typed = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = typed.isEmpty ? WorkerSettings.load().apiToken : typed else {
            say("Paste a Cloudflare API token first.", error: true)
            return
        }
        deploySteps = Setup.Checklist()
        run {
            do {
                let deployment = try await AppPaths.worker.deploy(apiToken: token, options: .init()) { step in
                    Task { @MainActor in self.deploySteps.advance(step) }
                }
                self.deploySteps.finish()
                self.apiToken = ""
                self.hasSavedToken = true
                self.loadWorkerStatus()
                self.menu.configChanged()
                return "The Worker is \(deployment.result.created ? "deployed" : "up to date") at \(deployment.result.workerURL)."
                    + (deployment.answering ? "" : " It isn't answering yet; a new workers.dev subdomain can take a few minutes.")
            } catch {
                self.deploySteps.fail(error.localizedDescription)
                throw error
            }
        }
    }

    func rotate(_ secret: WorkerManager.Secret) {
        run {
            let value = try await AppPaths.worker.rotate(secret)
            self.menu.configChanged()
            switch secret {
            case .password:
                self.menu.copy(value, note: "Copied the new password.")
                return "New password set and copied. Log in to the viewer and approve Claude's connector with it from now on."
            case .agentToken:
                return "New agent token set. minirun serve is reconnecting with it."
            }
        }
    }

    func forgetToken() {
        do {
            try WorkerManager.forgetToken()
            hasSavedToken = false
            say("Deleted the saved Cloudflare API token. Updating the Worker asks for one again.")
        } catch {
            say("Couldn't forget the token: \(error.localizedDescription)", error: true)
        }
    }

    // MARK: Helpers

    func say(_ text: String, error: Bool = false) {
        message = text
        messageIsError = error
    }

    /// Runs an action that returns a message for the user, one at a time.
    private func run(_ action: @escaping @MainActor () async throws -> String) {
        guard !working else { return }
        working = true
        message = nil
        Task {
            do {
                say(try await action())
            } catch {
                say(error.localizedDescription, error: true)
            }
            working = false
        }
    }
}
