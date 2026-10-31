#!/bin/bash
# Deploys the minirun Worker with wrangler, for working on the Worker itself. Everyone else
# should use `minirun worker deploy` on the Mac, which needs no node (scripts/install.sh runs it).
#
# Prints the settings for the Mac. Safe to re-run: it reuses the KV namespaces and keeps existing
# secrets unless you pass --new-password or --new-token.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

NEW_PASSWORD=0; NEW_TOKEN=0
for arg in "$@"; do
  case "$arg" in
    --new-password) NEW_PASSWORD=1 ;;
    --new-token) NEW_TOKEN=1 ;;
  esac
done

STATE_FILE="${MINIRUN_WORKER_STATE:-$HOME/.config/minirun/worker.env}"
mkdir -p "$(dirname "$STATE_FILE")"
[[ -f "$STATE_FILE" ]] && source "$STATE_FILE"

[[ -d node_modules ]] || npm ci --silent

if ! npx wrangler whoami 2>/dev/null | grep -q "You are logged in"; then
  echo "==> Logging in to Cloudflare (a browser window will open)"
  npx wrangler login
fi

# OAuth tokens, and shared screenshots and recordings.
for pair in OAUTH_KV:REPLACE_WITH_KV_ID MEDIA_KV:REPLACE_WITH_MEDIA_KV_ID; do
  binding=${pair%%:*}; placeholder=${pair#*:}
  grep -q "\"$placeholder\"" wrangler.jsonc || continue
  echo "==> Creating the $binding KV namespace"
  output=$(npx wrangler kv namespace create "$binding" 2>&1 || true)
  id=$(echo "$output" | grep -oE '"id": ?"[0-9a-f]{32}"' | grep -oE '[0-9a-f]{32}' | head -1)
  if [[ -z "$id" ]]; then
    # Already exists from an earlier run: look it up.
    id=$(npx wrangler kv namespace list 2>/dev/null | BINDING="$binding" python3 -c 'import json,os,sys; print(next((n["id"] for n in json.load(sys.stdin) if n["title"].endswith(os.environ["BINDING"])), ""))')
  fi
  [[ -n "$id" ]] || { echo "Could not create or find the $binding KV namespace:"; echo "$output"; exit 1; }
  sed -i.bak "s/\"$placeholder\"/\"$id\"/" wrangler.jsonc && rm -f wrangler.jsonc.bak
done

echo "==> Deploying the Worker"
deploy=$(npx wrangler deploy 2>&1 | tee /dev/stderr)
URL=$(echo "$deploy" | grep -oE 'https://[a-zA-Z0-9.-]+\.workers\.dev' | head -1)
[[ -n "$URL" ]] || { echo "Deployed, but couldn't find the workers.dev URL in the output above."; exit 1; }

if [[ -z "${OWNER_PASSWORD:-}" || $NEW_PASSWORD -eq 1 ]]; then
  OWNER_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)
  printf '%s' "$OWNER_PASSWORD" | npx wrangler secret put OWNER_PASSWORD >/dev/null
fi
if [[ -z "${AGENT_TOKEN:-}" || $NEW_TOKEN -eq 1 ]]; then
  AGENT_TOKEN=$(openssl rand -hex 32)
  printf '%s' "$AGENT_TOKEN" | npx wrangler secret put AGENT_TOKEN >/dev/null
fi

umask 077
cat > "$STATE_FILE" <<STATE
WORKER_URL='$URL'
OWNER_PASSWORD='$OWNER_PASSWORD'
AGENT_TOKEN='$AGENT_TOKEN'
STATE

cat <<DONE

minirun Worker is live at $URL

  Live viewer:        $URL/
  Claude connector:   $URL/mcp
  Password:           $OWNER_PASSWORD

(Saved to $STATE_FILE.)
Mac settings: minirun setup --relay ${URL/https:/wss:}/agent --token <AGENT_TOKEN from that file>
DONE
