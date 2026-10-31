# minirun

Turn a Mac (a home Mac mini is ideal) into a runner that Claude can drive from anywhere: it
builds your iOS app, runs it in a simulator (or your macOS app on the Mac itself), taps through it, reads logs, runs tests, and streams
the simulator live to your phone or laptop's browser so you can watch and take over.

Everything runs on hardware you own plus Cloudflare's free plan. There's no domain to buy, no
open ports, and no tunnel to run.

```
 Claude (phone, web, laptop)            Your browser (phone/laptop)
        │  MCP over HTTPS + OAuth               │  live H.264 (or JPEG) + touches
        ▼                                       ▼
 ┌──────────────────── Cloudflare Worker (minirun.<you>.workers.dev) ────────────────────┐
 │  /mcp  OAuth-protected MCP endpoint      /  viewer (password login)                    │
 │                     └──────────► Durable Object relay ◄──────────┘                     │
 └──────────────────────────────────────────▲─────────────────────────────────────────────┘
                                            │ one outbound WebSocket (AGENT_TOKEN)
                                 ┌──────────┴──────────┐
                                 │  minirun serve (Mac) │  Swift daemon (launchd)
                                 │  xcodebuild · simctl │
                                 │  FBSimulatorControl  │  in-process touch, screen, accessibility
                                 └─────────────────────┘
```

## How it works

- **`minirun` (Swift, on the Mac)** links Meta's FBSimulatorControl (the framework inside idb)
  in-process for screen capture, touch/keyboard injection and accessibility trees. It uses
  AXe's vendored helpers for the hard parts, like Xcode 27's Device Hub and orientation. App
  lifecycle goes through `simctl`, and builds go through `xcodebuild`. It holds one outbound
  WebSocket to your Worker.
- **The Worker (TypeScript)** is a remote MCP server that Claude connects to as a custom
  connector, protected by OAuth that you approve with your password. Tool calls are forwarded
  to the Mac through a Durable Object. The same object fans the live screen out to browser viewers.
- **The live view is H.264.** The Mac encodes the simulator's display with VideoToolbox (the
  hardware encoder on Apple silicon), reading frames straight from the simulator's framebuffer,
  and the viewer decodes them with WebCodecs. Frames are only sent when the screen changes. A
  browser without WebCodecs gets JPEG frames instead, and so does everyone watching that simulator
  with it, since one stream serves all of a simulator's viewers.
- **Long work runs as jobs.** `build`, `build_and_run`, `run_tests`, `swift_test` and
  `run_command` return within `wait_seconds` (default 45, max 50, under the MCP client's 60-second
  request timeout). If the work is still going they return a `job_id`, and Claude waits on it with
  `get_job`. Long builds never hit request timeouts.
- **Stuck work doesn't hold simulators.** Tests that print nothing for `stall_seconds` (default 5
  minutes; builds 15) are stopped as hung, and `cancel_job` stops a job on demand. Jobs are
  written to disk, so after a restart `get_job` says what happened to them, and anything the
  previous run left running (a hung `xcodebuild`) is stopped when minirun starts.

## Setup

On the Mac (Apple silicon, macOS 14+, Xcode 26 or 27 with an iOS simulator runtime):

```bash
git clone https://github.com/devenjarvis/minirun && cd minirun
./scripts/install.sh
```

That script:

1. Installs `xcodegen` and `gh` with Homebrew if missing.
2. Builds the FBSimulatorControl frameworks from AXe's pinned idb fork (a few minutes, once).
3. Builds `minirun` and the menu bar app, and installs them as `/Applications/minirun.app`. The
   app carries minirun itself (`minirun.app/Contents/Helpers/minirun`), the simulator frameworks
   and the prebuilt Worker. See [The menu bar app](#the-menu-bar-app).
4. Deploys the Worker to your Cloudflare account with `minirun worker deploy` (see
   [The Worker](#the-worker)). It asks for a Cloudflare API token, creates a KV namespace,
   uploads the prebuilt Worker, and generates a password and an agent token. Skip this with
   `--no-worker` and the app's setup window does it instead.
5. Installs a LaunchAgent (`minirun agent install`) so `minirun serve` starts at login and
   restarts if it crashes.

An older install in `~/.minirun/bin` is moved into the app; settings in `~/.config/minirun` and
workspaces are kept. `--no-app` installs to `~/.minirun/bin` without the app, as before.
`./scripts/install.sh --uninstall` removes the app, the LaunchAgent and the `minirun` command.

**Without building:** download `minirun-<version>.zip` from
[Releases](https://github.com/devenjarvis/minirun/releases), move `minirun.app` to
`/Applications`, run `xattr -dr com.apple.quarantine /Applications/minirun.app` (the build is
ad-hoc signed, not notarized), and open it. It sets up `minirun serve` and opens a setup window
that checks Xcode, deploys the Worker and shows how to connect Claude. You still need Xcode.
Building from source is the recommended way.

Add `--github-runner owner/repo` to also run that repository's GitHub Actions jobs on the Mac
(see [Run CI on your Mac](#run-ci-on-your-mac-optional)).

Then:

1. **Connect Claude.** In claude.ai, go to Settings → Connectors → Add custom connector and enter
   `https://minirun.<you>.workers.dev/mcp`. Approve with your minirun password. Once added it
   also works in the Claude mobile app.
2. **Watch live** at `https://minirun.<you>.workers.dev/` from any browser. Tap and swipe on the
   screen, type with the box at the bottom, and pick a stream quality (Saver, Smooth or Sharp).
   Add `?codec=jpeg` to the address to use JPEG frames instead of H.264.

For private repositories, run `gh auth login && gh auth setup-git` on the Mac so it can clone them.

### Permissions for macOS apps

iOS apps need nothing more. To build and drive **native macOS apps** on the Mac, macOS has to let
`minirun serve` see and control other apps' windows. It grants this per program, so the
permissions go to the daemon, `/Applications/minirun.app/Contents/Helpers/minirun`, not to the
menu bar app or Terminal:

| Permission | What it's for |
| --- | --- |
| **Screen Recording** | Screenshots of the app's window and the live view |
| **Accessibility** | Reading the window's UI (`describe_ui`), clicks, typing, keys and menus |
| **A display** | Windows only draw on an active display |

The easy way: open the menu bar app's **Set Up minirun… → macOS apps** and choose **Request
Access**. `minirun serve` asks macOS itself, so it shows up in System Settings by name; turn it on
in the panes the step opens, then choose **Restart minirun serve** (Screen Recording takes effect
after a restart). The rows turn green once granted.

By hand: System Settings → Privacy & Security → **Screen Recording**, and then **Accessibility**:
turn on `minirun`, or click **+**, press ⇧⌘G, enter the path above and add it. Then restart
`minirun serve` (`launchctl kickstart -k gui/$(id -u)/dev.minirun.agent`).

A headless Mac mini needs a logged-in user (automatic login, System Settings → Users & Groups)
and a display: a monitor or an HDMI dummy plug.

`minirun doctor` reports all three as `Screen Recording`, `Accessibility` and `Display`. They're
optional and never fail the iOS checks. minirun's builds are ad-hoc signed, so macOS may treat an
updated minirun as a different program and quietly stop honouring the grants: if macOS apps stop
working after an update, remove minirun from both lists, add it again and restart `minirun serve`.

### The Worker

`minirun worker deploy` deploys the Worker through the Cloudflare API, with no node or wrangler on
the Mac. It needs a Cloudflare API token:

1. Open [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens)
   and choose **Create Token**.
2. Use the **Edit Cloudflare Workers** template. Under Account Resources pick your account. Zone
   Resources don't matter to minirun.
3. Paste the token when `minirun worker deploy` asks, or set `MINIRUN_CLOUDFLARE_TOKEN`.

The token, account, Worker URL and password are saved in `~/.config/minirun/worker.json`, which
only your user can read. Later deploys reuse them. Deploying is safe to repeat: it updates the
Worker to the version bundled with this build of minirun and keeps the KV namespace, the
Durable Object and the secrets.

```bash
minirun worker deploy                  # deploy, or update to this build's Worker
minirun worker deploy --subdomain me   # first Worker on the account: claim me.workers.dev
minirun worker deploy --account ID     # the token reaches several accounts
minirun worker status                  # is the deployed Worker this build's?
minirun worker password                # the password for the viewer and the connector
minirun worker forget-token            # delete the saved API token
```

Already deployed with `worker/setup.sh`? Run `minirun worker deploy` once. It adopts that Worker,
its KV namespace and its password (from `worker.env`), and the Mac manages it from then on.

For headless Mac minis, set the Mac to never sleep and to log in automatically. Simulators need
a logged-in GUI session; `minirun serve` already blocks idle sleep while it runs.

## The loop Claude follows

1. Claude edits code in its own environment and pushes a branch.
2. `build_and_run {repo: "you/app", ref: "my-branch"}` syncs, builds, installs and launches the
   app, then returns a screenshot. If the build fails, it returns the errors with `file:line`.
3. `describe_ui` gives the accessibility tree, then `tap {id: "loginButton"}`, `type_text`,
   `swipe`, and `screenshot` to look. `app_logs` reads the app's output.
4. `run_tests` runs the tests on the simulator and reports pass/fail with failure messages. For a
   package in a subfolder, `project` is its folder: `run_tests {repo: "you/app", ref: "my-branch",
   project: "Packages/Core"}`. A package that builds for macOS can skip the simulator:
   `swift_test {repo: "you/app", ref: "my-branch", package: "Packages/Core"}`.
5. `build_and_run` and `boot_simulator` include a live view link for that simulator to share with
   you (`mac_status` gives it too).

## Several sessions at once

Several Claude sessions can use one Mac at the same time, whether they're on separate apps or on
different branches of the same app (for example, two worktrees). minirun keeps them apart:

- **Each repo + ref has its own checkout.** `you/app` at `feature-a` builds in
  `~/minirun/workspaces/you/app@feature-a`, with its own build folder, so one session's sync never
  swaps the source under another session's build. Builds of the same checkout wait their turn.
- **Each piece of work gets its own simulator.** `build_and_run` without `device` uses the simulator
  reserved for its repo + ref. If there isn't one, it takes an unreserved booted simulator or
  boots a separate one, creating a copy such as "iPhone 17 Pro (minirun 2)" if every simulator of
  that model is busy. If a shut-down "iPhone 17 Pro (minirun template)" of the same runtime
  exists, the copy is cloned from it, which skips the minutes-long first boot.
  `boot_simulator {label: "you/app@feature-a"}` does the same up front.
  Reservations are saved in `~/.config/minirun/simulators.json` and end when the simulator shuts down.
- **Idle simulators shut down.** A simulator nobody has used for `idleShutdownMinutes` (30 by
  default) is shut down and its reservation released. Running builds and tests, and an open live
  view, count as use. The most recently used simulator stays booted as a free spare, so the next
  session doesn't wait for a boot. Simulators you booted yourself, outside minirun, are left alone.
- **Boots don't block each other.** A new simulator's first boot can take minutes. Other sessions
  can pick, and use, their own simulators while it runs.
- **No guessing.** Results name the simulator's UDID, and Claude passes it as `device` on later calls.
  If a call leaves out `device` while several simulators are booted, it fails with a list of
  them and who each is reserved for, rather than tapping on someone else's simulator.
- **One viewer per simulator.** Each session's live view link opens on its own simulator
  (`/?device=UDID`), and taps from that page only reach that simulator. When more than one simulator
  is booted, the viewer shows a picker to switch between them.

## macOS apps

minirun also builds and drives native macOS apps (AppKit, SwiftUI or Mac Catalyst) on the Mac
itself, with the same loop:

1. `build_and_run {repo, ref, platform: "macos"}` builds the app, quits the copy it launched for
   this repo + ref last time, launches the new build, waits for its window and returns a
   screenshot of it. Without `platform`, a scheme that only builds for macOS is detected. The
   result gives a **Mac app id** like `mac-3f9a2c`; Claude passes it as `device` on later calls.
2. `screenshot`, `describe_ui` (`include_menus` for the menu bar), `tap` (by id/label/value through
   Accessibility, or a click at a window point; `button: "right"`, `count: 2`), `swipe` and
   `long_press` (mouse drags), `scroll`, `type_text` (any characters), `press_key` with
   `modifiers`, `press_menu_item ["File", "New Window"]`, `open_url`, `app_logs` (stdout/stderr
   since launch plus unified logging), `terminate_app`. `list_windows` lists the app's windows;
   most tools take `window` (an index or title). Coordinates are window points from the window's
   top-left, title bar included.
3. `run_tests {platform: "macos"}` runs the scheme's tests on the Mac, with the same
   `stall_seconds`/`timeout_seconds`, `cancel_job` and no-parallel defaults as iOS tests.
4. The live view link shows the app's window; you can click, drag, scroll, right-click and type
   into it.

**Isolation between sessions.** Each repo + ref gets its own Mac app id, and minirun only ever
quits the process it launched for that id (it checks the pid still runs that executable). Apps are
started as plain processes, not through Launch Services, so two branches of the same app run side
by side. Keys, scrolls and drags are posted to the app's process, so they don't move your cursor
or need the window in front. A tap (or a live view click) on a button or text field presses or
focuses it through Accessibility, because SwiftUI controls ignore clicks posted to the app.
`input: "hid"` uses the real cursor and keyboard instead, for anything those don't reach. `list_mac_apps` shows every Mac app minirun launched and who it's for.
Apps nobody has used for `idleShutdownMinutes` are quit, like idle simulators.

It needs Screen Recording and Accessibility for `minirun serve`: see
[Permissions for macOS apps](#permissions-for-macos-apps).

Limitations:

- Copies of one app share its bundle id, so they share UserDefaults and containers.
  `isolated_home: true` runs a non-sandboxed app with `CFFIXED_USER_HOME` set to
  `<checkout>/.minirun/home`, which separates its preferences and files; sandboxed apps still share.
- macOS UI tests take over the Mac's real mouse and keyboard, so `run_tests` for macOS runs one at
  a time on the Mac (unit tests included, since minirun can't tell them apart up front).
- A headless Mac needs a logged-in user and a display (or an HDMI dummy plug) for windows to draw.
- If signing with the project's team fails, minirun builds again signed ad hoc and says so. macOS
  kills an ad-hoc-signed app at launch if its entitlements need a provisioning profile (iCloud,
  push, app groups with a team prefix); the result says when that's the likely cause.
- `set_pasteboard` sets the Mac's own pasteboard, shared by every app and session.
- In the browser viewer, shortcuts the browser keeps for itself (⌘W, ⌘T, ⌘Q…) never reach the app;
  Claude can send them with `press_key` or `press_menu_item`.
- Menu bar–only apps and command-line tools launch and log, but have no window to show.
- `screenshot {share: true}` shares a Mac app's window for a PR, but `start_recording` and
  `stop_recording` are simulator-only for now: recording a Mac app isn't supported yet.

## Tools

| Area | Tools |
| --- | --- |
| Simulators | `list_simulators` (with what each is reserved for), `boot_simulator` (get your own), `shutdown_simulator`, `configure_simulator` (dark mode, text size including accessibility sizes, increase contrast, location, demo status bar, permissions) |
| Seeing | `screenshot` (sized so pixels = points; `share: true` also returns a link for a PR), `describe_ui` (compact text or full JSON) |
| Sharing | `start_recording`, `stop_recording` (a GIF that links to the MP4, ready to paste into a PR), `delete_media` |
| Touching | `tap` (x/y or id/label/value), `swipe` (points or direction), `long_press` (also drag), `type_text`, `press_key`, `press_button`, `open_url`, `set_pasteboard` |
| Apps | `install_app`, `launch_app`, `terminate_app`, `uninstall_app`, `app_logs`, `add_media` |
| Code | `sync_repo`, `list_schemes`, `build`, `build_and_run`, `run_tests` (all three take `platform`: `ios`, `macos`, `mac-catalyst`), `swift_test` (package tests, no simulator), `run_command` (opt-in) |
| macOS apps | `list_mac_apps`, `list_windows`, `scroll`, `press_menu_item`, plus the tools above with a Mac app id as `device` (see [macOS apps](#macos-apps)) |
| Jobs | `get_job`, `job_log`, `list_jobs`, `cancel_job` |
| Host | `host_info`, `mac_status` (served by the Worker) |

Try any tool locally: `minirun call describe_ui` or `minirun call tap '{"label":"General"}'`. The
`minirun` command is `/Applications/minirun.app/Contents/Helpers/minirun`; Settings → General →
Install Command Line Tool links it into `/usr/local/bin`.

See what the running `minirun serve` is doing with `minirun status`: the relay connection, the booted
simulators and who each is reserved for, and recent jobs. `minirun status --json` gives the same as
JSON. It asks the daemon over a socket at `~/.config/minirun/control.sock` that only your user can open.
`minirun doctor` checks Xcode, the simulators, the daemon and the settings, and says how to fix
each problem (`--json` for scripts). Claude gets the same checks from `host_info`, along with the
minirun version; `mac_status` says whether the Mac and the Worker run the same minirun.

## Screenshots and recordings in PRs

GitHub only shows images it can fetch from a public URL, so minirun hosts them on your Worker.
`screenshot {device, share: true}`, or `start_recording` → tap around → `stop_recording`, uploads
the result and returns markdown to paste into a PR description:

- A screenshot is a JPEG at 2x points.
- A recording is a looping GIF (about 10 fps, 320 px wide) that links to a player page for the
  full MP4. GitHub won't play video hosted elsewhere, so the GIF shows the motion inline.
  Recordings stop by themselves after `maxRecordingSeconds` (60).

Files are stored in a `MEDIA_KV` namespace with an expiry (`mediaRetentionDays`, 7), so KV deletes
them by itself; old PRs then show a broken image. The Mac keeps a list of what it uploaded in
`~/.config/minirun/media.json` and deletes the oldest files to stay under
`mediaStorageLimitMB` (500). The menu bar app lists them, with Open, Copy link and Delete.

Links are long and random, but anyone who has one can open it until it expires, even for a
private repository. GitHub's image proxy may keep showing a copy for a while after you delete it.

**How large can a GIF be?** GitHub's image proxy has a size limit that isn't documented. The Worker
serves test GIFs of any size from 1 to 25 MB at `/m/probe/<n>.gif`. Paste a few into a PR
description, see which ones show, and set `mediaInlineLimitMB` (default 5) to the largest. Larger
GIFs are shrunk until they fit.

## The menu bar app

`/Applications/minirun.app` puts minirun in the menu bar. The icon shows whether the Mac is
connected to the relay, still connecting, has a problem, or isn't running, with the number of
running jobs beside it. The menu shows:

- The relay connection and how long it's been up, or what went wrong and how to fix it.
- Booted simulators: who each is reserved for, whether it's booting or busy, and when it was last
  used. Each has Watch live, Show in Simulator, Release reservation and Shut down.
- Running and recent jobs, with Log and Cancel.
- Live view (in a window), Copy connector URL, Copy password, Restart service, Settings… and Quit.
- When `minirun serve` isn't running, a Start button and the end of its log.
- A note when the Worker runs older code than the app, or a newer release is on GitHub.
- Shared media: how many files and how much space, the newest ten with Open, Copy link and
  Delete, and Delete all. A simulator that's recording shows a red dot and Stop recording.

**Setup window.** It opens by itself while there's no Worker in the settings, and from the menu's
Set Up minirun…: it checks Xcode, the simulator runtime and the frameworks; takes a Cloudflare
API token, an account and (if needed) a workers.dev subdomain, and deploys the Worker with a live
checklist; shows the connector URL and password and waits for Claude's first call; offers
`gh auth login` for private repositories; and links the System Settings panes a headless Mac
mini needs (automatic login, no sleep).

**Settings (⌘,):**

- **General:** open at login, keep the Mac awake, notifications (relay down for 5 minutes, a job
  failed), install the `minirun` command, automatic updates.
- **Cloudflare:** the Worker's URL and account, bundled versus deployed version, Update Worker,
  rotate the password or agent token, and forget the saved API token.
- **Simulators:** the default device, idle shutdown minutes and the most simulators to keep booted.
- **Workspaces:** the workspace folder, and the checkouts with size and last use. Delete one, or all
  older than N days (never one a job is using).
- **Security:** `run_command`, behind a warning.
- **Diagnostics:** `minirun doctor` as a checklist, with fixes you can run in Terminal; Open log;
  Copy diagnostics (versions, state and settings without secrets); Reveal config in Finder.

**Automatic updates.** An app in `/Applications` keeps itself current, so the Mac needs no
visits: every hour it looks for a newer [release](https://github.com/devenjarvis/minirun/releases).
When it finds one, it waits until no job is running and nobody is using a simulator. Then it
downloads `minirun-<version>.zip`, checks it against the SHA-256 GitHub reports for it (or the
`.sha256` file next to it), and checks the unzipped app: the bundle id, the version, the
signature, and that its `minirun` starts. Then it swaps `/Applications/minirun.app`, restarts
`minirun serve` from the new copy and relaunches. If the new copy doesn't start, the old one is
put back. Next it updates the Worker with the saved Cloudflare API token, if the Worker runs
older code. The app turns on Open at login the first time it runs, so it comes back after a
restart. Turn automatic updates off in Settings → General; the menu then offers Install instead.
Releases aren't signed, so you're trusting whoever can push tags to this repository's GitHub
releases.

Saving writes `~/.config/minirun/config.json` and asks the daemon to reload it, so changes apply
without a restart.

The app watches and steers `minirun serve`, which runs separately under launchd: quitting the app
doesn't disconnect Claude. When the app opens, it makes sure the LaunchAgent runs its own copy of
minirun (a copy outside `/Applications`, such as an Xcode build, never takes over a working
install). It talks to the daemon over the control socket and never loads the simulator frameworks.
Build and install it on its own with `./scripts/install-app.sh` (needs `xcodegen`; add
`--with-daemon "$(swift build --show-bin-path)"` to bundle minirun). There's no Apple Developer
ID behind it, so it's ad-hoc signed and not notarized. A copy you build yourself runs without
Gatekeeper prompts.

## Configuration

`~/.config/minirun/config.json` (written by `minirun worker deploy` and `minirun setup`):

| Key | Default | |
| --- | --- | --- |
| `relayURL` | — | `wss://minirun.<you>.workers.dev/agent` |
| `agentToken` | — | Must match the Worker's `AGENT_TOKEN` secret |
| `workspaceRoot` | `~/minirun/workspaces` | Where repositories are cloned, one folder per repo + ref |
| `defaultDevice` | newest iPhone (its Pro model; never the SE or the foldable Duo) | Simulator model to boot when a session needs one, e.g. `"iPhone 18 Pro"` |
| `allowShell` | `false` | Enables `run_command`: arbitrary shell commands on your Mac |
| `preventSleep` | `true` | Blocks idle sleep while serving |
| `idleShutdownMinutes` | `30` | Shuts down simulators nobody has used for this long; `0` keeps them running |
| `maxBootedSimulators` | `4` | How many simulators minirun runs at once. Past this, a call that needs another one fails and lists the running ones |
| `shareMedia` | `true` | Lets `share: true` and `stop_recording` upload to the Worker |
| `mediaRetentionDays` | `7` | How long shared files last (1–90) |
| `mediaStorageLimitMB` | `500` | The oldest shared files are deleted to stay under this |
| `maxRecordingSeconds` | `60` | Recordings stop by themselves after this |
| `mediaInlineLimitMB` | `5` | Largest GIF to put in a PR; bigger ones are shrunk |

After editing, run `minirun reload` (or `kill -HUP` the daemon). Every setting applies at once; a
new `relayURL` or `agentToken` makes the Mac reconnect to the relay.

## Security

- The Mac only makes outbound connections. The Worker accepts the Mac's WebSocket only with
  `AGENT_TOKEN`.
- Claude's connector uses OAuth 2.1 with PKCE (`@cloudflare/workers-oauth-provider`). Every
  approval asks for your password, even if you're already logged in to the viewer.
- Viewers log in with the same password (30-day signed cookie). They can only send touch and
  keyboard input, not run tools like `build` or `run_command`.
- `run_command` is off by default. Turning it on lets anyone holding a connector token run shell
  commands on your Mac, so keep the password private. Building and testing a repository
  (`build`, `run_tests`, `swift_test`) runs that repository's own code too: build scripts,
  package plugins and tests. Only point minirun at repositories you trust.
- Rotate secrets with `minirun worker deploy --new-password` or `--new-token`. A new token is
  saved on the Mac and `minirun serve` reloads its settings and reconnects with it.
- The saved Cloudflare API token can deploy and change Workers on your account. Delete it with
  `minirun worker forget-token` if you'd rather paste it for each update.
- The optional GitHub runner runs pull request code on the Mac as your user. Read
  [Run CI on your Mac](#run-ci-on-your-mac-optional) before turning it on, especially for public
  repositories.

## Run CI on your Mac (optional)

The Mac can also run your GitHub Actions jobs, using GitHub's own runner
([actions/runner](https://github.com/actions/runner)). minirun doesn't run jobs itself; the install
script only downloads, registers and starts the official runner next to it.

```bash
gh auth login --scopes repo        # once; you need admin access to the repository
./scripts/install.sh --github-runner you/app                      # repeat the flag for more repos
./scripts/github-runner.sh install you/app                        # or just the runner, no rebuild
```

For each repository, this:

1. Checks that `gh` is logged in with enough access, and checks the repository's visibility.
2. Downloads the latest macOS arm64 runner, verifies its SHA-256 against the release, and extracts
   it to `~/.minirun/github-runner/<owner>-<repo>/`.
3. Registers it as `<hostname>-minirun` with the labels `self-hosted`, `macOS`, `ARM64` and
   `minirun`, using a short-lived token from `gh`. The token is never saved or printed. Re-running
   is safe: an existing registration is kept, and a stale one of the same name is replaced.
4. Installs it as a LaunchAgent, so it starts at login like `minirun serve`. Simulators need the
   logged-in GUI session, so it's not a LaunchDaemon.

Or, in the menu bar app, open **Settings → GitHub Runners**, type `owner/repo` and choose **Add
Runner**. The app carries the same script and runs it for you. The tab lists each runner with
its service state and GitHub's view of it (idle, busy or offline). From there you can start, stop
or remove a runner, open its logs, and open its page on GitHub. For a public repository it shows
the warning below and asks before registering. Once a runner is installed, the menu shows it too,
with Start and Stop.

Target it from a workflow with:

```yaml
runs-on: [self-hosted, macOS, minirun]
```

**Security.** A self-hosted runner runs workflow code from pull requests on your Mac as your user.
Jobs can read your files, your `gh` login and minirun's secrets in `~/.config/minirun`. On a public
repository anyone can open a pull request from a fork, so the script refuses public repositories
unless you pass `--allow-public`. If you do, first set the repository's Settings → Actions →
General → "Fork pull request workflows from outside collaborators" to "Require approval for all
outside collaborators" (or stricter), and read fork PRs before approving their runs.

**Sharing the Mac with Claude.** The runner takes one job at a time, but jobs run alongside
Claude's sessions on the same simulators, Xcode and disk. Treat a CI job like any other session
(see [Several sessions at once](#several-sessions-at-once)): get its own simulator with
`boot_simulator {label: "ci/<run id>"}` or `xcrun simctl create`, pass that UDID as `device` on
every minirun call or `-destination id=<UDID>` to `xcodebuild`, and shut it down or delete it at the
end. Don't rely on "the booted simulator", and don't run `simctl shutdown all` or `erase all`:
those reach the simulators Claude and your viewer are using.

**Status and uninstall.**

```bash
./scripts/github-runner.sh status              # service state and GitHub's view of each runner
./scripts/github-runner.sh stop you/app        # take no jobs until started again (or the next login)
./scripts/github-runner.sh start you/app
./scripts/github-runner.sh uninstall you/app   # stops the service, deregisters, deletes the folder
```

When the Mac is asleep or offline, jobs for `[self-hosted, macOS, minirun]` wait in the queue.
GitHub-hosted runners (`runs-on: macos-26`) remain the fallback; keep a hosted job, or switch
`runs-on` back, for anything that can't wait.

## Costs (Cloudflare free plan)

Workers, one SQLite Durable Object and KV all fit in the free tier for one person. Streaming
uses Durable Object requests: each frame and its acknowledgement count as 1/20 of a request.
H.264 only sends frames while the screen changes, so a still screen costs almost nothing and
scrolling at 30 fps costs about 3 requests per second. That works out to many hours of viewing a
day within the free 100k requests. The viewer stops streaming when its tab is hidden.

Shared media uses KV's free 1 GB and 1,000 writes a day; with the defaults (500 MB, 7 days) it
stays well inside both.

## Limitations (v0.1)

- One Mac per Worker deployment. Simulators and macOS apps only for UI control (physical devices are planned).
- Each branch keeps its own checkout and build folder. Delete old ones from `~/minirun/workspaces`
  to free disk space.
- The Mac and the Worker must be updated together: the viewer's per-simulator streams need both.
  `./scripts/install.sh` updates the Worker too when this Mac deployed it.
- `type_text` types US-keyboard characters. For other text, use `set_pasteboard` and paste.
- The live view runs at up to 30 fps. Viewers that join, or fall too far behind, wait for the
  next keyframe, which the Mac sends on request.

## Development

```bash
swift test                       # MiniRunKit unit tests (any platform)
./scripts/build-frameworks.sh    # macOS: FBSimulatorControl into Vendor/
swift build && ./scripts/smoke-test.sh   # macOS: boots a simulator and drives a fixture app
./scripts/install-app.sh --build-only --with-daemon "$(swift build --show-bin-path)"   # macOS: the app (cd App && xcodegen for Xcode)
cd worker && npm ci && npm test  # Worker tests (OAuth flow, relay, viewer) in workerd
cd worker && npm run bundle      # rebuild worker/dist after changing the Worker; commit it
```

`worker/dist` is the prebuilt Worker that `minirun worker deploy` uploads, along with a manifest
generated from `wrangler.jsonc`. CI fails if it doesn't match the source. `worker/setup.sh` still
deploys with wrangler, for working on the Worker itself.

Releases: bump `MiniRun.version` (`Sources/MiniRunKit/Version.swift`), `MARKETING_VERSION` in
`App/project.yml` and `VERSION` in `worker/src/version.ts` (then `npm run bundle`), add a section
for it to `CHANGELOG.md`, and merge. When `main`'s version has no tag yet, the Release workflow
builds the app and publishes a GitHub Release with `minirun-<version>.zip` and that changelog
section as its notes, which creates the `v<version>` tag. Pushing a tag or creating a release by
hand works too.

CI runs all of the above on GitHub's macOS runners. If a run fails, the logs are pushed to the
`ci-logs` branch.

## Credits

Simulator control builds on [AXe](https://github.com/cameroncooke/AXe) by Cameron Cooke and
[idb](https://github.com/facebook/idb) by Meta, both MIT licensed. See `THIRD_PARTY_NOTICES.md`.
