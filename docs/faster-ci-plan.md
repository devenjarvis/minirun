# Faster CI across repos

minirun already makes a Mac a good place for Claude to build and test. This plan is about making
the same Mac a fast CI machine for several repositories at once. Five changes, each its own PR,
ordered so that each one makes the next one pay off more.

**Where things stand.** A CI job doesn't go through minirun at all. `scripts/github-runner.sh`
registers GitHub's own runner, one per repository, and the runner builds in its own `_work`
folder with plain `xcodebuild`. So CI gets none of minirun's warm checkouts, simulator
reservations, templates or stall detection, and nothing stops ten runners and three Claude
sessions from all booting simulators at once. Inside minirun, every repo + ref gets a full
`git clone` and its own DerivedData, so the first build of every branch is a cold build. One
Mac checked while writing this had about 130 such checkouts, many of them for commit SHAs.

The order: **2** and **3** first (they speed up Claude's own builds too, and are contained in
`Workspace.swift` and `XcodeBuild.swift`), then **1** (brings them to CI), then **4** and **5**
(more jobs at once).

---

## 1. CI jobs go through minirun

**Today:** a workflow targets `runs-on: [self-hosted, macOS, minirun]` and runs its own
`xcodebuild`. The README asks it to reserve a simulator by hand and not touch "the booted
simulator". Nothing makes it do so.

**Change:** a `minirun ci` command that talks to the running `minirun serve` over the control
socket (`ControlSocket.swift`), plus a composite action in this repo (`ci/action.yml`) that wraps
it:

```yaml
runs-on: [self-hosted, macOS, minirun]
steps:
  - uses: devenjarvis/minirun/ci@v1
    with:
      command: test            # build | test | swift-test
      scheme: App
```

- The action passes `GITHUB_REPOSITORY` and `GITHUB_SHA` as repo + ref. The job then uses
  minirun's checkout for that ref (from item 3, a worktree in seconds) and its DerivedData, not
  `_work`.
- The tool calls are the existing ones (`build`, `run_tests`, `swift_test`), called through
  a new `call_tool` control command, so CI gets reservations, `maxBootedSimulators`, the
  stall timeout and job persistence with no new build code. The job shows in `list_jobs` and the
  menu as `ci: owner/repo@sha`.
- `minirun ci` streams the job's log to stdout and exits with the job's status, so the step's log
  and pass/fail look like a normal step. Compiler errors become `::error file=…` annotations, the
  way `scripts/ci-step.sh` does it today.
- Cancelling the workflow run sends SIGTERM to the step; `minirun ci` turns that into `cancel_job`,
  which frees the simulator.
- The result bundle path is printed, and the action can upload it with `actions/upload-artifact`.

**Why it's first in its group:** every other CI speedup lands in minirun, so this is what lets CI
benefit from them.

**Tests:** argument building and the log/annotation formatting are pure functions in MiniRunKit
(Linux). An end-to-end step in `.github/workflows/ci.yml` on the macOS runner calls the action
against `Tests/Fixtures/HelloApp`.

**Open questions:** the control socket lives in the user's `~/.config/minirun`, which the runner's
LaunchAgent can reach as the same user. Commit SHAs as refs make one checkout per commit; with
item 3 these are cheap, but they should be evicted sooner than branch checkouts (see "Disk" below).

---

## 2. Share build state between refs of a repo (implemented in this PR, opt-in)

**Today:** `XcodeBuild.baseArgs` passes `-derivedDataPath <checkout>/.minirun/DerivedData`. Each
ref's DerivedData starts empty, so it resolves and clones every Swift package and compiles
everything from scratch.

**What doesn't work:** copying another ref's DerivedData (even as an instant APFS clone). Xcode's
build database records absolute paths, and every source path differs between
`you/app@main` and `you/app@feature`, so it rebuilds everything anyway. Xcode 27.2's
`-showBuildSettings` lists no path remapping settings to work around that.

**Change** (behind `sharedBuildCache`, off by default until measured):

- **Package checkouts per repo, by Package.resolved.** Pass `-clonedSourcePackagesDirPath
  <root>/.cache/packages/<owner>/<name>/<hash of Package.resolved>`. Refs that pin the same
  package versions share one folder, so packages are cloned once and their sources sit at the same
  absolute path for every ref. Refs with different pins get different folders, so concurrent
  builds never fight over which revision is checked out. The first build to use a folder runs
  `xcodebuild -resolvePackageDependencies` while holding a lock on it, and marks it done, so two
  builds don't fill it at once. A project with no Package.resolved (or none committed) keeps the
  old per-checkout folder.
- **One compilation cache per repo.** Xcode 26+ can cache compiler work in a content-addressed
  store (`COMPILATION_CACHE_ENABLE_CACHING=YES`). Its `COMPILATION_CACHE_CAS_PATH` defaults to
  inside DerivedData, that is, per checkout. Point it at `<root>/.cache/compilation/<owner>/<name>`
  so all refs of a repo share it. With package sources at the same path (above), package targets
  should hit the cache in every new ref; app targets may too, as far as Xcode keys them without
  paths.
- Both are skipped when `extra_args` already sets them, and only apply to checkouts under the
  workspace root (not `path` builds elsewhere).

**To measure before turning it on by default:** on a repo with several packages, time (a) a cold
build of a new branch today, (b) the same with `sharedBuildCache` on and a warm cache from `main`,
(c) an incremental build with it on vs off (the setting must not slow down Claude's loop). Watch
for local-path packages: SwiftPM's state file in the shared package folder records absolute
paths of local packages, which differ per checkout.

**Tests:** cache folder naming, Package.resolved discovery, the hash and the "don't override what
the caller set" rules are pure functions in MiniRunKit (`BuildCache`), tested on Linux.

---

## 3. One git mirror per repo, a worktree per ref (implemented in this PR)

**Today:** `Workspace.sync` runs `git clone --filter=blob:none` for every new ref. A new branch
waits for a full clone, and each checkout carries its own copy of the history.

**Change:** keep one bare, blobless mirror per repository at
`<root>/.git-mirrors/<owner>/<name>.git` and make each ref's checkout a `git worktree` of it.
The checkout folders stay where they are (`<root>/<owner>/<name>@<ref>`), so reservations, locks
and tools see nothing new.

- A new ref is `git worktree add --detach --no-checkout`, then the usual fetch of that ref and
  `checkout --force --detach FETCH_HEAD`. Objects already in the mirror aren't downloaded again.
- `FETCH_HEAD` is per worktree in git, so fetches for different refs don't overwrite each other's.
  Git operations on one mirror (fetch, checkout, worktree add) are serialized in-process, because
  they write the shared object store and tags.
- `git worktree prune` runs before each add, so a checkout deleted from the menu or by hand
  doesn't block a new one at the same path.
- `.minirun/` is ignored through the mirror's `info/exclude`, shared by all its worktrees.
- Existing checkouts (full clones) keep working as they are. Delete one and it comes back as a
  worktree. If making the mirror or worktree fails for any reason, sync falls back to a full clone,
  as before.
- `WorkspaceInventory` reads a worktree's last fetch time through its `.git` file, so the menu's
  "last used" stays right. The mirrors (and `.cache`) are dot folders, so they aren't listed as
  checkouts and can't be deleted from the menu by mistake.

**Tests:** mirror naming and resolving a worktree's git folder are in MiniRunKit (Linux). The
smoke test syncs two refs of one repo and checks they share a mirror.

---

## 4. One scheduler for all repos, not one runner each

**Today:** one runner per repository, each taking one job at a time. Ten repos means up to ten
concurrent jobs with no limit between them or against Claude's sessions. Personal accounts can't
register user-level runners, so there's no single runner for all of them.

**Change, in two steps:**

1. **A slot limit in minirun.** A `ciSlots` setting (default 2). `minirun ci` (item 1) waits for a
   free slot before starting a build or test, and the menu shows queued CI jobs. Claude's
   sessions are not counted against it, but simulators are still capped by `maxBootedSimulators`.
   This alone stops the stampede, with the per-repo runners unchanged.
2. **Just-in-time runners.** The Worker gets a `/github/webhook` endpoint for `workflow_job`
   events (signed with a webhook secret). On `queued` for a job whose labels include `minirun`, it
   tells the Mac, which, when a slot is free, asks GitHub for a JIT runner config
   (`POST /repos/{owner}/{repo}/actions/runners/generate-jitconfig`) and starts an ephemeral
   runner for exactly that job. No standing registrations, no per-repo install, and each job gets
   a fresh runner folder. Adding a repo becomes adding a webhook. For an organization, one
   org-level webhook and `generate-jitconfig` cover every repo. The token needs `administration:
   write` on the repo (or org); a fine-grained token or GitHub App is better than the `gh` login.

**Tests:** slot accounting is a pure actor in MiniRunKit. The webhook signature check and event
filtering are unit-tested in the Worker (`npm test`).

**Security:** the same as today's runner, plus: the webhook endpoint must reject unsigned
events, and must ignore jobs from public repos unless they're explicitly allowed, like
`--allow-public`.

---

## 5. Parallel and sharded tests

**Today:** `XcodeBuild.testDefaults` sets `-parallel-testing-enabled NO`, because parallel testing
makes its own simulator clones outside minirun's reservations, and those were a common cause of
hangs. One CI job runs its whole test plan on one simulator.

**Change:**

- `run_tests` gets `shards: N`. minirun runs `build-for-testing` once, then `test-without-building`
  with the `.xctestrun` file on N simulators it reserves itself (clones of the model's template,
  see item 2 in `simulator-lifecycle-followups.md`), each with a share of the test classes. It
  merges the result bundles with `xcresulttool merge` and reports one summary.
- Test classes are split by previous run time when the last result bundle for that repo is
  available, else by name. A shard that stalls is stopped and reported on its own; the others
  keep their results.
- `shards` counts against `maxBootedSimulators` and, for CI, against the slot's simulator budget.
- `minirun ci` passes `shards` through, so a workflow opts in with one input.

This depends on simulator templates being made on demand (lifecycle follow-up 2): without them
each extra shard's first boot costs minutes, which is more than most test runs.

**Tests:** shard assignment (by time, by name) is a pure function in MiniRunKit. The smoke test runs
the fixture's tests with `shards: 2`.

---

## Disk

Items 2 and 3 reduce disk use (one history per repo; shared packages), but checkouts,
DerivedData, the package folders and the compilation cache still only grow. A follow-up should
evict by age and total size: checkouts for commit SHAs first, then branch checkouts not used
for N days, then package folders no checkout's Package.resolved points to, then the oldest
compilation caches. That runs in the idle loop, like simulator shutdown, and never touches a
busy checkout (`WorkspaceInventory.isBusy`).
