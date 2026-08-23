# WO-45 — the first real, complete combat swing on a ghost. Rung 2 works.

Worked 2026-08-23 (Fable 5), live, with the human at the machine. This session
verified WO-44's precondition map on a live ghost (Phase 1), then implemented
and fired the rung-2 construction — build a real `C_CombatAnimAction` with the
game's own constructor and hand it to the actor's own
`C_CombatAnimActionManager` — and **it produced a real, complete, visually
confirmed longsword swing on a ghost, reproduced twice**. Phase 3 (the
`C_CombatActorActionAttack` / `SetAction` route) was deliberately not attempted,
per the session brief's own gate: rung 2 completing a real swing means stop.

**Evidence classes, as elsewhere in this project:** observed-live (a human
watched it happen, or the native log recorded it from inside the game process) /
read-but-unrendered / inferred, labelled. Every rung-2 claim below is
observed-live on ghost `wo45b` (entity id 526457, this session's save), with
the native log lines quoted.

---

## 0. Verdict

**A ghost can be made to perform a real, complete combat swing.** The recipe,
end to end, all of it the game's own machinery:

1. `GetOrCreateCombatActor(actor)` (EntityModule `0x92260`) — creates the
   ghost's `I_CombatActor` (a fresh ghost has none).
2. `ParseFragmentSpec` (AnimationModule `0x12DB00`) on a real shipped row —
   `"FreeAttack, l_longsword+r_longsword+freeGuard+endFreeGuard+slash+attack_heavy"`
   (WO-43 test 3's row from `combat_action_attack.xml`) — resolved against the
   ghost's own animation database: fragmentID **195**, real 20-byte TagState.
3. Allocate `0x1A8` with CombatModule's own allocator, construct with the
   `C_CombatAnimAction` ctor (CombatModule `0xF26F0`), priority 5, flags 0.
4. AddRef (QueueAction consumes one reference).
5. `C_CombatAnimActionManager::QueueAction` (CombatModule `0xF3C00`), manager
   from `I_CombatActor+0x490`, time `-1.0f` **in XMM2**.
6. **The one extra precondition, found this session: the weapon must be
   drawn.** With the sword sheathed the identical queue succeeds silently and
   renders nothing; with `human:DrawWeapon()` done first, the same queue
   renders a full swing.

Observed-live, twice, same ghost: *"He swung his sword and returned to his
sword drawn position"* — *"Exact same thing, swung his sword and returned to
his position."* No crash, no fault, game healthy afterward.

WO-44 §5's stated uncertainty for rung 2 — that without `EnterImpl`'s combat
pre-roll and without the lifecycle delegates the swing might still not
complete — is **resolved: it completes anyway**, at least for an unpaired
`FreeAttack`. No pre-roll, no delegates, no attack descriptor, no opponent —
the action controller runs the fragment to completion and returns the
character to his stance on its own.

---

## 1. Phase 1 — the precondition probe on live subjects (Gate 1: all clean)

Method: the WO-44 §6.1 run sheet, driven entirely from the coding shell —
trigger file `kcdmp-combat.txt` beside the deployed DLL (writes from this
shell **do** reach the game; §4), probe re-fired live by the WO-43-era
watcher, results read from the new mirror log (§4). Every ghost spawned under
a fresh, never-used id (`wo45a`, `wo45b`).

**Test A — player, probe (read-only), and Test B — player, create:**

| item | result |
|---|---|
| actor vptr | `EntityModule.dll+0xE96F78` — **IS `C_Player::vftable`** |
| `GetName()` | `"Dude"` |
| `vtbl[0x988]` combat-capable | 1 |
| `actor+0x300` m_pCombatActor | already non-null (so `create` mode never had to call `GetOrCreateCombatActor` on the player — the raw read short-circuits it) |
| `+0x2D8` owning-entity round-trip | **MATCH** |
| `+0x2E0` director / `+0x490` manager / `+0x2F0` state | all non-null |
| `state+0x1118` opponent | null (not in combat — expected) |

**Test C — ghost `wo45a`** (female, `prepadeni_woman_1`, fresh id, validated:
`human` binding present, `GetAnimationLength(0,"relaxed_jump_start")` = 0.567):

| item | result |
|---|---|
| actor vptr | `EntityModule.dll+0xE98340` — **NOT C_Player; this is the `C_NPCActor` primary vtable WO-44 §2 identified statically** |
| `GetName()` | `"kcd2mp_wo45a"` |
| combat-capable | **1** |
| m_pCombatActor raw | **null** (never fought) → `GetOrCreateCombatActor` returned non-null |
| round-trip / director / manager / state | all clean, MATCH |
| opponent | null |

Repeated identically on `wo45b` (male, `tpod_man_5`, id 526457, the rung-2
subject): same vptr `0xE98340`, combat-capable 1, combat actor created clean,
every offset resolves, opponent null. **No probe read or call faulted on any
subject.**

**This settles WO-44 §2's open question:** a ghost is a `C_NPCActor`-family
actor (vptr `0xE98340`, two ghosts, matching the correction session's two),
*not* a `C_Player`-layout actor. The player is the only `C_Player`. And per
WO-43's correction, that difference never mattered for `+0xE48` — the guard
blocks a ghost one step earlier regardless.

**Gate 1: every reference the construction route consumes resolves cleanly on
a real ghost. Proceed.**

---

## 2. Phase 2 — rung 2, isolated first, then the deliberate combination

The construction code (`combat_construct.cpp` mode `rung2`, staged and
committed at the start of this session) adds: engine-parser fragment
resolution, module-allocator + ctor construction, refcount discipline, and the
manager queue — every RVA prologue-checked before the first call (all three
matched this build), every call SEH-isolated, every step logged.

### 2.1 Isolated (the one methodological rule): rung 2 alone, sword sheathed

Fired twice (11:31:47, 11:32:50), user watching the second time:

```
COMBAT: rung2 parsed fragment="FreeAttack" fragmentID=195
COMBAT: rung2 tagsB(+0x20) = 00 00 00 00 00 00 11 00 32 01 00 ... (feeds the ctor)
COMBAT: rung2 constructed C_CombatAnimAction 0000013283CD1A30: status(+0x28)=0 refcount(+0x58)=0
COMBAT: rung2 QueueAction returned. status(+0x28)=1 refcount(+0x58)=2
```

- The ghost's own animDB **knows the combat fragment** (id 195, not −1) —
  resolved through the live `GetGameIface → +0x08 → vtbl[0xB0] → vtbl[0x18] →
  vtbl[0x20](actorClass+0x28)` chain, exactly as `C_PlayAnim::Execute` does.
- `QueueAction`'s status gate passed; post-queue **status 1** (pending in the
  controller) and **refcount 2** (the controller took its own reference — the
  queue genuinely accepted the action, it was not dropped on the floor).
- **Visual result: nothing.** Ghost stood unchanged, sword sheathed
  (screenshot in the session). No crash; REST endpoint and log healthy.

So the isolated result on its own: *queues cleanly, renders nothing.* Logged
state and visual impression separated, as the brief demanded.

### 2.2 The deliberate combination: DrawWeapon first, then the same queue

Both halves individually confirmed (DrawWeapon alone: WO-43's correction
session, and re-confirmed alone here — sword out, held low, no swing; rung-2
queue alone: §2.1). Then combined as its own logged step:

- 11:34: `human:DrawWeapon()` alone on `wo45b` → sword drawn, standing at
  rest (screenshot in the session).
- 11:35:11: same rung-2 fire, byte-identical spec → **full swing, visually
  complete, returns to the drawn stance** (user watching).
- 11:35:49: fired again → **identical full swing, second confirmation.**

Native log for both fires is byte-for-byte the same shape as §2.1's
(fragmentID 195, status 0→1, refcount 2). **The only variable that changed
between "nothing" and "complete swing" is the drawn weapon.**

### 2.3 Reading (labelled inferred)

The `l_longsword`/`r_longsword` tags select fragment options whose clips live
on the weapon scopes; with the sword sheathed the resolved option set is
empty-or-inert, so the action installs and finishes invisibly. With the sword
in hand the same option resolves to the real swing clips. Consistent with all
four observations (2× sheathed nothing, 2× drawn swing); not separately
instrumented (the queued action's later status transitions were not re-read —
a `status`-tracking log line would need a DLL rebuild and another
relaunch cycle, not worth it once the swing was confirmed).

**Gate 2: a real animation is achieved — complete swing, evidenced by a human
watching it happen, twice, with the native log recording each construction.
Per the brief: stop here. Phase 3 not attempted.**

---

## 3. Phase 3 — not reached, on purpose

The brief's own gate: do not proceed to Phase 3 if Phase 2 completes a real
swing. It did. The two Phase-3 open questions therefore remain open and
untouched: the live attack-descriptor resolution (`I_CombatActor+0x478`/
`+0x4D8` trace) and whether `C_ActionDirector::SetAction` accepts a puppeted
ghost. Neither was investigated; nothing about them is claimed.

---

## 4. Session infrastructure facts (hard-won, worth keeping)

- **The coding shell CANNOT deploy `KCDMP.dll`.** Two independent
  confirmations this session: a `Copy-Item` to `%LocalAppData%\KCDMP` with no
  game running reported success and a matching read-back hash, yet the next
  launch loaded the old build. The loaded-build check that caught it:
  `Get-Process KingdomCome → Modules → ModuleMemorySize` equals the PE
  `SizeOfImage` (old build `0x4E000`, rung-2 build `0x50000`) — a live,
  unsandboxable observation. **Deploy = the user runs the copy in their own
  shell, game closed.**
- **The coding shell CAN write the small trigger files** — verified live: a
  `Set-Content` from this shell fired the in-game watcher within a second,
  repeatedly. The sandbox asymmetry (2-byte text files pass, the DLL does
  not) is recorded as a fact, not explained.
- **The mirror log works.** `log.h` now writes every line to both the
  AppData log and `kcdmp-native.mirror.log` in the game process's working
  directory (= the game root, `D:\SteamLibrary\steamapps\common\KCD2Mod`,
  set by the launcher's `GameRootOf`). That file is readable from the coding
  shell in real time — the first time this project has had a live native-log
  read path. (`kcd.log` never carries the native `logf` lines; WO-44 §6.1's
  suggestion to read them there was wrong.)
- Ghost gender/soul is deterministic from the id (`KCD2MP_HashString` djb2 mod
  65521 over `"Player"..id`; even = female). `wo45b` hashes male — male ghosts
  get the `kkut_menhart` weapon preset (`sermiry_longSwordMenhart`), which is
  why the longsword tag row fits them. The spawn logs
  `insufficient strength (9) / agility (4) for sermiry_longSwordMenhart`
  errors **on a clean, healthy first spawn** — so those two lines alone are
  NOT the WO-43 corruption signature; the ghost validated healthy and swung.
- The rung-2 implementation deliberately leaks one `0x1A8` action per
  invocation (a retained safety reference, documented in the code). Three
  leaks this session.

---

## 5. Where solid ground ends

**Observed-live:** everything in §1 (all three probe subjects); the four
rung-2 fires and their logged state; the two complete swings and the two
nothing-happens results; the drawn-weapon dependency; the loaded-build
mismatch and the trigger-file write asymmetry.

**Read-but-unrendered:** none new — this was a live session.

**Inferred, labelled:** §2.3's scope/tag explanation for the drawn-weapon
dependency; the assumption that status 1 = "pending installation" (consistent
with the WO-42 status-gate reading, not independently verified).

**Not done, on purpose:** Phase 3 (gated off by success); any repeat-cadence /
loop testing; any pairing (sync-attack) work; re-reading the queued action's
later status transitions; `VERSION` untouched.

---

## 6. Handoff

Rung 2 is the working primitive for ghost combat swings. What a future WO
builds on it:

- **Wire it to the combat-visibility stream** (WO-39's swing events): replace
  the ghost-side `PlayAnim` path with rung-2 construction. Needs the fragment
  spec chosen per weapon class (the tag row must match the ghost's carried
  weapon) and `DrawWeapon` state already synced (it is — WO-39).
- The drawn-weapon precondition is already satisfied in real use: the
  combat-viz stream only emits swings while the attacker's weapon is drawn.
- If paired/sync attacks are ever wanted, that is Phase 3's territory — the
  two open questions in §3, plus WO-42 §5.3's ADB-metadata constraint.
- The rung-2 trigger format, for manual testing:
  `kcdmp-combat.txt` = `<entityId>\nrung2\n<FragmentId, tag1+tag2+...>`
  (real rows only, from `combat_action_attack.xml` /
  `combat_action_sync_attack.xml` in `Tables.pak`).
