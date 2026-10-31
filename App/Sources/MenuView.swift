import AppKit
import MiniRunKit
import SwiftUI

/// The window that drops down from the menu bar icon.
struct MenuView: View {
    let store: MenuStore
    @Environment(\.openWindow) private var openWindow

    private var snapshot: MenuSnapshot { store.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if snapshot.daemonRunning {
                simulators
                if !snapshot.macApps.isEmpty { macApps }
                jobs
                if snapshot.mediaSummary != nil { sharedMedia }
            } else if snapshot.canStart {
                notRunning
            }
            RunnersMenuSection(store: store.runners, menu: store)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 380)
        .onAppear {
            store.menuShown(true)
            Task { await store.launched() }
        }
        .onDisappear { store.menuShown(false) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(snapshot.headline, systemImage: snapshot.icon.symbolName)
                    .font(.headline)
                    .foregroundStyle(snapshot.icon == .problem || snapshot.icon == .notRunning ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Spacer(minLength: 8)
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(",")
                    .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
                    .help("Settings…")
            }
            if let problem = snapshot.problem {
                Text(problem).font(.callout).textSelection(.enabled)
            }
            if let fix = snapshot.fix {
                Text(fix).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if snapshot.daemonOutdated {
                Text("minirun serve is older than this app, so only its status works here. Restart it to pick up the new version.")
                    .font(.callout).foregroundStyle(.orange)
            }
            if store.needsSetup {
                Button {
                    openWindow(id: WindowID.setup)
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Set Up minirun…", systemImage: "wand.and.stars")
                }
                .controlSize(.large)
            }
            if store.workerOutdated {
                HStack(alignment: .firstTextBaseline) {
                    Text("The Worker runs an older version than this app.").font(.callout).foregroundStyle(.orange)
                    Spacer()
                    SettingsLink { Text("Update…") }
                        .buttonStyle(.borderless)
                        .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
                        .help("Settings → Cloudflare → Update Worker")
                }
            }
            if let update = store.update {
                HStack(alignment: .firstTextBaseline) {
                    Text(store.updateStatus ?? "minirun \(update.version) is available.").font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if store.updating {
                        ProgressView().controlSize(.small)
                    } else if update.asset != nil && AppPaths.isInstalled {
                        Button("Install") { Task { await store.installUpdate(update, automatic: true) } }
                            .buttonStyle(.borderless)
                            .help("Installs it now, or as soon as no job is running. minirun serve restarts for a moment.")
                    } else {
                        Button("Get it") { store.open(update.url) }
                            .buttonStyle(.borderless)
                            .help("Opens the release on GitHub. Builds aren't signed; see the README.")
                    }
                }
            }
            if let notice = snapshot.notice {
                HStack(alignment: .firstTextBaseline) {
                    Text(notice.text).font(.callout).foregroundStyle(notice.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    Spacer()
                    Button { store.dismissNotice() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                }
            }
        }
    }

    // MARK: Simulators

    private var simulators: some View {
        Section {
            if let error = snapshot.simulatorError {
                Text("Couldn't list simulators: \(error)").font(.callout).foregroundStyle(.red)
            } else if snapshot.simulators.isEmpty {
                Text("None booted").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(snapshot.simulators) { sim in
                SimulatorRowView(sim: sim, store: store, actionsEnabled: !snapshot.daemonOutdated)
            }
        } header: {
            SectionTitle("Simulators")
        }
    }

    // MARK: Mac apps

    private var macApps: some View {
        Section {
            ForEach(snapshot.macApps) { app in
                MacAppRowView(app: app, store: store, actionsEnabled: !snapshot.daemonOutdated)
            }
            if let missing = snapshot.macPermissions?.missing, !missing.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text("Needs \(missing.joined(separator: " and ")).").font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Set Up…") {
                        openWindow(id: WindowID.setup)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Set Up minirun → macOS apps")
                }
            }
        } header: {
            SectionTitle("Mac apps")
        }
    }

    // MARK: Jobs

    private var jobs: some View {
        Section {
            if snapshot.jobs.isEmpty {
                Text("No jobs yet").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(snapshot.jobs) { job in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: job.isRunning ? "hammer" : (job.status == "succeeded" ? "checkmark.circle" : "xmark.circle"))
                        .foregroundStyle(job.isRunning ? AnyShapeStyle(.blue) : (job.status == "succeeded" ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(job.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let log = job.logPath {
                        Button("Log") { store.openFile(log) }
                            .buttonStyle(.borderless)
                            .help("Open the job's log")
                    }
                    if job.isRunning {
                        Button("Cancel") { store.perform(.cancelJob(job.id)) }
                            .buttonStyle(.borderless)
                            .disabled(snapshot.daemonOutdated)
                            .help("Stop this job")
                    }
                }
            }
        } header: {
            SectionTitle(snapshot.runningJobs > 0 ? "Jobs (\(snapshot.runningJobs) running)" : "Jobs")
        }
    }

    // MARK: Shared media

    private var sharedMedia: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "photo.on.rectangle")
                Text(snapshot.mediaSummary ?? "").font(.callout)
                Spacer()
                Menu {
                    if snapshot.media.isEmpty {
                        Text("Nothing shared")
                    }
                    ForEach(snapshot.media) { row in
                        Menu(row.title) {
                            Button("Open") { store.open(row.url) }
                            Button("Copy link") { store.copy(row.url, note: "Copied the link.") }
                            Divider()
                            Button("Delete") { store.perform(.deleteMedia(row.id)) }
                                .disabled(snapshot.daemonOutdated)
                        }
                    }
                    Divider()
                    Button("Delete all shared media…") { store.confirmDeleteAllMedia() }
                        .disabled(snapshot.daemonOutdated || snapshot.mediaCount == 0)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Screenshots and recordings shared for PR descriptions")
            }
        } header: {
            SectionTitle("Shared media")
        }
    }

    // MARK: Not running

    private var notRunning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                store.perform(.start)
            } label: {
                Label("Start minirun", systemImage: "play.fill")
            }
            .controlSize(.large)
            if let log = snapshot.logTail {
                SectionTitle("Last lines of minirun.log")
                ScrollView {
                    Text(log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                Button("Open the full log") { store.openFile(LaunchAgent.logPath) }
                    .buttonStyle(.borderless)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let flash = store.flash {
                Text(flash).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    openWindow(id: WindowID.liveView)
                    NSApp.activate(ignoringOtherApps: true)
                } label: { Label("Live view", systemImage: "play.rectangle") }
                    .disabled(snapshot.viewerURL == nil)
                    .help("Watch the simulators in a window")
                Button { store.copyConnectorURL() } label: { Label("Connector URL", systemImage: "link") }
                    .help("Copy the URL to add as a custom connector in Claude")
                Button { store.copyPassword() } label: { Label("Password", systemImage: "key") }
                    .help("Copy the password for the live view and Claude's connector")
            }
            HStack {
                Button { store.perform(.restart) } label: { Label("Restart service", systemImage: "arrow.clockwise") }
                    .disabled(!snapshot.canStart)
                    .help("Restart minirun serve. Claude's calls in progress are retried after it reconnects.")
                Spacer()
                Button("Quit") { store.quit() }
                    .keyboardShortcut("q")
                    .help("Quit the menu bar app. minirun serve keeps running.")
            }
        }
        .buttonStyle(.borderless)
    }
}

struct SimulatorRowView: View {
    let sim: MenuSnapshot.SimulatorRow
    let store: MenuStore
    let actionsEnabled: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "iphone")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(sim.name).lineLimit(1)
                    ActivityBadge(activity: sim.activity)
                    if sim.recording {
                        Image(systemName: "record.circle").foregroundStyle(.red).help("Recording its screen")
                    }
                }
                Text(sim.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Menu {
                Button("Watch live") { store.open(sim.viewerURL) }
                    .disabled(sim.viewerURL == nil)
                Button("Show in Simulator") { store.showInSimulator(sim.udid) }
                if sim.recording {
                    Button("Stop recording") { store.perform(.stopRecording(sim.udid)) }
                        .disabled(!actionsEnabled)
                }
                Divider()
                Button("Release reservation") { store.perform(.releaseSimulator(sim.udid)) }
                    .disabled(!actionsEnabled || sim.reservedFor == nil)
                Button("Shut down") { store.perform(.shutdownSimulator(sim.udid)) }
                    .disabled(!actionsEnabled)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Actions for \(sim.name)")
        }
    }
}

struct MacAppRowView: View {
    let app: MenuSnapshot.MacAppRow
    let store: MenuStore
    let actionsEnabled: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "macwindow")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(app.name).lineLimit(1)
                    Badge(text: app.activity.rawValue, color: color)
                }
                Text(app.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Menu {
                Button("Watch live") { store.open(app.viewerURL) }
                    .disabled(app.viewerURL == nil || !app.isRunning)
                Button("Bring to front") { store.bringToFront(app) }
                    .disabled(!actionsEnabled || !app.isRunning)
                Divider()
                Button("Quit") { store.perform(.quitMacApp(app.id)) }
                    .disabled(!actionsEnabled || !app.isRunning)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Actions for \(app.name) (\(app.id))")
        }
    }

    private var color: Color {
        switch app.activity {
        case .busy: return .blue
        case .idle: return .secondary
        case .notRunning: return .orange
        }
    }
}

struct ActivityBadge: View {
    let activity: MenuSnapshot.SimulatorRow.Activity

    var body: some View {
        Badge(text: activity.rawValue, color: color)
    }

    private var color: Color {
        switch activity {
        case .booting: return .orange
        case .busy: return .blue
        case .idle: return .secondary
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct SectionTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }
}
