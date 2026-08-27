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

### Phase 1 — RAN, every hypothesis held

Player soul and a real ghost soul, both directions. Chain, vptr, both slot
RVAs, both prologues, node name + `class=1`, bogus-name control, the
`UnconsciousHolsterInsteadDropWeapons` control read (`true`), and a
false -> set -> true -> unset -> false round trip with no fault. Lua's
`HasScriptContext` agreed with the native reader on both the true and the false
case. Full quotes in the findings doc §9.

### Phase 2 — wired

- `apply_isolation(guid, on)` in `script_context.cpp`: fail-closed integrity
  gate, `SoulsByGuid` -> `soul+0x40` WUID, per-context read-before-write (the
  store is refcounted, so re-applying would strand a context at count 2),
  per-context readback logged, first fault disarms the feature for the process.
- Pipe `0x07 GhostIsolate [guid:16][on:1]`, mirroring `0x04`'s identity and
  marshalling.
- Agent fires it on the `ghostid` event (the ghost-ready edge, so respawn and
  post-reload rebuilds are covered), resolving the soul guid fresh each time.
- Lua `mp_ghost_isolate` emits an `isolate` event so one switch still gates both
  halves.
- `tools/Probe-GhostIsolate.ps1` drives 0x07 with no agent attached.

### Phase 3 — the seven FAILED the repro; eleven PASS

Round one: seven contexts applied, verified natively and in Lua, still set at
the moment of the test — **and the player was still outlawed for punching the
ghost in front of a guard.** Verified write, unchanged defect.

Cause, from the game's own AI data
(`Scripts.pak :: AI/npc/basic/switch/handleAwareness_hitVolume.xml`): the
observer-side tree checks **`crime_ignoredNPCHitVolume` on the victim**, and no
shipped tree checks `crime_disableReport` against a victim at all. WO-34 and
KCD2Online's block both conflated "reports crimes it sees" with "crimes against
it count". Swept every awareness tree for the family and added the four
victim-side rows (`crime_ignoredNPCHitVolume`, `crime_ignoredUnconsciousBody`,
`crime_ignoredCorpse`, `crime_ignoredPickpocket`); excluded
`crime_ignoredCombat` (no tree checks it) and the observer-side/Relation
variants (wrong entity for a one-call-per-ghost fix).

Round two, eleven contexts, same save and same action: **"a guard noticed me
punching but did not arrest me for it."** No report, no fine, no outlaw. Two-point
A/B, so WO-34 §1 is fixed.

Also observed: the ghost **does not fight back** (so
`switch_disabledHitBehavioralReaction` does suppress WO-26's reactive combat —
an open unknown closed); `off` really removes all eleven and `on` re-applies;
a ghost spawned while the toggle was off got **zero** isolate calls; `on` after a
respawn applied to the new WUID, not a cached one. Inconclusive: a guard walking
*through* a ghost, seen once and not reproducible. Not run: pickpocket/near-miss
in-game attempts.

The context list is now overridable by `kcdmp-isolation.txt` (game root or
beside the DLL, one name per line), added after three rebuild+reinstall+restart
cycles proved the list is the part that needs iterating.

### Suites

Final-tree run, all green: **Sessions 22/22, Combat 14/14, Dice 14/14,
NpcClaimValidation 23/23, TimeSkipRelay 35/35, ItemSyncRelay 11/11**, and
**`Test-Pipe`: PASS** (`health 100 -> 96`) — run with the agent detached, which
is the skip this WO was told not to repeat again.

One environmental trap found while doing it, worth knowing before someone reads
a red result as a regression: **`Test-Dice`'s two seed-determinism cases only
pass against a freshly started relay.** Run against a relay process that has
already served matches they fail with different scores each time
(`same seed -> same final scores -- A=750/0 B=1050/300`), because the expected
values assume the relay's RNG state at process start. A clean relay on the same
tree gave 14/14 immediately. Also: `--port` moves only the relay's TCP port;
its HTTP endpoint comes from `appsettings.json` (`Urls`, 5273) and needs
`--Urls` to move, which is what makes a second relay collide with a running one.

### Next actions (cold start from here)

1. The four secondary in-game checks nobody has made: pickpocket an isolated
   ghost, near-miss it, and see whether a witness reacts to its corpse or its
   unconscious body — those are exactly the three contexts added in round two
   whose effect is applied-and-verified but not behaviourally observed.
2. Settle the pathing question: does isolation take a ghost out of NPC
   avoidance? Compare an isolated and an un-isolated ghost with the same NPC
   walking the same line.
3. `crime_disableReport`'s value for a ghost is unevidenced — worth one probe
   with it removed from the list (now a text-file edit) to see if anything
   changes.
