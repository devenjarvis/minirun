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

/**
 * One Durable Object per Mac. It holds the Mac's WebSocket ("agent") and any browser viewers,
 * forwards MCP tool calls to the Mac, and fans video frames out to viewers.
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

  async status(): Promise<{ online: boolean; host: Record<string, string> | null; viewers: number; connectedAt: number | null; toolCount: number }> {
    const hello = await this.ctx.storage.get<Hello>("hello");
    const agent = this.agent();
    return {
      online: agent !== null,
      host: hello?.host ?? null,
      viewers: this.viewers().length,
      connectedAt: (await this.ctx.storage.get<number>("connectedAt")) ?? null,
      toolCount: hello?.tools.length ?? 0,
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
      this.ctx.acceptWebSocket(server, ["viewer"]);
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

  private async greetViewer(ws: WebSocket) {
    const status = await this.status();
    safeSend(ws, JSON.stringify({ type: "status", online: status.online, host: status.host }));
    const screen = await this.ctx.storage.get<string>("screen");
    if (screen) safeSend(ws, screen);
    if (status.online) this.startStream();
  }

  private async startStream() {
    const settings = (await this.ctx.storage.get<StreamSettings>("stream")) ?? DEFAULT_STREAM;
    this.agent()?.send(JSON.stringify({ type: "stream", action: "start", ...settings }));
  }

  private broadcast(message: string) {
    for (const viewer of this.viewers()) safeSend(viewer, message);
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
        if (this.viewers().length > 0) await this.startStream();
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
      case "screen":
        await this.ctx.storage.put("screen", text);
        this.broadcast(text);
        break;
      case "stream_status":
        this.broadcast(text);
        break;
    }
  }

  private onFrame(frame: ArrayBuffer) {
    if (frame.byteLength < 5) return;
    const sequence = new DataView(frame).getUint32(1);
    for (const viewer of this.viewers()) {
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
        this.agent()?.send(JSON.stringify({ type: "ack", seq }));
        break;
      }
      case "input": {
        const tool = String(message.tool);
        if (!VIEWER_TOOLS.has(tool)) return;
        this.agent()?.send(JSON.stringify({ type: "call", tool, arguments: message.arguments ?? {} }));
        break;
      }
      case "stream": {
        const settings: StreamSettings = {
          fps: clamp(Number(message.fps) || DEFAULT_STREAM.fps, 1, 30),
          quality: clamp(Number(message.quality) || DEFAULT_STREAM.quality, 10, 95),
          scale: clamp(Number(message.scale) || DEFAULT_STREAM.scale, 0.2, 1),
        };
        await this.ctx.storage.put("stream", settings);
        await this.startStream();
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
      const remaining = this.viewers().filter((other) => other !== ws);
      if (remaining.length === 0) this.agent()?.send(JSON.stringify({ type: "stream", action: "stop" }));
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
