import { relayStub, type Env } from "./env";
import { streamKey, type ToolDefinition, type ToolResult } from "./relay";
import { compareVersions, VERSION } from "./version";

/**
 * A minimal MCP server over Streamable HTTP (JSON responses, no SSE). Every tool except
 * `mac_status` lives on the Mac; this just forwards `tools/list` and `tools/call` to it.
 */

const SUPPORTED_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
const SERVER_INFO = { name: "minirun", title: "minirun — iOS simulators on your Mac", version: VERSION };

const INSTRUCTIONS = `minirun drives iOS simulators and Xcode on the user's Mac.
Typical loop: push your branch to GitHub, call build_and_run with repo + ref, read any errors (they come back with file:line), fix, push, repeat.
Then exercise the app: describe_ui to find elements, tap by id/label (or x,y in points), type_text, swipe, screenshot to look.
Long builds return a job_id after at most 50 seconds; call get_job (repeatedly if need be) to wait for it. If a call ever times out, the work keeps running on the Mac: list_jobs finds it. A job of yours that's stuck or no longer needed: cancel_job stops it and frees its simulator. Jobs survive a restart of minirun; one cut off by a restart reports that.

Tests:
- A Swift package that builds for macOS: swift_test {repo, ref, package: "Packages/Core"} runs \`swift test\` with no simulator. Quickest, and use it to watch a test fail before you fix the code.
- iOS tests: run_tests {repo, ref, scheme?, project?}. For a package in a subfolder, project is the package's folder, relative to the checkout: run_tests {repo: "you/app", ref: "my-branch", project: "Packages/Core"}. Leave path out when you pass repo; path is only for a folder on the Mac that isn't a checkout.
- A run that prints nothing for stall_seconds (default 300) is stopped as hung and says so; that's usually the Mac, not your code.
- configure_simulator sets text_size (including accessibility-* sizes), increase_contrast and appearance; don't tap through the Settings app for them.

Other Claude sessions may be using the same Mac at the same time, on other apps or other branches of yours. To stay on your own simulator and checkout:
- Always pass the same repo + ref. Each repo + ref has its own checkout and build folder.
- build_and_run picks the simulator reserved for your repo + ref (or reserves one) and its result gives that simulator's UDID. You can also get one up front with boot_simulator {label: "owner/repo@branch"}.
- Pass that UDID as device on every simulator call (tap, screenshot, describe_ui, launch_app, …). Without it, a call fails when several simulators are booted rather than guessing.
- Never shut down or reuse a simulator reserved for something else; list_simulators shows who each one is reserved for.
The user can watch and touch your simulator live in their browser: share the live view link from build_and_run or boot_simulator, or call mac_status with your device.`;

const MAC_STATUS_TOOL: ToolDefinition = {
  name: "mac_status",
  description: "Check whether the Mac is online and which minirun version it and this relay run, and get the link where the user can watch and control a simulator live in a browser. Pass your simulator's UDID as device so the link opens on it. For Xcode, simulator and setup problems on the Mac, call host_info.",
  inputSchema: {
    type: "object",
    properties: { device: { type: "string", description: "UDID of your simulator. The link opens straight to it." } },
    additionalProperties: false,
  },
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
        if (name === MAC_STATUS_TOOL.name) return rpcResult(id, await macStatus(env, origin, args.device));
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

async function macStatus(env: Env, origin: string, device: unknown): Promise<ToolResult> {
  const status = await relayStub(env).status();
  const key = streamKey(device);
  if (key === null) return { content: [{ type: "text", text: "device must be a simulator UDID (from build_and_run, boot_simulator or list_simulators)." }], isError: true };
  const link = key ? `${origin}/?device=${encodeURIComponent(key)}` : `${origin}/`;
  const lines = [
    status.online ? `The Mac is online${status.host?.name ? ` (${status.host.name})` : ""}.` : "The Mac is offline.",
    versionLine(status.host?.minirun),
    key
      ? `Live view of simulator ${key}: ${link} — the user can watch and tap it there (they'll be asked for the minirun password).`
      : `Live view: ${link} — the user can watch and tap a simulator there and switch between booted ones (they'll be asked for the minirun password). Pass device to get a link that opens on your simulator.`,
    `Viewers connected: ${status.viewers}. Tools available: ${status.toolCount}.` + (status.location ? ` The relay runs in Cloudflare's ${status.location} data center.` : ""),
  ];
  if (!status.online) {
    lines.push("Ask the user to check that the Mac is awake and that `minirun serve` is running.");
  }
  return { content: [{ type: "text", text: lines.join("\n") }], isError: false };
}

/** Which minirun the Mac runs (as of its last connection) and the relay runs, and what to do if they differ. */
function versionLine(mac: string | undefined): string {
  if (!mac) return `Relay: minirun ${VERSION}. The Mac hasn't said which minirun it runs.`;
  const order = compareVersions(mac, VERSION);
  if (order === 0) return `minirun ${VERSION} on the Mac and the relay.`;
  const fix = order > 0
    ? "Ask the user to update the Worker: Update Worker in minirun's Settings → Cloudflare, or `minirun worker deploy`."
    : "Ask the user to update minirun on the Mac (Check for Updates in minirun's Settings).";
  return `minirun ${mac} on the Mac, but the relay is from minirun ${VERSION}. ${fix}`;
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
