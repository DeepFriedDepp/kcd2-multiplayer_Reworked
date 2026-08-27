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

## 9. Open unknowns (recorded, not rounded up)

- Whether the crime system consults `HasEntitySideEffect(crimeDisableReport)`
  **per report** (a runtime write then works) or caches it when a soul/brain
  initialises (a runtime write would not take). Every non-test caller reaches
  the manager through the vtable from another module, so static callers are not
  enumerable from WHGame alone. **The WO-34 live repro is the arbiter.**
- Whether the six `switch_disabled*Reaction` contexts are read by the brain per
  stimulus or latched at brain init — same question, different system.
- Whether the manager's per-entity store survives a save load (if not, the
  ghost respawn path re-applies anyway).
- `soul+0x40` is code-verified as *the value the readback uses*, not as "the
  soul's WUID field". The probe's control read is what settles that it is the
  right key for a soul we address by guid.
