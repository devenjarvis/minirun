// End-to-end check against a running Worker (e.g. `wrangler dev`) with a real `minirun serve`
// connected: OAuth like Claude's connector, MCP tool calls through the relay, and the live view.
//   node test/e2e-relay.mjs http://127.0.0.1:8787 <password>
import WebSocket from "ws";
import { createHash, randomBytes } from "node:crypto";

const [base = "http://127.0.0.1:8787", password = "e2e-password"] = process.argv.slice(2);
const redirect = "https://claude.test/callback";
const b64url = (buf) => Buffer.from(buf).toString("base64url");
const assert = (ok, message) => { if (!ok) { console.error("FAILED:", message); process.exit(1); } };
const step = (s) => console.log("•", s);

step("register client + authorize with password");
const reg = await (await fetch(`${base}/register`, { method: "POST", headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ redirect_uris: [redirect], client_name: "e2e", token_endpoint_auth_method: "none" }) })).json();
const verifier = b64url(randomBytes(32));
const challenge = b64url(createHash("sha256").update(verifier).digest());
const auth = new URL(`${base}/authorize`);
Object.entries({ response_type: "code", client_id: reg.client_id, redirect_uri: redirect, state: "x", code_challenge: challenge,
  code_challenge_method: "S256", resource: `${base}/mcp` }).forEach(([k, v]) => auth.searchParams.set(k, v));
const page = await (await fetch(auth)).text();
const state = page.match(/name="state" value="([^"]+)"/)?.[1]?.replace(/&amp;/g, "&");
assert(state, "consent page has state");
const approve = await fetch(`${base}/authorize`, { method: "POST", redirect: "manual",
  body: new URLSearchParams({ state, password, action: "approve" }) });
assert(approve.status === 302, `approve returned ${approve.status}`);
const code = new URL(approve.headers.get("location")).searchParams.get("code");
const tokenRes = await (await fetch(`${base}/token`, { method: "POST", body: new URLSearchParams({
  grant_type: "authorization_code", code, redirect_uri: redirect, client_id: reg.client_id, code_verifier: verifier, resource: `${base}/mcp` }) })).json();
const token = tokenRes.access_token;
assert(token, "got access token");

let id = 0;
async function rpc(method, params = {}) {
  const res = await fetch(`${base}/mcp`, { method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", Accept: "application/json, text/event-stream" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }) });
  const body = await res.json();
  assert(!body.error, `${method}: ${JSON.stringify(body.error)}`);
  return body.result;
}

step("MCP initialize + tools/list");
await rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "e2e", version: "1" } });
let tools = [];
for (let i = 0; i < 30 && tools.length < 10; i++) {
  tools = (await rpc("tools/list")).tools;
  if (tools.length < 10) await new Promise((r) => setTimeout(r, 1000));
}
console.log(`  ${tools.length} tools: ${tools.map((t) => t.name).join(", ")}`);
assert(tools.some((t) => t.name === "build_and_run"), "Mac tools are listed");

step("mac_status");
const status = await rpc("tools/call", { name: "mac_status", arguments: {} });
console.log("  " + status.content[0].text.split("\n")[0]);
assert(status.content[0].text.includes("online"), "Mac is online");

step("screenshot through the relay");
const shot = await rpc("tools/call", { name: "screenshot", arguments: {} });
assert(!shot.isError, JSON.stringify(shot.content).slice(0, 500));
const image = shot.content.find((c) => c.type === "image");
assert(image && Buffer.from(image.data, "base64").subarray(0, 2).equals(Buffer.from([0xff, 0xd8])), "got a JPEG");
console.log("  " + shot.content.find((c) => c.type === "text").text);

step("describe_ui through the relay");
const ui = await rpc("tools/call", { name: "describe_ui", arguments: {} });
assert(!ui.isError && ui.content[0].text.length > 20, "accessibility tree");
console.log("  " + ui.content[0].text.split("\n").slice(0, 3).join(" | "));

step("viewer login + live frames + input");
const login = await fetch(`${base}/login`, { method: "POST", redirect: "manual", body: new URLSearchParams({ password, next: "/" }) });
const cookie = login.headers.get("set-cookie").split(";")[0];
const ws = new WebSocket(`${base.replace(/^http/, "ws")}/viewer/ws`, { headers: { Cookie: cookie } });
const result = await new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error("no frames within 30s")), 30000);
  let frames = 0, screen = null;
  ws.on("message", (data, isBinary) => {
    if (!isBinary) { const m = JSON.parse(data.toString()); if (m.type === "screen") screen = m; return; }
    // Kind 2 frames carry [keyLength][key] (the simulator UDID, or "" for the default stream) before the JPEG.
    const start = data[0] === 2 ? 6 + data[5] : 5;
    assert((data[0] === 1 || data[0] === 2) && data[start] === 0xff && data[start + 1] === 0xd8, "frame is a JPEG");
    frames++;
    ws.send(JSON.stringify({ type: "ack", seq: data.readUInt32BE(1) }));
    if (frames === 1 && screen) ws.send(JSON.stringify({ type: "input", tool: "swipe", arguments: { direction: "down" } }));
    if (frames >= 5) { clearTimeout(timer); resolve({ frames, screen }); }
  });
  ws.on("error", reject);
});
console.log(`  ${result.frames} frames; screen ${result.screen?.name} ${result.screen?.pointWidth}x${result.screen?.pointHeight} pt`);
ws.close();

step("H.264 live view");
const video = new WebSocket(`${base.replace(/^http/, "ws")}/viewer/ws`, { headers: { Cookie: cookie } });
video.on("open", () => video.send(JSON.stringify({ type: "stream", codec: "h264", fps: 15, quality: 55, scale: 0.5 })));
const h264 = await new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error("no H.264 frames within 30s")), 30000);
  let frames = 0, bytes = 0, codec = null, swiped = false;
  video.on("message", (data, isBinary) => {
    if (!isBinary) return;
    if (data[0] !== 3) return; // JPEG frames from before the stream switched over
    // [3][seq][keyLength][key][flags][Annex B]: the first frame a viewer gets is a keyframe with SPS + PPS.
    const start = 6 + data[5];
    const keyframe = (data[start] & 1) === 1;
    const payload = data.subarray(start + 1);
    assert(payload[0] === 0 && payload[1] === 0 && payload[2] === 0 && payload[3] === 1, "Annex B start code");
    if (frames === 0) {
      assert(keyframe, "first H.264 frame is a keyframe");
      // NAL type 7 is the SPS (its header's top bits vary by encoder: 0x67, 0x27, ...).
      let sps = -1;
      for (let i = 0; i + 7 < payload.length && sps < 0; i++) {
        if (payload[i] === 0 && payload[i + 1] === 0 && payload[i + 2] === 1 && (payload[i + 3] & 0x1f) === 7) sps = i + 3;
      }
      assert(sps >= 0, "keyframe carries an SPS");
      codec = "avc1." + payload.subarray(sps + 1, sps + 4).toString("hex").toUpperCase();
    }
    frames++;
    bytes += payload.length;
    video.send(JSON.stringify({ type: "ack", seq: data.readUInt32BE(1) }));
    // The screen only produces frames when it changes, so scroll to get some.
    // A still screen sends just the keyframe, so give it a few seconds to send more after that.
    if (!swiped) {
      swiped = true;
      video.send(JSON.stringify({ type: "input", tool: "swipe", arguments: { direction: "up" } }));
      setTimeout(() => { clearTimeout(timer); resolve({ frames, bytes, codec }); }, 8000);
    }
    if (frames >= 3) { clearTimeout(timer); resolve({ frames, bytes, codec }); }
  });
  video.on("error", reject);
});
console.log(`  ${h264.frames} frames, ${h264.bytes} bytes, ${h264.codec}`);
video.close();

// A macOS app through the relay: build and launch the fixture, stream its window as H.264, click
// its button with live mouse touches and check the app saw it. Needs Screen Recording and
// Accessibility for minirun (CI grants them), so it only runs when MINIRUN_E2E_MAC_FIXTURE is set.
const macFixture = process.env.MINIRUN_E2E_MAC_FIXTURE;
if (macFixture) {
  const text = (result) => result.content.filter((c) => c.type === "text").map((c) => c.text).join("\n");
  async function call(name, args) {
    let result = await rpc("tools/call", { name, arguments: args });
    for (let i = 0; i < 20; i++) {
      const job = text(result).match(/is still running.*?(job_[0-9a-f]{8})/s);
      if (!job) break;
      result = await rpc("tools/call", { name: "get_job", arguments: { job_id: job[1], wait_seconds: 45 } });
    }
    return result;
  }

  step("macOS app: build_and_run through the relay");
  const built = await call("build_and_run", { path: macFixture, scheme: "HelloMacApp", platform: "macos", wait_seconds: 45 });
  assert(!built.isError, text(built).slice(-1500));
  const macId = text(built).match(/id (mac-[0-9a-f]{6})\./)?.[1];
  assert(macId, "build_and_run gave a Mac app id");
  console.log(`  ${macId}: ${text(built).split("\n").find((l) => l.startsWith("Launched"))}`);

  const tree = JSON.parse(text(await call("describe_ui", { device: macId, format: "json" })));
  const find = (nodes) => { for (const n of nodes) { if (n.AXIdentifier === "incrementButton") return n; const c = find(n.children || []); if (c) return c; } return null; };
  const button = find(tree);
  assert(button && button.frame, "incrementButton is in the window's tree");
  const at = { x: button.frame.x + button.frame.width / 2, y: button.frame.y + button.frame.height / 2 };

  step("macOS app: H.264 live view and live mouse");
  const mac = new WebSocket(`${base.replace(/^http/, "ws")}/viewer/ws`, { headers: { Cookie: cookie } });
  mac.on("open", () => mac.send(JSON.stringify({ type: "stream", device: macId, codec: "h264", fps: 15, quality: 55, scale: 0.5 })));
  const live = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("no Mac app frames within 30s")), 30000);
    let screen = null, frames = 0, clicked = false, picker = false;
    mac.on("message", (data, isBinary) => {
      if (!isBinary) {
        const m = JSON.parse(data.toString());
        if (m.type === "screen" && m.key === macId) screen = m;
        if (m.type === "simulators" && (m.devices || []).some((d) => d.udid === macId && d.kind === "mac")) picker = true;
        return;
      }
      if (data[0] !== 3 || data.subarray(6, 6 + data[5]).toString() !== macId) return;
      const keyframe = (data[6 + data[5]] & 1) === 1;
      if (frames === 0) assert(keyframe, "first Mac H.264 frame is a keyframe");
      frames++;
      mac.send(JSON.stringify({ type: "ack", seq: data.readUInt32BE(1) }));
      if (!clicked && screen) {
        clicked = true;
        mac.send(JSON.stringify({ type: "touch", phase: "down", ...at }));
        setTimeout(() => mac.send(JSON.stringify({ type: "touch", phase: "up", ...at })), 150);
        setTimeout(() => { clearTimeout(timer); resolve({ screen, frames, picker }); }, 3000);
      }
    });
    mac.on("error", reject);
  });
  mac.close();
  assert(live.screen.kind === "mac", `screen message says kind mac: ${JSON.stringify(live.screen)}`);
  console.log(`  ${live.frames} frames; screen ${live.screen.name} ${live.screen.pointWidth}x${live.screen.pointHeight} pt, ${live.screen.pixelWidth}x${live.screen.pixelHeight} px; in the picker: ${live.picker}`);
  const logs = text(await call("app_logs", { device: macId, seconds: 60, contains: "HelloMacApp:" }));
  assert(logs.includes("HelloMacApp: count=1"), `a live click on incrementButton reached the app:\n${logs}`);
  console.log("  live click reached the app (count=1)");
  const quit = await call("terminate_app", { device: macId });
  assert(!quit.isError && text(quit).includes("Quit HelloMacApp"), text(quit));
}
console.log("E2E relay test passed.");
process.exit(0);
