# WO-65 — Ghost civic isolation (script contexts)

Started 2026-08-27. Goal: stop a ghost from being a full vanilla crime victim
(WO-34 §1: real fines, jail, settlement rep loss; the `esFaction='Civilians'`
override is inert) by porting KCD2Online's script-context isolation block
(WO-64 Phase 1, source-read @`5777c15`, never live-observed there or here).

Evidence discipline: **observed / read-but-unrendered / inconclusive**, never
rounded up.

---

## Phase 0 — probe before feature

### Static evidence gathered before writing any code (all read-but-unrendered)

**The seven context names are real rows on OUR build.** All seven appear in
`Tables.pak :: Libs/Tables/ai/ScriptContext.xml`:

```
switch_disabledInformationReaction   (SideEffect="disableInformationReaction")
switch_disabledHearingReaction
switch_disabledPerceptionReaction
switch_disabledPickpocketReaction
switch_disabledNearMissReaction
switch_disabledHitBehavioralReaction
crime_disableReport                  (SideEffect="crimeDisableReport")
```

`Libs/Tables/ai/ScriptContextPreset.xml` even ships a preset,
`switch_unresponsive`, that is most of the isolation block in one name
(information/hit/hearing/perception/pickpocket + three crime_suppress
contexts). Nothing else in Tables.pak references these rows — the appliers
live in code/quest data, not in the tables.

**Three of the five calls exist on our build:**

| call | evidence |
|---|---|
| `soul:HasScriptContext(char*)` | Warhorse scriptbind docs page exists; string in `RPGModule.dll` (×2) and retail `WHGame.dll`; **called by shipped game Lua** (`Scripts/Entities/actor/BasicActor.lua:263`, `Scripts/Entities/WH/Triggers/TriggerBase.lua:423` in `Scripts.pak`) |
| `soul:RestrictDialog(bool)` | docs page exists; string in `DialogModule.dll` + `RPGModule.dll` |
| `human:InterruptDialogs()` | docs page exists; string in `DialogModule.dll` + `EntityModule.dll` |

The full documented `C_ScriptBindSoul` method list has **no**
`AddScriptContext`/`SetScriptContext` — reading contexts has a Lua surface,
writing them has no *documented* one.

**`Contexts.SetPersistentOption` was found NOWHERE statically:**

- not a string in any Modding Tools module DLL
  (`Bin/Win64ReleaseSteamLTO_DLL/*.dll`, all scanned)
- not a string in retail `WHGame.dll` / `WHGameArm.dll`
- not in any `.lua` in any game pak (all paks swept for `PersistentOption`)
- not defined by KCD2Online's own repo either: their
  `native_remote_avatar_backend.cpp:180` **runtime-probes**
  `GetFunctionPtrTableName("Contexts", "SetPersistentOption")` and silently
  skips the whole isolation step if absent. Their build is KCSE lineage;
  the symbol may exist only there, or nowhere.

Interesting string in `RPGModule.dll`: `SetEntityScriptContext` (near
`StaticDataScriptContext`, `E_ScriptContextSideEffect`) — an internal C++
entry point, no evidence of a Lua binding. Recorded, not used.

### `mp_probe_contexts` — shipped

Read-only console command (registered next to `mp_probe_stance`). Dumps:

1. `type(Contexts)` and, if a table, `type(Contexts.SetPersistentOption)`
   plus every key in it — this is the authoritative test the static sweep
   could not settle.
2. Every `_G` global whose name contains `ontext` (catches a renamed table).
3. On a live ghost (first in `KCD2MP.ghosts`) **and** on the player as a
   known-good control: `type()` of the three calls, every `soul`/`human` key
   whose name mentions Context/Option/Restrict/Dialog (candidate-setter
   enumeration — never guessing), and `HasScriptContext` for each of the
   seven names, pre-write.

Everything is pcall-wrapped and write-free. Run in-game:

```
mp_spawn_test        (if no ghost is up — the ghost half needs one)
mp_probe_contexts
```

then paste the `[KCD2-MP]` block from `kcd.log`.

**Status: probe shipped and pak rebuilt/installed; live output NOT yet
recorded. Phase 1 (the feature) is gated on that log by design.**

### Live probe output

*(pending — paste here)*

---

## Phase 1 — implement (NOT STARTED, gated on the Phase 0 log)

Plan, for the record:

- On ghost-ready (`KCD2MP_SpawnGhost`'s existing settle path — the same
  1500 ms soul-readiness window the name apply uses, plus an immediate
  attempt at spawn; all spawns funnel through `SpawnGhost`, including
  save-reload rebuilds and `mp_reconcile` recycling, so re-application on
  lifecycle edges comes free), when `mp_ghost_isolate` is on (default on):
  apply whatever setter the probe proves, tag `KCDMPGhost`, then
  `soul:RestrictDialog(true)`, then `human:InterruptDialogs()`.
- Every call pcall-wrapped; per-context readback via `HasScriptContext`
  logged as `applied-and-verified` / `applied-but-not-readable` /
  `missing-on-this-build`; a missing context never fails the spawn.
- Toggle semantics: `off` gates application at spawn; persistent options may
  not be removable at runtime — no fake removal.

## Phase 2 — live verification (NOT STARTED)

1. `mp_probe_contexts` before and after isolation.
2. WO-34 repro: punch the ghost in a guard's line of sight — expect no crime
   report, no fine, no guard reaction. Record either way.
3. Ghost no longer triggers pickpocket/near-miss/perception reactions; no
   dialog can be initiated with it.
4. `mp_ghost_isolate off` + respawn → vanilla (broken) behaviour returns.

---

## Version

`main` labelled **0.18.4** this session (user-chosen, no release/installer
published — `docs/VERSIONING.md`).
