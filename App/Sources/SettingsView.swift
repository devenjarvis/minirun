import AppKit
import MiniRunKit
import SwiftUI

/// The Settings window (⌘,). Each tab edits part of config.json or the Worker; Save applies the
/// config at once through `reload_config`.
struct SettingsView: View {
    @State private var store: SettingsStore

    init(menu: MenuStore) {
        _store = State(initialValue: SettingsStore(menu: menu))
    }

    var body: some View {
        TabView {
            GeneralTab(store: store).tabItem { Label("General", systemImage: "gearshape") }
            CloudflareTab(store: store).tabItem { Label("Cloudflare", systemImage: "cloud") }
            SimulatorsTab(store: store).tabItem { Label("Simulators", systemImage: "iphone") }
            WorkspacesTab(store: store).tabItem { Label("Workspaces", systemImage: "folder") }
            SecurityTab(store: store).tabItem { Label("Security", systemImage: "lock.shield") }
            DiagnosticsTab(store: store).tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 560)
        .frame(minHeight: 420)
        .onAppear { store.reload() }
    }
}

/// The last action's result, and Save/Revert while the form has changes.
struct SettingsFooter: View {
    let store: SettingsStore
    var saves = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = store.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(store.messageIsError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if saves {
                let problems = store.form.problems
                if !problems.isEmpty {
                    Text(problems.joined(separator: " ")).font(.callout).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Revert") { store.revert() }.disabled(!store.hasChanges || store.working)
                    Button("Save") { store.save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!store.hasChanges || !problems.isEmpty || store.working)
                }
            }
        }
    }
}

// MARK: General

struct GeneralTab: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Open minirun at login", isOn: Binding(get: { store.openAtLogin }, set: { store.setOpenAtLogin($0) }))
                Toggle("Keep this Mac awake while connected", isOn: $store.form.preventSleep)
                Toggle("Notify me when the relay is down or a job fails", isOn: Binding(get: { store.notificationsEnabled }, set: { store.setNotifications($0) }))
            }
            Section("Command line tool") {
                LabeledContent("minirun command") {
                    Text(store.commandLineTool.map { "\(CommandLineTool.linkPath) → \($0)" } ?? "not installed")
                        .foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
                Button("Install Command Line Tool…") { store.installCommandLineTool() }
                    .disabled(AppPaths.helper == nil)
                    .help("Links \(CommandLineTool.linkPath) to the minirun inside this app. Asks for an administrator password.")
            }
            Section("Version") {
                LabeledContent("This app") { Text(MiniRun.version) }
                LabeledContent("minirun serve") { Text(store.menu.snapshot.daemonVersion ?? "not running") }
                Toggle("Install updates automatically", isOn: Binding(get: { store.menu.autoUpdate }, set: { store.menu.setAutoUpdate($0) }))
                Text("Checks GitHub every 6 hours. Updates wait until no job is running and nobody is using a simulator, then restart minirun serve for a moment. The Worker is updated too, with the saved API token.")
                    .font(.callout).foregroundStyle(.secondary)
                if let status = store.menu.updateStatus {
                    Text(status).font(.callout)
                }
                if let update = store.menu.update {
                    HStack {
                        Button("Install minirun \(update.version)") { Task { await store.menu.installUpdate(update, automatic: true) } }
                            .disabled(store.menu.updating || update.asset == nil || !AppPaths.isInstalled)
                        Button("Release Notes…") { store.menu.open(update.url) }
                    }
                }
                Button("Check for Updates") { Task { await store.menu.updateTick(forceCheck: true) } }
                    .disabled(store.menu.updating)
            }
            SettingsFooter(store: store)
        }
        .formStyle(.grouped)
    }
}

// MARK: Cloudflare

struct CloudflareTab: View {
    @Bindable var store: SettingsStore
    @State private var confirmRotate: WorkerManager.Secret?

    var body: some View {
        Form {
            Section("Worker") {
                let status = store.workerStatus
                LabeledContent("URL") { Text(status?.workerURL ?? WorkerSettings.load().workerURL ?? "not deployed").textSelection(.enabled) }
                LabeledContent("Account") { Text(status?.accountID ?? "unknown") }
                LabeledContent("Bundled version") { Text(status?.bundled.map { String($0.prefix(12)) } ?? "not in this app") }
                LabeledContent("Deployed version") { Text(deployedText(status)) }
                if let error = store.workerStatusError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                if status?.outOfDate == true || store.menu.workerOutdated {
                    Text("The Worker is out of date. Update it to match this app.").foregroundStyle(.orange)
                }
            }
            Section {
                if !store.hasSavedToken {
                    SecureField("Cloudflare API token", text: $store.apiToken)
                    Text("Make one from the \"Edit Cloudflare Workers\" template.").font(.callout).foregroundStyle(.secondary)
                    Link("Open Cloudflare API Tokens", destination: URL(string: WorkerManager.tokenPage)!)
                }
                HStack {
                    Button(store.workerStatus?.workerURL == nil ? "Deploy Worker" : "Update Worker") { store.updateWorker() }
                        .disabled(store.working)
                    if store.working { ProgressView().controlSize(.small) }
                }
                ChecklistView(checklist: store.deploySteps)
            }
            Section("Secrets") {
                HStack {
                    Button("Copy Connector URL") { store.menu.copyConnectorURL() }
                    Button("Copy Password") { store.menu.copyPassword() }
                }
                HStack {
                    Button("Rotate Password…") { confirmRotate = .password }
                    Button("Rotate Agent Token…") { confirmRotate = .agentToken }
                }
                .disabled(!store.hasSavedToken || store.working)
                Button("Forget API Token", role: .destructive) { store.forgetToken() }
                    .disabled(!store.hasSavedToken)
                    .help("Deletes the Cloudflare API token saved in ~/.config/minirun/worker.json")
            }
            SettingsFooter(store: store, saves: false)
        }
        .formStyle(.grouped)
        .onAppear { store.loadWorkerStatus() }
        .alert(confirmRotate == .password ? "Set a new password?" : "Set a new agent token?",
               isPresented: Binding(get: { confirmRotate != nil }, set: { if !$0 { confirmRotate = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Rotate", role: .destructive) {
                if let secret = confirmRotate { store.rotate(secret) }
            }
        } message: {
            Text(confirmRotate == .password
                 ? "The old password stops working for the viewer and for approving Claude's connector. Connectors already approved keep working."
                 : "The Worker only accepts the new token. minirun serve reconnects with it in a few seconds.")
        }
    }

    private func deployedText(_ status: WorkerManager.Status?) -> String {
        if let running = store.menu.snapshot.relay?.workerBundle { return String(running.prefix(12)) }
        switch status?.deployed {
        case .bundle(let hash)?: return hash.map { String($0.prefix(12)) } ?? "deployed with wrangler"
        case .missing?: return "nothing deployed"
        case .unknown?, nil: return "unknown"
        }
    }
}

/// The deploy steps, ticked off as they finish.
struct ChecklistView: View {
    let checklist: Setup.Checklist

    var body: some View {
        if !checklist.rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(checklist.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        switch row.state {
                        case .running:
                            ProgressView().controlSize(.mini)
                        case .done:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failed:
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        }
                        VStack(alignment: .leading) {
                            Text(row.title)
                            if let message = failure(row.state) {
                                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
    }
}

extension ChecklistView {
    func failure(_ state: Setup.Checklist.State) -> String? {
        if case .failed(let message) = state { return message }
        return nil
    }
}

// MARK: Simulators

struct SimulatorsTab: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Default device", selection: $store.form.defaultDevice) {
                    Text("Automatic" + (store.automaticDevice.map { " (\($0))" } ?? "")).tag("")
                    ForEach(choices, id: \.self) { Text($0).tag($0) }
                }
                Text("Booted when a build doesn't name a simulator. Automatic picks the newest Pro iPhone, never an SE or a Duo.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Stepper(value: $store.form.idleShutdownMinutes, in: SettingsForm.idleRange, step: 5) {
                    LabeledContent("Shut down idle simulators after") {
                        Text(store.form.idleShutdownMinutes == 0 ? "never" : "\(store.form.idleShutdownMinutes) min")
                    }
                }
                Stepper(value: $store.form.maxBootedSimulators, in: SettingsForm.maxBootedRange) {
                    LabeledContent("Simulators booted at most") { Text("\(store.form.maxBootedSimulators)") }
                }
            }
            SettingsFooter(store: store)
        }
        .formStyle(.grouped)
        .onAppear { store.loadDevices() }
    }

    /// The saved device stays in the list even if it's not installed any more.
    private var choices: [String] {
        let saved = store.form.defaultDevice
        return saved.isEmpty || store.deviceChoices.contains(saved) ? store.deviceChoices : [saved] + store.deviceChoices
    }
}

// MARK: Workspaces

struct WorkspacesTab: View {
    @Bindable var store: SettingsStore
    @State private var confirmStale = false

    var body: some View {
        Form {
            Section("Folder") {
                HStack {
                    Text(store.form.workspaceRoot).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button("Choose…") { store.chooseWorkspaceFolder() }
                    Button("Reveal") { store.menu.reveal(store.form.workspaceRoot) }
                }
                Text("Repositories are cloned and built here. Changing it doesn't move existing checkouts.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Checkouts") {
                if let error = store.workspacesError {
                    Text(error).font(.callout).foregroundStyle(.red)
                } else if store.workspaces.isEmpty {
                    Text("No checkouts yet").foregroundStyle(.secondary)
                }
                ForEach(store.workspaces, id: \.path) { checkout in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(checkout.name).lineLimit(1).truncationMode(.middle)
                            Text(detail(checkout)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Delete") { store.delete([checkout]) }
                            .disabled(checkout.busy || store.working)
                            .help(checkout.busy ? "A job is using it" : "Delete this checkout and its build folder")
                    }
                }
                HStack {
                    Stepper("Older than \(store.staleDays) days", value: $store.staleDays, in: 1...365)
                    Spacer()
                    Button("Delete \(store.staleWorkspaces.count)…") { confirmStale = true }
                        .disabled(store.staleWorkspaces.isEmpty || store.working)
                }
            }
            SettingsFooter(store: store)
        }
        .formStyle(.grouped)
        .onAppear { store.loadWorkspaces() }
        .alert("Delete \(store.staleWorkspaces.count) checkouts?", isPresented: $confirmStale) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { store.delete(store.staleWorkspaces) }
        } message: {
            Text(store.staleWorkspaces.map(\.name).joined(separator: "\n"))
        }
    }

    private func detail(_ checkout: WorkspaceInfo) -> String {
        var parts = [WorkspaceInventory.formatSize(checkout.sizeBytes)]
        if let used = checkout.lastUsed { parts.append("used " + SimulatorPicker.ago(used, now: Date())) }
        if checkout.busy { parts.append("in use") }
        return parts.joined(separator: " · ")
    }
}

// MARK: Security

struct SecurityTab: View {
    @Bindable var store: SettingsStore
    @State private var confirmShell = false

    var body: some View {
        Form {
            Section {
                Toggle("Allow run_command (shell commands in workspaces)", isOn: Binding(
                    get: { store.form.allowShell },
                    set: { on in if on { confirmShell = true } else { store.form.allowShell = false } }
                ))
                Text("Off by default. Builds, tests and simulator tools work without it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            SettingsFooter(store: store)
        }
        .formStyle(.grouped)
        .alert("Let Claude run shell commands on this Mac?", isPresented: $confirmShell) {
            Button("Cancel", role: .cancel) {}
            Button("Allow", role: .destructive) { store.form.allowShell = true }
        } message: {
            Text("Anyone holding a token for your connector could run any command as you, inside the workspace folder and beyond it: read your files, use your GitHub login, install software. Only turn this on if you trust every Claude session connected to this Mac.")
        }
    }
}

// MARK: Diagnostics

struct DiagnosticsTab: View {
    let store: SettingsStore

    var body: some View {
        Form {
            Section {
                if store.checking && store.checks.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Checking…") }
                }
                if let error = store.checksError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                ForEach(store.checks, id: \.id) { check in
                    DoctorRow(check: check, store: store)
                }
                Button("Check Again") { store.runDoctor() }.disabled(store.checking)
            }
            Section {
                HStack {
                    Button("Open Log") { store.menu.openFile(LaunchAgent.logPath) }
                    Button("Copy Diagnostics") { store.copyDiagnostics() }
                        .help("Versions, state and settings, without the token or password")
                    Button("Reveal Config in Finder") { store.menu.reveal(MiniRunConfig.configURL.path) }
                }
            }
            SettingsFooter(store: store, saves: false)
        }
        .formStyle(.grouped)
        .onAppear { if store.checks.isEmpty { store.runDoctor() } }
    }
}

/// One doctor check, with its fix. A fix that's a command can be run in Terminal.
struct DoctorRow: View {
    let check: DoctorCheck
    let store: SettingsStore

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: check.ok ? "checkmark.circle.fill" : (check.optional ? "minus.circle" : "xmark.circle.fill"))
                .foregroundStyle(check.ok ? AnyShapeStyle(.green) : (check.optional ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)))
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                Text(check.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !check.ok, let fix = check.fix {
                    Text(fix).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            Spacer()
            if !check.ok, let fix = check.fix, DoctorRow.isCommand(fix) {
                Button("Run in Terminal") { store.runInTerminal(fix) }
                    .controlSize(.small)
            }
        }
    }

    /// Fixes like "sudo xcodebuild -license accept" or "gh auth login && gh auth setup-git".
    static func isCommand(_ fix: String) -> Bool {
        ["sudo ", "gh ", "launchctl ", "minirun ", "xcode-select", "./scripts/"].contains { fix.hasPrefix($0) }
    }
}
