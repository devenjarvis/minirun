# Plan: the live view as a phone test bench

> **Status:** step 1 is done (the phone layout, device switching, Add to Home Screen, live typing
> and the screen wake lock; see the CHANGELOG). Steps 2–4 are planned. Each step should fit in its own PR.

## Why

The live view is often the first place a person tries a build by hand, on their phone, before
they install it on a real device. Two things got in the way:

- **It was small on a phone.** A simulator's screen has about the same shape as a phone's, so
  every point of height the page uses for something else shrinks the picture in both directions.
  On an iPhone 13 in Safari (390 × 664 points visible), the header (48 pt), footer (61 pt),
  padding (28 pt) and Safari's bars left the simulator at 242 × 527 points: about 60% of its real
  size. The text box was 95 points wide.
- **It could only tap, swipe and type.** A viewer may only send `tap`, `swipe`, `long_press`,
  `type_text`, `press_key`, `press_button`, `open_url`, `scroll` and `press_menu_item`, and the
  page has buttons for few of those. Everything else a manual tester reaches for (dark mode, text
  size, relaunching the app, a deep link, a screenshot to keep, telling Claude what's wrong)
  needs a Claude session or the Mac.

## Step 1: fit the phone (done)

Worker only (`worker/src/viewer.ts`, `worker/src/app.ts`); no change to the Mac or the protocol.

- **Compact layout.** On a touch screen that's small in one direction
  (`(pointer: coarse) and (max-width: 600px)`, or `max-height: 500px` for landscape), the header
  and footer are hidden and the stream fills the window below the safe area at the top. A
  floating button opens them over the stream; it can be dragged to either side, and its place is
  remembered. `?layout=compact` or `?layout=classic` picks a layout on any device. The menu bar
  app's live view window (a mouse, not a touch screen) keeps the classic layout.
- **Add to Home Screen.** `/manifest.webmanifest`, `/icon-180.png`, `/icon-512.png` and
  `/apple-touch-icon.png`, served without a login (browsers fetch them without cookies; they hold
  nothing private), and the `apple-mobile-web-app-*` tags. Opened from the Home Screen there are no
  Safari bars, and the simulator shows at about 90% of its real size. A Home Screen app has its
  own cookies, so the user logs in once there. Safari on an iPhone or iPad shows a hint in the
  controls until it's opened that way.
- **Live typing.** The text box sends what's typed as it's typed (grouped like a Mac app's keys,
  60 ms) and turns backspace into `press_key delete`. While it has focus it holds a zero-width
  space, so a backspace on an empty box still shows up as an input event on phone keyboards that
  send no key events. ⌫ and ⏎ don't take focus from the box, so the keyboard stays up.
- **Device switching.** In the compact layout the header's picker gives way to a device button
  (device name, the app on it from `last_app`, and `reserved_for`), which opens a full-width list
  of every booted simulator and running Mac app. The classic dropdown shows the app too. A
  device asked for by a link or the picker is remembered (`minirun.device` in localStorage); a
  page opened without `?device` switches to it once the device list arrives, if it's still
  running. The default stream (no device asked for) is never remembered.
- **Screen Wake Lock** while the stream is live. A sleeping phone hides the page, and a hidden
  page stops its stream.
- `overscroll-behavior: none` and `-webkit-touch-callout: none`, so pull-to-refresh and the
  long-press callout don't fight with gestures on the stream.

Still open from this step, to check on a real iPhone: how the fixed footer behaves when the
keyboard is up (iOS moves the visual viewport, not the layout viewport), and whether swiping in
from the left edge in a Safari tab (Safari's "back") gets in the way. In a Safari tab the
simulator is inset from the edges, and a Home Screen app has no back gesture, so neither is
expected to be a problem.

## Step 2: a controls sheet with tools that exist

Mac and Worker together: the viewer allowlist is in two places that must agree,
`VIEWER_TOOLS` in `worker/src/relay.ts` (WebSocket input) and `RelayProtocol.viewerTools` in
`Sources/MiniRunKit/RTCSignaling.swift` (the WebRTC data channel). Bump the protocol version so
the viewer only shows buttons the Mac takes.

| Control | Tool | Notes |
|---|---|---|
| Light / dark | `configure_simulator {appearance}` | Allow only `appearance`, `text_size`, `increase_contrast`, `latitude`/`longitude` from a viewer; drop `permission`, `status_bar` and anything else, in both allowlist places. |
| Text size | `configure_simulator {text_size}` | A slider over the Dynamic Type sizes, accessibility sizes included. |
| Increase contrast | `configure_simulator {increase_contrast}` | A toggle. |
| Location | `configure_simulator {latitude, longitude}` | A few presets (Cupertino, London, Tokyo) plus "custom". |
| Open a link | `open_url` | Already allowed for viewers; it only needs a field. Remember recent links per `reserved_for`. |
| Relaunch app | `terminate_app` + `launch_app` | Only for the simulator's `last_app` (already in the `simulators` message). The Mac should check the bundle id against the claim, not trust the page. |
| Fresh install | `uninstall_app` + the last build's install | Needs the path of the last built app on the claim; a new small Mac-side helper rather than exposing `install_app`. |
| Lock, Siri | `press_button` | Already allowed. |
| Save screenshot | none | Done in the browser: draw the current `<video>`/canvas/img to a canvas, `toBlob`, then `navigator.share({files})` (or a download on desktop). Note it's at the stream's scale (Sharp is 0.8). |
| Record a clip | none | `MediaRecorder` on the WebRTC stream (or `canvas.captureStream()` for the WebSocket path), then share. |

Tests: relay tests that a viewer's `configure_simulator` with `permission` or `status_bar` is
dropped and that `terminate_app` for another bundle id is refused; Swift tests for
`RelayProtocol.viewerArguments` with the same cases.

## Step 3: replies from the Mac, then "Flag for Claude"

Viewer input is fire-and-forget today: the page sends `{type: "input", tool, arguments}` and never
hears back. Everything in this step needs an answer.

1. **Request and reply.** Add an optional `id` to viewer `input` messages. The Mac answers on the
   same path (the WebRTC "input" data channel, which is reliable and already carries messages to
   the page, or through the relay for the WebSocket stream) with `{type: "result", id, isError,
   content}`. Size-limit what goes back (images as a URL, not inline).
2. **Full-size screenshot.** `screenshot` from a viewer, answered with the image, instead of the
   stream's scaled frame.
3. **Logs drawer.** `app_logs` for `last_app`, polled while the drawer is open, newest at the
   bottom.
4. **Flag for Claude.** A button that freezes the current frame, lets the user circle or arrow
   something and type a note, then saves a *finding*: the full-size screenshot, the drawing, the
   note, the tap point (in simulator points), a `describe_ui` snapshot at that moment, the
   device, `last_app` and `reserved_for`. Findings are kept per `reserved_for` (in the Durable
   Object's storage, or on the Mac next to the claim). Claude reads them with a new
   `review_findings {repo, ref}` MCP tool (and can mark them done), and `build_and_run` mentions
   how many open findings there are for its repo + ref. That turns a review on the phone into a
   to-do list Claude can work through, without screenshots going through chat.

Security: findings hold screenshots, so they follow the same rule as `screenshot {share: true}`:
never shared anywhere by themselves, and only readable through the authenticated MCP endpoint.

## Step 4: rotate and shake (Mac side)

No tool can do these yet.

- **Rotate.** The Mac already tracks the simulator's orientation when mapping touches
  (`physicalPoints`). Add a `rotate {device, orientation}` tool, then a button in the viewer. The
  viewer must take the new `screen` message's size (it already re-reads `pointWidth` and
  `pointHeight` on every `screen` message, as Mac app windows resize) and the compact layout
  should prefer landscape-shaped fitting when the phone is in landscape too.
- **Shake.** A `shake {device}` tool (the simulator's shake gesture, for apps with
  shake-to-undo or shake-to-report), then a button.

Both go in the viewer allowlist once they exist.
