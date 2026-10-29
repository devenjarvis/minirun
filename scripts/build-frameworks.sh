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

if [[ -f "$VENDOR/.axe-ref" && "$(cat "$VENDOR/.axe-ref")" == "$AXE_REF" && -d "$VENDOR/XCFrameworks/FBSimulatorControl.xcframework" && "${1:-}" != "--force" ]]; then
  echo "Frameworks already built for AXe $AXE_REF (pass --force to rebuild)."
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
# Build without Developer ID signing: setup → frameworks → install → strip → xcframeworks.
for step in setup clean frameworks install strip xcframeworks; do
  echo "==> AXe build.sh $step"
  ./scripts/build.sh "$step"
done

rm -rf "$VENDOR/XCFrameworks" "$VENDOR/PrivateHeaders"
mkdir -p "$VENDOR"
cp -R build_products/XCFrameworks "$VENDOR/XCFrameworks"
cp -R idb_checkout/PrivateHeaders "$VENDOR/PrivateHeaders"
cp idb_checkout/LICENSE "$VENDOR/LICENSE-idb"
echo "$AXE_REF" > "$VENDOR/.axe-ref"
echo "Frameworks ready in $VENDOR"
