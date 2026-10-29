#!/bin/bash
# Pushes ci-logs/ to the `ci-logs` branch under <name>/ so failures can be read with plain git.
set -euo pipefail
name="$1"
[[ -d ci-logs ]] || exit 0
tmp=$(mktemp -d)
git config --global user.name "minirun-ci"
git config --global user.email "ci@users.noreply.github.com"
if git fetch --depth 1 origin ci-logs 2>/dev/null; then
  git worktree add "$tmp/wt" FETCH_HEAD --detach
else
  git worktree add --detach "$tmp/wt"
  (cd "$tmp/wt" && git checkout --orphan ci-logs-new && git rm -rfq . )
fi
mkdir -p "$tmp/wt/$name"
cp -R ci-logs/. "$tmp/wt/$name/"
cd "$tmp/wt"
git add -A
git commit -qm "CI logs for $name" || exit 0
git push -q origin HEAD:refs/heads/ci-logs
