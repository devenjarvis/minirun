import { baseStyles } from "./pages";

/**
 * The live viewer: streams the simulator screen and turns touches into taps and swipes.
 * Browsers with WebCodecs get H.264 (decoded onto a canvas); others get JPEG frames.
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
.screen img, .screen canvas { width: 100%; height: 100%; display: block; object-fit: contain; pointer-events: none; -webkit-user-drag: none; }
.screen img[hidden], .screen canvas[hidden] { display: none; }
.overlay { position: absolute; inset: 0; display: grid; place-items: center; text-align: center; padding: 24px; color: var(--muted); font-size: 14px; background: rgba(0,0,0,.55); }
.overlay[hidden] { display: none; }
.touch { position: absolute; width: 36px; height: 36px; margin: -18px 0 0 -18px; border-radius: 50%; background: rgba(124,196,255,.35); border: 2px solid rgba(124,196,255,.9);
  pointer-events: none; animation: touch .45s ease-out forwards; }
@keyframes touch { to { transform: scale(1.8); opacity: 0; } }
footer { display: flex; gap: 8px; align-items: center; padding: 10px 14px calc(env(safe-area-inset-bottom) + 10px); border-top: 1px solid var(--line); }
footer button { flex: 0 0 auto; padding: 10px 12px; font-size: 14px; }
footer form { flex: 1; display: flex; gap: 8px; min-width: 0; }
footer input { flex: 1; min-width: 0; padding: 10px 12px; border-radius: 10px; border: 1px solid var(--line); background: #0f1115; color: var(--text); font-size: 16px; }
select { padding: 10px 8px; border-radius: 10px; border: 1px solid var(--line); background: #1d2027; color: var(--text); font-size: 14px; }
</style>
</head>
<body>
<header>
  <div class="mark"><i></i>minirun</div>
  <span id="status" class="pill"><i></i><span>Connecting…</span></span>
  <span id="device" class="device"></span>
  <select id="sim" class="sim" title="Simulator" hidden></select>
</header>
<main>
  <div id="screen" class="screen">
    <img id="frame" alt="Simulator screen">
    <canvas id="video" hidden></canvas>
    <div id="overlay" class="overlay">Connecting…</div>
  </div>
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
  const screenEl = $("screen"), img = $("frame"), canvas = $("video"), overlay = $("overlay"), statusEl = $("status"), deviceEl = $("device"), simEl = $("sim");
  let ws = null, retry = 1000, online = false, live = false;
  // Whether the Mac takes live touches; older ones get whole gestures on finger-up instead.
  let touchLive = false;
  let screen = null; // { udid, pointWidth, pointHeight, name }
  let simulators = [];
  // The simulator this page shows: ?device=UDID, or "" for whichever one is booted.
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

  function connect() {
    const url = (location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/viewer/ws" + (wanted ? "?device=" + encodeURIComponent(wanted) : "");
    ws = new WebSocket(url);
    ws.binaryType = "arraybuffer";
    setStatus("", "Connecting…");
    ws.onopen = () => { retry = 1000; video.needKeyframe = true; sendStream(); };
    ws.onmessage = (event) => typeof event.data === "string" ? onText(event.data) : onFrame(event.data);
    ws.onclose = (event) => {
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

  function renderSimulators() {
    const current = screen ? screen.udid : wanted;
    const list = simulators.slice();
    if (current && !list.some((d) => d.udid === current)) list.push({ udid: current, name: screen ? screen.name : "Simulator" });
    simEl.hidden = list.length < 2;
    deviceEl.hidden = !simEl.hidden;
    simEl.replaceChildren(...list.map((d) => {
      const option = document.createElement("option");
      option.value = d.udid;
      option.textContent = d.name + (d.reserved_for ? " — " + d.reserved_for : "");
      return option;
    }));
    if (current) simEl.value = current;
  }

  function watch(udid) {
    if (udid === wanted) return;
    wanted = udid;
    const url = new URL(location.href);
    if (udid) url.searchParams.set("device", udid); else url.searchParams.delete("device");
    history.replaceState(null, "", url);
    screen = null; live = false; pendingFrame = null; video.needKeyframe = true;
    setStatus("", "Switching…"); showOverlay("Switching simulator…");
    sendStream();
  }

  function onText(text) {
    let m; try { m = JSON.parse(text); } catch { return; }
    if (m.type === "status") {
      online = m.online;
      touchLive = m.touch === true;
      if (!online) { live = false; setStatus("offline", "Mac offline"); showOverlay("Your Mac is offline. Make sure it's awake and minirun is running."); }
      else { setStatus("", "Starting stream…"); if (!live) showOverlay("Waiting for the simulator…"); }
      if (m.host && m.host.name && !screen) deviceEl.textContent = m.host.name;
    } else if (m.type === "simulators") {
      simulators = Array.isArray(m.devices) ? m.devices : [];
      renderSimulators();
    } else if (m.type === "screen") {
      if ((m.key || "") !== wanted) return;
      screen = m;
      deviceEl.textContent = m.name;
      screenEl.style.setProperty("--ratio", String(m.pointWidth / m.pointHeight));
      renderSimulators();
    } else if (m.type === "stream_status") {
      if ((m.key || "") !== wanted) return;
      if (m.status === "live") { live = true; setStatus("live", "Live"); showOverlay(""); }
      else if (m.status === "error") { setStatus("offline", "Stream error"); showOverlay(m.message || "The simulator stream failed."); }
    }
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
    const seq = new DataView(buffer).getUint32(1);
    if (bytes[0] === 3) { onVideo(seq, (bytes[start] & 1) === 1, bytes.subarray(start + 1)); return; }
    pendingFrame = { seq, blob: new Blob([bytes.subarray(start)], { type: "image/jpeg" }) };
    if (!decoding) showNext();
  }

  function showSurface(element) {
    img.hidden = element !== img;
    canvas.hidden = element !== canvas;
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
      showSurface(img);
      if (!live) { live = true; setStatus("live", "Live"); showOverlay(""); }
      if (!screen) screenEl.style.setProperty("--ratio", String(img.naturalWidth / img.naturalHeight));
      send({ type: "ack", seq });
      showNext();
    };
    img.onerror = () => { URL.revokeObjectURL(url); send({ type: "ack", seq }); showNext(); };
    img.src = url;
  }

  // Touch → tap / long press / swipe, in simulator points.
  function toPoints(clientX, clientY) {
    const surface = canvas.hidden ? img : canvas;
    const rect = surface.getBoundingClientRect();
    const naturalWidth = canvas.hidden ? img.naturalWidth : canvas.width, naturalHeight = canvas.hidden ? img.naturalHeight : canvas.height;
    const w = screen ? screen.pointWidth : naturalWidth / 3, h = screen ? screen.pointHeight : naturalHeight / 3;
    // object-fit: contain — account for letterboxing.
    const scale = Math.min(rect.width / w, rect.height / h);
    const offsetX = (rect.width - w * scale) / 2, offsetY = (rect.height - h * scale) / 2;
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
  function input(tool, args) { if (online) send({ type: "input", tool, arguments: args }); }

  // Live touches: down, moves (at most one per animation frame) and up are sent as they happen,
  // so drags and long presses track the finger. Without them, the gesture is sent on finger-up.
  let start = null, moved = null, moveQueued = false;
  function touch(phase, point) { if (online) send({ type: "touch", phase, x: point.x, y: point.y }); }
  function flushMove() {
    moveQueued = false;
    if (start && start.live && moved) { touch("move", moved); moved = null; }
  }
  screenEl.addEventListener("pointerdown", (e) => {
    if (!live) return;
    screenEl.setPointerCapture(e.pointerId);
    start = { x: e.clientX, y: e.clientY, t: performance.now(), id: e.pointerId, live: touchLive };
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
    if (start.live) {
      moved = null;
      touch("up", toPoints(e.clientX, e.clientY));
      start = null;
      return;
    }
    const dt = performance.now() - start.t, distance = Math.hypot(e.clientX - start.x, e.clientY - start.y);
    const from = toPoints(start.x, start.y);
    ripple(start.x, start.y);
    if (distance < 10) {
      if (dt > 500) input("long_press", { ...from, duration: Math.min(dt / 1000, 5) });
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

  $("home").onclick = () => input("press_button", { button: "home" });
  $("enter").onclick = () => input("press_key", { key: "return" });
  $("backspace").onclick = () => input("press_key", { key: "delete" });
  $("typing").onsubmit = (e) => {
    e.preventDefault();
    const field = $("text");
    if (field.value) input("type_text", { text: field.value });
    field.value = "";
  };
  $("quality").onchange = () => { store.set("minirun.quality", $("quality").value); sendStream(); };
  simEl.onchange = () => watch(simEl.value);
  document.addEventListener("visibilitychange", () => {
    // Stop streaming in background tabs to save the Mac and your data plan.
    if (document.hidden && ws) ws.close(1000);
    else if (!document.hidden && (!ws || ws.readyState > 1)) connect();
  });

  detectH264().then((supported) => { codec = supported ? "h264" : "jpeg"; connect(); });
})();
</script>
</body>
</html>`;
}
