# minirun as a Mac menu bar app: plan

Goal: install minirun by dragging an app to /Applications, then set it up, watch it and change its
settings from the menu bar. You should not need a terminal, `install.sh`, `minirun setup` or
editing `config.json` by hand.

## Where things stand

What exists today, and how much of it the app can reuse:

| Piece | Today | Reuse in the app |
| --- | --- | --- |
| `minirun serve` (Swift daemon) | Built with `swift build`, copied to `~/.minirun/bin` along with 4 FBSimulatorControl frameworks, run by a hand-written LaunchAgent (`dev.minirun.agent`) | **Keep as a separate process.** Bundle it inside the app and register it with `SMAppService` |
| `MiniRunKit` | Plain Swift: config, status model, control-socket protocol, simulator picker. Tests run on Linux | **The app links this directly.** It never needs FBSimulatorControl |
| Control socket (`~/.config/minirun/control.sock`) | One command, `status`. Its doc comments already mention "the menu bar app" | Add more commands (see Phase 0) |
| `ServeStatus` | Relay state, simulators (reservation, busy, booting, viewer link), jobs | The menu shows this almost as-is |
| Config | `config.json`, read **once** at startup; `ToolRegistry.config` is a `let` | Needs reloading (Phase 0) |
| `minirun doctor` | Lives in `Sources/minirun/main.swift` and prints to stdout | Move it into a library so the app can show the same checks |
| Worker deploy | `worker/setup.sh`: needs node and wrangler, `wrangler login` in a browser, and writes the password and token in plain text to `worker.env` | Biggest onboarding hurdle (Phase 4) |
| Frameworks | `build-frameworks.sh` builds idb from source (5–10 min, needs XcodeGen) | Build them once in CI and ship them inside the app |
| GitHub runner | `scripts/github-runner.sh` (install/status/uninstall) | Wrap it in Settings later |
| Distribution | None: you clone the repo and build it on the Mac | Signed, notarized `.app`, with automatic updates |

Two constraints shape everything below:

- **No sandbox, no App Store.** minirun uses private CoreSimulator/SimulatorKit frameworks and runs
  `xcodebuild`, `simctl` and `git`. Ship it as a Developer ID–signed, notarized app outside the
  App Store (GitHub Releases, a Homebrew cask, and Sparkle for updates).
- **The Mac and the Worker must be updated together** (README limitations). The app should ship
  both and keep their versions in step.

## Architecture decision: the app supervises the daemon

```
minirun.app/
  Contents/MacOS/minirun-menu          SwiftUI MenuBarExtra (links MiniRunKit only)
  Contents/Helpers/minirun             the existing CLI and daemon, unchanged
  Contents/Frameworks/FB*.framework    FBSimulatorControl, FBControlCore, FBDeviceControl, XCTestBootstrap
  Contents/Library/LaunchAgents/dev.minirun.agent.plist   → BundleProgram Contents/Helpers/minirun serve
  Contents/Resources/worker/           prebuilt Worker bundle, for deploys and updates
```

Recommended: **don't** run the server inside the menu bar process. Keep `minirun serve` as a
launchd agent that the app registers with `SMAppService.agent(plistName:)`:

- Quitting or updating the menu bar app doesn't drop Claude's sessions or live views.
- If the daemon crashes inside the private frameworks, launchd restarts it (`KeepAlive`, as it
  does today). The UI stays up and shows "restarting".
- The UI never links private frameworks, so it builds quickly and stays small.
- `minirun status` and `minirun call` keep working. Offer "Install command line tool…" to symlink
  `Contents/Helpers/minirun` into `/usr/local/bin`.

The app talks to the daemon only over the control socket. It edits `config.json` through
`MiniRunConfig`, then asks the daemon to reload it.

## Phases

Each phase can ship as one or more PRs, and each leaves the product working.

### Phase 0: daemon groundwork (mostly Linux-testable)

1. **More control commands** in `ControlProtocol`. Keep it one request line and one response line:
   - `reload_config`: re-read `config.json`. Reports which changes took effect now and which
     need a restart (`relayURL` and `agentToken` mean reconnecting).
   - `shutdown_simulator {udid}`, `release_simulator {udid}`: the same code paths as the tools.
   - `cancel_job {id}` (needs job cancellation in `JobStore`/`Shell`; it doesn't exist yet).
   - `workspaces`: list checkouts with size and last use. `delete_workspace {path}` refuses one
     with a running job.
   - `doctor`: the same checks as `minirun doctor`, as structured results (see 3).
   - Bump a `controlVersion` in the response so the app can detect an older daemon.
2. **Config hot reload.** Replace `ToolRegistry.config: let` with a locked box (or actor) that is
   read at each use. `idleShutdownMinutes`, `maxBootedSimulators`, `defaultDevice`, `allowShell`,
   `workspaceRoot` and `preventSleep` apply right away. Relay changes make `RelayClient`
   reconnect. Also reload on `SIGHUP`, so a hand-edited file works too.
3. **Move `doctor` into a library.** Put it in MiniRunCore, returning `[DoctorCheck {id, ok, detail, fix}]`.
   The CLI prints it and the app renders it as a checklist with "Fix" buttons.
4. **Report versions.** `ServeStatus` gains the relay protocol version the Worker reported. That
   needs a small Worker change: its reply to `hello` includes its own version. Then the app can say
   "Worker is out of date — update it".
5. **Structured log file.** Today launchd sends stderr to `~/Library/Logs/minirun/minirun.log`.
   Keep that, and add `os_log` so Console.app filtering works. The app reads the file.

Tests: protocol encoding and decoding, config diffing (what reloads and what needs a restart), the
workspace listing, and doctor result shapes. All of this lives in MiniRunKit, so it runs on Linux CI.

### Phase 1: menu bar app MVP (works with today's script install)

A new `App/` folder with an XcodeGen `project.yml`. The repo already uses XcodeGen, and the
`.xcodeproj` stays gitignored. One target, `minirun-menu`, depends on the local `MiniRunKit`
package product. SwiftUI `MenuBarExtra` with `.menuBarExtraStyle(.window)`. macOS 14 minimum,
which matches `Package.swift`.

- **Icon** shows the state: connected, connecting, disconnected or problem, and not running. Add a
  small badge while jobs are running.
- **Status header:** "Connected to minirun.you.workers.dev · 3h", or the relay's `problem`
  (for example, a rejected token) with a fix.
- **Simulators:** name, runtime, who it's reserved for, booting/busy/idle, and last used.
  Per-row actions: Watch live (opens `viewerURL`), Show in Simulator.app, Release, Shut down.
- **Jobs:** running and recent, with elapsed time and title. Open log, Cancel.
- **Footer:** Open live view, Copy connector URL, Restart service, Settings…, Quit.
- **Data:** poll `status` every 2 s while the menu is open and every 15 s while it's closed. An
  event stream can come later. The status model is already `Codable`.
- **"Not running" state:** offer "Start" (`launchctl kickstart`) and show the last lines of the log.

This is useful right away for existing installs, and it changes nothing in the daemon's lifecycle.

### Phase 2: the app owns the install

- Build pipeline: `swift build -c release` for the `minirun` binary, then `xcodebuild` the app,
  then copy the binary into `Contents/Helpers` and the frameworks into `Contents/Frameworks`. The
  daemon's rpath needs `@executable_path/../Frameworks`. Today it's `@executable_path` and
  `@executable_path/Frameworks`, so add one entry to `Package.swift`.
- Register the daemon with `SMAppService.agent(plistName: "dev.minirun.agent.plist")`. Use
  `SMAppService.mainApp` for "Open at login". Handle `.requiresApproval` by opening
  System Settings → Login Items.
- **Migration:** if `~/Library/LaunchAgents/dev.minirun.agent.plist` exists (an `install.sh`
  install), boot it out, remove it, and keep `~/.config/minirun` and `~/minirun/workspaces`.
  `install.sh --uninstall` should also learn to remove the app's registration.
- **Risk to check first:** hardened runtime with FBSimulatorControl. It loads Xcode's private
  frameworks at runtime. Those are Apple-signed, so library validation should allow them, but
  confirm it before building on it. The fallback is the
  `com.apple.security.cs.disable-library-validation` entitlement on the helper only.
- Keep `install.sh` working for people building from source, as a thin wrapper that builds the
  app bundle.

### Phase 3: settings window

A SwiftUI `Settings` scene, with one tab per area. Each field maps to a `MiniRunConfig` key.
Saving writes the config and then sends `reload_config`.

- **General:** Open at login, Keep Mac awake (`preventSleep`), Install command line tool, and an
  update channel once Sparkle lands.
- **Connection:** Worker URL, agent token (hidden, with a Rotate button), owner password (Reveal,
  Copy, Rotate), connector URL with Copy, and a "Test connection" button.
- **Simulators:** a default device picker filled from `simctl list` (the same rule as today: newest
  Pro, never SE or Duo), idle shutdown minutes, and max booted simulators.
- **Workspaces:** a folder picker for `workspaceRoot`, a table of checkouts with size and last use,
  and Delete / Delete all older than N days. This addresses the "delete old ones by hand"
  limitation.
- **Security:** a `run_command` toggle with a clear warning sheet. It explains that anyone with
  a connector token can run shell commands.
- **Diagnostics:** the doctor checklist, Open log, Copy diagnostics (versions and redacted
  config), and Reveal config in Finder.

### Phase 4: first-run onboarding, including the Worker

A step-by-step window that opens the first time the app runs, or when config has no relay:

1. **Prerequisites:** Xcode is installed and selected, the license is accepted, an iOS runtime
   is present, and the simulator frameworks load. Each check gets a "Fix" or "How to" button.
   XcodeGen and gh become optional; the frameworks now come with the app.
2. **Cloudflare.** Two options; pick one:
   - **A (quicker to build):** run the bundled `worker/setup.sh` and stream its output into the
     window. This still needs node, plus wrangler's browser login.
   - **B (recommended in the end):** deploy natively with the Cloudflare API and a scoped API
     token the user pastes. The app links to the token-creation page with the needed permissions:
     Workers Scripts edit, Workers KV edit, account read. The app uploads the prebuilt Worker module from
     `Resources/worker`, creates the KV namespace, applies the Durable Object migration,
     sets the `OWNER_PASSWORD` and `AGENT_TOKEN` secrets, and enables workers.dev. This removes node
     and wrangler from the user's Mac entirely. It also gives one-click **Worker updates**
     when the app's bundled Worker is newer than the deployed one. CI produces the Worker bundle
     (`wrangler deploy --dry-run --outdir`).
3. **Connect Claude:** show the connector URL and password with Copy buttons, and a "Waiting for
   Claude to connect…" indicator. This needs the Worker to expose "an OAuth client was approved"
   in `/status`, or the daemon to see its first tool call.
4. **GitHub (optional):** check `gh auth status`, and offer to run `gh auth login` in Terminal
   for private repositories.
5. **Headless Mac mini tips:** auto-login, never sleep, and Screen Sharing. Link to the Energy
   settings.

**Secrets:** move `agentToken` and `OWNER_PASSWORD` into the login Keychain. Today they sit in
`config.json` and `worker.env` in plain text. The daemon reads the token from the Keychain under
the same user, falling back to `config.json` for script installs. This needs stable code
signing (Phase 5); with ad-hoc signing, macOS asks for Keychain access again after every rebuild.

### Phase 5: distribution and updates

- A `release.yml` workflow on tag pushes. It restores or builds the frameworks (the existing
  cache key), builds the daemon, builds the app, and signs with Developer ID using the hardened
  runtime. It then notarizes with `notarytool`, staples the ticket, makes a DMG and a zip, and
  updates the Sparkle appcast. Finally it publishes a GitHub Release.
- Sparkle 2 for in-app updates. An update replaces the bundle and restarts the daemon only when
  no jobs are running, or after asking.
- A Homebrew cask (`brew install --cask minirun`) in a tap repo.
- Version checks: the app, daemon and bundled Worker share one version. The menu warns when the
  deployed Worker is older.
- macOS CI: add an `xcodebuild` of the app next to the existing smoke test, and check that the
  bundled daemon starts from inside the `.app` (rpaths and signing).

### Phase 6: polish

- Notifications, all optional: relay disconnected for more than 5 minutes, a build or test job
  failed, and a simulator was shut down at the cap.
- **GitHub runners tab:** list, add and remove, wrapping `github-runner.sh`. Keep its public-repo
  refusal and warning.
- Menu shortcuts to the open follow-ups in `docs/simulator-lifecycle-followups.md`, for example
  "Delete stale simulator copies".
- Option to show the live view in an app window (WKWebView on the viewer URL) as well as the browser.

## Suggested order and size

| Phase | Size | Ships value on its own? |
| --- | --- | --- |
| 0 Daemon groundwork | M | Partly (`minirun status`/`doctor` improve) |
| 1 Menu bar MVP | M | **Yes**: status and control for existing installs |
| 2 App owns the install | M | Yes: no more LaunchAgent script |
| 3 Settings | M | Yes: no more editing `config.json` |
| 4 Onboarding + native Worker deploy | L | Yes: no terminal needed |
| 5 Release pipeline | M | Yes: downloadable, auto-updating app |
| 6 Polish | S each | — |

Phases 0 and 1 can go in together. Do the hardened-runtime check (Phase 2) early, because it
decides whether the bundling plan works as written.

## Open questions

1. **Apple Developer ID.** Is there a paid Apple Developer account to sign and notarize with?
   Without one the app still works for you, but other people get Gatekeeper warnings, and
   Keychain storage is clumsy.
2. **Worker deploy approach.** Is option A (wrap `setup.sh`, keep node) fine for a first version,
   or go straight to option B (native API, no node)?
3. **Audience.** Just your own Mac, or something others will install? That decides how much of
   Phases 4–5 matters now.
4. **Name and bundle ID**, for example `dev.minirun.app`. Keep the daemon label `dev.minirun.agent`
   so migration stays simple.
