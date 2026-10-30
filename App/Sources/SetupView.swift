import AppKit
import MiniRunKit
import SwiftUI

/// The first-run window: check the Mac, deploy the Worker, connect Claude, then the optional bits.
/// It opens by itself while config.json has no relay, and from the menu's Set Up minirun….
@MainActor
@Observable
final class SetupStore {
    let menu: MenuStore
    var step: Setup.Step = .prerequisites

    // Check this Mac
    private(set) var checks: [DoctorCheck] = []
    private(set) var checksError: String?
    private(set) var checking = false

    // Deploy the Worker
    var apiToken = WorkerSettings.load().apiToken ?? ""
    private(set) var accounts: [CloudflareAPI.Account] = []
    var accountID = WorkerSettings.load().accountID ?? ""
    /// The account has no workers.dev subdomain yet, so the deploy needs one.
    private(set) var needsSubdomain = false
    var subdomain = ""
    private(set) var checklist = Setup.Checklist()
    private(set) var deployed: WorkerDeployer.Result?
    private(set) var error: String?
    private(set) var working = false

    // Connect Claude
    private(set) var claudeStepOpened = Date()

    init(menu: MenuStore) {
        self.menu = menu
    }

    var prerequisites: [DoctorCheck] { checks.filter { Setup.prerequisiteChecks.contains($0.id) } }
    var prerequisitesOK: Bool { !prerequisites.isEmpty && prerequisites.allSatisfy(\.ok) }
    var github: DoctorCheck? { checks.first { $0.id == "github" } }
    var claudeConnected: Bool { Setup.claudeConnected(menu.snapshot.relay, since: claudeStepOpened) }
    var relayConnected: Bool { menu.snapshot.relay?.state == .connected }

    func go(_ next: Setup.Step) {
        error = nil
        step = next
        if next == .claude { claudeStepOpened = Date() }
        if next == .prerequisites || next == .github { runChecks() }
    }

    func runChecks() {
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

    /// Checks the token and lists its accounts; one account is picked at once.
    func checkToken() {
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        work {
            let accounts = try await AppPaths.worker.accounts(apiToken: token)
            guard !accounts.isEmpty else { throw ToolError("This token can't see any Cloudflare account. Make it from the \"Edit Cloudflare Workers\" template.") }
            self.accounts = accounts
            if !accounts.contains(where: { $0.id == self.accountID }) { self.accountID = accounts[0].id }
            try await self.checkSubdomain()
        }
    }

    func accountChanged() {
        work { try await self.checkSubdomain() }
    }

    private func checkSubdomain() async throws {
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        needsSubdomain = try await AppPaths.worker.subdomain(apiToken: token, account: accountID) == nil
    }

    func deploy() {
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = subdomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let options = WorkerDeployer.Options(accountID: accountID.isEmpty ? nil : accountID, subdomain: needsSubdomain ? wanted : nil)
        checklist = Setup.Checklist()
        work {
            do {
                let deployment = try await AppPaths.worker.deploy(apiToken: token, options: options) { step in
                    Task { @MainActor in self.checklist.advance(step) }
                }
                self.checklist.finish()
                self.deployed = deployment.result
                self.menu.configChanged()
                // A brand-new install has no LaunchAgent until the app makes one.
                if let helper = AppPaths.helper, !LaunchAgent.isInstalled {
                    try await LaunchAgent.install(program: helper)
                }
            } catch {
                self.checklist.fail(error.localizedDescription)
                throw error
            }
        }
    }

    func logInToGitHub() {
        do {
            try AppleScript.runInTerminal("gh auth login && gh auth setup-git")
        } catch {
            self.error = "Couldn't open Terminal: \(error.localizedDescription)"
        }
    }

    private func work(_ action: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        error = nil
        Task {
            do {
                try await action()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

struct SetupView: View {
    @State private var store: SetupStore
    @Environment(\.dismissWindow) private var dismissWindow

    init(menu: MenuStore) {
        _store = State(initialValue: SetupStore(menu: menu))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Setup.Step.allCases, id: \.rawValue) { step in
                    Label(step.title, systemImage: step.rawValue < store.step.rawValue ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(step == store.step ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .fontWeight(step == store.step ? .semibold : .regular)
                }
                Spacer()
            }
            .padding(20)
            .frame(width: 190, alignment: .leading)
            .background(.quaternary.opacity(0.4))

            VStack(alignment: .leading, spacing: 14) {
                Text(store.step.title).font(.title2.weight(.semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        page
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = store.error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                Divider()
                footer
            }
            .padding(20)
            .frame(width: 480)
        }
        .frame(height: 500)
        .onAppear { store.go(Setup.needed(MiniRunConfig.load()) ? .prerequisites : store.step) }
    }

    @ViewBuilder private var page: some View {
        switch store.step {
        case .prerequisites: prerequisites
        case .cloudflare: cloudflare
        case .claude: claude
        case .github: github
        case .headless: headless
        }
    }

    // MARK: Pages

    @ViewBuilder private var prerequisites: some View {
        Text("minirun builds and runs your apps with this Mac's Xcode and simulators.")
        if store.checking && store.checks.isEmpty {
            HStack { ProgressView().controlSize(.small); Text("Checking…") }
        }
        if let error = store.checksError {
            Text(error).foregroundStyle(.red)
        }
        ForEach(store.prerequisites, id: \.id) { check in
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(check.ok ? .green : .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(check.title)
                    Text(check.detail).font(.caption).foregroundStyle(.secondary)
                    if !check.ok, let fix = check.fix { Text(fix).font(.caption.monospaced()).textSelection(.enabled) }
                }
                Spacer()
                if !check.ok, let fix = check.fix, DoctorRow.isCommand(fix) {
                    Button("Fix in Terminal") { try? AppleScript.runInTerminal(fix) }.controlSize(.small)
                }
            }
        }
        Button("Check Again") { store.runChecks() }.disabled(store.checking)
    }

    @ViewBuilder private var cloudflare: some View {
        Text("Claude reaches this Mac through a small Cloudflare Worker on your own account (the free plan is enough). minirun deploys it for you with an API token.")
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(WorkerManager.tokenSteps.enumerated()), id: \.offset) { index, text in
                Text("\(index + 1). \(text)").font(.callout)
            }
        }
        Link("Open Cloudflare API Tokens", destination: URL(string: WorkerManager.tokenPage)!)
        HStack {
            SecureField("Cloudflare API token", text: $store.apiToken)
            Button("Check") { store.checkToken() }.disabled(store.apiToken.isEmpty || store.working)
        }
        if store.accounts.count > 1 {
            Picker("Account", selection: $store.accountID) {
                ForEach(store.accounts, id: \.id) { Text($0.name).tag($0.id) }
            }
            .onChange(of: store.accountID) { store.accountChanged() }
        } else if let account = store.accounts.first {
            LabeledContent("Account") { Text(account.name) }
        }
        if store.needsSubdomain {
            TextField("workers.dev subdomain", text: $store.subdomain)
            Text("This account has no workers.dev subdomain yet. The Worker will be at https://minirun.\(store.subdomain.isEmpty ? "<name>" : store.subdomain).workers.dev.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if !store.accounts.isEmpty {
            HStack {
                Button(store.deployed == nil ? "Deploy" : "Deploy Again") { store.deploy() }
                    .disabled(store.working || (store.needsSubdomain && store.subdomain.isEmpty))
                if store.working { ProgressView().controlSize(.small) }
            }
        }
        ChecklistView(checklist: store.checklist)
        if let deployed = store.deployed {
            Text("Deployed to \(deployed.workerURL).").foregroundStyle(.green)
        }
    }

    @ViewBuilder private var claude: some View {
        Text("In Claude, open Settings → Connectors → Add custom connector and paste the connector URL. When Claude asks you to approve it, use the password.")
        LabeledContent("Connector URL") {
            HStack {
                Text(store.menu.snapshot.connectorURL ?? "—").textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Button("Copy") { store.menu.copyConnectorURL() }
            }
        }
        LabeledContent("Password") {
            Button("Copy Password") { store.menu.copyPassword() }
        }
        Divider()
        if store.claudeConnected {
            Label("Claude is connected.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if store.relayConnected {
            HStack { ProgressView().controlSize(.small); Text("This Mac is online. Waiting for Claude… ask it to run mac_status.") }
        } else {
            HStack { ProgressView().controlSize(.small); Text("Waiting for this Mac to connect to the Worker…") }
            if let fix = store.menu.snapshot.fix { Text(fix).font(.caption).foregroundStyle(.secondary) }
        }
        if let flash = store.menu.flash { Text(flash).font(.caption).foregroundStyle(.secondary) }
    }

    @ViewBuilder private var github: some View {
        Text("To build private repositories, the Mac needs a GitHub login. Public repositories work without one.")
        if let check = store.github {
            Label(check.detail, systemImage: check.ok ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(check.ok ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
        } else if store.checking {
            HStack { ProgressView().controlSize(.small); Text("Checking…") }
        }
        HStack {
            Button("Log In with gh in Terminal") { store.logInToGitHub() }
            Button("Check Again") { store.runChecks() }.disabled(store.checking)
        }
    }

    @ViewBuilder private var headless: some View {
        Text("If this Mac (a Mac mini, say) runs without anyone at it, set it up so minirun stays reachable:")
        VStack(alignment: .leading, spacing: 8) {
            tip("Log in automatically after a restart, so minirun starts.", "Users & Groups", SystemSettingsLinks.automaticLogin)
            tip("Never sleep (Prevent automatic sleeping when the display is off).", "Energy", SystemSettingsLinks.energy)
            tip("Open minirun at login (Settings → General in this app, or here).", "Login Items", SystemSettingsLinks.loginItems)
        }
        Text("minirun also keeps the Mac awake while it's connected (Settings → General).").font(.callout).foregroundStyle(.secondary)
    }

    private func tip(_ text: String, _ pane: String, _ link: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("• " + text)
            Spacer()
            Button("Open \(pane)") { store.menu.open(link) }.controlSize(.small)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if store.step != .prerequisites {
                Button("Back") { store.go(Setup.Step(rawValue: store.step.rawValue - 1)!) }
            }
            Spacer()
            switch store.step {
            case .prerequisites:
                Button(store.prerequisitesOK ? "Continue" : "Continue Anyway") { store.go(.cloudflare) }
                    .keyboardShortcut(.defaultAction)
            case .cloudflare:
                if !Setup.needed(MiniRunConfig.load()) && store.deployed == nil {
                    Text("A Worker is already set up.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Continue") { store.go(.claude) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.working || (store.deployed == nil && Setup.needed(MiniRunConfig.load())))
            case .claude:
                Button(store.claudeConnected ? "Continue" : "Skip for Now") { store.go(.github) }.keyboardShortcut(.defaultAction)
            case .github:
                Button("Continue") { store.go(.headless) }.keyboardShortcut(.defaultAction)
            case .headless:
                Button("Done") {
                    store.menu.configChanged()
                    dismissWindow(id: WindowID.setup)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
