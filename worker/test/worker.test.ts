import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

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
    // Give the Durable Object a moment to store the hello.
    await new Promise((r) => setTimeout(r, 50));

    // Pretend to be the Mac: answer any call.
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
    const mine = await rpc(token, "tools/call", { name: "mac_status", arguments: { device: "ABC-123" } });
    expect(mine.result.content[0].text).toContain(`${ORIGIN}/?device=ABC-123`);
    const bad = await rpc(token, "tools/call", { name: "mac_status", arguments: { device: "../x" } });
    expect(bad.result.isError).toBe(true);

    const call = await rpc(token, "tools/call", { name: "screenshot", arguments: { scale: 0.5 } });
    expect(call.result.content[0].text).toBe('ran screenshot with {"scale":0.5}');
    agent.close();
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
});
