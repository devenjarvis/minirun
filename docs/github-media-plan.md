# Media on GitHub, menu bar items, before/after: plan

Feedback from the Fetch repo (devenjarvis/fetch, spec FETCH-0033) after a week of sharing
screenshots in PRs. Four asks, reviewed and ordered below.

## What's actually broken

`screenshot {share}` and `stop_recording` upload to the Worker and return
`![…](https://minirun.<you>.workers.dev/m/<id>.jpg)`. Two problems with that link in a PR:

- **The GitHub tools strip it.** The GitHub MCP tools that agents post with drop the `!` from
  image markdown that points outside github.com, and escape `<img>` tags. The image turns into a
  plain link. (They also strip it from github.com links that aren't complete file links, such as
  placeholders or short SHAs.) `github.com/<repo>/blob/<sha>/<path>?raw=true` and
  `github.com/<repo>/raw/…` links survive, and they render for anyone who can see the repo,
  private repos included. `raw.githubusercontent.com` links survive but don't render for a
  private repo.
- **It expires.** The Worker's KV deletes it after 7 days by default.

Fetch works around both with `scripts/pr-media.sh`: the agent shares to the Worker, the script
downloads the file again, commits it to an orphan `pr-media` branch, pushes, and prints
`![name](https://github.com/<repo>/blob/<commit>/FETCH-NNNN/name.jpg?raw=true)`. A CI check
(`check-pr-media.sh`) fails UI PRs whose description doesn't embed an image in that exact form.

So the Worker link is fine for chat and the live view, but wrong for a PR description, and
minirun's own text tells agents to put it there.

## Decisions

| # | Ask | Decision | Why |
| --- | --- | --- | --- |
| 2 | Stop suggesting Worker links for PRs | **Do first** (hours) | One string and the instructions. It stops the mistake now, before (1) exists, for every repo. |
| 1 | Upload to GitHub directly | **Do next** (main work) | Removes a download/re-upload step, removes expiry, and works for any repo. The Mac already has `gh`. |
| 3 | Reach the menu bar item | **Do third** | A real gap: FETCH-0018 (p0, ready) can't be checked without it. Self-contained in `MiniRunMac`. |
| 4 | Before/after in one call | **Don't build as asked.** Ship a small version inside (1). | See [Before/after](#4-beforeafter). |

## 2. Reword the share result (do first)

Today `MediaSharing.report` ends with "Paste the markdown into the PR description." The
instructions in `worker/src/mcp.ts` say the same.

Change both so they say what the link is good for:

- Share result: "This link is hosted on your Worker, not github.com. The GitHub tools turn it
  into a plain link in a PR description, and it expires on <date>. Use it to check your work or
  in chat. For a PR, follow the repo's instructions for embedding media (for example a
  `pr-media` branch)." Keep the `delete_media` hint.
- Instructions: the "To show your work in a PR" section says the same in one line, and points at
  the repo's own instructions (AGENTS.md / CLAUDE.md) when it has any.

No per-repo setting: (1) makes it unnecessary, since a repo set up for GitHub media gets a
github.com link and different text automatically.

Tests: update the `MediaSharing.report` expectations; worker vitest for the instructions text if
one checks it.

## 1. Upload to GitHub

### Shape of the tool

Keep `share` a boolean, so the schema stays simple for every client. Add two optional strings
to `screenshot` and `stop_recording`:

- `folder`: the folder on the media branch, e.g. `FETCH-0032`. Default: the ref, with anything
  but letters, digits, `.`, `_` and `-` replaced by `-`.
- `name`: the file name without extension, e.g. `after`. Lowercase letters, digits and dashes.
  Default: a slug of the caption, else `screenshot-<hhmmss>`.

The repo comes from the simulator reservation or Mac app workspace label (`owner/app@branch`),
which minirun already reads to tag uploads. The agent never passes it, so it can't write to a
repo it isn't working on.

### Where it goes

`share: true` picks the destination by itself:

- **GitHub**, when the repo has the media branch (`pr-media` by default) on GitHub. A repo opts in
  by having that branch. Fetch already does; nothing to configure.
- **Worker**, otherwise, with the reworded text from (2), plus one line: "To get github.com
  embeds for this repo, ask the user to create an orphan `pr-media` branch."

Why opt in by branch, not by setting: it's per repo with no Mac config, it lives with the repo
(agents on any Mac get the same behaviour), and minirun never creates branches in a repo
nobody asked it to. minirun checks for the branch with `gh api repos/<repo>/branches/pr-media`
and caches the answer for 10 minutes.

New settings (Settings → Sharing, `config.json`):

| Key | Default | Meaning |
| --- | --- | --- |
| `githubMedia` | `true` | Use GitHub when the repo has the branch. Off: always the Worker. |
| `githubMediaBranch` | `"pr-media"` | The branch name. |

### How it uploads

Use the GitHub REST contents API through `gh api` rather than a git worktree:

1. `GET repos/<repo>/contents/<folder>/<name>.<ext>?ref=pr-media` to get the existing file's
   `sha`, if any (a re-upload with the same name replaces it, as `pr-media.sh` does).
2. `PUT repos/<repo>/contents/<folder>/<name>.<ext>` with `branch`, base64 `content`, `sha` if
   replacing, and the message `PR media for <folder>: <name>.<ext>`. The body goes through a
   temp file and `--input`, not the command line.
3. Read `commit.sha` from the reply and return the pinned embed:
   `![<caption or name>](https://github.com/<repo>/blob/<commit>/<folder>/<name>.<ext>?raw=true)`.
   This is exactly the form Fetch's CI check accepts.
4. On `409` (another agent moved the branch), retry up to 4 times with backoff, re-reading the
   `sha` each time.

Why not git: no clone or worktree, no touching any checkout, works for a repo that isn't checked
out on the Mac, one call per file. `gh` uses the Mac's sign-in, the same one `sync_repo` relies
on.

Errors: when `gh` isn't signed in or can't push to the repo, the share fails with the reason and
the fix (`gh auth login`, or "this account can't push to <repo>"). It does **not** quietly fall
back to the Worker, because that gives back the link that breaks. The agent still gets the image
itself.

### Recordings

Commit the GIF (it renders inline) and the MP4 next to it. The GIF links to the MP4's blob page.
The MP4 is only linked, so its size matters less; skip it when it's over 25 MB and link nothing.
Check during implementation that GitHub's blob page plays the MP4; if it doesn't, keep the GIF
alone and drop the MP4.

### Ledger and deletion

`MediaItem` gets `host` (`worker` or `github`), and for GitHub items `commit` and `path`. Old
ledgers decode as `worker`. The menu bar's Shared media list shows both, with "GitHub" on the
row.

GitHub items don't expire and can't really be taken back: the pinned commit keeps serving the
file. `delete_media` on one removes the file from the branch tip and says plainly that the
pinned link keeps working until the branch history is rewritten. This makes "never share
credentials or personal data" matter more, so the tool descriptions and the share result say
it again for GitHub uploads. The storage cap and retention settings apply only to the Worker.

### Tests

- MiniRunKit, on Linux, with a fake `gh` runner: destination choice (branch present, absent,
  setting off), folder and name defaults and validation, the request body, `409` retry,
  replacing an existing name, the exact embed string, the error text for an unsigned or
  read-only `gh`.
- On the Mac, once: share a screenshot from a Fetch branch, paste it into a draft PR with the
  GitHub MCP tool, read the body back, and check it still has the `!` and the Visual evidence
  check passes.

### Afterwards, in Fetch (their change, not ours)

`AGENTS.md` step 2 becomes "pass `folder: \"FETCH-NNNN\"` and `name`"; `pr-media.sh` stays for
local files.

## 3. Menu bar items for Mac apps

Two things hide Fetch's `MenuBarExtra` today:

- `MacAppDriver.readWindows` keeps only windows at layer 0. The status item and the
  `.window`-style panel live at higher levels, so `list_windows` and `screenshot` can't see them,
  and an app with only a menu bar item gets "has no windows open".
- `describe_ui {include_menus}` walks the app's `AXMenuBar` (File, Edit, …) but not its
  `AXExtrasMenuBar`, which holds the app's own menu bar items.

Plan:

1. **See the item.** `describe_ui` adds the app's `AXExtrasMenuBar` when `include_menus` is set,
   and always lists it in `list_windows` as "menu bar item: Fetch". It's this app's items only,
   never other apps'.
2. **Open it.** `press_menu_item {path: ["menu bar"]}` (or the item's label when an app has more
   than one) sends `AXPress` to the item. That opens a menu-style extra or a panel-style one
   without moving the mouse.
3. **See and use the panel.** `readWindows` also keeps the app's on-screen windows above layer 0
   that aren't the status item itself, marked `kind: "menu bar panel"` (and `"menu"` for open
   menus). `window: "menu bar panel"` selects it in `screenshot`, `describe_ui`, `tap` and the rest,
   with frames in that window's points as usual. `screenshot {share}` works on it.
4. **Picture the icon.** `screenshot {window: "menu bar item"}` captures a strip of the menu bar
   around the item, about 200 × 24 points, so a count badge (FETCH-0018 AC-4) can be shown in
   a PR.

Things to watch:

- The panel closes when it loses focus. Clicking elsewhere through minirun closes it, which is
  correct. Screenshots don't take focus.
- On a Mac with a notch, items can be hidden behind it. When the item's frame is off screen, say
  so.
- Tests: window filtering on recorded `CGWindowList` fixtures (MiniRunKit, Linux). On the Mac,
  a fixture app with a `.window` and a `.menu` `MenuBarExtra`, in the existing Mac test target.

## 4. Before/after

Running `main` and the branch side by side in one call is more than it looks for Mac apps: two
builds of the same bundle id share defaults and single-instance behaviour, and often a menu bar
item. Getting the same state on both is the agent's job anyway. The agent can already do it in
order: build `main`, screenshot, build the branch, screenshot.

What would make every UI PR consistent comes almost free with (1): when a share lands in a folder
that already has `before` and this one is `after` (or the other way round), the result also
gives a ready two-column table:

```
| Before | After |
| --- | --- |
| ![before](…/before.jpg?raw=true) | ![after](…/after.jpg?raw=true) |
```

No stitched image: two images in a table are as easy to read, and each stays sharp and
replaceable. Revisit a one-call version only if agents keep getting the state wrong.

## Order of work

1. (2) Reworded text and instructions. One PR.
2. (1) GitHub upload with the before/after table. One PR in MiniRunKit + tools, one for the
   Settings pane and the menu's Shared media rows. Release.
3. (3) Menu bar items. One PR. Release before FETCH-0018 is picked up.

## Open questions

- Opt in by branch (above) or by a list of repos in Settings? Branch is recommended; a list
  is easy to add later if a repo can't have the branch.
- Commit the MP4 for recordings, or the GIF only? Recommended: the MP4 too, if the blob page plays
  it.
