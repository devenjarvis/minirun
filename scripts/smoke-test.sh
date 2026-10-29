#!/bin/bash
# End-to-end check on a real Mac: boots a simulator, builds the fixture app, launches it, and drives
# it through the same tools Claude uses. Run after `swift build`.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${MINIRUN_BIN:-$ROOT/.build/debug/minirun}"
export MINIRUN_CONFIG="${MINIRUN_CONFIG:-$(mktemp -d)/config.json}"
run() { echo "+ minirun call $*" >&2; "$BIN" call "$@"; }
expect() {
  local output; output=$(cat)
  grep -q -- "$1" <<< "$output" || { echo "FAILED: expected output to contain: $1" >&2; echo "--- output was:" >&2; echo "$output" >&2; exit 1; }
}

"$BIN" doctor
"$BIN" tools > /dev/null

# A fresh simulator so the test doesn't depend on runner state.
RUNTIME=$(xcrun simctl list runtimes --json | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x["platform"]=="iOS" and x["isAvailable"]]; print(r[-1]["identifier"])')
TYPE=$(xcrun simctl list devicetypes --json | python3 -c 'import json,sys; t=[x["identifier"] for x in json.load(sys.stdin)["devicetypes"] if x["name"].startswith("iPhone") and "Pro" in x["name"] and "Max" not in x["name"]]; print(t[-1])')
UDID=$(xcrun simctl create "minirun-smoke" "$TYPE" "$RUNTIME")
# Deletes the smoke simulators: this one (unless MINIRUN_SMOKE_KEEP is set, so a later CI step can
# reuse it instead of paying for another first boot) and the second session's copy.
cleanup() {
  kill $(jobs -p) 2>/dev/null || true
  local sims; sims=$(xcrun simctl list devices --json | python3 -c 'import json,sys; print(" ".join(d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["name"].startswith("minirun-smoke (minirun ")))')
  [[ -n "${MINIRUN_SMOKE_KEEP:-}" ]] || sims="$UDID $sims"
  for sim in $sims; do xcrun simctl shutdown "$sim" >/dev/null 2>&1 || true; xcrun simctl delete "$sim" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT
echo "Created $UDID ($TYPE, $RUNTIME)"

# A new simulator's first boot takes minutes, so the second session's simulator (below) boots
# alongside the first. It's requested once the first is running, so boot_simulator has to create a copy.
echo "+ minirun call boot_simulator {\"device\":\"$UDID\"} &" >&2
"$BIN" call boot_simulator "{\"device\":\"$UDID\"}" > /tmp/minirun-boot1.txt 2>&1 &
BOOT1=$!
for _ in $(seq 1 120); do
  xcrun simctl list devices | grep -q "$UDID) (Booted)" && break
  kill -0 "$BOOT1" 2>/dev/null || break
  sleep 1
done
echo "+ minirun call boot_simulator {\"device\":\"minirun-smoke\",\"label\":\"smoke/second\"} &" >&2
"$BIN" call boot_simulator '{"device":"minirun-smoke","label":"smoke/second"}' > /tmp/minirun-boot2.txt 2>&1 &
BOOT2=$!
finish() { wait "$1" || { echo "FAILED: $2 exited with an error" >&2; cat "$2" >&2; exit 1; }; }
finish "$BOOT1" /tmp/minirun-boot1.txt
expect "Booted" < /tmp/minirun-boot1.txt
finish "$BOOT2" /tmp/minirun-boot2.txt
expect "Created minirun-smoke (minirun 2)" < /tmp/minirun-boot2.txt
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
# (Its simulator was booted at the start, alongside the first.)
UDID2=$(sed -n 's/^Simulator: .*, UDID \([0-9A-Fa-f-]*\)\..*/\1/p' /tmp/minirun-boot2.txt | head -1)
[[ -n "$UDID2" && "$UDID2" != "$UDID" ]] || { echo "FAILED: no second simulator UDID" >&2; exit 1; }
run boot_simulator '{"label":"smoke/second"}' | expect "$UDID2"
if out=$("$BIN" call tap '{"x":10,"y":10}'); then echo "FAILED: tap without device should refuse to guess" >&2; exit 1; fi
echo "$out" | expect "simulators are booted"
run list_simulators '{"include_shutdown":false}' | expect "smoke/second"
run build_and_run "{\"path\":\"$ROOT/Tests/Fixtures/HelloApp\",\"scheme\":\"HelloApp\",\"wait_seconds\":600}" | expect "UDID $UDID"
run shutdown_simulator "{\"device\":\"$UDID2\"}" | expect "Shut down"
echo "Smoke test passed."
