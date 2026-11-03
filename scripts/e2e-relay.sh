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
"$BIN" setup --relay "ws://127.0.0.1:$PORT" --token e2e-agent-token --workspaces "$TMP/workspaces"
# `minirun ci` below clones from a local repository.
python3 - "$MINIRUN_CONFIG" "file://$TMP/origin/{repo}" <<'PY'
import json, sys
path, template = sys.argv[1], sys.argv[2]
config = json.load(open(path))
config["gitURLTemplate"] = template
json.dump(config, open(path, "w"))
PY
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
if [[ $status -eq 0 ]]; then
  # `minirun ci` runs jobs in this minirun serve over its control socket: a Swift package with a
  # passing and a failing test, at its first commit (the second breaks the build).
  echo "--- minirun ci"
  PKG="$TMP/origin/you/pkg"
  mkdir -p "$PKG/Sources/Pkg" "$PKG/Tests/PkgTests"
  cat > "$PKG/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Pkg", targets: [.target(name: "Pkg"), .testTarget(name: "PkgTests", dependencies: ["Pkg"])])
SWIFT
  echo 'public func two() -> Int { 2 }' > "$PKG/Sources/Pkg/Pkg.swift"
  printf 'import XCTest\nimport Pkg\nfinal class PkgTests: XCTestCase {\n  func testPasses() { XCTAssertEqual(two(), 2) }\n  func testFails() { XCTAssertEqual(two(), 3, "on purpose") }\n}\n' > "$PKG/Tests/PkgTests/PkgTests.swift"
  git -C "$PKG" init -q -b main && git -C "$PKG" add . && git -C "$PKG" -c user.name=t -c user.email=t@t commit -qm "first"
  first=$(git -C "$PKG" rev-parse HEAD)
  echo 'public func two() -> Int { "two" }' > "$PKG/Sources/Pkg/Pkg.swift"
  git -C "$PKG" -c user.name=t -c user.email=t@t commit -qam "second"

  ci_status=0
  out=$("$BIN" ci swift-test --repo you/pkg --ref ci/main --commit "$first" --only-testing PkgTests 2>&1) || ci_status=$?
  echo "$out"
  [[ $ci_status -eq 1 ]] || { echo "FAILED: minirun ci should exit 1 for a failing test, not $ci_status"; status=1; }
  [[ "$out" == *"minirun: swift test you/pkg@ci/main"* ]] || { echo "FAILED: minirun ci didn't name the job"; status=1; }
  [[ "$out" == *"testFails"* && "$out" == *"::error"* ]] || { echo "FAILED: minirun ci didn't annotate the failing test"; status=1; }
  [[ "$out" != *"cannot convert"* ]] || { echo "FAILED: minirun ci built the second commit, not --commit"; status=1; }
  "$BIN" status | grep -q "swift test you/pkg@ci/main" || { echo "FAILED: the job isn't in minirun serve's job list"; status=1; }

  out=$("$BIN" ci sync --repo you/pkg --ref main 2>&1) || { echo "$out"; echo "FAILED: minirun ci sync"; status=1; }
  [[ "$out" == *"“second”"* ]] || { echo "$out"; echo "FAILED: minirun ci sync should check out main's latest"; status=1; }
fi
echo "--- minirun serve log"; tail -n 40 "$TMP/serve.log"
if [[ $status -ne 0 ]]; then echo "--- wrangler log"; tail -n 60 "$TMP/wrangler.log"; fi
rm -f .dev.vars
exit $status
