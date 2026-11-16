#!/bin/bash
# Builds FBSimulatorControl and friends (from AXe's pinned fork of Meta's idb) into Vendor/.
# minirun links these to drive simulators in-process: framebuffer, touch/keyboard (HID) and
# accessibility. Needs Xcode and XcodeGen (`brew install xcodegen`). Takes ~5–10 minutes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
WORK="${MINIRUN_FRAMEWORK_WORK:-$ROOT/.build/frameworks}"

# AXe pins an exact idb revision and has a tested build script; we reuse both.
AXE_URL="https://github.com/cameroncooke/AXe.git"
AXE_REF="30f4bfa9bc81817906a60fadedbc913d7314b7e1"
# Bump when the patches below change, so a Vendor/ built without them is rebuilt.
PATCH_LEVEL="1"
VENDOR_REF="$AXE_REF+patches.$PATCH_LEVEL"

if [[ -f "$VENDOR/.axe-ref" && "$(cat "$VENDOR/.axe-ref")" == "$VENDOR_REF" && -d "$VENDOR/XCFrameworks/FBSimulatorControl.xcframework" && "${1:-}" != "--force" ]]; then
  echo "Frameworks already built for AXe $AXE_REF with patch level $PATCH_LEVEL (pass --force to rebuild)."
  exit 0
fi

command -v xcodegen >/dev/null || { echo "XcodeGen is required: brew install xcodegen" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "Xcode is required." >&2; exit 1; }

mkdir -p "$WORK"
if [[ ! -d "$WORK/axe/.git" ]]; then
  git clone --quiet "$AXE_URL" "$WORK/axe"
fi
git -C "$WORK/axe" fetch --quiet origin "$AXE_REF" || true
git -C "$WORK/axe" checkout --quiet --force "$AXE_REF"

cd "$WORK/axe"
echo "==> AXe build.sh setup"
./scripts/build.sh setup

# Patches to the idb checkout. AXe's build refuses a checkout with local changes (and repairs one),
# so each patched file is marked skip-worktree: git status stays clean and the edit stays put.
#
# 1. CoreSimulator calls a display's IOSurface-change callbacks with nil when the simulator shuts
#    down. The private header declares the block's argument as nonnull (it's inside
#    NS_ASSUME_NONNULL), so Swift imports it as `(Any) -> Void`, and FBFramebuffer's callback
#    crashed in the bridging thunk (swift_getObjectType on nil) whenever a simulator with a live
#    view, recording or screen capture attached was shut down, taking `minirun serve` with it.
IDB="$WORK/axe/idb_checkout"
HEADER="PrivateHeaders/CoreSimDeviceIO/SimDisplayIOSurfaceRenderable-Protocol.h"
git -C "$IDB" update-index --no-skip-worktree "$HEADER"
git -C "$IDB" checkout -- "$HEADER"
sed -i '' -e 's/ChangeCallback:(void (^)(id))arg2/ChangeCallback:(void (^)(id _Nullable))arg2/' "$IDB/$HEADER"
[[ "$(grep -c 'ChangeCallback:(void (^)(id _Nullable))' "$IDB/$HEADER")" == "2" ]] || { echo "Patching $HEADER failed" >&2; exit 1; }
git -C "$IDB" update-index --skip-worktree "$HEADER"

# Build without Developer ID signing: frameworks → install → strip → xcframeworks.
for step in clean frameworks install strip xcframeworks; do
  echo "==> AXe build.sh $step"
  ./scripts/build.sh "$step"
done

rm -rf "$VENDOR/XCFrameworks" "$VENDOR/PrivateHeaders"
mkdir -p "$VENDOR"
cp -R build_products/XCFrameworks "$VENDOR/XCFrameworks"
cp -R idb_checkout/PrivateHeaders "$VENDOR/PrivateHeaders"
cp idb_checkout/LICENSE "$VENDOR/LICENSE-idb"
echo "$VENDOR_REF" > "$VENDOR/.axe-ref"
echo "Frameworks ready in $VENDOR"
