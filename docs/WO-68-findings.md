# WO-68 — Native ghost civic isolation (script contexts)

Continues WO-65, which proved (live) that **no Lua-reachable script-context
setter exists on this build** and shipped the dialog half of ghost isolation.
This WO goes after the crime half natively.

Evidence discipline: **observed / code-verified / read-but-unrendered /
inconclusive**. "code-verified" below means read out of the decompilation of the
installed Modding Tools binaries — not inferred from vendor headers, and not
yet exercised at runtime.

Toolchain: Ghidra 12.1.3 headless (the WO-42 pipeline, `native/ghidra_scripts`).
The Ghidra install had been moved to the Recycle Bin between sessions; it was
copied back out to `C:\Users\Jonasty\ghidra_12.1.3_PUBLIC` (unchanged bits) so
this and future sessions have it. Analysed this session: `RPGModule.dll`
(18.2 MB), `WHGame.dll` (4.5 MB), `XGenAIModule.dll` (48.9 MB, analysed but not
needed in the end).

---

## 0. Executive result of Phase 0

The applier is **not** in RPGModule (where WO-65's string sweep pointed). It is
`wh::game::C_ScriptContextManager` in **`WHGame.dll`**, and it is *virtual*, so
it can be called through a vtable slot rather than a bare RVA:

| what | where | evidence |
|---|---|---|
| `C_ScriptContextManager::vftable` | WHGame RVA **0x32AAD0** | Ghidra RTTI label, referenced by the ctor (`LEA RAX,[0x18032aad0]` at `1800696f3`) |
| **SetEntityContext(bool value, WUID entity, const S_ScriptContextDatabaseNode\* ctx)** | vtable **slot [2] / +0x10** = RVA **0x6BE80** | raw file bytes at RVA 0x32AAE0 read back `80 BE 06 80 01 00 00 00` = 0x18006BE80 |
| **HasEntityContext(WUID entity, const S_ScriptContextDatabaseNode\* ctx) -> bool** | vtable **slot [7] / +0x38** = RVA **0x6C4A0** | raw file bytes at RVA 0x32AB08 = 0x18006C4A0; and this is the exact slot `C_ScriptBindSoul::HasScriptContext` calls (§1) |
| ScriptContext database | `(*(gameIface+0x168))->vtbl[0x138]()` | identical code in `C_ScriptBindSoul::HasScriptContext` (RPGModule 0x5EEEC0) and `C_ContextOperator<Add>::SetName` (RPGModule 0x879340) |
| context node by name | `db->vtbl[0xC8](db, const CryString&)` -> `const S_ScriptContextDatabaseNode*` (null = unknown name) | same two functions; failure paths log `Script context does not exist: %s` / `STORM: Script context %s doesn't exists` |
| ScriptContextPreset database | `(*(gameIface+0x168))->vtbl[0x140]()`, same `vtbl[0xC8]` by-name lookup | `C_ContextPresetOperator<Add/Remove>::SetName` (RPGModule 0x879570 / 0x879650) |
| manager instance | `X = *(gameIface+0x18)`; `Y = X->vtbl[0x118](X)`; `mgr = Y->vtbl[0x38](Y)` | `C_ScriptBindSoul::HasScriptContext` |
| entity key | **WUID, 64-bit**, read from `soul+0x40` | `C_ScriptBindSoul::HasScriptContext` passes `*(soul+0x40)` as the manager's entity argument |

`wh::GetGameIface()` is exported
(`?GetGameIface@wh@@YAPEBVC_GameInterface@shared@1@XZ`) and KCDMP.dll already
resolves and calls it (`combat_construct.cpp`).

Prologue bytes for the fail-closed check (read from the file, not from memory):

```
SetEntityContext  RVA 0x6BE80 : 48 89 5C 24 10 55 56 57 48 81 EC 90 00 00 00 48
HasEntityContext  RVA 0x6C4A0 : 48 89 5C 24 08 48 89 74 24 18 48 89 54 24 10 57
```

## 1. The read path, decompiled (`C_ScriptBindSoul::HasScriptContext`)

RPGModule `FUN_1805eeec0` (RVA **0x5EEEC0**), identified by its own
`__FUNCTION__` string `wh::rpgmodule::C_ScriptBindSoul::HasScriptContext`:

1. resolve `self` -> soul (`FUN_1805eacc0`: reads the Lua table field
   **`__ThisWUID`**, then resolves a soul from that WUID through a registry —
   so a WUID is what Lua identity ultimately is on this build);
2. `db = (*(gi+0x168))->vtbl[0x138]()`;
3. build a CryString from the `char*` argument;
4. `node = db->vtbl[0xC8](db, &cryString)`; null -> log
   `Script context does not exist: %s` and return **false**. This is why
   WO-65's bogus-name control also returned false: through this binding, a name
   the database does not know and a context that is not set are
   indistinguishable;
5. `mgr = ((*(gi+0x18))->vtbl[0x118]())->vtbl[0x38]()`;
6. `return mgr->vtbl[0x38](mgr, *(soul+0x40), node)`.

So the Lua readback WO-65 left in place reads **exactly** the store this WO
writes, through the same slot. `soul:HasScriptContext(name)` is therefore a
true independent verifier of a native `SetEntityContext`, not a proxy for one.

## 2. The write path, and the in-binary caller that proves the recipe

`C_ScriptContextManager::SetEntityContext` (WHGame `FUN_18006be80`) packages
`(this, value, wuid, node)` into a `std::function` and hands it to
`FUN_18006af60`, a re-entrancy queue: if the manager is already inside a change
(`this+0x1C0` busy flag) the change is queued and drained afterwards, otherwise
it runs immediately. No lock — **main-thread only**, which is the rule
KCDMP.dll already enforces via `main_thread::run_sync`.

The invocation recipe comes from a caller compiled into the shipped DLL:
`FUN_180071c90`, a unit test from
`code\game\whgame\Tests\ScriptCallbackTests.cpp` (the Modding Tools build ships
its tests — WO-42's `__FUNCTION__` property again). In order:

```c
FUN_1800696d0(mngr);                                        // C_ScriptContextManager ctor (0x2B0 bytes)
FUN_18006c4a0(mngr, 0x6700000001234567, &DAT_180419cf8);    // HasEntityContext(mockWuid1, ctx1) -> false
FUN_18006be80(mngr, 1, 0x6700000001234567, &DAT_180419cf8); // SetEntityContext(true, mockWuid1, ctx1)
FUN_18006c4a0(mngr, 0x6700000001234567, &DAT_180419cf8);    // -> true   (asserts "mngr.HasEntityContext(...)")
...
FUN_18006be80(mngr, 0, 0x6700000001234567, &DAT_180419cf8); // SetEntityContext(false, ...) -> Has -> false
```

Assert strings recovered verbatim from the binary give the real API names:
`mngr.HasEntityContext(mockWuid1, mockEntityContext1)`,
`mngr.HasGameContext(...)`, `mngr.HasRelationContext(wuid1, wuid2, ...)`,
`clbk1.ReadContextAdded()` / `ReadContextRemoved()`.

Code-verified consequences:

- **Argument order and types**: `(this=RCX, bool value=DL, uint64 wuid=R8,
  const node* = R9)`.
- **The entity need not pre-exist** in the manager: the test's manager is
  freshly constructed, and `Set` then `Has` works, so the outer map
  auto-inserts.
- **Removal is the same call with `value=false`** — so `mp_ghost_isolate off`
  can honestly remove contexts, unlike WO-65's placeholder semantics.
- Adds/removes fire `I_ContextChangeCallback` notifications, so systems that
  cache off context changes are told.

## 3. Store layout (from the manager's own debug dump)

`FUN_18006caf0` (the `wh_ai_ScriptContextDebug_*` renderer) shows the store as
`unordered_map<WUID, list<{const S_ScriptContextDatabaseNode* node, int count}>>`:

- outer map members: `this+0x48` (map), `this+0x50` (end sentinel),
  `this+0x60` (buckets), `this+0x78` (bucket mask); key hashed with FNV-1a over
  the 8 WUID bytes — the same hash open-coded in `HasEntityContext`;
- per-entity entries are **refcounted**: the dump prints `"%-20s x%d"` from
  `node->Name` and the count, so add/remove is balanced, not set-idempotent;
- `S_ScriptContextDatabaseNode`: **+0x00 name (`char*`)**, **+0x08 `int Class`**
  (`E_ContextClass`; `HasEntitySideEffect` rejects anything but **1 = Entity**,
  logging `Script context side effect %s used on %s context, expected Entity`).
  All seven isolation rows are `Class="Entity"` in
  `Tables.pak :: Libs/Tables/ai/ScriptContext.xml`, so 1 is the value to expect.

Bonus live cross-check that needs no code: three CVars registered by the
manager's ctor — `wh_ai_ScriptContextDebug_Who` (string, entity-name
autocomplete), `_Filter`, `_Global` (`Debug prints global contexts`) — render
`Script contexts for %s` plus each context name and refcount.

## 4. Sibling vtable slots (named far enough to avoid mis-calling)

```
[0] 0x6BDB0  SetGameContext(bool, node)                (bool + node, no wuid)
[1] 0x6C210  Set*GameContext wrapper (node**)
[2] 0x6BE80  SetEntityContext(bool, wuid, node)        <-- the target
[3] 0x6C280  wrapper: forwards to slot [2] with *param4 (S_EntityScriptContext holds the node)
[4] 0x6BF60  SetRelationContext(bool, wuid, wuid, node)
[5] 0x6C300  relation wrapper
[6] 0x6C3A0  HasGameContext
[7] 0x6C4A0  HasEntityContext(wuid, node)              <-- the readback
[8] 0x6C620  HasRelationContext
[15] 0x6B160 HasGameSideEffect   [16] 0x6B2B0 HasEntitySideEffect
[17] 0x6B400 HasRelationSideEffect
(vtable is 25 slots; past [24] the data is not pointers)
```

## 5. Preset vs. seven individual calls — decision

A preset applier exists (`ScriptContextPreset` database at `gi+0x168`
`vtbl[0x140]`, storm operators `C_ContextPresetOperator<Add/Remove>`, and
`switch_unresponsive` is a real row in `ScriptContextPreset.xml`), but nothing
resolves a preset to a *manager* call in one hop: the preset path is a second
database plus a second node type, and it still would not cover
`crime_disableReport`. **Seven individual `SetEntityContext` calls** — one code
path, one node type, per-context readback — is the decision. The preset route
is recorded as an option, not adopted.

## 6. What Storm does (context, and a data-only alternative worth knowing)

Contexts in shipped content are applied by **Storm** rules
(`IPL_GameData.pak :: Libs/Storm/contexts/*.xml`), e.g.

```xml
<rule name="contexts_frisk_crimeTest2">
  <selectors><hasName name="test_crime_merchant_6" /></selectors>
  <operations><addContext name="switch_disabledPickpocketReaction" /></operations>
</rule>
```

`C_ContextOperator<Add>::SetName` resolves the name to a node at parse time
(§0), and RPGModule's `Tests\StaticDataScriptContextsTests.cpp` bodies show the
static-data side is a plain `std::vector<const node*>` with "find, push_back if
absent" semantics.

So a **mod Storm rule** could add the seven contexts to souls matched by
`hasName` with no native code at all. Not adopted and not tested: a ghost's
soul is a *roster* soul (`SharedSoulGuid`, WO-22), so a name-matched rule would
isolate the shipped NPCs sharing those souls too, and Storm evaluation is
load-time static data rather than the runtime manager this WO writes. Recorded
as a real alternative for the human to weigh, not a silent pivot.

## 7. Phase 1 probe plan (gated on the human — not yet run)

Opt-in file probe, `kcdmp-contexts.txt` beside the DLL, same convention as
`kcdmp-combat.txt` / `kcdmp-playanim.txt`, with the same live re-read watch so a
target can be dropped in while the game runs. Every native call SEH-guarded,
prologue-checked against §0 before the first call, main-thread posted.

Stage A — read-only, proves the whole chain before any write:

1. resolve `gi`, contexts DB, manager; **assert `*(void**)mgr == WHGame+0x32AAD0`**;
2. look up `crime_disableReport` -> log node pointer, `node->Name` (must
   strcmp-equal the requested name) and `node->Class` (must be 1);
3. the player soul is already cached (`g_player` from `walk_to_soul`); read
   `*(uint64*)(g_player+0x40)` -> WUID, log it;
4. `HasEntityContext(wuid, node)` for **`UnconsciousHolsterInsteadDropWeapons`**
   — a context the shipped Storm rule
   `contexts_playerHolsterWeaponInsteadDropOnUnconsciousness` adds to
   `<isPlayer/>`, so **true** is the expected answer and is what proves the
   WUID offset and the manager instance are right — and for
   `crime_disableReport`, where **false** is expected.

Stage B — exactly one write, self-cleaning, on the **player** (whose soul
pointer needs no new resolution machinery):

5. `SetEntityContext(true, playerWuid, crime_disableReport)`;
6. `HasEntityContext` -> expect true; **Lua
   `player.soul:HasScriptContext('crime_disableReport')` -> expect true** (the
   WO's stated success signal, and §1 proves it reads the same slot);
7. `SetEntityContext(false, ...)` -> both readbacks false again.

A clean negative at step 4 (control context reads false) means the WUID offset
or the manager chain is wrong, and the recipe gets re-derived before any write.

## 8. Wiring decision for Phase 2 (stated per the WO's instruction)

**Pipe-driven native apply, not a Lua binding.** Reasons, by weight:

- `CryScriptSystem.dll` exports 49 symbols and **none** are the Lua C API
  (`lua_*` / `luaL_*`), so registering `Contexts.SetPersistentOption` would
  first require recovering `lua_State` / `lua_pushcclosure` by disassembly — a
  sub-project next to a feature that needs none of it. That is exactly the
  disproportionate case the WO's fallback clause describes.
- The identity the applier needs is a **WUID**, obtained natively; the Lua path
  does not shorten that.
- The pipe already carries the very identity needed: `0x04 SetFactionHostile`
  takes the ghost's own `Soul::Guid`, the agent already resolves it
  (`ResolveGhostSoulGuidAsync` -> `kcd2mp_<id>` -> `SoulsByName/.../Guid`), and
  the DLL already turns that guid into a soul pointer (`find_soul_by_guid`). So
  the new command is a mirror of an existing one, with no new resolution code.

Planned shape (not yet implemented): pipe `0x07 GhostIsolate [guid:16][on:1]`
-> `find_soul_by_guid` -> `soul+0x40` -> seven `SetEntityContext` calls with
per-context `HasEntityContext` readback -> `native_context_isolation_enabled`
cleared on the first SEH fault for the rest of the process. WO-65's Lua
`KCD2MP_ApplyGhostIsolation` keeps the dialog half and gains an emitted event so
the agent knows the `mp_ghost_isolate` state. No protocol, relay or
session-framework change.

## 9. Phase 1 — OBSERVED, live (2026-08-27)

Driven from the coding shell against the injected game, config in the game root.
Every line below is quoted from `kcdmp-native.log`.

Chain and integrity, identical across every run:

```
SCTX: ScriptContext DB = XGenAIModule.dll+0x2E43900
SCTX: manager vptr = WHGame.DLL+0x32AAD0 == C_ScriptContextManager::vftable OK
SCTX: slot[2] SetEntityContext = WHGame.DLL+0x6BE80 expected WHGame+0x6BE80 MATCH
SCTX: slot[7] HasEntityContext = WHGame.DLL+0x6C4A0 expected WHGame+0x6C4A0 MATCH
SCTX: both prologues match -- addresses verified for this build
```

Every Phase 0 hypothesis held. Note the database object itself lives in
**XGenAIModule**, reached through `gameIface+0x168` — consistent with
`S_EntityScriptContext` being an xgenaimodule type.

| check | result |
|---|---|
| node lookup, name + class | **OBSERVED** — `crime_disableReport -> node=... name="crime_disableReport" class=1 (name matches)` |
| bogus-name control | **OBSERVED** — `kcdmp_wo68_not_a_context -> node=null (database has no such row)` |
| player WUID at `soul+0x40` | **OBSERVED** — `0x0500000000000251` |
| **control read** (`UnconsciousHolsterInsteadDropWeapons`, player) | **OBSERVED true** — the single line that validates the manager instance and the WUID offset together |
| target read before any write | **OBSERVED false** |
| Stage B write, player | **OBSERVED** — `after-set ... = true`, then `after-unset ... = false`, no fault |
| ghost soul via `SoulsByGuid` | **OBSERVED** — soul resolved, WUID `0x05000000000005EB`, distinct from the player's |
| Stage B write, real ghost | **OBSERVED** — same false -> true -> false round trip |
| Lua vs. native agreement | **OBSERVED** — `player:UnconsciousHolsterInsteadDropWeapons = true  ghost:false`, `crime_disableReport = false` on both, matching the native reader on both the true and the false case |

The one thing Phase 1 could **not** observe: the Lua readback flipping *because
of our write*. The probe sets and unsets inside one main-thread callback, so no
window exists for an external reader. Deferred to Phase 3 rather than papered
over.

## 10. Phase 3 — the WO-34 repro FAILED with the seven, and why

Live, human at the keyboard. Round one applied KCD2Online's seven contexts to a
ghost; all seven verified set natively **and** read `true` from Lua
(`mp_probe_contexts`), while the player read `false` for all seven — so the
write was real, targeted, and still in force at the moment of the test
(re-checked after the punch: still 7/7 true).

**Result: the player punched the isolated ghost in front of a guard, was seen,
and was outlawed.** Same outcome as WO-65's un-isolated run. A verified write
that changes nothing about the defect.

The game's own AI data says why. `Scripts.pak ::
AI/npc/basic/switch/handleAwareness_hitVolume.xml` — the observer-side tree that
turns a witnessed hit into a crime — contains:

```xml
<EntityContextCheck context="crime_ignoredNPCHitVolume" target="$volumeData.target">
  <Then><Expression expressions="$ignore = true" /></Then>
</EntityContextCheck>
<RelationContextCheck context="crime_ignoreNPCHitVolume" from="$this.id" to="$volumeData.target">
<EntityContextCheck context="crime_ignoreNPCHitVolumes" target="$this.id">
```

`$volumeData.target` is the **victim**. The context that makes a witness ignore
a hit sits on the thing that was hit — and **no shipped tree checks
`crime_disableReport` against a victim at all**. `crime_disableReport` governs
whether an entity reports crimes *it* witnesses; a ghost being punched is not
the reporter. WO-34's "a ghost is a full crime victim" and KCD2Online's block
both conflate the two roles, and this WO inherited that conflation from WO-64.

Sweeping every `<EntityContextCheck>`/`<RelationContextCheck>` in the shipped
awareness trees gives the whole family and, for each, which entity it is checked
on:

| context | tree | checked on |
|---|---|---|
| `crime_ignoredNPCHitVolume` | `handleAwareness_hitVolume` | `$volumeData.target` (victim) |
| `crime_ignoredUnconsciousBody` | `handleAwareness_unconsciousBody`, `_bodyHolder`, `_bodyCarrier`, `_enemy` | `$body` / `$enemy` |
| `crime_ignoredCorpse` | `handleAwareness_corpse`, `_bodyCarrier`, `_animal_corpse` | `$corpse` / `$body` |
| `crime_ignoredPickpocket` | `handleAwareness_pickpocket` | `$stimulus.pivot` |
| `crime_ignoredAnimalHitVolume` | `handleAwareness_animal_hitVolume` | `$volumeData.target` (animals) |
| `crime_ignoredHorseTheft_Horse` | `handleAwareness_playerMount`, `_playerMountedVolume` | `$mount` |
| `crime_ignoredHorseTheft_NPC` | same | `$this.id` (**observer**) |
| `crime_ignoreNPCHitVolumes` | `handleAwareness_hitVolume` | `$this.id` (**observer**) |

So the applied set became **eleven**: the original seven plus the four
victim-side rows that apply to a human ghost. Excluded deliberately:
`crime_ignoredCombat` (a real `Class="Entity"` table row, but **no shipped tree
checks it** — no evidence it does anything), the two observer-side entries
(they would have to be applied to every witness, not the ghost), and the
Relation-class `crime_ignoreNPCHitVolume` (slot [4], one call per
observer/victim pair).

### Round two — OBSERVED PASS

```
SCTX: isolate crime_ignoredNPCHitVolume: set -> readback=true (applied-and-verified)
... (11 lines)
SCTX: isolate(on) wuid=0x05000000000005DD -- 11/11 in state (11 changed, 0 already, 0 unresolved, 0 did not take)
PIPE: GhostIsolate on=true -> all contexts in state
```

Human report, same save, same action, same guard: **"a guard noticed me punching
but did not arrest me for it."** No crime report, no fine, no outlaw state.

That is a two-point A/B rather than a single observation: seven contexts →
outlawed; eleven contexts → no crime. **WO-34 §1's crime-victim defect is
fixed.**

### Everything else observed in Phase 3

| observation | result |
|---|---|
| Lua readback after a native apply — the WO's stated success signal, and WO-65's gap | **OBSERVED** — all seven (later all eleven) read `true` on the ghost via `mp_probe_contexts`, `false` on the player |
| `mp_ghost_isolate off` | **OBSERVED** — `11/11 in state (11 changed)` clearing, and all read `false` from Lua. Real removal, not WO-65's placeholder |
| `mp_ghost_isolate on` again | **OBSERVED** — re-applied, all read `true` again |
| Toggle gating the spawn path | **OBSERVED** — a ghost spawned while the toggle was off produced **zero** isolate lines (agent skipped, Lua skipped) |
| Toggle re-resolving identity | **OBSERVED** — `on` after a respawn applied to WUID `0x…0622`, not the previous ghost's `0x…05DD`, so nothing stale is cached |
| Ghost fighting back | **OBSERVED — it does not.** `switch_disabledHitBehavioralReaction` suppresses WO-26's always-on reactive combat. WO-65's run had the ghost aggro; this one did not. That closes an open unknown from the session prompt |
| Guard notices an **un-isolated** ghost | **OBSERVED** (screenshot) — the control behaves normally |
| Guard walking *through* a ghost | **INCONCLUSIVE** — seen once, then not reproducible on demand. WO-32 §Collision already records ghosts having no collision as inherent to the `SetWorldPos` position stream, so this is very likely pre-existing rather than an isolation side effect, but this session did not establish it either way |
| Pickpocket / near-miss / perception secondaries | **NOT RUN** — the contexts are applied and read back, but no in-game attempt was made |
| Broken-then-vanishing ghost body | **OBSERVED once, pre-existing defect** — reproduced while spawning a ghost at the player's *exact* position (overlapping their capsule) rather than the usual 3 m offset. This is WO-16's "the ghost's visual model disappeared, nametag stayed floating", tracked separately. Recorded here only because the exact-position spawn is a possible deterministic trigger — one sample, not a diagnosis |

### `Test-Pipe` — run, PASS

Run with the agent detached (the DLL's pipe takes one client), which is also
why it had been skipped for two WOs:

```
target : ttkc_man_32  guid=20dd03e3-...  health=100
ping   : pong
result : applied
health : 100 -> 96   IsDead=false
PASS - a remote peer's damage reached the game
```

`tools\Probe-GhostIsolate.ps1` exercised pipe 0x07 in both directions with no
agent in the loop: `11/11 in state` off, then `11/11 in state` on.

## 11. Open unknowns (recorded, not rounded up)

- ~~Whether the crime system consults the side effect per report or caches it at
  init~~ — **settled by Phase 3**: contexts written at runtime take effect
  immediately, with no respawn or reload. The eleven-context ghost was isolated
  seconds before the punch and the crime path already honoured it.
- ~~Whether `switch_disabled*Reaction` is read per stimulus or latched at brain
  init~~ — **settled**: `switch_disabledHitBehavioralReaction` suppressed
  reactive combat on an already-spawned, already-brained ghost.
- Whether `crime_disableReport` does anything useful for a ghost at all. It is
  applied and verified, but nothing observed depends on it, and no shipped tree
  checks it against a victim. Kept because it is harmless and is the row whose
  `SideEffect="crimeDisableReport"` the manager's own
  `HasEntitySideEffect` path consumes — but its value here is **unevidenced**.
- Whether the observer-side rows (`crime_ignoreNPCHitVolumes`,
  `crime_ignoredHorseTheft_NPC`) or the Relation-class
  `crime_ignoreNPCHitVolume` would add anything. Untried: they need application
  to every witness, or per-pair, rather than once per ghost.
- Whether isolation removes a ghost from NPC pathing/avoidance (the
  walk-through observation above). Inconclusive.
- Whether the manager's per-entity store survives a save load (if not, the
  ghost respawn path re-applies anyway).
- `soul+0x40` is code-verified as *the value the readback uses*, not as "the
  soul's WUID field". The probe's control read is what settles that it is the
  right key for a soul we address by guid.
