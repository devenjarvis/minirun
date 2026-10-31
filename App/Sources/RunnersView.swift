import AppKit
import MiniRunKit
import SwiftUI

/// Self-hosted GitHub Actions runners on this Mac, for the menu and Settings → GitHub Runners.
/// `github-runner.sh` (carried in the app) does the work; this lists what it installed and runs it.
@MainActor
@Observable
final class RunnerStore {
    private(set) var runners: [GitHubRunner] = []
    /// GitHub's view is being fetched.
    private(set) var refreshing = false
    /// The script is running for this repository.
    private(set) var workingOn: String?
    /// The script's output so far, while it runs and after it finishes.
    private(set) var output = ""
    private(set) var message: String?
    private(set) var messageIsError = false
    /// A command the failed run suggested, such as "gh auth login --scopes repo".
    private(set) var suggestedCommand: String?
    /// Install refused a public repository; Settings asks before trying again with --allow-public.
    var publicRepoToConfirm: String?
    private var lastRemoteRefresh: Date?

    var working: Bool { workingOn != nil }

    /// Re-reads the runners. GitHub's view costs a network call per runner, so it's fetched at most
    /// once a minute unless `force`; local state (folders, launchd) is always fresh.
    func refresh(force: Bool = false) {
        let remote = force || lastRemoteRefresh.map { Date().timeIntervalSince($0) > 60 } ?? true
        let previous = Dictionary(runners.map { ($0.id, $0.remote) }, uniquingKeysWith: { a, _ in a })
        if remote { refreshing = true }
        Task {
            var fresh = await GitHubRunners.status(remote: remote)
            if remote {
                lastRemoteRefresh = Date()
                refreshing = false
            } else {
                for index in fresh.indices { fresh[index].remote = previous[fresh[index].id] ?? nil }
            }
            runners = fresh
        }
    }

    func add(_ input: String, allowPublic: Bool = false) {
        let repo = GitHubRunners.normalizeRepo(input)
        guard GitHubRunners.isValidRepo(repo) else {
            say("Enter a repository as owner/repo.", error: true)
            return
        }
        run(.install(repo: repo, allowPublic: allowPublic))
    }

    func remove(_ runner: GitHubRunner) { run(.uninstall(repo: runner.repo)) }
    func start(_ runner: GitHubRunner) { run(.start(repo: runner.repo)) }
    func stop(_ runner: GitHubRunner) { run(.stop(repo: runner.repo)) }

    func runSuggestedCommand() {
        guard let command = suggestedCommand else { return }
        do {
            try AppleScript.runInTerminal(command)
        } catch {
            say("Couldn't open Terminal: \(error.localizedDescription)", error: true)
        }
    }

    private func run(_ command: GitHubRunners.Command) {
        guard !working else { return }
        guard let script = AppPaths.githubRunnerScript else {
            say("This copy of the app doesn't carry github-runner.sh. Build it with ./scripts/install.sh, or run scripts/github-runner.sh from the repository.", error: true)
            return
        }
        workingOn = command.repo
        output = ""
        message = nil
        suggestedCommand = nil
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("minirun-github-runner-\(UUID().uuidString).log")
        // Show the output as it arrives: the script appends to the log, this reads it back.
        let tail = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let text = try? String(contentsOf: log, encoding: .utf8) { self?.output = text }
            }
        }
        Task {
            defer {
                tail.cancel()
                try? FileManager.default.removeItem(at: log)
                workingOn = nil
                refresh(force: true)
            }
            do {
                let result = try await GitHubRunners.run(script: script, command, logURL: log)
                output = (try? String(contentsOf: log, encoding: .utf8)) ?? result.tail()
                if result.succeeded {
                    say(done(command))
                } else if case .install(let repo, false) = command, result.exitCode == GitHubRunners.publicRefusalExitCode {
                    publicRepoToConfirm = repo
                    say("\(repo) is public. Confirm to register it anyway.", error: true)
                } else {
                    suggestedCommand = GitHubRunners.suggestedCommand(in: output)
                    let reason = result.timedOut ? "timed out" : "failed"
                    let lastError = output.split(separator: "\n").last(where: { $0.hasPrefix("error: ") }).map { String($0.dropFirst(7)) }
                    say("\(verb(command)) \(command.repo) \(reason)" + (lastError.map { ": \($0)" } ?? ". See the output below."), error: true)
                }
            } catch {
                say("Couldn't run github-runner.sh: \(error.localizedDescription)", error: true)
            }
        }
    }

    private func verb(_ command: GitHubRunners.Command) -> String {
        switch command {
        case .install: return "Adding a runner for"
        case .uninstall: return "Removing the runner for"
        case .start: return "Starting the runner for"
        case .stop: return "Stopping the runner for"
        }
    }

    private func done(_ command: GitHubRunners.Command) -> String {
        switch command {
        case .install(let repo, _): return "The runner for \(repo) is registered and running. Target it with \(GitHubRunners.runsOn)."
        case .uninstall(let repo): return "Removed the runner for \(repo)."
        case .start(let repo): return "Started the runner for \(repo)."
        case .stop(let repo): return "Stopped the runner for \(repo). It stays registered and starts again at login."
        }
    }

    private func say(_ text: String, error: Bool = false) {
        message = text
        messageIsError = error
    }
}

// MARK: Settings tab

struct RunnersTab: View {
    let store: RunnerStore
    let menu: MenuStore
    @State private var repo = ""
    @State private var confirmRemove: GitHubRunner?

    var body: some View {
        Form {
            Section {
                if store.runners.isEmpty {
                    Text("No runners on this Mac yet").foregroundStyle(.secondary)
                }
                ForEach(store.runners) { runner in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(runner.repo).lineLimit(1).truncationMode(.middle)
                                RunnerBadge(badge: runner.badge)
                            }
                            Text(runner.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if store.workingOn == runner.repo {
                            ProgressView().controlSize(.small)
                        }
                        if runner.canStop {
                            Button("Stop") { store.stop(runner) }.disabled(store.working)
                        } else if runner.canStart {
                            Button("Start") { store.start(runner) }.disabled(store.working)
                        }
                        RunnerActions(runner: runner, store: store, menu: menu, remove: { confirmRemove = runner })
                    }
                }
                HStack {
                    if store.refreshing { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Refresh") { store.refresh(force: true) }.disabled(store.refreshing)
                }
            } header: {
                Text("Runners")
            } footer: {
                Text("Workflows target this Mac with \(GitHubRunners.runsOn). Jobs share the Mac with Claude's sessions, so have them boot their own simulator and pass its UDID on every call.")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section("Add a runner") {
                HStack {
                    TextField("Repository", text: $repo, prompt: Text("owner/repo"))
                        .onSubmit(add)
                    Button("Add Runner", action: add)
                        .disabled(store.working || repo.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Downloads GitHub's runner, checks its SHA-256 and registers it with gh, which must be logged in (gh auth login --scopes repo) as someone with admin access to the repository. A runner runs pull request code on this Mac as you, so public repositories need a second confirmation.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if store.message != nil || !store.output.isEmpty {
                Section {
                    if let message = store.message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(store.messageIsError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let command = store.suggestedCommand {
                        HStack {
                            Text(command).font(.caption.monospaced()).textSelection(.enabled)
                            Spacer()
                            Button("Run in Terminal") { store.runSuggestedCommand() }.controlSize(.small)
                        }
                    }
                    if !store.output.isEmpty {
                        ScrollView {
                            Text(store.output)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .defaultScrollAnchor(.bottom)
                        .frame(maxHeight: 160)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { store.refresh() }
        .alert("Register a runner for a public repository?",
               isPresented: Binding(get: { store.publicRepoToConfirm != nil }, set: { if !$0 { store.publicRepoToConfirm = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Register Anyway", role: .destructive) {
                if let repo = store.publicRepoToConfirm { store.add(repo, allowPublic: true) }
            }
        } message: {
            Text(GitHubRunners.publicWarning(store.publicRepoToConfirm ?? "This repository"))
        }
        .alert("Remove the runner for \(confirmRemove?.repo ?? "")?",
               isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if let runner = confirmRemove { store.remove(runner) }
            }
        } message: {
            Text(confirmRemove?.remote?.busy == true
                 ? "It's running a job right now; the job fails. The runner is deregistered from GitHub and its folder deleted."
                 : "It's deregistered from GitHub and its folder, with its work folder and logs, is deleted.")
        }
    }

    private func add() {
        guard !store.working else { return }
        store.add(repo)
        if GitHubRunners.isValidRepo(GitHubRunners.normalizeRepo(repo)) { repo = "" }
    }
}

/// Logs, GitHub and Remove for one runner.
struct RunnerActions: View {
    let runner: GitHubRunner
    let store: RunnerStore
    let menu: MenuStore
    var remove: (() -> Void)?

    var body: some View {
        Menu {
            Button("Open Logs") { menu.openFile(runner.diagnosticsPath) }
            Button("Open on GitHub") { menu.open(runner.settingsURL) }
            Button("Reveal in Finder") { menu.reveal(runner.directory) }
            if let remove {
                Divider()
                Button("Remove…", role: .destructive, action: remove).disabled(store.working)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Actions for the \(runner.repo) runner")
    }
}

struct RunnerBadge: View {
    let badge: GitHubRunner.Badge

    var body: some View {
        Text(badge.rawValue)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch badge {
        case .busy: return .blue
        case .idle, .running: return .green
        case .starting: return .orange
        case .offline, .broken: return .red
        case .stopped: return .secondary
        }
    }
}

// MARK: Menu section

/// The runners in the menu, shown only once one is installed.
struct RunnersMenuSection: View {
    let store: RunnerStore
    let menu: MenuStore

    var body: some View {
        if !store.runners.isEmpty {
            Section {
                ForEach(store.runners) { runner in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "server.rack")
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(runner.repo).lineLimit(1).truncationMode(.middle)
                                RunnerBadge(badge: runner.badge)
                            }
                            if store.workingOn == runner.repo {
                                Text("Working…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if runner.canStop {
                            Button("Stop") { store.stop(runner) }
                                .buttonStyle(.borderless)
                                .disabled(store.working)
                                .help("Stop taking jobs until started again or the next login")
                        } else if runner.canStart {
                            Button("Start") { store.start(runner) }
                                .buttonStyle(.borderless)
                                .disabled(store.working)
                        }
                        RunnerActions(runner: runner, store: store, menu: menu)
                    }
                }
            } header: {
                SectionTitle("GitHub runners")
            }
        }
    }
}
