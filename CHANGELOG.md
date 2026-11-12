# Changelog

## Unreleased

- **Tests say at once when they can't start with you switched away.** Xcode's test daemon
  (testmanagerd) only starts for the user on the Mac's screen. One started while you were there
  keeps working after you switch users (so others can use the Mac), but once it quits after a quiet
  spell, a new one refuses at the login window ("Disallowing automation at loginwindow") and
  xcodebuild built the app, then printed nothing until it was stopped as hung 5 minutes later,
  blamed on "a stuck simulator". `run_tests` now fails before building in that case and says to
  switch back, run any tests, and switch away again. `host_info` and `minirun doctor` have a
  "Test daemon (for tests)" check.
- **A failed Worker update is tried again.** The menu bar app tried to update the Worker once per
  launch, so a single failure (a network blip while the app restarted into a new version, say)
  left it on the old version until the next restart. It now tries again 15 minutes later, then
  twice as long each time, up to 6 hours, and notifies you once per version rather than at every
  try.
- **The menu says why the Worker is behind:** automatic updates are off, no API token is saved,
  or the last update failed (with the error, and when it tries again).
- **The app's Worker updates are in `minirun.log`**, as `app:` lines among serve's own, so a
  failure can be read afterwards.

## 0.9.0

The live view is built for phones: the simulator fills the screen, the viewer can be added to the
Home Screen to run without Safari's bars, switching devices takes a tap, and typing goes to the
app as you type. Only the Worker changes; update it from the menu when it asks.

- **The stream fills a phone's screen.** On a touch screen that's small in one direction, the
  header and footer give way to the stream, and open over it from a floating button you can drag
  to either side. On an iPhone in Safari the simulator goes from about 60% of its real size to
  about 75%. `?layout=compact` or `?layout=classic` picks a layout on any device.
- **Add to Home Screen.** The viewer has a web app manifest and icons, so added to the Home Screen
  it opens without the browser's bars: about 90% of the simulator's real size on an iPhone.
- **Live typing.** The text box sends each character as it's typed, and backspace deletes in the
  app, instead of sending the box's text when you press return. Tapping ⌫ or ⏎ keeps the phone's
  keyboard up.
- **Quick device switching on a phone.** The top of the controls is a device button showing the
  device, the app minirun last launched on it and the branch it's for. It opens a full-width list
  of every booted simulator and running Mac app. The desktop picker shows the app too.
- **Back to the last device.** Opened without `?device` (from the Home Screen, say), the viewer
  goes back to the device you last picked or opened a link to, if it's still running.
- **The screen stays on** while the stream is live (Screen Wake Lock), so a phone doesn't sleep
  and drop the stream in the middle of a review.

See [docs/mobile-viewer-plan.md](docs/mobile-viewer-plan.md) for what comes next.

## 0.8.0

minirun stops filling the Mac's disk, and a full disk no longer leaves it broken. Old checkouts
and the leftovers Xcode kept for them are deleted by themselves, and `minirun serve` keeps working
(and its GitHub runner jobs with it) through a full disk. The Worker only changes its version
number; update it from the menu when it asks.

- **Old checkouts are deleted by themselves.** Every repo + ref keeps its own checkout and build
  folder (often 1–3 GB), and agents and CI make a new ref for every branch, so they used to fill
  the disk. `minirun serve` now deletes checkouts nobody has used for `workspaceCleanupDays` (3),
  and while free disk is under `minFreeDiskGB` (30) deletes the least recently used ones, also
  before making a new checkout. A checkout a job is using, or one used in the last hour, is never
  deleted. Set either to 0 to turn it off.
- **No more leftovers in Xcode's own DerivedData.** Finding a scheme with `xcodebuild -list`
  resolved Swift packages into `~/Library/Developer/Xcode/DerivedData`, one folder per checkout,
  that nothing deleted. Builds now take the scheme from the project's shared `.xcscheme` files
  when they can, and the cleanup deletes Xcode's DerivedData folders whose checkout is gone.
- **A full disk no longer takes `minirun serve` down for good.** Writing a log line on a full disk
  raised an exception that crashed serve; it's now ignored. And when serve can't make its control
  socket at start (the disk was full, say), it retries every 30 seconds instead of running without
  one, which left `minirun status`, the menu bar app and every `minirun ci` job (exit 3) unable to
  reach it until a restart.

## 0.7.0

A minirun Mac becomes a faster CI machine: GitHub Actions jobs can hand their builds and tests to
`minirun serve`, and new branches check out from one git mirror per repository. The plan behind
this, with what comes next, is in `docs/faster-ci-plan.md`. The Worker only changes its version
number; update it from the menu when it asks.

- **`minirun ci` and a GitHub Action for CI jobs.** A workflow on a minirun runner can hand its
  build or tests to `minirun serve` (`uses: devenjarvis/minirun/ci@main` with `command: test`, or
  `minirun ci test --scheme App` in a `run:` step). The job builds the run's commit in a checkout
  of its own that stays warm between runs of a branch (`ci/<branch>`), gets a simulator from
  minirun's reservations and limits, and can be cancelled. Its log streams into the step,
  compiler errors and failed tests become annotations, and the exit status is the job's. Adds the
  `start_tool` and `job` control commands (protocol 7) and a `commit` argument to the build, test
  and sync tools: the exact commit to check out in `ref`'s checkout.
- **New branches check out in seconds.** Each repository now has one bare, blobless git mirror
  (`<workspaceRoot>/.git-mirrors/<owner>/<name>.git`), and every repo + ref checkout is a worktree
  of it, so a new ref only downloads what the Mac doesn't already have. Checkouts keep their paths;
  existing full clones keep working, and come back as worktrees if deleted. If the mirror can't be
  made, sync falls back to a full clone.
- **`sharedBuildCache` (experimental, off by default).** Builds of a repository's checkouts share
  Swift package checkouts, in one folder per Package.resolved, and Xcode's compilation cache
  (`COMPILATION_CACHE_ENABLE_CACHING`), under `<workspaceRoot>/.cache`. Arguments you pass in
  `extra_args` win. See `docs/faster-ci-plan.md` for what to measure before turning it on.
- **Synced commit subjects lose a stray newline.** `sync_repo` printed a commit's subject with
  git's trailing newline inside the quotes.

## 0.6.1

- **Updating the Worker clears "out of date".** After Update Worker (or `minirun worker deploy`)
  the menu kept saying the Worker was out of date until `minirun serve` restarted. The Worker's
  WebSockets hibernate, so the Mac's connection survived the deploy and still carried the old
  Worker's version. Now a deploy asks `minirun serve` to reconnect, and it keeps reconnecting for
  up to a minute until the relay runs the new code, which a deploy takes a few seconds to roll out.
  Adds the `reconnect_relay` control command (protocol 6). Live view viewers reconnect by
  themselves.

## 0.6.0

Live view goes over a direct WebRTC connection with much less lag, Screen Recording and
Accessibility can survive updates, and stopped Mac apps no longer pile up in the menu.

- **Live view over WebRTC (protocol 6).** The Mac now streams to viewers over a direct WebRTC
  connection: an H.264 track for the screen and data channels for touch and input. The Worker only
  carries connection setup, and the Mac enforces the viewer input rules the relay used to. STUN
  via `stun.cloudflare.com` is always used; Cloudflare TURN is optional, with the `TURN_KEY_ID` and
  `TURN_KEY_API_TOKEN` secrets. The WebSocket stream stays as an automatic fallback, and
  `?transport=ws` forces it. Update the Worker too (the app does it with the saved API token, or
  run `minirun worker deploy`).
- **Lower live view latency.** Both encoders ask VideoToolbox for low-latency settings, and an SPS
  that made browsers hold frames back is fixed. Live touches no longer look the simulator up on every
  event: about 0.3 ms each instead of 6–7 ms. Open the viewer with `?stats=1`, or tap **ms** in its
  header, for a readout of round trip, Mac pipeline and draw times, fps, bitrate and touch-to-screen.
- **Screen Recording and Accessibility survive updates.** A Mac with its own `minirun local`
  code-signing certificate now has minirun signed with it: `scripts/install.sh` and
  `scripts/install-app.sh` use it (or `MINIRUN_SIGN_IDENTITY`), and the menu bar app re-signs each
  update with it before installing. macOS then sees every build as the same program, so the grants
  no longer reset. The README's "Keep permissions across updates" says how to make the certificate,
  sign the installed app with it once, and grant both permissions one last time. Without a
  certificate nothing changes: releases are still ad-hoc signed.
- **Stopped Mac apps no longer pile up in the menu.** The menu lists every running Mac app but only
  the three most recently used stopped ones; the rest go in a "N more not running" submenu. Stopped
  apps now have Forget (and the submenu has Forget all not running), and `minirun serve` forgets
  them by itself once they've been stopped for a day, keeping at most the 10 most recent. Relaunching
  an app for the same repo and branch still gets the same id. Restart `minirun serve` after updating
  so the menu's new actions work.
- **Sharper, smoother recording GIFs.** GIFs are now made at 15 fps and 2x points (as sharp as a
  screenshot) instead of 10 fps and 320 px. A new encoder gives each frame its own palette and
  stores only the part of the screen that changed, so a typical clip is a few MB. Longer or busier
  clips step down in size and frame rate until they fit. GIFs committed to a `pr-media` branch can
  be up to 10 MB, because github.com serves them directly rather than through its image proxy.

## 0.5.0

Screenshots and recordings now embed in PR descriptions for repos with a `pr-media` branch, Mac
apps can be recorded, and macOS 26 is now required.

- **PR media on GitHub.** When the repo a simulator or Mac app is reserved for has a `pr-media`
  branch, `screenshot {share: true}` and `stop_recording` commit the image or GIF there with the
  Mac's `gh` sign-in and return a github.com embed pinned to that commit. These render for anyone
  who can see the repo, private repos included, survive the GitHub tools agents post with (which
  strip images hosted elsewhere), and don't expire. `folder` and `name` choose the path, and a
  `before` and an `after` in one folder also return a before/after table. To opt a repo in, push an
  orphan `pr-media` branch once; `githubMedia` and `githubMediaBranch` in `config.json` turn it off
  or rename it. Recordings commit only the GIF for now.
- **Worker links say what they're for.** Shares that go to the Worker now say the link won't embed
  in a PR description and expires, and how to opt the repo in, instead of telling agents to paste
  it. Redeploy the Worker (Settings → Cloudflare, or `minirun worker deploy`) to give agents the
  updated instructions.
- **Recordings of macOS apps.** `start_recording` / `stop_recording` now work with a Mac app id:
  they record one window (the main one, or `window`) with ScreenCaptureKit and share the same GIF
  and MP4 as simulator recordings. The recording stops by itself when the window closes or the app
  quits, and the menu bar app shows a red dot and Stop recording for it.
- **macOS 26 or later is now required** (was macOS 14), for the menu bar app and `minirun serve`.

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
