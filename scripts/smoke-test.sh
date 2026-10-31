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
  # The macOS fixture app, wherever the Mac section stopped.
  if [[ -n "${MAC_ID:-}" ]]; then "$BIN" call terminate_app "{\"device\":\"$MAC_ID\"}" >/dev/null 2>&1 || true; fi
  pkill -x HelloMacApp 2>/dev/null || true
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

# macOS apps: build HelloMacApp, run it on this Mac, read its output, drive it and quit it. Reading
# its UI and sending input need Accessibility, and screenshots need Screen Recording, granted to
# the process running minirun; host_info says whether they are, and steps without them are skipped.
echo "--- macOS app"
MAC_FIXTURE="$ROOT/Tests/Fixtures/HelloMacApp"
rm -rf "$MAC_FIXTURE/HelloMacApp.xcodeproj"
run build_and_run "{\"path\":\"$MAC_FIXTURE\",\"scheme\":\"HelloMacApp\",\"platform\":\"macos\",\"isolated_home\":true,\"wait_seconds\":600}" | tee /tmp/minirun-mac-build.txt | expect "Launched HelloMacApp"
MAC_ID=$(sed -n 's/^Mac app: .*, id \(mac-[0-9a-f]*\)\..*/\1/p' /tmp/minirun-mac-build.txt | head -1)
[[ -n "$MAC_ID" ]] || { echo "FAILED: no Mac app id in the build_and_run result" >&2; exit 1; }
[[ -d "$MAC_FIXTURE/.minirun/home" ]] || { echo "FAILED: isolated_home didn't make $MAC_FIXTURE/.minirun/home" >&2; exit 1; }
run list_mac_apps | expect "$MAC_ID"
run list_windows "{\"device\":\"$MAC_ID\"}" || true
mac_logs() { run app_logs "{\"device\":\"$MAC_ID\",\"seconds\":60,\"contains\":\"HelloMacApp:\"}"; }
mac_logs | expect "HelloMacApp: launched"
if out=$("$BIN" call press_button "{\"device\":\"$MAC_ID\",\"button\":\"home\"}"); then echo "FAILED: press_button should refuse a Mac app" >&2; exit 1; fi
echo "$out" | expect "press_key"

HOST=$(run host_info)
grep -E "(Screen Recording|Accessibility|Display) \(for macOS apps\)" <<< "$HOST" || true
# CI grants them first (scripts/ci-grant-tcc.sh) and sets this, so a lost grant fails rather than skips.
if [[ -n "${MINIRUN_SMOKE_REQUIRE_MAC_GRANTS:-}" ]]; then
  for check in "Accessibility" "Screen Recording" "Display"; do
    grep -q "✓ $check (for macOS apps)" <<< "$HOST" || { echo "FAILED: $check isn't available to minirun, but MINIRUN_SMOKE_REQUIRE_MAC_GRANTS is set" >&2; exit 1; }
  done
fi
if grep -q "✓ Accessibility (for macOS apps)" <<< "$HOST"; then
  run describe_ui "{\"device\":\"$MAC_ID\"}" | tee /tmp/minirun-mac-ui.txt | expect "incrementButton"
  run tap "{\"device\":\"$MAC_ID\",\"id\":\"incrementButton\"}" | expect "Pressed"
  sleep 1
  mac_logs | expect "HelloMacApp: count=1"
  run press_menu_item "{\"device\":\"$MAC_ID\",\"path\":[\"Counter\",\"Reset Counter\"]}" | expect "Picked Counter > Reset Counter"
  sleep 1
  mac_logs | expect "HelloMacApp: reset count=0"
  run tap "{\"device\":\"$MAC_ID\",\"id\":\"nameField\"}" > /dev/null
  sleep 1
  run type_text "{\"device\":\"$MAC_ID\",\"text\":\"Claude\"}" | expect "Typed"
  sleep 1
  if ! mac_logs | grep -q "HelloMacApp: name=Claude"; then
    # Some setups drop keyboard events posted to a process; the HID path is the fallback.
    echo "NOTE: typing posted to the app's pid didn't reach the field; trying input: hid" >&2
    run tap "{\"device\":\"$MAC_ID\",\"id\":\"nameField\"}" > /dev/null
    run type_text "{\"device\":\"$MAC_ID\",\"text\":\"Claude\",\"input\":\"hid\"}" | expect "moved the real cursor"
    sleep 1
    mac_logs | expect "HelloMacApp: name=Claude"
  fi
  run describe_ui "{\"device\":\"$MAC_ID\"}" | expect "Hello, Claude"
  run press_key "{\"device\":\"$MAC_ID\",\"key\":\"r\",\"modifiers\":[\"command\"]}" | expect "Pressed command+r"
else
  echo "Skipping describe_ui, tap, menus and typing on HelloMacApp: no Accessibility grant on this runner."
fi
if grep -q "✓ Screen Recording (for macOS apps)" <<< "$HOST" && grep -q "✓ Display (for macOS apps)" <<< "$HOST"; then
  run screenshot "{\"device\":\"$MAC_ID\"}" | tee /tmp/minirun-mac-shot.txt | expect "title bar included"
  shot=$(sed -n 's/.*image saved to \(.*\)]/\1/p' /tmp/minirun-mac-shot.txt)
  mkdir -p "$ROOT/ci-logs/screens" && cp "$shot" "$ROOT/ci-logs/screens/hello-mac-app.jpg" || true
else
  echo "Skipping the HelloMacApp screenshot: no Screen Recording grant (or no display) on this runner."
fi

run terminate_app "{\"device\":\"$MAC_ID\"}" | expect "Quit HelloMacApp"
if out=$("$BIN" call tap "{\"device\":\"$MAC_ID\",\"x\":10,\"y\":10}"); then echo "FAILED: tap on a quit Mac app should fail" >&2; exit 1; fi
echo "$out" | expect "isn't running"
run run_tests "{\"path\":\"$MAC_FIXTURE\",\"scheme\":\"HelloMacApp\",\"platform\":\"macos\",\"wait_seconds\":600}" | expect "passed on this Mac"
echo "Smoke test passed."
