# WO-49 progress

## Session 1 — 2026-08-24 (Fable 5)

1. **Label collision found first:** memory records a same-day session that
   used "WO-49" for the dice-payout `inventory:CreateItem` port. None of it
   is in this tree (kdcmp.lua:1301 still calls the broken
   `ItemUtils.AddMoneyToInventory`; no WO-49 commits/docs existed). Flagged
   in the findings; this WO-49 is the NPC-swing session per the user's brief.
2. Phase 1 (static): observer's puppet is the real local NPC → weapon
   resolved receiver-side, no wire change. Weapon read = the proven
   SoulsByName REST surface (whether world NPCs resolve by entity name is
   the one open probe; empty read degrades to the longsword constant).
   Trigger unchanged: bit 3 health-drop inference is still the only visible
   signal (WO-39/40). `human:GetItemInHand` exists in scriptbind docs but
   has no proven handle→class-GUID step — kept as backup route.
3. Phase 2 (staged): `npcid` emit at puppet start; agent strips bit 3 and
   routes it through the same `GhostSwingAsync` pipe path as ghost swings,
   with hold + fallback-to-Lua-cue mirroring WO-46's ladder; per-NPC catalog
   resolution incl. Oversized draw-through-`DrawFromInventory` (WO-47
   lesson applied to puppets) and Oversized-first row pick for consistency
   with the drawn item.
4. `tools/Test-NpcSwingE2E.ps1` written: one-human live gate (authority
   claim via agent restart, drawn heartbeats, 3 swing cues, auto-checks
   npcid/native-SWING/no-Lua-cue, human render verdict).
5. Suites: Farkle 59/59 PASS, Test-SwingCatalog PASS, build clean, pak
   rebuilt (-NoInstall — install is user-side, AppData is sandbox-redirected
   for this shell).
6. **Game was not running at commit time — live gate was PENDING** at
   20df3b7 (committed honestly as UNTESTED).
7. Joint-damage-on-shared-NPC flagged as out of scope for a future
   two-person session (findings, last section).

## Session 1 continued — live gate, same day

8. User deployed (Verify-Install ALL CHECKS PASSED) and ran
   Test-NpcSwingE2E.ps1: **run 1, 8/8 checks, real swing observed** — and a
   real regression: the NPC's unsuppressed brain re-holstered after two
   swings (cue 3 bare-handed). SoulsByName probe settled by direct REST
   query on the running game: world NPCs DO resolve by entity name
   (ttkc_man_1 → longswordOld, Type=4). Native log's slash→stab→slash
   rotation proved the catalog path ran (fallback is slash-only).
9. Fix: drawn-state re-assert in the puppet tick (1.5 s throttle, real
   IsWeaponDrawn vs streamed state, shared Oversized-aware mp_npc_draw).
   Injected into the RUNNING game via loadfile (WO-48 idiom) — no restart —
   and rebuilt into the pak.
10. **Run 2: 8/8, human-confirmed** — "he sheathed his sword but then
    grabbed it back out and swung"; kcd.log shows the re-assert fired
    twice. **LIVE GATE PASSED.** Committed and pushed.
11. Note for the user's next launch: run Build-And-Install-Mod.ps1 (without
    -NoInstall) so the installed pak picks up the re-assert fix — the
    running game has it only via the live patch.
