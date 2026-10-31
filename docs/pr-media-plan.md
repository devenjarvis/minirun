# Screenshots and recordings in PR descriptions: plan

Goal: an agent working through minirun can put a screenshot or a short recording of the simulator
in a PR description, so the owner can check the work without opening the live view.

Today `screenshot` returns the image inline to the agent, and nothing else. GitHub markdown needs
a URL that it can fetch, so the agent has nothing to paste.

## Constraints that shape the design

- **GitHub fetches the image anonymously.** It rewrites `![](url)` to go through its image proxy
  (camo), which can't send cookies or OAuth tokens. So a shared image needs a public, unguessable
  capability URL. It can't sit behind the viewer password.
- **The proxy may cap size.** Open-source camo defaults to 5 MB, but GitHub's live limit isn't
  documented and may be higher. Rather than guess, the Worker serves size probes (see
  [Finding the real size limit](#finding-the-real-size-limit)), and the inline limit is a
  setting (`mediaInlineLimitMB`, default 5) that can be raised once the probes show what renders.
- **GitHub won't play externally hosted video.** `<video>` works only for files uploaded through
  GitHub's web UI, and an agent can't upload that way. To show motion inline, use an **animated
  GIF**: it renders inline and loops. Link the GIF to a small player page that holds the full MP4.
- **Cost: $0 on the Cloudflare free plan.** Add no new account sign-ups, payment methods or
  API-token permissions.

## Storage: Workers KV, not R2

| | Workers KV (recommended) | R2 |
| --- | --- | --- |
| Already set up | Yes. `OAUTH_KV` exists, or a second namespace is created by the same deploy code | No. A bucket and a new binding are needed |
| Account setup | None | Enabling R2 needs a payment method on the account, even on the free tier |
| API token | Already has *Workers KV Storage: Edit* | Needs *R2: Edit* too, so every user must make a new token |
| Free allowance | 1 GB stored, 1,000 writes/day, 100k reads/day, 25 MiB per value | 10 GB-month, free egress |
| Cleanup | `expirationTtl` on each put: KV deletes the object by itself | Bucket lifecycle rule (days granularity) |

KV fits easily. A screenshot is about 100–300 KB, and a 60-second GIF plus MP4 is about 5–15 MB,
so 1 GB holds about a hundred recordings or thousands of screenshots, and 7-day expiry keeps
only a week's worth. A few dozen uploads a day is
nowhere near the 1,000-write limit. Each object gets its own TTL, so you don't need a cron job, a
cleanup worker or a lifecycle rule.

Use a **separate namespace, `MEDIA_KV`**, so media never mixes with OAuth grants and "delete
all" can't affect them. `WorkerDeployer` already creates and adopts KV namespaces by binding
name, so this is one more entry in its list.

If storage ever gets tight, R2 is a drop-in swap behind the same `/media` routes. Don't build it now.

## Data flow

```
 agent ── screenshot {share:true} ──► Worker /mcp ──relay──► Mac
                                                            │ capture JPEG / record MP4 → GIF
                                                            │ PUT /media/<id>.<ext>  (Bearer AGENT_TOKEN)
                                                            ▼
                                         Worker ── put MEDIA_KV (expirationTtl) ──► id
 agent ◄── URL + ready-to-paste markdown ◄────────────────── Mac

 GitHub camo ── GET /m/<id>.gif ──► Worker ── get MEDIA_KV ──► bytes (Cache-Control: immutable)
```

- **The Mac uploads over plain HTTPS, not the relay WebSocket.** Multi-MB blobs would otherwise
  share the socket with live-view frames and tool calls. Authentication is the same `AGENT_TOKEN`
  that `/agent` checks, and the Mac already knows `relayURL`.
- **IDs are random, 128 bits, base64url.** Only the Mac can write, so they never come from
  agent input.
- **Public routes:**
  - `GET /m/<id>.jpg|.gif|.mp4` serves the raw bytes, with `X-Robots-Tag: noindex` and long
    immutable caching, since objects never change.
  - `GET /m/<id>` is a small HTML player page for recordings: `<video controls>` showing the MP4.
- **Agent-token routes:** `PUT /media/<id>.<ext>` (see the contract below) and
  `DELETE /media/<id>`.

### The ledger lives on the Mac

There's one Mac per deployment and it makes every upload, so it can keep the index itself in
`~/.config/minirun/media.json`. Each entry holds: id, kind, bytes, created, expires, repo, ref,
URL. This means:

- The Worker needs no index, no Durable Object changes and no KV `list` calls, which have a
  1,000/day free limit.
- The storage cap is enforced on the Mac before upload. When an upload would exceed the cap, the
  oldest entries are deleted first.
- The menu bar app reads the ledger over the control socket, as it already does for jobs.
- Expired entries are pruned from the ledger lazily. KV has already deleted the objects.

## MCP tools

Keep the surface small: one flag on an existing tool, plus a start/stop pair. Recording needs two
calls because the agent has to tap and swipe while it records.

1. **`screenshot` gets `share: boolean`** (and an optional `caption`). With `share: true` it still
   returns the image to the agent, plus:
   ```
   Shared: https://minirun.you.workers.dev/m/Xb3…q.jpg (expires 2026-11-30)
   Markdown: ![Settings screen, dark mode](https://minirun.you.workers.dev/m/Xb3…q.jpg)
   ```
   Shared screenshots are captured at 2x points, not 1x, so they look sharp in a PR. The copy for
   the agent stays at 1x points.
2. **`start_recording {device, max_seconds?}`** starts recording that simulator. Use
   `simctl io <udid> recordVideo --codec=h264` to start: it's the least code, and the process
   stops cleanly on SIGINT. If it misbehaves on Xcode 27's Device Hub, put the existing
   `ScreenEncoder` H.264 frames into an `AVAssetWriter` instead. `max_seconds` defaults to
   `maxRecordingSeconds` (60). When the time runs out the recording stops by itself, so a forgotten
   recording can't run forever or hold the simulator. Allow one recording per simulator.
3. **`stop_recording {device, share?: true, caption?}`** stops the recording. It makes the GIF on
   the Mac with `AVAssetImageGenerator` and ImageIO's GIF encoder (`CGImageDestination`): about
   10 fps, 320 points wide, no ffmpeg. If the GIF comes out over `mediaInlineLimitMB`, lower the
   fps or width and encode again. Then it uploads both files and returns:
   ```
   Markdown: [![Onboarding flow](…/m/Ab9….gif)](…/m/Ab9…)
   ```
   That's an inline looping GIF; clicking it opens the MP4 player page. With `share: false` it
   only returns a few still frames to the agent, for checking its own work.
4. **`delete_media {id}`** lets an agent take back a wrong upload, but only one made with the same
   repo+ref. It's small, and it saves the owner from cleaning up after agents.

Uploads are tagged with the caller's `repo` + `ref` if it passes them. The simulator reservation
already knows them, so take them from there and the agent doesn't have to.

**Add this to `INSTRUCTIONS` in `worker/src/mcp.ts`:** "To show your work in a PR, call
`screenshot {share:true}` or `start_recording`/`stop_recording` and paste the returned markdown
into the PR description. Before recording, set `configure_simulator {status_bar: 'demo'}`.
Never share screens showing credentials or personal data."

## Cleanup

Plan for three levels; the first one does most of the work:

1. **TTL (automatic, built in).** Every object is written with `expirationTtl`. The default is 7
   days, and Settings offers 1, 7, 30 or 90. Expiry costs nothing and needs no code. After that the
   PR shows a broken image. For a verification screenshot that's fine; once merged, the code is
   the record. Make this clear in the settings text.
2. **Storage cap (automatic).** The default is 500 MB, about half the KV free limit, leaving room.
   The Mac deletes the oldest objects before an upload would go over it.
3. **Delete when the PR closes (optional, phase 2).** The Mac already has `gh`. About once an hour,
   for each repo+ref in the ledger, run `gh pr view <ref> --json state`, and delete that branch's
   media N days after the PR merged or closed. It's off by default because merged PRs are often
   reread soon after merging.

Note: GitHub's image proxy caches images, so a deleted image can still show in a PR for a while.
"Delete" means "stop serving", not "erase from everywhere". Capability URLs are public to anyone
holding the link, which matters for private repos. Say so in Settings.

## Menu bar app

- **Menu:** a "Shared media" row, e.g. `14 items · 38 MB`, with a submenu listing the latest ~10:
  `you/app@branch · recording · 2h ago`. Each item has *Open*, *Copy link* and *Delete*. At the
  bottom: *Delete all shared media…*, with a confirmation.
- **Settings → Sharing** (a new pane, backed by `config.json` like the other settings and
  reloaded live):
  - *Let Claude share screenshots and recordings* (on by default). When it's off, `share: true`
    fails with a clear message, and the agent still gets the image itself.
  - *Keep shared media for* 1 / 7 / 30 / 90 days (default 7).
  - *Storage limit*, default 500 MB.
  - *Longest recording*, default 60 s.
  - *Largest inline GIF*, default 5 MB (raise it after running the size probes).
  - *Delete media when its PR closes* (phase 2).
- **Recording indicator:** while any simulator is recording, show a red dot on the menu bar icon
  and add *Stop recording* to that simulator's row in the menu. You can tell what's being
  captured and stop it.
- **Setup and deploy:** `WorkerDeployer` creates or adopts `MEDIA_KV` alongside `OAUTH_KV`. Older
  Workers have no `/media` route, so the existing version mismatch shown by `mac_status` and the
  menu tells the user to redeploy. The share tools return "Redeploy the Worker from Settings to
  enable sharing" instead of failing with no explanation.

## Finding the real size limit

`GET /m/probe/<n>.gif` (n = 1 to 25, in MB) returns a valid animated GIF padded to exactly n MB,
generated on the fly with nothing stored. To find GitHub's real limit, put probes into a PR
description:

```markdown
| 4 MB | 6 MB | 8 MB | 10 MB | 15 MB | 20 MB | 25 MB |
| --- | --- | --- | --- | --- | --- | --- |
| ![](https://minirun.you.workers.dev/m/probe/4.gif) | ![](https://minirun.you.workers.dev/m/probe/6.gif) | … |
```

Then set `mediaInlineLimitMB` to the largest size that renders. KV's 25 MiB value limit is the
ceiling either way. The MP4 is only linked, never proxied, so it can always use the full 25 MiB.

## Implementation contract

What the Worker and the Mac agree on, so they can be built separately.

### Worker HTTP API

- `PUT /media/<id>.<ext>`: requires `Authorization: Bearer <AGENT_TOKEN>`.
  - `<id>` matches `^[A-Za-z0-9_-]{22}$` (16 random bytes, base64url, chosen by the Mac).
    `<ext>` is one of `jpg`, `png`, `gif`, `mp4`.
  - The body is the raw bytes. Header `X-Minirun-Expires-In` is the TTL in seconds: required,
    from 60 to 7,776,000 (90 days). Optional `X-Minirun-Caption` is percent-encoded and up to
    200 characters.
  - Stored in `MEDIA_KV` under key `<id>.<ext>`, with `expirationTtl` and metadata
    `{ type, bytes, caption?, created }`.
  - Replies `201 {"url": "https://<host>/m/<id>.<ext>"}`. `401` for a bad token, `400` for a bad
    id, ext or TTL, `413` for a body over 25 MiB.
- `DELETE /media/<id>`: agent token. Deletes `<id>.jpg|png|gif|mp4` and replies `204`.
- `GET|HEAD /m/<id>.<ext>`: public. Content-Type comes from the ext. Sends
  `Cache-Control: public, max-age=31536000, immutable`, `X-Robots-Tag: noindex`,
  `X-Content-Type-Options: nosniff`, and `Accept-Ranges: bytes`. Answers single-range
  `Range` requests with `206` (Safari needs these to play MP4). `404` if missing.
- `GET /m/<id>`: public HTML player page when `<id>.mp4` exists: `<video controls playsinline>`
  with the caption. `404` otherwise. Robots `noindex`.
- `GET|HEAD /m/probe/<n>.gif`: public size probe, n from 1 to 25, as above.

### Mac config (`config.json`)

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `shareMedia` | Bool | `true` | Whether `share` uploads are allowed |
| `mediaRetentionDays` | Int | `7` | TTL for uploads, clamped to 1–90 |
| `mediaStorageLimitMB` | Int | `500` | Delete the oldest uploads to stay under this |
| `maxRecordingSeconds` | Int | `60` | Recordings stop by themselves after this, clamped to 5–300 |
| `mediaInlineLimitMB` | Int | `5` | The largest GIF to embed; shrink the GIF to fit |

The media base URL comes from `relayURL` the same way `viewerURL` is derived
(`wss://host/agent` becomes `https://host`).

### Ledger (`~/.config/minirun/media.json`)

An array of `MediaItem`:
`{ id, kind: "screenshot"|"recording", files: [{ext, bytes}], createdAt, expiresAt, repo?, ref?, caption?, url }`.
`url` is the page to open: `/m/<id>.jpg` for screenshots, `/m/<id>` for recordings.

### Control socket (`controlVersion` 3)

- New commands: `list_media` (fills `Response.media: [MediaItem]`), `delete_media` (`id`),
  `delete_all_media`, `stop_recording` (`udid`).
- `ServeStatus.media: { count, bytes }?` and `ServeStatus.Simulator.recording: Bool`, which
  decodes as `false` when missing.

## Phases

1. **Worker:** add the `MEDIA_KV` binding, `PUT/DELETE /media`, `GET /m/<id>[.ext]`, and the
   player page, with vitest coverage (bad token, oversize body, unknown id, TTL passed through).
   Deployer: add the second namespace. Instructions text.
2. **Mac, screenshots:** media ledger and uploader in MiniRunKit (tested on Linux with a fake
   HTTP client), the `screenshot share` flag, `delete_media`, config keys and control-socket
   commands.
3. **Mac, recordings:** `start_recording`/`stop_recording`, auto-stop, GIF encoding with size
   back-off.
4. **Menu bar app:** the Shared media section, the Sharing settings pane, the recording indicator.
5. **Optional:** delete media when its PR closes, using `gh`.
