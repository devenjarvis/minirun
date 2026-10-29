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
}

interface StreamSettings {
  fps: number;
  quality: number;
  scale: number;
}

/** What a viewer is watching, kept on its socket so it survives hibernation. */
interface ViewerState extends StreamSettings {
  /** The simulator UDID the viewer asked for, or "" for whichever simulator is booted. */
  key: string;
}

/** A booted simulator, as the Mac reports it. */
export interface SimulatorInfo {
  udid: string;
  name: string;
  runtime?: string;
  reserved_for?: string;
  last_app?: string;
}

interface Pending {
  resolve: (result: ToolResult) => void;
  timer: ReturnType<typeof setTimeout>;
}

/** Tools the viewer may call directly (fire-and-forget input). */
const VIEWER_TOOLS = new Set(["tap", "swipe", "long_press", "type_text", "press_key", "press_button", "open_url"]);

/** Frames a viewer may have in flight before we skip frames for it. */
const VIEWER_WINDOW = 3;

/** Longest a tool call may take. Mac jobs return within their wait_seconds (max 600). */
const CALL_TIMEOUT_MS = 11 * 60 * 1000;

const DEFAULT_STREAM: StreamSettings = { fps: 12, quality: 60, scale: 0.5 };

const decoder = new TextDecoder();

/** Simulator UDIDs (and "" for the default stream). Anything else is ignored. */
export function streamKey(value: unknown): string | null {
  if (value === undefined || value === null || value === "") return "";
  return typeof value === "string" && /^[A-Za-z0-9-]{1,64}$/.test(value) ? value : null;
}

/**
 * One Durable Object per Mac. It holds the Mac's WebSocket ("agent") and any browser viewers,
 * forwards MCP tool calls to the Mac, and fans video frames out to viewers. Each viewer watches
 * one simulator; the Mac runs one stream per simulator being watched.
 *
 * Uses the WebSocket Hibernation API, so an idle connection costs nothing.
 */
export class MacRelay extends DurableObject<Env> {
  private pending = new Map<string, Pending>();
  /** Per-viewer flow control: last frame sent and last frame acknowledged. */
  private viewerFrames = new Map<WebSocket, { sent: number; acked: number }>();

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
      viewers: this.viewers().length,
      connectedAt: (await this.ctx.storage.get<number>("connectedAt")) ?? null,
      toolCount: hello?.tools.length ?? 0,
      // Only as fresh as the last time someone watched; the Mac sends it while streaming.
      simulators: (await this.ctx.storage.get<SimulatorInfo[]>("simulators")) ?? null,
    };
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
      this.pending.set(id, { resolve, timer });
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
      this.viewerFrames.set(server, { sent: 0, acked: 0 });
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
    return (ws.deserializeAttachment() as ViewerState | null) ?? { key: "", ...DEFAULT_STREAM };
  }

  private async greetViewer(ws: WebSocket) {
    const status = await this.status();
    safeSend(ws, JSON.stringify({ type: "status", online: status.online, host: status.host }));
    if (status.simulators) safeSend(ws, JSON.stringify({ type: "simulators", devices: status.simulators }));
    const screen = await this.ctx.storage.get<string>(`screen:${this.viewerState(ws).key}`);
    if (screen) safeSend(ws, screen);
    this.syncStreams();
  }

  /** Tells the Mac which simulators to stream: one stream per simulator someone is watching. */
  private syncStreams(leaving?: WebSocket) {
    const agent = this.agent();
    if (!agent) return;
    const streams = new Map<string, ViewerState>();
    for (const viewer of this.viewers()) {
      if (viewer === leaving) continue;
      const state = this.viewerState(viewer);
      streams.set(state.key, state);
    }
    if (streams.size === 0) {
      agent.send(JSON.stringify({ type: "stream", action: "stop" }));
      return;
    }
    const list = [...streams.values()].map(({ key, fps, quality, scale }) => ({ udid: key || null, fps, quality, scale }));
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
        await this.ctx.storage.put("hello", message as unknown as Hello);
        this.broadcast(JSON.stringify({ type: "status", online: true, host: (message as unknown as Hello).host }));
        this.syncStreams();
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
    // Kind 1: the default stream. Kind 2: [keyLength][key] follows the sequence number.
    let key = "";
    if (bytes[0] === 2) {
      if (frame.byteLength < 6 || frame.byteLength < 6 + bytes[5]!) return;
      key = decoder.decode(bytes.subarray(6, 6 + bytes[5]!));
    } else if (bytes[0] !== 1) {
      return;
    }
    const sequence = new DataView(frame).getUint32(1);
    for (const viewer of this.viewers()) {
      if (this.viewerState(viewer).key !== key) continue;
      let state = this.viewerFrames.get(viewer);
      if (!state) {
        state = { sent: 0, acked: 0 };
        this.viewerFrames.set(viewer, state);
      }
      // Skip this frame for viewers that are falling behind; they'll get a fresher one.
      if (state.sent - state.acked >= VIEWER_WINDOW) continue;
      if (safeSend(viewer, frame)) state.sent = sequence;
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
      case "input": {
        const tool = String(message.tool);
        if (!VIEWER_TOOLS.has(tool)) return;
        // Input always goes to the simulator this viewer is watching, never a guess.
        const device = await this.viewerDevice(ws);
        if (!device) return;
        const args = typeof message.arguments === "object" && message.arguments !== null ? message.arguments : {};
        this.agent()?.send(JSON.stringify({ type: "call", tool, arguments: { ...args, device } }));
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
        };
        ws.serializeAttachment(state);
        if (key !== previous.key) {
          // A different simulator: restart flow control and show its last known screen.
          this.viewerFrames.set(ws, { sent: 0, acked: 0 });
          const screen = await this.ctx.storage.get<string>(`screen:${key}`);
          if (screen) safeSend(ws, screen);
        }
        this.syncStreams();
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
        for (const [id, pending] of this.pending) {
          clearTimeout(pending.timer);
          pending.resolve({ isError: true, content: [{ type: "text", text: "The Mac disconnected while running this. Try again once it reconnects." }] });
          this.pending.delete(id);
        }
        this.broadcast(JSON.stringify({ type: "status", online: false }));
      }
    } else {
      this.viewerFrames.delete(ws);
      this.syncStreams(ws);
    }
  }
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
