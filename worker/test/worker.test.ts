import { env, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { streamKey } from "../src/relay";
import { iceServers, STUN, TURN_REFRESH_MS, TURN_RETRY_MS, TURN_TTL_SECONDS } from "../src/ice";
import { probeStream } from "../src/media";
import { compareVersions, VERSION } from "../src/version";

const ORIGIN = "https://example.com";
const REDIRECT = "https://claude.test/callback";

function b64url(bytes: ArrayBuffer | Uint8Array): string {
  const array = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  return btoa(String.fromCharCode(...array)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Runs the full OAuth flow the way Claude's connector does and returns an access token. */
async function getAccessToken(password = "test-password"): Promise<string> {
  const registration = await SELF.fetch(`${ORIGIN}/register`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ redirect_uris: [REDIRECT], client_name: "Claude", token_endpoint_auth_method: "none" }),
  });
  expect(registration.status).toBe(201);
  const { client_id } = (await registration.json()) as { client_id: string };

  const verifier = b64url(crypto.getRandomValues(new Uint8Array(32)));
  const challenge = b64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
  const authorizeURL = new URL(`${ORIGIN}/authorize`);
  for (const [k, v] of Object.entries({
    response_type: "code", client_id, redirect_uri: REDIRECT, state: "s1",
    code_challenge: challenge, code_challenge_method: "S256", resource: `${ORIGIN}/mcp`,
  })) authorizeURL.searchParams.set(k, v);

  const consent = await SELF.fetch(authorizeURL);
  expect(consent.status).toBe(200);
  const page = await consent.text();
  expect(page).toContain("Connect Claude?");
  const state = page.match(/name="state" value="([^"]+)"/)?.[1];
  expect(state).toBeTruthy();

  const form = new FormData();
  form.set("state", state!.replace(/&amp;/g, "&"));
  form.set("password", password);
  form.set("action", "approve");
  const approved = await SELF.fetch(`${ORIGIN}/authorize`, { method: "POST", body: form, redirect: "manual" });
  if (password !== "test-password") return String(approved.status);
  expect(approved.status).toBe(302);
  const location = new URL(approved.headers.get("Location")!);
  expect(location.origin + location.pathname).toBe(REDIRECT);
  expect(location.searchParams.get("state")).toBe("s1");
  const code = location.searchParams.get("code")!;

  const token = await SELF.fetch(`${ORIGIN}/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "authorization_code", code, redirect_uri: REDIRECT, client_id, code_verifier: verifier, resource: `${ORIGIN}/mcp` }),
  });
  expect(token.status).toBe(200);
  return ((await token.json()) as { access_token: string }).access_token;
}

async function rpc(token: string, method: string, params: Record<string, unknown> = {}, id = 1) {
  const response = await SELF.fetch(`${ORIGIN}/mcp`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", Accept: "application/json, text/event-stream" },
    body: JSON.stringify({ jsonrpc: "2.0", id, method, params }),
  });
  expect(response.status).toBe(200);
  return (await response.json()) as { result?: any; error?: { code: number; message: string } };
}

async function connectAgent(token = "test-agent-token"): Promise<WebSocket | Response> {
  const response = await SELF.fetch(`${ORIGIN}/agent`, { headers: { Upgrade: "websocket", Authorization: `Bearer ${token}` } });
  if (!response.webSocket) return response;
  response.webSocket.accept();
  return response.webSocket;
}

function nextMessage(ws: WebSocket, predicate: (data: string) => boolean = () => true): Promise<string> {
  return new Promise((resolve) => {
    const listener = (event: MessageEvent) => {
      if (typeof event.data === "string" && predicate(event.data)) {
        ws.removeEventListener("message", listener);
        resolve(event.data);
      }
    };
    ws.addEventListener("message", listener);
  });
}

describe("minirun worker", () => {
  it("protects /mcp with OAuth and advertises metadata", async () => {
    const response = await SELF.fetch(`${ORIGIN}/mcp`, { method: "POST", body: "{}" });
    expect(response.status).toBe(401);
    expect(response.headers.get("WWW-Authenticate")).toContain("resource_metadata");
    const metadata = await SELF.fetch(`${ORIGIN}/.well-known/oauth-protected-resource/mcp`);
    expect(metadata.status).toBe(200);
    expect(((await metadata.json()) as { resource: string }).resource).toBe(`${ORIGIN}/mcp`);
  });

  it("refuses consent with the wrong password", async () => {
    expect(await getAccessToken("nope")).toBe("401");
  });

  it("serves MCP once authorized, and reports the Mac offline", async () => {
    const token = await getAccessToken();
    const init = await rpc(token, "initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } });
    expect(init.result.protocolVersion).toBe("2025-06-18");
    expect(init.result.capabilities.tools).toBeDefined();
    expect(init.result.serverInfo.version).toBe(VERSION);

    const list = await rpc(token, "tools/list");
    expect(list.result.tools.map((t: { name: string }) => t.name)).toContain("mac_status");

    const status = await rpc(token, "tools/call", { name: "mac_status", arguments: {} });
    expect(status.result.content[0].text).toContain("offline");

    const call = await rpc(token, "tools/call", { name: "screenshot", arguments: {} });
    expect(call.result.isError).toBe(true);
    expect(call.result.content[0].text).toContain("offline");

    const unknown = await rpc(token, "nope/method");
    expect(unknown.error?.code).toBe(-32601);
  });

  it("rejects a Mac with the wrong token", async () => {
    const response = (await connectAgent("wrong")) as Response;
    expect(response.status).toBe(401);
  });

  it("relays tool calls to the Mac and back", async () => {
    const agent = (await connectAgent()) as WebSocket;
    agent.send(JSON.stringify({
      type: "hello", version: 1, host: { name: "Test Mac" },
      tools: [{ name: "screenshot", description: "Take a screenshot", inputSchema: { type: "object", properties: {} } }],
    }));
    // Pretend to be the Mac: answer any call.
    const welcome = new Promise<{ bundle: string | null }>((resolve) => {
      agent.addEventListener("message", (event) => {
        if (typeof event.data === "string" && event.data.includes('"welcome"')) resolve(JSON.parse(event.data));
      });
    });
    // Wrangler-style deploys (the tests included) have no MINIRUN_BUNDLE.
    expect(await welcome).toEqual({ type: "welcome", bundle: null });

    agent.addEventListener("message", (event) => {
      if (typeof event.data !== "string" || event.data === "pong") return;
      const message = JSON.parse(event.data);
      if (message.type === "call" && message.id) {
        agent.send(JSON.stringify({ type: "result", id: message.id, result: { content: [{ type: "text", text: `ran ${message.tool} with ${JSON.stringify(message.arguments)}` }], isError: false } }));
      }
    });

    const token = await getAccessToken();
    const list = await rpc(token, "tools/list");
    expect(list.result.tools.map((t: { name: string }) => t.name)).toEqual(["mac_status", "screenshot"]);

    const status = await rpc(token, "tools/call", { name: "mac_status", arguments: {} });
    expect(status.result.content[0].text).toContain("online (Test Mac)");
    expect(status.result.content[0].text).toContain("hasn't said which minirun");
    const mine = await rpc(token, "tools/call", { name: "mac_status", arguments: { device: "ABC-123" } });
    expect(mine.result.content[0].text).toContain(`${ORIGIN}/?device=ABC-123`);
    const bad = await rpc(token, "tools/call", { name: "mac_status", arguments: { device: "../x" } });
    expect(bad.result.isError).toBe(true);

    const call = await rpc(token, "tools/call", { name: "screenshot", arguments: { scale: 0.5 } });
    expect(call.result.content[0].text).toBe('ran screenshot with {"scale":0.5}');
    agent.close();
  });

  it("says which minirun the Mac and the relay run, and which to update", async () => {
    const token = await getAccessToken();
    const statusWith = async (minirun: string) => {
      const agent = (await connectAgent()) as WebSocket;
      agent.send(JSON.stringify({ type: "hello", version: 3, host: { name: "Test Mac", minirun }, tools: [] }));
      await new Promise((r) => setTimeout(r, 50));
      const status = await rpc(token, "tools/call", { name: "mac_status", arguments: {} });
      agent.close();
      return status.result.content[0].text as string;
    };
    expect(await statusWith(VERSION)).toContain(`minirun ${VERSION} on the Mac and the relay.`);
    expect(await statusWith("0.0.1")).toContain("update minirun on the Mac");
    expect(await statusWith("99.0.0")).toContain("update the Worker");
  });

  it("keeps a call across a reconnect, and fails it if minirun restarted", async () => {
    const tools = [{ name: "shutdown_simulator", description: "Shut down", inputSchema: { type: "object", properties: {} } }];
    const first = (await connectAgent()) as WebSocket;
    first.send(JSON.stringify({ type: "hello", version: 3, instance: "run-1", host: { name: "Test Mac" }, tools }));
    await new Promise((r) => setTimeout(r, 50));
    const token = await getAccessToken();

    // The connection drops mid-call; the same run of minirun reconnects and hands over the result.
    let received = nextMessage(first, (d) => d.includes('"call"'));
    let call = rpc(token, "tools/call", { name: "shutdown_simulator", arguments: {} });
    const { id } = JSON.parse(await received);
    first.close();
    await new Promise((r) => setTimeout(r, 50));
    const second = (await connectAgent()) as WebSocket;
    const asked = nextMessage(second, (d) => d.includes('"pending"'));
    second.send(JSON.stringify({ type: "hello", version: 3, instance: "run-1", host: { name: "Test Mac" }, tools }));
    expect(JSON.parse(await asked).ids).toEqual([id]);
    second.send(JSON.stringify({ type: "result", id, result: { content: [{ type: "text", text: "Shut down" }], isError: false } }));
    expect((await call).result.content[0].text).toBe("Shut down");

    // A restarted minirun no longer has the call, so it fails right away and says so.
    received = nextMessage(second, (d) => d.includes('"call"'));
    call = rpc(token, "tools/call", { name: "shutdown_simulator", arguments: {} }, 2);
    await received;
    second.close();
    await new Promise((r) => setTimeout(r, 50));
    const third = (await connectAgent()) as WebSocket;
    third.send(JSON.stringify({ type: "hello", version: 3, instance: "run-2", host: { name: "Test Mac" }, tools }));
    const failed = (await call).result;
    expect(failed.isError).toBe(true);
    expect(failed.content[0].text).toContain("restarted while running shutdown_simulator");
    third.close();
  });

  it("serves the viewer only after login, and relays frames and input", async () => {
    const anonymous = await SELF.fetch(`${ORIGIN}/`, { redirect: "manual" });
    expect(anonymous.status).toBe(302);
    const deepLink = await SELF.fetch(`${ORIGIN}/?device=ABC-123`, { redirect: "manual" });
    expect(deepLink.headers.get("Location")).toBe(`/login?next=${encodeURIComponent("/?device=ABC-123")}`);

    const wrong = new FormData();
    wrong.set("password", "nope");
    expect((await SELF.fetch(`${ORIGIN}/login`, { method: "POST", body: wrong, redirect: "manual" })).status).toBe(401);

    const form = new FormData();
    form.set("password", "test-password");
    const login = await SELF.fetch(`${ORIGIN}/login`, { method: "POST", body: form, redirect: "manual" });
    expect(login.status).toBe(302);
    const cookie = login.headers.get("Set-Cookie")!.split(";")[0]!;

    const page = await SELF.fetch(`${ORIGIN}/`, { headers: { Cookie: cookie } });
    expect(await page.text()).toContain("Type into the app");

    const agent = (await connectAgent()) as WebSocket;
    agent.send(JSON.stringify({ type: "hello", version: 1, host: { name: "Test Mac" }, tools: [] }));
    await new Promise((r) => setTimeout(r, 50));

    const streamStart = nextMessage(agent, (d) => d.includes('"stream"'));
    const viewerResponse = await SELF.fetch(`${ORIGIN}/viewer/ws`, { headers: { Upgrade: "websocket", Cookie: cookie } });
    const viewer = viewerResponse.webSocket!;
    viewer.accept();
    const start = JSON.parse(await streamStart);
    expect(start).toMatchObject({ action: "set", streams: [{ udid: null }] });

    // The Mac says which simulator the default stream shows; input goes to that one.
    agent.send(JSON.stringify({ type: "screen", key: "", udid: "SIM-A", name: "iPhone 17 Pro", pointWidth: 402, pointHeight: 874 }));
    await new Promise((r) => setTimeout(r, 50));

    // A frame from the Mac reaches the viewer.
    const frameArrived = new Promise<ArrayBuffer>((resolve) => {
      viewer.addEventListener("message", (event) => {
        if (typeof event.data === "string") return;
        // Workers-side sockets deliver binary as Blob; browsers use ArrayBuffer (binaryType).
        const data = event.data as ArrayBuffer | Blob;
        if (data instanceof Blob) data.arrayBuffer().then(resolve);
        else resolve(data);
      });
    });
    const frame = new Uint8Array([1, 0, 0, 0, 7, 0xff, 0xd8]);
    agent.send(frame.buffer);
    const received = new Uint8Array(await frameArrived);
    expect([...received]).toEqual([...frame]);

    // Viewer input becomes a fire-and-forget call; acks flow back to the Mac.
    const inputCall = nextMessage(agent, (d) => d.includes('"call"'));
    viewer.send(JSON.stringify({ type: "input", tool: "tap", arguments: { x: 10, y: 20 } }));
    const call = JSON.parse(await inputCall);
    expect(call).toMatchObject({ type: "call", tool: "tap", arguments: { x: 10, y: 20, device: "SIM-A" } });
    expect(call.id).toBeUndefined();

    const ack = nextMessage(agent, (d) => d.includes('"ack"'));
    viewer.send(JSON.stringify({ type: "ack", seq: 7 }));
    expect(JSON.parse(await ack)).toMatchObject({ seq: 7, key: "" });

    // Viewers can't call arbitrary tools.
    viewer.send(JSON.stringify({ type: "input", tool: "run_command", arguments: { command: "rm -rf /" } }));

    const stop = nextMessage(agent, (d) => d.includes('"stop"'));
    viewer.close();
    expect(JSON.parse(await stop).action).toBe("stop");
    agent.close();
  });

  it("streams each viewer the simulator it picked, and sends its input there", async () => {
    const form = new FormData();
    form.set("password", "test-password");
    const login = await SELF.fetch(`${ORIGIN}/login`, { method: "POST", body: form, redirect: "manual" });
    const cookie = login.headers.get("Set-Cookie")!.split(";")[0]!;

    const agent = (await connectAgent()) as WebSocket;
    agent.send(JSON.stringify({ type: "hello", version: 2, host: { name: "Test Mac" }, tools: [] }));
    await new Promise((r) => setTimeout(r, 50));

    async function openViewer(device: string): Promise<WebSocket> {
      const response = await SELF.fetch(`${ORIGIN}/viewer/ws?device=${device}`, { headers: { Upgrade: "websocket", Cookie: cookie } });
      const ws = response.webSocket!;
      ws.accept();
      return ws;
    }
    function frames(ws: WebSocket): Uint8Array[] {
      const received: Uint8Array[] = [];
      ws.addEventListener("message", (event) => {
        if (typeof event.data === "string") return;
        const data = event.data as ArrayBuffer | Blob;
        if (data instanceof Blob) data.arrayBuffer().then((b) => received.push(new Uint8Array(b)));
        else received.push(new Uint8Array(data));
      });
      return received;
    }
    function keyedFrame(key: string, seq: number): Uint8Array {
      const keyBytes = new TextEncoder().encode(key);
      return new Uint8Array([2, 0, 0, 0, seq, keyBytes.length, ...keyBytes, 0xff, 0xd8]);
    }

    const firstSet = nextMessage(agent, (d) => d.includes('"set"'));
    const a = await openViewer("SIM-A");
    expect(JSON.parse(await firstSet).streams).toEqual([{ udid: "SIM-A", fps: 12, quality: 60, scale: 0.5, codec: "jpeg" }]);
    const bothSet = nextMessage(agent, (d) => d.includes('"SIM-B"'));
    const b = await openViewer("SIM-B");
    const both = JSON.parse(await bothSet).streams.map((s: { udid: string }) => s.udid).sort();
    expect(both).toEqual(["SIM-A", "SIM-B"]);

    const aFrames = frames(a);
    const bFrames = frames(b);
    agent.send(keyedFrame("SIM-A", 1));
    agent.send(keyedFrame("SIM-B", 1));
    agent.send(keyedFrame("SIM-B", 2));
    await new Promise((r) => setTimeout(r, 100));
    expect(aFrames.length).toBe(1);
    expect(bFrames.length).toBe(2);
    expect(new TextDecoder().decode(aFrames[0]!.subarray(6, 11))).toBe("SIM-A");

    // Input from each viewer goes to its own simulator, whatever the page claims.
    const inputCall = nextMessage(agent, (d) => d.includes('"call"'));
    b.send(JSON.stringify({ type: "input", tool: "tap", arguments: { x: 1, y: 2, device: "SIM-A" } }));
    expect(JSON.parse(await inputCall).arguments).toEqual({ x: 1, y: 2, device: "SIM-B" });

    // Live touches go to the viewer's simulator too, and a viewer that leaves mid-touch has its
    // finger lifted.
    const touchDown = nextMessage(agent, (d) => d.includes('"touch"'));
    b.send(JSON.stringify({ type: "touch", phase: "down", x: 5, y: 6, device: "SIM-A" }));
    expect(JSON.parse(await touchDown)).toEqual({ type: "touch", device: "SIM-B", phase: "down", x: 5, y: 6 });
    const touchMove = nextMessage(agent, (d) => d.includes('"touch"'));
    b.send(JSON.stringify({ type: "touch", phase: "wiggle", x: 1, y: 1 }));
    b.send(JSON.stringify({ type: "touch", phase: "move", x: 7, y: Number.NaN }));
    b.send(JSON.stringify({ type: "touch", phase: "move", x: 7, y: 8 }));
    expect(JSON.parse(await touchMove)).toMatchObject({ phase: "move", x: 7, y: 8 });

    // Switching simulators re-plans the streams.
    const switched = nextMessage(agent, (d) => d.includes('"set"') && !d.includes('"SIM-B"'));
    b.send(JSON.stringify({ type: "stream", device: "SIM-A", fps: 6, quality: 45, scale: 0.33 }));
    expect(JSON.parse(await switched).streams.map((s: { udid: string }) => s.udid)).toEqual(["SIM-A"]);

    // The simulator list reaches viewers, and mac_status keeps it.
    const listed = nextMessage(a, (d) => d.includes('"simulators"'));
    agent.send(JSON.stringify({ type: "simulators", devices: [{ udid: "SIM-A", name: "iPhone 17 Pro", reserved_for: "you/app@a" }] }));
    expect(JSON.parse(await listed).devices[0].reserved_for).toBe("you/app@a");

    const stop = nextMessage(agent, (d) => d.includes('"stop"'));
    const lifted = nextMessage(agent, (d) => d.includes('"touch"'));
    a.close();
    b.close();
    expect(JSON.parse(await lifted)).toEqual({ type: "touch", phase: "up", device: "SIM-B", x: 7, y: 8 });
    expect(JSON.parse(await stop).action).toBe("stop");
    agent.close();
  });

  it("streams Mac app windows and sends their input, scrolling and menus there", async () => {
    expect(streamKey("mac-3f9a2c")).toBe("mac-3f9a2c");
    expect(streamKey("mac")).toBe("mac");
    expect(streamKey("mac/../x")).toBeNull();

    const form = new FormData();
    form.set("password", "test-password");
    const login = await SELF.fetch(`${ORIGIN}/login`, { method: "POST", body: form, redirect: "manual" });
    const cookie = login.headers.get("Set-Cookie")!.split(";")[0]!;
    const page = await SELF.fetch(`${ORIGIN}/?device=mac-3f9a2c`, { headers: { Cookie: cookie } });
    expect(page.status).toBe(200);

    const agent = (await connectAgent()) as WebSocket;
    agent.send(JSON.stringify({ type: "hello", version: 5, host: { name: "Test Mac" }, tools: [] }));
    await new Promise((r) => setTimeout(r, 50));

    // Mac apps are in the picker list, next to simulators; it's kept for viewers that join later.
    const devices = [
      { udid: "SIM-A", name: "iPhone 17 Pro" },
      { udid: "mac-3f9a2c", kind: "mac", name: "Fetch", reserved_for: "you/fetch@main" },
    ];
    agent.send(JSON.stringify({ type: "simulators", devices }));
    agent.send(JSON.stringify({ type: "screen", key: "mac-3f9a2c", udid: "mac-3f9a2c", kind: "mac", name: "Fetch", pointWidth: 800, pointHeight: 600, pixelWidth: 1600, pixelHeight: 1200 }));
    await new Promise((r) => setTimeout(r, 50));

    const streamSet = nextMessage(agent, (d) => d.includes('"set"'));
    const response = await SELF.fetch(`${ORIGIN}/viewer/ws?device=mac-3f9a2c`, { headers: { Upgrade: "websocket", Cookie: cookie } });
    const viewer = response.webSocket!;
    const listed = nextMessage(viewer, (d) => d.includes('"simulators"'));
    const screen = nextMessage(viewer, (d) => d.includes('"screen"'));
    viewer.accept();
    expect(JSON.parse(await listed).devices).toEqual(devices);
    expect(JSON.parse(await screen)).toMatchObject({ udid: "mac-3f9a2c", pointWidth: 800 });
    expect(JSON.parse(await streamSet).streams).toEqual([{ udid: "mac-3f9a2c", fps: 12, quality: 60, scale: 0.5, codec: "jpeg" }]);

    // A resized window re-announces its size to the viewers watching it.
    const resized = nextMessage(viewer, (d) => d.includes('"screen"'));
    agent.send(JSON.stringify({ type: "screen", key: "mac-3f9a2c", udid: "mac-3f9a2c", kind: "mac", name: "Fetch", pointWidth: 1024, pointHeight: 700, pixelWidth: 2048, pixelHeight: 1400 }));
    expect(JSON.parse(await resized).pointWidth).toBe(1024);

    // Mac input from the viewer keeps its arguments and goes to the Mac app being watched.
    const calls: Array<{ tool: string; arguments: Record<string, unknown> }> = [];
    agent.addEventListener("message", (event) => {
      if (typeof event.data !== "string" || event.data === "pong") return;
      const message = JSON.parse(event.data);
      if (message.type === "call") calls.push(message);
    });
    const inputs: Array<[string, Record<string, unknown>]> = [
      ["tap", { x: 10, y: 20, button: "right" }],
      ["tap", { x: 10, y: 20, count: 2 }],
      ["scroll", { x: 400, y: 300, dx: 0, dy: 42.5 }],
      ["press_key", { key: "n", modifiers: ["command", "shift"] }],
      ["type_text", { text: "hello" }],
      ["press_menu_item", { path: ["File", "New Window"], device: "SIM-A" }],
      // A viewer can't pick the HID path (the real cursor and keyboard) or another window.
      ["tap", { x: 1, y: 2, input: "hid", window: "Settings" }],
      ["run_command", { command: "rm -rf /" }],
    ];
    for (const [tool, args] of inputs) viewer.send(JSON.stringify({ type: "input", tool, arguments: args }));
    const touched = nextMessage(agent, (d) => d.includes('"touch"'));
    viewer.send(JSON.stringify({ type: "touch", phase: "down", x: 5, y: 6 }));
    expect(JSON.parse(await touched)).toEqual({ type: "touch", device: "mac-3f9a2c", phase: "down", x: 5, y: 6 });
    viewer.send(JSON.stringify({ type: "touch", phase: "up", x: 5, y: 6 }));
    await new Promise((r) => setTimeout(r, 100));
    expect(calls.map((c) => [c.tool, c.arguments])).toEqual([
      ...inputs.slice(0, 6).map(([tool, args]) => [tool, { ...args, device: "mac-3f9a2c" }]),
      ["tap", { x: 1, y: 2, device: "mac-3f9a2c" }],
    ]);

    // mac_status links straight to a Mac app.
    const token = await getAccessToken();
    const status = await rpc(token, "tools/call", { name: "mac_status", arguments: { device: "mac-3f9a2c" } });
    expect(status.result.content[0].text).toContain(`Live view of Mac app mac-3f9a2c: ${ORIGIN}/?device=mac-3f9a2c`);

    viewer.close();
    agent.close();
  });

  it("tells viewers whether the Mac takes live touches", async () => {
    const form = new FormData();
    form.set("password", "test-password");
    const login = await SELF.fetch(`${ORIGIN}/login`, { method: "POST", body: form, redirect: "manual" });
    const cookie = login.headers.get("Set-Cookie")!.split(";")[0]!;
    const agent = (await connectAgent()) as WebSocket;
    agent.send(JSON.stringify({ type: "hello", version: 3, host: { name: "Test Mac" }, tools: [] }));
    await new Promise((r) => setTimeout(r, 50));

    const response = await SELF.fetch(`${ORIGIN}/viewer/ws`, { headers: { Upgrade: "websocket", Cookie: cookie } });
    const viewer = response.webSocket!;
    const greeting = nextMessage(viewer, (d) => d.includes('"status"'));
    viewer.accept();
    expect(JSON.parse(await greeting).touch).toBe(false);

    const upgraded = nextMessage(viewer, (d) => d.includes('"status"'));
    agent.send(JSON.stringify({ type: "hello", version: 4, host: { name: "Test Mac" }, tools: [] }));
    expect(JSON.parse(await upgraded).touch).toBe(true);
    viewer.close();
    agent.close();
  });

  it("streams H.264 to viewers that can decode it, keyframe first", async () => {
    const form = new FormData();
    form.set("password", "test-password");
    const login = await SELF.fetch(`${ORIGIN}/login`, { method: "POST", body: form, redirect: "manual" });
    const cookie = login.headers.get("Set-Cookie")!.split(";")[0]!;

    const agent = (await connectAgent()) as WebSocket;
    agent.send(JSON.stringify({ type: "hello", version: 3, host: { name: "Test Mac" }, tools: [] }));
    await new Promise((r) => setTimeout(r, 50));
    const toMac: string[] = [];
    agent.addEventListener("message", (event) => {
      if (typeof event.data === "string" && event.data !== "pong") toMac.push(event.data);
    });

    async function openViewer(): Promise<{ ws: WebSocket; frames: number[] }> {
      const response = await SELF.fetch(`${ORIGIN}/viewer/ws?device=SIM-V`, { headers: { Upgrade: "websocket", Cookie: cookie } });
      const ws = response.webSocket!;
      ws.accept();
      const frames: number[] = [];
      ws.addEventListener("message", (event) => {
        if (typeof event.data === "string") return;
        const data = event.data as ArrayBuffer | Blob;
        const record = (b: ArrayBuffer) => frames.push(new DataView(b).getUint32(1));
        if (data instanceof Blob) data.arrayBuffer().then(record);
        else record(data);
      });
      return { ws, frames };
    }
    function videoFrame(seq: number, keyframe: boolean): Uint8Array {
      const key = new TextEncoder().encode("SIM-V");
      return new Uint8Array([3, 0, 0, 0, seq, key.length, ...key, keyframe ? 1 : 0, 0, 0, 0, 1, keyframe ? 0x65 : 0x41]);
    }
    const settle = () => new Promise((r) => setTimeout(r, 100));

    const h264 = nextMessage(agent, (d) => d.includes('"h264"'));
    const viewer = await openViewer();
    viewer.ws.send(JSON.stringify({ type: "stream", device: "SIM-V", codec: "h264", fps: 30, quality: 55, scale: 0.5 }));
    expect(JSON.parse(await h264).streams).toEqual([{ udid: "SIM-V", fps: 30, quality: 55, scale: 0.5, codec: "h264" }]);
    await settle();
    expect(toMac.some((m) => JSON.parse(m).type === "keyframe" && JSON.parse(m).key === "SIM-V")).toBe(true);

    // A delta frame is useless to a viewer that hasn't had a keyframe yet.
    agent.send(videoFrame(1, false));
    agent.send(videoFrame(2, true));
    agent.send(videoFrame(3, false));
    await settle();
    expect(viewer.frames).toEqual([2, 3]);

    // A viewer that falls too far behind skips to the next keyframe.
    for (let seq = 4; seq <= 20; seq++) agent.send(videoFrame(seq, false));
    await settle();
    expect(viewer.frames.at(-1)).toBe(11); // 10 frames in flight since the last one counted as seen (1)
    viewer.ws.send(JSON.stringify({ type: "ack", seq: 20 }));
    await settle();
    agent.send(videoFrame(21, false));
    agent.send(videoFrame(22, true));
    await settle();
    expect(viewer.frames.at(-1)).toBe(22);
    expect(viewer.frames).not.toContain(21);

    // A viewer without H.264 turns the stream back to JPEG, and never gets H.264 frames.
    const jpeg = nextMessage(agent, (d) => d.includes('"set"') && d.includes('"jpeg"'));
    const old = await openViewer();
    expect(JSON.parse(await jpeg).streams[0].codec).toBe("jpeg");
    agent.send(videoFrame(23, true));
    await settle();
    expect(old.frames).toEqual([]);
    expect(viewer.frames.at(-1)).toBe(23);

    viewer.ws.close();
    old.ws.close();
    agent.close();
  });

  it("echoes a viewer's probe to that viewer only, and sends each stream's stats to its viewers", async () => {
    const form = new FormData();
    form.set("password", "test-password");
    const login = await SELF.fetch(`${ORIGIN}/login`, { method: "POST", body: form, redirect: "manual" });
    const cookie = login.headers.get("Set-Cookie")!.split(";")[0]!;
    const agent = (await connectAgent()) as WebSocket;
    agent.send(JSON.stringify({ type: "hello", version: 5, host: { name: "Test Mac" }, tools: [] }));
    await new Promise((r) => setTimeout(r, 50));

    async function openViewer(device: string) {
      const response = await SELF.fetch(`${ORIGIN}/viewer/ws?device=${device}`, { headers: { Upgrade: "websocket", Cookie: cookie } });
      const ws = response.webSocket!;
      const texts: Array<{ type: string; [key: string]: unknown }> = [];
      ws.addEventListener("message", (event) => {
        if (typeof event.data === "string") texts.push(JSON.parse(event.data));
      });
      ws.accept();
      return { ws, of: (type: string) => texts.filter((m) => m.type === type) };
    }
    const settle = () => new Promise((r) => setTimeout(r, 100));
    const a = await openViewer("SIM-A");
    const b = await openViewer("SIM-A");
    const c = await openViewer("SIM-B");

    // The relay tags each probe with the viewer it came from; nothing else from the page passes.
    const fromA = nextMessage(agent, (d) => d.includes('"probe"'));
    a.ws.send(JSON.stringify({ type: "probe", t: 1234.5, viewer: "spoofed" }));
    const probeA = JSON.parse(await fromA);
    expect(probeA).toMatchObject({ type: "probe", t: 1234.5 });
    expect(typeof probeA.viewer).toBe("string");
    expect(probeA.viewer).not.toBe("spoofed");
    const fromB = nextMessage(agent, (d) => d.includes('"probe"'));
    b.ws.send(JSON.stringify({ type: "probe", t: 99 }));
    const probeB = JSON.parse(await fromB);
    expect(probeB.viewer).not.toBe(probeA.viewer);

    // Switching streams keeps a viewer's id.
    b.ws.send(JSON.stringify({ type: "stream", device: "SIM-A", fps: 6, quality: 45, scale: 0.33 }));
    await settle();
    const again = nextMessage(agent, (d) => d.includes('"probe"'));
    b.ws.send(JSON.stringify({ type: "probe", t: 100 }));
    expect(JSON.parse(await again).viewer).toBe(probeB.viewer);

    // A probe without a usable time doesn't reach the Mac.
    let stray = 0;
    const count = (event: MessageEvent) => { if (typeof event.data === "string" && event.data.includes('"probe"')) stray++; };
    agent.addEventListener("message", count);
    a.ws.send(JSON.stringify({ type: "probe", t: "soon" }));
    await settle();
    agent.removeEventListener("message", count);
    expect(stray).toBe(0);

    // The Mac's echo goes to the viewer it names, and only that one. An unknown id goes nowhere.
    agent.send(JSON.stringify({ type: "probe", t: 1234.5, viewer: probeA.viewer }));
    agent.send(JSON.stringify({ type: "probe", t: 7, viewer: "nobody" }));
    agent.send(JSON.stringify({ type: "probe", t: 8 }));
    await settle();
    expect(a.of("probe")).toEqual([{ type: "probe", t: 1234.5 }]);
    expect(b.of("probe")).toEqual([]);
    expect(c.of("probe")).toEqual([]);

    // Stats reach the viewers of their stream only.
    const stats = { type: "stats", key: "SIM-A", codec: "h264", fps: 30, pipelineMs: 12.3, pipelineP95Ms: 20.1, touchMs: 48, touchP95Ms: 70 };
    agent.send(JSON.stringify(stats));
    agent.send(JSON.stringify({ ...stats, key: "SIM-B", pipelineMs: 40 }));
    await settle();
    expect(a.of("stats")).toEqual([stats]);
    expect(b.of("stats")).toEqual([stats]);
    expect(c.of("stats")).toEqual([{ ...stats, key: "SIM-B", pipelineMs: 40 }]);

    a.ws.close();
    b.ws.close();
    c.ws.close();
    agent.close();
  });
});

describe("compareVersions", () => {
  it("compares by number, not as text", () => {
    expect(compareVersions("0.10.0", "0.9.0")).toBeGreaterThan(0);
    expect(compareVersions("0.2", "0.2.0")).toBe(0);
    expect(compareVersions("1.0.0", "1.0.1")).toBeLessThan(0);
  });
});

describe("shared media", () => {
  const AGENT = { Authorization: "Bearer test-agent-token" };

  function newId(): string {
    return b64url(crypto.getRandomValues(new Uint8Array(16)));
  }

  function put(path: string, body: BodyInit | null, headers: Record<string, string> = {}) {
    return SELF.fetch(`${ORIGIN}${path}`, { method: "PUT", body, headers: { ...AGENT, "X-Minirun-Expires-In": "3600", ...headers } });
  }

  it("needs the agent token to upload or delete", async () => {
    const id = newId();
    expect((await put(`/media/${id}.jpg`, "x", { Authorization: "Bearer wrong" })).status).toBe(401);
    const missing = await SELF.fetch(`${ORIGIN}/media/${id}.jpg`, { method: "PUT", body: "x", headers: { "X-Minirun-Expires-In": "3600" } });
    expect(missing.status).toBe(401);
    expect((await SELF.fetch(`${ORIGIN}/media/${id}`, { method: "DELETE" })).status).toBe(401);
    expect((await SELF.fetch(`${ORIGIN}/m/${id}.jpg`)).status).toBe(404);
  });

  it("rejects bad ids, extensions, expiries and captions", async () => {
    const id = newId();
    expect((await put(`/media/short.jpg`, "x")).status).toBe(400);
    expect((await put(`/media/${id.slice(0, 21)}!.jpg`, "x")).status).toBe(400);
    expect((await put(`/media/${id}.webp`, "x")).status).toBe(400);
    expect((await put(`/media/${id}`, "x")).status).toBe(400);
    for (const ttl of ["", "59", "7776001", "1e3", "-60", "60.5"]) {
      expect((await put(`/media/${id}.jpg`, "x", { "X-Minirun-Expires-In": ttl })).status, ttl).toBe(400);
    }
    expect((await put(`/media/${id}.jpg`, "x", { "X-Minirun-Caption": "%E0%A4%A" })).status).toBe(400);
    expect((await put(`/media/${id}.jpg`, "x", { "X-Minirun-Caption": "a".repeat(201) })).status).toBe(400);
    expect((await put(`/media/${id}.jpg`, "x", { "X-Minirun-Caption": "a".repeat(200), "X-Minirun-Expires-In": "7776000" })).status).toBe(201);
    expect((await put(`/media/${id}.png`, "x", { "X-Minirun-Expires-In": "60" })).status).toBe(201);
    expect((await SELF.fetch(`${ORIGIN}/media/${id}.jpg`, { method: "DELETE", headers: AGENT })).status).toBe(400);
  });

  it("refuses bodies over 25 MiB", async () => {
    const id = newId();
    const big = new Uint8Array(25 * 1024 * 1024 + 1);
    expect((await put(`/media/${id}.mp4`, big)).status).toBe(413);
    // A body without a Content-Length is counted as it arrives.
    const stream = new Response(big).body!.pipeThrough(new TransformStream());
    expect((await put(`/media/${id}.mp4`, stream)).status).toBe(413);
    expect((await SELF.fetch(`${ORIGIN}/m/${id}.mp4`)).status).toBe(404);
    const exact = await put(`/media/${id}.mp4`, new Uint8Array(25 * 1024 * 1024));
    expect(exact.status).toBe(201);
  });

  it("stores an upload and serves it publicly with caching, ranges and HEAD", async () => {
    const id = newId();
    const bytes = Uint8Array.from({ length: 1000 }, (_, i) => i % 256);
    const uploaded = await put(`/media/${id}.mp4`, bytes, { "X-Minirun-Caption": encodeURIComponent("Onboarding <flow> & \"done\"") });
    expect(uploaded.status).toBe(201);
    expect(await uploaded.json()).toEqual({ url: `${ORIGIN}/m/${id}.mp4` });

    const stored = await env.MEDIA_KV.getWithMetadata<{ type: string; bytes: number; caption?: string; created: number }>(`${id}.mp4`);
    expect(stored.metadata).toMatchObject({ type: "video/mp4", bytes: 1000, caption: "Onboarding <flow> & \"done\"" });
    expect(Math.abs(stored.metadata!.created - Date.now())).toBeLessThan(60_000);

    const got = await SELF.fetch(`${ORIGIN}/m/${id}.mp4`);
    expect(got.status).toBe(200);
    expect(got.headers.get("Content-Type")).toBe("video/mp4");
    expect(got.headers.get("Content-Length")).toBe("1000");
    expect(got.headers.get("Cache-Control")).toBe("public, max-age=31536000, immutable");
    expect(got.headers.get("X-Robots-Tag")).toBe("noindex");
    expect(got.headers.get("X-Content-Type-Options")).toBe("nosniff");
    expect(got.headers.get("Accept-Ranges")).toBe("bytes");
    expect(new Uint8Array(await got.arrayBuffer())).toEqual(bytes);

    const head = await SELF.fetch(`${ORIGIN}/m/${id}.mp4`, { method: "HEAD" });
    expect(head.status).toBe(200);
    expect(head.headers.get("Content-Length")).toBe("1000");
    expect(head.headers.get("Content-Type")).toBe("video/mp4");
    expect((await head.arrayBuffer()).byteLength).toBe(0);

    const partial = await SELF.fetch(`${ORIGIN}/m/${id}.mp4`, { headers: { Range: "bytes=10-19" } });
    expect(partial.status).toBe(206);
    expect(partial.headers.get("Content-Range")).toBe("bytes 10-19/1000");
    expect(partial.headers.get("Content-Length")).toBe("10");
    expect(new Uint8Array(await partial.arrayBuffer())).toEqual(bytes.slice(10, 20));

    const open = await SELF.fetch(`${ORIGIN}/m/${id}.mp4`, { headers: { Range: "bytes=990-" } });
    expect(open.status).toBe(206);
    expect(open.headers.get("Content-Range")).toBe("bytes 990-999/1000");
    await open.arrayBuffer();
    const suffix = await SELF.fetch(`${ORIGIN}/m/${id}.mp4`, { headers: { Range: "bytes=-5" } });
    expect(suffix.headers.get("Content-Range")).toBe("bytes 995-999/1000");
    expect(new Uint8Array(await suffix.arrayBuffer())).toEqual(bytes.slice(995));

    const beyond = await SELF.fetch(`${ORIGIN}/m/${id}.mp4`, { headers: { Range: "bytes=1000-" } });
    expect(beyond.status).toBe(416);
    expect(beyond.headers.get("Content-Range")).toBe("bytes */1000");

    const several = await SELF.fetch(`${ORIGIN}/m/${id}.mp4`, { headers: { Range: "bytes=0-1,5-6" } });
    expect(several.status).toBe(200);
    expect((await several.arrayBuffer()).byteLength).toBe(1000);

    expect((await SELF.fetch(`${ORIGIN}/m/${id}.gif`)).status).toBe(404);
    expect((await SELF.fetch(`${ORIGIN}/m/${newId()}.mp4`)).status).toBe(404);
    expect((await SELF.fetch(`${ORIGIN}/m/${id}.mp4`, { method: "POST" })).status).toBe(405);
  });

  it("serves a player page for recordings, with the caption escaped", async () => {
    const id = newId();
    expect((await put(`/media/${id}.mp4`, "mp4", { "X-Minirun-Caption": encodeURIComponent("<script>alert(1)</script>") })).status).toBe(201);
    const page = await SELF.fetch(`${ORIGIN}/m/${id}`);
    expect(page.status).toBe(200);
    expect(page.headers.get("Content-Type")).toContain("text/html");
    expect(page.headers.get("X-Robots-Tag")).toBe("noindex");
    const text = await page.text();
    expect(text).toContain(`<video src="/m/${id}.mp4" controls playsinline`);
    expect(text).toContain(`<meta name="robots" content="noindex">`);
    expect(text).toContain("&lt;script&gt;alert(1)&lt;/script&gt;");
    expect(text).not.toContain("<script>");

    const screenshot = newId();
    expect((await put(`/media/${screenshot}.jpg`, "jpg")).status).toBe(201);
    expect((await SELF.fetch(`${ORIGIN}/m/${screenshot}`)).status).toBe(404);
    expect((await SELF.fetch(`${ORIGIN}/m/${newId()}`)).status).toBe(404);
  });

  it("deletes every file with an id", async () => {
    const id = newId();
    for (const ext of ["jpg", "png", "gif", "mp4"]) expect((await put(`/media/${id}.${ext}`, ext)).status).toBe(201);
    const gif = await SELF.fetch(`${ORIGIN}/m/${id}.gif`);
    expect(gif.status).toBe(200);
    await gif.arrayBuffer();
    const deleted = await SELF.fetch(`${ORIGIN}/media/${id}`, { method: "DELETE", headers: AGENT });
    expect(deleted.status).toBe(204);
    for (const ext of ["jpg", "png", "gif", "mp4"]) expect((await SELF.fetch(`${ORIGIN}/m/${id}.${ext}`)).status).toBe(404);
    expect((await SELF.fetch(`${ORIGIN}/m/${id}`)).status).toBe(404);
  });

  it("serves size probes of exactly n MiB that are valid GIFs", async () => {
    for (const n of [1, 2, 7, 25]) {
      const response = await SELF.fetch(`${ORIGIN}/m/probe/${n}.gif`);
      expect(response.status).toBe(200);
      expect(response.headers.get("Content-Type")).toBe("image/gif");
      expect(response.headers.get("Content-Length")).toBe(String(n * 1024 * 1024));
      expect(response.headers.get("Cache-Control")).toContain("public");
      const bytes = new Uint8Array(await response.arrayBuffer());
      expect(bytes.length).toBe(n * 1024 * 1024);
      expect(String.fromCharCode(...bytes.slice(0, 6))).toBe("GIF89a");
      expect(bytes[bytes.length - 1]).toBe(0x3b);
      expect(walkGIF(bytes)).toEqual({ frames: 2, end: bytes.length - 1 });
    }
    const head = await SELF.fetch(`${ORIGIN}/m/probe/10.gif`, { method: "HEAD" });
    expect(head.status).toBe(200);
    expect(head.headers.get("Content-Length")).toBe(String(10 * 1024 * 1024));
    for (const n of ["0", "26", "05", "x"]) expect((await SELF.fetch(`${ORIGIN}/m/probe/${n}.gif`)).status, n).toBe(404);
  });

  it("pads probes to any size exactly, whatever the remainder", async () => {
    // A leftover of one byte can't be a single sub-block; cover every remainder mod 256.
    for (let total = 3000; total < 3000 + 260; total++) {
      const bytes = new Uint8Array(await new Response(probeStream(total)).arrayBuffer());
      expect(bytes.length).toBe(total);
      expect(walkGIF(bytes)).toEqual({ frames: 2, end: total - 1 });
    }
  });
});

/** Walks a GIF's blocks the way a decoder does, returning the frame count and where the trailer is. */
function walkGIF(bytes: Uint8Array): { frames: number; end: number } {
  const table = (packed: number) => (packed & 0x80 ? 3 * 2 ** ((packed & 7) + 1) : 0);
  let i = 13 + table(bytes[10]!);
  const skipSubBlocks = () => {
    while (bytes[i] !== 0) {
      if (i >= bytes.length) throw new Error("ran off the end");
      i += bytes[i]! + 1;
    }
    i++;
  };
  let frames = 0;
  for (;;) {
    const kind = bytes[i];
    if (kind === 0x3b) return { frames, end: i };
    if (kind === 0x21) {
      i += 2;
      skipSubBlocks();
    } else if (kind === 0x2c) {
      i += 10 + table(bytes[i + 9]!) + 1;
      skipSubBlocks();
      frames++;
    } else {
      throw new Error(`bad block 0x${kind?.toString(16)} at ${i}`);
    }
  }
}

describe("WebRTC signaling (protocol 6)", () => {
  type Message = { type: string; [key: string]: unknown };
  const settle = () => new Promise((r) => setTimeout(r, 100));

  async function login(): Promise<string> {
    const form = new FormData();
    form.set("password", "test-password");
    const response = await SELF.fetch(`${ORIGIN}/login`, { method: "POST", body: form, redirect: "manual" });
    return response.headers.get("Set-Cookie")!.split(";")[0]!;
  }

  /** A socket that keeps what it receives: text as parsed JSON, binary as a count. */
  function record(ws: WebSocket) {
    const texts: Message[] = [];
    let binary = 0;
    ws.addEventListener("message", (event) => {
      if (typeof event.data === "string") texts.push(JSON.parse(event.data));
      else binary++;
    });
    return {
      ws,
      texts,
      binary: () => binary,
      of: (type: string, action?: string) => texts.filter((m) => m.type === type && (action === undefined || m.action === action)),
      clear: () => { texts.length = 0; binary = 0; },
    };
  }

  async function macWith(hello: Record<string, unknown>) {
    const agent = (await connectAgent()) as WebSocket;
    const mac = record(agent);
    agent.send(JSON.stringify({ type: "hello", version: 6, host: { name: "Test Mac" }, tools: [], ...hello }));
    await settle();
    return mac;
  }

  async function openViewer(cookie: string, query: string) {
    const response = await SELF.fetch(`${ORIGIN}/viewer/ws?${query}`, { headers: { Upgrade: "websocket", Cookie: cookie } });
    const viewer = record(response.webSocket!);
    response.webSocket!.accept();
    await settle();
    return viewer;
  }

  const lastStreams = (mac: ReturnType<typeof record>) =>
    ((mac.of("stream").at(-1)?.streams ?? []) as Array<{ udid: string | null; codec: string }>);

  it("routes each viewer's signaling to and from its own peer connection only", async () => {
    const cookie = await login();
    const mac = await macWith({ webrtc: true });
    const a = await openViewer(cookie, "device=SIM-A&rtc=1");
    const b = await openViewer(cookie, "device=SIM-A&rtc=1");
    const c = await openViewer(cookie, "device=SIM-B");
    expect(a.of("status")[0]).toMatchObject({ online: true, touch: true, webrtc: true });
    // ?rtc=1 viewers wait to be asked for; the WebSocket stream is only for c.
    expect(lastStreams(mac).map((s) => s.udid)).toEqual(["SIM-B"]);

    // The relay picks the viewer id; the page can't.
    mac.clear();
    a.ws.send(JSON.stringify({ type: "rtc", action: "start", device: "SIM-A", fps: 30, quality: 55, scale: 0.5, viewer: "spoofed" }));
    await settle();
    const startA = mac.of("rtc", "start")[0]!;
    expect(startA).toMatchObject({ key: "SIM-A", fps: 30, quality: 55, scale: 0.5, iceServers: [{ urls: "stun:stun.cloudflare.com:3478" }] });
    expect(typeof startA.viewer).toBe("string");
    expect(startA.viewer).not.toBe("spoofed");
    b.ws.send(JSON.stringify({ type: "rtc", action: "start", device: "SIM-A", fps: 30, quality: 55, scale: 0.5 }));
    await settle();
    const viewerA = startA.viewer as string, viewerB = mac.of("rtc", "start")[1]!.viewer as string;
    expect(viewerB).not.toBe(viewerA);
    // WebRTC viewers stay out of the WebSocket streams.
    expect(lastStreams(mac).map((s) => s.udid)).toEqual(["SIM-B"]);

    // The Mac's offer reaches the viewer it names, with the same ICE servers, and nobody else.
    mac.ws.send(JSON.stringify({ type: "rtc", action: "offer", viewer: viewerA, sdp: "v=0 offer-a" }));
    mac.ws.send(JSON.stringify({ type: "rtc", action: "offer", viewer: "nobody", sdp: "v=0 stray" }));
    mac.ws.send(JSON.stringify({ type: "rtc", action: "offer", sdp: "v=0 no viewer" }));
    mac.ws.send(JSON.stringify({ type: "rtc", action: "candidate", viewer: viewerB, candidate: "candidate:1 1 udp 1 192.168.1.2 5000 typ host", sdpMid: "0", sdpMLineIndex: 0 }));
    await settle();
    expect(a.of("rtc")).toEqual([{ type: "rtc", action: "offer", viewer: viewerA, sdp: "v=0 offer-a", iceServers: [{ urls: "stun:stun.cloudflare.com:3478" }] }]);
    expect(b.of("rtc")).toEqual([{ type: "rtc", action: "candidate", viewer: viewerB, candidate: "candidate:1 1 udp 1 192.168.1.2 5000 typ host", sdpMid: "0", sdpMLineIndex: 0 }]);
    expect(c.of("rtc")).toEqual([]);

    // Answers and candidates go to the Mac tagged with the sender's own id, whatever the page says.
    mac.clear();
    a.ws.send(JSON.stringify({ type: "rtc", action: "answer", sdp: "v=0 answer-a", viewer: viewerB }));
    a.ws.send(JSON.stringify({ type: "rtc", action: "candidate", candidate: null, sdpMid: null, sdpMLineIndex: null, viewer: viewerB }));
    // A viewer without a peer connection can't send signaling, and pages can't send offers.
    c.ws.send(JSON.stringify({ type: "rtc", action: "answer", sdp: "v=0 answer-c" }));
    a.ws.send(JSON.stringify({ type: "rtc", action: "offer", sdp: "v=0 offer from a page" }));
    await settle();
    expect(mac.of("rtc")).toEqual([
      { type: "rtc", action: "answer", viewer: viewerA, sdp: "v=0 answer-a" },
      { type: "rtc", action: "candidate", viewer: viewerA, candidate: null, sdpMid: null, sdpMLineIndex: null },
    ]);

    // Frames for a stream go to its WebSocket viewers only.
    const key = new TextEncoder().encode("SIM-A");
    b.clear();
    mac.ws.send(new Uint8Array([2, 0, 0, 0, 1, key.length, ...key, 0xff, 0xd8]));
    await settle();
    expect(b.binary()).toBe(0);

    // Switching device: the old peer connection is stopped before the new one starts.
    mac.clear();
    a.ws.send(JSON.stringify({ type: "rtc", action: "start", device: "SIM-B", fps: 30, quality: 55, scale: 0.5 }));
    await settle();
    expect(mac.of("rtc").map((m) => [m.action, m.viewer, m.key])).toEqual([["stop", viewerA, undefined], ["start", viewerA, "SIM-B"]]);

    // Falling back to the WebSocket stream stops the peer connection and puts the viewer back in the streams.
    mac.clear();
    b.ws.send(JSON.stringify({ type: "rtc", action: "stop" }));
    b.ws.send(JSON.stringify({ type: "stream", device: "SIM-A", codec: "h264", fps: 30, quality: 55, scale: 0.5 }));
    await settle();
    expect(mac.of("rtc")).toEqual([{ type: "rtc", action: "stop", viewer: viewerB }]);
    expect(lastStreams(mac)).toEqual(expect.arrayContaining([expect.objectContaining({ udid: "SIM-A", codec: "h264" })]));

    // An error from the Mac reaches the viewer and ends its peer connection: later signaling for it is dropped.
    mac.ws.send(JSON.stringify({ type: "rtc", action: "error", viewer: viewerA, message: "no encoder" }));
    await settle();
    expect(a.of("rtc", "error")).toEqual([{ type: "rtc", action: "error", viewer: viewerA, message: "no encoder" }]);
    mac.ws.send(JSON.stringify({ type: "rtc", action: "offer", viewer: viewerA, sdp: "v=0 late" }));
    await settle();
    expect(a.of("rtc", "offer").map((m) => m.sdp)).toEqual(["v=0 offer-a"]);

    // A viewer that leaves while on WebRTC has its peer connection stopped.
    a.ws.send(JSON.stringify({ type: "rtc", action: "start", device: "SIM-B", fps: 30, quality: 55, scale: 0.5 }));
    await settle();
    mac.clear();
    a.ws.close();
    await settle();
    expect(mac.of("rtc")).toEqual([{ type: "rtc", action: "stop", viewer: viewerA }]);
    // b fell back, so closing it stops nothing.
    mac.clear();
    b.ws.close();
    await settle();
    expect(mac.of("rtc")).toEqual([]);

    c.ws.close();
    mac.ws.close();
  });

  it("tells a viewer when the Mac can't do WebRTC", async () => {
    const cookie = await login();
    const mac = await macWith({ version: 5 });
    const viewer = await openViewer(cookie, "device=SIM-A&rtc=1");
    expect(viewer.of("status")[0]).toMatchObject({ online: true, webrtc: false });
    viewer.ws.send(JSON.stringify({ type: "rtc", action: "start", device: "SIM-A", fps: 30, quality: 55, scale: 0.5 }));
    await settle();
    expect(viewer.of("rtc", "error")).toHaveLength(1);
    expect(mac.of("rtc")).toEqual([]);
    viewer.ws.close();
    mac.ws.close();
  });
});

describe("ICE servers", () => {
  const TURN_RESPONSE = {
    iceServers: [
      { urls: ["stun:stun.cloudflare.com:3478", "stun:stun.cloudflare.com:53"] },
      {
        urls: [
          "turn:turn.cloudflare.com:3478?transport=udp", "turn:turn.cloudflare.com:53?transport=udp",
          "turn:turn.cloudflare.com:3478?transport=tcp", "turns:turn.cloudflare.com:5349?transport=tcp",
          "turn:turn.cloudflare.com:80?transport=tcp", "turns:turn.cloudflare.com:443?transport=tcp",
        ],
        username: "user-1",
        credential: "secret-1",
      },
    ],
  };
  const SECRETS = { TURN_KEY_ID: "key-id", TURN_KEY_API_TOKEN: "api-token" };

  function mockFetch(respond: () => Response | Promise<Response>) {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const fetcher = (async (url: string, init: RequestInit) => {
      calls.push({ url, init });
      return respond();
    }) as unknown as typeof fetch;
    return { calls, fetcher };
  }

  it("is STUN only without the TURN secrets", async () => {
    const { calls, fetcher } = mockFetch(() => Response.json(TURN_RESPONSE, { status: 201 }));
    expect(await iceServers({}, { turn: null }, fetcher)).toEqual([STUN]);
    expect(await iceServers({ TURN_KEY_ID: "key-id" }, { turn: null }, fetcher)).toEqual([STUN]);
    expect(calls).toHaveLength(0);
  });

  it("adds Cloudflare TURN credentials when the secrets are set, and caches them", async () => {
    const { calls, fetcher } = mockFetch(() => Response.json(TURN_RESPONSE, { status: 201 }));
    const cache = { turn: null };
    const now = 1_000_000;
    const servers = await iceServers(SECRETS, cache, fetcher, now);
    expect(calls).toHaveLength(1);
    expect(calls[0]!.url).toBe("https://rtc.live.cloudflare.com/v1/turn/keys/key-id/credentials/generate-ice-servers");
    expect(calls[0]!.init.method).toBe("POST");
    expect((calls[0]!.init.headers as Record<string, string>).Authorization).toBe("Bearer api-token");
    expect(JSON.parse(calls[0]!.init.body as string)).toEqual({ ttl: TURN_TTL_SECONDS });
    // STUN once, then the TURN entry without the port 53 URL browsers block.
    expect(servers).toEqual([
      STUN,
      {
        urls: [
          "turn:turn.cloudflare.com:3478?transport=udp", "turn:turn.cloudflare.com:3478?transport=tcp",
          "turns:turn.cloudflare.com:5349?transport=tcp", "turn:turn.cloudflare.com:80?transport=tcp",
          "turns:turn.cloudflare.com:443?transport=tcp",
        ],
        username: "user-1",
        credential: "secret-1",
      },
    ]);

    // Cached until shortly before they expire, then fetched again.
    const expiry = now + TURN_TTL_SECONDS * 1000;
    expect(await iceServers(SECRETS, cache, fetcher, expiry - TURN_REFRESH_MS - 1)).toEqual(servers);
    expect(calls).toHaveLength(1);
    await iceServers(SECRETS, cache, fetcher, expiry - TURN_REFRESH_MS);
    expect(calls).toHaveLength(2);
  });

  it("shares one request between viewers starting together", async () => {
    const { calls, fetcher } = mockFetch(() => Response.json(TURN_RESPONSE, { status: 201 }));
    const cache = { turn: null };
    const [one, two] = await Promise.all([iceServers(SECRETS, cache, fetcher), iceServers(SECRETS, cache, fetcher)]);
    expect(calls).toHaveLength(1);
    expect(one).toEqual(two);
    expect(one).toHaveLength(2);
  });

  it("falls back to STUN only when the TURN API fails, and tries again later", async () => {
    let fail = true;
    const { calls, fetcher } = mockFetch(() => fail ? new Response("Unauthorized", { status: 401 }) : Response.json(TURN_RESPONSE, { status: 201 }));
    const cache = { turn: null };
    expect(await iceServers(SECRETS, cache, fetcher, 0)).toEqual([STUN]);
    expect(await iceServers(SECRETS, cache, fetcher, TURN_RETRY_MS - 1)).toEqual([STUN]);
    expect(calls).toHaveLength(1);
    fail = false;
    expect(await iceServers(SECRETS, cache, fetcher, TURN_RETRY_MS)).toHaveLength(2);
    expect(calls).toHaveLength(2);

    // A network error or a response with no TURN entry is the same.
    const thrown = mockFetch(() => { throw new Error("network down"); });
    expect(await iceServers(SECRETS, { turn: null }, thrown.fetcher)).toEqual([STUN]);
    const empty = mockFetch(() => Response.json({ iceServers: [{ urls: "stun:stun.cloudflare.com:3478" }] }, { status: 201 }));
    expect(await iceServers(SECRETS, { turn: null }, empty.fetcher)).toEqual([STUN]);
  });
});
