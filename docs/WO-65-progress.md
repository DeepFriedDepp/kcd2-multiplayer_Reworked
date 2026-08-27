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

### Live probe output — OBSERVED 2026-08-27

Driven from the coding shell over `localhost:1403` ExecuteString with the
game running via Modding Tools, one `test_ghost` up (WO-43's channel).

```
[KCD2-MP] global Contexts type=nil
[KCD2-MP] ghost[test_ghost]: soul=table human=table
[KCD2-MP] ghost[test_ghost].soul.HasScriptContext : function
[KCD2-MP] ghost[test_ghost].soul.RestrictDialog   : function
[KCD2-MP] ghost[test_ghost].soul.IsDialogRestricted : function
[KCD2-MP] ghost[test_ghost].human.InterruptDialogs : function
[KCD2-MP] ghost[test_ghost] HasScriptContext('<each of the 7>') ok=true -> false
[KCD2-MP] player: (identical -- all functions, all 7 read false)
```

Caveat discovered: scriptbind methods live behind a metatable, so the
`pairs()` candidate-setter enumeration in the probe sees nothing — absence
of enumerated keys is NOT evidence. Follow-up probes (type() lookups, which
do traverse `__index`) settled it:

```
soul.AddScriptContext / RemoveScriptContext / SetScriptContext /
  AddScriptContextPreset / SetPersistentOption / SetEntityScriptContext /
  AddContext : all nil
globals SetEntityScriptContext / ScriptContext / ScriptContexts : nil
AI / Game / XGenAIModule / System / Script scans for *ontext*/*ersistent*:
  only AI.SetMovementContext + AI.ClearMovementContext (locomotion, unrelated)
System.ExecuteCommand('SetEntityScriptContext') -> "Unknown command"
bogus-name control: HasScriptContext('kcdmp_bogus_context_xyz') ok=true -> false
  (so false cannot distinguish "not set" from "unknown name"; the seven
   names are confirmed real by the Tables.pak rows instead)
```

Meta-role avenue checked and closed: `Libs/Tables/rpg/metarole.xml` roles are
dialogue/voice-line tags (`COMPANION_KOMENTUJE_CRIME_*`), not context
appliers.

**VERDICT (observed): our build has NO Lua-reachable script-context setter.**
`Contexts.SetPersistentOption` is a KCSE-lineage surface we don't have. The
crime-report half of KCD2Online's isolation block is native-only here — a
finding, not a failure. The reachable subset is the dialog half:

```
[WO65] before IsDialogRestricted=false
[WO65] RestrictDialog(true) ok=true err=nil
[WO65] after IsDialogRestricted=true          <- REAL WRITE, observed
[WO65] InterruptDialogs() ok=true err=nil
```

---

## Phase 1 — implemented (same day, after the probe log)

`KCD2MP_ApplyGhostIsolation(id, stage)` + `mp_ghost_isolate on|off`
(default **on**, `KCD2MP.ghostIsolate`):

- Called directly in `KCD2MP_SpawnGhost` (spawn path, NOT a timer — menus
  suspend `Script.SetTimer`, reload kills timers) and re-asserted from the
  existing 1500 ms name-settle timer in case the soul wasn't ready at
  spawn+0 (`ghost.isolated` dedupes). All respawn paths funnel through
  `SpawnGhost`, so save-load re-application comes free.
- Context half: generic setter hook — if a future patch ships
  `Contexts.SetPersistentOption` (tag `KCDMPGhost`) it lights up with
  per-context `HasScriptContext` readback; today every context logs
  `missing-on-this-build` and the spawn continues.
- Dialog half: `RestrictDialog(true)` with `IsDialogRestricted` readback,
  then `InterruptDialogs()`. Everything pcall-wrapped.
- Toggle: `off` gates future spawns AND takes the clean removal that exists
  (`RestrictDialog(false)`, readback verified); no fake removal of context
  options is pretended.

## Phase 2 — live verification

Run via ExecuteString against the running game, 2026-08-27:

| check | result |
|---|---|
| Full apply pass on a live ghost | **OBSERVED** — 7× `missing-on-this-build`, `RestrictDialog(true): ok=true readback=true (applied-and-verified)`, `InterruptDialogs(): ok=true` |
| `mp_ghost_isolate off` clean removal | **OBSERVED** — `RestrictDialog(false): readback=false`, `ghostIsolate=false (touched 1 live ghosts)` |
| `mp_ghost_isolate on` re-apply | **OBSERVED** — full pass re-ran, readback=true |
| Whole edited kdcmp.lua compiles | **OBSERVED** — in-game `loadfile` compile-only check, `compiled=true` (WO-13's trick) |
| Spawn-path integration (Isolate lines firing from a real `SpawnGhost` call) | **OBSERVED** — after the 0.18.4 pak install + restart, `mp_spawn_test` produced the full Isolate block unprompted, `ghostIsolate default=true`, RestrictDialog applied-and-verified at spawn+0 (soul was ready immediately), settle pass correctly deduped (no duplicate block) |
| `mp_probe_contexts` before AND after isolation | **OBSERVED** — identical: `Contexts` nil both times; all seven contexts read `false` after isolation too, consistent with nothing having set them |
| "No dialog can be initiated with the ghost" (human at keyboard) | **OBSERVED** — the user walked up and tried to talk: no dialog can be started with the isolated ghost. The dialog half works in the real UI, not just in readback |
| WO-34 crime repro (punch ghost before a guard) | **OBSERVED, STILL BROKEN as predicted** — the user punched the test ghost with witnesses around: the ghost aggroed (WO-26's always-on reactive combat, expected), everyone nearby noticed, the user was outlawed and killed. The crime-victim defect stands until the native follow-up; no regression from isolation |
| Pickpocket/near-miss/perception secondary checks | **NOT RUN — cannot pass**: those reactions are exactly the contexts that cannot be set on this build |

Injection-environment note (not a shipped-code bug): `mp_log` is a
file-local in the pak, so the hand-injected section needed a global shim;
and the injected run needed `KCD2MP.ghostIsolate=true` set by hand because
the running pak predated the default. Neither applies to the built pak,
where the section compiles inside the same file.

## What would actually fix the crime problem — native follow-up (proposed)

`RPGModule.dll` carries `SetEntityScriptContext` / `StaticDataScriptContext`
/ `E_ScriptContextSideEffect` internals. A KCDMP.dll call into that layer
(WO-42/44-style disassembly to pin the function, then apply the seven
contexts on ghost-ready) is the real port of KCD2Online's block. Out of
WO-65's Lua-only scope by design — flagged per instruction 5, not touched.

---

## Suites

Run 2026-08-27 against a real relay: **Sessions 22/22, Combat 14/14,
Dice 14/14 — green.** `Test-Pipe` NOT run this session: it requires
KCDMP.dll injected (launcher flow); the game was launched bare via Modding
Tools for the probe work, and WO-65 touches no pipe path.

## Version

`main` labelled **0.18.4** this session (user-chosen, no release/installer
published — `docs/VERSIONING.md`).

## Definition-of-done ledger

- `mp_probe_contexts` shipped, live output recorded above — DONE
- isolation on ghost-ready behind `mp_ghost_isolate` (default on), all
  pcall-wrapped, per-context verification logging — DONE (dialog half is
  what this build allows; contexts log `missing-on-this-build`)
- WO-34 repro executed, observed result recorded honestly — DONE (still
  broken, as the missing setter predicts)
- no engine/protocol/relay/session-framework changes — HELD
- suites — 3 of 4 green, Test-Pipe not run (reason above)
- next session starts cold from this doc + the WO-65 prompt; the open
  thread is the **native follow-up**: pin RPGModule's
  `SetEntityScriptContext`/context-applier and call it from KCDMP.dll on
  ghost-ready — that is the actual crime fix
