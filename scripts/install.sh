#!/bin/bash
# One-time setup on the Mac: builds minirun, deploys the Cloudflare Worker (if needed), and
# installs a LaunchAgent so `minirun serve` starts at login and restarts if it crashes.
#
#   ./scripts/install.sh            build, deploy Worker, install and start
#   ./scripts/install.sh --no-worker   skip the Worker (already deployed; run `minirun setup` yourself)
#   ./scripts/install.sh --uninstall
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="$HOME/.minirun"
LABEL="dev.minirun.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/minirun/minirun.log"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  rm -rf "$PREFIX/bin"
  echo "minirun removed (config in ~/.config/minirun and workspaces in ~/minirun were kept)."
  exit 0
fi

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "Checking prerequisites"
xcode-select -p >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1 || {
  echo "Install Xcode from the App Store, open it once, then run: sudo xcode-select -s /Applications/Xcode.app"; exit 1; }
command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }
for tool in xcodegen node gh; do command -v "$tool" >/dev/null || brew install "$tool"; done
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
echo "Installed to $PREFIX/bin/minirun"

if [[ "${1:-}" != "--no-worker" ]] && ! grep -q '"relayURL"' "$HOME/.config/minirun/config.json" 2>/dev/null; then
  step "Deploying the Cloudflare Worker"
  "$ROOT/worker/setup.sh"
  source "$HOME/.config/minirun/worker.env"
  "$PREFIX/bin/minirun" setup --relay "$WORKER_URL" --token "$AGENT_TOKEN"
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

if [[ -f "$HOME/.config/minirun/worker.env" ]]; then
  source "$HOME/.config/minirun/worker.env"
  cat <<DONE

All set. Next:
  1. In Claude (claude.ai → Settings → Connectors → Add custom connector), add:
       $WORKER_URL/mcp
     and approve it with your password: $OWNER_PASSWORD
  2. Watch the simulator live at $WORKER_URL/

Logs: $LOG
DONE
fi
