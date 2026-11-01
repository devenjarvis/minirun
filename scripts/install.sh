#!/bin/bash
# One-time setup on the Mac: builds minirun and its menu bar app, installs /Applications/minirun.app,
# deploys the Cloudflare Worker (if needed), and installs a LaunchAgent so `minirun serve` (the
# app's helper, minirun.app/Contents/Helpers/minirun) starts at login and restarts if it crashes.
# The Worker is deployed with the Cloudflare API by `minirun worker deploy`; no node needed. It
# asks for a Cloudflare API token, or takes one from $MINIRUN_CLOUDFLARE_TOKEN. With --no-worker,
# the app's setup window asks for the token instead.
#
#   ./scripts/install.sh               build, install the app, deploy or update the Worker, start
#   ./scripts/install.sh --no-worker   skip the Worker (the app's setup window or `minirun worker deploy` does it)
#   ./scripts/install.sh --no-app      no menu bar app: install minirun to ~/.minirun/bin as before
#   ./scripts/install.sh --uninstall   remove the app, the LaunchAgent and the minirun command
#
# Optionally also registers this Mac as a self-hosted GitHub Actions runner (see scripts/github-runner.sh):
#   ./scripts/install.sh --github-runner owner/repo [--github-runner owner/other] [--allow-public]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="$HOME/.minirun"
APP="/Applications/minirun.app"
LABEL="dev.minirun.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/minirun/minirun.log"
LINK="/usr/local/bin/minirun"
CONFIG_DIR="$HOME/.config/minirun"

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
  # The command line tool, if it's the link the app made.
  if [[ -L "$LINK" && "$(readlink "$LINK")" == *"minirun.app/Contents/Helpers/minirun" ]]; then
    rm -f "$LINK" 2>/dev/null || sudo rm -f "$LINK" || echo "Couldn't remove $LINK; delete it yourself."
  fi
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

if $NO_APP; then
  mkdir -p "$PREFIX/bin"
  rm -rf "$PREFIX/bin/"*.framework
  cp "$BIN_DIR/minirun" "$PREFIX/bin/minirun"
  for fw in FBControlCore FBSimulatorControl FBDeviceControl XCTestBootstrap; do
    src="$BIN_DIR/$fw.framework"
    [[ -d "$src" ]] || src="$ROOT/Vendor/XCFrameworks/$fw.xcframework/macos-arm64_x86_64/$fw.framework"
    cp -R "$src" "$PREFIX/bin/"
  done
  # libwebrtc, which SwiftPM downloaded for the build.
  cp -R "$BIN_DIR/WebRTC.framework" "$PREFIX/bin/"
  codesign --force --sign - "$PREFIX/bin/WebRTC.framework" >/dev/null 2>&1 || true
  codesign --force --sign - --deep "$PREFIX/bin/minirun" >/dev/null 2>&1 || true
  # The prebuilt Worker that `minirun worker deploy` uploads (made by `npm run bundle` in worker/).
  rm -rf "$PREFIX/worker"
  cp -R "$ROOT/worker/dist" "$PREFIX/worker"
  MINIRUN="$PREFIX/bin/minirun"
  echo "Installed to $MINIRUN"
else
  step "Building and installing the menu bar app"
  "$ROOT/scripts/install-app.sh" --with-daemon "$BIN_DIR" --no-open
  MINIRUN="$APP/Contents/Helpers/minirun"
fi

if ! $NO_WORKER; then
  if ! grep -q '"relayURL"' "$CONFIG_DIR/config.json" 2>/dev/null || [[ -f "$CONFIG_DIR/worker.json" ]]; then
    # First install, or a Worker this Mac manages: deploy, or update it to match this build.
    step "Deploying the Cloudflare Worker"
    if ! "$MINIRUN" worker deploy; then
      $NO_APP && exit 1
      echo "The Worker isn't deployed yet. The minirun app's setup window picks up from here."
    fi
  else
    echo
    echo "Your Worker was deployed with worker/setup.sh. To update it from this Mac from now on (no node"
    echo "needed), use Update Worker in the app's settings, or run: $MINIRUN worker deploy"
  fi
fi

step "Installing the LaunchAgent"
"$MINIRUN" agent install
if ! $NO_APP && [[ -d "$PREFIX/bin" ]]; then
  # The daemon used to live here; the app carries it now. Settings and workspaces are untouched.
  rm -rf "$PREFIX/bin" "$PREFIX/worker"
  echo "Removed the old copy in $PREFIX/bin."
fi
sleep 3

step "Checking"
"$MINIRUN" doctor || true
tail -n 5 "$LOG" || true

if ! $NO_APP; then
  open "$APP"
  if [[ ! -e "$LINK" ]]; then
    echo
    echo "For the minirun command in a terminal, choose Install Command Line Tool in the app's settings,"
    echo "or run: sudo ln -sf $MINIRUN $LINK"
  fi
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
  OWNER_PASSWORD=$("$MINIRUN" worker password 2>/dev/null || echo "(run: $MINIRUN worker password)")
  cat <<DONE

All set. Next:
  1. In Claude (claude.ai → Settings → Connectors → Add custom connector), add:
       $WORKER_URL/mcp
     and approve it with your password: $OWNER_PASSWORD
  2. Watch the simulator live at $WORKER_URL/

Logs: $LOG
DONE
fi
