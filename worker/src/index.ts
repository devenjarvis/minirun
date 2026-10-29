import { OAuthProvider, type AuthRequest } from "@cloudflare/workers-oauth-provider";
import { bearer, checkPassword, clearSessionCookie, createSession, isLoggedIn, safeEqual, sessionCookie } from "./auth";
import { relayStub, type Env } from "./env";
import { handleMcp } from "./mcp";
import { authorizePage, html, loginPage, messagePage } from "./pages";
import { viewerPage } from "./viewer";

export { MacRelay } from "./relay";

/** Everything that isn't the OAuth-protected /mcp endpoint. */
async function handleDefault(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const secure = url.protocol === "https:";

  switch (url.pathname) {
    case "/agent": {
      // The Mac's connection. Authenticated with the shared AGENT_TOKEN.
      const token = bearer(request);
      if (!env.AGENT_TOKEN || !token || !(await safeEqual(token, env.AGENT_TOKEN))) {
        return new Response("Invalid agent token", { status: 401 });
      }
      return relayStub(env).fetch(new Request("https://relay/agent", request));
    }

    case "/viewer/ws": {
      if (!(await isLoggedIn(request, env.OWNER_PASSWORD))) return new Response("Log in first", { status: 401 });
      return relayStub(env).fetch(new Request("https://relay/viewer", request));
    }

    case "/status": {
      if (!(await isLoggedIn(request, env.OWNER_PASSWORD))) return new Response("Log in first", { status: 401 });
      return Response.json(await relayStub(env).status());
    }

    case "/": {
      if (!(await isLoggedIn(request, env.OWNER_PASSWORD))) return redirect("/login");
      return html(viewerPage());
    }

    case "/login": {
      if (!env.OWNER_PASSWORD) return html(messagePage("Not set up yet", "Set the OWNER_PASSWORD secret on the Worker first (see the README)."), 500);
      if (request.method === "POST") {
        const form = await request.formData();
        if (await checkPassword(form.get("password")?.toString(), env.OWNER_PASSWORD)) {
          return redirect(safeNext(form.get("next")?.toString()), { "Set-Cookie": sessionCookie(await createSession(env.OWNER_PASSWORD), secure) });
        }
        return html(loginPage({ error: "That password isn't right.", next: form.get("next")?.toString() }), 401);
      }
      return html(loginPage({ next: url.searchParams.get("next") ?? undefined }));
    }

    case "/logout":
      return redirect("/login", { "Set-Cookie": clearSessionCookie() });

    case "/authorize":
      return authorize(request, env, secure);

    case "/favicon.ico":
      return new Response(null, { status: 204 });

    default:
      return new Response("Not found", { status: 404 });
  }
}

/** OAuth consent for Claude's connector: the owner approves with the minirun password. */
async function authorize(request: Request, env: Env, secure: boolean): Promise<Response> {
  if (request.method === "GET") {
    let oauthRequest;
    try {
      oauthRequest = await env.OAUTH_PROVIDER.parseAuthRequest(request);
    } catch (error) {
      return html(messagePage("Invalid request", error instanceof Error ? error.message : "The authorization request is invalid."), 400);
    }
    const client = await env.OAUTH_PROVIDER.lookupClient(oauthRequest.clientId);
    if (!client) return html(messagePage("Unknown app", "This app isn't registered with minirun."), 400);
    return html(authorizePage({
      clientName: client.clientName ?? client.clientId,
      redirectUri: oauthRequest.redirectUri,
      // The parsed request is round-tripped through the form; it's validated again on submit.
      state: encodeState(oauthRequest),
    }));
  }

  if (request.method !== "POST") return new Response(null, { status: 405 });
  const form = await request.formData();
  let oauthRequest: AuthRequest;
  try {
    oauthRequest = decodeState(form.get("state")?.toString() ?? "");
  } catch {
    return html(messagePage("Invalid request", "The authorization form was malformed. Start the connection again from Claude."), 400);
  }
  const client = await env.OAUTH_PROVIDER.lookupClient(oauthRequest.clientId);
  if (!client || !client.redirectUris.includes(oauthRequest.redirectUri)) {
    return html(messagePage("Invalid request", "This app or redirect address isn't registered."), 400);
  }
  if (form.get("action") === "deny") {
    const deny = new URL(oauthRequest.redirectUri);
    deny.searchParams.set("error", "access_denied");
    if (oauthRequest.state) deny.searchParams.set("state", oauthRequest.state);
    return redirect(deny.toString());
  }
  // Always require the password here, even with a viewer session, so a malicious page can't
  // quietly approve a connection using the owner's cookie.
  if (!(await checkPassword(form.get("password")?.toString(), env.OWNER_PASSWORD))) {
    return html(authorizePage({
      clientName: client.clientName ?? client.clientId,
      redirectUri: oauthRequest.redirectUri,
      state: form.get("state")?.toString() ?? "",
      error: "That password isn't right.",
    }), 401);
  }
  const { redirectTo } = await env.OAUTH_PROVIDER.completeAuthorization({
    request: oauthRequest,
    userId: "owner",
    metadata: { client: client.clientName ?? client.clientId, approvedAt: Date.now() },
    scope: oauthRequest.scope ?? [],
    props: { user: "owner" },
  });
  return redirect(redirectTo, { "Set-Cookie": sessionCookie(await createSession(env.OWNER_PASSWORD), secure) });
}

function encodeState(value: unknown): string {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function decodeState(state: string): AuthRequest {
  const binary = atob(state);
  const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
  const parsed = JSON.parse(new TextDecoder().decode(bytes));
  if (!parsed || typeof parsed.clientId !== "string" || typeof parsed.redirectUri !== "string") throw new Error("bad state");
  return parsed as AuthRequest;
}

function redirect(location: string, headers: Record<string, string> = {}): Response {
  return new Response(null, { status: 302, headers: { Location: location, ...headers } });
}

function safeNext(next: string | undefined): string {
  return next && next.startsWith("/") && !next.startsWith("//") ? next : "/";
}

// The OAuth resource identifier must be this deployment's own /mcp URL, which we only learn from
// the first request (e.g. https://minirun.you.workers.dev/mcp). One provider per origin.
const providers = new Map<string, OAuthProvider<Env>>();

function providerFor(origin: string): OAuthProvider<Env> {
  let provider = providers.get(origin);
  if (!provider) {
    provider = new OAuthProvider<Env>({
      apiRoute: "/mcp",
      apiHandler: { fetch: (request, env) => handleMcp(request as Request, env as Env) },
      defaultHandler: { fetch: (request, env) => handleDefault(request as Request, env as Env) },
      authorizeEndpoint: "/authorize",
      tokenEndpoint: "/token",
      clientRegistrationEndpoint: "/register",
      clientIdMetadataDocumentEnabled: true,
      accessTokenTTL: 24 * 3600,
      resourceMetadata: { resource: `${origin}/mcp`, authorization_servers: [origin], resource_name: "minirun" },
    });
    providers.set(origin, provider);
  }
  return provider;
}

export default {
  fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    return providerFor(new URL(request.url).origin).fetch(request, env, ctx);
  },
} satisfies ExportedHandler<Env>;
