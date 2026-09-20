# WO-106 Phase 6 — the audit, on the corrected premise

WO-105 answered the question this audit series was originally for: the
scriptbind dispatch is thin (WO-105 §3.2/17.3), so "Lua is slow, migrate to
native" is not supported by measurement or by the engine's own structure.
The real argument for native is **reach** — four transform flags no Lua
bind can pass (WO-105 §17.1), one of which (`bRecalcBounds` bit 32) is
almost certainly the ground-collider mechanism behind every puppet sinking
into the ground since WO-63 (Phase 3, blocked this session on a live
two-player test).

This document is the narrower audit that premise leaves: **what does the
mod do that it cannot do from Lua at all**, separated from **what merely
costs more than it has to**, and a redesign list for the latter.

Evidence marks: (observed) / (code-verified) / (synthetic) / (inconclusive).

## 1. Frequency inventory — the vector-getter paths (Phase 2's scope)

Confirmed live this session (`Script.SetTimer` intervals read directly
from `kdcmp.lua`, not inferred):

| path | function | rate | multiplier | Phase 2 status |
|---|---|---|---|---|
| player position (movement stream) | `KCD2MP_EmitState` | 50 Hz (20 ms) | ×1 | converted |
| ghost position (frozen-corpse read) + player position | `KCD2MP_InterpTick` | 50 Hz (20 ms) | ×1 (player) + ×N frozen ghosts | converted |
| puppet tug-of-war read + player target-tracking | `KCD2MP_NpcPuppetTick` | 20 Hz (50 ms) | ×1 (player) + ×N live puppets | converted |
| tracked-NPC position/rotation read (MP-NPCREAD) + player | `KCD2MP_NpcSyncTick` | 10 Hz (100 ms) | ×1 (player) + ×N tracked NPCs | converted |
| riding-check (player + nearby-entity pos, inside `GetEntitiesInSphere`) | `KCD2MP_InterpTick` | 10 Hz (100 ms, throttled 5:1) | ×1-3 entities typically | **left alone** (low volume, see WO-106-findings.md S4.3) |
| general housekeeping | `KCD2MP_Tick` | 2 Hz (500 ms) | — | no vector-getter calls found |

**This is every per-tick vector-getter path in the file.** The remaining
~88 no-argument `GetWorldPos`/`GetWorldAngles` sites (WO-105's 84+13
count) are one-off: spawn paths, console commands, probes, setup — called
per event, not per tick, and were left unconverted by design (see
`docs/WO-106-findings.md` S4).

**Cost ranking, weighted against Phase 2 — with the gap stated plainly:**
Phase 2's own before/after measurement was **not taken** this session (no
rebuilt pak to measure against — findings S4.4). This audit therefore
**cannot** rank table-churn cost against anything else with real numbers.
Treat the frequency table above as the best available proxy (higher
Hz × higher multiplier = more churn removed) until a real `MP-NPCREAD`
before/after exists. **Do not read Phase 2 as "measured and flat" or
"measured and significant" — it is unmeasured**, and this audit's
priority ordering below is frequency-based, not measurement-based, for
exactly that reason.

## 2. Native-only: what Lua genuinely cannot reach

From WO-105 §18.2, cross-checked against what this mod actually needs
today (not everything CRYENGINE offers):

| lever | what it does | relevant to this mod? |
|---|---|---|
| `bRecalcBounds` bit 32 | position change that does not release a living entity's ground collider | **Yes — directly. This is Phase 3**, blocked on a live two-player test this session. The single highest-value native lever this project has identified. |
| transform reason flags (ignore-physics, no-event, not-reregister) | selective suppression of a transform write's side effects | Plausibly useful alongside bit 32 for the same native puppet-write path, but **no need identified independent of Phase 3** — do not build these speculatively ahead of Phase 3 confirming the mechanism live. |
| `IEntitySystemSink` (veto spawn/remove) | callbacks with veto power on every entity lifecycle event | No current need. Would matter if the mod ever needed to intercept a REAL game spawn/despawn, which it does not — it only manages entities it creates itself. |
| `IEntityClass` user proxy create function | attach a native component to every entity of a class | No current need. |
| `RequestMovement` / actor target (exact positioning) | move a character through animation instead of a transform write | **WO-105's own §6.3 flags this as the single most valuable unprobed item it surfaced** — whether KCD2 exposes an equivalent to `IMovementController` at all is (inconclusive), not attempted this session (native-only investigation, out of scope for a Lua WO). Carried forward as open per WO-105's durable context. |
| collider-mode script layer | request a collider mode without fighting the animation graph | No current need identified; WO-105 marks it (inferred as unused, not verified against KCD2's bind set). |
| Mannequin action priority / forced scope mask | make a queued action win a scope | **Already the native combat-anim work's whole subject** (WO-42/44/45/46/47/49) — not a new item, already pursued natively for exactly the reason WO-105 §5.3 describes ("a queue call succeeding is not evidence the fragment played"). |
| `MarkAspectsDirty` / aspect profiles | the engine's own declare-not-diff networking model | Not used and not needed — KCD2 barely implements `NetSerialize` (WO-52), so there is no aspect-profile machinery to hook into. WO-105 §14.3 suggests stealing the *concept* (a discrete profile change sent reliably, separate from state) for the puppet/replica promotion boundary — **already effectively what the replica promotion does**, just not framed in those terms. Not an action item. |
| entity system `PauseTimers` | pause the *entity* timer system | Distinct from the *script* timer manager this project has fought (WO-78, WO-105 §12.2). No identified need to touch entity timers specifically. |

**Bottom line: exactly one native-only lever has a live, active use case —
`bRecalcBounds` bit 32 for Phase 3.** Everything else in the native-only
column is either already being pursued (Mannequin), speculative
(transform reason flags without Phase 3 confirmed), or a genuinely open
question for a future WO (`RequestMovement`/`IMovementController`).

## 3. What should NOT move — policy stays in Lua

Per the standing split (native for per-tick reads/writes, Lua for
decisions): every toggle, threshold and yes/no policy decision in
`kdcmp.lua` stays in Lua regardless of this audit. Concretely: the
`_on`/`_off` command family (WO-106 Phase 1 §3.3), the yield/diverge/cull
thresholds, the co-location hysteresis, the replica promote/demote
decision itself (as opposed to the write it produces), quest-sync gating.
None of these run at a rate where Lua's dispatch cost (WO-105 §3.2:
small, constant, no allocation) is distinguishable from zero, and every
one of them is exactly the kind of judgment call this project's own
"ship new features on" / fail-closed design rules depend on being easy to
read and change without touching a native DLL.

## 4. What should be redesigned rather than migrated

### 4.1 `System.GetEntitiesInSphere` → `System.GetPhysicalEntitiesInBox`

**Tested live this session — the picture is more specific than WO-105's
reference predicted, in a way that matters for anyone touching this next.**

**28 call sites**, categorized by rate:

| call site | function | rate |
|---|---|---|
| the roster rescan (37,079-entity walk, WO-102.5 S6.2) | `mp_npc_rescan` (2 sites) | every 2000 ms (`npcSync.scanMs`), per anchor |
| non-authority drag detection | `mp_drag_sensor` | every 100 ms (10 Hz) when a non-authority player is near a dragged body |
| dropped-item detect/spawn/finalize | `mp_item_detect`, `mp_item_spawn`, `mp_item_finalize` | every 750 ms (`itemSync.scanMs`) + one tick later per drop |
| periodic replica reconciliation | `KCD2MP_NpcReplicaSweep` | every `NPC_RECONCILE_INTERVAL_S` (a few seconds) |
| riding-check nested loop | `KCD2MP_InterpTick` | 10 Hz, throttled, small result sets (Phase 2 S4.3) |
| everything else (18 sites) | console commands, probes, one-off diagnostics (`mp_find_npcs`, `mp_scan_horse`, `mp_dice_scan`, known-answer checks, test spawns) | per event / per command, not periodic |

**The two highest-value redesign targets by rate are `mp_npc_rescan` and
`mp_drag_sensor`.**

**Live test against the running 0.26.2 session, same anchor (player
position), same 30 m radius, same instant:**

* `System.GetEntitiesInSphere(pos, 30)` → **698** entities (full-array
  walk, matches WO-105 §1.3's description exactly — every entity within
  range, no physics filter).
* `System.GetPhysicalEntitiesInBox(pos, 30)` → **262** entities.
* **Signature correction, build-specific, not in the WO-105 reference:**
  the stock signature is `(boxMin, boxMax)`, two corner points. **On this
  build it is `(center, radius)`** — calling it with two corner tables
  produced `[Warning] Validator: [Script Error] Wrong parameter type.
  Function System.GetPhysicalEntitiesInBox(center, radius) expect
  parameter 2 of type Number (Provided type Table)`. This is exactly the
  standing trap restated: WO-105's reference is stock CRYENGINE 5.7.1:
  correct about the engine, wrong about this specific bind's exposed
  signature on the KCD2/Warhorse build. **Anyone using this bind must
  pass `(center, radius)`, not two corners.**
* **The `es_UseProximityTriggerSystem` CVar named in WO-105 §1.3/17.5 does
  not exist on this build** — `Unknown command` from the console, `nil`
  from `System.GetCVar`. There is **no CVar-based gate to check** before
  trusting this bind on KCD2, contrary to the reference's caution. The
  grid nonetheless returned real, non-empty, non-trivial results (262
  entities), so **the grid is being maintained regardless** — but this
  was verified by testing, not by reading a CVar, because the CVar this
  build would use (if any) is unknown.
* **The result is not a subset of the sphere walk filtered to physics
  entities**, as the naive reading would predict — filtering both lists to
  class `NPC`/`NPC_Female` gave **12 human NPCs from the sphere walk and
  16 from the box query**, i.e. the box query found MORE named humans at
  the same radius. This is consistent with the box literally being a box
  (side `2×radius`) rather than a sphere: a cube circumscribing a sphere
  of the same radius has roughly 1.9× the volume, so entities near the
  anchor's diagonal corners that are outside the 30 m sphere are inside
  the 30 m box. **This confirms WO-105's own caveat exactly**: "a caller
  wanting a sphere must distance-filter afterwards." Skipping that step
  would silently pull in entities further away than the code thinks it
  asked for — not an empty-result trap, but an over-inclusion trap.

**Recommendation:** the swap is real and the grid clearly works on this
build, but it is **not a drop-in rename**. A correct redesign of
`mp_npc_rescan` (the actual 37,079-entity cost site) needs:
1. Call with `(center, radius)`, not corners.
2. Distance-filter the result back down to the intended radius (one
   `dx*dx+dy*dy <= r*r` check per candidate — cheap compared to the walk
   it replaces).
3. Confirm the physics-only filter doesn't silently drop a human NPC that
   is, for some reason, not physicalized at the moment of the query (WO-105
   §4.6/13.3: physics can be LOD'd off by distance/visibility) — this
   session's 16-vs-12 comparison didn't hit that case, but a systematic
   before/after over many anchors, not just one, is the real test before
   converting the live rescan path.
4. **Not attempted this session** — this is a real code change to the
   mod's single most expensive periodic operation, and per this WO's own
   discipline ("test before you build"), the next WO should do the
   before/after over multiple anchors first, the same way Phase 3's test
   is designed, before touching `mp_npc_rescan` itself.

### 4.2 What is NOT a redesign candidate

`mp_drag_sensor`'s and the item-sync functions' `GetEntitiesInSphere`
calls are smaller in both radius and expected result count than the
roster rescan; converting them is lower-value and was not investigated
further this session — flagged, not ranked, pending the multi-anchor test
above landing first for the higher-value site.

## 5. Next three WOs, in order

1. **Phase 3, live, two machines**: halve the puppet write rate on one
   sinking NPC, watch whether it improves (WO-106 Phase 3, this WO's own
   blocked phase). This is still the single highest-value open question
   in the project — it reframes every puppet-smoothing WO since WO-63 if
   confirmed.
2. **The `GetEntitiesInSphere`→`GetPhysicalEntitiesInBox` swap for
   `mp_npc_rescan`**, done as its own small WO: multi-anchor before/after
   comparison first (§4.1 point 4), then the actual code change behind a
   toggle (`mp_npc_scan_native_on`-style, ship on with a fallback), with
   the distance-filter and physics-LOD caveats from §4.1 built in from the
   start rather than discovered live.
3. **Probe `IMovementController`/`RequestMovement` on KCD2** (WO-105
   §6.3's open item): a native-side investigation, not a Lua one — is
   there any Warhorse-side equivalent reachable at all, even read-only?
   This is the lever that would let a puppet move *through animation*
   instead of a teleporting transform write, which is the structurally
   correct fix for the whole class of problem Phase 3 is chasing from the
   other direction (suppressing the transform write's side effects rather
   than not needing the write at all).
