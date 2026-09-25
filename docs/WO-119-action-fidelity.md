# WO-119 — action fidelity: the research

Session 2026-09-24, solo, unattended, Modding Tools build (binaries dated
2026-08-26, image base 0x180000000), the installed 0.28.3 pak, **no KCDMP.dll,
no agent, no relay**. Three game launches, one fresh throwaway save
(`quicksave034`, 09:30, world-time ratio 1, death guard on). Progress, method,
side effects: `docs/WO-119-progress.md`.

**Research only. No shipped code, no pak, no installer, no VERSION bump.**
A research probe DLL (the WO-116 pattern, grown into a runtime-hook tool) was
built and injected from the session scratchpad; it is not in the repository.

Evidence marks: (observed) / (code-verified) / (synthetic) / (inconclusive).
"The call succeeded" is never used as "the thing happened": live rows below
were read back from the engine (combat-model properties that name themselves,
director scopes, Mannequin tag state, animation state, kcd.log's own skirmish
/ dialogue lines, health) or seen on screen. Frame rate: 73–94 fps with the
game window in front for every live row (per-30-s frame-hook counts); no row
was taken under the background limiter.

Paths: `<install>`, `<saves>`, `<scratch>`. "Avatar" = the peer's ghost body
(`kcd2mp_<id>`, the mod's own spawn path, `KCD2MP_SpawnGhost`). RVAs are this
build's; every lead from another developer's pointers (retail addresses) was
re-found by `__FUNCTION__` strings, RTTI or live capture — none was used as
given.

---

## 0. Answer first

* **The engine already has a replay door for every group, and it is not
  input.** Warhorse ships a full combat test harness inside CombatModule
  (`wh::tests::combat_AttackAction / BlockAction / SetGuardZone /
  SetRequestedAttackZone / SetGuard / SetBlockMode / SetTarget / SetAim /
  EnableAutomation / StealthAction / MasterStrikeAction / PerfectBlockAction /
  DodgeAction …`). Each command resolves any named actor → combat actor and
  calls the same functions the player path calls. That harness is the map of
  "how to apply X on a body that has no player". (code-verified)
* **Combat accept points on this build (observed live on Henry):**
  zone = `SetRequestedAtkZone` (CombatModule `0x72850`, from
  `CombatPlayerInput`); guard zone = `SetGuardZone` `0x72980`; held block =
  `SetBlockMode(on, scope)` `0x72eb0`; attack = `PlayerController::Attack`
  `0x33f3c0` → attack factory `0x5a690` → `C_ActionDirector::SetAction`
  (Framework export). All three state setters **land on the avatar**
  (observed; the model properties read back their own names).
* **The avatar can hold combat mode natively** — `TryStartCombatMode`
  (combat-actor vtable `+0x360`) plus one guard-request flag
  (`model+0xEE8`, `E_GuardRequestScope`, 8 bools). Without the flag the
  engine ends combat the next frame (kcd.log: `Requested combat termination:
  No main action`, printed on that branch too). With it the avatar shows a
  real guard stance and holds a `C_CombatActorActionBlockTrigger` as block
  state. (observed)
* **Attacks on a remote body: the look and the outcome are separate
  routes.** The cosmetic route (queue a `C_CombatAnimAction` from a
  `combat_action_attack` row's fragment + tags, WO-45/46) renders
  **directional** swings on the avatar — overhead head slash (aZ0), right
  slash (aZ2), thrust (aZ5) — with no combat mode and no hit logic
  (observed). The real-action route (attack factory) refuses the avatar (its
  row search finds nothing for an NPC with this weapon), and a forced row
  enters and finishes in ~90 ms with no visible swing (observed). **Build on
  the cosmetic route; the outcome stays name-addressed damage from the
  attacker's machine.**
* **Velocity drives gait, confirmed live.** A moving avatar shows no engine
  gait (idle tags, `MotionIdle`); with `C_Actor::SetPseudoSpeed` (EntityModule
  `0x978f0`) written every frame the engine itself sets `walk`/`run`,
  `forward`/`backward`, alternating footfall tags and `MotionMovement`.
  Pseudo-speed alone on a *stationary* body does nothing (the logical speed
  is capped by the body's real speed). (observed, code-verified)
* **Crouch and jump apply on the avatar** through its state expansion
  (`SetCrouch` slot `+0xE8` → engine tag `stealth`; `RequestJump` slot
  `+0x100` → `MotionJump>MotionLand`). (observed; crouch pose on screen not
  confirmed)
* **Takedowns and bodies apply on the avatar through shipped Lua binds.**
  `actor:RequestKnockOut(victim)` on the avatar ran a real stealth sync pair
  on a test NPC (clinch, then the victim won the perfect-block duel and a
  real fight followed); `RequestGrabCorpse` / `RequestPutCorpse` on the
  avatar carried a body on the shoulder (`MasterSlaveManager … 'kcd2mp_7' ->
  body`), followed the avatar while the mod's stream moved it, and dropped
  it. (observed)
* **Phase 0 verdict: keep the brain, overwrite its combat choices** (§1).
  `NoAI` bodies are refused by the skirmish system (can't be an NPC's combat
  target) and have no AI object (`entity.this` nil). `SuspendedAI` at spawn
  does **not** suspend the brain (the body walked ~100 m and played
  `LookingAround`). The current body is perceived, targeted and attacked
  (observed). Keep it; suppress its combat automation (the shipped
  `combat_EnableAutomation` path) and hold combat state from the stream.
* **Phase 1: attribution is four sinks, and the natives for all four are
  found.** Damage (`TakeDamage`/`DealDamage` with attacker → the victim's
  vanilla shout names the avatar), combat history (RPGModule `0x750e10` →
  `HasCombatHistoryWithSoul` 0→1 both ways, the first time this project made
  it true), skirmish (`AddSoulToSkirmish(victim, avatar, override 1)` → the
  NPC's own target and opponent become the avatar, and the next attributed
  hit is booked as `Skirmish event: HitTarget on kcd2mp_7`), and the brain
  message `hitReaction`. (observed) **Not shown: the victim fighting back** —
  the spawned test souls reacted civically (barks) and never entered combat
  in 15 s windows (inconclusive; §2.4).
* **Bow: the whole chain is mapped and captured live on Henry**
  (`StartMain(mode 2)` → `Fire` → `C_ActorShootingUtils::Shoot`), but on the
  avatar the bow never got into its hand, so the expansion calls faulted
  (caught). (observed / inconclusive)

---

## 1. Phase 0 — the avatar's body (verdict: keep the brain)

Solo, three bodies side by side in an empty meadow ~140 m from Troskowitz
(nobody within 70 m): the mod's ghost (`KCD2MP_SpawnGhost`, i.e. today's body:
soul-backed `NPC`, `AI.SetIgnorant`, isolation contexts — **but see caveat**),
an `NPC` spawned with `NoAI=true`, and one with `SuspendedAI=true`, same
spawn table otherwise. Probes: skirmish targeting from a test NPC, perception
signs, Henry's hits, combat state writes.

| question | current body (ghost) | `NoAI` | `SuspendedAI` | evidence |
|---|---|---|---|---|
| AI object present (`entity.this`) | yes | **no (nil)** | yes | observed |
| brain really off | no (by design; ignorant) | yes | **no** — walked ~100 m on its own, anim `LookingAround` | observed |
| perceives others | yes — greeted Henry with the vanilla greeting monologue | (n/a — no brain) | yes | observed |
| can be an NPC's combat target (`AddSoulToSkirmish(npc, body, 1)`) | yes — `TargetChanged … (target kcd2mp_7)`, `Set opponent` | **refused** (returns 0, no skirmish lines) ×2 | yes — `TargetChanged on wo119_soldier2 (target wo119_susp)` | observed |
| hostile NPC attacks it | **yes** — after a failed takedown a test soldier ran `CombatAttackComboGen` on it, health 100 → 3.3 | not reached (refused above) | target set, no attack in 10 s | observed |
| its brain competes with replay | yes — fled the fight (`SKIRMISH_SOULFLEE` bark), ended combat mode each frame without a request flag | — | — | observed |
| guards react in a restricted area | not tested | | | (inconclusive) — out of scope with the shared world; a restricted-area walk near guards was ruled out by the safety rules |
| NPCs step around it | not tested | | | (inconclusive) |
| takes local damage from Henry | Henry's swings produced WHGame hits on it (hitType 10, strength 5/2) that come from **XGenAI → RPGModule `0x70c720`** on worker threads, not from a weapon collision; health stayed 100 | not tested | not tested | observed — see §2.5 |

**Caveat.** KCDMP.dll was not loaded, so the ghosts' isolation script contexts
(applied natively, WO-68/99.5) were absent in these runs; the ghost therefore
was *more* reactive than a production ghost (it greeted Henry, witnessed and
barked). Nothing here depends on those contexts except the civic barks.

**Verdict: keep the current body (brain on), overwrite its combat choices.**
Why:
* `NoAI` loses exactly what Phase 1 needs — it cannot be put in a skirmish,
  so no NPC can target it through the engine's own system. This contradicts
  WO-100.5's "NoAI keeps hit registration" only in part: WO-100.5 counted
  `HitTarget` lines from Henry's direct hits; the skirmish *add* is refused.
  Both observations stand.
* `SuspendedAI` as a spawn flag does not keep the brain off on this build.
* The brain's competition is containable natively and cheaply:
  `combat_EnableAutomation`'s own call (combat actor vtable `+0x2C8` →
  automation manager slots `+0x08/+0x40/+0x58/+0x88`, CombatModule `0x498060`)
  disables all combat automations of one actor (code-verified; not fired
  live — the next WO's first probe), the guard-request flag keeps combat mode
  up while the stream says so, and the existing ignorant + isolation stay.
* Friendly fire: stop local *death*, keep local *hit reactions*, forward the
  hit (§2.5). Hiding the body from the world is not needed for that.

---

## 2. Phase 1 — hits carry an attacker

### 2.1 The four sinks (code-verified; RPG half by a static-RE sub-agent, then live)

| sink | native | what it gives | live |
|---|---|---|---|
| damage | RTTR `CombatSoul::TakeDamage` / Lua `soul:DealDamage(st, hp, attackerWUID)` → C_CombatSoul `+0xD8` → `+0xE0` → **ScriptedHit** `+0x168` | health loss, attacker as cause source | 100→95→90…; the victim's vanilla shout names the avatar (`COMBAT_VICTIM_SCREAM_RECEIVED_HIT; Nx: kcd2mp_7 … COMBAT_SHOUT_OPPONENT`) (observed) |
| combat history | RPGModule **`0x750e10`** `(C_CombatSoul*, S_CombatHitData*)` — only the melee (`+0x150`) and missile (`+0x158`) hit slots call it | `HasCombatHistoryWithSoul` true | 0 → **1 both ways** after one call with `{+0x00 attacker WUID, +0x10 victim WUID}` (observed) |
| skirmish | RPGModule getter `0x5d2a70` → `I_SkirmishManager` vtable `+0x10` `AddSoulToSkirmish(soul, reference, E_SkirmishRelationOverride)` (`0x645700`) | a skirmish with the pair | override 0: forms, dissolves at once (`SkirmishVictory`) — no enemies; **override 1**: the NPC's target and opponent become the avatar, `Soul kcd2mp_7 is added to the skirmish history because it became target` (observed) |
| brain aggro | brain message `hitReaction` `attacker(<WUID %lld>),hitStrength(n),hitType(n),targetOrigMat(n)` — WHGame `CGameRules::SendAISignal` `0x168690` sends it; Lua `XGenAIModule.SendMessageToEntity(wuid, type, value)` reaches the same slot (inferred) | the victim's brain learns the attacker | accepted (returns true); alone no visible victim reaction; combined with the skirmish + a damage call → `Skirmish event: HitTarget on kcd2mp_7 (target wo119_soldier)` and the melee-specific assault bark (observed) |

* TakeDamage/DealDamage with an attacker still creates **no** combat history
  (re-observed live this WO: false both ways after two calls) — WO-23's
  negative stands; the reason is now known (ScriptedHit never calls the
  history writer). (observed, code-verified)
* The Lua payload needs the attacker WUID in decimal; Lua 5.1 doubles cannot
  hold it (0x05000000000005ED = 360287970189641197). Build the string
  natively or from the WUID's hex. (observed)
* Natives for the souls: soul = actor vtable `+0x6E0`; CombatSoul = soul
  `+0x108` (vtable RPGModule `0xD69108`); `HasCombatHistoryWithSoul` =
  CombatSoul vtable `+0xD0` `(this, I_Soul*, float maxTime in XMM2)`.
  (observed)

### 2.2 The route for a remote player's hit on a local NPC (design)

On the NPC's authority machine, per attributed hit, main thread:
1. damage — today's name-addressed `TakeDamage`, now with the avatar soul as
   attacker;
2. history — `0x750e10` with `{avatar WUID, victim WUID}`;
3. skirmish — once per engagement, `AddSoulToSkirmish(victim, avatar, 1)`;
4. aggro — `hitReaction` with melee values (capture one vanilla payload first
   by hooking `SendAISignal` on a real sword hit; §2.5 captured only the
   brain-driven hitType 10).
Crime stays out of scope (shared world).

### 2.3 Player versus player (design; toggle, default is the maintainer's call)

* The single chokepoint every melee hit on a soul passes: C_CombatSoul vtable
  slot `+0x150` (RPGModule `0x70ce00`, `CombatHit(this, out cause, const
  S_CombatHitData*)`, victim WUID at data `+0x10`, attacker at `+0x00`);
  missiles `+0x158`. (code-verified; not reached in the live tests, §2.5)
* Patch the slot (vtable pointer at RPGModule `0xD69258`), filter
  victim WUID ∈ avatars:
  * friendly fire **on**: send `{attacker=local player, victim=peer,
    stamina, health, flags (+0x54 blocking, +0x59 combo, +0x65), material
    +0x4C}` to the peer, whose own `TakeDamage` applies it to **their Henry**;
    skip the local original (null-cause tolerance to be probed) or let it
    run with an `imm+upr` buff on the avatar so it cannot die/KO locally;
  * friendly fire **off**: skip the local original, send nothing.
* The field bug (avatar dies locally, host untouched) is exactly "the local
  original runs and nothing is forwarded". The `imm+upr` buff alone
  (`death_protection_cutscene` has both, WO-111) stops the local death and
  knockout without hiding the avatar (inferred from RPGModule `0x52c230` /
  `0x52fbe0` / `0x70f6b0`; not fired live on an avatar).

### 2.4 What did not happen: fight-back

Neither spawned test soul (`test_soldier_ai`, `test_cuman_ai`) entered combat
mode against the avatar within 10–15 s after damage + history + skirmish +
message; both stayed `State=1` with the avatar as opponent. They are homeless,
schedule-less spawns (`[XBehaviorUtils] … is homeless` every frame), and the
avatar is not faction-hostile to them — their reaction was the civic one
(`PRATELSKE_NPC_DOSTALO_ZASAH` "friendly NPC got hit"). When a takedown
started a real duel, the soldier did fight the avatar to 3 hp. So the engine
*can* make an NPC fight the avatar; which input flips "complain" into
"fight" (faction relation vs. the real melee signal `I_CombatActor +0x4A8`
that the sinks above do not emit) is open. (inconclusive) Needs a
world NPC in a safe spot — **needs the maintainer** (§9).

### 2.5 Henry's hits on the avatar (the friendly-fire case), solo

* Without a lock and at 1.7 m: swings never collided (no CombatModule
  collision/RPG hook fired). (observed)
* Locked (native `SetTarget`) at 1.25 m: 3–4 hits per burst reached WHGame's
  queue (`ClientHit` → `ProcessLocalHit` → `SendAISignal`), `S_HitInfo`
  attacker `0x7777` (Henry), target = the avatar, **hitType 10, strength 5
  or 2**, called from RPGModule `0x70c8c9` on XGenAI worker threads; no
  `CombatHit`, no history write, **health stayed 100**. (observed)
* Reading: these are brain-driven hit events (the avatar's combat brain
  blocking/reacting), not Henry's weapon collision; a clean body hit was not
  produced solo. The 0.28.3 peer log shows real damage and death on an
  avatar, so the damage path exists in sessions. (inconclusive for the solo
  route)

---

## 3. Phase 2 — the action map

Columns: **accept** (where the game decides it on the local player) · **inputs**
(S = replicated state, E = ordered event) · **anim read** (where the animation
system consumes them) · **apply** (avatar / NPC copy) · **cancels** (what fights
it on a remote body) · **world ID** · **outcome owner** · **probe**.
Module prefixes: C = CombatModule, E = EntityModule, R = RPGModule,
W = WHGame, A = AnimationModule, F = Framework.

### 3.1 Combat

| action | accept | inputs | anim read | apply (avatar / NPC copy) | cancels | world ID | outcome | probe |
|---|---|---|---|---|---|---|---|---|
| attack direction (combat star) | C `0x72850` SetRequestedAtkZone ← `CombatPlayerInput` (caller ret `0x34370d`); in combat `State==2` it forwards to C `0x72980` SetGuardZone | S: requested atk zone 0–5 (model `+0x200`), guard zone `+0x140`, guard stance `+0x100` | attack row tags `aZ0…aZ5`/`sZ`/`eZ` picked by the attack search (C `0x5b950`) | avatar: same setter (observed, value reads back); cosmetic swing uses the row with that `aZ` tag. NPC copy: same setter | outside combat mode only the value lands; the guard action's own update writes zone −1 (C `0x4be01`) | — | cosmetic | observed (Henry: 0/5/1/0 as the mouse moved; avatar: write lands) |
| attack (light/heavy), stab vs slash | C `0x33f3c0` PlayerController::Attack(inputClass) → C `0x5a690` CreateAttack(factory, out, ic, flags) → F `SetAction`; `SetRequestedInputClass` C `0x727f0` | E: input class (0 light,1 heavy,2 special), zone, attack type, **row GUID** (`combat_action_attack.mn_fragment_guid`) | `C_CombatActorActionAttack` (ctor C `0x84d20`, descriptor `+0x60`: fragment id `+0x0C`, 20-byte tags `+0x24`) → C `0xF3C00` anim-action queue | avatar **cosmetic**: `ParseFragmentSpec` A `0x12DB00` + `C_CombatAnimAction` C `0xF26F0` + C `0xF3C00` with the row's `"FragmentId, tags"` — per-zone variety rendered (observed). Real action: CreateAttack null; forced row enters, ends ~90 ms, nothing visible (observed). NPC copy: cosmetic route as WO-49 | weapon must be drawn (WO-45); real route: no combat mode ("No main action"), no qualifying row (factory search stops after C `0x5b950`), combat slots (C `0x80a10`) unless flag `0x2000` | opponent name (optional) | attacker's machine (name-addressed damage + §2 sinks) | observed |
| combos | C `0x5aed0` CreateCombo (from PlayerController::Attack when a combo slot is open) | E: attack event with combo step | `CombatAttackComboGen` / `CombatHitComboGen` sync rows | cosmetic: queue the combo row (paired rows need the victim side, §3.4) | combo slot timing on the remote body | victim name | attacker | code-verified |
| feint (abort) | `attack_abort` action; not traced to a function | E: cancel phase | the attack action ends | send `phase=Cancel`; receiver stops queuing | — | — | — | (inconclusive) |
| master strike | C `0x33f8c0` → C `0x73ee0` → `RequestAction(ca, type, 0, 0, ic)` C `0x76500` when model `+0xA60` (MS slot count) > 0 | E: master strike (paired) | `CombatStopMaster`/`CombatMasterStrikeGen` rows | cosmetic paired rows; the NPC victim side via its own director (WO-42 pairing) | needs an open slot on the *remote* opponent; metadata table (WO-42 §5.3) | victim name | attacker | code-verified |
| guard / block (held) | RMB → C `0x72eb0` SetBlockMode(on=1, scope 0) (ret `0x340722`); release → SetBlockMode(0) (`0x33dee0`) | **S**: block mode (5 per-scope bytes model `+0x860…+0x864`, max `+0x865`) | on a transition SetBlockMode creates a block-mode action and `SetAction` → `C_CombatActorActionBlockTrigger` at director scope 3 | avatar: needs combat mode first (below); then SetBlockMode(1) holds a BlockTrigger at scope 3 (observed, persists 4 s+); outside combat mode: no action, nothing visible (observed) | combat mode ending; automation | — | defender's machine for the block result (see perfect block) | observed |
| combat mode (stance) | player: C `0x71a80` TryStartCombatMode (combat actor vtable `+0x360`) → StartCombatMode `+0x6D0` (C `0x70890`) | **S**: in combat, weapon drawn | guard + guard-movement + pose-modifier actions (vtables C `0x5c2800/0x5c2550/0x5c1740`) | avatar: vtable `+0x360` then **guard-request flag** `SetFlag(model+0xEE8, 4, 1)` (C `0xF4C20`) → holds; visible guard stance (observed) | C `0x6f660` PostUpdateActor ends combat when no request flag is set and the main action allows it | — | — | observed |
| perfect block | automation `C_CombatAutomationPerfectBlock::OnSlotStart` → RequestAction(14…) | E: timed block within the attacker's slot | `CombatBlockPerfectGen` / `…SyncGen` | cosmetic one-shot `CombatBlockGen`/`CombatBlockPerfectGen` row on the avatar (a block gesture rendered, observed); outcome decided on the attacked machine | slot windows (~0.06–0.9 s) never align across a network | — | defender | observed (gesture) / code-verified |
| riposte | `RiposteState` model `+0x4C0`; `CombatAttackRiposteGen` rows | E | rows | cosmetic | slot | victim | attacker | code-verified (strings/rows only) |
| dodge | automation / test `combat_DodgeAction` (C `0x48ebb0`); player move-back input class 5 | E: dodge dir | `CombatDodgeGen` rows (`move_back` etc.) | cosmetic row | position stream moves the body anyway | — | cosmetic | code-verified |
| shield | tags `l_shield`, guard type `freeBlockShieldUp` (19) | S: shield raised | guard/block rows with `l_shield` | rides block mode | — | — | — | (inconclusive) |

### 3.2 Ranged

| action | accept | inputs | anim read | apply | cancels | world ID | outcome | probe |
|---|---|---|---|---|---|---|---|---|
| bow draw | LMB hold → E `0xbbc1d0` `C_ActorShootingExpansion::StartMain(mode 2)` (caller E `0xb0b6f2`); expansion via actor vtable `+0xA10` (vtable E `0xEA45F0`); slot `+0xB8` = draw | E: press | Charging / InstantCharging sub-states | avatar: expansion reachable (StartMain entered on the avatar) but the bow was not in hand → faulted (caught) (observed) | item in hand (`OnItemInHandChanged` resets), action director acceptance | — | — | observed (Henry) / inconclusive (avatar) |
| hold / aim | Charging sub-state: charge `+0xB0` (min `+0xC0`, max `+0xC4`); aim read at fire time from actor `+0x1E8` provider | **S**: charge 0–1, aim yaw/pitch | Mannequin params (`C_ActorShootingUtils::GetMannequinParams`) | set the aim provider / look target on the body (unproven); `combat_SetAim` test command is the shipped example (C `0x49b1d0`) | the NPC's own look/aim | — | — | code-verified |
| release | release → Firing (vtable E `0xD71130`) → anim event → `Fire` E `0x198ef0` → `C_ActorShootingUtils::Shoot` E `0x1a3d90`; expansion slot `+0xD0` = release | E: release (+ charge) | `afterShot` tag | cosmetic draw/release on the avatar once the bow is in hand; **do not spawn the projectile remotely** (Shoot spawns a real arrow and makes noise/perception) | double arrows if the remote Shoot runs | — | shooter's machine (hit as a missile hit, slot `+0x158`) | observed (Henry: StartMain, Fire, Shoot captured) |
| crossbow / gun | same expansion; Main's instant path E `0x19a900` fires without a Firing state (weapon class `+0x9e`); inputs `crossbow_prepare/execute/abort`, `gun_*` (WO-47 §6) | E: prepare / execute / abort | shooting sub-states | as bow | reload state | — | shooter | code-verified |

### 3.3 Movement

| action | accept | inputs | anim read | apply | cancels | world ID | outcome | probe |
|---|---|---|---|---|---|---|---|---|
| walk / run / sprint | player HSM ground state → E `0xcbd80` FinalizeMovementRequest (caches requested velocity at actor `+0x574`) | **S**: planar velocity (speed + heading vs facing) | E `0x94750` (UpdateMannequinTags equivalent) → E `0xc0120` GetCurrentLogicalSpeedTag; speed = pseudo-speed (actor `+0x7E8` → `+0x18`) or requested velocity; **capped by the body's real speed** | avatar: per-frame `SetPseudoSpeed` E `0x978f0` while the stream moves the body → `walk`/`run`, `forward`/`backward`, footfalls, `MotionMovement` (observed); stationary + pseudo-speed → nothing (observed). NPC copy: WO-116 R1 movement requests, or the same pseudo-speed on the native writer's bodies | the NPC's own movement controller rewriting `+0x574`; real-speed clamp | — | cosmetic | observed |
| crouch / sneak | `toggle_crouch` → state expansion (actor vtable `+0x980` → E `0xcf3e0`) slot `+0xE8` SetCrouch(want, force) E `0x1a6ce0` → `C_ActorActionCrouch` | **S**: crouched | Stance tag `stealth` | avatar: SetCrouch(1,0) → `stealth` set, held 7 s+, `GetCrouch` slot `+0xF0` = 1; holsters the weapon (observed); body looked upright in the one frame taken (inconclusive) | blockers (actor vtable `0xaf8/0x420/0xa78`), no room | — | — | observed (tag) |
| jump | HSM ground state E `0xc9590` → state expansion slot `+0x100` RequestJump E `0x1a64d0` → action type 9 | E: jump | `MotionJump`/`MotionLand` | avatar: RequestJump → true, `MotionJump>MotionLand`; rise held to 0.06 m by the stream's position write (observed) | restriction flags, crouch, mount; the stream's Z | — | cosmetic | observed (avatar, Henry by key) |
| vault / ledge | `CActionLedgeGrab`; nearest-ledge E `0xc3630` | E + **world ID** | `JumpOver` fragment | re-query the nearest ledge at the same position, or send the LedgeId | alignment interrupted by requested velocity/jump | LedgeId (grid index, per level build) or position | cosmetic | code-verified |
| ladder | action type `0x22` (`C_ActorActionLadder::EnterImpl` E `0x15dc90`) | E + **world ID** | ladder states | push action `0x22` with the ladder's EntityId; claim via `C_LadderManager` | ladder claimed/used; invalid entity | ladder **EntityId** (authored ids are stable, WO-109) | cosmetic | code-verified |

### 3.4 Takedowns and bodies

| action | accept | inputs | anim read | apply | cancels | world ID | outcome | probe |
|---|---|---|---|---|---|---|---|---|
| stealth knockout / kill | `stealth_kill`/`knock_out` input; Lua `actor:RequestKnockOut(victim)` / `RequestStealthKill` → E `0xb29ef0` → combat component mode 4 / 3 | E: attacker, victim, kind | paired rows `CombatStealthAttackSuccess` / `CombatStealthHitSuccess` (two directors, WO-42 pairing) | **avatar as attacker: works** — real clinch + sync perfect-block duel on a test NPC (observed). NPC copy as victim: the same Lua on the attacker body | victim state / awareness; the victim's perfect block (happened); vanilla metadata gaps (`Meta data for asset is missing … CombatBlockPerfectHitSyncGen` logged) | victim entity **name** | the victim's authority machine decides KO/kill (RPG `0x52fbe0` / `0x70f6b0`, cause = attacker) | observed |
| finishing (mercy kill) | `mercy_kill`; Lua `RequestMercyKill`; C `0xd7af0` ("Unable to create mercy kill action") | E | `CombatAttackMercy` rows | as takedown | victim not downed | victim name | victim's authority | code-verified |
| carry | `grab_body`; Lua `RequestGrabCorpse(victim)` → carry component (actor vtable `+0x838`) → state expansion E `0x1a60f0` → action `0x23` on the carrier, `0x24` on the victim; victim hung on the carrier's attachment | **S**: carrying `victim` (relation at actor `+0x844`) | stance layer 2 = 9 (`carryCorpse`), master/slave | **avatar: works** — `IsCarryingCorpse` true, body 0.21 m / +0.79 m, `MasterSlaveManager … 'kcd2mp_7' -> body`, follows the stream-moved carrier (observed) | victim ragdoll/state; carrier related to another entity; riding shares the `+0x844` slot | victim **name** | **the carrier owns the body while carrying** (settled rule): the carrier's machine streams it; on the other machine the carried copy is attached, not streamed | observed |
| drop | Lua `RequestPutCorpse()` → carry slot `+0x50` → release/detach E `0xaa410` / `0xa8f70` | E: drop (+ position) | `carryCorpsePutdown` | avatar: works — carrying false, body on the ground (observed) | action exit (interrupt, save load) | victim name | carrier's machine, then back to the body's authority | observed |

The joiner-carry gap from the 0.28.3 field test is structural: under host
authority the joiner's drag detection is off, so nothing streams the body.
With this map the carrier's side emits `carry(victim)` / `put(victim, pos)`
events and the other side runs the same two Lua binds on the avatar.

### 3.5 Horses (noted, not chased)

Actor action types `0x29–0x2c` mount/dismount (+slave), `0x2f/0x31` rider/horse
sync; the mount relation uses the same actor `+0x844` slot as carrying
(code-verified by the static sub-agent). The avatar-stays-mounted bug is
WO-120's.

---

## 4. Phase 3 — the live probes

| probe | body | result | cancelled by | evidence |
|---|---|---|---|---|
| directional attack (not the canonical swing) | avatar | aZ0 overhead head slash, aZ2 right slash, aZ5 thrust from `CombatAttackGen` rows (fragment 897 + tags) | — (weapon drawn) | observed, screenshots |
| real attack action | avatar | CreateAttack null (in and out of combat mode, flags 0 / `0x2000`, ic 0/1/2); forced row: enters, done in ~90 ms, no swing | row search; combat mode; (inconclusive for the forced row) | observed |
| block held as state | avatar | outside combat mode: nothing; inside (flag + `+0x360`): guard stance visible, `BlockTrigger` held at scope 3 | combat termination without a request flag | observed |
| guard zone change | avatar | 1 → 5 reads back; pose not visibly different at 4 m | guard action rewrites zone −1 | observed / inconclusive |
| jump | avatar | `MotionJump>MotionLand`, rise suppressed by the stream | stream Z | observed |
| crouch as stance | avatar | `stealth` tag held; weapon holstered; pose not confirmed | — | observed / inconclusive |
| bow draw → release | Henry | StartMain(2) → Fire → Shoot captured, `afterShot` tag | a one-time tutorial popup (first try); arrows must be equipped | observed |
| bow draw → release | avatar | expansion reached, calls faulted | bow not in hand after `DrawFromInventory` | observed / inconclusive |
| velocity with position | avatar | gait follows pseudo-speed only while the body moves | real-speed clamp | observed |
| takedown | avatar → test NPC | stealth clinch, victim perfect-blocked, real fight | victim's perfect block | observed |
| carry / drop | avatar | carry, follow, drop | — | observed |

Triggering method: Henry's actions by synthetic keyboard/mouse (SendInput scan
codes to the focused window — space, c, b, tab, LMB/RMB, mouse moves) worked;
`actor:SimulateOnAction("jump",…)` is registered but did nothing (observed).
Remote bodies were driven only by native calls and shipped Lua binds.

---

## 5. Phase 4 — the wire (design; protocol v7 → **v8**)

Principle: replicate the inputs the engine consumes (state) and the decisions
it makes once (events); never clips. Every enum crosses by **name or authored
GUID** (WO-100 §6.5), never engine ids.

### 5.1 Replicated state — on the Position/Ghost frame (flag `0x10` BODYSTATE2)

Sent at the position cadence (30 ms native, ≤ 2 s heartbeat when still),
change-gated per field group; a late joiner gets it with the next position.

| field | bytes | source (sender) | receiver |
|---|---|---|---|
| planar speed | 2 (cm/s) | player: requested velocity actor `+0x574` (C_Player overrides pseudo-speed, WO-100 §10.3) | `SetPseudoSpeed` every frame at the frame hook |
| heading − facing | 1 (1.4°) | same | direction via the body's own facing + move vector |
| combat mode | bit | model `+0x0` CombatMode | `+0x360` + guard-request flag scope 4 set / cleared |
| weapon set | 1 | existing draw events | unchanged |
| guard zone / stance | 1+1 | model `+0x140`, `+0x100` | SetGuardZone |
| requested attack zone | 1 | model `+0x200` | SetRequestedAtkZone (and picks the swing row's `aZ`) |
| block mode | bit | model `+0x865` | SetBlockMode(scope 0) |
| crouch | bit | stance tag `stealth` / GetCrouch | SetCrouch |
| carrying | 1 + name ref | IsCarryingCorpse + victim | RequestGrabCorpse on start (event) |
| aim (ranged, while drawn) | 2+2 (yaw/pitch) + 1 charge | aim provider, Charging `+0xB0` | aim provider / cosmetic only |

≈ 10–14 bytes when present; the WO-100.5 `0x04` block (pace/dir/stance/speed)
is superseded by it.

### 5.2 Events — the ActionUp/ActionDown channel (`0x3B`/`0x3C`), new kinds

Ordered per `(sender, kind)` by `seq`, validity by `gen` (both already on the
channel); the sender clock rides the position frame. Late events (older than
the body's current incarnation, or > 1 s behind the sender clock) are dropped
and counted.

| kind | phase use | payload |
|---|---|---|
| Attack (1, extend) | press / commit / cancel | input class, zone, attack type (names), **row GUID** 16, opponent name |
| Jump (2, now sent) | commit | — |
| Block impulse (6) | commit | block zone, perfect flag |
| Dodge (7) | commit | direction (input-class name) |
| Ranged (8) | press = draw, commit = release, cancel | weapon family, charge u8, yaw/pitch |
| Takedown (9) | commit | kind (knockout/kill/mercy), victim name |
| Carry (10) | commit = grab, complete = put | victim name, put position |
| Traverse (11) | commit | ladder entity name / ledge position |

### 5.3 Attributed hits

* PvE: extend `0x30/0x31` NpcDamage with an attacker-present flag and the
  sender's player id → the NPC's authority applies §2.2's four steps.
* PvP: new pair **`0x44`/`0x45` PlayerHitUp/Down** `[victimPlayerId:1][stamina:4f][health:4f][flags:1][material:1]`
  (fixed 11 / 12), sent by the attacker's machine from the `+0x150` slot
  filter when friendly fire is on; the victim's machine applies it to its own
  Henry with the avatar as attacker.
* Protocol bumps to **v8** (standing rule since WO-110); the relay's
  exact-length gate takes the new lengths from one list (WO-101).

Sizes/rates: state adds ≤ 14 B at ≤ 33 Hz while changing; events are
bursty (a fight: ~2–4/s per player, 20–40 B each).

---

## 6. The build plan — three WOs, in order

Effort as relative size (S = the WO-118 follow-ups, M = WO-118, L = WO-113).

### WO-A — combat (L)
Depends on nothing new; needs the native writer (0.28.x) and KCDMP.dll.
1. Phase 0 body: keep the ghost; native automation-off (`0x498060` path),
   guard-request flag + `+0x360` from streamed combat mode; first probe:
   automation-off + held combat mode on a live ghost for 60 s.
2. Phase 1 attacker: §2.2 on the NPC authority; `hitReaction` values from one
   captured vanilla hit; fight-back test on a world NPC with the maintainer.
3. PvP: `+0x150` vtable-slot filter, friendly-fire toggle, `0x44/0x45`,
   `imm+upr` on avatars as the no-hook fallback.
4. Melee look: cosmetic rows by GUID (sender reads the committed
   `C_CombatActorActionAttack`'s descriptor → row GUID; receiver queues
   fragment + tags); zone/guard/block state; one-shot block/perfect-block/
   dodge rows.
5. Ranged look: get the bow into the avatar's hand first (the WO-47 polearm
   lesson), then expansion draw/release cosmetically, never `Shoot`.
* **Avatar first, NPC copies second.** Harder for copies: their brains are
  suspended (WO-107), so combat mode needs the same request flag and the
  pause must not cancel the combat actor; their swings already ride WO-49.

### WO-B — movement and traversal (M)
Depends on WO-A's state block (shared frame flag) only for the wire.
1. Velocity → gait: per-frame `SetPseudoSpeed` on every native-written body
   (avatar and copies) from the streamed speed.
2. Crouch state; jump event (engine anim, stream keeps Z).
3. Ladders by entity name; vaults by position (re-query).
* Harder for copies: WO-116's R1 movement requests already give real gait
  for suspended NPCs; choose per body which of pseudo-speed or R1 drives it.

### WO-C — takedowns and bodies (M)
Depends on WO-A (attribution) and WO-B (carry follows gait).
1. Carry ownership rule: the carrier owns the body while carrying
   (like a ridden horse); `carry`/`put` events; the joiner-carry gap closes.
2. Takedowns: attacker's machine sends `takedown(victim, kind)`; the
   victim's authority runs the same Lua bind on the avatar body and decides
   the outcome (the paired rows animate on both sides).
3. Mercy kill, finishing.
* Harder for copies: a suspended victim has no reactions — the pair must be
  driven from the attacker side only (the victim's director gets the hit
  action, WO-42 pairing).

Total ≈ L + M + M, in that order; each can ship on its own.

---

## 7. Address index (this build)

| what | where |
|---|---|
| PlayerController::Attack(inputClass) | C `0x33f3c0` |
| attack factory CreateAttack / CreateCombo | C `0x5a690` / `0x5aed0` |
| attack search (row candidates) | C `0x5b950` |
| `C_CombatActorActionAttack` ctor / EnterImpl / vtable | C `0x84d20` / `0x44300` / `0x5c3b18` |
| priority setter | C `0x8cd70` |
| SetRequestedAtkZone / SetGuardZone / guard-zone raw writer | C `0x72850` / `0x72980` / `0x72df0` |
| SetRequestedInputClass | C `0x727f0` |
| SetBlockMode(on, scope) | C `0x72eb0` |
| RequestAction(ca, out, type, zone, hand, p6) | C `0x76500` |
| TryStartCombatMode / StartCombatMode | combat actor vtable `+0x360` (C `0x71a80`) / `+0x6D0` (C `0x70890`) |
| PostUpdateActor (combat termination rule) | C `0x6f660` |
| SetFlag(flags, index, value) on model `+0xEE8` | C `0xF4C20` |
| SetTarget | combat actor vtable `+0x210` |
| automation manager / enable-automation body | combat actor vtable `+0x2C8` / C `0x498060` |
| C_CombatPlayerController vtable | C `0x612a68` |
| C_CombatActor vtable | C `0x5bf030` |
| test commands (Execute = slot `+0xE0`) | `C_SetRequestedAttackZone` `0x49faf0`, `C_SetGuardZone` `0x49e380`, `C_SetGuard` `0x49cf60`, `C_SetBlockMode` `0x49c0e0`, `C_SetTarget` `0x4a05f0`, `C_SetAim` `0x49b1d0`, `C_EnableAutomation` `0x497bc0`, attack/block/… common `0x489c80` |
| actor → combat actor / actor by entity id | actor vtable `+0x970` / GameIface `+0x188` vtable `+0x18` |
| `C_ActionDirector::SetAction` | F export `0x171c0` |
| cosmetic swing: ParseFragmentSpec / anim-action ctor / queue | A `0x12DB00` / C `0xF26F0` / C `0xF3C00` |
| combat RPG hit processing | C `0x372120` ("RPGProcessHit") ← collision process C `0x163b30` / `0x164630` |
| `CGameRules::ClientHit` / ProcessLocalHit / SendAISignal | W `0x167d20` / `0x1683e0` / `0x168690` |
| C_CombatSoul vtable; CombatHit / MissileHit / HasCombatHistory | R `0xD69108`; `+0x150` `0x70ce00` / `+0x158` / `+0xD0` `0x70bf20` |
| combat history writer | R `0x750e10` |
| skirmish manager getter / AddSoulToSkirmish | R `0x5d2a70` / vtable `+0x10` `0x645700` |
| SetPseudoSpeed / GetPseudoSpeed | E `0x978f0` / `0x97970` |
| UpdateMannequinTags / GetCurrentLogicalSpeedTag | E `0x94750` / `0xc0120` |
| state expansion: holder / resolver / SetCrouch / GetCrouch / RequestJump | actor vtable `+0x980` / E `0xcf3e0` / slot `+0xE8` `0x1a6ce0` / `+0xF0` / `+0x100` `0x1a64d0` |
| shooting expansion / StartMain / draw / release / Fire / Shoot | actor vtable `+0xA10` (vtable E `0xEA45F0`) / E `0xbbc1d0` / slot `+0xB8` / slot `+0xD0` / E `0x198ef0` / E `0x1a3d90` |
| stealth routing / grab / put (scriptbind targets) | E `0xb29ef0` / `0xb2a4d0` / `0xb2a610` |
| soul / CombatSoul from an actor | actor vtable `+0x6E0` / soul `+0x108` |

Combat model properties used (base `model = combatActor+0x2F0`, each names
itself at `+0x30`): CombatMode `+0x0` (bool), State `+0x40`, GuardType
`+0x80`, GuardStance `+0x100`, GuardZone `+0x140`, RequestedAtkZone `+0x200`,
RequestedInputClass `+0x300`, opponent pointer `+0x1118`.

---

## 8. Corrections and additions to the record

* **WO-100.5 §2.3 "the block action is refused on the player; untried on an
  NPC":** the refusal is structural — RequestAction/automations fire only in
  open combat *slots*, and the held block is a different mechanism
  (`SetBlockMode`, a state with per-scope requesters). (code-verified,
  observed)
* **WO-100.5 §1.4 "NoAI keeps hit registration":** true for direct hits
  (their count); but a `NoAI` body is refused by `AddSoulToSkirmish` and has
  no AI object. (observed)
* **WO-107 "SuspendedAI is the spawn-time form of the suspend":** on this
  build the flag did not keep the brain off. (observed)
* **WO-23 attribution negative:** reproduced, and explained — TakeDamage goes
  through ScriptedHit, which never writes history; the writer is R
  `0x750e10` and it works when called. (observed, code-verified)
* **kcd.log "Requested combat termination: No main action"** is printed on
  the "no request flag and the main action allows it" branch too; it does not
  mean the director is empty. (code-verified, observed)
* **WO-44 "direction B" and WO-45/46:** still the right cosmetic route; the
  row tags carry direction — the one-row-for-all-swings limit was the choice
  of row, not the route. (observed)
* `actor:SimulateOnAction` is registered and does not drive player input on
  this build (observed); synthetic keyboard/mouse does.
* The retail lead names (`SetCombatZone`, `RequestGuard`, `BeginAttack`,
  `PerformAttack`, `UpdateMannequinTags`, `FireWeapon`) have **no string
  anchors** in this build; their equivalents above were found by the test
  harness, RTTI and live capture. (code-verified)

---

## 9. Needs the maintainer

1. **Fight-back test on a world NPC** in a spot with no witnesses: §2.2's four
   steps with a peer's avatar as attacker; does the NPC fight the avatar?
   (The session rules forbade aggroing townsfolk.)
2. **Friendly-fire default** (on/off) — the maintainer's call (§2.3).
3. **One vanilla sword hit on an NPC** with a `SendAISignal` hook, to capture
   the melee `hitType`/`hitStrength`/material values for `hitReaction`.
4. **Two-player**: everything.
