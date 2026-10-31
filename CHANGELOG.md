# Changelog

## 0.4.0

minirun now builds, runs and drives macOS apps, agents can share screenshots and recordings in
PR descriptions, and hung test runs are stopped instead of holding the Mac.

**Screenshots and recordings in PR descriptions.** Agents can now show their work in a PR.

- **`screenshot {share: true}`** uploads a 2x screenshot to your Worker and returns markdown for a
  PR description.
- **`start_recording` / `stop_recording`** record the simulator (up to 60 s by default) and share a
  looping GIF that links to a player page for the MP4. `delete_media` takes back a wrong upload.
- **Stored in a new `MEDIA_KV` namespace** that expires files after 7 days and is kept under
  500 MB. Redeploy the Worker (Settings → Cloudflare, or `minirun worker deploy`) to get it; no new
  API token permissions are needed.
- **Size probes** at `/m/probe/<n>.gif` find the largest GIF GitHub will show; set
  `mediaInlineLimitMB` to match.
- **Menu bar app:** a Shared media section, a Sharing settings tab, and a red dot while a
  simulator is recording.

Fixes for test runs that hung and held every simulator, from a report of several sessions
sharing one Mac.

- **Hung tests are stopped.** `run_tests` stops xcodebuild when it prints nothing for
  `stall_seconds` (default 300) or runs past `timeout_seconds` (default 1800, was 90 minutes), and
  says it was treated as hung. Builds are stopped after 15 silent minutes. Either way the
  simulator is no longer busy.
- **Tests run on the reserved simulator only.** `run_tests` passes `-parallel-testing-enabled NO`
  (parallel testing clones the simulator outside minirun's reservations, a common cause of hangs
  after the build) and a 5-minute per-test time allowance, unless `extra_args` set them.
- **`cancel_job`** stops a job and the commands it started. A job cancelled while it waits for
  its checkout no longer starts.
- **Restarts don't lose jobs.** Jobs are kept in `~/.config/minirun/jobs.json`: after a restart
  `get_job` gives the result, or says the job was cut off by the restart. xcodebuild and other
  commands a previous run left behind are stopped when `minirun serve` starts.
- **`swift_test`** runs a Swift package's tests with `swift test` on the Mac, without a simulator
  or `allowShell`, and reports totals and failures with `file:line`.
- **Packages in subfolders.** `project` takes a package's folder (or its `Package.swift`) and
  xcodebuild runs there; before, pointing at `Package.swift` built the checkout's top level.
  `path` accepts a `Package.swift` too. `run_tests` on a package prefers its `-Package` scheme.
- **`configure_simulator`** sets `text_size` (all Dynamic Type sizes, including the accessibility
  ones) and `increase_contrast`.
- When every simulator is taken, the error points to `list_jobs` and `cancel_job` instead of
  suggesting shutting down someone else's simulator.
- The instructions Claude gets explain package tests, `cancel_job` and the stall timeout.
- Automatic updates check GitHub every hour instead of every 6 hours.

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
  across `minirun serve` restarts only while their pid still runs the same executable (the
  cleanup of commands a previous run left behind leaves them running), and quit
  after `idleShutdownMinutes` unused. macOS test runs go one at a time, since UI tests take over
  the mouse and keyboard.
- **Permissions:** `minirun doctor`, `host_info` and the menu bar app check Screen Recording,
  Accessibility and a display for the daemon; Setup can request them. `minirun status` and the
  menu list the Mac apps minirun launched. Apps minirun launches are responsible for themselves,
  so they never get minirun's permissions. `input: "hid"` checks before each event that the app
  is in front (and its window is under the pointer), and stops otherwise; the live view never
  uses it. `open_url` goes to the app's own pid.
- **With the other new features:** Mac builds and tests get the same stall and overall timeouts,
  `cancel_job` and job records as iOS ones (macOS tests also run without parallel testing and with
  the per-test allowance). `screenshot {share: true}` with a Mac app id shares its window;
  recordings aren't supported for Mac apps yet. Control protocol version 4.

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
