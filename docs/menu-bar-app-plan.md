# minirun as a Mac menu bar app: plan

Goal: set minirun up, watch it and change its settings from the menu bar. You should not need
a terminal after the first install, nor `minirun setup`, `worker/setup.sh` or editing `config.json` by
hand.

## Decisions

- **Open source, built mainly for one person's Mac.** No marketing and no polished distribution
  for now. Building from source is the main way to install; a downloadable build is a bonus.
- **No paid Apple Developer account yet.** The app is ad-hoc signed: no notarization, no
  hardened runtime, and no Keychain-dependent features. "Later, with Developer ID" lists what
  that unlocks.
- **Deploy the Worker with the Cloudflare API, from Swift.** The Mac no longer needs node,
  npm or wrangler. The Worker itself stays TypeScript, because Cloudflare Workers run
  JavaScript. (Swift compiled to Wasm could run there in principle, but it would mean rewriting
  the OAuth provider and the relay for no gain.) Node stays a developer-only tool, for Worker
  tests and for producing the Worker bundle.

## Where things stand

| Piece | Today | In the app |
| --- | --- | --- |
| `minirun serve` (Swift daemon) | Built with `swift build`, copied to `~/.minirun/bin` with 4 FBSimulatorControl frameworks, run by a hand-written LaunchAgent (`dev.minirun.agent`) | **Keep it as a separate process.** Bundle it inside the app; the app writes the LaunchAgent |
| `MiniRunKit` | Plain Swift: config, status model, control-socket protocol, simulator picker. Tests run on Linux | **The app links this directly.** It never needs FBSimulatorControl |
| Control socket (`~/.config/minirun/control.sock`) | `status`, `reload_config`, simulator, job and workspace commands, `doctor` (Phase 0, done) | The app's only link to the daemon |
| Install | `install.sh` builds everything into `/Applications/minirun.app` and runs `minirun agent install` (Phase 3, done) | The app repoints the LaunchAgent at its own helper when it opens |
| `ServeStatus` | Relay state, simulators (reservation, busy, booting, viewer link), jobs | The menu shows this almost as-is |
| Config | `config.json`, reloaded live by `reload_config`, `minirun reload` or SIGHUP (Phase 0, done) | The app edits it, then asks for a reload |
| `minirun doctor` | `Doctor` in MiniRunKit returns structured checks; the CLI prints them (Phase 0, done) | Settings → Diagnostics and the setup window (Phase 4, done) |
| Worker deploy | `worker/setup.sh`: `npm ci`, `wrangler login` in a browser, `wrangler deploy`, `wrangler secret put`. Writes the password and token in plain text to `worker.env` | Swift Cloudflare API client (Phase 2) |
| Frameworks | `build-frameworks.sh` builds idb from source (5–10 min, needs XcodeGen) | Unchanged for source installs. Release zips include them |
| GitHub runner | `scripts/github-runner.sh` (install/start/stop/status/uninstall) | Settings → GitHub Runners and a menu section run the bundled script (Phase 6, done) |

## Architecture: the app supervises the daemon

```
minirun.app/
  Contents/MacOS/minirun-menu          SwiftUI MenuBarExtra (links MiniRunKit only)
  Contents/Helpers/minirun             the existing CLI and daemon
  Contents/Frameworks/FB*.framework    FBSimulatorControl, FBControlCore, FBDeviceControl, XCTestBootstrap
  Contents/Resources/worker/           the prebuilt Worker bundle (index.js + manifest.json)
```

Don't run the server inside the menu bar process. Keep `minirun serve` as a launchd agent:

- Quitting or rebuilding the menu bar app doesn't drop Claude's sessions or live views.
- If the daemon crashes inside the private frameworks, launchd restarts it (`KeepAlive`, as it
  does today). The UI stays up and shows "restarting".
- The UI never links private frameworks, so it builds quickly and stays small.
- `minirun status`, `minirun call` and the new `minirun worker …` keep working.

**The LaunchAgent stays a plain plist** in `~/Library/LaunchAgents/dev.minirun.agent.plist`,
written by the app. Its `ProgramArguments` point into `minirun.app/Contents/Helpers/minirun`.
`SMAppService.agent` is tidier, but with ad-hoc signing it adds failure modes this repo
doesn't have today. A plain plist is what `install.sh` already does, doesn't depend on signing,
and makes migration a one-line path change. Revisit with Developer ID. "Open at login" for the
menu bar app itself uses `SMAppService.mainApp`. If that fails with ad-hoc signing, use a
second small LaunchAgent that runs `open -a minirun`.

The app talks to the daemon only over the control socket. It edits `config.json` through
`MiniRunConfig`, then asks the daemon to reload it.

## Phases

Each phase can ship as one or more PRs, and each leaves the product working.

### Phase 0: daemon groundwork (mostly Linux-testable) — done

Built as planned, except:
- `controlVersion` is 2. A daemon from before it sends none, which the app reads as 1 (status only).
- `DoctorCheck` and the checks live in MiniRunKit (`Doctor.swift`), not MiniRunCore. The parts that
  need macOS (running programs, loading the simulator frameworks, asking the daemon) are passed in,
  so the checks are tested on Linux. Checks also carry a `title` and an `optional` flag (GitHub auth
  is optional).
- `ToolRegistry.config` is now a computed property over a `LiveConfig` (a locked box with
  observers). Observers make `RelayClient` reconnect and take or drop the sleep assertion. Idle
  shutdown re-reads `idleShutdownMinutes` every minute, so it can be turned on without a restart.
- `cancel_job` marks the job cancelled at once and cancels its task; `Shell.run` stops the program
  and its children when its task is cancelled.
- A checkout counts as busy while a sync or build holds its lock or `run_command` runs inside it.
  `delete_workspace` takes the checkout's lock while it deletes, so a build can't start mid-delete,
  and only deletes folders exactly two levels under `workspaceRoot`.
- Also added: `minirun reload`, `minirun doctor --json`, and `minirun setup` asks a running daemon
  to reload.
- Not done: item 4 (the Worker reporting its version in its reply to `hello`). It's left for
  Phase 4, where the app first needs it.


1. **More control commands** in `ControlProtocol`. Keep it one request line and one response line:
   - `reload_config`: re-read `config.json`. Reports which changes took effect now and which
     mean reconnecting (`relayURL`, `agentToken`).
   - `shutdown_simulator {udid}`, `release_simulator {udid}`: the same code paths as the tools.
   - `cancel_job {id}` (needs job cancellation in `JobStore`/`Shell`; it doesn't exist yet).
   - `workspaces`: list checkouts with size and last use. `delete_workspace {path}` refuses one
     with a running job.
   - `doctor`: the same checks as `minirun doctor`, as structured results (see 3).
   - A `controlVersion` in every response, so the app can detect an older daemon.
2. **Config hot reload.** Replace `ToolRegistry.config: let` with a locked box (or actor) that is
   read at each use. `idleShutdownMinutes`, `maxBootedSimulators`, `defaultDevice`, `allowShell`,
   `workspaceRoot` and `preventSleep` apply right away. Relay changes make `RelayClient`
   reconnect. Also reload on `SIGHUP`, so a hand-edited file works too.
3. **Move `doctor` into a library.** Put it in MiniRunCore, returning `[DoctorCheck {id, ok, detail, fix}]`.
   The CLI prints it and the app renders it as a checklist with "Fix" buttons.
4. **Report versions.** The Worker includes its version in its reply to the Mac's `hello`, and
   `ServeStatus.relay` carries it. That lets the app say "the Worker is out of date — update it".

Tests: protocol encoding and decoding, config diffing (what reloads and what reconnects), the
workspace listing, and doctor result shapes. All of this lives in MiniRunKit, so it runs on Linux CI.

### Phase 1: menu bar app MVP (works with today's script install) — done

Built as planned, except:
- `App/project.yml` compiles `Sources/MiniRunKit` into a static library target instead of
  depending on the package product. On macOS the root package also declares the FBSimulatorControl
  binary targets, which exist only after `build-frameworks.sh`, so depending on the package would
  make the app need the frameworks to build. The app still links nothing else.
- The app is `minirun.app` (target `minirun-menu`, bundle id `dev.minirun.menu`).
- The view model is `MenuSnapshot` (pure: one poll in, what the menu shows out) and `MenuModel` (an
  actor that polls and runs actions) in MiniRunKit, tested on Linux. The SwiftUI side is a thin
  `@Observable` wrapper plus the AppKit bits (pasteboard, opening links, Simulator.app).
- No Settings… item yet (Phase 4). "Open at login" is left to System Settings → Login Items.
- `scripts/install-app.sh` builds, ad-hoc signs and installs `/Applications/minirun.app`;
  `install.sh` runs it (skip with `--no-app`), and the macOS CI job builds the app.


A new `App/` folder with an XcodeGen `project.yml`. The repo already uses XcodeGen, and the
`.xcodeproj` stays gitignored. One target, `minirun-menu`, depends on the local `MiniRunKit`
package product. SwiftUI `MenuBarExtra` with `.menuBarExtraStyle(.window)`. macOS 26 minimum,
which matches `Package.swift`.

- **Icon** shows the state: connected, connecting, disconnected or problem, and not running. Add a
  small badge while jobs are running.
- **Status header:** "Connected to minirun.you.workers.dev · 3h", or the relay's `problem`
  (for example, a rejected token) with a fix.
- **Simulators:** name, runtime, who it's reserved for, booting/busy/idle, and last used.
  Per-row actions: Watch live (opens `viewerURL`), Show in Simulator.app, Release, Shut down.
- **Jobs:** running and recent, with elapsed time and title. Open log, Cancel.
- **Footer:** Open live view, Copy connector URL, Copy password, Restart service, Settings…, Quit.
- **Data:** poll `status` every 2 s while the menu is open and every 15 s while it's closed.
- **"Not running" state:** offer "Start" (`launchctl kickstart`) and show the last lines of
  `~/Library/Logs/minirun/minirun.log`.

### Phase 2: deploy the Worker from Swift (removes node from the Mac) — done

Built as `minirun worker deploy|status|password|forget-token` (`Sources/MiniRunKit/Cloudflare.swift`,
`WorkerDeploy.swift`, `WorkerCommand.swift`). Differences from the sketch below:
- All the Worker's settings are in one file, `~/.config/minirun/worker.json` (0600): account,
  URL, owner password and API token. The agent token stays in `config.json`.
- The deployed version is a `MINIRUN_BUNDLE` text variable holding the bundle's SHA-256. It is read
  back from the script settings, so `minirun worker status` can say whether the Worker is current.
- A changed relay URL or agent token is applied with `reload_config`; the LaunchAgent is restarted
  only if the daemon doesn't answer (or is too old to reload).
- Not yet checked against the live API: it follows the calls wrangler 4.155 makes, and is tested
  against recorded responses.

**Worker bundle.** A developer script, `worker/scripts/bundle.mjs` (`npm run bundle`), runs
`wrangler deploy --dry-run --outdir dist`. It also writes `dist/manifest.json` from
`wrangler.jsonc`, so that file stays the single source of truth. The manifest holds the version,
compatibility date and flags, the Durable Object classes and migrations, and the binding names.
**`worker/dist/` is committed**, so building from source needs no node. A CI step re-bundles it
and fails on `git diff --exit-code worker/dist` if someone forgets.

**Swift Cloudflare client.** It lives in `Sources/MiniRunKit/Cloudflare/` and uses Foundation and
FoundationNetworking only, so it builds and is tested on Linux.

- `CloudflareAPI`: a small typed client over `https://api.cloudflare.com/client/v4`, with
  Bearer-token auth and the `{success, errors, result}` response wrapper. It takes a transport
  protocol so tests can stub HTTP.
- `WorkerDeployer`: idempotent steps, each reporting progress for the CLI and the UI:
  1. **Check the token** (`GET /user/tokens/verify`) and pick the account (`GET /accounts`). If
     there are several, ask which one.
  2. **workers.dev subdomain** (`GET /accounts/{a}/workers/subdomain`). If the account has none,
     ask for one and create it.
  3. **KV namespace.** Find one whose title ends in `OAUTH_KV`, which adopts a namespace that
     `setup.sh` created. Otherwise create `minirun-OAUTH_KV`.
  4. **Upload the script**: `PUT /accounts/{a}/workers/scripts/minirun` as multipart. One part
     is `index.js` (`application/javascript+module`). The other is the metadata:
     `main_module`, `compatibility_date`/`_flags`, the bindings (Durable Object `MAC_RELAY` →
     `MacRelay`, KV `OAUTH_KV`) and `observability`. It also carries `migrations`, with
     `old_tag` set to the deployed migration tag from the scripts listing, so
     `new_sqlite_classes: [MacRelay]` applies only once. On first deploy or rotation the
     secrets go in as `secret_text` bindings. Otherwise `keep_bindings: ["secret_text"]`
     leaves them alone.
  5. **Turn on workers.dev** (`POST …/scripts/minirun/subdomain {enabled: true}`). The URL is
     `https://minirun.<subdomain>.workers.dev`.
  6. **Save and verify.** Write `relayURL` and `agentToken` to config and send `reload_config`.
     Then check that `GET <url>/login` returns 200, and wait for the daemon to report `connected`.
- Rotation: `PUT …/scripts/minirun/secrets` for `OWNER_PASSWORD` or `AGENT_TOKEN`. A new token
  is saved to config and followed by `reload_config`, so the Mac reconnects without a restart.

**Credentials.** The user creates a Cloudflare API token from Cloudflare's "Edit Cloudflare
Workers" template. It includes Account Settings: Read, Workers Scripts: Edit and Workers KV
Storage: Edit. The token is saved because Worker updates need it later; "Forget token" deletes
it. An existing `worker.env` is adopted, and kept in step while it exists, because `setup.sh`
reads it.

**CLI**, which replaces `worker/setup.sh`:
`minirun worker deploy [--account ID] [--new-password] [--new-token]`, `minirun worker status`
(deployed vs bundled version), and `minirun worker password` (prints it). `install.sh` calls
`minirun worker deploy` and no longer installs node. `setup.sh` and `npm run deploy` stay
for Worker development only.

**Testing.**
- Linux unit tests against recorded API responses: multipart shape, metadata JSON,
  adopting an existing KV namespace and migration tag, choosing `keep_bindings` versus secrets,
  and error mapping ("token lacks Workers KV permission" rather than a raw 403).
- An opt-in CI job, run only when a `CLOUDFLARE_API_TOKEN` repository secret exists, deploys to a
  throwaway script name (`minirun-ci`) and checks `/login`.
- The existing `wrangler dev` e2e test keeps covering the relay itself.

### Phase 3: the app owns the install — done

Built as planned, except:
- `scripts/install-app.sh --with-daemon BIN_DIR` assembles the bundle (Helpers, Frameworks,
  Resources/worker), signs the frameworks, the helper and then the app, and runs
  `Contents/Helpers/minirun version` once so a broken rpath fails the build. CI and releases build
  the app this way.
- The plist is written by Swift (`LaunchAgent.plist(program:)` in MiniRunKit), through a new
  `minirun agent install|uninstall`. `install.sh` calls it, so the plist has one source.
- `LaunchAgent.plan` decides what the app does at launch: install the agent if there's none, keep
  it if it already runs this helper, and repoint it if it runs `~/.minirun/bin/minirun`, a copy
  that's gone, or (when this app is in an Applications folder) any other copy. A build run from
  Xcode or `.build/` never takes over a working install. The app leaves `~/.minirun/bin` on disk
  and says it can be deleted; `install.sh` deletes it.
- `install.sh --no-app` keeps the old `~/.minirun/bin` layout, for Macs that only serve CI.
- "Install command line tool…" is in Settings → General. It runs `ln -sf` through AppleScript's
  `with administrator privileges`.


- `install.sh` becomes "build the app":
  1. Build the frameworks (unchanged) and the daemon.
  2. Run `xcodebuild` on the app.
  3. Assemble the bundle (Helpers, Frameworks, Resources/worker).
  4. Ad-hoc sign it (`codesign -s -`) and copy it to `/Applications`.
  5. Open it.
  An app built locally has no quarantine flag, so Gatekeeper doesn't get involved.
- The daemon's rpath gains `@executable_path/../Frameworks` in `Package.swift`.
- On launch, the app makes sure the LaunchAgent plist points at its own Helpers binary. If an
  old `~/.minirun/bin` install is found, it rewrites the plist and restarts the daemon,
  keeping `~/.config/minirun` and `~/minirun/workspaces`.
- "Install command line tool…" symlinks the helper into `/usr/local/bin/minirun`, with an
  admin prompt.
- `install.sh --uninstall` removes the app, the LaunchAgent and the symlink.

### Phase 4: settings and first-run setup — done

Built as planned, except:
- `WorkerManager` (MiniRunKit) holds deploy, status, rotate and forget-token; `minirun worker`
  and the app both use it. Rotation sets just the one secret with `PUT …/secrets`.
- Phase 0 item 4 is in: the Worker answers `hello` with `{type: "welcome", bundle: MINIRUN_BUNDLE}`
  and `ServeStatus.relay.workerBundle` carries it, so the menu says "the Worker is out of date"
  without an API token. `relay.lastCallAt` (the last call from Claude, not the viewer) is how the
  setup window sees "Claude is connected"; the Worker's `/status` isn't used.
- The pure parts are in MiniRunKit and tested on Linux: `SettingsForm` (validation, and saving
  onto a fresh read of config.json so a token written meanwhile isn't lost), the device picker's
  choices, `WorkspaceInventory.stale`, `Diagnostics.report` (no secrets), `Setup` (when to show the
  window, the deploy checklist) and `AppDoctor` (the daemon's `doctor`, or the helper's
  `doctor --json` when the daemon isn't running).
- Fixes that are commands ("sudo xcodebuild -license accept", `gh auth login`) open in Terminal.
- The token link is the dashboard's API Tokens page plus the template steps, not a prefilled
  template URL: Cloudflare's permission keys for those URLs aren't documented consistently.


**Settings window** (a SwiftUI `Settings` scene). Each field maps to a `MiniRunConfig` key, and
saving sends `reload_config`.

- **General:** Open at login, Keep Mac awake (`preventSleep`), Install command line tool.
- **Cloudflare:** account and Worker URL, deployed vs bundled Worker version with an
  **Update Worker** button, Rotate password, Rotate agent token, Copy connector URL, and Forget
  API token.
- **Simulators:** a default device picker filled from `simctl list` (the same rule as today: newest
  Pro, never SE or Duo), idle shutdown minutes, and max booted simulators.
- **Workspaces:** a folder picker for `workspaceRoot`, a table of checkouts with size and last
  use, and Delete / Delete all older than N days.
- **Security:** a `run_command` toggle with a warning sheet explaining that anyone with a
  connector token can run shell commands.
- **Diagnostics:** the doctor checklist, Open log, Copy diagnostics (versions and redacted
  config), and Reveal config in Finder.

**First-run window**, shown when there's no relay in the config:

1. **Prerequisites:** Xcode is installed and selected, the license is accepted, an iOS runtime
   is present, and the simulator frameworks load. Each check gets a Fix or How-to button.
2. **Cloudflare:** a link to create the API token with the needed permissions, a paste field,
   an account picker, then the deploy steps from Phase 2 shown as a live checklist.
3. **Connect Claude:** the connector URL and password with Copy buttons, and "Waiting for
   Claude…". This needs `/status` on the Worker to report that an OAuth client was approved,
   or the daemon to see its first tool call.
4. **GitHub (optional):** check `gh auth status` and offer `gh auth login` in Terminal for
   private repositories.
5. **Headless Mac mini tips:** auto-login and never sleep, with links to the right settings panes.

### Phase 5: lightweight releases (optional, unsigned) — done

Built as planned: `.github/workflows/release.yml` runs on `v*` tags (or by hand with a tag),
checks the tag matches `MiniRun.version`, builds with the frameworks cache, and attaches
`minirun-<version>.zip` and its SHA-256 to the release. The helper is built for the runner's
architecture, so release builds are Apple silicon only. `MiniRun.version` moved to MiniRunKit
(now 0.2.0) so the app can compare it, and a test keeps `MARKETING_VERSION` in step.
`UpdateCheck` asks GitHub's latest-release API and ignores drafts and pre-releases.

**Automatic updates (added after the plan, to leave the Mac alone).** This reverses the "no
auto-updating unsigned code" call below: the Mac is meant to run without visits, and the
releases come from this repository's own workflow. Safeguards in place of a signature:
- The zip must match its SHA-256: GitHub's asset `digest`, else the `.sha256` asset.
- The unzipped app must have bundle id `dev.minirun.menu`, the release's version, a valid
  (ad-hoc) signature, and a helper that starts and reports that version. The new copy is checked
  again after it is moved into `/Applications`; if it fails there, the old copy goes back.
- It only installs while no job runs and no simulator is busy (`Updater.decide`), then restarts
  `minirun serve` (`launchctl kickstart -k`) and relaunches the app.
- After an update, the app redeploys the Worker if it runs other code, using the saved API token
  (once per launch; failures are notified, not retried in a loop).
- On by default and checked every hour. The app turns Open at login on once, at its first
  launch from `/Applications`. Both can be switched off in Settings → General.
The logic is in `Updater` (MiniRunKit, tested on Linux); the download and swap are in
`App/Sources/AppUpdater.swift`. Still manual: pushing the release tag.


- A `release.yml` workflow on tags. It builds the app on `macos-26`, using the existing
  frameworks cache, ad-hoc signs it, zips it, and attaches the zip to a GitHub Release.
- The README explains that the build is unsigned. After unzipping, run
  `xattr -dr com.apple.quarantine /Applications/minirun.app`, or allow it under System Settings →
  Privacy & Security → Open Anyway. Building from source stays the recommended path.
- No Homebrew cask and no Sparkle for now: Homebrew is moving away from casks that fail
  Gatekeeper. (The original plan also ruled out auto-updating unsigned code; see "Automatic
  updates" above for why the app now does it, and how.)

### Phase 6: polish — partly done

Done: notifications (relay disconnected for 5 minutes, once per outage; a job failed; nothing
replayed from the first poll), with a switch in Settings → General; and the live view in an app
window (a WKWebView on the viewer URL, which keeps its login cookie). The GitHub runners tab:
the app carries `github-runner.sh` in Contents/Resources and runs it to add, start, stop and
remove runners; `GitHubRunners` in MiniRunKit reads what it installed, launchd's state and
GitHub's view (through gh). The script exits 3 when it refuses a public repository, and the app
then shows the warning and asks before passing `--allow-public`.

Not done yet:
- Notifying when a simulator is shut down at the cap: the status doesn't report that event.
- "Delete stale simulator copies": the daemon doesn't track copies yet
  (`docs/simulator-lifecycle-followups.md`, item 2).


- Notifications, all optional: relay disconnected for more than 5 minutes, a build or test job
  failed, and a simulator was shut down at the cap.
- **GitHub runners tab:** list, add and remove, wrapping `github-runner.sh`. Keep its public-repo
  refusal.
- Menu actions for the open items in `docs/simulator-lifecycle-followups.md`, for example
  "Delete stale simulator copies".
- Option to show the live view in an app window (WKWebView on the viewer URL).

## Later, with Developer ID

- Hardened runtime and notarization. First check that FBSimulatorControl can still load Xcode's
  private frameworks with library validation. The fallback is
  `com.apple.security.cs.disable-library-validation` on the helper only.
- Move the agent token, password and Cloudflare token into the Keychain. With ad-hoc signing,
  every rebuild changes the code identity, so macOS would ask for Keychain access again.
- `SMAppService.agent` in place of the hand-written plist, Sparkle updates, and a Homebrew cask.

## Order and size

| Phase | Size | Ships value on its own? |
| --- | --- | --- |
| 0 Daemon groundwork | M | Partly (`minirun status`/`doctor` improve) |
| 1 Menu bar MVP | M | **Yes**: status and control for the existing install |
| 2 Swift Worker deploy | M–L | **Yes**: no node on the Mac; `minirun worker deploy` |
| 3 App owns the install (done) | M | Yes: one `install.sh` produces `/Applications/minirun.app` |
| 4 Settings + first run (done) | M | Yes: no terminal after install |
| 5 Unsigned releases (done) | S | Yes: download instead of build |
| 6 Polish (partly done) | S each | — |

Phases 0+1 and Phase 2 don't depend on each other and can be worked on in parallel. Phase 4's
Cloudflare screens need Phase 2.
