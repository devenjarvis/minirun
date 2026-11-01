# Plan: lower live view latency (WebRTC)

> **Status:** planned. Phase 0 (quick fixes, latency readout) and phase 1 (WebRTC) are in
> progress on separate branches, listed below. GIF quality and speed are out of scope: another
> branch is working on them.

## Why

Today every frame and every touch goes through the Durable Object (`MacRelay`) in Cloudflare's
ATL data center, over one TCP WebSocket on each side:

- **Hairpin.** The Mac mini's round trip to the relay is about 26–40 ms (`Relay round trip` in
  `~/Library/Logs/minirun/minirun.log`, plus `ping`). A phone on the same Wi-Fi as the Mac still
  pays Mac → ATL → phone for frames and phone → ATL → Mac for touches: about 60–80 ms of network
  time where a direct path on the home network would take a few ms. The menu bar app's live view
  window (`LiveViewWindow`, a WKWebView of the Worker page) sends the Mac's own frames to Atlanta
  and back. A page served over https can't open a plain connection to a LAN address, so **WebRTC
  is the only way a browser can connect to the Mac directly.**
- **TCP, no bitrate control.** One lost packet holds up every frame behind it. A lagging viewer
  makes the relay skip frames and ask for a keyframe, and keyframes are the largest frames.
  WebRTC adjusts the bitrate to the connection, resends single lost packets (NACK) and recovers
  with a keyframe request (PLI) only when it has to.
- **Encoder not in low-latency mode.** `ScreenEncoder` and `MacWindowEncoder` don't request
  VideoToolbox's low-latency rate control.
- **Slow touch path.** Every live touch event runs `HIDBroker.currentBootIdentity`, which reads
  the arguments of every process on the Mac (about 950) to find `launchd_sim`. `physicalPoints`
  also sets up a new orientation check every time. `TouchQueue` handles events one at a time, so
  every touch-down and touch-up waits for this.

### Cost

Streaming barely costs anything on Workers today. While someone watches, the Durable Object is
awake: about 450 GB-s per hour, plus about 60 WebSocket messages a second (frames and acks,
billed 20 messages to a request). That's under 1¢ per streaming hour, mostly within the Workers
Paid plan's included usage. With WebRTC the relay only carries connection setup.
`stun.cloudflare.com` is free and unlimited. Cloudflare Realtime TURN costs $0.05/GB after
1,000 GB a month free, and is only used when a direct connection fails (mostly on cellular).

## Phase 0: quick fixes and a latency readout

### 0a. Encoder and touch path (`claude/live-latency-encoder-input`)

- In `ScreenEncoder.makeSession` and `MacWindowEncoder.makeSession`, create the session with
  `kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true`. Set
  `kVTCompressionPropertyKey_MaxFrameDelayCount = 0` and
  `kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality = true`. Low-latency mode wants a
  profile it supports (Constrained Baseline or Constrained High). If creating the session fails,
  create it again with today's settings so the stream still starts. Keep the SPS VUI fix
  (`H264.withoutReordering`), and check it still applies to the new SPS.
- In the touch path, keep the HID session and the boot identity while sending works. Check the
  boot identity again only after a failure, or after it is a few seconds old. Do the same for the
  orientation in `physicalPoints`. Log the time per live touch event before and after the change
  (debug log only) to measure the gain.

### 0b. Latency readout (`claude/live-latency-stats`)

Show the latency so every later change has a number. In the viewer, `?stats=1` (or a small
toggle) shows an overlay with:

- **RTT viewer ↔ Mac.** The viewer sends `{type: "probe", t}`, the relay passes it to the Mac,
  and the Mac sends it straight back as `{type: "probe", t}` to that viewer.
- **Mac pipeline.** For each frame, the Mac measures the time from frame capture (framebuffer
  damage, or ScreenCaptureKit delivering the frame) to the frame being handed to the socket.
  The Mac sends a rolling average in a `{type: "stats", key, ...}` text message about once a
  second. Change the binary frame format only if there's a good reason, and if so raise
  `RelayProtocol.version`.
- **Viewer.** Frame received → frame drawn (WebCodecs output, or `img.onload`), frames per
  second, and kbps.
- **Touch to screen.** The Mac measures from a live touch arriving to the next frame sent after
  the screen changes. Report it in the same `stats` message.

The total is about Mac pipeline + RTT/2 + viewer time. Phase 1 reports the same fields from
`RTCPeerConnection.getStats()` (`roundTripTime`, `jitterBufferDelay`, `totalDecodeTime`,
`framesPerSecond`), so the WebSocket path and WebRTC can be compared directly.

As built (protocol stays 5; the binary frame format is unchanged):

- **Viewer ids.** The relay gives each viewer socket a random `viewer` id in its attachment
  (the one protocol 6 uses). A socket from before ids existed gets one when it first needs it.
- **Probe.** Viewer → relay: `{type: "probe", t}` (`t` is the page's `performance.now()`; a
  probe without a finite number is dropped). Relay → Mac: `{type: "probe", t, viewer}`. Mac →
  relay: the same, straight back. Relay → that viewer only: `{type: "probe", t}`. A Mac older
  than this ignores probes, and the readout shows no RTT.
- **Stats.** Mac → relay → the stream's viewers: `{type: "stats", key, codec, fps, pipelineMs,
  pipelineP95Ms, touchMs?, touchP95Ms?}`, in ms rounded to 0.1. `codec` is `"h264"` or `"jpeg"`,
  `fps` is frames sent per second. Pipeline figures cover the last 60 frames, touch figures the
  last 20 touches that changed the screen (left out until there is one). Sent at most once a
  second, and only when a frame was sent, so a still screen sends nothing (`LatencyStats` in
  MiniRunKit).
- **Capture time.** Simulators (H.264): the first framebuffer damage since the last frame, so
  the figure includes waiting for the frame interval (`ScreenEncoder.Frame.capturedAt`). Mac
  windows (H.264): when ScreenCaptureKit delivered the frame (`MacWindowEncoder.Frame.capturedAt`).
  JPEG: just before the screenshot. A keyframe of an unchanged screen counts from when it's
  encoded.
- **Touch to screen.** From the Mac decoding a `touch` message to sending the next frame that
  was captured after it and shows a change (JPEG frames with the same bytes as the last one
  don't count). A touch with no such frame within 2 s is dropped.
- **Viewer.** `?stats=1` turns the readout on and `?stats=0` off. Either is remembered in
  `localStorage` (`minirun.stats`), as is the "ms" button in the header. While it's on, the page
  probes once a second. The readout takes its numbers from `readout.update({transport, rtt, mac,
  macP95, macFps, view, fps, kbps, touch, touchP95})`, so WebRTC can feed it from `getStats()`;
  `macStats(m)` and `probeAnswered(m)` take the Mac's `stats` and `probe` messages from whichever
  channel they came on. It shows "Frame total ≈ mac + rtt/2 + view" and "Touch total ≈ rtt +
  touch + view".

## Phase 1: WebRTC (`claude/webrtc-mac` + `claude/webrtc-viewer`)

The Durable Object becomes the signaling channel. Media and input go directly between the Mac
and the viewer. The current WebSocket stream stays as the automatic fallback.

### Shared contract (protocol 6)

Both branches implement exactly this. Change it here first if it has to change.

- **Version.** `RelayProtocol.version` becomes 6, and the Mac's `hello` adds `"webrtc": true`.
  The relay's `status` message to viewers adds `webrtc: boolean`: true when the Mac's hello said
  so.
- **Viewer ids.** On connect, the relay gives each viewer socket a random `viewer` id, kept in
  its attachment, so it survives hibernation. Every `rtc` message between the relay and the Mac
  carries that id. The relay never forwards an `rtc` message from the Mac to a viewer with a
  different id.
- **Messages.** All `rtc` messages are JSON text on the existing sockets.
  - Viewer → relay: `{type: "rtc", action: "start", device, fps, quality, scale}`. The relay sets
    the viewer's state to `codec: "webrtc"`, which takes it out of `syncStreams` (no WebSocket
    frames for it). It then sends the Mac `{type: "rtc", action: "start", viewer, key, fps,
    quality, scale, iceServers}`.
  - Mac → relay → viewer: `{type: "rtc", action: "offer", viewer, sdp}`. The Mac makes the offer.
  - Viewer → relay → Mac: `{type: "rtc", action: "answer", sdp}` (the relay adds `viewer`).
  - Both ways: `{type: "rtc", action: "candidate", candidate, sdpMid, sdpMLineIndex}` (trickle
    ICE). `candidate: null` means end of candidates.
  - Both ways: `{type: "rtc", action: "stop"}`. The relay sends `stop` to the Mac when the
    viewer's socket closes or the viewer switches to another device.
  - Mac → relay → viewer: `{type: "rtc", action: "error", viewer, message}`. The viewer falls
    back to the WebSocket stream.
- **ICE servers.** The relay sends the same list to both sides. It always includes
  `stun:stun.cloudflare.com:3478`. When the Worker has the secrets `TURN_KEY_ID` and
  `TURN_KEY_API_TOKEN`, the relay also adds short-lived Cloudflare Realtime TURN credentials
  (generated through Cloudflare's credentials API, cached until shortly before they expire).
  Without the secrets, it's STUN only.
- **Media.** The offer has one video track (sendonly from the Mac) per peer connection. Viewers
  watching the same simulator or Mac window share one capture source on the Mac. Each peer
  connection has its own track and encoder, which is fine for one or two viewers. H.264 is
  preferred, so Safari decodes in hardware.
- **Data channels.** The Mac creates two in the offer:
  - `"touch"`: unordered, `maxRetransmits: 0`. It carries `{phase, x, y}` for `move`.
    `down` and `up` go on `"input"`, so they are never lost.
  - `"input"`: ordered and reliable. It carries `{type: "touch", phase, x, y}` for down and up,
    `{type: "input", tool, arguments}` (as today), `{type: "probe", t}` (echoed back on the
    same channel), and Mac → viewer `{type: "screen", ...}`, `{type: "stream_status", ...}`
    and `{type: "stats", ...}`, with the same fields as the relay messages.
- **Security.** The relay no longer sees the input, so the Mac must enforce what
  `relay.ts` enforces today: the `VIEWER_TOOLS` allowlist, removing `input` and `window` from
  the arguments, setting `device` to the peer connection's own key, and treating the call as
  `fromViewer`. Signaling only reaches the Mac through an authenticated viewer socket, so only a
  logged-in viewer can open a peer connection. If the data channels close while a finger is
  down, the touch is released, as when a viewer socket closes.
- **Fallback.** The viewer starts with WebRTC when `status.webrtc` is true and the browser has
  `RTCPeerConnection`. If the connection hasn't reached `connected` within 8 s, or later reaches
  `failed`, the viewer sends `rtc stop` and the usual `stream` message (H.264 or JPEG over the
  WebSocket). `?transport=ws` forces the WebSocket path.

### Mac side (`claude/webrtc-mac`)

- **libwebrtc.** Add a prebuilt libwebrtc as a SwiftPM binary target in the macOS-only part of
  `Package.swift`, for example the `stasel/WebRTC` package, pinned to an exact version. Copy and
  codesign `WebRTC.framework` wherever the FB frameworks go: `scripts/install-app.sh`,
  `scripts/install.sh` and the release workflow. Add the license to `THIRD_PARTY_NOTICES.md`.
- **Video sources.** Use `RTCPeerConnectionFactory.videoSource(forScreenCast: true)`.
  - Simulators: the framebuffer `IOSurface` that `ScreenEncoder` already gets, wrapped in a
    `CVPixelBuffer` and passed in as `RTCCVPixelBuffer`, on each damage callback.
  - Mac windows: the ScreenCaptureKit `CVPixelBuffer`s that `MacWindowEncoder` already gets.
  - Factor the capture out of the two encoders so WebRTC and the current H.264 path use the same
    capture code.
  - Resend the last frame about once a second while the screen is still, so the encoder can
    sharpen the picture.
  - A resized Mac window produces frames of a new size. Send `screen` again, as today.
- **Encoding.** Use libwebrtc's own VideoToolbox H.264 encoder; don't pass through our own
  encoder's output. Set `degradationPreference` to maintain resolution (screen text must stay
  sharp), and cap the bitrate from `quality` with `H264.bitrate`.
- **Wiring.** Add a `WebRTCSessions` actor (one peer connection per viewer id) next to
  `FrameStreamer`. `RelayClient.handle` sends `rtc` messages to it. Touch and input from the
  data channels go through the same `TouchQueue` and `registry.call` paths as the relay's,
  after the security checks above. While a peer connection is open, call `activity.begin` for
  its device, as `FrameStreamer` does.

### Viewer and Worker side (`claude/webrtc-viewer`)

- **Relay.** In `relay.ts`: add viewer ids, route `rtc` messages, add `webrtc` to `status`,
  generate ICE servers (STUN, plus TURN when its secrets are set), and keep WebRTC viewers out of
  `syncStreams`. Add the TURN secrets to `env.ts`, `setup.sh` (optional) and the README.
- **Viewer.** In `viewer.ts`: show a `<video autoplay muted playsinline>` element when on
  WebRTC. `geometry()` uses its size and `videoWidth`/`videoHeight`. Send input over the data
  channels instead of the socket. Where the browser supports it, set
  `receiver.jitterBufferTarget = 0` (and `playoutDelayHint = 0` in Chrome). Fall back as
  described above. Feed the phase 0b overlay from `getStats()`.
- **Tests.** Extend `worker/test/worker.test.ts` for signaling routing: viewer ids, a viewer
  can't receive another viewer's offer, and `stop` when a viewer leaves. Test the whole flow
  without a Mac using a Playwright Chromium page that connects to `/agent` and acts as the Mac.
  Its video comes from `canvas.captureStream()`, and it answers on the data channels. Run it
  against `wrangler dev`.

### Done when

- On the same Wi-Fi as the Mac, the iPhone (Safari) and the menu bar app's live view window
  connect directly. `getStats` shows a `host` or `srflx` candidate pair, not `relay`, and the
  readout shows lower RTT and touch-to-screen times than the 0b baseline.
- On cellular, WebRTC either connects (with TURN if needed) or falls back to the WebSocket
  stream within about 8 s, with no action from the user.
- `scripts/e2e-relay.sh` and the smoke test still pass. The WebSocket path is unchanged for
  older viewers and Macs.

## Follow-ups (not scheduled)

- **Recording without `simctl`.** Write simulator recordings with `AVAssetWriter` from the
  framebuffer that's already captured, and remove the up-to-3 s wait for
  `simctl recordVideo` to start. Talk to whoever owns the GIF work first, since it changes the
  same files.
- **Local live view without the network.** The menu bar app could show the stream directly from
  the daemon (over the control socket, or WebRTC over loopback), with no Worker involved. With
  phase 1, the WKWebView window already connects over loopback, so this only matters if that
  isn't fast enough.
- **Native iOS viewer.** An iOS app could decode in hardware, use macOS 26/iOS 26
  `VTFrameProcessor` low-latency super resolution to show a half-size stream sharply, and use
  Bonjour to find the Mac on the LAN. Only worth it if you want an app for other reasons.
- **HEVC over WebRTC.** It saves bandwidth, not latency. Revisit if bandwidth on cellular is the
  limit.
- **Media over QUIC / WebTransport.** Cloudflare runs a MoQ relay, but Safari on iOS isn't a
  dependable WebTransport client yet. Check again later.
- **Mac on Ethernet.** The Mac mini is on Wi-Fi (en1). A cable lowers jitter for both paths.

## Not doing

- **Cloudflare Realtime SFU.** It adds a server hop for every frame and only helps with many
  viewers.
- **WHIP/WHEP into Cloudflare Stream.** It's still a server hop, with per-minute pricing.
