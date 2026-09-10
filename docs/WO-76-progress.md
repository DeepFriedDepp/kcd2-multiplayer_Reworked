# WO-76 progress

Read `docs/WO-76-findings.md` first — it carries the evidence and citations.
This file is the state-of-play, run phase by phase and pushed to `origin
main` at the end of each phase, per the work order.

## Status

| Phase | State |
|---|---|
| 0 — ground truth | done. PR #3 open/unmerged (GitHub API); `ClientSession.Id` confirmed `byte` from source; Id-wrap pool item ruled **in scope** |
| 1 — five small fixes | done, 5 commits: ServerFull packet, MaxPlayers clamp, run_sync started-path timeout, Id-wrap pool, kdcmp.lua nil fix |
| 2 — test suite repair | done, 1 commit: all six named suites fixed, sweep re-run clean |
| 3 — discriminator | **not run** — no live game in this environment; no data fabricated |
| 4 — doc corrections | done, 1 commit: README/RELEASE-NOTES/PROJECT-STATE/MASTER-SERVER fixed; WO-69-progress got a pointer; deferred list named |
| Suites | green — see findings §5. `Test-Pipe` and the six repaired live-game suites not run, reason stated |
| Code changes | .NET (Server/Client/Protocol), native (`pipe_server.cpp`), Lua (`kdcmp.lua`), PowerShell (7 test scripts) |
| `VERSION` | unchanged |
| Live game / relay-under-game-load / injector | none run this session |

## Commits, in order (all on `main`, all pushed)

1. `WO-76: clamp ServerInfo:MaxPlayers to >=1, log the effective limit`
2. `WO-76: free-list pool for the wire's byte-wide session id`
3. `WO-76: ServerFull (0x36) reject packet instead of a silent close`
4. `WO-76: bound pipe_server's wait on a started native call`
5. `WO-76: fix undefined raw_vx/raw_vy in KCD2MP_UpdateGhost`
6. `WO-76: repair six stale test-suite assertions (docs/WO-75-audit-findings.md s5)`
7. `WO-76: doc corrections — README, release notes, PROJECT-STATE, MASTER-SERVER`

Items 1/2/3 in Phase 1 all touch `ClientHandler.cs`/`ClientSession.cs` in
adjacent but separable hunks; each commit was built by staging only its own
hunks (verified with `dotnet build` at each intermediate state before
committing), not by one bulk commit split after the fact.

## What was done, in order

1. Confirmed the session's working directory was the right repo (`git
   remote -v`, `git log`) before touching anything — this session started
   from a generic scratch workspace and had to be redirected.
2. `git pull` (already up to date); checked PR #3 via the GitHub API (`gh`
   is not installed in this environment, matching the WO-75 session's own
   note) and read `ClientSession.cs:34` directly to settle the Id-wrap
   question rather than trusting any doc's number.
3. Read `docs/WO-75-audit-findings.md` §1/§2/§5 and the PR #1 merge commit
   message (`git log -1 --format=%B 8e836c5`) for the exact root causes
   Phase 1 implements — no WO-A1 doc is committed to this repo, so its
   citations came from the WO-76 prompt itself, cross-checked against
   WO-75's independent record of the same four items.
4. Implemented and built Phase 1 item by item, running the relevant relay
   test suite after each before moving on. Discovered mid-session that a
   real, compilable MSVC + CMake + Ninja toolchain exists on this machine
   (VS Build Tools 2022, not on PATH — `vswhere.exe` needed the installer
   directory added to PATH first) and used it to compile-check the native
   `pipe_server.cpp` change rather than leaving it unverified.
5. Phase 2: located each of the six named stale assertions by content (the
   prompt's own line numbers were all stale — see findings §2), fixed each,
   syntax-checked every touched script, and fully ran the one suite that
   does not need a live game (`Test-PlayerCombat.ps1`), including a positive
   isolation test against a second relay occupying the default ports.
6. Phase 3: checked for a live game (process list, port 1403) before
   concluding it could not run; recorded that conclusion rather than
   guessing or running a synthetic substitute.
7. Phase 4: fixed the named current-state docs, checking each claim against
   source or a suite run this session before rewriting it; added the
   historical-doc pointer; left the three deferred items named only.
8. Wrote this document and `WO-76-findings.md`; pushed.

## Not done, deliberately

- Phase 3's data gathering — no live game available; not approximated.
- `Test-Pipe.ps1` and the five other live-game-dependent Phase 2 suites —
  not run, syntax-checked only.
- No NPC puppet rendering/jitter work — WO-77's scope, explicitly out of
  bounds here.
- No amendment of any doc beyond the ones named in the work order, beyond
  what those specific corrections required touching.
- No `VERSION` change.
- No history rewrite for the privacy-flagged field logs or
  username-carrying docs (WO-75 §6) — the maintainer's call, not repeated
  here since nothing new was found.

## Traps hit or re-confirmed

- The WO-76 prompt's own cited line numbers for the Phase 2 test fixes
  (`:312`, `:363`, `:24`, `:332-337`) were stale against the actual current
  files in every case but one (`Test-CombatVizE2E.ps1:24` matched) — the
  same kind of drift this whole session exists to fix. Every fix was
  located and verified by content, not by trusting the line number.
- `vswhere.exe` (used internally by `vcvars64.bat`) is not itself on PATH
  even from an elevated shell; `vcvars64.bat` fails opaquely
  ("'vswhere.exe' is not recognized") until
  `C:\Program Files (x86)\Microsoft Visual Studio\Installer` is added to
  PATH first.
- `git diff` on `ClientHandler.cs` after finishing Phase 1's three
  interleaved items showed genuinely separable hunks (by line-range, not by
  file) — worth remembering that "land as separate commits" does not
  require touching disjoint files, just disjoint hunks, and `git add
  <file>` against a hand-reconstructed intermediate working-tree state is a
  reliable way to get that without an interactive `git add -p`.
- Re-confirmed the WO-32/WO-58 trap already on record: a stale injected DLL
  or a running relay locks its own build output — not hit this session
  (nothing native or relay was left running across a rebuild), but checked
  for before every native build.
