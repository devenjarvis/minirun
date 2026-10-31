import type { OAuthHelpers } from "@cloudflare/workers-oauth-provider";
import type { MacRelay } from "./relay";

export interface Env {
  MAC_RELAY: DurableObjectNamespace<MacRelay>;
  OAUTH_KV: KVNamespace;
  /** Shared screenshots and recordings, keyed "<id>.<ext>". */
  MEDIA_KV: KVNamespace;
  /** Injected by OAuthProvider into the default handler. */
  OAUTH_PROVIDER: OAuthHelpers;
  OWNER_PASSWORD: string;
  AGENT_TOKEN: string;
  /** SHA-256 of the deployed code, set by `minirun worker deploy`. Unset when deployed with wrangler. */
  MINIRUN_BUNDLE?: string;
}

declare global {
  namespace Cloudflare {
    interface Env {
      MAC_RELAY: DurableObjectNamespace<MacRelay>;
      OAUTH_KV: KVNamespace;
      MEDIA_KV: KVNamespace;
      OWNER_PASSWORD: string;
      AGENT_TOKEN: string;
    }
  }
}

/** One Mac per deployment for now; the Durable Object is addressed by this name. */
export function relayStub(env: Env | Cloudflare.Env): DurableObjectStub<MacRelay> {
  return env.MAC_RELAY.get(env.MAC_RELAY.idFromName("default"));
}
