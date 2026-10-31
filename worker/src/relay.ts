import { DurableObject } from "cloudflare:workers";
import type { Env } from "./env";

/** MCP tool result shape, as produced by the Mac. */
export interface ToolResult {
  content: Array<{ type: "text"; text: string } | { type: "image"; data: string; mimeType: string }>;
  isError?: boolean;
}

export interface ToolDefinition {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

interface Hello {
  type: "hello";
  version: number;
  host: Record<string, string>;
  tools: ToolDefinition[];
  /** Random per run of `minirun serve`, so a reconnect can be told apart from a restart. */
  instance?: string;
}

type Codec = "jpeg" | "h264";

interface StreamSettings {
  fps: number;
  quality: number;
  scale: number;
  /** What the viewer can decode. A stream is H.264 only if all its viewers can decode it. */
  codec: Codec;
}

/** What a viewer is watching, kept on its socket so it survives hibernation. */
interface ViewerState extends StreamSettings {
  /** The simulator UDID or Mac app id the viewer asked for, or "" for whichever simulator is booted. */
  key: string;
}

/**
 * A booted simulator or a running Mac app, as the Mac reports it. Mac apps (protocol 5) have
 * kind "mac", their id (e.g. "mac-3f9a2c") in udid and the workspace they're for in reserved_for.
 */
export interface SimulatorInfo {
  udid: string;
  kind?: "simulator" | "mac";
  name: string;
  runtime?: string;
  reserved_for?: string;
  last_app?: string;
}

interface Pending {
  tool: string;
  resolve: (result: ToolResult) => void;
  timer: ReturnType<typeof setTimeout>;
}

/** Tools the viewer may call directly (fire-and-forget input). */
const VIEWER_TOOLS = new Set([
  "tap", "swipe", "long_press", "type_text", "press_key", "press_button", "open_url",
  // Mac apps (protocol 5): wheel scrolling and menu commands.
  "scroll", "press_menu_item",
]);

/** Phases of a live touch from the viewer. */
const TOUCH_PHASES = new Set(["down", "move", "up"]);

/** The first Mac protocol version that takes live touches. */
const TOUCH_VERSION = 4;

/** Frames a viewer may have in flight before we skip frames for it. */
const VIEWER_WINDOW = 3;

/**
 * The same for H.264, whose frames are smaller. Skipping one breaks the picture until the next
 * keyframe, so it's set above the Mac's own window (6) and only a lagging viewer hits it.
 */
const VIDEO_WINDOW = 10;

/** How often a stream's viewers may ask the Mac for a keyframe. */
const KEYFRAME_INTERVAL_MS = 500;

/** Longest a tool call may take. Mac jobs return within their wait_seconds (max 50); this is a backstop. */
const CALL_TIMEOUT_MS = 11 * 60 * 1000;

/**
 * How long calls wait for the Mac to reconnect after its connection drops. The Mac keeps running
 * them meanwhile and hands over their results once it's back.
 */
const RECONNECT_GRACE_MS = 60 * 1000;

const DEFAULT_STREAM: StreamSettings = { fps: 12, quality: 60, scale: 0.5, codec: "jpeg" };

const decoder = new TextDecoder();

/** Simulator UDIDs and Mac app ids like "mac-3f9a2c" (and "" for the default stream). Anything else is ignored. */
export function streamKey(value: unknown): string | null {
  if (value === undefined || value === null || value === "") return "";
  return typeof value === "string" && /^[A-Za-z0-9-]{1,64}$/.test(value) ? value : null;
}

/**
 * One Durable Object per Mac. It holds the Mac's WebSocket ("agent") and any browser viewers,
 * forwards MCP tool calls to the Mac, and fans video frames out to viewers. Each viewer watches
 * one simulator or Mac app window; the Mac runs one stream per one being watched.
 *
 * Uses the WebSocket Hibernation API, so an idle connection costs nothing.
 */
export class MacRelay extends DurableObject<Env> {
  private pending = new Map<string, Pending>();
  /** Fails the pending calls if the Mac doesn't reconnect in time. */
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  /**
   * Per-viewer flow control: last frame sent, last frame acknowledged, and whether the viewer
   * must wait for an H.264 keyframe (it just joined, or missed a frame).
   */
  private viewerFrames = new Map<WebSocket, FlowState>();
  /** When each stream last asked the Mac for a keyframe. */
  private keyframeRequested = new Map<string, number>();
  /** Where each viewer's finger is down, so it can be lifted if the viewer goes away mid-touch. */
  private touching = new Map<WebSocket, { device: string; x: number; y: number }>();
  /** The Cloudflare data center this object runs in (e.g. "ATL"), looked up once. */
  private location: Promise<string | null> | null = null;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // Answer keep-alive pings without waking the object.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    switch (url.pathname) {
      case "/agent":
        return this.acceptSocket(request, "agent");
      case "/viewer":
        return this.acceptSocket(request, "viewer");
      default:
        return new Response("Not found", { status: 404 });
    }
  }

  // MARK: RPC used by the Worker

  async status(): Promise<{
    online: boolean;
    host: Record<string, string> | null;
    /** Whether the Mac takes live touches (otherwise the viewer sends whole gestures). */
    touch: boolean;
    /** Where this relay runs. Every frame and touch passes through it, so it should be near the Mac and viewers. */
    location: string | null;
    viewers: number;
    connectedAt: number | null;
    toolCount: number;
    simulators: SimulatorInfo[] | null;
  }> {
    const hello = await this.ctx.storage.get<Hello>("hello");
    const agent = this.agent();
    return {
      online: agent !== null,
      host: hello?.host ?? null,
      touch: (hello?.version ?? 0) >= TOUCH_VERSION,
      location: await this.dataCenter(),
      viewers: this.viewers().length,
      connectedAt: (await this.ctx.storage.get<number>("connectedAt")) ?? null,
      toolCount: hello?.tools.length ?? 0,
      // Only as fresh as the last time someone watched; the Mac sends it while streaming.
      simulators: (await this.ctx.storage.get<SimulatorInfo[]>("simulators")) ?? null,
    };
  }

  /** The data center this object runs in, from Cloudflare's trace page (fetched from here). */
  private dataCenter(): Promise<string | null> {
    this.location ??= fetch("https://www.cloudflare.com/cdn-cgi/trace")
      .then((response) => response.text())
      .then((text) => {
        const colo = /^colo=(\w+)$/m.exec(text)?.[1] ?? null;
        if (!colo) console.log("relay location: unexpected trace", text.slice(0, 200));
        return colo;
      })
      .catch((error) => {
        console.log("relay location lookup failed", String(error));
        return null;
      });
    return this.location;
  }

  /** Tool definitions from the Mac's last hello (kept so tools/list works while it's offline). */
  async tools(): Promise<ToolDefinition[]> {
    return (await this.ctx.storage.get<Hello>("hello"))?.tools ?? [];
  }

  async call(tool: string, args: unknown): Promise<ToolResult> {
    const agent = this.agent();
    if (!agent) {
      return {
        isError: true,
        content: [{ type: "text", text: "The Mac is offline. Check that it's awake and that `minirun serve` is running (launchctl list | grep minirun)." }],
      };
    }
    const id = crypto.randomUUID();
    const result = new Promise<ToolResult>((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        resolve({ isError: true, content: [{ type: "text", text: `${tool} didn't answer within ${CALL_TIMEOUT_MS / 60000} minutes.` }] });
      }, CALL_TIMEOUT_MS);
      this.pending.set(id, { tool, resolve, timer });
    });
    agent.send(JSON.stringify({ type: "call", id, tool, arguments: args ?? {} }));
    return result;
  }

  // MARK: WebSockets

  private acceptSocket(request: Request, role: "agent" | "viewer"): Response {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected a WebSocket upgrade", { status: 426 });
    }
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];

    if (role === "agent") {
      // A new Mac connection replaces any old one (e.g. after a network change).
      for (const old of this.ctx.getWebSockets("agent")) old.close(4000, "Replaced by a new connection");
      this.ctx.acceptWebSocket(server, ["agent"]);
      this.ctx.waitUntil(this.ctx.storage.put("connectedAt", Date.now()));
    } else {
      const key = streamKey(new URL(request.url).searchParams.get("device")) ?? "";
      this.ctx.acceptWebSocket(server, ["viewer"]);
      server.serializeAttachment({ key, ...DEFAULT_STREAM } satisfies ViewerState);
      this.viewerFrames.set(server, newFlow());
      this.ctx.waitUntil(this.greetViewer(server));
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  private agent(): WebSocket | null {
    return this.ctx.getWebSockets("agent")[0] ?? null;
  }

  private viewers(): WebSocket[] {
    return this.ctx.getWebSockets("viewer");
  }

  private role(ws: WebSocket): "agent" | "viewer" {
    return this.ctx.getTags(ws).includes("agent") ? "agent" : "viewer";
  }

  private viewerState(ws: WebSocket): ViewerState {
    // Attachments from before a setting existed get its default.
    return { key: "", ...DEFAULT_STREAM, ...(ws.deserializeAttachment() as Partial<ViewerState> | null) };
  }

  private async greetViewer(ws: WebSocket) {
    const status = await this.status();
    safeSend(ws, JSON.stringify({ type: "status", online: status.online, host: status.host, touch: status.touch }));
    if (status.simulators) safeSend(ws, JSON.stringify({ type: "simulators", devices: status.simulators }));
    const screen = await this.ctx.storage.get<string>(`screen:${this.viewerState(ws).key}`);
    if (screen) safeSend(ws, screen);
    this.syncStreams();
    this.requestKeyframe(this.viewerState(ws).key, true);
  }

  /** Asks the Mac for an H.264 keyframe on stream `key`, at most every KEYFRAME_INTERVAL_MS unless `now`. */
  private requestKeyframe(key: string, now = false) {
    const last = this.keyframeRequested.get(key) ?? 0;
    if (!now && Date.now() - last < KEYFRAME_INTERVAL_MS) return;
    this.keyframeRequested.set(key, Date.now());
    this.agent()?.send(JSON.stringify({ type: "keyframe", key }));
  }

  /** Tells the Mac which simulators to stream: one stream per simulator someone is watching. */
  private syncStreams(leaving?: WebSocket) {
    const agent = this.agent();
    if (!agent) return;
    const streams = new Map<string, ViewerState>();
    for (const viewer of this.viewers()) {
      if (viewer === leaving) continue;
      const state = this.viewerState(viewer);
      // The newest viewer's settings win, but one viewer without H.264 keeps the stream JPEG.
      const codec = streams.get(state.key)?.codec === "jpeg" ? "jpeg" : state.codec;
      streams.set(state.key, { ...state, codec });
    }
    if (streams.size === 0) {
      agent.send(JSON.stringify({ type: "stream", action: "stop" }));
      return;
    }
    const list = [...streams.values()].map(({ key, fps, quality, scale, codec }) => ({ udid: key || null, fps, quality, scale, codec }));
    agent.send(JSON.stringify({ type: "stream", action: "set", streams: list }));
  }

  private broadcast(message: string, key?: string) {
    for (const viewer of this.viewers()) {
      if (key === undefined || this.viewerState(viewer).key === key) safeSend(viewer, message);
    }
  }

  /** The simulator a viewer's input should go to: the one it's watching. */
  private async viewerDevice(ws: WebSocket): Promise<string | null> {
    const { key } = this.viewerState(ws);
    if (key) return key;
    const screen = await this.ctx.storage.get<string>("screen:");
    if (!screen) return null;
    try {
      return (JSON.parse(screen) as { udid?: string }).udid ?? null;
    } catch {
      return null;
    }
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer) {
    if (this.role(ws) === "agent") {
      if (typeof message === "string") await this.onAgentText(message);
      else this.onFrame(message);
    } else if (typeof message === "string") {
      await this.onViewerText(ws, message);
    }
  }

  private async onAgentText(text: string) {
    let message: { type?: string; [key: string]: unknown };
    try {
      message = JSON.parse(text);
    } catch {
      return;
    }
    switch (message.type) {
      case "hello": {
        const hello = message as unknown as Hello;
        const previous = await this.ctx.storage.get<Hello>("hello");
        await this.ctx.storage.put("hello", hello);
        // Tells the Mac which code this Worker runs, so it can say when the Worker needs updating.
        this.agent()?.send(JSON.stringify({ type: "welcome", bundle: this.env.MINIRUN_BUNDLE ?? null }));
        this.broadcast(JSON.stringify({ type: "status", online: true, host: hello.host, touch: hello.version >= TOUCH_VERSION }));
        this.syncStreams();
        this.recoverPending(hello.instance !== undefined && hello.instance === previous?.instance);
        break;
      }
      case "result": {
        const id = String(message.id);
        const pending = this.pending.get(id);
        if (pending) {
          clearTimeout(pending.timer);
          this.pending.delete(id);
          pending.resolve(message.result as ToolResult);
        }
        break;
      }
      case "screen": {
        const key = streamKey(message.key) ?? "";
        await this.ctx.storage.put(`screen:${key}`, text);
        this.broadcast(text, key);
        break;
      }
      case "stream_status":
        this.broadcast(text, streamKey(message.key) ?? "");
        break;
      case "simulators":
        await this.ctx.storage.put("simulators", Array.isArray(message.devices) ? message.devices : []);
        this.broadcast(text);
        break;
    }
  }

  private onFrame(frame: ArrayBuffer) {
    if (frame.byteLength < 5) return;
    const bytes = new Uint8Array(frame);
    // Kind 1: a JPEG of the default stream. Kind 2: a JPEG with [keyLength][key] after the
    // sequence number. Kind 3: H.264, with [keyLength][key][flags] (bit 0 = keyframe).
    let key = "";
    const video = bytes[0] === 3;
    if (bytes[0] === 2 || video) {
      if (frame.byteLength < 6 + bytes[5]! + (video ? 1 : 0)) return;
      key = decoder.decode(bytes.subarray(6, 6 + bytes[5]!));
    } else if (bytes[0] !== 1) {
      return;
    }
    const keyframe = video && (bytes[6 + bytes[5]!]! & 1) === 1;
    const sequence = new DataView(frame).getUint32(1);
    for (const viewer of this.viewers()) {
      const viewerState = this.viewerState(viewer);
      if (viewerState.key !== key) continue;
      // A JPEG-only viewer can't show H.264; the stream switches to JPEG for it shortly.
      if (video && viewerState.codec !== "h264") continue;
      let state = this.viewerFrames.get(viewer);
      if (!state) {
        state = newFlow();
        this.viewerFrames.set(viewer, state);
      }
      if (video) {
        // H.264 frames depend on the ones before, so a viewer that missed one waits for a keyframe.
        if (state.needsKeyframe && !keyframe) {
          this.requestKeyframe(key);
          continue;
        }
        if (state.sent - state.acked >= VIDEO_WINDOW) {
          state.needsKeyframe = true;
          this.requestKeyframe(key);
          continue;
        }
      } else if (state.sent - state.acked >= VIEWER_WINDOW) {
        // Skip this frame for viewers that are falling behind; they'll get a fresher one.
        continue;
      }
      if (safeSend(viewer, frame)) {
        state.sent = sequence;
        if (video) state.needsKeyframe = false;
      }
      if (state.acked === 0) state.acked = sequence - 1;
    }
  }

  private async onViewerText(ws: WebSocket, text: string) {
    let message: { type?: string; [key: string]: unknown };
    try {
      message = JSON.parse(text);
    } catch {
      return;
    }
    switch (message.type) {
      case "ack": {
        const seq = Number(message.seq) || 0;
        const state = this.viewerFrames.get(ws);
        if (state && seq > state.acked) state.acked = seq;
        this.agent()?.send(JSON.stringify({ type: "ack", seq, key: this.viewerState(ws).key }));
        break;
      }
      case "keyframe": {
        // The viewer's decoder lost its place (e.g. after an error).
        const state = this.viewerFrames.get(ws);
        if (state) state.needsKeyframe = true;
        this.requestKeyframe(this.viewerState(ws).key);
        break;
      }
      case "input": {
        const tool = String(message.tool);
        if (!VIEWER_TOOLS.has(tool)) return;
        // Input always goes to the simulator or Mac app this viewer is watching, never a guess.
        const device = await this.viewerDevice(ws);
        if (!device) return;
        const args = typeof message.arguments === "object" && message.arguments !== null ? message.arguments : {};
        this.agent()?.send(JSON.stringify({ type: "call", tool, arguments: { ...args, device } }));
        break;
      }
      case "touch": {
        const { phase, x, y } = message;
        if (typeof phase !== "string" || !TOUCH_PHASES.has(phase)) return;
        if (typeof x !== "number" || typeof y !== "number" || !Number.isFinite(x) || !Number.isFinite(y)) return;
        // Like input, a touch only reaches the simulator this viewer is watching.
        const device = await this.viewerDevice(ws);
        if (!device) return;
        if (phase === "up") this.touching.delete(ws);
        else this.touching.set(ws, { device, x, y });
        this.agent()?.send(JSON.stringify({ type: "touch", device, phase, x, y }));
        break;
      }
      case "stream": {
        const previous = this.viewerState(ws);
        const key = "device" in message ? streamKey(message.device) ?? previous.key : previous.key;
        const state: ViewerState = {
          key,
          fps: clamp(Number(message.fps) || DEFAULT_STREAM.fps, 1, 30),
          quality: clamp(Number(message.quality) || DEFAULT_STREAM.quality, 10, 95),
          scale: clamp(Number(message.scale) || DEFAULT_STREAM.scale, 0.2, 1),
          codec: message.codec === "h264" ? "h264" : "jpeg",
        };
        ws.serializeAttachment(state);
        if (key !== previous.key) {
          // A different simulator: restart flow control and show its last known screen.
          this.viewerFrames.set(ws, newFlow());
          const screen = await this.ctx.storage.get<string>(`screen:${key}`);
          if (screen) safeSend(ws, screen);
        }
        this.syncStreams();
        if (key !== previous.key || state.codec !== previous.codec) this.requestKeyframe(key, true);
        break;
      }
    }
  }

  async webSocketClose(ws: WebSocket, code: number) {
    await this.dropSocket(ws, code);
  }

  async webSocketError(ws: WebSocket) {
    await this.dropSocket(ws, 1011);
  }

  private async dropSocket(ws: WebSocket, code: number) {
    const role = this.role(ws);
    try {
      ws.close(code === 1005 || code === 1006 ? 1000 : code);
    } catch {
      // already closed
    }
    if (role === "agent") {
      // Only report offline if this wasn't replaced by a newer connection.
      if (this.ctx.getWebSockets("agent").every((other) => other === ws)) {
        if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
        this.reconnectTimer = setTimeout(() => {
          this.reconnectTimer = null;
          this.failPending((tool) =>
            `The Mac lost its connection while running ${tool} and hasn't reconnected. It may have finished anyway: ` +
            "check (e.g. list_jobs, list_simulators) before trying again.");
        }, RECONNECT_GRACE_MS);
        this.broadcast(JSON.stringify({ type: "status", online: false }));
      }
    } else {
      const held = this.touching.get(ws);
      if (held) {
        this.touching.delete(ws);
        this.agent()?.send(JSON.stringify({ type: "touch", phase: "up", ...held }));
      }
      this.viewerFrames.delete(ws);
      this.syncStreams(ws);
    }
  }

  /**
   * Picks up the calls that were in flight when the Mac reconnects. The same run of minirun still
   * has them (running, or with a result it couldn't send), so it's asked to answer them; a
   * restarted one lost them, as did a Mac too old to say which run it is.
   */
  private recoverPending(sameInstance: boolean) {
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
    if (this.pending.size === 0) return;
    if (sameInstance) {
      this.agent()?.send(JSON.stringify({ type: "pending", ids: [...this.pending.keys()] }));
    } else {
      this.failPending((tool) =>
        `minirun on the Mac restarted while running ${tool}, so it may not have finished. ` +
        "Check (e.g. list_jobs, list_simulators) before trying again.");
    }
  }

  private failPending(message: (tool: string) => string) {
    for (const [id, pending] of this.pending) {
      clearTimeout(pending.timer);
      pending.resolve({ isError: true, content: [{ type: "text", text: message(pending.tool) }] });
      this.pending.delete(id);
    }
  }
}

interface FlowState {
  sent: number;
  acked: number;
  needsKeyframe: boolean;
}

function newFlow(): FlowState {
  return { sent: 0, acked: 0, needsKeyframe: true };
}

function safeSend(ws: WebSocket, data: string | ArrayBuffer): boolean {
  try {
    ws.send(data);
    return true;
  } catch {
    return false;
  }
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}
