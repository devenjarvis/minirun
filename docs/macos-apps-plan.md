# Plan: build, run and drive macOS apps

> **Status:** phases 1 and 2 have landed on `claude/macos-apps-integration`: the build pipeline,
> the Mac driver, viewer and relay, host checks and menu, and the integration (`MacTools.swift`,
> `platform` on the build tools, Mac live view, idle quitting, the control handlers, protocol 5,
> the smoke test's macOS section, README and CHANGELOG). On GitHub's macOS runners (which already
> grant Screen Recording and Accessibility to `/bin/bash`, the process macOS checks there) CI
> builds, launches and quits HelloMacApp and checks: list_mac_apps, list_windows, app_logs,
> describe_ui, tap by id, a tap at a window point (pid and hid), press_menu_item, typing into a
> field, press_key with modifiers, scroll, swipe, screenshot, terminate_app, run_tests, and through
> the relay a Mac app's H.264 live view (`screen` with `kind: "mac"`, picker entry) and a live
> click. Not yet checked on a real Mac: window resizes during a live view, drags that need the
> mouse (pid-posted drags reach SwiftUI?), Catalyst builds, idle quitting, the menu bar app's Mac
> section, and two sessions on two branches of one app. Phase 3 (review) is next.
>
> Found on CI: clicks posted to the app's pid never reach SwiftUI controls (keys, scrolls and
> AXPress do), and HID clicks only land if the cursor stays put until the app handles them. So a
> pid tap at a point, and a live view click, press the button or focus the text field there
> through Accessibility, and fall back to a posted click elsewhere; the HID path waits before
> putting the cursor back.
>
> Merged with main's stall timeouts, `cancel_job`, persisted jobs and PR media: Mac builds and
> tests get the same stall/overall timeouts, test defaults (no parallel testing, per-test
> allowance) and cancellation (the macOS test lock is let go when a run is cancelled). The orphan
> cleanup only stops what `ChildProcessLedger` recorded (xcodebuild, commands, recorders), never
> Mac apps, which are spawned directly and reconciled by `MacAppStore` after a restart.
> `screenshot {share: true}` with a Mac app id shares the window at 2x; `start_recording` and
> `stop_recording` say recording Mac apps isn't supported yet (not built). Control protocol 4.
>
> Deviations: `run_tests` for macOS always takes the global lock (unit tests too), because
> telling UI test targets apart would need another `xcodebuild` call. `scroll` with `direction`
> means the content direction (`down` shows more below), with `amount` (default 300 points).
> Live view clicks only press the mouse button once the pointer moves (a drag); a click without
> movement is performed as a whole when it ends.

Today minirun builds iOS apps, runs them in a simulator, and lets Claude see and touch them. This
plan adds the same loop for **native macOS apps** (AppKit or SwiftUI, and Mac Catalyst), running
directly on the Mac that hosts minirun. The first users are Fetch (a macOS app) and a future
macOS version of Edition.

The goal: an agent calls `build_and_run {repo, ref, platform: "macos"}`, gets a screenshot of its
app's window, reads the window's accessibility tree, clicks, types, uses menus and keyboard
shortcuts, reads the app's logs, runs its tests, and the user can watch the window live in the
browser viewer. All of this must work while other sessions use the same Mac for their own
simulators and Mac apps.

## What is different from a simulator

| | iOS simulator | macOS app |
| --- | --- | --- |
| Unit of isolation | a simulator (UDID), reserved per repo + ref | **an app process (pid)**, tracked per repo + ref |
| Screen | the simulator's framebuffer | **the app's windows**, on a desktop shared with other apps |
| Seeing | FBSimulatorControl framebuffer | **ScreenCaptureKit** window capture (works when covered by other windows) |
| Accessibility | AXe / simulator AX bridge | **macOS Accessibility API** (`AXUIElement`) |
| Input | HID events into one simulator | **AX actions** (`AXPress`, set value) first; **CGEvents posted to the app's pid** for clicks, scrolls and keys |
| Launch | `simctl launch` | **spawn the app's executable** (stdout/stderr go to a log file) |
| Logs | `simctl spawn log show` | **captured stdout/stderr** + `log show --predicate 'processIdentifier == PID'` |
| Permissions | none | **Screen Recording** and **Accessibility** (TCC) for the minirun binary |
| Extra concepts | home button, rotation, location | **windows, the menu bar, modifier keys, right/double click, scroll wheel** |

## Tool surface

Mac apps reuse the existing tools wherever the meaning carries over, so agents learn one loop.
The `device` argument names what a call acts on: a simulator UDID as today, or a **Mac app id**
like `mac-3f9a2c`. Every result that hands out a Mac app id says "pass device: "mac-3f9a2c" on
later calls", the way simulator results do today.

A Mac app id is stable for one piece of work: it's derived from the workspace label
(`owner/repo@ref`, or the folder for `path`), so relaunching the app after a rebuild keeps the
same id while the pid changes. `launch_app` of an already-installed app with no workspace gets an
id derived from the bundle id plus a random suffix.

### Changed tools

| Tool | Change |
| --- | --- |
| `build`, `build_and_run`, `run_tests` | New `platform`: `"ios"` (simulator), `"macos"`, `"mac-catalyst"`. Omitted: `macos` if `device` is a Mac app id, or the scheme only supports macOS (`SUPPORTED_PLATFORMS` has no `iphonesimulator`); otherwise `ios`. For macOS, `build_and_run` quits the app it launched earlier for this workspace (by pid; never anyone else's), launches the new build, waits for a window, and returns a window screenshot plus the Mac app id. New `isolated_home` (bool): run the app with `CFFIXED_USER_HOME` set to `<checkout>/.minirun/home`, so non-sandboxed apps get fresh, per-branch data. |
| `launch_app` | With `device: "mac"` or a Mac app id: launch by `app_path` or `bundle_id` (found via LaunchServices). `arguments`, `environment`, `isolated_home` as above. |
| `terminate_app` | Mac app id: quit it (polite terminate, then force after 5s). |
| `screenshot` | Mac app id: JPEG of the app's window, 1 image pixel = 1 window point, origin at the window's top-left (title bar included). New optional `window` (index from `list_windows` or a title substring). Default: the app's main/frontmost window. `share: true` (PR media) uploads a 2x copy of the window. |
| `describe_ui` | Mac app id: the window's AX tree in the same JSON shape AXe produces, so `XcodeParsing.summarizeAccessibility` formats both. Frames are window-relative points. New `window` and `include_menus` (the menu bar tree). |
| `tap` | Mac app id: by `id`/`label`/`value` → `AXPress` on the element (no mouse needed), falling back to a click at its center; by `x`,`y` → a click at window point. New `button` (`left`/`right`) and `count` (2 = double click), also used on Mac only. |
| `swipe`, `long_press` | Mac app id: a mouse drag (button held) between window points. |
| `type_text` | Mac app id: Unicode keyboard events to the app (any characters, including emoji). `submit` presses Return. |
| `press_key` | New `modifiers`: any of `command`, `shift`, `option`, `control`, `fn`. On Mac also accepts letters, digits, `f1`–`f12`, `home`, `end`, `pageup`, `pagedown`, `forwarddelete`. iOS keeps today's behaviour (modifiers may be supported later). |
| `app_logs` | Mac app id: captured stdout/stderr since launch, merged with unified logging for the pid. |
| `open_url` | Mac app id: open the URL with that app (`NSWorkspace.open(_:withApplicationAt:)`). |
| `set_pasteboard` | Mac: sets the **shared** Mac pasteboard; the result says so. |
| `press_button`, `configure_simulator`, `add_media`, `install_app`, `uninstall_app` | Mac app id: a clear error that says what to use instead. |

### New tools

| Tool | What it does |
| --- | --- |
| `list_mac_apps` | The Mac apps minirun launched: id, name, bundle id, pid, running or not, who they're for (workspace label), last used, windows. |
| `list_windows` | One Mac app's windows: index, title, frame (points), main/key/minimized, on screen. |
| `scroll` | Mac app id: scroll-wheel at a window point (default: window center) by `dx`/`dy` points, or `direction` like `swipe`. |
| `press_menu_item` | Mac app id: pick a menu bar item by path, e.g. `["File", "New Window"]`, through AX (case-insensitive, prefix match on `…`-stripped titles). Lists the top-level menus on a miss. |

## Several sessions on one Mac

- **One process per workspace.** A `MacAppStore` (MiniRunKit, persisted to
  `~/.config/minirun/mac-apps.json`) maps Mac app id → `{label, bundleID, appPath, executable,
  pid, logPath, launchedAt, updatedAt}`. `build_and_run` only ever quits the pid it recorded for
  that same id. After `minirun serve` restarts, entries whose pid is still alive with the same
  executable are kept; others are marked not running.
  Mac apps are spawned directly and never recorded in `ChildProcessLedger`, so the cleanup of
  orphans a previous `minirun serve` left behind (xcodebuild, commands) leaves them running.
- **Same app, two branches.** Two checkouts of Fetch share a bundle id. Spawning the executable
  directly (not `open`) avoids LaunchServices handing the launch to the instance already running.
  They still share UserDefaults and containers; `isolated_home` separates non-sandboxed apps. The
  tool descriptions say this.
- **No stolen mouse.** Element taps go through `AXPress`, which needs no focus. Coordinate clicks,
  scrolls and keys are CGEvents posted to the app's pid (`CGEvent.postToPid`) with the target
  window number set, so they don't move the user's cursor or need the window in front. If an
  app ignores pid-posted events, the driver falls back to raising the window and posting to the
  HID tap, under one global `mac-input` lock, and the result notes it.
- **Windows can overlap.** ScreenCaptureKit captures a single window (`SCContentFilter(
  desktopIndependentWindow:)`) even when other windows cover it.
- **Idle apps quit.** A Mac app minirun launched and nobody used for `idleShutdownMinutes` is
  quit, like idle simulators. An open live view or a running job counts as use.
- **macOS UI tests take over the real mouse and keyboard**, so `run_tests` for macOS runs UI
  test bundles under a global lock (one at a time on the Mac) and says so. Unit tests run
  concurrently.

## Live view

The viewer streams a Mac app's window the same way it streams a simulator. The stream key is the
Mac app id. The Mac sends the window as H.264 from an `SCStream` (VideoToolbox, as for
simulators), with JPEG as the fallback. The window's size can change, so the stream re-announces
`screen` (point and pixel size) and sends a keyframe when it does.

The relay already forwards a viewer's input as tool calls with `device` set to the stream key,
so viewer taps on a Mac stream reach the Mac app. Swift-side, a `touch` message for a Mac app id
becomes mouse down / drag / up. The viewer additionally:

- lists Mac apps in its picker (entries in the `simulators` message carry `kind: "mac"`; their
  `udid` field is the Mac app id),
- hides Home and other simulator-only buttons for Mac streams and shows the app's name,
- sends `scroll` for wheel / two-finger trackpad scrolling, right-click as `tap {button: "right"}`,
  double-click as `tap {count: 2}`, and keys with modifiers as `press_key {modifiers}`.

`RelayProtocol.version` goes to 5 ("Mac app streams"). The relay must allow `scroll` and
`press_menu_item` from viewers.

## Permissions and host checks

macOS gates screen capture and input behind TCC, granted per binary: here the daemon,
`/Applications/minirun.app/Contents/Helpers/minirun`, launched by launchd.

- **Doctor checks** (`minirun doctor`, `host_info`, the menu bar app): Screen Recording
  (`CGPreflightScreenCaptureAccess`), Accessibility (`AXIsProcessTrusted`), and whether the Mac
  has an active display (headless Mac minis need auto-login and a display or HDMI dummy plug for
  window capture). Each failing check says how to fix it. These checks don't fail the iOS loop:
  they are reported as "needed for macOS apps".
- **Asking for them from the right process.** A new control socket command,
  `request_mac_permissions`, makes `minirun serve` itself call `CGRequestScreenCaptureAccess()`
  and `AXIsProcessTrustedWithOptions(prompt: true)`, so the prompt names the daemon. The menu bar
  app's Setup window gets a "macOS apps" step with a button that does that and opens the right
  System Settings panes, and a status row that turns green once granted.
- **Known caveat:** the app is ad-hoc signed, so macOS may treat each new build as a different
  binary and drop the grants after an update. The Setup step and the doctor check detect this
  and say to re-grant. Signing with a stable local identity is a follow-up.

## Architecture and code layout

```
MiniRunKit (Linux-testable, plain Swift)
  BuildPlatform.swift        platform enum, destination args, auto-detection from build settings
  XcodeParsing+Mac.swift     macOS AppProduct (executable path), SUPPORTED_PLATFORMS, signing errors
  MacAppStore.swift          Mac app sessions, ids, persistence, IdleMacApps.plan
  MacGeometry.swift          window-point ↔ global-point conversion, JPEG sizing math
  MacKeys.swift              key names + modifiers → virtual key codes and CGEventFlags bits
  Doctor / Status / MenuModel / ControlSocket   Mac checks, ServeStatus.macApps, menu rows, commands

MiniRunMac (new target, macOS only, AppKit + ApplicationServices + ScreenCaptureKit + VideoToolbox;
            does not link FBSimulatorControl)
  MacAppDriver.swift         launch / terminate / windows / screenshot / describeUI / input / menus / logs
  MacAccessibility.swift     AXUIElement tree → AXe-shaped JSON, element search
  MacInput.swift             CGEvent clicks, drags, scrolls, keys posted to a pid
  MacPermissions.swift       TCC checks and requests, active display check
  MacWindowEncoder.swift     SCStream of one window → H.264 Frame (same shape as ScreenEncoder.Frame)

MiniRunCore
  MacTools.swift             list_mac_apps, list_windows, scroll, press_menu_item, and the Mac
                             branches of the existing tools (routing on a "mac-" device)
  CodeTools.swift            platform on build / build_and_run / run_tests
  XcodeBuild.swift           destination from BuildPlatform; signing fallback; macOS product
  FrameStreamer.swift        Mac app streams; mac apps in the `simulators` message
  ToolRegistry.swift         MacAppStore, idle Mac app quitting, status

worker/                      viewer picker kinds, Mac input mapping, relay allow-list, tests, dist
App/                         Mac apps section in the menu, permissions step in Setup
Tests/Fixtures/HelloMacApp   SwiftUI macOS fixture for the smoke test
```

### Interfaces between the parts

These are the contracts the work streams build against. Names may be refined, but changes must
keep both sides in step.

```swift
// MiniRunKit/BuildPlatform.swift
public enum BuildPlatform: String, Sendable, CaseIterable {
    case ios, macos, macCatalyst = "mac-catalyst"
    public var isMac: Bool { self != .ios }
    /// xcodebuild -destination value. `udid` is required for .ios.
    public func destination(udid: String?) -> String
        // ios: "platform=iOS Simulator,id=UDID"; macos: "platform=macOS,arch=arm64" (host arch);
        // mac-catalyst: "platform=macOS,variant=Mac Catalyst,arch=arm64"
    /// From `-showBuildSettings -json` of the scheme (no destination): macos if
    /// SUPPORTED_PLATFORMS lacks iphonesimulator/iphoneos and has macosx, else ios.
    public static func detect(fromBuildSettings json: Data) -> BuildPlatform
}

// MiniRunKit/XcodeParsing+Mac.swift
extension XcodeParsing {
    public struct MacAppProduct: Equatable, Sendable {
        public let appPath: String            // …/Build/Products/Debug/Fetch.app
        public let executablePath: String     // appPath + "/Contents/MacOS/" + EXECUTABLE_NAME
        public let bundleIdentifier: String?
        public let productName: String?
    }
    public static func parseMacAppProduct(_ json: Data) -> MacAppProduct?
    /// True for "requires a development team", "No signing certificate", "No profiles for" …
    public static func isSigningFailure(_ output: String) -> Bool
}

// MiniRunKit/MacAppStore.swift
public struct MacAppSession: Codable, Equatable, Sendable {
    public var id: String          // "mac-" + 6 hex chars
    public var label: String?      // workspace label it's for
    public var name: String        // app display name
    public var bundleID: String?
    public var appPath: String
    public var executablePath: String
    public var pid: Int32?         // nil when not running
    public var logPath: String?
    public var launchedAt: Date?
    public var updatedAt: Date     // last use
}
public enum MacAppID {
    public static let prefix = "mac-"
    public static func isMacDevice(_ device: String?) -> Bool   // "mac" or "mac-…"
    public static func forLabel(_ label: String) -> String       // stable hash of the label
    public static func random() -> String
}
public actor MacAppStore {
    public init(url: URL)
    public static var defaultURL: URL                 // ~/.config/minirun/mac-apps.json
    public func session(_ id: String) -> MacAppSession?
    public func all() -> [MacAppSession]
    public func upsert(_ session: MacAppSession)
    public func touch(_ id: String)
    public func markExited(_ id: String)
    public func remove(_ id: String)
    /// Keeps entries whose pid `isAlive(pid, executablePath)` still says are ours; clears pid of the rest.
    public func reconcile(isAlive: (Int32, String) -> Bool)
}
public enum IdleMacApps {
    /// Running apps not in `busy` and unused for `idleAfter` seconds → ids to quit.
    public static func plan(_ sessions: [MacAppSession], busy: Set<String>, idleAfter: TimeInterval, now: Date) -> [String]
}

// MiniRunKit/MacGeometry.swift — pure math on plain doubles (no CoreGraphics on Linux)
public struct MacRect: Equatable, Sendable, Codable { x, y, width, height }   // top-left origin, points
public enum MacGeometry {
    public static func toGlobal(windowPoint: (x: Double, y: Double), window: MacRect) -> (x: Double, y: Double)
    public static func toWindow(globalRect: MacRect, window: MacRect) -> MacRect
    public static func contains(_ window: MacRect, windowPoint: (x: Double, y: Double)) -> Bool
}

// MiniRunKit/MacKeys.swift
public enum MacKeys {
    public struct Modifiers: OptionSet, Sendable { command, shift, option, control, function }
    public static func parseModifiers(_ names: [String]) throws -> Modifiers   // accepts cmd/⌘/alt/ctrl aliases
    public static func flags(_ m: Modifiers) -> UInt64                         // CGEventFlags raw bits
    public static func keyCode(_ name: String) -> UInt16?                      // kVK_* virtual key codes, US layout
}

// MiniRunMac/MacAppDriver.swift
public struct MacWindowInfo: Sendable, Equatable {
    public let index: Int, windowID: UInt32, title: String
    public let frame: MacRect        // global points, top-left origin
    public let isMain: Bool, isMinimized: Bool, isOnScreen: Bool
}
public enum MacWindowSelector: Sendable { case main, index(Int), title(String) }
public enum MacElementQuery: Sendable { case id(String), label(String), value(String) }
public enum MacMouseButton: String, Sendable { case left, right }
public struct MacPermissionStatus: Sendable { public let screenRecording: Bool, accessibility: Bool, hasDisplay: Bool }

@MainActor public final class MacAppDriver {
    public static let shared: MacAppDriver
    public func permissions() -> MacPermissionStatus
    public func requestPermissions()                                 // prompts as this process
    public func launch(executablePath: String, arguments: [String], environment: [String: String], logURL: URL) throws -> Int32
    public func appPath(forBundleID: String) -> String?
    public func waitForWindow(pid: Int32, timeout: TimeInterval) async -> Bool
    public func terminate(pid: Int32, grace: TimeInterval) async
    public func isRunning(pid: Int32, executablePath: String?) -> Bool
    public func windows(pid: Int32) -> [MacWindowInfo]
    public func screenshotJPEG(pid: Int32, window: MacWindowSelector, scale: Double?, quality: Int) async throws
        -> (data: Data, width: Int, height: Int, window: MacWindowInfo)  // default: width == window points
    public func describeUI(pid: Int32, window: MacWindowSelector, includeMenus: Bool, at point: (x: Double, y: Double)?) throws -> Data
    public func press(pid: Int32, window: MacWindowSelector, query: MacElementQuery, wait: TimeInterval) async throws -> (x: Double, y: Double)
    public func click(pid: Int32, window: MacWindowSelector, x: Double, y: Double, button: MacMouseButton, count: Int) async throws
    public func drag(pid: Int32, window: MacWindowSelector, from: (x: Double, y: Double), to: (x: Double, y: Double), duration: Double, hold: Double) async throws
    public func mouse(pid: Int32, window: MacWindowSelector, phase: String, x: Double, y: Double) async throws  // live view touches: down/move/up
    public func scroll(pid: Int32, window: MacWindowSelector, x: Double?, y: Double?, dx: Double, dy: Double) async throws
    public func typeText(pid: Int32, text: String) async throws
    public func pressKey(pid: Int32, key: String, modifiers: MacKeys.Modifiers) async throws
    public func pressMenuItem(pid: Int32, path: [String]) throws -> String     // the title path it pressed
    public func openURL(_ url: String, appPath: String) async throws
    public func setPasteboard(_ text: String)
    public func logs(pid: Int32?, processName: String, capturedLog: URL?, since: Date?, seconds: Int, filter: String?) async throws -> String
    public func windowEncoder(pid: Int32, window: MacWindowSelector, scale: Double, fps: Int,
                              bitrate: @escaping @Sendable (Int, Int) -> Int) async throws -> MacWindowEncoder
}

// MiniRunMac/MacWindowEncoder.swift — same methods FrameStreamer calls on ScreenEncoder
public final class MacWindowEncoder: @unchecked Sendable {
    public struct Frame: Sendable { nalUnits, lengthSize, parameterSets, isKeyframe, sourceWidth, sourceHeight, pointWidth, pointHeight }
    public func encode(forceKeyframe: Bool) async throws -> Frame?   // nil when nothing changed
    public func waitForChange(timeout: TimeInterval) async
    public func jpeg(scale: Double, quality: Int) async throws -> (data: Data, width: Int, height: Int)  // JPEG fallback
    public func close()
}
```

## Work streams

Phase 1 runs in parallel. Each stream owns its files; the only shared files are listed.

1. **Build pipeline** — `BuildPlatform.swift`, `XcodeParsing+Mac.swift`, `XcodeBuild.swift`
   (destination from a platform, macOS product lookup, retry once with ad-hoc signing
   (`CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=`)
   when the first build fails only on signing, and say so), the `HelloMacApp` fixture
   (SwiftUI window with a labelled button, a text field, a counter label, a menu command and a
   `print` on each action), Linux tests in `Tests/MiniRunKitTests/MacBuildTests.swift`.
2. **Mac driver** — `Package.swift` (the `MiniRunMac` target, a dependency of MiniRunCore and the
   `minirun` executable), everything in `Sources/MiniRunMac/`, `MacGeometry.swift`,
   `MacKeys.swift`, Linux tests in `Tests/MiniRunKitTests/MacInputTests.swift`.
3. **Viewer and relay** — `worker/` only: picker kinds, Mac input mapping (click, right click,
   double click, drag, wheel scroll, modifier keys), allow-list, tests, rebuilt `dist/`.
4. **Host: store, checks, status, menu bar app** — `MacAppStore.swift`, Doctor checks (driven by
   an injected `macPermissions` closure, like `loadFrameworks`), `ServeStatus.macApps`, menu
   model rows, control commands `request_mac_permissions` and `quit_mac_app`, the App's Mac apps
   section and Setup step, Linux tests in `Tests/MiniRunKitTests/MacHostTests.swift`.

Phase 2, after phase 1 merges:

5. **Integration** — `MacTools.swift` and the Mac branches of existing tools, platform on the
   build tools, FrameStreamer Mac streams, idle Mac app quitting, the daemon's control handlers,
   `RelayProtocol.version` 5, `scripts/smoke-test.sh` Mac section (build, launch, describe_ui,
   tap by id, type, menu, logs, quit; screenshot and input only when the runner has the TCC
   grants, skipped with a clear message otherwise), README, CHANGELOG.

Phase 3:

6. **Review** — an independent review of the whole change for correctness, multi-session safety
   (never touching another session's pid), and permission failure messages; then fixes.

## Testing

- **Linux CI** (`swift test`): platform detection, destination strings, macOS product parsing,
  signing failure detection, Mac app ids, store persistence and reconcile, idle plan, geometry,
  key and modifier tables, doctor check formatting, status encoding, menu rows.
- **Worker tests**: Mac entries in the picker, allowed viewer tools, Mac input messages.
- **macOS CI** (`macos-26`): everything compiles; the smoke test builds and launches
  HelloMacApp, reads logs and quits it. GitHub's runners may lack Screen Recording and
  Accessibility grants, so steps that need them check `MacAppDriver.permissions()` and are
  skipped with a notice, not failed.
- **On the real Mac**, after install: grant the two permissions, then run the full loop against
  HelloMacApp and Fetch with two sessions at once (two branches of the same app) to check
  isolation, and watch it live in the viewer.

## Release checklist (on the real Mac)

CI covers the loop on HelloMacApp. After installing the release, check what CI can't:

1. **Permissions.** Menu bar app → Set Up → macOS apps → Request Access; grant Screen Recording
   and Accessibility; `minirun doctor` shows all three Mac checks ✓. Restart `minirun serve` and
   check they still hold.
2. **Fetch end to end.** `build_and_run {repo: "devenjarvis/fetch", ref: <branch>, platform:
   "macos"}`. If the build needed the ad-hoc signing fallback and the app exits at launch, the
   result should blame entitlements (iCloud, push, team app groups).
3. **Input on a real app.** describe_ui, tap by id and at a point, right click, double click,
   drag (swipe / long_press), type_text, press_key with ⌘, press_menu_item, scroll.
4. **Two sessions at once.** Two branches of the same app via `build_and_run`: each gets its own
   Mac app id, rebuilding one never quits the other, and `isolated_home` keeps their data apart.
5. **Live view.** Open the Mac app from the viewer's picker; click, scroll and type; resize the
   window while watching; try `?codec=jpeg`.
6. **Menu bar app.** The Mac apps section shows the app with Watch live, Bring to front and Quit.
7. **Idle quitting** after `idleShutdownMinutes`, and reconciling after `minirun serve` restarts.
8. **After the next update,** check whether macOS dropped the permission grants (ad-hoc signing).

## Out of scope for now

- Command-line tools and menu bar–only (`LSUIElement`) apps beyond launch and logs (they have no
  window to capture; `run_command` covers CLIs).
- Signing with a team identity or notarizing builds.
- Driving system UI outside the app (permission prompts the app triggers, Finder, System Settings).
  Results mention when a system dialog may be showing.
- Per-session sandbox containers for sandboxed apps that share a bundle id.
