# WO-99 — progress

Fix-first pass over the 2026-09-16 session (0.22.5). Findings in
`WO-99-findings.md`; channel changes in `WO-98-log-format.md`. Hands-off
session: no native calls, no live game, no DLL deploy. `KCDMP.dll`
source-unchanged. `VERSION` → `0.22.7` (pre-authorised for this session).

| Phase | Status |
|---|---|
| 0 `Dude` collision | **done** — `NpcDamageGuard`: local player excluded by PlayerSoul guid (name fallback), send+receive; echo guard (hit + fatal, 300 s); Lua exclusion extended with the live player name; every other name-keyed path audited (none collided); 12 xunit tests replaying the session's lines |
| 1 ghost gaps | **done** — classified: 426/490 gaps are the 2 s standing-still heartbeat, 57 are sender menu pauses, 9 are loading/fast-travel/sleep; 1 unmatched 2.0 s gap; **zero transport**; RTT unchanged from 2026-09-15; fix = stale-flagged 2 s heartbeat while the emitter is halted, counted on receipt |
| 2 sub-8 m yield | **done** — landed behind `mp_npc_yield_on/off` (default on), thresholds 0.30 m / 10 ticks / 1.0 m re-pin, `MP-NPCYIELD`, 39/39 MoonSharp |
| 3 death / reload | **done (explained)** — asymmetry = Phase 0; reload revival is a documented accepted limit (mod already clears its death marks); re-kill proven harmless (idempotent `apply_death`, agent dedupe, observer transitions only); no code |
| 4 instrumentation | **done** — `MP-CUTSCENE` absent because all 18 cutscenes were `Fader` (now logged, `acted=0`); `MP-SUMMARY` absent because no clean disconnect (now every 300 s too); swing `sid` on the wire (CombatEvent v2) |

## Verification

* `KcdMp.Client.Tests`: 101/101 (89 prior + 12 `NpcDamageGuardTests`).
* Lua under MoonSharp: `Test-WO99Synthetic` (new) 39/39; regressions
  `NpcSmooth` 48/48, `WO-90` 70/70, `WO-98` 50/50, `WO-86` 47/47, `WO-84`
  72/72.
* Solution builds (client, protocol, relay, launcher, master).
* **Not live-verified:** everything. The yield rule, the stale heartbeat
  and the swing id all need the two-machine A/B named in the findings'
  WO-99.5 list.

## Commits

`WO-99: Phase 0`, `Phase 1`, `Phase 2`, `Phase 4`, `rebuild kdcmp.pak`,
`docs`, `version 0.22.7`, `end gate`. Deploy is a matched set: pak + agent +
relay (CombatEvent v2 length; Position flag bit 0x02 is additive).

## Deviations

Recorded in `WO-99-findings.md` (Deviations, WO-99.5 addenda, WO-100
candidates). Summary: the prompt's Phase 0 `hp` semantics and Phase 1
transport premise corrected in place with evidence; Phase 3's reload gap
documented rather than extended; Fader/Text/SkipTime cutscene edges added
as log-only; swing id as an additive v2 length.

## End gate — 0.22.7 built from a fresh clone

Version `0.22.7` (maintainer pre-authorised for this session; Setup exe only,
no DirectInstall ZIP). `VERSION`, README badge and
`docs/releases/RELEASE-NOTES-0.22.7.md` committed and pushed first
(`079854d`); then a fresh `--depth 1` clone of `origin/main` at that commit
ran `tools\Build-Installer.ps1` (Publish-Release → pak rebuild → Inno Setup).

* `kdcmp.pak` rebuilt in the clone: 706,376 bytes (CRLF checkout; the
  working tree's LF build is 695,788 — line endings only, as in WO-97/98)
* `KCDMP.dll` rebuilt in the clone: 332,288 bytes, source-unchanged since
  0.22.4 (`git diff aab0a56 HEAD -- native` is empty)
* **`KCDMP-Setup-0.22.7.exe`, 100,493,607 bytes (95.8 MB)**,
  sha256 `a1849f2383db4576dce1f30afe0f12c3bc33535178ac1b728f16004bfdd69e3d`
* `KcdMpClient.dll` 772,096 bytes, `KcdMpServer.dll` 82,432 bytes
* copied to `release\KCDMP-Setup-0.22.7.exe` in the working tree (gitignored)
* **WO-98 privacy fix survived:** the clone's full publish output
  (`release\KCDMP`, **1,023 files** incl. subfolders) grepped for the build
  machine's profile path and the clone path in UTF-8 **and** UTF-16LE —
  **zero first-party hits**; the same six third-party NAudio DLLs carry their
  own author's `\Users\` path as in 0.22.5.

**What is in it:** all five phases (0, 1, 2, 4 as code; 3 as documentation).
No phase halted.

**Not verified here:** the installer was not run (sandbox AppData redirect;
Setup + `tools\Verify-Install.ps1` are the maintainer's step). Nothing in
0.22.7 is live-verified.

## Next session starts here

1. Two-machine run on 0.22.7. First reads: `MP-DMG dir=drop` / `result=refused`
   (should be the only `Dude` lines left), `[pos] mod emitter silent` vs the
   peer's `MP-GHOSTPKT … stale=`, `MP-NPCYIELD` beside `MP-NPCFIGHT`, and the
   periodic `MP-SUMMARY` blocks.
2. Yield A/B: `mp_npc_yield_off` for a minute in the same scene; if the
   stutter persists with it on, `#KCD2MP_SetNpcYield("0.10 10 1.0")`.
3. WO-99.5 native: refresh `g_player` per rescan, carry credit across rescans.
