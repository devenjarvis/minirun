/** An entry of RTCConfiguration.iceServers, as both the browser and libwebrtc take it. */
export interface IceServer {
  urls: string | string[];
  username?: string;
  credential?: string;
}

/** Cloudflare's STUN server: free, and always in the list. */
export const STUN: IceServer = { urls: "stun:stun.cloudflare.com:3478" };

/** How long TURN credentials last. A peer connection keeps its TURN allocation only while they're valid. */
export const TURN_TTL_SECONDS = 24 * 60 * 60;

/** Credentials are fetched again this long before they expire, so new connections get fresh ones. */
export const TURN_REFRESH_MS = 60 * 60 * 1000;

/** After a failed fetch, STUN only for this long before trying again. */
export const TURN_RETRY_MS = 60 * 1000;

/** How long the credentials request may take before the relay gives up and uses STUN only. */
const TURN_TIMEOUT_MS = 3000;

export interface TurnCache {
  servers: IceServer[];
  /** When to fetch again (ms since the epoch). */
  until: number;
}

/**
 * The ICE servers for a new peer connection: Cloudflare's STUN server, plus Cloudflare Realtime
 * TURN credentials when the Worker has the TURN_KEY_ID and TURN_KEY_API_TOKEN secrets. The
 * credentials are cached in `cache` until shortly before they expire. If generating them fails,
 * it's STUN only.
 */
export async function iceServers(
  secrets: { TURN_KEY_ID?: string; TURN_KEY_API_TOKEN?: string },
  cache: { turn: TurnCache | null; pending?: Promise<TurnCache> | null },
  fetcher: typeof fetch = (input, init) => fetch(input, init),
  now = Date.now(),
): Promise<IceServer[]> {
  const { TURN_KEY_ID: id, TURN_KEY_API_TOKEN: token } = secrets;
  if (!id || !token) return [STUN];
  if (!cache.turn || now >= cache.turn.until) {
    // Viewers starting together share one request.
    cache.pending ??= generateTurn(id, token, fetcher, now).finally(() => { cache.pending = null; });
    cache.turn = await cache.pending;
  }
  return [STUN, ...cache.turn.servers];
}

async function generateTurn(id: string, token: string, fetcher: typeof fetch, now: number): Promise<TurnCache> {
  try {
    // https://developers.cloudflare.com/realtime/turn/generate-credentials/
    const response = await fetcher(`https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(id)}/credentials/generate-ice-servers`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ ttl: TURN_TTL_SECONDS }),
      signal: AbortSignal.timeout(TURN_TIMEOUT_MS),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${(await response.text()).slice(0, 200)}`);
    const body = (await response.json()) as { iceServers?: unknown };
    const list = Array.isArray(body.iceServers) ? body.iceServers : body.iceServers ? [body.iceServers] : [];
    const servers: IceServer[] = [];
    for (const entry of list as Array<Partial<IceServer>>) {
      // Only the TURN entry: STUN is already first in the list.
      if (typeof entry?.username !== "string" || typeof entry.credential !== "string") continue;
      // Browsers block port 53, so that URL only times out.
      const urls = (Array.isArray(entry.urls) ? entry.urls : [entry.urls]).filter(
        (url): url is string => typeof url === "string" && /^turns?:/.test(url) && !/:53(\?|$)/.test(url));
      if (urls.length) servers.push({ urls, username: entry.username, credential: entry.credential });
    }
    if (!servers.length) throw new Error("no TURN servers in the response");
    return { servers, until: now + TURN_TTL_SECONDS * 1000 - TURN_REFRESH_MS };
  } catch (error) {
    console.log("TURN credentials failed, using STUN only", String(error));
    return { servers: [], until: now + TURN_RETRY_MS };
  }
}
