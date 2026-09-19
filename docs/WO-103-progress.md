# WO-103 — progress

Session 2026-09-18. Findings: `docs/WO-103-findings.md`. Field runbook:
`docs/WO-103-field-runbook.md`. Builds on WO-102.5 (0.25.1, native NPC scan
+ uncapped co-located ownership shipped).

## Phases

| phase | state | evidence |
|---|---|---|
| 0 — measure what's replaced | **shipped**: `MP-NPCREAD path=lua\|native\|mixed n= mean_ms= p50_ms= p95_ms= max_ms= window_s=` (a Lua-side bucketed-histogram mirror of `CadenceStats.cs`'s scheme — Lua cannot call the C# class), `MP-NPCTRACK tracked= culled=` every 15s. **Baseline taken live, same day**: 300m default, `mean_ms=1.5 p50=1 p95=2` at 78-80 tracked, growing to `mean_ms=7.0 p95=15` at ~450 tracked — cost scales with tracked, confirmed | (code-verified); (synthetic) scenario `dd`; **(observed)** live field session, findings §5.1 |
| 1 — uncap the radius | **shipped**: upper clamp removed (floor 10m only), default 150→300m, `GameBridge.cs`'s mirror bumped to match. Reply truncation now logs loudly with a real dropped-count on both sides — fixing this also fixed a latent bug where a truncated scan under-reported its own `total_walked`/`vptrOk`/`nameRejects` (the loop used to `break` outright). A SECOND, self-found ceiling: the agent→Lua push (not the wire) would have exceeded the transport's 4000-char batching budget at the old 200-name cap once positions were added — cut to 40, with the arithmetic in a comment | (code-verified); wire header 14→18 bytes, agent<->DLL local pipe only; (synthetic) scenario `bb` updated (radius-clamp test rewritten, 4 new checks); radius escalation itself live-verified (see phase 3) |
| 2 — native position/yaw | **shipped behind `mp_npc_read_native_on` (on)**: the native scan already computed and wired x/y/z/yaw per entity (WO-102.5) — the entire gap was the agent discarding them before the push. Now pushed as `name:x:y:z:yaw:isHorse`; `KCD2MP_NpcSyncTick`'s read loop takes position from the push when fresh, else the SAME `e:GetWorldPos()` it always called (the entity is fetched regardless, for health/dead/KO/drawn/engaged — WO-103.5's job, unmapped). This is the answer to the cadence question: the fallback is free, so nothing stale ever ships and no cadence/second-call fix was needed. `mp_npc_read_compare` known-answer check fails the toggle closed on a genuine mismatch; re-enabling re-verifies immediately. **A real bug in the check itself found and fixed live same day**: the tolerance had no staleness cap, so an old push could always "match" — fixed (commit `b6634f4`) | (code-verified); (synthetic) scenario `dd`, 20 checks now; **(observed)** the substitution itself proven live via manual injection (findings §5.2) — but never observed via the agent's own automatic push, blocked by a stale-agent deployment issue, not this WO's code |
| 3 — find the ceiling | **PARTIALLY RUN, live, same day**: radius walked 300→600→1000→2000→5000m. Zero crashes at any radius. Tracked count 79→161→324→447→plateaus ~457 — the ceiling is the ENGINE's own NPC-streaming distance, not this mod's radius. Mod-tick `max` rose ~40ms→~62-63ms past ~300 tracked (avg unaffected) — a mild, occasional hitch, not a crash. The NATIVE-specific half (truncation ceiling, native vs Lua `dur_ms`) did NOT run — blocked by the same stale-agent issue as phase 2 | **(observed)** findings §5.1; runbook §2 |
| 4 — verification | synthetic 196/196 (was 169, +27, 0 regressed — 2 more added same day for the staleness-gate fix); every other Lua synthetic suite re-run green (48/35/33/72/47/70/101/32/160/50) + WO-99's durable "exits 2" quirk unchanged; agent unit tests 157/157 (was 156, +1); relay 13/13 unchanged (no wire change crosses it); native + full dotnet solution build clean | (observed) this session's own runs |
| end gate (0.26.0) | **built: `KCDMP-Setup-0.26.0.exe`** from a fresh clone of `origin main` at `e6ed0a2`; `rollback/0.25.1` tagged at `64b3f6b` (the last pre-WO-103 commit) before the bump | inside the clone: relay 13/13, agent 157/157, Lua synthetic 194/194; privacy sweep 1,024 files, one benign false positive (the same generic `myserver.duckdns.org` example string WO-102.5 already found and cleared, confirmed by reading its surrounding context again rather than assumed unchanged), zero real hits, `/PDBALTPATH` re-confirmed holding on both native binaries; pak byte-scanned for 8 of this session's own markers, all present incl. `authorityRadius = 300.0`; sha256 `1a92b62da10ae60bc85dabe526484b7ead630a8232b5594040193c6abd34a341`, 100,572,712 bytes |
| live field session | **run, same day** — see findings §5. First time ANY of this WO's code ran live. Phase 0 baseline and Phase 3 radius ladder both real results now; a real bug in `KCD2MP_NpcReadCompare` found and fixed; native scan never reached Lua due to a stale, hash-mismatched agent (`KcdMpClient.exe` dated 8/15, not this session's build) — an environmental/deployment finding, not a code defect, but blocking further native verification until a genuinely matched set is confirmed | (observed) findings §5 |
| end gate (0.26.1) | **built: `KCDMP-Setup-0.26.1.exe`** from a fresh clone of `origin main`; `rollback/0.26.0` tagged before the bump (below has the exact commit/hash) | see "End gate details (0.26.1)" below |

## Commits (`WO-103:` on `origin main`)

1. `WO-103 Phase 1: native reply-truncation accounting (dropped-match count)`
   — native (`npc_scan.h/.cpp`, `pipe_server.h/.cpp`) + `NpcScanCodec.cs` +
   its tests. Findings §1.2-1.3.
2. `WO-103 Phases 0-2: read-loop timing, uncapped radius, native
   position/yaw` — `kdcmp.lua` + `GameBridge.cs` together (they land in one
   commit because Phase 0's bracket and Phase 2's substitution touch the
   same tick function; splitting them would have meant an artificial
   mid-function commit boundary, not a real one). Findings §0-§2.
3. `WO-103: synthetic coverage for Phases 0-2 (scenario dd, bb radius fix)`
   — `tools/Test-WO102Synthetic.lua`. Findings §4.1.
4. Docs — this file, `docs/WO-103-findings.md`,
   `docs/WO-103-field-runbook.md`.
5. `WO-103: VERSION 0.26.0, README badge, release notes`.
6. End gate (0.26.0 built) — this progress doc update; `KCDMP-Setup-0.26.0.exe`.
7. Live field session (maintainer-driven, this session-connected) — findings
   §5; `WO-103: fix unbounded tolerance in the read known-answer check`
   (`b6634f4`) — the live-found staleness-gate bug, kdcmp.lua + 2 new
   synthetic checks.
8. `WO-103: VERSION 0.26.1, README badge, release notes`.
9. End gate (0.26.1 built) — this progress doc update; `KCDMP-Setup-0.26.1.exe`.

## End gate details

* **Fresh-clone build.** `git clone` of `origin/main` at `e6ed0a2` into a
  scratch directory (never the working tree). `native\Build-Native.ps1`
  (self-locates vcvars/cmake/ninja via `vswhere`) then
  `tools\Build-Installer.ps1` end-to-end: pak rebuild
  (`Build-And-Install-Mod.ps1 -NoInstall`), the relay round-trip gate, the
  agent unit tests, the Lua synthetic suite, `Publish-Release.ps1`, the
  install manifest, then Inno Setup. Re-ran all three gates independently
  inside the same clone afterward for a clean, ungarbled pass/fail read
  (the combined build log's tail was dominated by ISCC's own per-file
  compression output): relay 13/13, agent 157/157, Lua synthetic 194/194.
* **Privacy sweep, re-run rather than assumed** (the standing lesson from
  WO-102.5's own end gate, which found a real regression this way): every
  file under the fresh clone's `release\` output (1,024 files — same count
  as 0.25.1's own sweep, consistent payload composition) scanned for three
  real-identity needles (the build account name, the DDNS provider domain,
  the associated mailbox name — not printed here, by design) as both raw
  ASCII/UTF-8 and UTF-16LE. **One hit**: `KCDMP_launcher.dll`, UTF-16LE —
  read its surrounding bytes directly rather than trusting the file name
  alone, and it is the exact same generic `"...such as myserver.duckdns.org,
  or an IP address"` WO-55 input-validation string 0.25.1's own sweep
  already found and cleared. **Zero real hits.** Separately confirmed
  neither `KCDMP.dll` nor `KCDMP_LauncherInjector.exe` carries the build
  account's name in either encoding — `/PDBALTPATH` (`native/CMakeLists.txt`,
  the WO-102.5 fix) is still applying.
* **Pak verification**: opened the fresh clone's `kdcmp/Data/kdcmp.pak`
  (a standard zip) and extracted `Scripts/Startup/kdcmp.lua` directly rather
  than trusting the repo's own committed copy (WO-94's own caution — the
  shipped pak is not byte-deterministic and is not what git tracks).
  Checked for 8 markers unique to this session's own Lua changes
  (`MP-NPCREAD`, `KCD2MP_NpcReadCompare`, `mp_npc_read_native_on`,
  `WO103-READNATIVE`, `mp_npc_read_compare`, `NPC_READ_COMPARE_SPEED_MPS`,
  `MP-NPCTRACK`, `authorityRadius = 300.0`) — **all 8 present**.
* **Native payload confirmed**: `release\KCDMP\KCDMP.dll` inside the
  installer payload is 396,800 bytes, matching this session's own
  `native\Build-Native.ps1` output exactly (same source, same toolchain) —
  the Setup exe ships the DLL this session actually built, not a stale one.
* **Artifact**: `KCDMP-Setup-0.26.0.exe`, sha256
  `1a92b62da10ae60bc85dabe526484b7ead630a8232b5594040193c6abd34a341`,
  100,572,712 bytes. Copied from the scratch clone into the working tree's
  `release\` folder and re-hashed there — identical. `rollback/0.25.1`
  (tagged at `64b3f6b`, the last commit before any WO-103 change) pushed to
  `origin` ahead of this build.
* **Not done**: the installer itself was not run (AppData sandbox
  redirection — the maintainer runs Setup + `Verify-Install.ps1`, per
  standing session practice). Handed off, not self-verified end to end.
  Phase 3's radius ladder and Phase 0's A/B baseline (`docs/
  WO-103-field-runbook.md`) still have not run against a live game.
  **Superseded the same day** — the maintainer ran this exact build live;
  see the live field session row above and findings §5.

## Baseline before any change (observed this session)

* `cmake --build native/build --target KCDMP` (via `native/Build-Native.ps1`):
  green, 396,800 bytes, before any WO-103 change was reverted to check —
  confirmed the working tree built clean at the start via the SAME command
  after all changes landed (below), not compared against a pre-change
  artifact size (none was taken; WO-102.5's own baseline section didn't
  either).
* `dotnet test KcdMp.Client.Tests`: 157/157 post-change. `KcdMp.Relay.Tests`:
  13/13. (Pre-change baseline not separately captured — the repo was clean
  at session start per `git status`, and WO-102.5's own end-gate numbers
  — 156/156 agent, 13/13 relay — are the last known-good baseline this
  session built on.)
* `tools/Test-WO102Synthetic.ps1`: 169/169 pre-change (WO-102.5's own
  shipped count, confirmed by reading that session's progress doc, not
  re-run against the pre-change tree separately since the tree was already
  clean at 169/169 per WO-102.5's own end gate).

## Not done, and why

* **The native-specific half of Phase 3** (truncation ceiling, native vs
  Lua `dur_ms`) — blocked by the stale-agent deployment issue (findings
  §5.2), not attempted further this session. Needs a live re-run once a
  genuinely hash-confirmed matched set is running.
* **Native scan end-to-end, via the agent's own automatic push** — never
  observed. The read substitution itself IS live-proven (manual injection,
  findings §5.2), but whether the real agent can reliably push scan data at
  typical tracked counts (40+ names) remains unconfirmed — the "unfinished
  string" pattern observed this session is consistent with a
  transport-level truncation that could recur even on a matched, fresh
  agent, not just the stale one that was actually running. Genuinely open.
* **The agent-push chunking gap** (findings §1.4) — at high tracked counts,
  the 40-entry push cap means most tracked NPCs beyond the first 40 keep
  falling back to the live read. Correct and safe, but it means Phase 3's
  own ceiling-finding radii (where tracked counts are largest) are exactly
  where Phase 2's win shrinks the most. Not fixed this session; chunking
  the push across multiple `ExecuteString` calls is the stated follow-up —
  now with an added motivation if the transport-truncation theory (above)
  holds, since a smaller-but-more-frequent push would also reduce that risk.
* **The two-machine falsifiable condition** (WO-102.5's own runbook §4) —
  still not run, unrelated to this WO's own changes but unresolved from
  the prior session and worth restating so it isn't lost.
* **WO-103.5** (health/dead/KO/drawn/engaged natively) — deliberately not
  attempted; explicitly out of scope per the session prompt. The wire
  format is left exactly where WO-102.5 shipped it (`NpcEntry` unchanged in
  shape); that future session will need to grow the per-entry structure
  itself, a bigger wire change than either of this WO's two additions
  (a header-only growth, and an agent-local push format change that never
  touches the DLL<->agent wire).

## End gate details (0.26.1)

* **Fresh-clone build.** `git clone` of `origin/main` at `47c646f` into a
  new scratch directory (never the working tree, never reusing the 0.26.0
  clone). `native\Build-Native.ps1` then `tools\Build-Installer.ps1`
  end-to-end. Re-ran all three gates independently afterward: relay 13/13,
  agent 157/157, Lua synthetic 196/196 (up from 194 -- the 2 staleness-gate
  regression checks).
* **Privacy sweep**: 1,024 files under the fresh clone's `release\`, same
  one already-known benign hit (`KCDMP_launcher.dll`, the generic
  `myserver.duckdns.org` example string), zero real hits. Native binaries
  confirmed clean of the build account's name in both encodings --
  `/PDBALTPATH` still applying.
* **Pak verification**: extracted `Scripts/Startup/kdcmp.lua` from the
  fresh clone's `kdcmp/Data/kdcmp.pak` directly; confirmed not just the
  WO-103 markers but the SPECIFIC live-found fix -- `stale_after_s=%.1f`
  (the new format string) and the comment text naming the 2026-09-18 field
  session are both present, proving this pak carries the fix and isn't a
  stale rebuild of the pre-fix commit.
* **Native payload confirmed**: `KCDMP.dll` in the payload is 396,800
  bytes, identical to 0.26.0's (no native source changed between the two --
  this release is Lua-only).
* **Artifact**: `KCDMP-Setup-0.26.1.exe`, sha256
  `e3c5ab6e4b1e2a7881fdbe67f2a47f7789b96351899f9409cdf8e45ea68df5f1`,
  100,575,644 bytes. Copied into the working tree's `release\` and
  re-hashed there -- identical. `rollback/0.26.0` (tagged at `b6634f4`)
  pushed to `origin` ahead of this build.
* **For verifying the install actually replaces the stale agent this
  time**: this build's own `KcdMpClient.exe` hashes to
  `f2190583cf445f1cb544831bfc0b55efa779915f55499bf2ae3e0128aca2017c`. After
  installing, hash `%LOCALAPPDATA%\KCDMP\KcdMpClient.exe` and compare --
  a mismatch means the same install-while-running failure happened again
  (findings §5.2).
* **Not done**: the installer itself was not run from here (AppData
  sandbox redirection). Whether the transport-truncation theory for the
  native scan push (findings §5.2) holds even with a confirmed-fresh agent
  is still open -- needs a live re-test with the hash above confirmed
  matching first.

## Two more costumes for the standing trap

"A plausible result is not a result" (WO-96/97/99.5/100/100.5/101/102.5)
gained an eighth instance this session: `npc_scan.cpp`'s pre-WO-103
truncation `break` silently under-reported `total_walked`/`vptrOk`/
`nameRejects` for any truncated scan (the walk stopped early, so these
counters stopped incrementing early too) — a normal-looking number that was
quietly wrong. Found while fixing the NAMED gap (the missing dropped-count
itself), not independently sought. Findings §1.2.

A ninth, live-found the same day: `KCD2MP_NpcReadCompare` reporting
`verdict=match` was itself a plausible-looking result that was quietly
wrong — an unbounded age-scaled tolerance meant "match" proved nothing once
the compared entry was old enough. Findings §5.3.
