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
    assert(data[0] === 1 && data[5] === 0xff && data[6] === 0xd8, "frame is a JPEG");
    frames++;
    ws.send(JSON.stringify({ type: "ack", seq: data.readUInt32BE(1) }));
    if (frames === 1 && screen) ws.send(JSON.stringify({ type: "input", tool: "swipe", arguments: { direction: "down" } }));
    if (frames >= 5) { clearTimeout(timer); resolve({ frames, screen }); }
  });
  ws.on("error", reject);
});
console.log(`  ${result.frames} frames; screen ${result.screen?.name} ${result.screen?.pointWidth}x${result.screen?.pointHeight} pt`);
ws.close();
console.log("E2E relay test passed.");
process.exit(0);
