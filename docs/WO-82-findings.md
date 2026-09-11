# WO-82 — release cut: 0.20.6 (WO-78 + WO-80 + WO-81)

Release-build session, 2026-09-11. Mechanical, not novel: follows WO-74's
already-proven build/install pipeline to ship three prior sessions' work that
had landed on `main` but never been built or installed — WO-78 (Lua
chain-leak fix), WO-80 (.NET agent, cutscene pause detection), WO-81 (.NET
relay + launcher, claim-lifecycle logging). No product code was written in
this session except a one-line fix to a test script's own cleanup race,
found and root-caused during Phase 2 (§3 below).

Evidence discipline as in prior WOs: **(observed)** run this session ·
**(code-verified)** read directly in the source tree.

---

## 0. Ground truth

- (observed) `git pull`: already up to date. `main` at `ef4f570` (WO-81's
  findings/progress commit) before this session's own commits.
- (observed) `git log --oneline` since `f1d5f94` (0.20.2): exactly WO-78 (3
  commits), WO-80 (2 commits), WO-81 (4 commits) — nothing else landed.
  Matches the session brief's own accounting; no surprises.
- (observed) Two stale processes from an earlier session were still running
  at session start — `KcdMpServer.exe` and `KcdMpMasterServer.exe`, both
  bound to port 7778 with no owning shell attached. Killed before any build
  or test step, per the standing discipline (WO-32/WO-74's "hard-kill test
  processes before rebuilding").
- (code-verified) `tools\Build-Installer.ps1` and `tools\Build-DirectInstall.ps1`
  only ever write under `release\` (repo-local, gitignored) and rebuild the
  pak via `Build-And-Install-Mod.ps1 -NoInstall`, which never touches a game
  folder. `tools\Test-InstallerUpgrade.ps1` and `tools\Test-InstallerDetect.ps1`
  only ever touch a fixture Steam tree under `%TEMP%`. `tools\Test-Installer.ps1`
  touches the real game folder **unless** `-SteamRoot` is passed, so it was
  run against a fixture built from the same recipe (`New-SteamFixture`) that
  `Test-InstallerUpgrade.ps1` uses internally. None of this session's build or
  test steps touched `%LocalAppData%\KCDMP` or a real Steam library — see
  `[[appdata-sandbox-redirection]]` for why that matters from this shell.

## 1. Version

**`VERSION`: `0.20.2` → `0.20.6`, user-specified in the session prompt** (not
chosen by this session — per `docs/VERSIONING.md`).

Worth flagging, not deciding: bundling a Lua fix (WO-78), an agent-side fix
(WO-80) and relay/launcher changes (WO-81) together reads, by this project's
own past pattern (e.g. `0.11.5`'s four-WO bundle), as more than a patch-level
step. `0.20.2 → 0.20.6` is what was asked for and what shipped; noting the
observation here per the brief's own instruction, not overriding the given
number.

## 2. Build

- `tools\Build-Installer.ps1`: rebuilt `kdcmp.pak` (409,120-byte Lua source,
  561,019-byte pak — same shape as WO-78 left it, just repacked), published
  launcher/agent/relay/master-server self-contained, generated the v2 install
  manifest (1,024 entries), compiled `release\KCDMP-Setup-0.20.6.exe` via
  Inno Setup 6. **0 errors.**
- `tools\Build-DirectInstall.ps1 -SkipPublish`: built
  `release\KCDMP-DirectInstall-0.20.6.zip` from the same publish output.
- Artifact sizes: `KCDMP-Setup-0.20.6.exe` 39.1 MB, `KCDMP-DirectInstall-0.20.6.zip`
  130 MB. The Setup exe is notably smaller than 0.19.0's recorded 95.7 MB
  (WO-74) for what the install matrix confirms is the same file count (1,024
  manifest entries, 1,027 files in a clean install dir — consistent with
  0.19.0's 1,022). Read as an Inno Setup compression difference, not a
  missing-content signal: cell-by-cell byte/sha256 comparison against a fresh
  reference install of this same version (below) found zero differences in
  every cell, including the byte-for-byte "self-contained runtime present"
  check. Not independently root-caused beyond that; noted rather than
  silently assumed benign.
- Native plugin/injector and Inno Setup 6 were already present on this
  machine; neither needed a fresh build.

## 3. Phase 2 regression — one test-only bug found and fixed

All suites green. Two needed no action; one (`Test-NpcClaimLifecycle.ps1`)
failed deterministically on first run and was root-caused as a race in the
test's own cleanup, not a defect in WO-81's shipped relay code — details
below. Every other figure matches or equals the originating WO's own
reported count.

| Suite | Result | vs. originating WO |
|---|---|---|
| `Test-Sessions.ps1 -IncludeTimeout` | **23/23** | matches WO-74 |
| `Test-Combat.ps1` | **14/14** | matches WO-74/81 |
| `Test-Dice.ps1` (fresh source relay, Debug, no `-ReleaseRelay`) | **15/15** | WO-81's own run hit 1 pre-existing intermittent flake on this suite (confirmed present on an untouched baseline, unrelated to WO-81's area); this run did not reproduce it — consistent with "intermittent," not a contradiction |
| `Test-NpcClaimValidation.ps1` | **29/29** | matches WO-81 |
| `Test-NpcClaimLifecycle.ps1` | **28/28**, after a one-line test fix (see below) | matches WO-81's original figure |
| `Test-TimeSkipRelay.ps1` | **35/35** | matches WO-81 |
| `Test-ItemSyncRelay.ps1` | **11/11** | matches WO-81 |
| Farkle unit tests (`dotnet test dotnet\KcdMp.Farkle.Tests`) | **59/59** | matches WO-81 |
| `Test-NpcSmoothSynthetic.ps1` | **48/48** | matches WO-78 |
| `Test-GhostInterpSynthetic.ps1` | **35/35** | matches WO-78 |
| `dotnet build KCD2-MP.sln` (7 projects) | 0 errors, 8 warnings | same 8 pre-existing warnings as WO-80/81 (1 `ServerList.razor` nullability, 1 `LogTailGameTransport.cs` nullability, 6 `CA1416` Windows-registry-API warnings in `KcdMp.Client`) — none new |

Also run, fixture-only, no real game/Steam touched (WO-74's own suites,
re-confirmed against this version):

| Suite | Result | vs. WO-74 |
|---|---|---|
| `Test-InstallerUpgrade.ps1` (6-cell matrix) | **33/33** | matches |
| `Test-InstallerDetect.ps1` | **21/21** | matches |
| `Test-Installer.ps1 -SteamRoot <fixture>` | **43/43** | matches |

### 3.1 `Test-NpcClaimLifecycle.ps1` T7 — a test race, not a relay defect

First run: 27/27 + 1 failure — "no `[CLAIM]` line anywhere in the log with
the gate off" (T7) failed, while the same test's own functional assertion two
lines later ("claim counters all zero with the gate off") **passed**.
Reproduced identically on a second clean run — deterministic, not flaky.

Root cause (code-verified after isolating it): T7 starts a second relay
instance in the **same working directory** as the first (so both, being on
the same calendar day, share one `relay<date>.log` under Serilog's
`rollingInterval: Day`). The script already knows this and calls
`Remove-Item (Join-Path $serverDir 'relay*.log')` right after killing the
first relay, specifically so T7 reads only fresh content. But
`Stop-Process -Force` requests termination and returns — it does not wait for
the OS to actually tear the process down — so `Remove-Item`, running
immediately after, can hit a file the first relay's Serilog File sink hasn't
released yet. `-ErrorAction SilentlyContinue` swallows that, the stale file
survives, and the second (gate-off) relay's own log lines land after the
first relay's genuine (gate-on) `[CLAIM]` lines still sitting in the same
file — which is exactly what T7's substring check then (correctly, given
what it was looking at) flagged as a failure.

Confirmed directly: `awk` isolating only the lines the *second* relay
instance itself wrote (everything after its own `Listening on port 7797`
line) shows **zero** `[CLAIM]` lines — the config gate
(`NpcClaimValidation:ClaimLifecycleLogging=false`) was working exactly as
WO-81 shipped it the whole time.

**Fix** (`tools/Test-NpcClaimLifecycle.ps1`, one call site): added
`$relay.WaitForExit(3000)` right after `Stop-Process -Force` in the `finally`
block, so the file handle is actually released before the next
`Remove-Item` runs. Re-ran twice after the fix: **28/28** both times,
matching WO-81's original figure. No relay, protocol, or claim-logic code
touched — this is test tooling only.

## 4. Phase 3 — smoke pass

**No live game was running at session start** (checked: no `KingdomCome.exe`
process, no listener on the debug API ports). Per the brief, Phase 3 is
opportunistic and not required to ship; launching the actual game is a
heavyweight, screen-visible action this session did not take unprompted.
What *was* checked, using the actual shipped release artifact rather than
source:

- (observed) `release\KCDMP\KcdMpServer.exe` (the published relay binary that
  ships in both the installer and the DirectInstall zip) started cleanly,
  bound its port, and wrote a real `relay20260911.log` next to itself with
  the new Serilog file-sink config from `appsettings.json` — the same file
  content shape WO-81 wired into Collect Logs. No errors.
- (code-verified) `mp_npc_chainfix` and `mp_ghost_chainfix` are present in the
  Lua source this session just packed into `kdcmp.pak` (10 matches across
  both console-command registrations and their handlers) — confirms they
  shipped in this build's pak. Not executed: both are in-game console
  commands and no game was running to run them against.
- **Not done, explicitly**: "game loads with the new pak, no obvious startup
  errors" needs a live game, which this session did not launch. The real
  two-player verification — jitter feel, cutscene behavior, whether
  `[CLAIM-CONTESTED]` ever fires against a real report — remains the
  maintainer's own follow-up, exactly as the brief says, not something this
  session substitutes for.

## 5. What this session did not do

- No feature, protocol, or gameplay code changed. The only source edit is
  the one-line test-race fix in §3.1.
- No engine, native plugin, or Lua changes beyond the pak rebuild (repack of
  already-shipped WO-78 Lua source; no new bytes of logic).
- Did not launch the actual game or attempt a live two-player test — named
  explicitly as the maintainer's own next step, not skipped silently.
- Did not investigate the Setup.exe size difference from 0.19.0 beyond
  confirming file-count/manifest/sha256 parity (§2) — flagged, not chased
  further, since nothing in the verification suite suggests missing content.

## 6. For the next session

- Watch a real two-player field session for: `GHOST CHAIN LEAK CONFIRMED` /
  `NPC-SYNC CHAIN LEAK CONFIRMED` (should be absent), `CHAIN <key> was
  suspended, not dead` (expected, proves the gate is working), and
  `[CLAIM-CONTESTED]` on the relay correlated against `distanceBetweenPlayers`
  and whatever jitter is actually reported.
- If `human:IsInDialog()` ever gets probed live and works, that is the
  concrete next step for dialog pause coverage (WO-80's own named follow-up,
  still open).
- The Setup.exe size drop noted in §2 is unexplained past "compression, not
  missing content" — worth a closer look if a future release shows an even
  bigger jump either direction.
