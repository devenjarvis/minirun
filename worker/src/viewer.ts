import { baseStyles } from "./pages";

/**
 * The live viewer: streams a simulator's screen or a Mac app's window and turns touches into
 * taps and swipes. On a Mac app it also sends right and double clicks, wheel scrolling and keys.
 * When the Mac can (protocol 6), video and input go over a WebRTC peer connection straight to the
 * Mac, with the relay only carrying the signaling. Otherwise, or if that doesn't connect, browsers
 * with WebCodecs get H.264 over the WebSocket (decoded onto a canvas) and others get JPEG frames.
 */
export function viewerPage(): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover,user-scalable=no">
<meta name="theme-color" content="#0b0c0f">
<title>minirun</title>
<style>
${baseStyles}
body { display: flex; flex-direction: column; height: 100dvh; overflow: hidden; }
header { display: flex; align-items: center; gap: 10px; padding: calc(env(safe-area-inset-top) + 10px) 14px 10px; border-bottom: 1px solid var(--line); }
header .mark { margin: 0; }
.pill { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; color: var(--muted); padding: 4px 10px; border: 1px solid var(--line); border-radius: 999px; }
.pill i { width: 7px; height: 7px; border-radius: 50%; background: #5b6170; }
.pill.live i { background: #4ade80; box-shadow: 0 0 0 3px rgba(74,222,128,.15); }
.pill.offline i { background: var(--danger); }
.device { margin-left: auto; font-size: 13px; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 45vw; }
.sim { margin-left: auto; max-width: 55vw; padding: 6px 8px; font-size: 13px; text-overflow: ellipsis; }
.sim[hidden], .device[hidden] { display: none; }
main { flex: 1; min-height: 0; display: grid; place-items: center; padding: 14px; position: relative; }
.screen { position: relative; max-width: 100%; max-height: 100%; aspect-ratio: var(--ratio, 0.46); height: 100%; border-radius: 28px; overflow: hidden;
  background: #000; box-shadow: 0 0 0 1px var(--line), 0 20px 60px rgba(0,0,0,.5); touch-action: none; user-select: none; -webkit-user-select: none; }
.screen img, .screen canvas, .screen video { width: 100%; height: 100%; display: block; object-fit: contain; pointer-events: none; -webkit-user-drag: none; }
.screen img[hidden], .screen canvas[hidden], .screen video[hidden] { display: none; }
.screen:focus { outline: none; }
/* A Mac app's window: any shape (it can be resized while streaming), so it's fitted in both directions. */
body.mac main { container-type: size; }
body.mac .screen { height: auto; width: min(100cqw, 100cqh * var(--ratio, 1.6)); aspect-ratio: var(--ratio, 1.6); border-radius: 10px; }
body.mac .screen:focus-visible, body.mac .screen.focused { box-shadow: 0 0 0 1px var(--accent), 0 20px 60px rgba(0,0,0,.5); }
footer button[hidden] { display: none; }
.overlay { position: absolute; inset: 0; display: grid; place-items: center; text-align: center; padding: 24px; color: var(--muted); font-size: 14px; background: rgba(0,0,0,.55); }
.overlay[hidden] { display: none; }
.touch { position: absolute; width: 36px; height: 36px; margin: -18px 0 0 -18px; border-radius: 50%; background: rgba(124,196,255,.35); border: 2px solid rgba(124,196,255,.9);
  pointer-events: none; animation: touch .45s ease-out forwards; }
@keyframes touch { to { transform: scale(1.8); opacity: 0; } }
footer { display: flex; gap: 8px; align-items: center; padding: 10px 14px calc(env(safe-area-inset-bottom) + 10px); border-top: 1px solid var(--line); }
footer button { flex: 0 0 auto; padding: 10px 12px; font-size: 14px; }
footer form { flex: 1; display: flex; gap: 8px; min-width: 0; }
footer input { flex: 1; min-width: 0; padding: 10px 12px; border-radius: 10px; border: 1px solid var(--line); background: #0f1115; color: var(--text); font-size: 16px; }
.readout { position: absolute; top: 8px; left: 8px; z-index: 2; padding: 6px 8px; border-radius: 8px; background: rgba(0,0,0,.72); color: #d7dae0;
  font: 11px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre; pointer-events: none; }
.readout[hidden] { display: none; }
.stats-toggle { flex: 0 0 auto; padding: 3px 8px; font-size: 11px; border-radius: 999px; }
.stats-toggle[aria-pressed="true"] { color: var(--accent); border-color: var(--accent); }
select { padding: 10px 8px; border-radius: 10px; border: 1px solid var(--line); background: #1d2027; color: var(--text); font-size: 14px; }
</style>
</head>
<body>
<header>
  <div class="mark"><i></i>minirun</div>
  <span id="status" class="pill"><i></i><span>Connecting…</span></span>
  <button id="statsToggle" class="stats-toggle" type="button" title="Latency readout" aria-pressed="false">ms</button>
  <span id="device" class="device"></span>
  <select id="sim" class="sim" title="Simulator or Mac app" hidden></select>
</header>
<main>
  <div id="screen" class="screen" tabindex="0">
    <img id="frame" alt="Live screen">
    <canvas id="video" hidden></canvas>
    <video id="rtcVideo" autoplay muted playsinline disablepictureinpicture hidden></video>
    <div id="overlay" class="overlay">Connecting…</div>
  </div>
  <div id="readout" class="readout" hidden></div>
</main>
<footer>
  <button id="home" type="button" title="Home">Home</button>
  <form id="typing" autocomplete="off">
    <input id="text" placeholder="Type into the app…" enterkeyhint="send" autocapitalize="off" autocorrect="off" spellcheck="false">
    <button type="button" id="backspace" title="Delete">⌫</button>
    <button type="button" id="enter" title="Return">⏎</button>
  </form>
  <select id="quality" title="Stream quality">
    <option value="saver">Saver</option>
    <option value="smooth">Smooth</option>
    <option value="sharp">Sharp</option>
  </select>
</footer>
<script>
(() => {
  const presets = {
    jpeg: { saver: { fps: 6, quality: 45, scale: 0.33 }, smooth: { fps: 15, quality: 55, scale: 0.5 }, sharp: { fps: 10, quality: 80, scale: 0.8 } },
    // H.264 only sends frames when the screen changes, so it can afford a higher frame rate.
    h264: { saver: { fps: 10, quality: 45, scale: 0.33 }, smooth: { fps: 30, quality: 55, scale: 0.5 }, sharp: { fps: 30, quality: 80, scale: 0.8 } },
  };
  const $ = (id) => document.getElementById(id);
  const screenEl = $("screen"), img = $("frame"), canvas = $("video"), videoEl = $("rtcVideo"), overlay = $("overlay"), statusEl = $("status"), deviceEl = $("device"), simEl = $("sim");
  let ws = null, retry = 1000, online = false, live = false;
  // Whether the Mac takes live touches; older ones get whole gestures on finger-up instead.
  let touchLive = false;
  let screen = null; // { udid, pointWidth, pointHeight, name, kind? }, the latest for this stream
  // Booted simulators and running Mac apps ({ udid, name, kind: "mac", reserved_for } for those).
  let simulators = [];
  // The simulator or Mac app this page shows: ?device=UDID or ?device=mac-…, or "" for whichever simulator is booted.
  let wanted = new URLSearchParams(location.search).get("device") || "";
  let currentURL = null, decoding = false, pendingFrame = null;
  // "h264" once we know this browser can decode it (?codec=jpeg forces JPEG).
  let codec = "jpeg";
  const video = { decoder: null, codec: "", needKeyframe: true, errors: 0 };

  const store = { get(k) { try { return localStorage.getItem(k); } catch { return null; } }, set(k, v) { try { localStorage.setItem(k, v); } catch {} } };
  $("quality").value = store.get("minirun.quality") || "smooth";

  function setStatus(kind, text) {
    statusEl.className = "pill " + kind;
    statusEl.lastElementChild.textContent = text;
  }
  function showOverlay(text) { overlay.textContent = text; overlay.hidden = !text; }

  // The latency readout (?stats=1, or the "ms" button; remembered). It shows whatever it's given
  // through readout.update, so every transport feeds it the same fields, in ms unless noted:
  // transport ("ws h264", "ws jpeg", "webrtc host h264"), rtt (viewer ↔ Mac), mac and macP95 (capture → socket on the
  // Mac), macFps, view (frame received → drawn), fps and kbps (as drawn and received here), and
  // touch and touchP95 (a live touch reaching the Mac → the next changed frame sent).
  const readoutEl = $("readout"), statsToggle = $("statsToggle");
  const readout = {
    on: false,
    fields: {},
    update(fields) { Object.assign(this.fields, fields); if (this.on) this.render(); },
    reset() { this.fields = {}; if (this.on) this.render(); },
    render() {
      const f = this.fields, num = (v) => typeof v === "number" && Number.isFinite(v);
      const ms = (v) => num(v) ? Math.round(v) + " ms" : "–";
      const p95 = (v) => num(v) ? "  p95 " + Math.round(v) : "";
      const row = (label, value) => label.padEnd(13) + value;
      const lines = [
        [f.transport || "–", num(f.fps) ? Math.round(f.fps) + " fps" + (num(f.macFps) ? " (Mac " + Math.round(f.macFps) + ")" : "") : "", num(f.kbps) ? Math.round(f.kbps) + " kbps" : ""].filter(Boolean).join(" · "),
        row("RTT", ms(f.rtt)),
        row("Mac", ms(f.mac) + p95(f.macP95)),
        row("Viewer", ms(f.view)),
        row("Touch (Mac)", ms(f.touch) + p95(f.touchP95)),
        // A frame: the Mac's pipeline, half the round trip, then the viewer. A touch: half the
        // round trip there, the Mac's touch time (which includes its pipeline), half back, the viewer.
        row("Frame total", num(f.mac) && num(f.rtt) && num(f.view) ? "≈ " + ms(f.mac + f.rtt / 2 + f.view) : "–"),
        row("Touch total", num(f.touch) && num(f.rtt) && num(f.view) ? "≈ " + ms(f.rtt + f.touch + f.view) : "–"),
      ];
      readoutEl.textContent = lines.join("\\n");
    },
  };
  // The Mac's figures for the stream on screen (a "stats" message).
  function macStats(m) {
    if ((m.key || "") !== wanted) return;
    readout.update({ mac: m.pipelineMs, macP95: m.pipelineP95Ms, macFps: m.fps, touch: m.touchMs, touchP95: m.touchP95Ms });
  }
  // The round trip to the Mac and back: "probe" carries this page's clock, which the Mac echoes.
  // On WebRTC it goes over the data channel, and the Mac echoes it there.
  function probe() {
    const message = { type: "probe", t: performance.now() };
    if (!sendInput(message)) send(message);
  }
  function probeAnswered(m) {
    if (typeof m.t !== "number") return;
    // WebRTC's own round trip (from the candidate pair) is the figure there; a probe fills in without it.
    if (peer && peer.pairRtt) return;
    readout.update({ rtt: performance.now() - m.t });
  }

  // The WebSocket stream's own figures: when each frame arrived (by sequence number), when it
  // was drawn, and the bytes received, summed up once a second.
  const meter = { bytes: 0, drawn: 0, waits: [], since: performance.now(), received: new Map(), timer: null };
  function frameReceived(seq, bytes) {
    meter.bytes += bytes;
    // Sequence numbers start again when the Mac restarts a stream; old ones are never drawn.
    if (meter.received.size > 200) meter.received.clear();
    meter.received.set(seq, performance.now());
  }
  function frameDrawn(seq) {
    const t = meter.received.get(seq);
    // Frames skipped on the way (a newer JPEG came first, or H.264 waiting for a keyframe) go too.
    for (const s of meter.received.keys()) { if (s > seq) break; meter.received.delete(s); }
    meter.drawn++;
    if (t !== undefined) meter.waits.push(performance.now() - t);
  }
  function meterTick() {
    if (peer) { peerStats(); probe(); return; }
    const now = performance.now(), seconds = Math.max(0.001, (now - meter.since) / 1000);
    const fields = { transport: "ws " + codec, fps: meter.drawn / seconds, kbps: meter.bytes * 8 / 1000 / seconds };
    // A still screen draws nothing; keep the last time rather than show none.
    if (meter.waits.length) fields.view = meter.waits.reduce((a, b) => a + b, 0) / meter.waits.length;
    meter.bytes = 0; meter.drawn = 0; meter.waits = []; meter.since = now;
    readout.update(fields);
    probe();
  }
  function showReadout(on) {
    readout.on = on;
    readoutEl.hidden = !on;
    statsToggle.setAttribute("aria-pressed", String(on));
    clearInterval(meter.timer);
    meter.timer = null;
    if (!on) return;
    meter.bytes = 0; meter.drawn = 0; meter.waits = []; meter.since = performance.now();
    meter.timer = setInterval(meterTick, 1000);
    readout.render();
    probe();
  }
  const statsParam = new URLSearchParams(location.search).get("stats");
  if (statsParam === "1" || statsParam === "0") store.set("minirun.stats", statsParam);
  statsToggle.onclick = () => { const on = !readout.on; store.set("minirun.stats", on ? "1" : "0"); showReadout(on); };

  function connect() {
    const query = new URLSearchParams();
    if (wanted) query.set("device", wanted);
    // Tells the relay not to start a WebSocket stream for this page before it knows whether WebRTC works.
    if (wantRTC()) query.set("rtc", "1");
    const url = (location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/viewer/ws" + (String(query) ? "?" + query : "");
    ws = new WebSocket(url);
    ws.binaryType = "arraybuffer";
    setStatus("", "Connecting…");
    // WebRTC waits for the relay's status, which says whether the Mac can do it.
    ws.onopen = () => { retry = 1000; video.needKeyframe = true; requested = false; if (!wantRTC()) beginStream(false); };
    ws.onmessage = (event) => typeof event.data === "string" ? onText(event.data) : onFrame(event.data);
    ws.onclose = (event) => {
      // The relay tells the Mac to close the peer connection when this socket goes.
      closePeer();
      live = false;
      if (event.code === 1008 || event.code === 4401) { location.href = "/login"; return; }
      if (document.hidden) { setStatus("", "Paused"); return; }
      setStatus("offline", "Reconnecting…");
      setTimeout(() => { if (!document.hidden) connect(); }, retry);
      retry = Math.min(retry * 2, 15000);
    };
  }

  function send(message) { if (ws && ws.readyState === 1) ws.send(JSON.stringify(message)); }
  function sendStream() { send({ type: "stream", device: wanted, codec, ...presets[codec][$("quality").value] }); }

  // WebRTC (protocol 6). The relay passes the signaling between this page and the Mac; the Mac
  // makes the offer, with its video track and two data channels: "touch" (unordered, no
  // retransmits) for moves, and "input" (reliable) for everything else, both ways.
  // ?transport=ws keeps to the WebSocket stream.
  const RTC_TIMEOUT_MS = 8000;
  const forceWS = new URLSearchParams(location.search).get("transport") === "ws";
  const rtcSupported = typeof RTCPeerConnection === "function";
  // Whether the Mac said it can stream over WebRTC, whether a stream was asked for on this socket,
  // and whether WebRTC failed (then it's the WebSocket until the Mac reconnects).
  let macRTC = false, requested = false, rtcFailed = false;
  // The current peer connection: { pc, touch, input, timer, connected, candidates, pairRtt, last }.
  let peer = null;
  function wantRTC() { return !forceWS && rtcSupported && !rtcFailed; }

  // Asks for this page's stream: a peer connection if possible, else WebSocket frames.
  function beginStream(rtc) {
    requested = true;
    if (rtc) startPeer(); else sendStream();
  }

  function startPeer() {
    closePeer();
    peer = { pc: null, touch: null, input: null, connected: false, candidates: [], pairRtt: false, last: null };
    peer.timer = setTimeout(() => fallBack("didn't connect within " + RTC_TIMEOUT_MS / 1000 + " s"), RTC_TIMEOUT_MS);
    readout.reset();
    readout.update({ transport: "webrtc connecting" });
    send({ type: "rtc", action: "start", device: wanted, ...presets.h264[$("quality").value] });
  }

  // Closes the peer connection on this side only.
  function closePeer() {
    if (!peer) return;
    clearTimeout(peer.timer);
    if (peer.pc) { try { peer.pc.close(); } catch {} }
    peer = null;
    videoEl.srcObject = null;
    videoEl.hidden = true;
  }

  // WebRTC didn't work: tell the Mac, and use the WebSocket stream.
  function fallBack(reason) {
    if (!peer) return;
    console.log("minirun: WebRTC " + reason + "; using the WebSocket stream");
    closePeer();
    rtcFailed = true;
    live = false;
    readout.reset();
    send({ type: "rtc", action: "stop" });
    video.needKeyframe = true;
    sendStream();
  }

  async function onRTC(m) {
    if (!peer) return;
    if (m.action === "error" || m.action === "stop") { fallBack(m.action === "error" ? "failed on the Mac: " + (m.message || "") : "was stopped by the Mac"); return; }
    if (m.action === "offer") {
      if (peer.pc || typeof m.sdp !== "string") return;
      const current = peer;
      const pc = new RTCPeerConnection({ iceServers: Array.isArray(m.iceServers) ? m.iceServers : [] });
      current.pc = pc;
      pc.ontrack = (event) => {
        const receiver = event.receiver;
        // Show frames as soon as they're decoded, rather than buffer them against jitter.
        try { if ("jitterBufferTarget" in receiver) receiver.jitterBufferTarget = 0; } catch {}
        try { if ("playoutDelayHint" in receiver) receiver.playoutDelayHint = 0; } catch {}
        videoEl.srcObject = event.streams && event.streams[0] ? event.streams[0] : new MediaStream([event.track]);
        videoEl.play().catch(() => {});
      };
      pc.ondatachannel = (event) => {
        const channel = event.channel;
        if (channel.label === "touch") current.touch = channel;
        else if (channel.label === "input") {
          current.input = channel;
          channel.onmessage = (e) => { if (peer === current && typeof e.data === "string") onText(e.data, true); };
        }
      };
      pc.onicecandidate = (event) => {
        if (peer !== current) return;
        const c = event.candidate;
        send({ type: "rtc", action: "candidate", candidate: c ? c.candidate : null, sdpMid: c ? c.sdpMid : null, sdpMLineIndex: c ? c.sdpMLineIndex : null });
      };
      // connectionState is missing in some older Safari versions; the ICE state says the same.
      const changed = () => {
        if (peer !== current) return;
        const state = pc.connectionState || pc.iceConnectionState;
        if (state === "connected" || state === "completed") {
          current.connected = true;
          clearTimeout(current.timer);
        } else if (state === "failed") {
          fallBack("connection failed");
        }
      };
      pc.onconnectionstatechange = changed;
      pc.oniceconnectionstatechange = changed;
      try {
        await pc.setRemoteDescription({ type: "offer", sdp: m.sdp });
        // H.264 first, so the Mac's hardware encoder and Safari's hardware decoder are used.
        const caps = typeof RTCRtpReceiver !== "undefined" && RTCRtpReceiver.getCapabilities ? RTCRtpReceiver.getCapabilities("video") : null;
        if (caps) {
          const codecs = caps.codecs.slice().sort((a, b) => (b.mimeType === "video/H264") - (a.mimeType === "video/H264"));
          for (const t of pc.getTransceivers()) { try { if (t.setCodecPreferences) t.setCodecPreferences(codecs); } catch {} }
        }
        for (const c of current.candidates.splice(0)) await addCandidate(pc, c);
        await pc.setLocalDescription(await pc.createAnswer());
        if (peer !== current) return;
        send({ type: "rtc", action: "answer", sdp: pc.localDescription.sdp });
      } catch (error) {
        if (peer === current) fallBack("couldn't answer the offer: " + error);
      }
    } else if (m.action === "candidate") {
      // Candidates can come before the offer is set; they wait for it.
      if (!peer.pc || !peer.pc.remoteDescription) peer.candidates.push(m);
      else await addCandidate(peer.pc, m);
    }
  }
  async function addCandidate(pc, m) {
    try {
      // null (or an empty candidate in older browsers) ends the candidates.
      await pc.addIceCandidate(m.candidate ? { candidate: m.candidate, sdpMid: m.sdpMid, sdpMLineIndex: m.sdpMLineIndex } : null);
    } catch {}
  }

  // Sends on a data channel when the peer connection has it open. Returns whether it did.
  function sendInput(message) {
    if (!peer || !peer.input || peer.input.readyState !== "open") return false;
    try { peer.input.send(JSON.stringify(message)); return true; } catch { return false; }
  }
  function sendTouchMove(point) {
    if (!peer || !peer.touch || peer.touch.readyState !== "open") return false;
    try { peer.touch.send(JSON.stringify({ phase: "move", x: point.x, y: point.y })); return true; } catch { return false; }
  }

  // The readout's figures from getStats(): the candidate pair's round trip, and for the video,
  // jitter buffer delay + decode time per frame (the viewer's time), frames per second and kbps.
  async function peerStats() {
    const current = peer;
    if (!current || !current.pc) return;
    let report;
    try { report = await current.pc.getStats(); } catch { return; }
    if (peer !== current) return;
    const byId = new Map();
    report.forEach((s) => byId.set(s.id, s));
    let pair = null, inbound = null;
    report.forEach((s) => {
      if (s.type === "transport" && s.selectedCandidatePairId) pair = byId.get(s.selectedCandidatePairId) || pair;
      if (s.type === "inbound-rtp" && (s.kind || s.mediaType) === "video") inbound = s;
    });
    // Without a transport report (older Safari), the nominated pair in use.
    if (!pair) report.forEach((s) => { if (!pair && s.type === "candidate-pair" && s.nominated && s.state === "succeeded") pair = s; });
    const fields = {};
    let route = "";
    if (pair) {
      if (typeof pair.currentRoundTripTime === "number") { fields.rtt = pair.currentRoundTripTime * 1000; current.pairRtt = true; }
      // The pair's route: relay if either side is a TURN relay, else the less direct of the two.
      const rank = { host: 0, prflx: 1, srflx: 2, relay: 3 };
      const types = [byId.get(pair.localCandidateId), byId.get(pair.remoteCandidateId)].map((c) => c && c.candidateType).filter(Boolean);
      route = types.sort((a, b) => (rank[b] || 0) - (rank[a] || 0))[0] || "";
    }
    let codecName = "";
    if (inbound) {
      const codecStats = inbound.codecId ? byId.get(inbound.codecId) : null;
      if (codecStats && codecStats.mimeType) codecName = codecStats.mimeType.split("/")[1].toLowerCase();
      const now = { t: performance.now(), bytes: inbound.bytesReceived || 0, frames: inbound.framesDecoded || 0,
        jitter: inbound.jitterBufferDelay || 0, emitted: inbound.jitterBufferEmittedCount || 0, decode: inbound.totalDecodeTime || 0 };
      const last = current.last;
      if (last) {
        const seconds = Math.max(0.001, (now.t - last.t) / 1000), frames = now.frames - last.frames, emitted = now.emitted - last.emitted;
        fields.kbps = (now.bytes - last.bytes) * 8 / 1000 / seconds;
        fields.fps = typeof inbound.framesPerSecond === "number" ? inbound.framesPerSecond : frames / seconds;
        // A still screen decodes nothing; keep the last time rather than show none.
        if (frames > 0 && emitted > 0) fields.view = (now.jitter - last.jitter) / emitted * 1000 + (now.decode - last.decode) / frames * 1000;
      }
      current.last = now;
    }
    fields.transport = ["webrtc", current.connected ? route : "connecting", codecName].filter(Boolean).join(" ");
    readout.update(fields);
  }

  videoEl.addEventListener("playing", () => {
    if (!peer) return;
    showSurface(videoEl);
    if (!live) { live = true; setStatus("live", "Live"); showOverlay(""); }
  });
  videoEl.addEventListener("resize", () => {
    if (!screen && videoEl.videoWidth) screenEl.style.setProperty("--ratio", String(videoEl.videoWidth / videoEl.videoHeight));
  });

  // Mac app ids look like "mac-3f9a2c"; the Mac also says so with kind: "mac".
  function isMacId(udid) {
    const listed = simulators.find((d) => d.udid === udid);
    if (listed && listed.kind) return listed.kind === "mac";
    if (screen && screen.udid === udid && screen.kind) return screen.kind === "mac";
    return typeof udid === "string" && udid.startsWith("mac-");
  }
  // Whether this page shows a Mac app's window rather than a simulator.
  let mac = false;
  function noun() { return mac ? "app window" : "simulator"; }

  function applyMode() {
    mac = isMacId(screen && screen.udid ? screen.udid : wanted);
    document.body.classList.toggle("mac", mac);
    $("home").hidden = mac;
    $("text").placeholder = mac ? "Type into the app (or click its window and type)…" : "Type into the app…";
  }

  function renderSimulators() {
    const current = screen ? screen.udid : wanted;
    const list = simulators.slice();
    if (current && !list.some((d) => d.udid === current)) {
      list.push({ udid: current, name: screen ? screen.name : (isMacId(current) ? "Mac app" : "Simulator"), kind: isMacId(current) ? "mac" : undefined });
    }
    simEl.hidden = list.length < 2;
    deviceEl.hidden = !simEl.hidden;
    const sims = list.filter((d) => d.kind !== "mac"), apps = list.filter((d) => d.kind === "mac");
    const option = (d) => {
      const element = document.createElement("option");
      element.value = d.udid;
      element.textContent = d.name + (d.kind === "mac" && !sims.length ? " (Mac app)" : "") + (d.reserved_for ? " — " + d.reserved_for : "");
      return element;
    };
    const group = (label, devices) => {
      const element = document.createElement("optgroup");
      element.label = label;
      element.append(...devices.map(option));
      return element;
    };
    // Simulators first, then Mac apps, in groups when there are both.
    if (sims.length && apps.length) simEl.replaceChildren(group("Simulators", sims), group("Mac apps", apps));
    else simEl.replaceChildren(...list.map(option));
    if (current) simEl.value = current;
  }

  function watch(udid) {
    if (udid === wanted) return;
    wanted = udid;
    const url = new URL(location.href);
    if (udid) url.searchParams.set("device", udid); else url.searchParams.delete("device");
    history.replaceState(null, "", url);
    screen = null; live = false; pendingFrame = null; video.needKeyframe = true;
    readout.reset();
    applyMode();
    setStatus("", "Switching…"); showOverlay(mac ? "Opening the app window…" : "Switching simulator…");
    // A new peer connection for the new device; the relay closes the old one on the Mac.
    if (peer) startPeer(); else if (requested) sendStream();
  }

  // Text from the relay, or (fromPeer) from the Mac over the "input" data channel.
  function onText(text, fromPeer) {
    let m; try { m = JSON.parse(text); } catch { return; }
    // On WebRTC, the stream's status, figures and probe echoes come over the data channel; the
    // relay's are about the WebSocket stream.
    if (peer && !fromPeer && (m.type === "stream_status" || m.type === "stats" || m.type === "probe")) return;
    if (m.type === "rtc") { onRTC(m); return; }
    if (m.type === "status") {
      online = m.online;
      touchLive = m.touch === true;
      macRTC = m.webrtc === true;
      if (!online) {
        live = false; setStatus("offline", "Mac offline"); showOverlay("Your Mac is offline. Make sure it's awake and minirun is running.");
        // Its peer connections go with it. When it's back, WebRTC gets another try.
        closePeer();
        requested = false;
        rtcFailed = false;
      } else {
        setStatus("", "Starting stream…"); if (!live) showOverlay("Waiting for the " + noun() + "…");
        if (!requested) beginStream(macRTC && wantRTC());
        // The Mac reconnected (a new connection replaces the old without an offline status in
        // between) and may have restarted, so its peer connections may be gone: start again.
        else if ((peer || rtcFailed) && macRTC && !forceWS && rtcSupported) { rtcFailed = false; beginStream(true); }
        else if (peer) { closePeer(); sendStream(); }
      }
      if (m.host && m.host.name && !screen) deviceEl.textContent = m.host.name;
    } else if (m.type === "simulators") {
      simulators = Array.isArray(m.devices) ? m.devices : [];
      applyMode();
      renderSimulators();
      // Only Mac apps and no simulator booted: open the first app rather than wait for a simulator.
      if (!wanted && simulators.length && simulators.every((d) => d.kind === "mac")) watch(simulators[0].udid);
    } else if (m.type === "screen") {
      if ((m.key || "") !== wanted) return;
      // A Mac app's window can be resized mid-stream: the Mac re-sends this with the new size,
      // and taps are mapped with the latest one.
      screen = m;
      applyMode();
      deviceEl.textContent = m.name;
      screenEl.style.setProperty("--ratio", String(m.pointWidth / m.pointHeight));
      renderSimulators();
    } else if (m.type === "stream_status") {
      if ((m.key || "") !== wanted) return;
      if (m.status === "live") { live = true; setStatus("live", "Live"); showOverlay(""); }
      else if (m.status === "error") { setStatus("offline", "Stream error"); showOverlay(m.message || "The " + noun() + " stream failed."); }
    } else if (m.type === "stats") macStats(m);
    else if (m.type === "probe") probeAnswered(m);
  }

  function onFrame(buffer) {
    const bytes = new Uint8Array(buffer);
    if (bytes.length < 6) return;
    // Kind 1: [1][seq][jpeg]. Kind 2: [2][seq][keyLength][key][jpeg], key = UDID or "".
    // Kind 3: [3][seq][keyLength][key][flags][H.264 Annex B], flags bit 0 = keyframe.
    let key = "", start = 5;
    if (bytes[0] === 2 || bytes[0] === 3) {
      start = 6 + bytes[5];
      key = new TextDecoder().decode(bytes.subarray(6, start));
    } else if (bytes[0] !== 1) return;
    if (key !== wanted) return; // a frame from before we switched simulators
    if (peer) return; // from before this page switched to WebRTC
    const seq = new DataView(buffer).getUint32(1);
    frameReceived(seq, bytes.length);
    if (bytes[0] === 3) { onVideo(seq, (bytes[start] & 1) === 1, bytes.subarray(start + 1)); return; }
    pendingFrame = { seq, blob: new Blob([bytes.subarray(start)], { type: "image/jpeg" }) };
    if (!decoding) showNext();
  }

  function showSurface(element) {
    img.hidden = element !== img;
    canvas.hidden = element !== canvas;
    videoEl.hidden = element !== videoEl;
  }

  // The WebCodecs codec string ("avc1.PPCCLL") from the SPS NAL unit in an Annex B keyframe.
  function avcCodec(bytes) {
    for (let i = 0; i + 6 < bytes.length; i++) {
      if (bytes[i] === 0 && bytes[i + 1] === 0 && bytes[i + 2] === 1 && (bytes[i + 3] & 0x1f) === 7) {
        return "avc1." + [bytes[i + 4], bytes[i + 5], bytes[i + 6]].map((b) => b.toString(16).padStart(2, "0")).join("").toUpperCase();
      }
    }
    return null;
  }

  function onVideo(seq, keyframe, data) {
    if (codec !== "h264") { send({ type: "ack", seq }); return; } // until the Mac switches this stream to JPEG
    if (keyframe) {
      const avc = avcCodec(data) || "avc1.4D401F";
      if (!video.decoder || video.decoder.state === "closed" || avc !== video.codec) startDecoder(avc);
      video.needKeyframe = false;
    }
    // Until a keyframe arrives there's nothing to decode against.
    if (video.needKeyframe || !video.decoder || video.decoder.state !== "configured") { send({ type: "ack", seq }); return; }
    try {
      // Without a codec description, WebCodecs reads H.264 as Annex B. The timestamp carries seq to the output.
      video.decoder.decode(new EncodedVideoChunk({ type: keyframe ? "key" : "delta", timestamp: seq, data }));
    } catch {
      videoFailed();
      send({ type: "ack", seq });
    }
  }

  function startDecoder(avc) {
    if (video.decoder && video.decoder.state !== "closed") video.decoder.close();
    video.codec = avc;
    video.decoder = new VideoDecoder({ output: drawFrame, error: videoFailed });
    video.decoder.configure({ codec: avc, optimizeForLatency: true });
  }

  function videoFailed() {
    video.needKeyframe = true;
    if (video.decoder && video.decoder.state !== "closed") video.decoder.close();
    video.decoder = null;
    if (++video.errors >= 3) { codec = "jpeg"; sendStream(); return; } // this browser can't keep up; use JPEG
    send({ type: "keyframe" });
  }

  function drawFrame(frame) {
    const seq = frame.timestamp;
    if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
      canvas.width = frame.displayWidth;
      canvas.height = frame.displayHeight;
    }
    canvas.getContext("2d").drawImage(frame, 0, 0, canvas.width, canvas.height);
    frame.close();
    frameDrawn(seq);
    video.errors = 0;
    showSurface(canvas);
    if (!live) { live = true; setStatus("live", "Live"); showOverlay(""); }
    if (!screen) screenEl.style.setProperty("--ratio", String(canvas.width / canvas.height));
    send({ type: "ack", seq });
  }

  async function detectH264() {
    if (new URLSearchParams(location.search).get("codec") === "jpeg") return false;
    if (typeof VideoDecoder !== "function" || typeof EncodedVideoChunk !== "function") return false;
    try {
      return (await VideoDecoder.isConfigSupported({ codec: "avc1.4D401F", optimizeForLatency: true })).supported === true;
    } catch {
      return false;
    }
  }

  function showNext() {
    if (!pendingFrame) { decoding = false; return; }
    decoding = true;
    const { seq, blob } = pendingFrame;
    pendingFrame = null;
    const url = URL.createObjectURL(blob);
    img.onload = () => {
      if (currentURL) URL.revokeObjectURL(currentURL);
      currentURL = url;
      frameDrawn(seq);
      showSurface(img);
      if (!live) { live = true; setStatus("live", "Live"); showOverlay(""); }
      if (!screen) screenEl.style.setProperty("--ratio", String(img.naturalWidth / img.naturalHeight));
      send({ type: "ack", seq });
      showNext();
    };
    img.onerror = () => { URL.revokeObjectURL(url); send({ type: "ack", seq }); showNext(); };
    img.src = url;
  }

  // Touch → tap / long press / swipe, in simulator (or Mac window) points, from the latest screen message.
  function geometry() {
    const surface = !videoEl.hidden ? videoEl : canvas.hidden ? img : canvas;
    const rect = surface.getBoundingClientRect();
    const naturalWidth = surface === videoEl ? videoEl.videoWidth : surface === canvas ? canvas.width : img.naturalWidth;
    const naturalHeight = surface === videoEl ? videoEl.videoHeight : surface === canvas ? canvas.height : img.naturalHeight;
    const w = screen ? screen.pointWidth : naturalWidth / (mac ? 1 : 3), h = screen ? screen.pointHeight : naturalHeight / (mac ? 1 : 3);
    // object-fit: contain — account for letterboxing.
    const scale = Math.min(rect.width / w, rect.height / h);
    return { rect, w, h, scale, offsetX: (rect.width - w * scale) / 2, offsetY: (rect.height - h * scale) / 2 };
  }
  function toPoints(clientX, clientY) {
    const { rect, w, h, scale, offsetX, offsetY } = geometry();
    const x = (clientX - rect.left - offsetX) / scale, y = (clientY - rect.top - offsetY) / scale;
    return { x: Math.round(Math.max(0, Math.min(w, x)) * 10) / 10, y: Math.round(Math.max(0, Math.min(h, y)) * 10) / 10 };
  }
  function ripple(clientX, clientY) {
    const rect = screenEl.getBoundingClientRect();
    const dot = document.createElement("div");
    dot.className = "touch";
    dot.style.left = clientX - rect.left + "px";
    dot.style.top = clientY - rect.top + "px";
    screenEl.appendChild(dot);
    setTimeout(() => dot.remove(), 500);
  }
  // Characters typed on a Mac app's window, sent together as one type_text. Anything else sent
  // goes after them, so keys and clicks keep their order.
  let typed = "", typedTimer = null;
  function flushText() {
    clearTimeout(typedTimer);
    typedTimer = null;
    const text = typed;
    typed = "";
    if (text) input("type_text", { text });
  }
  function input(tool, args) {
    if (typed) flushText();
    const message = { type: "input", tool, arguments: args };
    if (online && !sendInput(message)) send(message);
  }

  // Live touches: down, moves (at most one per animation frame) and up are sent as they happen,
  // so drags and long presses track the finger. Without them, the gesture is sent on finger-up.
  // On a Mac app they're the mouse: the Mac turns them into mouse down, drag and up.
  let start = null, moved = null, moveQueued = false;
  // The last plain mouse click on a Mac app, so a second one soon after becomes a double click.
  let lastClick = null, lastPointerType = "";
  // On WebRTC, moves go on the "touch" channel (a lost one is soon replaced by the next) and
  // down and up on "input", so they always arrive.
  function touch(phase, point) {
    if (typed) flushText();
    if (!online) return;
    const message = { type: "touch", phase, x: point.x, y: point.y };
    if (phase === "move" ? sendTouchMove(point) : sendInput(message)) return;
    send(message);
  }
  function flushMove() {
    moveQueued = false;
    if (start && start.live && moved) { touch("move", moved); moved = null; }
  }
  screenEl.addEventListener("pointerdown", (e) => {
    lastPointerType = e.pointerType;
    if (!live) return;
    const mouse = mac && e.pointerType === "mouse";
    // Right clicks (and control-clicks on a Mac browser) arrive as contextmenu.
    if (mouse && (e.button !== 0 || (e.ctrlKey && /Mac/.test(navigator.platform)))) return;
    if (mac) { screenEl.focus({ preventScroll: true }); screenEl.classList.add("focused"); }
    screenEl.setPointerCapture(e.pointerId);
    const now = performance.now();
    // The second click of a double click isn't sent live: it goes as tap {count: 2} on mouse up.
    const double = mouse && lastClick !== null && now - lastClick.t < 400 && Math.hypot(e.clientX - lastClick.x, e.clientY - lastClick.y) < 6;
    start = { x: e.clientX, y: e.clientY, t: now, id: e.pointerId, live: touchLive && !double, mouse, double };
    lastClick = null;
    moved = null;
    e.preventDefault();
    if (start.live) {
      ripple(e.clientX, e.clientY);
      touch("down", toPoints(e.clientX, e.clientY));
    }
  });
  screenEl.addEventListener("pointermove", (e) => {
    if (!start || !start.live || e.pointerId !== start.id) return;
    moved = toPoints(e.clientX, e.clientY);
    if (!moveQueued) { moveQueued = true; requestAnimationFrame(flushMove); }
  });
  screenEl.addEventListener("pointerup", (e) => {
    if (!start || e.pointerId !== start.id) return;
    const dt = performance.now() - start.t, distance = Math.hypot(e.clientX - start.x, e.clientY - start.y);
    if (start.live) {
      moved = null;
      touch("up", toPoints(e.clientX, e.clientY));
      if (start.mouse && distance < 6 && dt < 500) lastClick = { t: performance.now(), x: e.clientX, y: e.clientY };
      start = null;
      return;
    }
    const from = toPoints(start.x, start.y);
    ripple(start.x, start.y);
    if (distance < 10) {
      if (start.double) input("tap", { ...from, count: 2 });
      else if (dt > 500) input("long_press", { ...from, duration: Math.min(dt / 1000, 5) });
      else input("tap", from);
    } else {
      const to = toPoints(e.clientX, e.clientY);
      input("swipe", { from_x: from.x, from_y: from.y, to_x: to.x, to_y: to.y, duration: Math.max(0.1, Math.min(dt / 1000, 1.5)) });
    }
    start = null;
  });
  screenEl.addEventListener("pointercancel", (e) => {
    if (start && start.live && e.pointerId === start.id) touch("up", toPoints(e.clientX, e.clientY));
    start = null; moved = null;
  });

  // Mac apps: right click, wheel and trackpad scrolling, and keys.
  screenEl.addEventListener("contextmenu", (e) => {
    if (!mac) return;
    e.preventDefault();
    // A long press on a touch screen also fires contextmenu; that one is already a touch.
    if (!live || lastPointerType === "touch" || lastPointerType === "pen") return;
    ripple(e.clientX, e.clientY);
    input("tap", { ...toPoints(e.clientX, e.clientY), button: "right" });
  });

  // Wheel deltas add up and go as one scroll at most every 33 ms, in window points (positive dy
  // scrolls down, as in the browser), at the pointer.
  let wheel = null, wheelTimer = null, wheelSent = 0;
  function flushWheel() {
    wheelTimer = null;
    if (!wheel) return;
    const { x, y } = wheel, dx = Math.round(wheel.dx * 10) / 10, dy = Math.round(wheel.dy * 10) / 10;
    wheel = null;
    wheelSent = performance.now();
    if (dx || dy) input("scroll", { x, y, dx, dy });
  }
  screenEl.addEventListener("wheel", (e) => {
    if (!mac) return;
    e.preventDefault();
    // Control + wheel is a trackpad pinch, not a scroll.
    if (!live || e.ctrlKey) return;
    const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? screenEl.clientHeight : 1;
    const perPoint = geometry().scale || 1;
    const at = toPoints(e.clientX, e.clientY);
    wheel = { x: at.x, y: at.y, dx: (wheel ? wheel.dx : 0) + e.deltaX * unit / perPoint, dy: (wheel ? wheel.dy : 0) + e.deltaY * unit / perPoint };
    if (!wheelTimer) wheelTimer = setTimeout(flushWheel, Math.max(0, 33 - (performance.now() - wheelSent)));
  }, { passive: false });

  // Keys typed while the page (not a text field) has focus go to a Mac app: printable characters
  // as type_text, everything else, and anything with command, control or option, as press_key.
  const keyNames = {
    Enter: "return", Backspace: "delete", Delete: "forwarddelete", Tab: "tab", Escape: "escape", " ": "space",
    ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right", Home: "home", End: "end", PageUp: "pageup", PageDown: "pagedown",
  };
  const codeNames = { Minus: "-", Equal: "=", BracketLeft: "[", BracketRight: "]", Backslash: "\\\\", Semicolon: ";", Quote: "'", Comma: ",", Period: ".", Slash: "/", Backquote: "\`" };
  function keyName(e) {
    if (keyNames[e.key]) return keyNames[e.key];
    if (/^F([1-9]|1[0-2])$/.test(e.key)) return e.key.toLowerCase();
    // With option or shift held, e.key is the character it makes ("å", "A"); the key itself is what's pressed (US layout).
    if (e.code.startsWith("Key") && e.code.length === 4) return e.code.slice(3).toLowerCase();
    if (e.code.startsWith("Digit") && e.code.length === 6) return e.code.slice(5);
    if (codeNames[e.code]) return codeNames[e.code];
    return e.key.length === 1 ? e.key.toLowerCase() : null;
  }
  document.addEventListener("keydown", (e) => {
    if (!mac || !live || e.isComposing) return;
    if (e.target instanceof Element && e.target.closest("input, textarea, select")) return;
    const altGraph = e.getModifierState && e.getModifierState("AltGraph");
    if (e.key.length === 1 && (altGraph || (!e.metaKey && !e.ctrlKey && !e.altKey))) {
      typed += e.key;
      if (!typedTimer) typedTimer = setTimeout(flushText, 60);
    } else {
      const key = keyName(e);
      if (!key) return; // a modifier on its own, or a key the Mac doesn't know
      const modifiers = [];
      if (e.metaKey) modifiers.push("command");
      if (e.ctrlKey) modifiers.push("control");
      if (e.altKey) modifiers.push("option");
      if (e.shiftKey) modifiers.push("shift");
      input("press_key", modifiers.length ? { key, modifiers } : { key });
    }
    e.preventDefault();
  });
  screenEl.addEventListener("blur", () => screenEl.classList.remove("focused"));

  $("home").onclick = () => input("press_button", { button: "home" });
  $("enter").onclick = () => input("press_key", { key: "return" });
  $("backspace").onclick = () => input("press_key", { key: "delete" });
  $("typing").onsubmit = (e) => {
    e.preventDefault();
    const field = $("text");
    if (field.value) input("type_text", { text: field.value });
    field.value = "";
  };
  $("quality").onchange = () => {
    store.set("minirun.quality", $("quality").value);
    if (peer) startPeer(); else if (requested) sendStream();
  };
  simEl.onchange = () => watch(simEl.value);
  document.addEventListener("visibilitychange", () => {
    // Stop streaming in background tabs to save the Mac and your data plan.
    if (document.hidden && ws) ws.close(1000);
    else if (!document.hidden && (!ws || ws.readyState > 1)) connect();
  });

  showReadout(store.get("minirun.stats") === "1");
  detectH264().then((supported) => { codec = supported ? "h264" : "jpeg"; connect(); });
})();
</script>
</body>
</html>`;
}
