# WO-121 — movement and combat: findings

Solo work on one machine with the Modding Tools build, a synthetic v8 peer
(`tools/wo121/avatarpeer`), WO-118's SynthPeer and a throwaway save.
Nothing in this file is two-player evidence. Evidence marks: (observed),
(code-verified), (synthetic), (inconclusive).

## 0. Answer first

- **Avatars now move with the engine's own gait.** Per-frame
  `SetPseudoSpeed` from the peer's streamed speed. Walk, run and sprint look
  like Henry's; the pseudo-speed readback equals the stream (1.40 → 1.40)
  (observed). NPC copies get the same from their rendered speed (observed).
  WO-118's trace gate stays **GREEN** with gait on, on the final build
  (synthetic).
- **Crouch and jump replay** through the engine's own `SetCrouch` /
  `RequestJump` (observed, screenshots §2).
- **Combat is state plus rows, never "play animation X".**
  - The avatar's brain stays, with its combat automation off natively
    (observed: 60 s held combat, no self-directed action).
  - Guard zone and held block replay as state; two guard zones give two
    distinct poses (observed).
  - Attacks, dodges and perfect blocks replay the sender's committed Mannequin
    row by GUID (observed, 4 longsword attack rows + dodge + perfect block).
- **NPC copies swing the host NPC's real rows** (`NpcAttack`). Three fist
  rows queued and visible on a puppet (observed).
- **Friendly fire ships ON.**
  - Gate items 1–5 passed solo.
  - Bleeding is **not** carried, because the forward is plain damage. The
    maintainer decided: ship on, record the gap. §6.
- **NPCs "fight back": partial.**
  - An attributed hit makes the NPC target the avatar and join a skirmish with
    it (observed).
  - The hit NPC itself never swung back in three tries. It barks "a friendly
    NPC got hit".
  - Bystanders do brawl the avatar once its AI ignorance is lifted (observed).
  - Shipped: ignorance is lifted per engagement for 30 s (maintainer
    decision). §5.
- **Protocol v8.** A v7 handshake is refused with `0x09`/server v8 (observed).
- **Not done:** Phase 2c (ladders/vaults) not attempted; Phase 7 (ranged)
  parked; no two-machine run. §9.
- **One game crash** (BugSplat) on a save load right after a bystander brawl
  with ghost ignorance off. Not reproduced in two narrower repeats
  (inconclusive). §8.

## 1. Phase 0 — addresses, found by anchor, fail closed

Every piece resolves by RTTI vtable, string-referencing function,
unique-call-target or byte check. A missing anchor disarms only its own piece
and logs why: `WO121-MOTION piece=<x> NOT armed -- <reason>`. On this build
all pieces armed, every launch (observed):

| piece | anchor |
|---|---|
| gait | `C_Actor` vft slot 0x448 `SetPseudoSpeed` (checks the actor+0x7E8 → +0x18 write) |
| crouch / jump | `C_ActorStateExpansion` slots 0xE8 / 0xF0 / 0x100; holder at actor slot 0x980 |
| combat mode | `C_CombatActor` slot 0x360 `TryStartCombatMode`; the guard-request flag via the common callee of `C_SetGuard::Execute` and the "Player standard guard request cleared" function |
| automation off | CombatModule `0x498060` target (contains `call [r*+0x2C8]`) |
| guard / attack zone / block | unique call targets of the test commands' `Execute` (slot 0xE0) |
| capture | `EnterImpl` slot 0x1C8 thunks on the Attack / Dodge / PerfectBlock / Block actions; combat actor at action+0x78 |
| hit slot | `C_CombatSoul` +0x150 / +0x158 (vtable patch) |
| history / skirmish | RPGModule `0x750e10`; the `StopFight` callee (the skirmish getter), checked against the `C_SkirmishManager` vptr at use |

Retail names from other pointers do not exist on this build; nothing here
uses one (code-verified).

## 2. The screenshot table (Henry's reference beside the avatar)

Images are in `docs/wo121-shots/`. Henry's references use the hunting sword,
Henry's only blade on the throwaway save; the avatar carries a longsword.

| action | Henry | avatar | verdict |
|---|---|---|---|
| walk / run / sprint | `1-gait.jpg` left | right | same gait bands; sprint leans and pumps like Henry (observed) |
| crouch | `2-crouch-jump.jpg` | shipped build | crouched pose (observed) |
| mid-jump | `2-crouch-jump.jpg` | Z arc 0.6 m | airborne, legs tucked (observed) |
| guard zones, held block | `3-guard-block.jpg` top | bottom | two distinct guards; the block raises the blade (observed) |
| overhead / right / left / thrust | `4-attacks.jpg` (Henry: left slash only) | 4 rows | four distinct swings (observed). Henry's sword overhead / right / thrust references were blocked by a tree and not retaken |
| dodge / perfect block | none in the WO list | `5-dodge-perfectblock.jpg` | side lunge; crosswise overhead block (observed) |
| NPC copy gait and rows | — | `6-npc-copies.jpg` | stride between frames; fist-fight poses on three rows (observed) |
| legacy preset | — | `7-…jpg` bottom right | the 0.28.x clip walk returns (observed) |

A synthetic trap worth keeping: photo mode freezes Henry, but the native
writer keeps moving puppets at the frame hook. The peer's `freeze` command
stops the stream at the shutter.

## 3. Phase 2 — gait, crouch, jump

- The avatar's speed comes from the v8 state block while it is fresh
  (< 1.5 s). An NPC copy's speed is its rendered planar speed, smoothed with
  τ ≈ 0.15 s. A render step over 9 m/s is treated as a snap and ignored: a
  `stand` teleport had briefly driven 13.65 m/s into the gait (observed, fixed).
- `WO121-GAIT` lines, every 2 s per avatar, show state, stream speed, render
  speed, written speed and readback. Readback equals written (observed).
- WO-119's probe verb read the wrong offset for pseudo-speed, and that
  offset showed 0 throughout. The real field is actor+0x7E8 → +0x18.
- Crouch: `SetCrouch(want, false)` on the expansion, one call per edge
  (observed).
- Jump: the `RequestJump` hook marks the local jump; the receiver calls it on
  the avatar. Tested with a stream whose Z really rises (observed).
- The Lua `StartAnimation` locomotion loop is parked for native-owned bodies
  (one `StopAnimation(0,0)`). It masked every Mannequin pose, which is why
  WO-119's guard "worked" only after the park (observed).

## 4. Phases 3–4 — held combat, rows

- Automation off: `0x498060(cmd, ca, 0)`, once per attach. Combat mode is held
  with `TryStartCombatMode` plus the guard-request flag (model+0xEE8, scope 4),
  re-asserted every 0.25 s only while not in combat. 60 s held at 3 m from
  Henry: State 2 throughout, no attack / target / skirmish line naming the
  avatar, Henry untouched (observed, shipped build).
- Sender: `EnterImpl` thunks read the committed row GUID (descriptor+0x84,
  Windows GUID byte order), the zone and the type, and send them over pipe
  0x96 to the agent as a v8 ActionUp.
- Receiver: the agent maps the GUID through `ActionRowCatalog` (745 rows from
  Tables.pak: attack / block / perfect_block / dodge) to `"<fragment>, <tags>"`.
  It holds the body 900 ms and queues the row through the existing swing path:
  `SWING … queued fragment 897 status=1` (observed).
- Free-mode attacks always use the one FreeAttack row (fragment 195); locked
  attacks use CombatAttackGen (fragment 897) (observed).
- Events carry the sender's clock. An event more than 1 s behind the newest
  position from that peer is dropped and counted (`ev_stale`) (synthetic).

## 5. Phase 5 — attributed NPC hits

On the NPC's damage authority, an attributed `0x31` (flag 0x04) runs four
steps (all four observed, `steps=0x7` plus the Lua brain message):

1. damage with the peer's avatar as the attacker;
2. the combat-history write `0x750e10`;
3. one skirmish add (override 1) per engagement per 30 s;
4. the brain message `hitReaction`.

**The hitReaction values are captured, no longer provisional.** One vanilla
sword hit by Henry on a lone farmer was taken with a `SendAISignal` hook
(WHGame 0x168690) (observed, with the maintainer):
- `S_HitInfo` offsets: hitStrength +0x44 = **5**, hitType +0x18 = **1**,
  targetOrigMat +0x34 = **5** (cloth; it is the victim's material and varies).
  The message is sent only when +0x78 ≠ 0.
- The hitType 10 WO-119 saw is the brain-driven event, not a weapon hit.

The attributed apply also echoed: it came back out as a local hit
(`MP-DMG dir=out` after the apply). Fixed with the plain path's
`note_remote_damage` guard. With attribution off, no echo occurs (observed).

**Fight-back test** (5.3, with the maintainer):

| try | victim | result |
|---|---|---|
| 1 | a farmer, ghosts ignorant (default) | knocked down; targets the avatar, skirmish; "changing weapon" bark loop, then gives up ("Nothing, I suppose.") (observed) |
| 2 | spawned `test_soldier_ai` | knocked down; `Set opponent: kcd2mp_1`; stands facing it 12 s, bark `PRATELSKE_NPC_DOSTALO_ZASAH` ("a friendly NPC got hit") (observed) |
| 3 | same, ghost ignorance off | two bystanders brawl the avatar (`Skirmish event: Attack … target kcd2mp_1`); the victim still does not swing (observed) |
| 4 | same, per-engagement un-ignore (shipped) | `WO121-ENGAGE … SetIgnorant(0) ok=true`, released 30 s later; the victim targets but does not swing (observed) |

Reading: the victim treats the avatar as friendly. Ghost ignorance only
gates the bystanders. The relation / friendliness lever is still open (§9).

## 6. Phase 6 — friendly fire and its gate

**The mechanism as built:**
- The hit slot does not apply damage inside the call. `0x70ce00` copies the
  0x90-byte hit data into a cause, queues it, and writes history. hp and
  stamina are unchanged across the call, every time, and `S_CombatHitData`
  holds no damage amount (code-verified from disassembly, observed from
  dumps).
- Skipping the call crashes the game (session 1).
- So a player's hit on an avatar is **watched**: the avatar's hp/stamina are
  read every frame for 0.6 s. The drop lands at frame 1 and is put back at
  once, and the total goes out as `PlayerHit` 0x44. Hits from non-players
  are untouched (observed).
- With the host lever off, the measurement still restores but nothing is sent.

**Avatar script contexts**, while `mp_avatar_combat` is on:
- `crime_ignorePlayersDrawnWeapon`, `crime_disableHitFromPlayerReaction`,
  `crime_suppressBehavioralReaction`, `crime_suppressFightStartBark`,
  `combat_disableAllSkirmishBarks`, set natively with readback true (observed).
- Before these, the avatar barked `crime_reaction_barks … vytazena_zbran`
  at Henry's drawn weapon and changed weapon on its own (observed).
- **`combat_suppressFriendlyFire` is deliberately absent.** With it set, a
  sword hit on the avatar did no damage at all (unarmoured, buff removed), so
  there was nothing to forward (observed).
- The imm+upr guard buff stays. It does not block damage: a Lua `DealDamage`
  took 100 → 90 with it on (observed).

**The gate:**

| # | item | result |
|---|---|---|
| 1 | no fight on the attacker's machine | **pass**: no combat HUD after 3 hits, no skirmish or lock (the lock in the test is the harness's own) (observed) |
| 2 | no reaction from the avatar's brain | **pass**: no targeting, no fleeing, no bark. It does give the pain scream `COMBAT_VICTIM_SCREAM_RECEIVED_HIT`, counted as cosmetic (observed) |
| 3 | not a crime | **pass**: no crime or witness lines (observed) |
| 4 | the hit lands on the partner's Henry | **pass except bleeding**: 20 hp / 10 st applied, no attacker; unarmed floor → knockdown, wake in place; lethal weapon hit → death, grave with 28 items, wake 348 m away, no Game Over (observed, injected PlayerHit) |
| 5 | no fight on the victim's machine | **pass**: nothing names the attacker's avatar (observed) |

The chain end to end (synthetic peer): Henry's sword hit on the avatar,
measured hp −0.33 / st −40, arrived at the peer as
`PlayerHit … hp=0.33 st=40.00` (observed).

**Default: ON.** The strict rule would ship off because item 4 names
bleeding. The maintainer decided ship on and document the gap. The
`WO121-BUILD` line says so on every launch.

## 7. Smoke on the shipped pak

1. Phase 2 and 4 actions, screenshots: run, crouch, guard, overhead retaken on
   the final pak and DLL (observed); the rest from the same motion code
   earlier the same day.
2. WO-118 gate: **GREEN** (walker 0 frozen, seated 0.0 mm), final build
   (synthetic).
3. 60 s held combat, no self-directed action (observed).
4. Phase 6 gate: §6.
5. v7 client → `0x09` with server version 8; v8 → Ack (observed, one
   direction; WO-118 saw the reverse refusal).
6. `mp_preset_legacy`: all six motion/combat toggles off, contexts cleared,
   automation back on, the clip walk returns (observed). Friendly fire follows
   the host's session setting, so a joiner keeps the host's value by design.

## 8. The crash

A BugSplat on `wh_sys_LoadGame` about 8 s after the stack stopped. Just
before: a bystander brawl with ghost ignorance off, the avatar at 1 hp, a
spawned soldier alive, and Henry added to the skirmish.

Not reproduced by:
- (A) spawn-only then load;
- (B) spawn, attributed hit and skirmish, avatar despawn, then load.

Both were clean (observed). The leading guess is the known "map marks hold raw
pointers" trap: a combat mark on an entity the load destroys (inconclusive).

## 9. Not done, stated plainly

- **Phase 2c** (ladders, vaults): not attempted (optional).
- **Phase 7** (ranged): parked, never started. The bow-in-hand step alone
  needs its own session.
- **Bleeding** is not carried by friendly fire.
- **Victim fight-back**: the victim targets the avatar but does not swing; a
  relation lever is needed.
- **Two machines**: nothing here ran across two machines. The Steam
  two-network gate (WO-120) is also still unrun.
- Henry's sword overhead / right / thrust references were occluded and not
  retaken.

## 10. Needs the maintainer

Both items ran this session with the maintainer present:
- the vanilla sword-hit capture (§5, done);
- the fight-back test (§5, partial result).

Still open for a person: a two-player session with the runbook
(`docs/WO-121-runbook.md`) and the predictions in §11.

## 11. Predictions for the next peer session

Both machines on this build, runbook followed. "Joiner" = the machine whose
kcd.log says `MP-AUTHORITY-OWNER … authority=peer`.

| # | prediction | P |
|---|---|---|
| P1 | The partner's avatar walks, runs and sprints with leg motion matching its speed (no gliding) | 0.85 |
| P2 | `WO121-GAIT … state=fresh` dominates on both sides while moving | 0.90 |
| P3 | Crouch replays within ~0.3 s | 0.80 |
| P4 | A jump replays as a visible jump, not a slide | 0.60 |
| P5 | Guard zone changes show on the avatar in locked combat | 0.70 |
| P6 | Attacks replay as the same direction the partner chose (`MP-SWING hop=queued ok=1`) | 0.75 |
| P7 | `ev_stale` stays under 5 % of `ev_in` | 0.85 |
| P8 | A friendly-fire sword hit costs the partner hp, with `MP-FF dir=in … result=applied` | 0.80 |
| P9 | …and starts no fight or crime on either machine | 0.75 |
| P10 | A fist knockout of a partner is a knockdown, never a grave | 0.85 |
| P11 | An NPC hit by the partner targets the partner's avatar (`Set target: kcd2mp_N`) | 0.80 |
| P12 | …and actually swings at it | 0.20 |
| P13 | A mixed 0.28.x / this-build pair is refused at the handshake | 0.98 |

**Top failure modes, with the identifying line:**
1. Gait reads 0 on the avatar: `WO121-GAIT … state=none` means the state
   block isn't arriving (check the sender's `MP-WO121-STATS ev_out`).
2. Double damage on an NPC: `MP-DMG dir=out` right after
   `MP-ATTRIB … result=applied` on the same NPC (the echo; fixed, watch for a
   regression).
3. The avatar fights on its own: `Skirmish event: Attack on kcd2mp_N` with
   no inbound attack event (automation not off: `WO121-MOTION piece=combat
   NOT armed`).
