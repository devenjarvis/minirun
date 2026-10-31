#!/bin/bash
# CI only: grants Screen Recording and Accessibility to the minirun binary the smoke test runs, so
# its macOS app steps (describe_ui, taps, typing, menus, screenshots) can run. GitHub's macOS
# images have SIP turned off and their own setup writes TCC.db the same way (actions/runner-images,
# configure-tccdb-macos.sh). Never run this on your own Mac: use System Settings instead.
#
# macOS checks the "responsible" process, which for a command started by the runner can be an
# ancestor rather than minirun itself, so every executable from this shell up to launchd is
# granted too.
#
# Usage: scripts/ci-grant-tcc.sh /path/to/minirun
set -uo pipefail
BIN="${1:?usage: ci-grant-tcc.sh /path/to/minirun}"
csrutil status || true

clients=("$BIN" "$(cd "$(dirname "$BIN")" && pwd -P)/$(basename "$BIN")")
pid=$$
while [[ "$pid" -gt 1 ]]; do
  exe=$(ps -o comm= -p "$pid" 2>/dev/null | sed 's/^ *//')
  [[ "$exe" == /* ]] && clients+=("$exe")
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  [[ -n "$pid" ]] || break
done

now=$(date +%s)
grant() {
  local db=$1 service=$2 client=$3
  # Named columns, so it works whatever columns newer macOS versions add (they have defaults).
  sudo sqlite3 "$db" "INSERT OR REPLACE INTO access
    (service, client, client_type, auth_value, auth_reason, auth_version, csreq, policy_id,
     indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags, last_modified)
    VALUES ('$service', '$client', 1, 2, 4, 1, NULL, NULL, 0, 'UNUSED', NULL, 0, $now);"
}

for db in "/Library/Application Support/com.apple.TCC/TCC.db" "$HOME/Library/Application Support/com.apple.TCC/TCC.db"; do
  [[ -f "$db" ]] || { echo "No $db"; continue; }
  echo "== $db"
  sudo sqlite3 "$db" "PRAGMA table_info(access);" | cut -d'|' -f2 | tr '\n' ' '; echo
  while IFS= read -r client; do
    for service in kTCCServiceScreenCapture kTCCServiceAccessibility; do
      grant "$db" "$service" "$client" && echo "granted $service to $client" || echo "couldn't grant $service to $client in $db"
    done
  done < <(printf '%s\n' "${clients[@]}" | sort -u)
done
# tccd caches decisions; it's relaunched on demand.
sudo killall tccd 2>/dev/null || true
sleep 2

# Check from minirun itself.
"$BIN" call host_info | grep -E "\((for macOS apps)\)" || true
