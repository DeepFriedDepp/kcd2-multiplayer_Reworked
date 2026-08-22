# WO-44 progress

Worked 2026-08-22 (Fable 5). Phase 2 of the combat-swing-fidelity work
(WO-42 reverse-engineering → WO-43 live-tested rung 1 → this: decompile the
rung-1 target, decide direction A vs B). `docs/WO-44-findings.md` is the
deliverable; this is the session log.

**⚠ Correction added same day, by a live-testing follow-up session:** this
WO's own premise — that WO-43 observed a real partial-swing render from
`vtbl[+0xE48]` — was wrong. A follow-up session ran this WO's own
`combat_construct.cpp`/`combat_playanim.cpp` probes (adding a live-reload
watcher to each) against real ghosts and found the guard
(`actor[+0x28]->vtbl[0x80]()`) blocks on every ghost tested — `vtbl[+0xE48]`
never runs for a ghost at all. The pose WO-43 attributed to it was
`DrawWeapon()`'s own stance. §1's decompilation of `C_Player::PlayAnim`
remains accurate (confirmed live for the player, whose guard passes); §2's
class-dispatch finding remains accurate and was independently live-confirmed
the same follow-up session. The direction-B recommendation is unaffected.
Full correction in `docs/WO-44-findings.md`'s own correction section.

## What was done, in order

1. Read the full handoff: `docs/WO-43-findings.md` (§4-5 live evidence, §9
   handoff), `docs/WO-42-findings.md` (§4-5 construction sequences, §9.5/§9.6
   the traced-but-unread `vtbl+0xE48` target and `GetOrCreateCombatActor`),
   `docs/WO-42-progress.md`, `docs/WO-43-progress.md`.
2. Confirmed WO-42's three Ghidra projects survived in the prior session's
   scratchpad (`gproj`=AnimationModule, `gproj2`=CombatModule,
   `gproj3`=EntityModule) — reused as-is, no re-import. Ghidra 12.1.3 + JDK 21
   still installed at WO-42's paths.
3. **Decompiled `EntityModule.dll+0xAE17A0`** (the WO-43 target) via the WO-42
   pipeline. Result: it is `C_Player::PlayAnim`, and it builds a **bare 0x90
   `TAction<SAnimationContext>`** (RTTI-labelled ctor `0x121300`, field-for-field
   the same base ctor WO-42 §3 documented) and queues it through
   `IActionController::Queue` (+0x98). **No combat machinery whatsoever.**
4. Confirmed the class-dispatch subtlety WO-42 §9.6 / WO-43 left open:
   `0xAE17A0` is `C_Player::vftable` slot [457]/+0xE48 and sits in **no other
   vtable** (the four other refs are `.pdata` EH triples — the README's trap,
   verified). `C_Human`'s primary vtable is shorter (~431 slots), so +0xE48 is
   C_Player-specific. So `human:PlayAnim`'s hard-coded +0xE48 is calibrated for
   C_Player; what rendered on WO-43's ghosts is a C_Player-layout actor or a
   class-sibling bare-fragment player — a live-checkable point, not settled.
5. Re-verified direction B's entry points against the installed binaries:
   `GetOrCreateCombatActor` (EntityModule `0x92260`, `m_pCombatActor` at +0x300),
   `C_CombatAnimAction` ctor (CombatModule `0xF26F0`),
   `C_CombatAnimActionManager::QueueAction` (CombatModule `0xF3C00`). All match
   WO-42.
6. Wrote `native/ghidra_scripts/DumpWo44Owner.java` (raw slot address → owning
   vftable + byte offset) — what identified the C_Player slot and unmasked the
   `.pdata` false refs.
7. Built the direction-B **precondition probe** `native/KCDMP/combat_construct.cpp`
   (`probe_combat_construct`): resolves the ghost's `C_Actor` → `I_CombatActor*`,
   logs the actor vptr (vs C_Player), combat-capability, the combat actor
   (raw read, or `GetOrCreateCombatActor` in `create` mode), and the
   manager/director/state/opponent offsets rung 2/3 consume — with a round-trip
   assertion. Constructs and queues nothing. Gated by `kcdmp-combat.txt`
   (opt-in, same convention as `kcdmp-faction.txt`/`kcdmp-playanim.txt`).
   Wired into `dllmain.cpp` and `CMakeLists.txt`.
8. `native/Build-Native.ps1` (Release): clean, `KCDMP.dll` 289,280 bytes, zero
   errors, zero new warnings.

## Gate: direction A vs B

**A is closed by decompilation.** Rung 1 (`PlayAnim`/`vtbl+0xE48`) is a generic
single-fragment player that builds a bare `TAction` — it cannot complete a
combat swing, and there is no branch to enable that would change that. Not
salvageable with a precondition. This *explains* WO-43's three-times-reproduced
partial swing: a bare `TAction` gets the fragment's entry playing but nothing
drives the combat transitions to completion (jumps work because they're
self-terminating; attacks aren't).

**B is the path.** Its entry points are re-verified. The full rung-2 (build a
`C_CombatAnimAction`, queue via the actor's `C_CombatAnimActionManager` at
`I_CombatActor+0x490`) and rung-3 (construct a `C_CombatActorActionAttack`, hand
to the actor's `C_ActionDirector` via `SetAction`) construction sequences are
specified in `docs/WO-44-findings.md` §5, with the one open runtime unknown
called out (a loaded attack-descriptor pointer, for rung 3).

## Not done, on purpose

- No construction/queue code — direction B's actual build is staged for the next
  session, gated on the probe first confirming the inputs resolve on a live
  ghost. Building an un-testable, crash-risky queue path this session (no game
  access here) would be worse than a staged, safe probe + a complete written
  spec. See findings §5-6.
- Game never launched; nothing live-verified this session (same constraint as
  WO-42/WO-43 when working away from the machine).
- `VERSION` untouched (no release; ask the user for the exact string before any
  bump — `docs/VERSIONING.md`).

## Handoff

Next session (human at the machine): run the §6.1 run sheet (probe Tests A→C),
then implement rung 2, then rung 3 if needed. `docs/WO-44-findings.md` §9 has
the ordered plan. The probe's outcome→verdict table maps each `kcd.log` line to
a decision.
