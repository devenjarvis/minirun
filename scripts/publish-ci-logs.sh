#!/bin/bash
# Pushes ci-logs/ to the `ci-logs` branch under <name>/ so failures can be read with plain git.
set -euo pipefail
name="$1"
[[ -d ci-logs ]] || exit 0
git config --global user.name "minirun-ci"
git config --global user.email "ci@users.noreply.github.com"
src="$PWD/ci-logs"

# Commits ci-logs/ onto the current tip of the branch and pushes it.
publish() {
  local tmp; tmp=$(mktemp -d)
  if git fetch --depth 1 origin ci-logs 2>/dev/null; then
    git worktree add "$tmp/wt" FETCH_HEAD --detach
  else
    git worktree add --detach "$tmp/wt"
    (cd "$tmp/wt" && git checkout --orphan ci-logs-new && git rm -rfq . )
  fi
  mkdir -p "$tmp/wt/$name"
  cp -R "$src/." "$tmp/wt/$name/"
  (
    cd "$tmp/wt"
    git add -A
    git commit -qm "CI logs for $name" || exit 0
    git push -q origin HEAD:refs/heads/ci-logs
  )
}

# Parallel jobs can push at the same moment. Each writes its own folder, so a rejected push just
# starts again from the new tip.
for attempt in 1 2 3 4; do
  publish && exit 0
  echo "Pushing CI logs failed (attempt $attempt); retrying" >&2
  sleep $((attempt * 3))
done
exit 1
