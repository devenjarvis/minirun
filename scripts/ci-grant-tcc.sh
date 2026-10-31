#!/bin/bash
# CI only: grants Screen Recording and Accessibility to the minirun binary the smoke test runs, so
# its macOS app steps (describe_ui, taps, typing, menus, screenshots) can run. GitHub's macOS
# images have SIP turned off and their own setup writes TCC.db the same way (actions/runner-images,
# configure-tccdb-macos.sh). Never run this on your own Mac: use System Settings instead.
#
# It grants as little as works: first the minirun binary alone, and only if minirun still lacks
# the permissions, the processes it runs under (macOS may check the "responsible" process, an
# ancestor, instead). The log says which was needed.
#
# Usage: scripts/ci-grant-tcc.sh /path/to/minirun
set -uo pipefail
if [[ "${GITHUB_ACTIONS:-}" != "true" || "${RUNNER_ENVIRONMENT:-}" != "github-hosted" ]]; then
  echo "ci-grant-tcc.sh only runs on GitHub-hosted CI runners. It edits TCC.db directly; on your own Mac, grant the permissions in System Settings." >&2
  exit 1
fi
BIN="${1:?usage: ci-grant-tcc.sh /path/to/minirun}"
csrutil status || true

DBS=("/Library/Application Support/com.apple.TCC/TCC.db" "$HOME/Library/Application Support/com.apple.TCC/TCC.db")
now=$(date +%s)

grant() {
  local client=$1 db service
  for db in "${DBS[@]}"; do
    [[ -f "$db" ]] || continue
    for service in kTCCServiceScreenCapture kTCCServiceAccessibility; do
      # Named columns, so it works whatever columns newer macOS versions add (they have defaults).
      if sudo sqlite3 "$db" "INSERT OR REPLACE INTO access
        (service, client, client_type, auth_value, auth_reason, auth_version, csreq, policy_id,
         indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags, last_modified)
        VALUES ('$service', '$client', 1, 2, 4, 1, NULL, NULL, 0, 'UNUSED', NULL, 0, $now);"; then
        echo "granted $service to $client in $db"
      else
        echo "couldn't grant $service to $client in $db"
      fi
    done
  done
}

# True when minirun itself reports both permissions.
granted() {
  # tccd caches decisions; it's relaunched on demand.
  sudo killall tccd 2>/dev/null || true
  sleep 2
  local checks; checks=$("$BIN" call host_info | grep -E "\(for macOS apps\)")
  echo "$checks"
  grep -q "✓ Screen Recording" <<< "$checks" && grep -q "✓ Accessibility" <<< "$checks"
}

for db in "${DBS[@]}"; do
  [[ -f "$db" ]] && { echo "$db columns:"; sudo sqlite3 "$db" "PRAGMA table_info(access);" | cut -d'|' -f2 | tr '\n' ' '; echo; }
done

echo "== Before granting anything"
granted && { echo "minirun already has both permissions."; exit 0; }

echo "== Granting the minirun binary"
grant "$BIN"
real="$(cd "$(dirname "$BIN")" && pwd -P)/$(basename "$BIN")"
[[ "$real" != "$BIN" ]] && grant "$real"
granted && { echo "Granting the minirun binary was enough."; exit 0; }

echo "== Granting the processes minirun runs under"
pid=$$
while [[ "$pid" -gt 1 ]]; do
  exe=$(ps -o comm= -p "$pid" 2>/dev/null | sed 's/^ *//')
  [[ "$exe" == /* ]] && grant "$exe"
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  [[ -n "$pid" ]] || break
done
granted && { echo "minirun needed its parent processes granted too."; exit 0; }
echo "::warning::minirun still lacks Screen Recording or Accessibility after editing TCC.db."
