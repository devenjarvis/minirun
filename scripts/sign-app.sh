#!/bin/bash
# Signs minirun's code: minirun.app, or the folder a --no-app install puts minirun in.
#
#   ./scripts/sign-app.sh minirun.app                sign the bundle, frameworks and helper first
#   ./scripts/sign-app.sh --bin ~/.minirun/bin       sign minirun and the frameworks next to it
#   ./scripts/sign-app.sh --local-only minirun.app   only with this Mac's own certificate; without
#                                                    one, change nothing (the app's updater uses this)
#
# macOS grants Screen Recording and Accessibility to a program by its signature. An ad-hoc
# signature names the exact bytes, so every update is a new program and loses the grants. Signed
# with a certificate, the program is its identifier plus that certificate, which every later build
# shares, so the grants carry over. There's no Apple Developer ID behind minirun, so releases are
# ad-hoc signed; a Mac with its own certificate re-signs them with it (README: "Keep permissions
# across updates").
#
# The identity: $MINIRUN_SIGN_IDENTITY, else a "minirun local" code-signing identity in the
# keychain, else ad-hoc ("-"). Self-signed certificates work: macOS doesn't need to trust them.
set -euo pipefail
LOCAL_NAME="minirun local"
HELPER_ID="dev.minirun.helper"
MODE=app LOCAL_ONLY=false TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin) MODE=bin ;;
    --local-only) LOCAL_ONLY=true ;;
    -*) echo "Unknown option: $1 (see the top of $0)"; exit 1 ;;
    *) TARGET="$1" ;;
  esac
  shift
done
[[ -n "$TARGET" && -d "$TARGET" ]] || { echo "usage: $0 [--local-only] minirun.app | --bin DIR"; exit 1; }

identity="${MINIRUN_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]] && /usr/bin/security find-identity -p codesigning 2>/dev/null | grep -qF "\"$LOCAL_NAME\""; then
  identity="$LOCAL_NAME"
fi
if [[ -z "$identity" || "$identity" == "-" ]]; then
  if $LOCAL_ONLY; then echo "No local signing identity; leaving $TARGET as it is."; exit 0; fi
  identity="-"
fi

sign() { /usr/bin/codesign --force --sign "$identity" "$@" >/dev/null; }

if [[ "$MODE" == bin ]]; then
  for fw in "$TARGET"/*.framework; do [[ -d "$fw" ]] && sign "$fw"; done
  sign --identifier "$HELPER_ID" "$TARGET/minirun"
else
  # Inside out: a bundle's signature covers what's in it, so it's signed last.
  for fw in "$TARGET"/Contents/Frameworks/*.framework; do [[ -d "$fw" ]] && sign "$fw"; done
  [[ -f "$TARGET/Contents/Helpers/minirun" ]] && sign --identifier "$HELPER_ID" "$TARGET/Contents/Helpers/minirun"
  sign "$TARGET"
fi

if [[ "$identity" == "-" ]]; then
  echo "Signed $TARGET ad-hoc."
else
  echo "Signed $TARGET with \"$identity\"."
fi
