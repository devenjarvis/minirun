// End-to-end check of the WebRTC live view (protocol 6) with no Mac: runs the Worker locally with
// `wrangler dev`, and drives two Chromium pages through it. One plays the Mac: it connects to
// /agent, says hello with webrtc: true and answers `rtc start` with an offer carrying a
// canvas.captureStream() video track and the "touch" and "input" data channels. The other logs in
// and opens the viewer. Also checks the fallback to the WebSocket stream when the Mac refuses
// (rtc error) or when ICE can't connect, and that ?transport=ws skips WebRTC.
//   npm run e2e:webrtc            (needs Playwright with its Chromium installed)
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const { chromium } = createRequire(import.meta.url)("playwright");
const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const port = Number(process.env.PORT || 8799);
const base = `http://127.0.0.1:${port}`;
const password = "e2e-password", agentToken = "e2e-agent-token", device = "SIM-E2E";

const step = (s) => console.log("•", s);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(what, check, timeout = 15000) {
  const end = Date.now() + timeout;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(100);
  }
}

// The Worker, with its own empty storage.
const state = mkdtempSync(join(tmpdir(), "minirun-e2e-webrtc-"));
const wrangler = spawn("npx", ["wrangler", "dev", "--port", String(port), "--ip", "127.0.0.1", "--persist-to", state,
  "--var", `OWNER_PASSWORD:${password}`, "--var", `AGENT_TOKEN:${agentToken}`], {
  cwd: root, env: { ...process.env, WRANGLER_SEND_METRICS: "false" }, stdio: ["ignore", "pipe", "pipe"], detached: true,
});
let wranglerLog = "";
wrangler.stdout.on("data", (d) => { wranglerLog += d; });
wrangler.stderr.on("data", (d) => { wranglerLog += d; });

let browser = null;
async function finish(code) {
  if (browser) await browser.close().catch(() => {});
  try { process.kill(-wrangler.pid, "SIGTERM"); } catch {}
  rmSync(state, { recursive: true, force: true });
  process.exit(code);
}

/** Runs in the Mac page. Plays a Mac with protocol 6: `window.mac.mode` picks how it answers. */
function fakeMac({ token, device }) {
  const mac = { mode: "ok", log: [], peers: new Map(), streams: [] };
  window.mac = mac;
  const log = (entry) => mac.log.push({ at: performance.now(), ...entry });

  // A moving picture, so the encoder has frames to send.
  const canvas = document.createElement("canvas");
  canvas.width = 390; canvas.height = 844;
  const g = canvas.getContext("2d");
  let tick = 0;
  setInterval(() => {
    tick++;
    g.fillStyle = `hsl(${tick * 7 % 360} 60% 40%)`;
    g.fillRect(0, 0, canvas.width, canvas.height);
    g.fillStyle = "#fff";
    g.font = "48px sans-serif";
    g.fillText(String(tick), 40, 120);
  }, 50);
  const stream = canvas.captureStream(20);
  const screen = { type: "screen", key: device, udid: device, name: "E2E iPhone", pointWidth: 390, pointHeight: 844 };

  // The Worker takes the agent token from the Authorization header, which this page's context adds.
  const ws = new WebSocket(location.origin.replace(/^http/, "ws") + "/agent");
  ws.binaryType = "arraybuffer";
  const send = (m) => ws.send(JSON.stringify(m));
  ws.onopen = () => {
    log({ kind: "open" });
    send({ type: "hello", version: 6, host: { name: "E2E Mac" }, tools: [], instance: "e2e", webrtc: true });
    send({ type: "simulators", devices: [{ udid: device, name: "E2E iPhone" }] });
  };
  ws.onclose = (e) => log({ kind: "closed", code: e.code });

  // The WebSocket stream: JPEG frames (kind 2) while someone watches over it.
  let seq = 0;
  setInterval(() => {
    if (!mac.streams.some((s) => s.udid === device)) return;
    canvas.toBlob(async (blob) => {
      const jpeg = new Uint8Array(await blob.arrayBuffer());
      const key = new TextEncoder().encode(device);
      const frame = new Uint8Array(6 + key.length + jpeg.length);
      frame[0] = 2;
      new DataView(frame.buffer).setUint32(1, ++seq);
      frame[5] = key.length;
      frame.set(key, 6);
      frame.set(jpeg, 6 + key.length);
      if (ws.readyState === 1) ws.send(frame);
    }, "image/jpeg", 0.6);
  }, 200);

  ws.onmessage = async (event) => {
    if (typeof event.data !== "string") return;
    const m = JSON.parse(event.data);
    if (m.type === "stream") {
      mac.streams = m.action === "set" ? m.streams : [];
      log({ kind: "stream", action: m.action, streams: m.streams });
      if (m.action === "set") { send(screen); send({ type: "stream_status", key: device, status: "live" }); }
      return;
    }
    if (m.type !== "rtc") return;
    log({ kind: "rtc", action: m.action, viewer: m.viewer, message: m });
    const viewer = m.viewer;
    if (m.action === "start") {
      if (mac.mode === "refuse") { send({ type: "rtc", action: "error", viewer, message: "refused by the test" }); return; }
      mac.peers.get(viewer)?.pc.close();
      // "noice": no candidates either way, so ICE never connects.
      const quiet = mac.mode === "noice";
      const pc = new RTCPeerConnection({ iceServers: [] });
      const peer = { pc, quiet, touches: [], inputs: [] };
      mac.peers.set(viewer, peer);
      pc.addTransceiver(stream.getVideoTracks()[0], { direction: "sendonly", streams: [stream] });
      const touch = pc.createDataChannel("touch", { ordered: false, maxRetransmits: 0 });
      const input = pc.createDataChannel("input");
      touch.onmessage = (e) => { const t = JSON.parse(e.data); peer.touches.push(t); log({ kind: "touch-channel", viewer, data: t }); };
      input.onopen = () => {
        input.send(JSON.stringify(screen));
        input.send(JSON.stringify({ type: "stream_status", key: device, status: "live" }));
        input.send(JSON.stringify({ type: "stats", key: device, codec: "h264", fps: 20, pipelineMs: 4.2, pipelineP95Ms: 6.1 }));
      };
      input.onmessage = (e) => {
        const d = JSON.parse(e.data);
        peer.inputs.push(d);
        log({ kind: "input-channel", viewer, data: d });
        if (d.type === "probe") input.send(JSON.stringify({ type: "probe", t: d.t }));
      };
      pc.onicecandidate = (e) => {
        if (quiet) return;
        const c = e.candidate;
        send({ type: "rtc", action: "candidate", viewer, candidate: c ? c.candidate : null, sdpMid: c ? c.sdpMid : null, sdpMLineIndex: c ? c.sdpMLineIndex : null });
      };
      pc.onconnectionstatechange = () => log({ kind: "state", viewer, state: pc.connectionState });
      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      // The offer as created, before any candidates were gathered: they trickle.
      send({ type: "rtc", action: "offer", viewer, sdp: offer.sdp });
    } else if (m.action === "answer") {
      await mac.peers.get(viewer)?.pc.setRemoteDescription({ type: "answer", sdp: m.sdp });
    } else if (m.action === "candidate") {
      const peer = mac.peers.get(viewer);
      if (!peer || peer.quiet) return;
      try { await peer.pc.addIceCandidate(m.candidate ? { candidate: m.candidate, sdpMid: m.sdpMid, sdpMLineIndex: m.sdpMLineIndex } : null); } catch {}
    } else if (m.action === "stop") {
      mac.peers.get(viewer)?.pc.close();
      mac.peers.delete(viewer);
    }
  };
  return token;
}

try {
  step("wrangler dev");
  await until("wrangler dev", async () => {
    if (wrangler.exitCode !== null) throw new Error("wrangler exited");
    try { return (await fetch(`${base}/login`)).ok; } catch { return false; }
  }, 90000);

  browser = await chromium.launch({
    // Host candidates as plain addresses: the two pages can't resolve each other's mDNS names here.
    args: ["--disable-features=WebRtcHideLocalIpsWithMdns", "--autoplay-policy=no-user-gesture-required"],
  });

  step("the Mac page connects to /agent with protocol 6 and webrtc: true");
  const macContext = await browser.newContext({ extraHTTPHeaders: { Authorization: `Bearer ${agentToken}` } });
  const macPage = await macContext.newPage();
  macPage.on("pageerror", (e) => console.log("  [mac page error]", e.message));
  await macPage.goto(`${base}/login`);
  await macPage.evaluate(fakeMac, { token: agentToken, device });
  await until("the Mac's socket", () => macPage.evaluate(() => window.mac.log.some((e) => e.kind === "open")));
  await sleep(300); // for the hello to be stored

  const viewerContext = await browser.newContext();
  const login = await viewerContext.newPage();
  await login.goto(`${base}/login`);
  await login.fill("input[name=password]", password);
  await Promise.all([login.waitForURL(`${base}/`), login.press("input[name=password]", "Enter")]);
  await login.close();

  const macLog = () => macPage.evaluate(() => window.mac.log.map(({ kind, action, viewer, streams, data, state, message }) =>
    ({ kind, action, viewer, streams, data, state, iceServers: message?.iceServers, fps: message?.fps, key: message?.key })));
  async function openViewer(query) {
    const page = await viewerContext.newPage();
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    page.on("console", (m) => { if (m.text().startsWith("minirun:")) console.log("  [viewer]", m.text()); });
    await page.goto(`${base}/?device=${device}&stats=1${query ? "&" + query : ""}`);
    return { page, errors, readout: () => page.locator("#readout").textContent() };
  }
  const visible = (page, id) => page.evaluate((id) => !document.getElementById(id).hidden, id);

  // 1. WebRTC end to end.
  step("viewer: rtc start → offer → answer → connected, video plays");
  const before = (await macLog()).length;
  const v1 = await openViewer("");
  const start = await until("rtc start on the Mac", async () => (await macLog()).slice(before).find((e) => e.kind === "rtc" && e.action === "start"));
  if (start.key !== device) throw new Error(`rtc start key ${start.key}`);
  if (!start.iceServers?.some((s) => [].concat(s.urls).includes("stun:stun.cloudflare.com:3478"))) throw new Error("no STUN server in rtc start");
  console.log(`  viewer ${start.viewer.slice(0, 8)}…, ${start.iceServers.length} ICE server(s), fps ${start.fps}`);
  await until("the video to play", () => v1.page.evaluate(() => {
    const v = document.getElementById("rtcVideo");
    return !v.hidden && v.readyState >= 2 && v.videoWidth > 0 && !v.paused;
  }), 15000);
  const t1 = await v1.page.evaluate(() => document.getElementById("rtcVideo").currentTime);
  await sleep(1000);
  const t2 = await v1.page.evaluate(() => document.getElementById("rtcVideo").currentTime);
  if (!(t2 > t1)) throw new Error("the video isn't advancing");
  if (await visible(v1.page, "frame") || await visible(v1.page, "video")) throw new Error("the WebSocket surfaces should be hidden");
  const wsStreams = (await macLog()).slice(before).filter((e) => e.kind === "stream" && e.action === "set" && e.streams.some((s) => s.udid === device));
  console.log(`  video ${await v1.page.evaluate(() => { const v = document.getElementById("rtcVideo"); return v.videoWidth + "x" + v.videoHeight; })}, playing`);

  step("the readout shows webrtc, the candidate type and the RTT");
  const text = await until("a webrtc readout with a route", async () => {
    const t = await v1.readout();
    return /webrtc (host|srflx|prflx|relay)/.test(t) && /\d+ fps/.test(t) && /RTT\s+\d+ ms/.test(t) && /Viewer\s+\d+ ms/.test(t) ? t : null;
  }, 10000);
  console.log("  " + text.split("\n").join("\n  "));
  if (!/Mac\s+4 ms/.test(text)) throw new Error("the Mac's stats from the data channel aren't shown");

  step("a touch reaches the Mac over the data channels");
  const box = await v1.page.locator("#screen").boundingBox();
  await v1.page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await v1.page.mouse.down();
  for (let i = 1; i <= 5; i++) { await v1.page.mouse.move(box.x + box.width / 2, box.y + box.height / 2 - i * 20); await sleep(30); }
  await v1.page.mouse.up();
  const touches = await until("down, moves and up on the Mac", async () => {
    const peer = await macPage.evaluate((viewer) => {
      const p = window.mac.peers.get(viewer);
      return p ? { touches: p.touches, inputs: p.inputs.filter((i) => i.type === "touch") } : null;
    }, start.viewer);
    return peer && peer.inputs.some((i) => i.phase === "up") && peer.touches.length ? peer : null;
  });
  if (touches.inputs[0].phase !== "down") throw new Error("down should come first on the input channel");
  if (touches.touches.some((t) => t.phase !== "move" || "type" in t)) throw new Error("only moves, as {phase, x, y}, on the touch channel");
  const down = touches.inputs[0];
  if (Math.abs(down.x - 195) > 2 || Math.abs(down.y - 422) > 2) throw new Error(`touch at ${down.x},${down.y}, expected the middle (195,422)`);
  console.log(`  down ${down.x},${down.y}; ${touches.touches.length} moves on "touch"; up on "input"`);
  const probes = await macPage.evaluate((viewer) => window.mac.peers.get(viewer).inputs.filter((i) => i.type === "probe").length, start.viewer);
  if (probes < 1) throw new Error("no probes on the input channel");
  if (wsStreams.length) throw new Error("the relay streamed WebSocket frames for a WebRTC viewer");

  step("closing the viewer sends rtc stop to the Mac");
  const mark = (await macLog()).length;
  await v1.page.close();
  await until("rtc stop", async () => (await macLog()).slice(mark).some((e) => e.kind === "rtc" && e.action === "stop" && e.viewer === start.viewer));
  if (v1.errors.length) throw new Error("page errors: " + v1.errors.join("; "));

  // 2. Fallbacks.
  async function expectFallback(name, mode, timeout) {
    step(`fallback: ${name}`);
    await macPage.evaluate((mode) => { window.mac.mode = mode; }, mode);
    const from = (await macLog()).length;
    const started = Date.now();
    const v = await openViewer("");
    await until("the WebSocket stream", async () => (await macLog()).slice(from).some((e) => e.kind === "stream" && e.action === "set" && e.streams.some((s) => s.udid === device)), timeout);
    await until("JPEG frames on screen", () => visible(v.page, "frame"), 10000);
    const transport = await until("a ws readout", async () => { const t = await v.readout(); return /^ws /.test(t) ? t.split("\n")[0] : null; }, 5000);
    const log = (await macLog()).slice(from);
    const viewer = log.find((e) => e.kind === "rtc" && e.action === "start")?.viewer;
    if (!viewer) throw new Error("WebRTC wasn't tried first");
    if (await visible(v.page, "rtcVideo")) throw new Error("the video element should be hidden");
    console.log(`  fell back in ${((Date.now() - started) / 1000).toFixed(1)} s: ${transport}`);
    if (v.errors.length) throw new Error("page errors: " + v.errors.join("; "));
    return { v, log, viewer };
  }
  const refused = await expectFallback("the Mac refuses (rtc error)", "refuse", 8000);
  await refused.v.page.close();

  const noIce = await expectFallback("ICE can't connect (8 s timeout)", "noice", 15000);
  const stopped = noIce.log.some((e) => e.kind === "rtc" && e.action === "stop" && e.viewer === noIce.viewer);
  if (!stopped) throw new Error("the viewer didn't stop the peer connection when it fell back");
  await noIce.v.page.close();

  step("?transport=ws skips WebRTC");
  await macPage.evaluate(() => { window.mac.mode = "ok"; });
  const from = (await macLog()).length;
  const v3 = await openViewer("transport=ws");
  await until("JPEG frames on screen", () => visible(v3.page, "frame"), 10000);
  if ((await macLog()).slice(from).some((e) => e.kind === "rtc" && e.action === "start")) throw new Error("rtc start with ?transport=ws");
  await v3.page.close();

  console.log("✓ WebRTC e2e passed");
  await finish(0);
} catch (error) {
  console.error("FAILED:", error.message);
  console.error("--- wrangler log\n" + wranglerLog.split("\n").slice(-40).join("\n"));
  await finish(1);
}
