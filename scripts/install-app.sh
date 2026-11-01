#!/bin/bash
# Builds the menu bar app (App/), ad-hoc signs it and installs it as /Applications/minirun.app.
# scripts/install.sh runs this with --with-daemon, so the app carries minirun itself:
#
#   minirun.app/Contents/MacOS/minirun          the menu bar app (links MiniRunKit only)
#   minirun.app/Contents/Helpers/minirun        the CLI and `minirun serve`, run by the LaunchAgent
#   minirun.app/Contents/Frameworks/FB*.framework   the simulator frameworks the helper loads
#   minirun.app/Contents/Frameworks/WebRTC.framework libwebrtc, for live view over WebRTC
#   minirun.app/Contents/Resources/worker/      the prebuilt Worker that `minirun worker deploy` uploads
#   minirun.app/Contents/Resources/github-runner.sh   what Settings → GitHub Runners runs
#
#   ./scripts/install-app.sh [--with-daemon BIN_DIR]   build, install and open
#   ./scripts/install-app.sh --build-only [--with-daemon BIN_DIR]   just build (CI and releases use this)
#   ./scripts/install-app.sh --uninstall
#
# BIN_DIR is `swift build --show-bin-path` after `swift build` (and scripts/build-frameworks.sh).
# Without --with-daemon the app only watches a daemon installed some other way.
#
# There's no Apple Developer ID behind this, so the app is ad-hoc signed and not notarized. A copy
# built on this Mac has no quarantine flag, so Gatekeeper doesn't stop it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="/Applications/minirun.app"
BUNDLE_ID="dev.minirun.menu"
BUILD_ONLY=false NO_OPEN=false
DAEMON_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only) BUILD_ONLY=true ;;
    --no-open) NO_OPEN=true ;;
    --with-daemon)
      [[ -n "${2:-}" ]] || { echo "--with-daemon needs the folder swift build put minirun in"; exit 1; }
      DAEMON_DIR="$2"; shift ;;
    --uninstall)
      osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
      rm -rf "$DEST"
      echo "Removed $DEST."
      exit 0 ;;
    *) echo "Unknown option: $1 (see the top of $0)"; exit 1 ;;
  esac
  shift
done

command -v xcodegen >/dev/null || brew install xcodegen
(cd "$ROOT/App" && xcodegen generate --quiet)

DERIVED="$ROOT/.build/app"
xcodebuild -quiet -project "$ROOT/App/minirun-menu.xcodeproj" -scheme minirun-menu -configuration Release \
  -derivedDataPath "$DERIVED" -destination "generic/platform=macOS" build \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
APP="$DERIVED/Build/Products/Release/minirun.app"
[[ -d "$APP" ]] || { echo "The build didn't produce $APP"; exit 1; }

if [[ -n "$DAEMON_DIR" ]]; then
  [[ -x "$DAEMON_DIR/minirun" ]] || { echo "No minirun in $DAEMON_DIR. Run swift build first."; exit 1; }
  rm -rf "$APP/Contents/Helpers" "$APP/Contents/Frameworks" "$APP/Contents/Resources/worker"
  mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
  cp "$DAEMON_DIR/minirun" "$APP/Contents/Helpers/minirun"
  for fw in FBControlCore FBSimulatorControl FBDeviceControl XCTestBootstrap; do
    src="$DAEMON_DIR/$fw.framework"
    [[ -d "$src" ]] || src="$ROOT/Vendor/XCFrameworks/$fw.xcframework/macos-arm64_x86_64/$fw.framework"
    [[ -d "$src" ]] || { echo "Missing $fw.framework. Run scripts/build-frameworks.sh first."; exit 1; }
    cp -R "$src" "$APP/Contents/Frameworks/"
    codesign --force --sign - "$APP/Contents/Frameworks/$fw.framework" >/dev/null
  done
  # libwebrtc comes with the package (a binary target SwiftPM downloads), not from Vendor/.
  src="$DAEMON_DIR/WebRTC.framework"
  [[ -d "$src" ]] || src="$(ls -d "$ROOT"/.build/artifacts/*/WebRTC/WebRTC.xcframework/macos-*/WebRTC.framework 2>/dev/null | head -1)"
  [[ -d "$src" ]] || { echo "Missing WebRTC.framework. Run swift build first."; exit 1; }
  cp -R "$src" "$APP/Contents/Frameworks/"
  codesign --force --sign - "$APP/Contents/Frameworks/WebRTC.framework" >/dev/null
  cp -R "$ROOT/worker/dist" "$APP/Contents/Resources/worker"
  codesign --force --sign - "$APP/Contents/Helpers/minirun" >/dev/null
  # Proves the helper finds its frameworks inside the bundle (dyld fails at launch otherwise).
  "$APP/Contents/Helpers/minirun" version >/dev/null || { echo "The bundled minirun doesn't start; see the error above."; exit 1; }
fi
# Settings → GitHub Runners runs the same script as the command line.
install -m 755 "$ROOT/scripts/github-runner.sh" "$APP/Contents/Resources/github-runner.sh"
codesign --force --sign - "$APP"
echo "Built $APP"
$BUILD_ONLY && exit 0

# Replace a running copy. The daemon keeps running from the old path until the app (or
# install.sh) points the LaunchAgent at the new one, so Claude's sessions stay up.
osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "Installed $DEST"
$NO_OPEN || open "$DEST"
