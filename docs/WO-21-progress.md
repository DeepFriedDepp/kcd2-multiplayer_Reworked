# WO-21 progress

## 2026-08-04 — behaviour-tree hypothesis tested, refuted, A1 re-root-caused

Full evidence in `docs/WO-21-findings.md`. Summary of the session:

**Phase 0 (offline, shipped game data).** Solved the "IdleSeq is already
shared" puzzle: `esModularBehaviorTree = "IdleSeq"` is the class default in
`Scripts/Entities/AI/Shared/BasicAITable.lua`, and the string occurs exactly
once in all of `Scripts.pak` + `Tables.pak` + `IPL_GameData.pak` — there is no
tree by that name. KCD2 runs NPC behaviour on Warhorse's brain/subbrain system
instead (`npc_basic` → `npc_basic_scheduler` + `npc_basic_switch`, which holds
the hit-reaction, wake-up and attack branches; the plain default brain maps to
a single `Wait(-1)` node).

**Phase 0 (live).** No brain surface is reachable: `Actor.SetAIBrainId` is
documented by Warhorse but not registered in this build, nothing on
`AI`/`actor`/`soul` mentions brains, `XBehaviorModule` reflects nothing, and
every AI-relevant Lua property reads identically on a real guard and a ghost.
`AI.StartModularBehaviorTree` is inert (a garbage tree name returns exactly as
cleanly as a real one). `soulPool` as a spawn property does nothing.
**Gate 0: no Lua-level differentiator — escalated to native, not guessed at.**

**Phase 1.** Could not run as written; there is no richer configuration to
apply. At the human's direction the session instead reproduced A1 live: four
faction-attached ghosts, tree/preset/weapon varied independently.

- Every **male** ghost was beaten unconscious within ~60 s regardless of
  configuration — faction membership alone is sufficient for real aggro.
- **A1 reproduces but WO-17's root cause is wrong.** It is not a state desync;
  `IsUnconscious=true` with real injury buffs and attackers correctly
  disengaging. What never happens is the wake-up: 16 minutes unconscious,
  health frozen to the decimal. WO-17's `RANENY_NA_ZEMI_MUZ` evidence should be
  retired — `Roles` is a static catalogue, present on an untouched ghost.
- **A2: no change.** No ghost attempted to act against anything.
- **New, unconfirmed:** the female ghost was never attacked — 100 hp for 16
  minutes with an identical attach, standing between two ghosts that went down.
  n=1; needs a dedicated confirmation run.

**Phase 2.** Both regression risks moot — nothing new to regress. Said plainly
rather than claimed as a pass. They come back live if native brain assignment
is ever achieved.

**Also corrected:** WO-16's perception asymmetry does not reproduce. An
empty-tree ghost both perceives and is perceived (5 perceptor / 18 perceptible
records). `mp_enable_aggro`'s tree switch is a no-op; the feature works purely
through the native faction attach.

**Scope respected:** no change to `KCD2MP_SpawnGhost`'s defaults, the aggro
toggle, `VERSION`, or the release pipeline. New files are test tooling only.
All test spawns removed; `KCD2MP.aggroEnabled` returned to `false`.

### Open, for a future WO

1. Native: how a brain is bound to an entity, and whether it can be written
   like WO-15's `SetParent`. This is the only path left to A1 or A2.
2. Confirm or drop the female-ghost result before it goes anywhere
   user-facing.
3. `KCD2MP_SpawnGhost`'s `mbt` switch is dead code; its comments and
   `WO-16-release-candidate.md` Phase C claim it does something it does not.
