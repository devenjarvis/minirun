# minirun

Turn a Mac (a home Mac mini is ideal) into a runner that Claude can drive from anywhere: it
builds your iOS app, runs it in a simulator, taps through it, reads logs, runs tests, and streams
the simulator live to your phone or laptop's browser so you can watch and take over.

Everything runs on hardware you own plus Cloudflare's free plan. There's no domain to buy, no
open ports, and no tunnel to run.

```
 Claude (phone, web, laptop)            Your browser (phone/laptop)
        │  MCP over HTTPS + OAuth               │  live JPEG stream + touches
        ▼                                       ▼
 ┌──────────────────── Cloudflare Worker (minirun.<you>.workers.dev) ────────────────────┐
 │  /mcp  OAuth-protected MCP endpoint      /  viewer (password login)                    │
 │                     └──────────► Durable Object relay ◄──────────┘                     │
 └──────────────────────────────────────────▲─────────────────────────────────────────────┘
                                            │ one outbound WebSocket (AGENT_TOKEN)
                                 ┌──────────┴──────────┐
                                 │  minirun serve (Mac) │  Swift daemon (launchd)
                                 │  xcodebuild · simctl │
                                 │  FBSimulatorControl  │  in-process touch, screen, accessibility
                                 └─────────────────────┘
```

## How it works

- **`minirun` (Swift, on the Mac)** links Meta's FBSimulatorControl (the framework inside idb)
  in-process for screen capture, touch/keyboard injection and accessibility trees. It uses
  AXe's vendored helpers for the hard parts, like Xcode 27's Device Hub and orientation. App
  lifecycle goes through `simctl`, and builds go through `xcodebuild`. It holds one outbound
  WebSocket to your Worker.
- **The Worker (TypeScript)** is a remote MCP server that Claude connects to as a custom
  connector, protected by OAuth that you approve with your password. Tool calls are forwarded
  to the Mac through a Durable Object. The same object fans the live screen out to browser viewers.
- **Long work runs as jobs.** `build`, `build_and_run`, `run_tests` and `run_command` return
  within `wait_seconds` (default 45). If the work is still going they return a `job_id`, and
  Claude waits on it with `get_job`. Long builds never hit request timeouts.

## Setup

On the Mac (Apple silicon, macOS 14+, Xcode 26 or 27 with an iOS simulator runtime):

```bash
git clone https://github.com/devenjarvis/minirun && cd minirun
./scripts/install.sh
```

That script:

1. Installs `xcodegen`, `node` and `gh` with Homebrew if missing.
2. Builds the FBSimulatorControl frameworks from AXe's pinned idb fork (a few minutes, once).
3. Builds `minirun` and installs it to `~/.minirun/bin`.
4. Deploys the Worker to your Cloudflare account. It opens a browser to log in, creates a KV
   namespace, and generates a password and an agent token, saved in `~/.config/minirun/worker.env`.
5. Installs a LaunchAgent so `minirun serve` starts at login and restarts if it crashes.

Then:

1. **Connect Claude.** In claude.ai, go to Settings → Connectors → Add custom connector and enter
   `https://minirun.<you>.workers.dev/mcp`. Approve with your minirun password. Once added it
   also works in the Claude mobile app.
2. **Watch live** at `https://minirun.<you>.workers.dev/` from any browser. Tap and swipe on the
   screen, type with the box at the bottom, and pick a stream quality (Saver, Smooth or Sharp).

For private repositories, run `gh auth login && gh auth setup-git` on the Mac so it can clone them.

For headless Mac minis, set the Mac to never sleep and to log in automatically. Simulators need
a logged-in GUI session; `minirun serve` already blocks idle sleep while it runs.

## The loop Claude follows

1. Claude edits code in its own environment and pushes a branch.
2. `build_and_run {repo: "you/app", ref: "my-branch"}` syncs, builds, installs and launches the
   app, then returns a screenshot. If the build fails, it returns the errors with `file:line`.
3. `describe_ui` gives the accessibility tree, then `tap {id: "loginButton"}`, `type_text`,
   `swipe`, and `screenshot` to look. `app_logs` reads the app's output.
4. `run_tests` runs the tests and reports pass/fail with failure messages.
5. `mac_status` gives Claude the viewer link to share with you.

## Tools

| Area | Tools |
| --- | --- |
| Simulators | `list_simulators`, `boot_simulator`, `shutdown_simulator`, `configure_simulator` (dark mode, location, demo status bar, permissions) |
| Seeing | `screenshot` (sized so pixels = points), `describe_ui` (compact text or full JSON) |
| Touching | `tap` (x/y or id/label/value), `swipe` (points or direction), `long_press` (also drag), `type_text`, `press_key`, `press_button`, `open_url`, `set_pasteboard` |
| Apps | `install_app`, `launch_app`, `terminate_app`, `uninstall_app`, `app_logs`, `add_media` |
| Code | `sync_repo`, `list_schemes`, `build`, `build_and_run`, `run_tests`, `run_command` (opt-in) |
| Jobs | `get_job`, `job_log`, `list_jobs` |
| Host | `host_info`, `mac_status` (served by the Worker) |

Try any tool locally: `~/.minirun/bin/minirun call describe_ui` or
`minirun call tap '{"label":"General"}'`.

## Configuration

`~/.config/minirun/config.json` (written by `minirun setup`):

| Key | Default | |
| --- | --- | --- |
| `relayURL` | — | `wss://minirun.<you>.workers.dev/agent` |
| `agentToken` | — | Must match the Worker's `AGENT_TOKEN` secret |
| `workspaceRoot` | `~/minirun/workspaces` | Where repositories are cloned |
| `defaultDevice` | newest iPhone | Simulator to boot when none is running, e.g. `"iPhone 17 Pro"` |
| `allowShell` | `false` | Enables `run_command`: arbitrary shell commands on your Mac |
| `preventSleep` | `true` | Blocks idle sleep while serving |

After editing, restart: `launchctl kickstart -k gui/$(id -u)/dev.minirun.agent`.

## Security

- The Mac only makes outbound connections. The Worker accepts the Mac's WebSocket only with
  `AGENT_TOKEN`.
- Claude's connector uses OAuth 2.1 with PKCE (`@cloudflare/workers-oauth-provider`). Every
  approval asks for your password, even if you're already logged in to the viewer.
- Viewers log in with the same password (30-day signed cookie). They can only send touch and
  keyboard input, not run tools like `build` or `run_command`.
- `run_command` is off by default. Turning it on lets anyone holding a connector token run shell
  commands on your Mac, so keep the password private.
- Rotate secrets with `worker/setup.sh --new-password` or `--new-token`. A new token also needs
  `minirun setup --token …` on the Mac.

## Costs (Cloudflare free plan)

Workers, one SQLite Durable Object and KV all fit in the free tier for one person. Streaming
uses Durable Object requests, roughly 1–2 per second at the default 12 fps. That works out to
many hours of viewing a day within the free 100k requests. The viewer stops streaming when its
tab is hidden.

## Limitations (v0.1)

- One Mac per Worker deployment. Simulators only for UI control (physical devices are planned).
- `type_text` types US-keyboard characters. For other text, use `set_pasteboard` and paste.
- The live view is JPEG frames, up to about 30 fps. A hardware H.264 stream is next.

## Development

```bash
swift test                       # MiniRunKit unit tests (any platform)
./scripts/build-frameworks.sh    # macOS: FBSimulatorControl into Vendor/
swift build && ./scripts/smoke-test.sh   # macOS: boots a simulator and drives a fixture app
cd worker && npm ci && npm test  # Worker tests (OAuth flow, relay, viewer) in workerd
```

CI runs all of the above on GitHub's macOS runners. If a run fails, the logs are pushed to the
`ci-logs` branch.

## Credits

Simulator control builds on [AXe](https://github.com/cameroncooke/AXe) by Cameron Cooke and
[idb](https://github.com/facebook/idb) by Meta, both MIT licensed. See `THIRD_PARTY_NOTICES.md`.
