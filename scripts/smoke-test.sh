#!/bin/bash
# End-to-end check on a real Mac: boots a simulator, builds the fixture app, launches it, and drives
# it through the same tools Claude uses. Run after `swift build`.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${MINIRUN_BIN:-$ROOT/.build/debug/minirun}"
export MINIRUN_CONFIG="${MINIRUN_CONFIG:-$(mktemp -d)/config.json}"
# Each call is logged with the Mac's load average and free memory, to show what slow steps wait on.
run() { echo "+ minirun call $* [load $(sysctl -n vm.loadavg | tr -d '{}'), $(memory_pressure 2>/dev/null | sed -n 's/.*free percentage: //p') free]" >&2; "$BIN" call "$@"; }
expect() {
  local output; output=$(cat)
  grep -q -- "$1" <<< "$output" || { echo "FAILED: expected output to contain: $1" >&2; echo "--- output was:" >&2; echo "$output" >&2; exit 1; }
}

"$BIN" doctor
"$BIN" tools > /dev/null

# A fresh simulator so the test doesn't depend on runner state. It's cloned from a template that has
# already booted once (made here the first time; CI caches it), which skips the slow first boot.
TEMPLATE=$("$ROOT/scripts/sim-template.sh" ensure)
UDID=$(xcrun simctl clone "$TEMPLATE" "minirun-smoke")
# Deletes the smoke simulators: this one (unless MINIRUN_SMOKE_KEEP is set, so a later CI step can
# reuse it instead of paying for another boot) and the second session's copy. Keeps the template.
cleanup() {
  local sims; sims=$(xcrun simctl list devices --json | python3 -c 'import json,sys; print(" ".join(d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["name"].startswith("minirun-smoke (minirun ") and not d["name"].endswith(" template)")))')
  [[ -n "${MINIRUN_SMOKE_KEEP:-}" ]] || sims="$UDID $sims"
  for sim in $sims; do xcrun simctl shutdown "$sim" >/dev/null 2>&1 || true; xcrun simctl delete "$sim" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT
echo "Cloned $UDID from the template $TEMPLATE"

run boot_simulator "{\"device\":\"$UDID\"}" | expect "Booted"
run screenshot "{\"device\":\"$UDID\"}" | expect "image saved"

# No `xcodegen generate` here: build_and_run generates HelloApp.xcodeproj from project.yml itself.
rm -rf "$ROOT/Tests/Fixtures/HelloApp/HelloApp.xcodeproj"
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
run boot_simulator '{"device":"minirun-smoke","label":"smoke/second"}' | tee /tmp/minirun-boot2.txt | expect "Created minirun-smoke (minirun 2) from the template"
UDID2=$(sed -n 's/^Simulator: .*, UDID \([0-9A-Fa-f-]*\)\..*/\1/p' /tmp/minirun-boot2.txt | head -1)
[[ -n "$UDID2" && "$UDID2" != "$UDID" ]] || { echo "FAILED: no second simulator UDID" >&2; exit 1; }
run boot_simulator '{"label":"smoke/second"}' | expect "$UDID2"
if out=$("$BIN" call tap '{"x":10,"y":10}'); then echo "FAILED: tap without device should refuse to guess" >&2; exit 1; fi
echo "$out" | expect "simulators are booted"
run list_simulators '{"include_shutdown":false}' | expect "smoke/second"
run build_and_run "{\"path\":\"$ROOT/Tests/Fixtures/HelloApp\",\"scheme\":\"HelloApp\",\"wait_seconds\":600}" | expect "UDID $UDID"
run shutdown_simulator "{\"device\":\"$UDID2\"}" | expect "Shut down"
echo "Smoke test passed."
