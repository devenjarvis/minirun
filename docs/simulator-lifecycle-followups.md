# Simulator lifecycle: follow-up work

minirun now shuts down idle simulators (`idleShutdownMinutes`), caps how many run at once
(`maxBootedSimulators`, which `boot_simulator` now respects too), saves last-used times, and boots
simulators outside the allocation lock so one session's first boot doesn't block the others.

The items below are still open. Each one should fit in its own PR. They're ordered by payoff.

## 1. Take back stale reservations instead of failing at the cap

**Today:** when `maxBootedSimulators` simulators are running and all are reserved, a build
without `device` fails and lists them (`SimulatorPicker.target`, `Sources/MiniRunKit/Simulators.swift`).
Idle shutdown frees them eventually, but only after `idleShutdownMinutes`.

**Change:** at the cap, hand over the least recently used simulator that is not busy and has been
idle past a shorter threshold, for example 10 minutes. Busy means it has a job running or a
viewer watching (`SimulatorActivity`). Say so in the result, the way "It was reserved for X; it's
now reserved for Y" does today. The picker would need the busy set as input, and the threshold
should be a config setting.

**Tests:** picker cases in `SimulatorPickerTests` (Linux).

## 2. Make templates for `simctl clone`, and delete stale copies

**Today:** when every simulator of a model is in use, minirun makes a copy (`ToolRegistry.realize`).
If a shut-down template of that model and runtime exists (named like
"iPhone 17 Pro (minirun template)", see `SimulatorPicker.template`), it runs `simctl clone`, which
copies the template's data and skips the first-boot data migration. Otherwise it runs
`simctl create` and the first boot takes several minutes. Only the smoke test makes templates
(`scripts/sim-template.sh`). The "(minirun N)" copies are never deleted, so they pile up in
`~/Library/Developer/CoreSimulator/Devices`.

**Change:**
- Make the template the first time a copy of a model is needed: create it, boot it once, shut it
  down, then clone it. Do it outside the allocation lock, and not alongside another first boot
  (two at once timed out `simctl` calls on GitHub's runners).
- Delete copies (names containing `SimulatorPicker.cloneMarker`, but not templates) that have been
  shut down for more than a few days, or keep at most N of them, with `simctl delete`. This could
  run in the idle shutdown loop (`ToolRegistry.shutDownIdleSimulators`).

**Tests:** the choice of which copies to delete can be a pure function in MiniRunKit.

## 3. Clean up when a simulator changes hands

**Today:** when a build adopts a free simulator, the previous session's app and its data stay
installed.

**Change:** when `workspaceDevice` hands a simulator to a different workspace than the one before,
uninstall the claim's last `bundleID` (`Simctl.uninstall`). This is much cheaper than
`simctl erase`, which needs a shutdown and a fresh first boot. Skip it when the new workspace is
the same repo, so switching branches keeps the app's data.

**Tests:** the "should we uninstall, and what" decision can live in MiniRunKit. The uninstall
itself needs a Mac.

## 4. Pick a free simulator instead of failing when several are booted

**Today:** a build without `device` fails with a list when more than one booted simulator has no
reservation (`SimulatorPicker.target`, the `free.count > 1` branch). The idle shutdown spare makes
this less common, but simulators booted by hand still trigger it.

**Change:** take the most recently used free simulator and reserve it. The no-guessing rule
exists so taps never land on someone else's simulator. Claiming an unreserved simulator for a
build that will report its UDID doesn't risk that. Leave plain tools (`tap`, `screenshot` and
so on) as they are: those should still refuse to guess.

**Tests:** update `testBuildsFindTheirOwnSimulator`.

## Smaller items

- **Build while the simulator boots.** `build` and `build_and_run` wait for the boot before
  starting `xcodebuild`. Compiling doesn't need a booted simulator, so the two could overlap,
  waiting for `Allocation.ready()` only before install. Check first that `xcodebuild` accepts a
  destination ID that is still booting.
- **A stuck boot.** If `bootstatus` times out, the simulator can be left in the `Booting` state.
  Its reservation is then dropped and the next pick tries to boot it again, which fails. Shut it
  down when a boot fails.
