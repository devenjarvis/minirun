#!/bin/bash
# End-to-end check on a real Mac: boots a simulator, builds the fixture app, launches it, and drives
# it through the same tools Claude uses. Run after `swift build`.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${MINIRUN_BIN:-$ROOT/.build/debug/minirun}"
export MINIRUN_CONFIG="${MINIRUN_CONFIG:-$(mktemp -d)/config.json}"
run() { echo "+ minirun call $*" >&2; "$BIN" call "$@"; }
expect() { grep -q -- "$1" || { echo "FAILED: expected output to contain: $1" >&2; exit 1; }; }

"$BIN" doctor
"$BIN" tools > /dev/null

# A fresh simulator so the test doesn't depend on runner state.
RUNTIME=$(xcrun simctl list runtimes --json | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x["platform"]=="iOS" and x["isAvailable"]]; print(r[-1]["identifier"])')
TYPE=$(xcrun simctl list devicetypes --json | python3 -c 'import json,sys; t=[x["identifier"] for x in json.load(sys.stdin)["devicetypes"] if x["name"].startswith("iPhone") and "Pro" in x["name"] and "Max" not in x["name"]]; print(t[-1])')
UDID=$(xcrun simctl create "minirun-smoke" "$TYPE" "$RUNTIME")
trap 'xcrun simctl delete "$UDID" >/dev/null 2>&1 || true' EXIT
echo "Created $UDID ($TYPE, $RUNTIME)"

run boot_simulator "{\"device\":\"$UDID\"}" | expect "Booted"
run screenshot "{\"device\":\"$UDID\"}" | expect "image saved"

(cd "$ROOT/Tests/Fixtures/HelloApp" && xcodegen generate --quiet)
run build_and_run "{\"device\":\"$UDID\",\"path\":\"$ROOT/Tests/Fixtures/HelloApp\",\"scheme\":\"HelloApp\",\"wait_seconds\":600}" | tee /tmp/minirun-build.txt | expect "Installed and launched"

sleep 2
run describe_ui "{\"device\":\"$UDID\"}" | tee /tmp/minirun-ui.txt | expect "tapButton"
run tap "{\"device\":\"$UDID\",\"id\":\"tapButton\"}" | expect "Tapped"
sleep 1
run describe_ui "{\"device\":\"$UDID\"}" | expect "Taps: 1"

run tap "{\"device\":\"$UDID\",\"id\":\"nameField\"}" > /dev/null
sleep 1
run type_text "{\"device\":\"$UDID\",\"text\":\"Claude\"}" | expect "Typed"
sleep 1
run describe_ui "{\"device\":\"$UDID\"}" | expect "Hello, Claude!"
# Keep a screenshot of the result for the CI logs.
shot=$(run screenshot "{\"device\":\"$UDID\"}" | sed -n 's/.*image saved to \(.*\)]/\1/p')
mkdir -p "$ROOT/ci-logs/screens" && cp "$shot" "$ROOT/ci-logs/screens/hello-app.jpg" || true

run swipe "{\"device\":\"$UDID\",\"direction\":\"up\"}" | expect "Swiped"
run press_button "{\"device\":\"$UDID\",\"button\":\"home\"}" | expect "Pressed"
run app_logs "{\"device\":\"$UDID\",\"bundle_id\":\"dev.minirun.HelloApp\",\"seconds\":120}" > /dev/null
run terminate_app "{\"device\":\"$UDID\",\"bundle_id\":\"dev.minirun.HelloApp\"}" | expect "Terminated"

# A second session on the same Mac: it gets its own simulator, nothing guesses between the two,
# and builds find the simulator reserved for their workspace.
run boot_simulator '{"device":"minirun-smoke","label":"smoke/second"}' | tee /tmp/minirun-boot2.txt | expect "Created minirun-smoke (minirun 2)"
UDID2=$(sed -n 's/^Simulator: .*, UDID \([0-9A-Fa-f-]*\)\..*/\1/p' /tmp/minirun-boot2.txt | head -1)
[[ -n "$UDID2" && "$UDID2" != "$UDID" ]] || { echo "FAILED: no second simulator UDID" >&2; exit 1; }
trap 'xcrun simctl delete "$UDID" "$UDID2" >/dev/null 2>&1 || true' EXIT
run boot_simulator '{"label":"smoke/second"}' | expect "$UDID2"
if out=$("$BIN" call tap '{"x":10,"y":10}'); then echo "FAILED: tap without device should refuse to guess" >&2; exit 1; fi
echo "$out" | expect "simulators are booted"
run list_simulators '{"include_shutdown":false}' | expect "smoke/second"
run build_and_run "{\"path\":\"$ROOT/Tests/Fixtures/HelloApp\",\"scheme\":\"HelloApp\",\"wait_seconds\":600}" | expect "UDID $UDID"
run shutdown_simulator "{\"device\":\"$UDID2\"}" | expect "Shut down"
echo "Smoke test passed."
