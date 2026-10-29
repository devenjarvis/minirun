import { relayStub, type Env } from "./env";
import type { ToolDefinition, ToolResult } from "./relay";

/**
 * A minimal MCP server over Streamable HTTP (JSON responses, no SSE). Every tool except
 * `mac_status` lives on the Mac; this just forwards `tools/list` and `tools/call` to it.
 */

const SUPPORTED_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
const SERVER_INFO = { name: "minirun", title: "minirun — iOS simulators on your Mac", version: "0.1.0" };

const INSTRUCTIONS = `minirun drives iOS simulators and Xcode on the user's Mac.
Typical loop: push your branch to GitHub, call build_and_run with repo + ref, read any errors (they come back with file:line), fix, push, repeat.
Then exercise the app: describe_ui to find elements, tap by id/label (or x,y in points), type_text, swipe, screenshot to look.
Long builds return a job_id; call get_job to wait for it.
The user can watch and touch the simulator live in their browser — call mac_status for the link.`;

const MAC_STATUS_TOOL: ToolDefinition = {
  name: "mac_status",
  description: "Check whether the Mac is online, and get the link where the user can watch and control the simulator live in a browser.",
  inputSchema: { type: "object", properties: {}, additionalProperties: false },
};

interface RpcRequest {
  jsonrpc: "2.0";
  id?: string | number | null;
  method: string;
  params?: Record<string, unknown>;
}

type RpcResponse = { jsonrpc: "2.0"; id: string | number | null } & ({ result: unknown } | { error: { code: number; message: string } });

export async function handleMcp(request: Request, env: Env): Promise<Response> {
  if (request.method === "GET" || request.method === "DELETE") {
    // No server-initiated stream and no sessions to end.
    return new Response(null, { status: 405, headers: { Allow: "POST" } });
  }
  if (request.method !== "POST") return new Response(null, { status: 405, headers: { Allow: "POST" } });

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return json(rpcError(null, -32700, "Parse error"), 400);
  }

  const origin = new URL(request.url).origin;
  const batch = Array.isArray(body);
  const messages = (batch ? body : [body]) as RpcRequest[];
  const responses: RpcResponse[] = [];
  for (const message of messages) {
    const response = await handleMessage(message, env, origin);
    if (response) responses.push(response);
  }
  if (responses.length === 0) return new Response(null, { status: 202 });
  return json(batch ? responses : responses[0]);
}

async function handleMessage(message: RpcRequest, env: Env, origin: string): Promise<RpcResponse | null> {
  if (!message || message.jsonrpc !== "2.0" || typeof message.method !== "string") {
    return rpcError(message?.id ?? null, -32600, "Invalid request");
  }
  const isNotification = message.id === undefined || message.id === null;
  if (isNotification) return null; // notifications/initialized, cancelled, etc.
  const id = message.id as string | number;

  try {
    switch (message.method) {
      case "initialize": {
        const requested = String(message.params?.protocolVersion ?? "");
        return rpcResult(id, {
          protocolVersion: SUPPORTED_VERSIONS.includes(requested) ? requested : SUPPORTED_VERSIONS[0],
          capabilities: { tools: { listChanged: false } },
          serverInfo: SERVER_INFO,
          instructions: INSTRUCTIONS,
        });
      }
      case "ping":
        return rpcResult(id, {});
      case "tools/list": {
        const tools = await relayStub(env).tools();
        return rpcResult(id, { tools: [MAC_STATUS_TOOL, ...tools] });
      }
      case "tools/call": {
        const name = String(message.params?.name ?? "");
        const args = (message.params?.arguments as Record<string, unknown> | undefined) ?? {};
        if (!name) return rpcError(id, -32602, "Missing tool name");
        if (name === MAC_STATUS_TOOL.name) return rpcResult(id, await macStatus(env, origin));
        const result: ToolResult = await relayStub(env).call(name, args);
        return rpcResult(id, result);
      }
      case "resources/list":
        return rpcResult(id, { resources: [] });
      case "prompts/list":
        return rpcResult(id, { prompts: [] });
      default:
        return rpcError(id, -32601, `Method not found: ${message.method}`);
    }
  } catch (error) {
    return rpcError(id, -32603, error instanceof Error ? error.message : String(error));
  }
}

async function macStatus(env: Env, origin: string): Promise<ToolResult> {
  const status = await relayStub(env).status();
  const lines = [
    status.online ? `The Mac is online${status.host?.name ? ` (${status.host.name})` : ""}.` : "The Mac is offline.",
    `Live view: ${origin}/ — the user can watch and tap the simulator there (they'll be asked for the minirun password).`,
    `Viewers connected: ${status.viewers}. Tools available: ${status.toolCount}.`,
  ];
  if (!status.online) {
    lines.push("Ask the user to check that the Mac is awake and that `minirun serve` is running.");
  }
  return { content: [{ type: "text", text: lines.join("\n") }], isError: false };
}

function rpcResult(id: string | number, result: unknown): RpcResponse {
  return { jsonrpc: "2.0", id, result };
}

function rpcError(id: string | number | null, code: number, message: string): RpcResponse {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });
}
