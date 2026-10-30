#!/bin/bash
# One-time setup on the Mac: builds minirun, deploys the Cloudflare Worker (if needed), and
# installs a LaunchAgent so `minirun serve` starts at login and restarts if it crashes.
# The Worker is deployed with the Cloudflare API by `minirun worker deploy`; no node needed. It
# asks for a Cloudflare API token, or takes one from $MINIRUN_CLOUDFLARE_TOKEN.
#
#   ./scripts/install.sh            build, deploy or update the Worker, install and start
#   ./scripts/install.sh --no-worker   skip the Worker (run `minirun worker deploy` yourself)
#   ./scripts/install.sh --no-app      skip the menu bar app (scripts/install-app.sh)
#   ./scripts/install.sh --uninstall
#
# Optionally also registers this Mac as a self-hosted GitHub Actions runner (see scripts/github-runner.sh):
#   ./scripts/install.sh --github-runner owner/repo [--github-runner owner/other] [--allow-public]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="$HOME/.minirun"
LABEL="dev.minirun.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/minirun/minirun.log"

UNINSTALL=false NO_WORKER=false NO_APP=false ALLOW_PUBLIC=false
GITHUB_RUNNERS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) UNINSTALL=true ;;
    --no-worker) NO_WORKER=true ;;
    --no-app) NO_APP=true ;;
    --github-runner)
      [[ -n "${2:-}" ]] || { echo "--github-runner needs a repository: --github-runner owner/repo"; exit 1; }
      GITHUB_RUNNERS+=("$2"); shift ;;
    --allow-public) ALLOW_PUBLIC=true ;;
    *) echo "Unknown option: $1 (see the top of $0)"; exit 1 ;;
  esac
  shift
done

if $UNINSTALL; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  rm -rf "$PREFIX/bin" "$PREFIX/worker"
  "$ROOT/scripts/install-app.sh" --uninstall
  echo "minirun removed (config in ~/.config/minirun and workspaces in ~/minirun were kept)."
  if compgen -G "$PREFIX/github-runner/*/" >/dev/null; then
    echo "GitHub runners are still installed; remove each with: $ROOT/scripts/github-runner.sh uninstall owner/repo"
    "$ROOT/scripts/github-runner.sh" status || true
  fi
  exit 0
fi

# Fail on a bad repository name now, not after a long build.
for repo in ${GITHUB_RUNNERS[@]+"${GITHUB_RUNNERS[@]}"}; do
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "--github-runner expects owner/repo, got '$repo'"; exit 1; }
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "Checking prerequisites"
xcode-select -p >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1 || {
  echo "Install Xcode from the App Store, open it once, then run: sudo xcode-select -s /Applications/Xcode.app"; exit 1; }
command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }
for tool in xcodegen gh; do command -v "$tool" >/dev/null || brew install "$tool"; done
xcrun simctl list runtimes | grep -q "iOS" || echo "warning: no iOS simulator runtime installed (Xcode > Settings > Components)."

step "Building simulator frameworks (first run takes a few minutes)"
"$ROOT/scripts/build-frameworks.sh"

step "Building minirun"
(cd "$ROOT" && swift build -c release)
BIN_DIR="$(cd "$ROOT" && swift build -c release --show-bin-path)"
mkdir -p "$PREFIX/bin"
rm -rf "$PREFIX/bin/"*.framework
cp "$BIN_DIR/minirun" "$PREFIX/bin/minirun"
for fw in FBControlCore FBSimulatorControl FBDeviceControl XCTestBootstrap; do
  src="$BIN_DIR/$fw.framework"
  [[ -d "$src" ]] || src="$ROOT/Vendor/XCFrameworks/$fw.xcframework/macos-arm64_x86_64/$fw.framework"
  cp -R "$src" "$PREFIX/bin/"
done
codesign --force --sign - --deep "$PREFIX/bin/minirun" >/dev/null 2>&1 || true
# The prebuilt Worker that `minirun worker deploy` uploads (made by `npm run bundle` in worker/).
rm -rf "$PREFIX/worker"
cp -R "$ROOT/worker/dist" "$PREFIX/worker"
echo "Installed to $PREFIX/bin/minirun"

CONFIG_DIR="$HOME/.config/minirun"
if ! $NO_WORKER; then
  if ! grep -q '"relayURL"' "$CONFIG_DIR/config.json" 2>/dev/null || [[ -f "$CONFIG_DIR/worker.json" ]]; then
    # First install, or a Worker this Mac manages: deploy, or update it to match this build.
    step "Deploying the Cloudflare Worker"
    "$PREFIX/bin/minirun" worker deploy
  else
    echo
    echo "Your Worker was deployed with worker/setup.sh. To update it from this Mac from now on (no node"
    echo "needed), run: $PREFIX/bin/minirun worker deploy"
  fi
fi

step "Installing the LaunchAgent"
mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
cat > "$PLIST" <<PLIST_END
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$PREFIX/bin/minirun</string><string>serve</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST_END
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 3

step "Checking"
"$PREFIX/bin/minirun" doctor || true
tail -n 5 "$LOG" || true

if ! $NO_APP; then
  step "Installing the menu bar app"
  "$ROOT/scripts/install-app.sh" || echo "warning: the menu bar app didn't build. minirun itself is installed; retry with $ROOT/scripts/install-app.sh"
fi

for repo in ${GITHUB_RUNNERS[@]+"${GITHUB_RUNNERS[@]}"}; do
  step "Setting up a GitHub Actions runner for $repo"
  args=(install "$repo")
  $ALLOW_PUBLIC && args+=(--allow-public)
  "$ROOT/scripts/github-runner.sh" "${args[@]}" || {
    echo "The GitHub runner for $repo wasn't set up. minirun itself is installed; fix the above and run:"
    echo "  $ROOT/scripts/github-runner.sh ${args[*]}"
    exit 1; }
done

WORKER_URL=$(grep -oE '"relayURL" *: *"[^"]+"' "$CONFIG_DIR/config.json" 2>/dev/null | sed -E 's/.*"(wss?:[^"]+)"$/\1/; s#^wss://#https://#; s#^ws://#http://#; s#/agent$##' || true)
if [[ -n "$WORKER_URL" ]]; then
  OWNER_PASSWORD=$("$PREFIX/bin/minirun" worker password 2>/dev/null || echo "(run: $PREFIX/bin/minirun worker password)")
  cat <<DONE

All set. Next:
  1. In Claude (claude.ai → Settings → Connectors → Add custom connector), add:
       $WORKER_URL/mcp
     and approve it with your password: $OWNER_PASSWORD
  2. Watch the simulator live at $WORKER_URL/

Logs: $LOG
DONE
fi
