#!/bin/bash
# The smoke test's simulator template: a shut-down simulator that has booted once. Simulators cloned
# from it (by the smoke test, and by minirun when it makes a copy) skip the data migration of a first
# boot, which takes 6-7 minutes on GitHub's runners. CI caches it between runs.
#   scripts/sim-template.sh ensure       Prints the template's UDID, creating and booting it once if needed.
#   scripts/sim-template.sh key          Prints what the template depends on, for a cache key.
#   scripts/sim-template.sh save DIR     Copies the template's device folder into DIR.
#   scripts/sim-template.sh restore DIR  Puts a template saved by `save` back into CoreSimulator.
set -euo pipefail
NAME="minirun-smoke (minirun template)"
DEVICES="$HOME/Library/Developer/CoreSimulator/Devices"

# The newest iOS runtime and the newest iPhone Pro (not Max).
RUNTIME_JSON=$(xcrun simctl list runtimes --json | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x["platform"]=="iOS" and x["isAvailable"]][-1]; print(r["identifier"], r["buildversion"])')
RUNTIME=${RUNTIME_JSON% *}
RUNTIME_BUILD=${RUNTIME_JSON#* }
TYPE=$(xcrun simctl list devicetypes --json | python3 -c 'import json,sys; t=[x["identifier"] for x in json.load(sys.stdin)["devicetypes"] if x["name"].startswith("iPhone") and "Pro" in x["name"] and "Max" not in x["name"]]; print(t[-1])')

find_template() {
  xcrun simctl list devices --json | NAME="$NAME" RUNTIME="$RUNTIME" TYPE="$TYPE" python3 -c '
import json, os, sys
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if runtime == os.environ["RUNTIME"] and d["name"] == os.environ["NAME"] and d.get("deviceTypeIdentifier") == os.environ["TYPE"] and d["state"] == "Shutdown":
            print(d["udid"]); sys.exit()'
}

case "${1:-}" in
  key)
    echo "$TYPE-$RUNTIME-$RUNTIME_BUILD"
    ;;
  ensure)
    udid=$(find_template)
    if [[ -z "$udid" ]]; then
      udid=$(xcrun simctl create "$NAME" "$TYPE" "$RUNTIME")
      # A template that never finished its first boot would be cloned (and cached) half set up.
      trap 'xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true; xcrun simctl delete "$udid" >/dev/null 2>&1 || true' ERR
      echo "Booting the new template $udid once ($TYPE, $RUNTIME); a first boot takes several minutes" >&2
      start=$SECONDS
      xcrun simctl boot "$udid"
      xcrun simctl bootstatus "$udid" >&2
      # After the boot, the simulator spends a few minutes on first-run work (icon caches, first
      # launches of system apps). Doing it here keeps it in the template, so clones don't redo it.
      sleep "${MINIRUN_TEMPLATE_SETTLE:-120}"
      xcrun simctl shutdown "$udid"
      trap - ERR
      echo "Template ready after $((SECONDS - start))s" >&2
    fi
    echo "$udid"
    ;;
  save)
    udid=$(find_template)
    [[ -n "$udid" ]] || { echo "No template to save." >&2; exit 0; }
    rm -rf "$2" && mkdir -p "$2"
    # -c clones the files (APFS copy-on-write), so this is instant.
    cp -cR "$DEVICES/$udid" "$2/"
    rm -rf "$2/$udid/data/Library/Logs"
    du -sh "$2/$udid"
    ;;
  restore)
    for dir in "$2"/*/; do
      [[ -f "$dir/device.plist" ]] || continue
      udid=$(basename "$dir")
      [[ -e "$DEVICES/$udid" ]] || cp -cR "$dir" "$DEVICES/$udid"
    done
    # CoreSimulator reads the device folders when it starts; restart it so it sees the template.
    killall -9 com.apple.CoreSimulator.CoreSimulatorService 2>/dev/null || true
    if udid=$(find_template) && [[ -n "$udid" ]]; then
      echo "Restored the template $udid"
    else
      echo "::warning title=Simulator template::The cached template didn't load; the smoke test will make a new one."
    fi
    ;;
  *)
    echo "usage: $0 key | ensure | save DIR | restore DIR" >&2
    exit 2
    ;;
esac
