# WO-45 progress

Worked 2026-08-23 (Fable 5), live, human at the machine. `docs/WO-45-findings.md`
is the deliverable; this is the session log.

## What was done, in order

1. **Step 0 — committed and pushed prior work first** (f526803): the staged,
   untested rung-2 construction code in `combat_construct.cpp` and the
   mirror-log change in `log.h`, with an honest "UNTESTED" commit message.
2. Read the full handoff: WO-44 findings/progress (incl. its correction),
   WO-43's correction section, WO-42 §4–§5.
3. (Power outage mid-session; state re-verified from scratch afterward.)
4. **Caught a silent deploy failure**: the running game had the old WO-44
   build loaded. Proof: loaded `ModuleMemorySize` `0x4E000` vs the rung-2
   build's PE `SizeOfImage` `0x50000`. The coding shell's `Copy-Item` into
   `%LocalAppData%\KCDMP` reports success (and a matching read-back hash!)
   but never reaches the real file — confirmed twice. Fix: the user ran the
   copy from their own shell, game closed, then relaunched. Loaded size then
   read `0x50000`.
5. **Mirror log confirmed working** — `kcdmp-native.mirror.log` in the game
   root, written by the DLL from inside the game process, readable live from
   the coding shell. First real-time native-log read path this project has had.
   Trigger-file writes from the coding shell reach the game (verified live,
   watcher fired) — the sandbox blocks the DLL copy but passes the text files.
6. **Phase 1** (probe Tests A→C per WO-44 §6.1): player probe + create, then
   ghosts `wo45a` and `wo45b` (fresh, never-reused ids, both validated
   healthy first). Every item clean; ghost vptr = `EntityModule.dll+0xE98340`
   (C_NPCActor family) — settles WO-44 §2 live. Gate 1 passed with zero
   faulting reads.
7. **Phase 2, isolated**: rung 2 fired on `wo45b` (male, real longsword from
   the `kkut_menhart` preset) with WO-43's real `FreeAttack` row. Engine
   parser resolved fragmentID 195 on the ghost's own animDB; ctor + QueueAction
   clean (status 0→1, refcount 2, controller took its reference). **Visual:
   nothing** — sword sheathed. Logged and kept as the isolated result.
8. **Phase 2, deliberate combination** (both halves individually confirmed
   first, per the session's one methodological rule): `DrawWeapon()` alone
   (sword out, no swing — re-confirming WO-43's correction), then the same
   rung-2 fire with sword in hand: **full, complete swing, returning to the
   drawn stance. Reproduced — two for two.** Gate 2: achieved.
9. **Phase 3 not attempted** — the brief gates it off once rung 2 completes a
   real swing.
10. Cleared the trigger file (watcher confirmed idle), `dotnet test` green
    (59/59 Farkle), findings + progress written, committed and pushed.

## Gates

- **Gate 1: pass.** Every reference the construction consumes resolves on a
  live ghost; nothing faulted (findings §1).
- **Gate 2: completes a real animation.** Complete swing, human-watched,
  twice, with per-step native logs — with the one extra precondition found
  this session: the weapon must be drawn (findings §2).
- **Gate 3: not reached, by design.**

## Not done, on purpose

- Phase 3 (`C_CombatActorActionAttack`/`SetAction`, attack-descriptor trace).
- `VERSION` untouched (docs/VERSIONING.md — user owns version strings).
- No stacking of untested calls: the DrawWeapon+rung2 combination ran only
  after each half was confirmed alone, as its own logged step.

## Handoff

Findings §6: rung 2 is the working primitive; next WO wires it into the
WO-39 combat-visibility stream (per-weapon-class fragment rows; DrawWeapon
state is already synced). Phase 3's two open questions stay open.
