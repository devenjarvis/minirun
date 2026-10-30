import AppKit
import MiniRunKit
import SwiftUI

/// minirun in the menu bar: what `minirun serve` is doing, and a few things to do about it.
/// The daemon runs on its own under launchd; quitting this app doesn't stop it. The app carries
/// the daemon (Contents/Helpers/minirun) and points the LaunchAgent at it when it opens.
@main
struct MiniRunMenuApp: App {
    @State private var store = MenuStore()

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store)
        } label: {
            MenuIconLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(menu: store)
        }

        Window("Set Up minirun", id: WindowID.setup) {
            SetupView(menu: store)
        }
        .windowResizability(.contentSize)

        Window("minirun Live View", id: WindowID.liveView) {
            LiveViewWindow(menu: store)
        }
        .defaultSize(width: 460, height: 900)
    }
}

enum WindowID {
    static let setup = "setup"
    static let liveView = "live-view"
}

/// The icon in the menu bar, with the number of running jobs beside it. It's on screen from
/// launch, so it also opens the setup window the first time.
struct MenuIconLabel: View {
    let store: MenuStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: store.snapshot.icon.symbolName)
            if store.snapshot.runningJobs > 0 {
                Text("\(store.snapshot.runningJobs)").monospacedDigit()
            }
        }
        .accessibilityLabel("minirun: \(store.snapshot.headline)")
        .task {
            await store.launched()
            if store.needsSetup {
                openWindow(id: WindowID.setup)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

/// Bridges `MenuModel` (an actor in MiniRunKit) to SwiftUI, and does the things that need AppKit:
/// opening links and files, the pasteboard, Simulator.app, notifications.
@MainActor
@Observable
final class MenuStore {
    private(set) var snapshot: MenuSnapshot
    /// A short-lived note from a local action such as Copy.
    private(set) var flash: String?
    /// A newer release on GitHub, if there is one.
    private(set) var update: UpdateCheck.Release?
    /// The first-run window should open: there's no relay to connect to.
    private(set) var needsSetup: Bool
    let model: MenuModel
    private var flashTask: Task<Void, Never>?
    private var didLaunch = false

    init() {
        let model = MenuModel(environment: .live(notify: { note in
            Task { @MainActor in AppNotifications.post(note) }
        }))
        self.model = model
        snapshot = MenuSnapshot.make(.pending, connectorURL: nil, logTail: nil, canStart: false, now: Date())
        needsSetup = Setup.needed(MiniRunConfig.load())
        Task { [weak self] in
            await model.observe { snapshot in
                Task { @MainActor in self?.snapshot = snapshot }
            }
            await model.start()
        }
    }

    /// Runs once, when the menu bar icon first appears: makes sure launchd runs this app's helper,
    /// then looks for updates.
    func launched() async {
        guard !didLaunch else { return }
        didLaunch = true
        if let helper = AppPaths.helper {
            do {
                if let message = try await LaunchAgent.ensure(helper: helper, helperIsInstalled: AppPaths.isInstalled) {
                    show(message)
                    await model.refresh()
                }
            } catch {
                show("Couldn't set up minirun serve: \(error.localizedDescription)")
            }
        }
        await checkForUpdates()
    }

    /// Checks GitHub for a newer release, at most once a day.
    func checkForUpdates(force: Bool = false) async {
        let key = "lastUpdateCheck"
        if !force, let last = UserDefaults.standard.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 86400 { return }
        UserDefaults.standard.set(Date(), forKey: key)
        update = try? await UpdateCheck.newer(than: MiniRun.version, transport: URLSessionTransport())
        if force { show(update.map { "minirun \($0.version) is available." } ?? "This is the latest version.") }
    }

    /// Re-reads config.json, after setup or a settings change.
    func configChanged() {
        needsSetup = Setup.needed(MiniRunConfig.load())
        Task { await model.refresh() }
    }

    var workerOutdated: Bool { snapshot.workerOutdated(bundled: AppPaths.bundledWorkerHash) }

    func menuShown(_ shown: Bool) {
        Task { await model.setMenuOpen(shown) }
    }

    func perform(_ action: MenuAction) {
        Task { await model.perform(action) }
    }

    func dismissNotice() {
        Task { await model.dismissNotice() }
    }

    /// Sends one control command and says what happened.
    func send(_ request: ControlProtocol.Request) async throws -> ControlProtocol.Response {
        try await Task.detached { try ControlProtocol.send(request, timeout: 120) }.value
    }

    func open(_ link: String?) {
        guard let link, let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    func openFile(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Opens Simulator.app on this simulator's window.
    func showInSimulator(_ udid: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Simulator", "--args", "-CurrentDeviceUDID", udid]
        do {
            try process.run()
        } catch {
            show("Couldn't open Simulator: \(error.localizedDescription)")
        }
    }

    func copyConnectorURL() {
        guard let url = snapshot.connectorURL else {
            show("No Worker yet. Choose Set Up minirun….")
            return
        }
        copy(url, note: "Copied the connector URL.")
    }

    func copyPassword() {
        guard let password = WorkerSettings.load().ownerPassword else {
            show("No password saved yet. Choose Set Up minirun….")
            return
        }
        copy(password, note: "Copied the password.")
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func copy(_ text: String, note: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(note)
    }

    func show(_ note: String) {
        flash = note
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.flash = nil
        }
    }
}
