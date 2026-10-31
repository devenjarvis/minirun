/**
 * Shared screenshots and recordings, for PR descriptions. The Mac uploads with the agent token;
 * anyone with the unguessable URL can fetch, because GitHub's image proxy can't log in.
 *
 *   PUT    /media/<id>.<ext>   upload (agent token)
 *   DELETE /media/<id>         delete every file with that id (agent token)
 *   GET    /m/<id>.<ext>       the file, with Range support
 *   GET    /m/<id>             a player page for <id>.mp4
 *   GET    /m/probe/<n>.gif    an n MiB GIF, to find the largest image GitHub will show
 */
import { bearer, safeEqual } from "./auth";
import type { Env } from "./env";
import { baseStyles, escapeHTML } from "./pages";

/** KV's largest value. */
export const MAX_BYTES = 25 * 1024 * 1024;
const MIN_TTL = 60;
const MAX_TTL = 90 * 86400;
const MAX_CAPTION = 200;

const TYPES: Record<string, string> = { jpg: "image/jpeg", png: "image/png", gif: "image/gif", mp4: "video/mp4" };
const ID = "[A-Za-z0-9_-]{22}";
const UPLOAD = new RegExp(`^/media/(${ID})\\.(jpg|png|gif|mp4)$`);
const DELETE = new RegExp(`^/media/(${ID})$`);
const FILE = new RegExp(`^/m/(${ID})\\.(jpg|png|gif|mp4)$`);
const PLAYER = new RegExp(`^/m/(${ID})$`);
const PROBE = /^\/m\/probe\/([1-9]|1[0-9]|2[0-5])\.gif$/;

export interface MediaMetadata {
  type: string;
  bytes: number;
  caption?: string;
  /** Milliseconds since 1970. */
  created: number;
}

/** Handles /media/… and /m/…, or returns null for any other path. */
export async function handleMedia(request: Request, env: Env): Promise<Response | null> {
  const url = new URL(request.url);
  const path = url.pathname;
  if (path.startsWith("/media/")) return agentRoute(request, env, url);
  if (!path.startsWith("/m/")) return null;

  if (request.method !== "GET" && request.method !== "HEAD") return new Response(null, { status: 405, headers: { Allow: "GET, HEAD" } });
  let match: RegExpMatchArray | null;
  if ((match = path.match(PROBE))) return probe(Number(match[1]), request.method === "HEAD");
  if ((match = path.match(FILE))) return serveFile(request, env, match[1]!, match[2]!);
  if ((match = path.match(PLAYER))) return player(env, match[1]!);
  return notFound();
}

async function agentRoute(request: Request, env: Env, url: URL): Promise<Response> {
  const token = bearer(request);
  if (!env.AGENT_TOKEN || !token || !(await safeEqual(token, env.AGENT_TOKEN))) {
    return new Response("Invalid agent token", { status: 401 });
  }
  if (request.method === "PUT") return upload(request, env, url);
  if (request.method === "DELETE") {
    const id = url.pathname.match(DELETE)?.[1];
    if (!id) return new Response("Bad media id", { status: 400 });
    await Promise.all(Object.keys(TYPES).map((ext) => env.MEDIA_KV.delete(`${id}.${ext}`)));
    return new Response(null, { status: 204 });
  }
  return new Response(null, { status: 405, headers: { Allow: "PUT, DELETE" } });
}

async function upload(request: Request, env: Env, url: URL): Promise<Response> {
  const match = url.pathname.match(UPLOAD);
  if (!match) return new Response("Bad media id or extension: use /media/<22 base64url characters>.jpg|png|gif|mp4", { status: 400 });
  const [, id, ext] = match as [string, string, string];

  const ttlHeader = request.headers.get("X-Minirun-Expires-In") ?? "";
  const ttl = /^\d+$/.test(ttlHeader) ? Number(ttlHeader) : NaN;
  if (!(ttl >= MIN_TTL && ttl <= MAX_TTL)) return new Response(`X-Minirun-Expires-In must be ${MIN_TTL} to ${MAX_TTL} seconds`, { status: 400 });

  let caption: string | undefined;
  const captionHeader = request.headers.get("X-Minirun-Caption");
  if (captionHeader) {
    try {
      // Control characters would bloat the JSON metadata, which KV caps at 1 KB.
      caption = decodeURIComponent(captionHeader).replace(/[\u0000-\u001f\u007f]/g, " ").trim();
    } catch {
      return new Response("X-Minirun-Caption must be percent-encoded", { status: 400 });
    }
    if ([...caption].length > MAX_CAPTION) return new Response(`X-Minirun-Caption must be at most ${MAX_CAPTION} characters`, { status: 400 });
    if (!caption) caption = undefined;
  }

  const declared = Number(request.headers.get("Content-Length") ?? 0);
  if (declared > MAX_BYTES) return tooLarge();
  const body = await readUpTo(request.body, MAX_BYTES);
  if (!body) return tooLarge();
  if (body.byteLength === 0) return new Response("Empty body", { status: 400 });

  const metadata: MediaMetadata = { type: TYPES[ext]!, bytes: body.byteLength, created: Date.now() };
  if (caption) metadata.caption = caption;
  await env.MEDIA_KV.put(`${id}.${ext}`, body, { expirationTtl: ttl, metadata });
  return Response.json({ url: `${url.origin}/m/${id}.${ext}` }, { status: 201 });
}

function tooLarge(): Response {
  return new Response(`Too large: the limit is ${MAX_BYTES} bytes`, { status: 413 });
}

/** The whole body, or null once it passes `limit` bytes (whatever Content-Length said). */
async function readUpTo(body: ReadableStream<Uint8Array> | null, limit: number): Promise<Uint8Array | null> {
  if (!body) return new Uint8Array();
  const chunks: Uint8Array[] = [];
  let total = 0;
  const reader = body.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

function publicHeaders(type: string, length: number): Headers {
  return new Headers({
    "Content-Type": type,
    "Content-Length": String(length),
    "Cache-Control": "public, max-age=31536000, immutable",
    "X-Robots-Tag": "noindex",
    "X-Content-Type-Options": "nosniff",
    "Accept-Ranges": "bytes",
  });
}

function notFound(): Response {
  return new Response("Not found", { status: 404, headers: { "X-Robots-Tag": "noindex", "Cache-Control": "no-store" } });
}

async function serveFile(request: Request, env: Env, id: string, ext: string): Promise<Response> {
  const range = request.headers.get("Range");
  const head = request.method === "HEAD";
  // A range needs the bytes in hand; otherwise stream straight from KV.
  if (range && !head) {
    const { value, metadata } = await env.MEDIA_KV.getWithMetadata<MediaMetadata>(`${id}.${ext}`, "arrayBuffer");
    if (!value) return notFound();
    const size = value.byteLength;
    const span = parseRange(range, size);
    const type = metadata?.type ?? TYPES[ext]!;
    if (span === "unsatisfiable") {
      const headers = publicHeaders(type, 0);
      headers.set("Content-Range", `bytes */${size}`);
      headers.set("Cache-Control", "no-store");
      return new Response(null, { status: 416, headers });
    }
    if (span) {
      const [start, end] = span;
      const headers = publicHeaders(type, end - start + 1);
      headers.set("Content-Range", `bytes ${start}-${end}/${size}`);
      return new Response(value.slice(start, end + 1), { status: 206, headers });
    }
    return new Response(value, { headers: publicHeaders(type, size) });
  }

  const { value, metadata } = await env.MEDIA_KV.getWithMetadata<MediaMetadata>(`${id}.${ext}`, "stream");
  if (!value) return notFound();
  const type = metadata?.type ?? TYPES[ext]!;
  if (!metadata?.bytes) {
    // Shouldn't happen (every upload records its size), but serve it anyway.
    const bytes = await new Response(value).arrayBuffer();
    return new Response(head ? null : bytes, { headers: publicHeaders(type, bytes.byteLength) });
  }
  if (head) {
    await value.cancel();
    return new Response(null, { headers: publicHeaders(type, metadata.bytes) });
  }
  return new Response(value.pipeThrough(new FixedLengthStream(metadata.bytes)), { headers: publicHeaders(type, metadata.bytes) });
}

/**
 * One byte range [start, end] from a Range header, "unsatisfiable", or null to send the whole
 * file (no header, a syntax we don't handle, or several ranges, which RFC 9110 lets us ignore).
 */
export function parseRange(header: string, size: number): [number, number] | "unsatisfiable" | null {
  const match = header.trim().match(/^bytes=(\d*)-(\d*)$/);
  if (!match || (!match[1] && !match[2])) return null;
  const [, first, last] = match as [string, string, string];
  if (!first) {
    const suffix = Number(last);
    if (suffix === 0 || size === 0) return "unsatisfiable";
    return [Math.max(0, size - suffix), size - 1];
  }
  const start = Number(first);
  const end = last ? Number(last) : size - 1;
  if (last && end < start) return null;
  if (start >= size) return "unsatisfiable";
  return [start, Math.min(end, size - 1)];
}

async function player(env: Env, id: string): Promise<Response> {
  const { value, metadata } = await env.MEDIA_KV.getWithMetadata<MediaMetadata>(`${id}.mp4`, "stream");
  if (!value) return playerResponse(missingPage(), 404);
  await value.cancel();
  return playerResponse(playerPage(id, metadata?.caption));
}

function playerResponse(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": status === 200 ? "public, max-age=300" : "no-store",
      "X-Robots-Tag": "noindex",
      "Referrer-Policy": "no-referrer",
    },
  });
}

function mediaPage(title: string, body: string): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>${escapeHTML(title)} · minirun</title><style>${baseStyles}
  .card.wide { max-width: 520px; margin-top: 6vh; }
  video { display: block; width: 100%; max-height: 78vh; border-radius: 12px; background: #000; }
  .caption { margin: 14px 0 0; color: var(--text); }
</style></head><body>${body}</body></html>`;
}

export function playerPage(id: string, caption?: string): string {
  return mediaPage(caption || "Recording", `<div class="card wide">
  <div class="mark"><i></i>minirun</div>
  <video src="/m/${id}.mp4" controls playsinline preload="metadata"></video>
  ${caption ? `<p class="caption">${escapeHTML(caption)}</p>` : ""}
</div>`);
}

function missingPage(): string {
  return mediaPage("Not found", `<div class="card"><div class="mark"><i></i>minirun</div><h1>Not found</h1><p>This recording doesn't exist or has expired.</p></div>`);
}

// MARK: Size probe

/**
 * A valid two-frame animated GIF padded with a comment extension to exactly `mib` MiB, streamed
 * so that even 25 MiB costs no memory to speak of.
 */
function probe(mib: number, head: boolean): Response {
  const total = mib * 1024 * 1024;
  const headers = {
    "Content-Type": "image/gif",
    "Content-Length": String(total),
    "Cache-Control": "public, max-age=86400",
    "X-Robots-Tag": "noindex",
    "X-Content-Type-Options": "nosniff",
  };
  if (head) return new Response(null, { headers });
  const fixed = new FixedLengthStream(total);
  probeStream(total).pipeTo(fixed.writable).catch(() => {});
  return new Response(fixed.readable, { headers });
}

const PROBE_SIDE = 32;
// Full comment sub-blocks (a length byte of 255, then 255 bytes), 256 of them per 64 KiB chunk.
const PADDING_CHUNK = (() => {
  const chunk = new Uint8Array(256 * 256).fill(0x20);
  for (let i = 0; i < chunk.length; i += 256) chunk[i] = 255;
  return chunk;
})();

export function probeStream(total: number): ReadableStream<Uint8Array> {
  const { start, end } = probeParts(total);
  let fullBlocks = (total - start.length - end.length) / 256;
  let sentStart = false;
  let sentEnd = false;
  return new ReadableStream<Uint8Array>({
    pull(controller) {
      if (!sentStart) {
        sentStart = true;
        controller.enqueue(start);
      } else if (fullBlocks > 0) {
        const blocks = Math.min(fullBlocks, 256);
        fullBlocks -= blocks;
        controller.enqueue(PADDING_CHUNK.subarray(0, blocks * 256));
      } else if (!sentEnd) {
        sentEnd = true;
        controller.enqueue(end);
      } else {
        controller.close();
      }
    },
  });
}

/**
 * The GIF up to the comment's first full sub-block, and from its last full sub-block on.
 * The full sub-blocks in between (256 bytes each) make up the rest of `total`.
 */
function probeParts(total: number): { start: Uint8Array; end: Uint8Array } {
  const side = [PROBE_SIDE, 0];
  const start = [
    ...ascii("GIF89a"),
    ...side, ...side, 0x80, 0, 0, // logical screen, 2-color global table
    0x15, 0x17, 0x1c, 0x7c, 0xc4, 0xff, // dark, accent
    0x21, 0xff, 0x0b, ...ascii("NETSCAPE2.0"), 0x03, 0x01, 0x00, 0x00, 0x00, // loop forever
    ...frame(0), ...frame(1),
    0x21, 0xfe, // comment extension
  ];
  // Then the comment's sub-blocks, its terminator and the GIF trailer.
  const rest = total - start.length - 2;
  if (rest < 0) throw new Error("probe too small");
  const tail: number[] = [];
  let partial = rest % 256;
  // A sub-block costs its length plus one, so a remainder of 1 can't be one block: use two.
  if (partial === 1) partial = 257;
  if (partial > 1 && partial < 257) tail.push(...block(partial - 1));
  if (partial === 257) tail.push(...block(200), ...block(55));
  tail.push(0x00, 0x3b);
  return { start: Uint8Array.from(start), end: Uint8Array.from(tail) };
}

function block(length: number): number[] {
  return [length, ...new Array<number>(length).fill(0x20)];
}

function ascii(text: string): number[] {
  return [...text].map((c) => c.charCodeAt(0));
}

/** A half-second frame filling the screen with one color. */
function frame(color: number): number[] {
  const side = [PROBE_SIDE, 0];
  const data = lzw(color, PROBE_SIDE * PROBE_SIDE);
  const blocks: number[] = [];
  for (let i = 0; i < data.length; i += 255) {
    const piece = data.slice(i, i + 255);
    blocks.push(piece.length, ...piece);
  }
  return [
    0x21, 0xf9, 0x04, 0x00, 50, 0, 0x00, 0x00, // graphic control: 0.5 s
    0x2c, 0, 0, 0, 0, ...side, ...side, 0x00, // image descriptor, no local table
    0x02, ...blocks, 0x00, // LZW minimum code size 2, data, terminator
  ];
}

/**
 * LZW data for `count` pixels of one color, without compressing: a clear code before every two
 * pixels keeps the code width at 3 bits, so no code table is needed.
 */
function lzw(color: number, count: number): number[] {
  const codes: number[] = [];
  for (let i = 0; i < count; i++) {
    if (i % 2 === 0) codes.push(4);
    codes.push(color);
  }
  codes.push(5);
  const bytes: number[] = [];
  let bits = 0;
  let width = 0;
  for (const code of codes) {
    bits |= code << width;
    width += 3;
    while (width >= 8) {
      bytes.push(bits & 0xff);
      bits >>= 8;
      width -= 8;
    }
  }
  if (width > 0) bytes.push(bits & 0xff);
  return bytes;
}
