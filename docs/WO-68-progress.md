# WO-68 — progress

## Session 1 (2026-08-27)

### Phase 0 — static disassembly: DONE, hypothesis sheet in `WO-68-findings.md`

- Ghidra 12.1.3 had been moved to the Recycle Bin since WO-44; recovered to
  `C:\Users\Jonasty\ghidra_12.1.3_PUBLIC` (byte copy, nothing else touched).
  JDK 21 was still installed. Imported and auto-analysed `RPGModule.dll`,
  `WHGame.dll`, `XGenAIModule.dll`.
- **The applier is not in RPGModule.** WO-65's `SetEntityScriptContext` string
  there turned out to be an rttr **test-command name** (registered alongside
  `SetPosition`, `SpawnEntity`, `combat_skirmish_AddSoul`), not the applier.
  The real surface is `wh::game::C_ScriptContextManager` in **`WHGame.dll`**
  (the 4.5 MB module WO-67 called a "stub" — it holds the whole script-context
  system).
- Recovered, all code-verified with the citing function recorded in the
  findings doc: the manager vftable (WHGame RVA 0x32AAD0),
  **`SetEntityContext` = vtable slot [2] / RVA 0x6BE80**,
  **`HasEntityContext` = slot [7] / RVA 0x6C4A0**, the context-database and
  preset-database accessors off `gameIface+0x168`, the by-name node lookup
  (`vtbl[0xC8]`, CryString), the manager-instance chain off `gameIface+0x18`,
  and the entity key: a **64-bit WUID at `soul+0x40`**.
- The argument recipe comes from a real in-binary caller — the shipped unit
  test from `game\whgame\Tests\ScriptCallbackTests.cpp` (WHGame 0x71C90), which
  calls `Set(true, wuid, node)` then asserts `Has(...)` is true, and `Set(false,
  ...)` then asserts false. So **removal is the same call with `value=false`**,
  and the entity does not have to pre-exist in the manager.
- `C_ScriptBindSoul::HasScriptContext` (RPGModule 0x5EEEC0) decompiled: it
  resolves the soul via the Lua table field `__ThisWUID`, looks up the node by
  name, and calls **the same slot [7]**. So WO-65's Lua readback verifies the
  exact store this WO writes — and it also explains WO-65's bogus-name control:
  an unknown name returns false through that binding, indistinguishable from
  "not set".
- Decisions recorded with reasons: **seven individual `SetEntityContext` calls**
  (not the preset path), and **pipe-driven wiring, not a Lua binding** —
  `CryScriptSystem.dll` exports no `lua_*`/`luaL_*` at all, so a Lua binding
  would mean reversing `lua_State`/`pushcclosure` first.
- Recorded but not pursued: a **data-only Storm rule** alternative
  (`Libs/Storm/contexts/*.xml`, `<addContext>` + `hasName`), which would also
  isolate the shipped NPCs that share a ghost's roster soul.
- Also found for free: `wh_ai_ScriptContextDebug_Who` / `_Filter` / `_Global`
  CVars that render an entity's contexts and refcounts — an independent live
  verifier that needs no code from us.

### Phase 1 — probe implemented, NOT RUN (gate: human at the keyboard)

`native/KCDMP/script_context.{h,cpp}` + `kcdmp-contexts.txt` opt-in (the
`kcdmp-combat.txt` convention), wired into `dllmain.cpp` at attach and on the
per-tick watch so a soul guid can be dropped in mid-session. Builds clean
(KCDMP.dll 312,832 bytes).

Config file:

```
player                 <- or  guid:<32 hex chars>   (a soul Guid, as pipe 0x04 uses)
read                   <- or  write
crime_disableReport    <- optional; this is the default
```

Fail-closed chain before any call: manager vptr must equal
`WHGame+0x32AAD0`; slots [2]/[7] must equal `WHGame+0x6BE80`/`+0x6C4A0`; both
prologues must match the bytes read out of the file. Node must carry the
requested name and `Class == 1` (Entity). A zero WUID stops the probe.
Everything SEH-guarded, everything posted to the main thread (the setter has no
lock, only a re-entrancy busy flag).

Stage A is read-only and includes two controls: the bogus name
`kcdmp_wo68_not_a_context` (expect `node=null`) and, for the player,
`UnconsciousHolsterInsteadDropWeapons` (a shipped Storm rule adds it to
`<isPlayer/>`, so **true** is expected — that single read is what validates the
manager instance and the `soul+0x40` offset). Stage B (`write`) sets exactly
one context, verifies, and **unsets it again** in the same run.

### Suites

Run against a real relay this session: **Sessions 22/22, Combat 14/14,
Dice 14/14, NpcClaimValidation 23/23, TimeSkipRelay 35/35, ItemSyncRelay
11/11 — all green.** `Test-Pipe` still outstanding: it needs the game injected,
which is the same thing Phase 1 needs.

### Next actions (cold start from here)

1. Human launches the game through the launcher (injected), loads a save.
2. Drop `kcdmp-contexts.txt` (`player` / `read`) beside the DLL, read the
   `SCTX:` block out of `kcdmp-native.log` (or the mirror in the game root).
   The control read is the go/no-go.
3. Flip line 2 to `write`, confirm `after-set` true + Lua
   `player.soul:HasScriptContext('crime_disableReport')` true, `after-unset`
   false.
4. Only then Phase 2: pipe `0x07 GhostIsolate [guid:16][on:1]`, seven contexts,
   `native_context_isolation_enabled` disable-on-first-fault, agent call at
   ghost-ready, `mp_ghost_isolate` gating both halves.
5. Phase 3: WO-34 repro (punch an isolated ghost in front of a guard) and
   `Test-Pipe`.
