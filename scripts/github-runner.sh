#!/bin/bash
# Registers this Mac as a self-hosted GitHub Actions runner for a repository, using GitHub's own
# runner (github.com/actions/runner). minirun doesn't run jobs itself; this only installs and
# manages the official runner next to it, as a LaunchAgent so it starts at login like minirun.
#
#   ./scripts/github-runner.sh install owner/repo [--allow-public]
#   ./scripts/github-runner.sh uninstall owner/repo
#   ./scripts/github-runner.sh start|stop owner/repo
#   ./scripts/github-runner.sh status
#
# Needs `gh` logged in as someone with admin access to the repository. Registration tokens are
# fetched with gh, live about an hour, and are never written to disk or printed.
# The menu bar app carries this script (Settings → GitHub Runners) and runs the same commands.
# Exit codes: 1 for errors, 3 when install refuses a public repository without --allow-public.
set -euo pipefail
RUNNERS="$HOME/.minirun/github-runner"
LABEL_EXTRA="minirun"   # the runner adds self-hosted, macOS and ARM64 itself
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

step() {
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then printf '\n\033[1m==> %s\033[0m\n' "$*"; else printf '\n==> %s\n' "$*"; fi
}
die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '6,9s/^#   //p' "${BASH_SOURCE[0]}"; exit "${1:-1}"; }

check_repo_arg() {
  [[ "${1:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "expected owner/repo, got '${1:-}'"
}

check_mac() {
  [[ "$(uname -s)" == Darwin ]] || die "the GitHub runner setup only works on macOS."
  [[ "$(uname -m)" == arm64 ]] || die "this installs the Apple silicon (arm64) runner; this Mac is $(uname -m)."
}

check_gh() {
  command -v gh >/dev/null || die "gh isn't installed. Run: brew install gh && gh auth login"
  local status
  status="$(gh auth status --hostname github.com 2>&1)" || die "gh isn't logged in to github.com.
Run: gh auth login --scopes repo
$status"
  # Classic OAuth tokens list their scopes; registering a repository runner needs 'repo'.
  # Fine-grained tokens and GH_TOKEN don't, and are checked by the admin test in repo_info.
  if grep -q "Token scopes:" <<<"$status" && ! grep -q "'repo'" <<<"$status"; then
    die "gh is logged in without the 'repo' scope, which runner registration needs.
Run: gh auth refresh --hostname github.com --scopes repo"
  fi
}

runner_dir() { echo "$RUNNERS/${1%%/*}-${1#*/}"; }
runner_name() { echo "$(scutil --get LocalHostName 2>/dev/null || hostname -s)-minirun"; }

# The LaunchAgent label svc.sh created, read from the plist path it saves in .service.
service_label() {
  [[ -f "$1/.service" ]] || return 1
  basename "$(cat "$1/.service")" .plist
}

service_state() {
  local label
  label="$(service_label "$1")" || { echo "no service"; return; }
  launchctl print "gui/$(id -u)/$label" 2>/dev/null | awk '/^\tstate = / { print $3; found=1; exit } END { if (!found) print "not loaded" }'
}

warn_public() {
  cat <<WARN

  $1 is PUBLIC. A self-hosted runner runs workflow code from pull requests on this Mac, as your
  user, with access to your files, your gh login and minirun's secrets in ~/.config/minirun.
  On a public repository anyone can open a pull request from a fork. Before relying on this, set
  Settings → Actions → General → "Fork pull request workflows from outside collaborators" to
  "Require approval for all outside collaborators" (or stricter), and review fork PRs before
  approving their workflow runs.
WARN
}

cmd_install() {
  local repo="" allow_public=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --allow-public) allow_public=true ;;
      -*) die "unknown option $1" ;;
      *) [[ -z "$repo" ]] || die "one repository at a time"; repo="$1" ;;
    esac
    shift
  done
  check_repo_arg "$repo"
  check_mac
  check_gh

  local dir name
  dir="$(runner_dir "$repo")"
  name="$(runner_name)"

  step "Checking $repo"
  local info visibility admin
  info="$(gh api "repos/$repo" --jq '.visibility, (.permissions.admin // false)' 2>/dev/null)" ||
    die "can't read $repo with gh. Check the name and that $(gh api user --jq .login 2>/dev/null || echo 'your gh account') can see it."
  { read -r visibility; read -r admin; } <<<"$info"
  [[ "$admin" == true ]] || die "your gh account needs admin access to $repo to register a runner."
  echo "Visibility: $visibility"
  if [[ "$visibility" == public ]]; then
    warn_public "$repo"
    $allow_public || { echo "error: refusing to register a runner for a public repository. Re-run with --allow-public once fork PR approval is set." >&2; exit 3; }
    local policy
    policy="$(gh api "repos/$repo/actions/permissions/fork-pr-contributor-approval" --jq .approval_policy 2>/dev/null || true)"
    if [[ -n "$policy" && "$policy" != all_external_contributors ]]; then
      echo "warning: fork PR approval is currently '$policy', not 'all_external_contributors'."
    fi
  fi

  if [[ -f "$dir/.minirun-repo" && "$(cat "$dir/.minirun-repo")" != "$repo" ]]; then
    die "$dir already holds the runner for $(cat "$dir/.minirun-repo"). Uninstall that one first."
  fi
  if [[ -f "$dir/.runner" ]]; then
    step "Runner already registered in $dir"
  else
    step "Downloading the GitHub Actions runner"
    local release version asset url digest notes_sha
    # shellcheck disable=SC2016  # jq variables, not shell ones
    release="$(gh api repos/actions/runner/releases/latest --jq '
      (.tag_name | ltrimstr("v")) as $v | ("actions-runner-osx-arm64-" + $v + ".tar.gz") as $n |
      $v, $n,
      ([.assets[] | select(.name == $n) | .browser_download_url][0] // ""),
      ([.assets[] | select(.name == $n) | .digest][0] // "" | ltrimstr("sha256:")),
      ((.body // "") | [match("BEGIN SHA osx-arm64 -->\\s*([0-9a-f]{64})").captures[0].string][0] // "")')" ||
      die "couldn't look up the latest runner release from github.com/actions/runner."
    { read -r version; read -r asset; read -r url; read -r digest; read -r notes_sha; } <<<"$release"
    [[ -n "$url" ]] || die "the latest runner release ($version) has no $asset."
    echo "Version $version"

    local tmp
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064  # expand $tmp now
    trap "rm -rf '$tmp'" EXIT
    curl -fsSL --retry 3 -o "$tmp/$asset" "$url" || die "download failed: $url"
    local actual
    actual="$(shasum -a 256 "$tmp/$asset" | awk '{ print $1 }')"
    if [[ -z "$digest" && -z "$notes_sha" ]]; then
      echo "warning: the release publishes no SHA-256 for $asset; continuing without a checksum check."
    fi
    for expected in "$digest" "$notes_sha"; do
      [[ -z "$expected" || "$expected" == "$actual" ]] ||
        die "SHA-256 mismatch for $asset: expected $expected, got $actual. Not installing."
    done
    [[ -n "$digest$notes_sha" ]] && echo "SHA-256 verified: $actual"

    rm -rf "$dir"   # a leftover, unconfigured folder from an interrupted install
    mkdir -p "$dir"
    tar -xzf "$tmp/$asset" -C "$dir"
    echo "$repo" > "$dir/.minirun-repo"

    step "Registering $name with $repo"
    local token
    token="$(gh api -X POST "repos/$repo/actions/runners/registration-token" --jq .token)" ||
      die "couldn't get a registration token for $repo (needs admin access and the 'repo' scope)."
    # The runner reads ACTIONS_RUNNER_INPUT_<ARG> for any argument, which keeps the token out of
    # the process list. --replace takes over a runner of the same name left on GitHub earlier.
    (cd "$dir" && ACTIONS_RUNNER_INPUT_TOKEN="$token" ./config.sh --unattended \
      --url "https://github.com/$repo" --name "$name" --labels "$LABEL_EXTRA" \
      --work _work --replace) || { rm -rf "$dir"; die "runner configuration failed (see above)."; }
    token=""
  fi

  step "Installing the runner LaunchAgent"
  if ! service_label "$dir" >/dev/null; then
    (cd "$dir" && ./svc.sh install)
  fi
  case "$(service_state "$dir")" in
    running) ;;
    "not loaded") (cd "$dir" && ./svc.sh start) || die "the runner service didn't start. Check $dir/_diag." ;;
    *) launchctl kickstart -k "gui/$(id -u)/$(service_label "$dir")" || die "the runner service didn't restart. Check $dir/_diag." ;;
  esac
  sleep 2
  echo "Service: $(service_state "$dir")"

  cat <<DONE

Runner '$name' is registered for $repo. Use it from a workflow with:

    runs-on: [self-hosted, macOS, minirun]

Jobs share this Mac with Claude's sessions: have them create and boot their own simulator and pass
its UDID on every call, rather than using whichever simulator is booted.
Logs: $dir/_diag
DONE
}

cmd_uninstall() {
  local repo="${1:-}"
  check_repo_arg "$repo"
  check_mac
  local dir
  dir="$(runner_dir "$repo")"
  if [[ ! -d "$dir" ]]; then
    echo "No runner installed for $repo."
    return 0
  fi

  step "Stopping the runner service"
  if [[ -x "$dir/svc.sh" ]] && service_label "$dir" >/dev/null; then
    (cd "$dir" || exit; ./svc.sh stop || true; ./svc.sh uninstall || true)
  fi

  if [[ -f "$dir/.runner" ]]; then
    step "Removing the runner from $repo"
    local token=""
    if (check_gh) && token="$(gh api -X POST "repos/$repo/actions/runners/remove-token" --jq .token)" &&
       (cd "$dir" && ACTIONS_RUNNER_INPUT_TOKEN="$token" ./config.sh remove --unattended); then
      echo "Deregistered."
    else
      echo "warning: couldn't deregister from GitHub. Remove '$(runner_name)' under $repo → Settings → Actions → Runners."
    fi
    token=""
  fi

  rm -rf "$dir"
  rmdir "$RUNNERS" 2>/dev/null || true
  echo "Runner for $repo removed."
}

# Starts or stops an installed runner's LaunchAgent. A stopped runner shows as offline on GitHub
# and takes no jobs; it stays registered, and starts again at the next login unless uninstalled.
cmd_service() {
  local action="$1" repo="${2:-}"
  check_repo_arg "$repo"
  check_mac
  local dir
  dir="$(runner_dir "$repo")"
  [[ -f "$dir/.runner" ]] || die "no runner is installed for $repo. Add one with: $0 install $repo"
  service_label "$dir" >/dev/null || die "the runner for $repo has no LaunchAgent. Re-run: $0 install $repo"
  case "$action" in
    start)
      case "$(service_state "$dir")" in
        running) echo "The runner for $repo is already running." ; return 0 ;;
        "not loaded") (cd "$dir" && ./svc.sh start) || die "the runner service didn't start. Check $dir/_diag." ;;
        *) launchctl kickstart "gui/$(id -u)/$(service_label "$dir")" || die "the runner service didn't start. Check $dir/_diag." ;;
      esac
      sleep 2 ;;
    stop)
      if [[ "$(service_state "$dir")" == "not loaded" ]]; then
        echo "The runner for $repo is already stopped."
        return 0
      fi
      (cd "$dir" && ./svc.sh stop) || die "the runner service didn't stop." ;;
  esac
  echo "Service: $(service_state "$dir")"
}

cmd_status() {
  local found=false dir repo name gh_status
  for dir in "$RUNNERS"/*/; do
    [[ -d "$dir" ]] || continue
    dir="${dir%/}"
    found=true
    repo="$(cat "$dir/.minirun-repo" 2>/dev/null || basename "$dir")"
    name="$(runner_name)"
    if [[ ! -f "$dir/.runner" ]]; then
      echo "$repo: not configured (re-run: $0 install $repo)"
      continue
    fi
    gh_status="$(gh api "repos/$repo/actions/runners" --paginate \
      --jq ".runners[] | select(.name == \"$name\") | .status + (if .busy then \", busy\" else \"\" end)" 2>/dev/null || true)"
    echo "$repo: runner '$name', service $(service_state "$dir"), GitHub ${gh_status:-unknown}"
  done
  $found || echo "No GitHub runners installed. Add one with: $0 install owner/repo"
}

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  start|stop) cmd_service "$@" ;;
  status) cmd_status ;;
  -h|--help) usage 0 ;;
  *) usage ;;
esac
