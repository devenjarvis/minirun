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
| Control socket (`~/.config/minirun/control.sock`) | One command, `status`. Its doc comments already mention "the menu bar app" | Add more commands (Phase 0) |
| `ServeStatus` | Relay state, simulators (reservation, busy, booting, viewer link), jobs | The menu shows this almost as-is |
| Config | `config.json`, read **once** at startup; `ToolRegistry.config` is a `let` | Needs reloading (Phase 0) |
| `minirun doctor` | Lives in `Sources/minirun/main.swift` and prints to stdout | Move it into a library so the app can show the same checks |
| Worker deploy | `worker/setup.sh`: `npm ci`, `wrangler login` in a browser, `wrangler deploy`, `wrangler secret put`. Writes the password and token in plain text to `worker.env` | Swift Cloudflare API client (Phase 2) |
| Frameworks | `build-frameworks.sh` builds idb from source (5–10 min, needs XcodeGen) | Unchanged for source installs. Release zips include them |
| GitHub runner | `scripts/github-runner.sh` (install/status/uninstall) | Wrap it in Settings later |

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

### Phase 0: daemon groundwork (mostly Linux-testable)

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
- **Footer:** Open live view, Copy connector URL, Copy password, Restart service, Settings…, Quit.
- **Data:** poll `status` every 2 s while the menu is open and every 15 s while it's closed.
- **"Not running" state:** offer "Start" (`launchctl kickstart`) and show the last lines of
  `~/Library/Logs/minirun/minirun.log`.

### Phase 2: deploy the Worker from Swift (removes node from the Mac)

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

**Credentials.** The user creates a Cloudflare API token from a custom template. The plan is
Account → Workers Scripts: Edit, Workers KV Storage: Edit, and Account Settings: Read; confirm
the exact minimum during implementation. Store it in `~/.config/minirun/cloudflare-token` (0600),
because Worker updates need it later. "Forget token" deletes it. The owner password moves from
`worker.env` to `~/.config/minirun/secrets.json` (0600). An existing `worker.env` is read
once and adopted.

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

### Phase 3: the app owns the install

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

### Phase 4: settings and first-run setup

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

### Phase 5: lightweight releases (optional, unsigned)

- A `release.yml` workflow on tags. It builds the app on `macos-26`, using the existing
  frameworks cache, ad-hoc signs it, zips it, and attaches the zip to a GitHub Release.
- The README explains that the build is unsigned. After unzipping, run
  `xattr -dr com.apple.quarantine /Applications/minirun.app`, or allow it under System Settings →
  Privacy & Security → Open Anyway. Building from source stays the recommended path.
- No Homebrew cask and no Sparkle for now: Homebrew is moving away from casks that fail
  Gatekeeper, and auto-updating unsigned code is not worth the risk. Instead, the menu shows "A
  newer version is available" by checking the latest GitHub release tag, and links to it.

### Phase 6: polish

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
| 3 App owns the install | M | Yes: one `install.sh` produces `/Applications/minirun.app` |
| 4 Settings + first run | M | Yes: no terminal after install |
| 5 Unsigned releases | S | Yes: download instead of build |
| 6 Polish | S each | — |

Phases 0+1 and Phase 2 don't depend on each other and can be worked on in parallel. Phase 4's
Cloudflare screens need Phase 2.
