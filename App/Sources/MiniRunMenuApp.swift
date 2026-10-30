import AppKit
import MiniRunKit
import SwiftUI

/// minirun in the menu bar: what `minirun serve` is doing, and a few things to do about it.
/// The daemon runs on its own under launchd; quitting this app doesn't stop it.
@main
struct MiniRunMenuApp: App {
    @State private var store = MenuStore()

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store)
        } label: {
            MenuIconLabel(snapshot: store.snapshot)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The icon in the menu bar, with the number of running jobs beside it.
struct MenuIconLabel: View {
    let snapshot: MenuSnapshot

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: snapshot.icon.symbolName)
            if snapshot.runningJobs > 0 {
                Text("\(snapshot.runningJobs)").monospacedDigit()
            }
        }
        .accessibilityLabel("minirun: \(snapshot.headline)")
    }
}

/// Bridges `MenuModel` (an actor in MiniRunKit) to SwiftUI, and does the things that need AppKit:
/// opening links and files, the pasteboard, Simulator.app.
@MainActor
@Observable
final class MenuStore {
    private(set) var snapshot: MenuSnapshot
    /// A short-lived note from a local action such as Copy.
    private(set) var flash: String?
    private let model: MenuModel
    private var flashTask: Task<Void, Never>?

    init(environment: MenuModel.Environment = .live()) {
        let model = MenuModel(environment: environment)
        self.model = model
        snapshot = MenuSnapshot.make(.pending, connectorURL: nil, logTail: nil, canStart: false, now: Date())
        Task { [weak self] in
            await model.observe { snapshot in
                Task { @MainActor in self?.snapshot = snapshot }
            }
            await model.start()
        }
    }

    func menuShown(_ shown: Bool) {
        Task { await model.setMenuOpen(shown) }
    }

    func perform(_ action: MenuAction) {
        Task { await model.perform(action) }
    }

    func dismissNotice() {
        Task { await model.dismissNotice() }
    }

    func open(_ link: String?) {
        guard let link, let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    func openFile(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
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
            show("No Worker yet. Run `minirun worker deploy`.")
            return
        }
        copy(url, note: "Copied the connector URL.")
    }

    func copyPassword() {
        guard let password = WorkerSettings.load().ownerPassword else {
            show("No password saved yet. Run `minirun worker deploy`.")
            return
        }
        copy(password, note: "Copied the password.")
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func copy(_ text: String, note: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(note)
    }

    private func show(_ note: String) {
        flash = note
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.flash = nil
        }
    }
}
