const encoder = new TextEncoder();
const SESSION_COOKIE = "minirun_session";
const SESSION_DAYS = 30;

async function sha256(text: string): Promise<ArrayBuffer> {
  return crypto.subtle.digest("SHA-256", encoder.encode(text));
}

/** Constant-time string comparison (hashing first makes lengths equal). */
export async function safeEqual(a: string, b: string): Promise<boolean> {
  const [ha, hb] = await Promise.all([sha256(a), sha256(b)]);
  return crypto.subtle.timingSafeEqual(ha, hb);
}

export async function checkPassword(given: string | null | undefined, expected: string | undefined): Promise<boolean> {
  if (!expected || !given) return false;
  return safeEqual(given, expected);
}

/** Bearer token from an Authorization header, or ?token= for clients that can't set headers. */
export function bearer(request: Request): string | null {
  const header = request.headers.get("Authorization");
  if (header?.startsWith("Bearer ")) return header.slice(7).trim();
  return null;
}

async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", encoder.encode("minirun-session:" + secret), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
    "verify",
  ]);
}

function toHex(buffer: ArrayBuffer): string {
  return [...new Uint8Array(buffer)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function fromHex(hex: string): Uint8Array | null {
  if (!/^[0-9a-f]+$/.test(hex) || hex.length % 2) return null;
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

/** A signed session value: "<expiry>.<hmac>". Changing OWNER_PASSWORD logs everyone out. */
export async function createSession(secret: string): Promise<string> {
  const expires = Math.floor(Date.now() / 1000) + SESSION_DAYS * 86400;
  const signature = await crypto.subtle.sign("HMAC", await hmacKey(secret), encoder.encode(`viewer:${expires}`));
  return `${expires}.${toHex(signature)}`;
}

export async function verifySession(value: string | null, secret: string | undefined): Promise<boolean> {
  if (!value || !secret) return false;
  const [expires, signature] = value.split(".");
  if (!expires || !signature || Number(expires) * 1000 < Date.now()) return false;
  const bytes = fromHex(signature);
  if (!bytes) return false;
  return crypto.subtle.verify("HMAC", await hmacKey(secret), bytes, encoder.encode(`viewer:${expires}`));
}

export function readCookie(request: Request, name = SESSION_COOKIE): string | null {
  const header = request.headers.get("Cookie") ?? "";
  for (const part of header.split(";")) {
    const [key, ...rest] = part.trim().split("=");
    if (key === name) return decodeURIComponent(rest.join("="));
  }
  return null;
}

export function sessionCookie(value: string, secure: boolean): string {
  return `${SESSION_COOKIE}=${encodeURIComponent(value)}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${SESSION_DAYS * 86400}${secure ? "; Secure" : ""}`;
}

export function clearSessionCookie(): string {
  return `${SESSION_COOKIE}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0`;
}

export async function isLoggedIn(request: Request, secret: string | undefined): Promise<boolean> {
  return verifySession(readCookie(request), secret);
}
