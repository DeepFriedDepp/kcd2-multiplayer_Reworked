# WO-85 — release cut: 0.21.1 (WO-83 + WO-84 + WO-86)

Release-build session, 2026-09-12. Mechanical, not novel: follows WO-74/82's
already-proven build/install pipeline. Unlike WO-82, this is not three
sessions that had merely never been *installed* — WO-83 and WO-84 already
shipped their own Setup exes (0.20.9, 0.20.8). What this session actually
adds is the first full production build that includes **WO-86**, and the
first time in this arc the native `KCDMP.dll` half of a release required a
rebuild rather than being reused unchanged.

Evidence discipline as in prior WOs: **(observed)** run this session ·
**(code-verified)** read directly in the source tree.

---

## 0. Ground truth

- (observed) `git pull`: already up to date. `main` at `5d6ab59` (WO-86's
  findings/progress commit).
- (observed) `git log --oneline` since 0.20.6 (WO-82): exactly WO-84 (4
  commits incl. its own 0.20.8 release), WO-83 (3 commits incl. its own
  0.20.9 release), WO-86 (2 commits, no release) — nothing else landed.
- (observed) `git log --oneline --all -- kdcmp/Data/Scripts/Startup/kdcmp.lua`
  confirms WO-83 (`4d392ec`), WO-84 (`66e1cec`, `d0eacc5`) and WO-86
  (`d7da56a`) commits all touch the file. `git log -- dotnet/KcdMp.Protocol`
  and `-- native/KCDMP` both show `d7da56a` (WO-86) as their most recent
  commit, confirming the protocol and native halves of the death-sync work
  are present, not just the Lua half.
- (observed) No stale relay/agent/game processes were running at session
  start (`tasklist` filtered for `kingdom|kcdmp|kcd2`: empty).

## 1. Version

**`VERSION`: `0.20.9` → `0.21.1`, user-chosen; `0.21.0` deliberately
skipped.** Per `docs/VERSIONING.md`, this is the largest single build in the
project's arc so far — three sessions, four subsystems (Lua, protocol, agent,
relay, and for the first time in this arc, the native plugin) — flagged
here, not decided on: the version given is what shipped.

`docs/VERSIONING.md`'s own version-history table previously attributed the
`0.21.1` row to "WO-86"; corrected to "WO-85" in this session, since WO-86's
own commits never touched `VERSION` (confirmed: no commit bumps it; the
change was uncommitted working-tree state going into this session) and the
row's own convention (see `0.20.6 | WO-82 | + WO-78/80/81`) attributes each
row to the session that did the packaging, not the session whose code
changes it happens to describe.

## 2. Build

All four artifacts confirmed freshly built this session, not reused:

- **Native `KCDMP.dll`**: `native\Build-Native.ps1 -Clean` (full CMake
  reconfigure + Ninja rebuild from a wiped `native\build\`, not an
  incremental build). Output: `327,680 bytes`, matching the size WO-86's own
  scratch-environment build reported. sha256
  `be76ba6a578a356357485b542dffa5175c4a86d452ce4c376b615c5a872c8984`,
  confirmed identical between `native\build\KCDMP\KCDMP.dll`,
  `release\KCDMP\KCDMP.dll`, and the `APP|KCDMP.dll|327680|be76ba6a...`
  line in `release\KCDMP\install-manifest.txt` — the shipped installer
  embeds the exact DLL this session compiled, not a stale one.
- **Agent, relay, master server, launcher**: `tools\Build-Installer.ps1`
  (without `-SkipPublish`) republished all four via `dotnet publish`, then
  rebuilt `kdcmp.pak` from source, generated the manifest, and compiled
  `KCDMP-Setup-0.21.1.exe` (95.8 MB). `tools\Build-DirectInstall.ps1
  -SkipPublish` then packaged `KCDMP-DirectInstall-0.21.1.zip` (130 MB) from
  the same payload, per `docs/VERSIONING.md`'s documented order (so the two
  artifacts' `kdcmp.pak` — not byte-deterministic across separate rebuilds —
  stay identical to each other).
- `dotnet build KCD2-MP.sln -c Release`: 0 errors, 8 warnings — the same 8
  pre-existing warnings WO-80/81/82 already had (2 nullability, 6
  `CA1416` Windows-registry-on-all-platforms), nothing new.

## 3. Regression suite (Phase 2)

All green, 415 checks, 0 failures:

| Suite | Result | Notes |
|---|---|---|
| Test-Sessions | 22/22 | fresh Debug relay |
| Test-Combat | 14/14 | same relay as Sessions |
| Test-Dice | 15/15 | separate fresh relay (known trap: stale relay state breaks Dice) |
| Test-NpcClaimValidation | 29/29 | self-starting relay |
| Test-NpcClaimLifecycle | 28/28 | self-starting relay, `-WorkingDirectory` set so `appsettings.json` actually loads |
| Test-TimeSkipRelay | 35/35 | self-starting relay |
| Test-ItemSyncRelay | 11/11 | self-starting relay |
| Farkle unit tests | 59/59 | `dotnet test`, Release |
| Test-NpcSmoothSynthetic | 48/48 | MoonSharp, no relay/game |
| Test-GhostInterpSynthetic | 35/35 | MoonSharp, no relay/game |
| Test-WO84Synthetic | 72/72 | MoonSharp, no relay/game |
| Test-WO86Synthetic | 47/47 | MoonSharp, no relay/game; matches WO-86's own reported figure |

No regressions found; nothing needed fixing.

## 4. Install matrix (Phase 1 step 6)

`[[appdata-sandbox-redirection]]` rules out running the real
`KCDMP-Setup-0.21.1.exe` against this machine's actual `%LocalAppData%\KCDMP`
from this shell — that path is virtualized for tool processes here and any
result read back would be meaningless. WO-74/82 already solved this: the
project's own fixture-based installer suites exercise the exact matrix the
session brief asked for (virgin install, upgrade from a previous release,
idempotent re-run) against a throwaway Steam tree under `%TEMP%`, never
touching the real install directory or a real Steam library. All three run
against the real `KCDMP-Setup-0.21.1.exe`:

- `tools\Test-InstallerDetect.ps1` — Steam/Modding-Tools detection against
  synthetic fixtures: **21/21**.
- `tools\Test-InstallerUpgrade.ps1` — six-cell matrix, each an independent
  fixture install: virgin, upgrade from the previous release
  (`KCDMP-Setup-0.20.9.exe`, found on disk), idempotent re-run, a
  deliberately half-applied install repaired, a damaged mod folder repaired,
  and the negative control (one unreplaceable file — Setup must NOT exit
  green): **33/33**, matching WO-82's own figure for this suite exactly.
- `tools\Test-Installer.ps1 -SteamRoot <fixture>` — full lifecycle: fresh
  install (files, registry, shortcuts, `settings.json` seeding, Add/Remove
  Programs entry), upgrade over the existing install (settings preserved),
  silent uninstall (everything owned removed, nothing else touched):
  **43/43**, matching WO-82's own figure for this suite exactly.

97/97 additional checks, 0 failures. Combined with §3, **512 checks total
this session, 0 failures.**

## 5. Phase 3 (smoke pass)

No live game was reachable — `tasklist` found no `KingdomCome*` process at
any point this session, and starting one (Steam → KCD2 Modding Tools →
load a save) is an interactive step this release-cut session did not take.
Per the brief, this is opportunistic only; the real two-player verification
of the death-sync fix, the guard-roster fix and the animation/leak/sweep
fixes remains explicitly the maintainer's own follow-up.

## 6. What was NOT done, deliberately

- No feature, protocol, engine, or gameplay code changed this session —
  only `VERSION`, `README.md`, `docs/VERSIONING.md`, `kdcmp/Data/kdcmp.pak`
  (rebuilt, not edited), and `tools/Verify-Install.ps1` (new markers).
- No live game launched, no two-player session — named as the maintainer's
  own next step for all three sessions' work, not attempted as a
  substitute.
- No `docs/PROJECT-STATE.md` edit — nothing in this session changes what
  that ledger already claims about WO-83/84/86 landing on `main`.
