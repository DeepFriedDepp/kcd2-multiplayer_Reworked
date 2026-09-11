# WO-82 — progress

Session 2026-09-11. Release cut: build and ship WO-78 (Lua chain-leak fix),
WO-80 (.NET agent cutscene pause detection) and WO-81 (.NET relay + launcher
claim diagnostics) — three sessions that had landed on `main` but never been
built or installed. Findings and every number: `docs/WO-82-findings.md`.

## Status

- **Phase 0** done: `main` confirmed at WO-81's head (`ef4f570`); `git log`
  since 0.20.2 confirmed exactly WO-78/80/81 landed, nothing else. Two stale
  relay/master-server processes from an earlier session killed before any
  build step.
- **Phase 1** done: `VERSION` `0.20.2` → `0.20.6` (user-specified in the
  session prompt, not chosen here). Full release built:
  `KCDMP-Setup-0.20.6.exe` (39.1 MB), `KCDMP-DirectInstall-0.20.6.zip`
  (130 MB). WO-74's install matrix re-run against this version: 33/33
  (six-cell upgrade matrix), 21/21 (Steam-detection fixtures), 43/43
  (install/upgrade/uninstall lifecycle against a fixture Steam tree) — all
  fixture-based, nothing outside `%TEMP%` touched.
- **Phase 2** done: full regression suite green — 23/23, 14/14, 15/15,
  29/29, 28/28, 35/35, 11/11, 59/59, 48/48, 35/35 (ten suites; see findings
  §3 for the mapping). One deterministic failure was found and fixed:
  `Test-NpcClaimLifecycle.ps1`'s own T7 tripped over a race in its cleanup
  (`Stop-Process -Force` doesn't wait for the killed relay's log-file handle
  to release before the next `Remove-Item` runs), not a defect in WO-81's
  shipped relay code — root-caused, fixed with a 3s `WaitForExit`, re-run
  clean twice. `dotnet build KCD2-MP.sln`: 0 errors, the same 8 pre-existing
  warnings WO-80/81 already had.
- **Phase 3** partial, as the brief allows: no live game was running at
  session start and this session did not launch one (a screen-visible action
  not taken unprompted). What was checked used the actual shipped release
  relay binary: starts clean, writes `relay<date>.log` with the new Serilog
  config, no errors. `mp_npc_chainfix`/`mp_ghost_chainfix` confirmed present
  in the packed Lua (code-verified, not executed — no game to run them
  against). The real live-game and two-player checks are named explicitly as
  the maintainer's own next step.
- **Phase 4** done: `docs/releases/RELEASE-NOTES-0.20.6.md` written, stating
  verification status honestly (synthetic/replayed evidence only, first real
  build to touch a live game). README banner badge and the two feature-table
  rows referencing WO-78/80 as "(unreleased)" updated to `0.20.6`; a new row
  entry added for WO-81's relay diagnostics.

## Commits, in order (all on `main`, pushed to `origin main`)

See `git log --oneline` for hashes; messages prefixed `WO-82:`.

1. `WO-82: version 0.20.6, pak rebuild for WO-78/80/81`
2. `WO-82: fix a relay-log cleanup race in Test-NpcClaimLifecycle.ps1`
3. `WO-82: release notes, README banner + status rows for 0.20.6`
4. `WO-82: findings and progress docs`

## What was done, in order

1. Pulled; confirmed `main` at WO-81's head. Confirmed via `git log` that
   only WO-78/80/81 landed since 0.20.2. Killed two stale relay/master-server
   processes found already running.
2. Read `docs/WO-74-progress.md`, `docs/WO-78-findings.md`,
   `docs/WO-80-findings.md`, `docs/WO-81-findings.md` and their progress
   companions in full before touching anything.
3. Confirmed which build/test scripts touch the real game folder or
   `%LocalAppData%\KCDMP` (sandboxed from this shell) versus a throwaway
   fixture, so nothing this session ran would produce a meaningless result —
   see findings §0.
4. Bumped `VERSION` to `0.20.6`. Ran `tools\Build-Installer.ps1` (pak
   rebuild, publish, manifest, Inno Setup compile) then
   `tools\Build-DirectInstall.ps1 -SkipPublish`.
5. Built a standalone Steam-fixture helper script (scratchpad, matching
   `Test-InstallerUpgrade.ps1`'s own `New-SteamFixture` recipe) so
   `Test-Installer.ps1` could run with `-SteamRoot` instead of touching a
   real Steam library. Ran the three installer suites; all matched WO-74's
   original figures.
6. `dotnet build KCD2-MP.sln` — 0 errors, same 8 pre-existing warnings.
7. Ran the ten from-source regression suites against a fresh Debug relay
   (`Test-Sessions`/`Test-Combat`/`Test-Dice`) and the self-starting ones
   (`Test-NpcClaimValidation`/`Test-NpcClaimLifecycle`/`Test-TimeSkipRelay`/
   `Test-ItemSyncRelay`), the two MoonSharp synthetic suites, and the Farkle
   unit tests.
8. `Test-NpcClaimLifecycle.ps1` failed its T7 case deterministically (twice).
   Isolated the actual gate-off relay's own log output (everything after its
   own `Listening on port 7797` line) and found zero `[CLAIM]` lines,
   proving WO-81's shipped config gate was working correctly — root-caused
   the failure to a `Stop-Process`/`Remove-Item` race in the test's own
   cleanup, fixed it, re-ran clean twice. See findings §3.1.
9. Verified the actual shipped `release\KCDMP\KcdMpServer.exe` starts clean
   and writes its own log file with the new Serilog config. Confirmed
   `mp_npc_chainfix`/`mp_ghost_chainfix` are present in the packed Lua. No
   live game was reachable to go further.
10. Wrote `docs/releases/RELEASE-NOTES-0.20.6.md`. Updated the README badge
    and the two feature rows that referenced WO-78/80 as unreleased; added a
    relay-diagnostics line for WO-81.
11. Wrote this doc and the findings doc.

## Not done, deliberately

- No feature, protocol, engine, or gameplay code changed — the only source
  edit is the one-line test-cleanup race fix (findings §3.1).
- No live game launched, no two-player session — named as the maintainer's
  own next step, not attempted as a substitute.
- No investigation of the Setup.exe size drop from 0.19.0's 95.7 MB beyond
  confirming file-count/manifest/sha256 parity — flagged in findings §2,
  not chased further.
- No `docs/PROJECT-STATE.md` edit — nothing in this session changes the
  project-state ledger's own claims; it already reflects WO-78/80/81 as
  landed on `main`.

## For the next session

- Everything WO-78/80/81 each already named as their own follow-up still
  stands, unchanged by this release cut: `human:IsInDialog()` live probe
  (WO-80), the `ContestedGapSeconds` retune-if-needed (WO-81), and the
  longer-standing items in `docs/WO-78-findings.md` §5 (GHOST_DEATH
  flapping, the horse teleport, ExecuteString batch truncation).
- The real verification this release needs is a live two-player session:
  grep for the leak-detector lines (should be absent), watch a real
  cutscene and a real dialog with a connected ghost, and check
  `[CLAIM-CONTESTED]` against whatever jitter gets reported.
