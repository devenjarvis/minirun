# Changelog

## Unreleased

### macOS apps

minirun now builds, runs and drives native macOS apps (AppKit, SwiftUI, Mac Catalyst) on the Mac
itself, with the same loop as iOS. See [macOS apps](README.md#macos-apps).

- **`platform`** on `build`, `build_and_run` and `run_tests`: `ios`, `macos` or `mac-catalyst`.
  Left out, a scheme that only builds for macOS is detected. Mac builds don't use a simulator.
- **`build_and_run` for macOS** quits the copy it launched last time for this repo + ref (only
  that process), launches the new build, waits for its window and returns a screenshot and a
  **Mac app id** (`mac-3f9a2c`) to pass as `device`. `isolated_home` gives a non-sandboxed app its
  own home folder per checkout. If an ad-hoc-signed build quits at launch, the result says its
  entitlements are the likely cause.
- **The existing tools take a Mac app id:** `screenshot` and `describe_ui` (with `window`,
  `include_menus`), `tap` (with `button`, `count`), `swipe`/`long_press` (mouse drags),
  `type_text`, `press_key` (with `modifiers`), `app_logs`, `open_url`, `set_pasteboard`,
  `launch_app` (`device: "mac"` with `app_path` or `bundle_id`) and `terminate_app`. Input tools
  take `input: "hid"` for apps that ignore events posted to their process. Simulator-only tools say
  what to use instead.
- **New tools:** `list_mac_apps`, `list_windows`, `scroll` and `press_menu_item`.
- **Clicks without the cursor:** SwiftUI controls ignore clicks posted to the app, so a tap at a
  window point, or a click in the live view, on a button or text field presses or focuses it
  through Accessibility. `input: "hid"` clicks with the real cursor.
- **Live view of Mac app windows** (H.264, JPEG fallback), with clicks, drags, right and double
  clicks, wheel scrolling and keys with modifiers. Relay protocol version 5.
- **Several sessions:** apps are tracked per repo + ref in `~/.config/minirun/mac-apps.json`, kept
  across `minirun serve` restarts only while their pid still runs the same executable, and quit
  after `idleShutdownMinutes` unused. macOS test runs go one at a time, since UI tests take over
  the mouse and keyboard.
- **Permissions:** `minirun doctor`, `host_info` and the menu bar app check Screen Recording,
  Accessibility and a display for the daemon; Setup can request them. `minirun status` and the
  menu list the Mac apps minirun launched.

## 0.3.0

minirun is now a Mac menu bar app. Install it once and it runs `minirun serve`, sets up the
Cloudflare Worker, shows you what Claude is doing, and keeps itself and the Worker up to date. This
is the first published release, so it also includes everything built before it.

### The menu bar app

- **minirun.app owns the install.** It carries the daemon, the simulator frameworks and the Worker
  bundle, points the LaunchAgent at its own helper when it opens, turns on Open at Login, and can
  install `/usr/local/bin/minirun` for the command line. `scripts/install.sh` installs the app;
  `--no-app` keeps the old `~/.minirun/bin` layout.
- **First-run setup.** Checks the Mac, deploys the Worker with a live checklist, waits for
  Claude's first call, offers `gh auth login`, and links the settings a headless Mac needs.
- **The menu** shows the relay connection (or what's wrong and how to fix it), booted simulators
  and who each is reserved for, and running jobs. You can shut down or release a simulator and
  cancel a job from it. Settings is the gear in the header (⌘,).
- **Settings:** General, Cloudflare, Simulators, Workspaces, GitHub Runners, Security and
  Diagnostics. Saving applies at once without restarting anything.
- **GitHub runners:** list, add, start, stop and remove self-hosted runners from Settings →
  GitHub Runners or the menu. Public repositories get a warning and need your OK first.
- **Live view in a window**, and notifications when the relay is down or a job fails.

### Automatic updates

- An app in `/Applications` checks GitHub Releases every 6 hours. When no job is running and no
  simulator is busy, it downloads the new version, checks its SHA-256, bundle id, version and that
  its helper starts, swaps itself in (rolling back if the new copy won't start), restarts
  `minirun serve` and relaunches.
- It then redeploys the Worker with your saved Cloudflare API token if the Worker runs older code.
- On by default; turn it off in Settings → General → Install updates automatically.

### The Worker

- **`minirun worker deploy` deploys from Swift** through the Cloudflare API, so installing
  minirun no longer needs node, npm or wrangler. It reuses your KV namespace and secrets, and
  adopts a Worker deployed with `worker/setup.sh`, password included.
- `minirun worker status` says whether the live Worker runs this build's code.

### For Claude (MCP tools)

- **`host_info` reports the minirun version and the setup checks**: Xcode and its license, the
  simulator frameworks, simulators, relay settings, workspaces and GitHub auth, each failing check
  with how to fix it.
- **`mac_status` says which minirun the Mac and the relay run**, and which to update when they
  differ. The MCP server reports its real version.
- **Long builds no longer time out.** Waits are capped at 50 seconds, so `build_and_run`,
  `run_tests` and the rest return a `job_id` before the client gives up; `get_job` picks it up.

### The daemon and CLI

- The control socket answers `reload_config`, `shutdown_simulator`, `release_simulator`,
  `cancel_job`, `workspaces`, `delete_workspace` and `doctor`.
- Settings reload live (also on `SIGHUP` and with the new `minirun reload`); a changed relay URL
  or token reconnects at once.
- Jobs can be cancelled, which stops the commands they run and their children.
- `minirun doctor` returns structured checks (`--json`). New: `minirun agent install|uninstall`.

### Also included

Earlier work, published for the first time: a live view that streams hardware H.264
with live touches, calls that survive relay reconnects, XcodeGen projects generated before
builds, idle simulators shut down automatically, per-session simulators so several Claude
sessions can share one Mac, and `minirun status` over a local control socket.
