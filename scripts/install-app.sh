#!/bin/bash
# Builds the menu bar app (App/), ad-hoc signs it and installs it as /Applications/minirun.app.
# The app shows what `minirun serve` is doing; install the daemon itself with scripts/install.sh,
# which runs this script at the end.
#
#   ./scripts/install-app.sh               build, install and open
#   ./scripts/install-app.sh --build-only  just build (CI uses this)
#   ./scripts/install-app.sh --uninstall
#
# There's no Apple Developer ID behind this, so the app is ad-hoc signed and not notarized. A copy
# built on this Mac has no quarantine flag, so Gatekeeper doesn't stop it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="/Applications/minirun.app"
BUNDLE_ID="dev.minirun.menu"
BUILD_ONLY=false

case "${1:-}" in
  --build-only) BUILD_ONLY=true ;;
  --uninstall)
    osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
    rm -rf "$DEST"
    echo "Removed $DEST."
    exit 0 ;;
  "") ;;
  *) echo "Unknown option: $1 (see the top of $0)"; exit 1 ;;
esac

command -v xcodegen >/dev/null || brew install xcodegen
(cd "$ROOT/App" && xcodegen generate --quiet)

DERIVED="$ROOT/.build/app"
xcodebuild -quiet -project "$ROOT/App/minirun-menu.xcodeproj" -scheme minirun-menu -configuration Release \
  -derivedDataPath "$DERIVED" -destination "generic/platform=macOS" build \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
APP="$DERIVED/Build/Products/Release/minirun.app"
[[ -d "$APP" ]] || { echo "The build didn't produce $APP"; exit 1; }
codesign --force --deep --sign - "$APP"
echo "Built $APP"
$BUILD_ONLY && exit 0

# Replace a running copy.
osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "Installed $DEST"
open "$DEST"
