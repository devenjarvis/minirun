#!/bin/bash
# Runs the Worker locally (wrangler dev), connects a real `minirun serve` to it, and drives it
# through OAuth + MCP + the live viewer with worker/test/e2e-relay.mjs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${MINIRUN_BIN:-$ROOT/.build/debug/minirun}"
PORT=8787
TMP=$(mktemp -d)
cleanup() { kill "${SERVE_PID:-}" "${DEV_PID:-}" 2>/dev/null || true; }
trap cleanup EXIT

cd "$ROOT/worker"
printf 'OWNER_PASSWORD=e2e-password\nAGENT_TOKEN=e2e-agent-token\n' > .dev.vars
WRANGLER_SEND_METRICS=false npx wrangler dev --port $PORT --ip 127.0.0.1 > "$TMP/wrangler.log" 2>&1 &
DEV_PID=$!
for _ in $(seq 1 60); do curl -s -o /dev/null "http://127.0.0.1:$PORT/login" && break; sleep 1; done
curl -s -o /dev/null "http://127.0.0.1:$PORT/login" || { cat "$TMP/wrangler.log"; exit 1; }

export MINIRUN_CONFIG="$TMP/config.json"
"$BIN" setup --relay "ws://127.0.0.1:$PORT" --token e2e-agent-token
"$BIN" serve > "$TMP/serve.log" 2>&1 &
SERVE_PID=$!

status=0
node test/e2e-relay.mjs "http://127.0.0.1:$PORT" e2e-password || status=$?
if [[ $status -eq 0 ]]; then
  # The control socket that `minirun status` and the menu bar app read.
  echo "--- minirun status"
  "$BIN" status || status=$?
  json=$("$BIN" status --json) || status=$?
  [[ "$json" == *'"state":"connected"'* ]] || { echo "minirun status --json doesn't say the relay is connected: $json"; status=1; }
fi
echo "--- minirun serve log"; tail -n 40 "$TMP/serve.log"
if [[ $status -ne 0 ]]; then echo "--- wrangler log"; tail -n 60 "$TMP/wrangler.log"; fi
rm -f .dev.vars
exit $status
