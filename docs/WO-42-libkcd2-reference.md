# WO-42 reference — the community `libKCD2` account of the native combat-animation route

**Status of this document: SOURCE MATERIAL, NOT FINDINGS.** Everything here is
what the community-maintained `libKCD2` reverse-engineering documentation
(JerryYOJ, GPL-3.0 — see the licensing note in `docs/WO-40-findings.md`
Phase 1) *claims*. It is checked in verbatim as the starting hypothesis for
WO-42 so that the WO's own verification work has something concrete to be
measured against. **Nothing in this file has been confirmed against this
project's installed build.** For what is actually confirmed, read
`docs/WO-42-findings.md` — and where the two disagree, the findings doc wins.

Licensing: studied as documentation only. No code or headers copied. The
addresses and layouts below are restated as facts-about-a-binary (not
copyrightable expression) so that WO-42 can re-derive them independently.

## What the reference claims

### 1. The queue entry point

```
wh::animationmodule::I_AnimationController::QueueAction(
        IAction& action, float time, bool restartInstalled)
```

- Takes a **fully constructed action object**, not a fragment name and not an
  ID. This is the whole reason WO-40 Phase 6 stalled: there is no
  "play fragment X" native call to reach for; an `IAction` subclass instance
  has to exist first.
- Reached as a WH wrapper at **vtable slot [1]**, or via
  `IAnimatedCharacter::GetActionController()` (**slot [37]**,
  `CAnimatedCharacter::m_pActionController` at **+0x80**), with KCD2's real
  `IActionController::Queue` at **vtable+0x98** (the public CryEngine SDK
  header's declaration order is interfuscator-shuffled and unusable for slot
  arithmetic).

### 2. The real target: the paired sync classes

```
wh::combatmodule::C_CombatActorActionSyncAttack     (attacker side)
wh::combatmodule::C_CombatActorActionSyncHit        (victim side)
```

- Documented as the game's **own internal mechanism for making two
  combatants' animations correspond to each other** — one swings, the other
  reacts, on matching timelines.
- The two instances are linked by a **`m_pSyncPartner` back-reference**
  between the pair.
- This is described as the correct native target for cross-player combat
  sync, not an approximation of it — which is exactly what this project
  needs, because the mod's problem *is* two machines' combatants failing to
  correspond.

### 3. The simpler fallback

```
wh::combatmodule::C_CombatActorActionAttack     -- single, unpaired attack
```

- Documented at **`sizeof 0xB0`**, with a described factory function and
  vtable layout.
- **Critically: the reference contains no example anywhere of one actually
  being constructed and queued.** Only the static layout is documented. The
  real construction sequence — what gets allocated, what fields get set in
  what order, what else must be called before `QueueAction` — is *not* in the
  reference. That gap is precisely WO-42 Phase 3's job.

### 4. Named helper dependencies

```
wh::combatmodule::C_CombatActionHelperAttack
wh::combatmodule::C_CombatActionEarlyExitHelper
```

Named as things these constructors depend on. What they actually require to
exist and be initialized is **not** specified — also WO-42's job.

### 5. The version caveat (the reason Phase 1 exists)

**Every address in the community reference is pinned to one specific game
build**, and that build is *retail* — a monolithic `WHGame.dll`. libKCD2
resolves addresses through an SKSE-style per-build address library whose
generator is not published (`docs/WO-40-findings.md` Phase 1). So the literal
numbers are only meaningful for the exact build they were taken from, and
must be verified against this project's installed version before anything is
built on them.

## How WO-42 is to treat this

- Structural knowledge (class names, rough contents, the fact that a sync
  pair exists and is linked) — **valuable as a map of where to look.**
- Literal addresses, vtable slot numbers, and `sizeof` values — **hypotheses
  to be independently confirmed or replaced**, per WO-42 Phase 2.
- A byte-pattern match is not proof of behavior; a function is only confirmed
  when its disassembled body does what the reference says it does.
