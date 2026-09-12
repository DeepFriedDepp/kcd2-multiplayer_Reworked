# WO-85 — progress

Session 2026-09-12. Release cut: build and ship WO-83 (guard-class roster
fix, already shipped in 0.20.9), WO-84 (animation throttle + leak retirement
+ stray sweep, already shipped in 0.20.8) and WO-86 (NPC death sync, merged
to `main` but never built) together for the first time. Findings and every
number: `docs/WO-85-findings.md`.

## Status

- **Phase 0** done: `main` confirmed at WO-86's head (`5d6ab59`); `git log`
  since 0.20.6 confirmed exactly WO-84/83/86 landed. Confirmed via
  path-scoped `git log` that WO-86's changes span all three layers
  (`kdcmp.lua`, `dotnet/KcdMp.Protocol`, `native/KCDMP`), not just Lua. No
  stale processes found running.
- **Phase 1** done: `VERSION` `0.20.9` → `0.21.1` (user-chosen; `0.21.0`
  skipped). Native `KCDMP.dll` rebuilt clean (327,680 bytes, sha256-confirmed
  identical to the copy embedded in the shipped installer's own manifest —
  this build's one new risk, explicitly verified, not assumed).
  `KCDMP-Setup-0.21.1.exe` (95.8 MB) and `KCDMP-DirectInstall-0.21.1.zip`
  (130 MB) built via the documented pipeline. Install matrix run against
  fixtures (real AppData is sandbox-redirected from this shell, per
  `[[appdata-sandbox-redirection]]`): 21/21 (Steam detection), 33/33
  (six-cell upgrade matrix, incl. upgrade from the real 0.20.9 Setup exe
  found on disk), 43/43 (full install/upgrade/uninstall lifecycle) — all
  matching WO-82's own figures for the same three suites.
- **Phase 2** done: full regression suite green, 415/415 across 12 suites
  (see findings §3 for the mapping). Nothing needed fixing this session.
  `dotnet build KCD2-MP.sln`: 0 errors, same 8 pre-existing warnings.
- **Phase 3** not done, as the brief allows: no live game was running at
  session start and this session did not launch one. Named explicitly as
  the maintainer's own next step for all three underlying sessions' work.
- **Phase 4** done: `docs/releases/RELEASE-NOTES-0.21.1.md` written, stating
  verification status honestly — everything proven in isolated tests,
  nothing (least of all the four-layer death-sync fix) watched live yet.
  `docs/VERSIONING.md`'s `0.21.1` row corrected to attribute the session as
  `WO-85` (was mislabeled `WO-86` from uncommitted working-tree state going
  into this session) and reworded to describe the consolidated build.

## Commits, in order (all on `main`, to be pushed to `origin main`)

See `git log --oneline` for hashes; messages prefixed `WO-85:`.

1. `WO-85: version 0.21.1, native DLL + full release build for WO-83/84/86`
2. `WO-85: findings and progress docs`

## What was done, in order

1. Pulled; confirmed `main` at WO-86's head. Confirmed via `git log`
   (repo-wide and path-scoped) that WO-83/84/86 all landed and that WO-86
   specifically touches Lua, protocol and native code, not just one layer.
2. Found `VERSION`, `README.md`, `docs/VERSIONING.md`,
   `kdcmp/Data/kdcmp.pak` and `tools/Verify-Install.ps1` already modified in
   the working tree (uncommitted) from earlier in this same session, bumping
   to `0.21.1`. Verified this reflected an already-answered version question
   (`docs/VERSIONING.md`'s own new row cites "User-chosen; 0.21.0 skipped by
   the user") rather than re-asking. Verified no dotnet/native source
   differed from `HEAD` — confirming nothing was silently changed
   mid-session — before proceeding.
3. Set up the MSVC Build Tools PATH (`vswhere.exe` under
   `...\Microsoft Visual Studio\Installer`) and ran
   `native\Build-Native.ps1 -Clean` for a guaranteed fresh compile: 327,680
   bytes.
4. Ran `tools\Build-Installer.ps1` (rebuilds the pak, publishes all four
   .NET projects, generates the install manifest, compiles the Setup exe)
   then `tools\Build-DirectInstall.ps1 -SkipPublish`. Confirmed by sha256
   that the manifest's `KCDMP.dll` entry is the exact DLL step 3 built.
5. Ran the full Phase 2 regression suite: a fresh Debug relay for
   Test-Sessions/Test-Combat, a separate fresh relay for Test-Dice (known
   trap: stale relay state breaks Dice), the four self-starting relay
   suites, the Farkle unit tests, and the four MoonSharp synthetic suites.
   All green on the first run; nothing needed fixing.
6. Ran the three fixture-based installer suites
   (Test-InstallerDetect/Test-InstallerUpgrade/Test-Installer with a
   scratchpad Steam fixture) against the real `KCDMP-Setup-0.21.1.exe`,
   satisfying the install-matrix requirement without touching the
   sandbox-redirected real install directory.
7. `dotnet build KCD2-MP.sln -c Release` — 0 errors, same 8 pre-existing
   warnings as prior sessions.
8. Checked for a live game (`tasklist`): none running; did not start one.
9. Wrote `docs/releases/RELEASE-NOTES-0.21.1.md`. Corrected
   `docs/VERSIONING.md`'s `0.21.1` row from "WO-86" to "WO-85" and reworded
   it to describe the consolidated build.
10. Wrote this doc and the findings doc.

## Not done, deliberately

- No feature, protocol, engine, or gameplay code changed — see findings §6.
- No live game launched, no two-player session — the maintainer's own next
  step, for all three underlying sessions' fixes at once.
- No `docs/PROJECT-STATE.md` edit — nothing here changes what it already
  claims about WO-83/84/86.

## For the next session

The real verification this release needs is a live two-player session on
`0.21.1` specifically, since it is the first build where all three
sessions' work — and WO-86's native half in particular — has actually run
compiled together:

1. Confirm no roster ghost enforces the drawn-weapon rule (WO-83).
2. Confirm ghost animation no longer spams the queue and stray bodies get
   swept during play (WO-84).
3. Kill a world NPC as one player, watch whether the other player's copy
   dies too and whether a locally-dead body stops following a live stream
   (WO-86) — read `docs/WO-86-progress.md`'s "Next session (live)" section
   for the exact log lines to check on each machine.
4. `mp_npc_deathsync off` on both, repeat once, to see the pre-WO-86 shape
   with the new logging in place.
