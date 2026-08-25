# WO-57 — how close can "play the story together" get? (design document)

Worked 2026-08-25 (Fable 5). Design document only — no code, no prototypes, no
VERSION change. Evidence tiers used throughout: **observed** (run live or read
from the shipped binaries/paks this session, file named) /
**read-but-unrendered** (a mechanism read in code/docs, never executed) /
**inconclusive** — never rounded up. The game was NOT running this session
(REST :1403 probed, timed out), so every new claim here is static: shipped
DLL strings, shipped pak scripts, shipped vendor docs, and this repo's own
code. Anything that needs a running game is explicitly listed as a live-gated
probe for a follow-up.

**The framing, applied throughout** (`docs/WO-57-mmo-reference.md`): a good
shared world is *selective* — world, combat, and activities shared; quest
progression, reputation, and story state personal. This project drew that
boundary correctly in `ARCHITECTURE-shared-world.md` (generic/shared vs
unique/personal) and it is re-applied per phase below, including where the
honest answer is "leave this individual."

**Corrections to the prompt's premises, found before Phase 1:**

- There is **no `docs/WO-33-findings.md`** in this repo and never was. The
  dice `OverrideNextThrow` corpus is WO-23 → WO-24 → WO-25 (7 shapes across
  two sessions, WO-25's table is the authority). Nothing is lost; the prompt's
  citation is just misnumbered.
- **WO-54 (the live two-human session) never happened.** It fell through
  because the joining player's DDNS hostname was rejected by the launcher's
  Add Server validation (`WO-55-findings.md` §"Why this existed" — observed).
  WO-55 fixed the launcher; the session itself was never re-run and produced
  no findings doc. Phase 3 below therefore treats WO-51's recommendation as
  the standing plan, per this WO's own instruction.

**Presence (pre-existing, not a phase):** unchanged and confirmed current
through 0.17.1 — position/rotation ghosts at 50 ms, gear (0x1A appearance),
soul-roster faces, nameplates, native per-weapon swings (WO-47), Discord
presence and HUD release-toggle (WO-50). Nothing regressed in WO-51–56 (all
design/research WOs; WO-55 touched only the launcher's address validation).

---

## Phase 1 — native dice, revisited with the WO-42–49 toolkit

### 1.1 What was true before this session

- `Dice.SetScore` / `HoldDie` / `RollDie` all **observed** producing real
  changes in the native minigame (WO-24): SetScore is *additive* to the
  banked total; HoldDie visibly selects a die; RollDie silently re-rolls one
  individual die's face (1→4, no animation).
- `Dice.OverrideNextThrow(playerIndex, dieValues)` — 7 structurally distinct,
  engine-accepted table shapes, zero observed effect (WO-25 Phase 1). The
  validator leak recovered the real parameter names. The standing open
  question is **shape vs lifecycle/timing** — the auto-roll fires with no
  player-controllable "about to cast" moment, so every call may have expired
  or been overwritten before the roll it targeted.
- The reflection route to dice state is **closed definitively**
  (WO-6-native-dice): `C_UIDice` is a push-only presentation sink with zero
  reflected properties; `wh::playermodule::C_Dice` is real but NOT
  rttr-registered; the `SetPauseWorldTime` inline hook installed cleanly and
  never fired during ordinary NPC gambling.

### 1.2 New this session — the anchors exist, and so does a start call nobody probed

All **observed (static)**, read from the shipped Modding Tools files today:

1. **The dice scriptbind and controller live in `PlayerModule.dll`** and are
   fully anchored for the WO-42 method: RTTI
   `.?AVC_ScriptBind_Dice@playermodule@wh@@`, `__FUNCTION__` strings
   `wh::playermodule::C_Dice::StartDice`, `::OnGameStateChanged`,
   `::SetSelectedDie`, `::InitActorPositions`, `::NotifyAudioSystem`,
   `::OpenInventory`, `::ReadjustActorPosition`, plus the literal Lua
   registration string `"playerIndex, dieValues"`. WO-6's era had none of
   this method; WO-42–44 proved functions in these DLLs self-identify.
   **Recovering `OverrideNextThrow`'s real table shape AND its
   consumption timing is now a bounded static-disassembly job**, not
   guesswork: decompile the scriptbind method (read which keys it extracts
   from the SmartScriptTable and where it stores them), then xref that
   storage to its consumer inside the roll path (anchored by
   `C_Dice::StartDice`/`OnGameStateChanged`). The Ghidra headless pipeline
   this needs is already installed and proven (WO-6 addendum, WO-42–44).
   Note the irony: WO-6 closed `C_Dice` as "probably a different dice
   context" — the `StartDice` `__FUNCTION__` string found today says it IS
   the game controller; what never fired was one specific method
   (`SetPauseWorldTime`), not the class.

2. **A direct minigame start call exists, Lua-documented, with an explicit
   opponent parameter.** From the shipped scriptbind docs (extracted today)
   and the shipped `DiceInteractor.lua` (Scripts.pak):

   - `Minigame.StartDice(tableId, playerId, opponentNpcId)` — all three are
     entity ids.
   - `Minigame.StartDiceWithScore(tableId, playerId, opponentNpcId,
     targetScore)`.
   - `Minigame.StartDiceByName(name)` — present as a commented-out line in
     `DiceInteractor.lua` itself (`Minigame.StartDiceByName("test_dice01")`).
   - `Minigame.CanUseMinigame(playerId, filterMask)` — the gate the game's
     own interactor uses; the filter mask disables individual blockers
     (combat danger etc.).

   The shipped start flow is: DiceInteractor's `OnUsed` →
   `XGenAIModule.SendMessageToEntity(linkedNpc, "dice:init",
   "forceDialog(true)")` — i.e. vanilla starts dice **through the linked
   NPC's dialogue**, which is why no prior WO ever saw a start call: the
   Dice.* binds probed in WO-23–25 are the *mid-game* controls. `StartDice`
   bypasses the dialogue and takes an arbitrary opponent entity id.
   **Whether `Minigame` is registered in this build's sandbox and whether
   `StartDice` accepts a ghost as `opponentNpcId` are untested** — the
   standing trap (documented ≠ registered ≠ effective: `Dice.GetDice` was
   documented and nil; `GameRules` is documented and nil) applies with full
   force. But `DiceInteractor.lua`/`AlchemyTable.lua`/`Smithery.lua` all call
   `Minigame.CanUseMinigame` in the same Lua state the mod runs in, so the
   table itself must exist at runtime. Registration of the Start* methods is
   a 2-minute live probe.

3. **The PvP-only dice table (the human's idea).** `DiceInteractor` is a
   plain Lua script entity (`Entities/DiceInteractor.ent` → 1.9 KB
   `DiceInteractor.lua`, derives `UsableItem`, model
   `dice_board.cgf`, no C++ item-attach step). This is the *good* half of the
   WO-48 lesson: `PickableItem` spawn failed because its item is "attached
   from C++"; DiceInteractor has no such hidden half visible in its script —
   but `StartDice(tableId, …)` may still validate the table against
   something (a linked NPC, a smart-object seat from
   `AI/world/so_diceTable_new.xml`, interior placement). **Verdict:
   plausible, spawn-recipe unknown, one live session to answer** — spawn a
   `DiceInteractor` shell at a position, then call `StartDice` naming it.
   Worth noting the interference argument for a separate table is weaker
   than it looks: `StartDice` at an *existing* table also never touches the
   NPC dice economy (the NPC game is dialogue-initiated and per-world). What
   the spawned table actually buys is **placement anywhere and guaranteed
   vacancy** — a real but smaller win.

### 1.3 What is achievable now that wasn't, and what still isn't

**Now achievable (with named methods):**

- Recovering the `OverrideNextThrow` shape/timing answer by disassembly —
  bounded, anchored, offline (no live game needed for the read itself).
- Probing a native two-human match shape that was invisible before:
  `StartDiceWithScore(table, me, ghostOfOtherPlayer, target)` on both
  machines, mod drives the "NPC" side of each board from the remote human's
  real actions. `SetScore` (verified additive write) plus `SetAIDifficulty` /
  `SetAIRiskTaking` (registered, untested effect) are the levers already in
  hand; forced die faces still gate full fidelity.
- Live testing is drastically cheaper than in WO-23–25: loadfile
  section-injection (WO-48) and the retail RemoteConsole (WO-43) mean no pak
  rebuild per iteration.

**Still not achievable / unknown:**

- Forcing individual die faces — until the disassembly answers shape vs
  timing, this remains the one blocker to "both players see the same
  physical rolls." If timing is the problem, the fix may need a native hook
  at the pre-roll moment (invasive, WO-6's dice-hook discipline applies).
- Whether the native minigame will accept and animate a ghost opponent at
  all (seat alignment via `InitActorPositions`/`ReadjustActorPosition`
  suggests the opponent needs to be seatable).

**Shared-vs-individual verdict:** a dice match is a *shared activity between
two consenting humans* — exactly the kind of thing that should be synced, and
the NPC dice economy (winnings, badges, quest dice) stays personal by
construction because nothing in this design touches it. The WO-49 payout
lesson (money in decagroschen, `inventory:CreateItem`) already covers the
wager mechanics. **Recommended follow-up: one static-disassembly session
(OverrideNextThrow + StartDiceInner) before any live probing** — it answers
shape, timing, and the `[options]` table of `StartDice` in one pass.

---

## Phase 2 — fluid animation: ranged weapons and swing zones

### 2.1 Ranged (bows, crossbows, guns)

Groundwork (WO-47 §6, all observed): drawn-state sync already works for all
three families; the full input vocabulary reaches the Lua OnAction hook
unmapped (`bow_primary`/`bow_primary_release`,
`crossbow_prepare`/`execute`/`abort`, `gun_prepare`/`execute`/`abort`);
a bow can leak fake melee `combat swing` events (silent no-op on receivers).

What a ranged-visibility WO would build (design, not built):

- **Wire:** extend the 0x2C combat-event byte space (today 0=drawn,
  1=sheathed, 2=swing, 3=block — `kdcmp.lua:3862`) with
  prepare/execute/abort per family, mapped 1:1 from the recorded action
  names. Trivial, additive, no protocol bump (the standing idiom).
- **Render route — the honest unknown.** There are **no FreeAttack rows for
  missile classes** (WO-47 §2, observed) — correctly none; shooting is not a
  melee fragment. The render route must come from a different fragment
  family (aim/shoot fragments whose `mn_fragment_id` vocabulary nobody has
  enumerated yet — the §9.2 extraction only covered the attack tables), or
  from the same native QueueAction path with a shoot-action descriptor.
  The WO-47 polearm lesson is the method: check what actually renders on a
  ghost before trusting any equip/pose call.
- **Projectiles:** `CProjectile` is a real GameObject-extension class
  (EntityModule RTTI, WO-52 — observed). Whether a mod can spawn a flying
  arrow with a trajectory is completely unprobed. The honest v1 is: aim pose
  + shot cue + (already-working) damage over the ghost-health sensor; a
  visible projectile is polish, and impact-point fidelity would be
  approximate anyway (the shooter's world decides the hit).
- Also fix the recorded bow leak (suppress melee-named actions while a
  missile weapon is drawn) — one guard clause.

**Cost/benefit: the best ratio in this WO.** The input vocabulary is already
recorded, the wire idiom exists, and the only research risk is the render
route — one live enumeration session (what does a bow-draw fragment look
like on a ghost). Fully shared-appropriate: this is combat visibility, the
same category the project has synced since WO-39.

### 2.2 Swing direction / attack zones

- The tables are zone-tagged and shipped: `eZ1`/`aZ2`-style tags on real
  attack rows (WO-42 §9.2, observed), and WO-47 §8 explicitly left "mirror
  the attacker's real sZ/aZ" open pending an emitter that reports zones.
- **The gap is entirely on the emit side.** Today's swing detection is the
  OnAction hook — `combat swing` carries no direction; KCD2's attack zone
  comes from mouse position at commit, which never surfaces as an action
  name. Nothing in the registered Lua surface reads the player's current
  attack zone (no such method appears in the scriptbind docs; checked the
  method listings this session — read-but-unrendered).
- **The native route exists and is anchored:** the attacker's own machine
  holds the truth in its combat action pipeline. Two shapes, in escalation
  order: (a) *read* — walk the local player's
  `GetOrCreateCombatActor` (EntityModule RVA 0x92260, decompiled WO-44) →
  `CombatAnimActionManager` (0xF3C00) → current action's descriptor row,
  poll it on swing; (b) *hook* — the QueueAction slot (AnimationModule RVA
  0x20410 slot[1], WO-42) on the local player captures every real combat
  action with its full fragment+tags at the moment it is queued. (b) is
  strictly better data at strictly higher risk (an inline/vtable hook on a
  hot path vs a poll). Either way the wire then carries the row identity
  (fragment id + tags, or an index into the shipped table), and the receiver
  plays the exact row through the existing `ghost_swing` — which already
  accepts an arbitrary fragment spec (WO-47: "the DLL's ghost_swing already
  took an arbitrary fragment spec").
- **Payoff honestly stated:** today's swing already rotates slash/stab per
  weapon class and the human verdicts were "it worked" ×4. Zone mirroring
  upgrades "a real swing of the right weapon" to "the actual attack you
  made." Visible mainly to a player watching closely or fighting the ghost
  (dueling — Phase 6 makes this more valuable than it was).

**Verdict:** ranged first (cheaper, bigger visible hole), zones second, and
zones become a natural sub-task of the Phase 6 duel WO if that proceeds —
duels are where swing fidelity is actually watched.

---

## Phase 3 — shared combat and fully synced NPCs

Per this WO's instruction, WO-51 was read in full and is not re-derived.
Status check performed:

- **WO-54 did not happen** (see corrections above). There is no live
  two-human data newer than the single 2026-08-18 footage paragraph WO-51
  §1.5 already accounts for. Nothing updates the recommendation.
- **WO-52/53/56 (all post-WO-51) each narrow the option space in WO-51's
  favor:** WO-52 killed the "use CryEngine's own netcode" escape hatch
  (nothing this project needs implements NetSerialize — observed); WO-53
  confirmed no headless mode exists in any KCD2 build (keeping option 4
  dead); WO-56 killed the "second real Henry" variant and *strengthened* the
  Flow B priority — the wire hop is topology-required no matter what entity
  represents the remote player, and NPC hits already land natively on
  today's ghosts (WO-56 Phase 4, observed via WO-26's 100→57.5
  counterattack).

**The standing plan is therefore unchanged and is restated here as this
phase's answer:** WO-A measure joint combat on the current build with two
humans (now unblocked by WO-55's launcher fix — it was the blocker) →
WO-B Flow B verification + symmetric swing cues → WO-C receiver-side brain
suppression → WO-D combat-scoped engagement claims. Do not build the
dedicated instance; do not revert claims.

**The MMO lens adds one genuinely useful reframe:** WO-51's option 5 ("the
authority's world is already the shared arena — finish it") *is* the
reference doc's "shared enemies + group credit" model, and the doc's
vocabulary makes the product statement crisper than WO-51's: the NPC is a
**shared enemy** (one authoritative health/death), engagement is **group
credit** (both players' damage lands, whoever kills it, it's dead for both),
but loot/XP/crime remain **individual pools** — which this project already
does (independent loot pools by design, WO-48; per-machine crime since
WO-32). That is the hybrid every real MMO ships, and it means the
remaining work (WO-A–D) is completing an architecture that is already
MMO-shaped, not choosing a new one. No re-opening needed.

---

## Phase 4 — "in conversation" as a real, synced state

The gap (WO-40, observed): PB's 79 s dialogue window produced **no pause
event and a 79 s position-stream gap** — dialogue freezes the local world
without tripping the marker-based pause detector
(`LogTailGameTransport.ProcessPauseMarkers` knows exactly three states:
menu RTPC, inventory audio pair, AfterSkipTime observer — read, this
session, `LogTailGameTransport.cs:259-296`).

### 4.1 The detection surface is better than the marker set

Found in the shipped scriptbind docs this session (**read-but-unrendered**,
registration untested — the `GameRules`-is-nil trap applies):

- **`human:IsInDialog()`** (`C_ScriptBindHuman::IsInDialog`) — a direct
  boolean on the player's own human component. The emit tick already reads
  player vitals every 250 ms; adding one poll is structurally free.
- `Dialog.IsSoulInDialog(wuid)` (`C_ScriptBindDialog::IsSoulInDialog`) —
  the same question about any soul, useful for the *NPC* side (see 4.3).
- Fallback if neither is registered: a kcd.log marker diff during dialogue
  (the exact WO-11 method that found the menu/inventory markers), and a
  REST probe of the `dialog` module root (`/api/dialog?depth=1` — the root
  exists, WO-6 observed it; its contents were never enumerated).

### 4.2 Design (not built): a player-activity state, not another pause bit

Rather than widening the boolean pause aggregate, broadcast a small
**activity enum** on the existing pause packet's idiom (or a new additive
type): `idle / menu / dialogue / crafting / dice`. Three consumers:

- **Presence:** the ghost's nameplate gains a suffix ("in conversation…"),
  and optionally the dialogue-frozen peer's ghost plays the game's own
  talk stance rather than standing combat-idle. This is the MMO
  "seeing other players" layer done honestly — B learns *why* A froze.
- **Puppet/pause machinery:** dialogue joins menus in driving the
  InterpPump path, closing the 79 s stream-gap class (the pump mechanism
  already exists and was extended once before, WO-40 Phase 2 — this is the
  same one-liner class of fix).
- **Shared-combat state (the human's example):** see 4.3.

### 4.3 "The fight should visibly stop for Player B too"

Precision first, because the honest mechanics are subtler than the example:
when Player A enters dialogue with an NPC both players were fighting,
**A's world freezes for A only** — in B's world nothing happened, and if
the NPC's authority is A, its stream stops (B sees the NPC freeze
mid-swing: the current buggy-looking behavior). What a synced dialogue
state enables, in order of ambition:

1. **Legibility (cheap, recommended):** B sees "A is in conversation" on
   the nameplate and the NPC puppet drops into idle instead of freezing
   mid-pose (receiver-side: on peer-dialogue, ease puppets to idle stance —
   the drawn-state and animTag machinery already exists).
2. **Combat-state coherence (moderate):** while any engaged player is in
   dialogue, suppress swing cues/damage events for the shared NPC, so the
   fight is "paused" rather than half-alive. Needs the engagement notion
   from WO-51's option 2 to know which NPCs are "the fight."
3. **True shared stop (not recommended):** forcing B's *local* world to
   also hold (e.g. forcing B into a menu) — rejected: it would let one
   player freeze another's game at will. This is where the
   shared-vs-individual line lands: **dialogue is personal story state; its
   *existence* should be shared (visible), its *effect* (world freeze)
   should stay individual.** The reference doc's instancing analogy is
   exact — you see your partner talking to the questgiver; you don't get
   frozen by it.

**Also fix, same WO:** the pause state machine smearing across death-reload
(`entered` 19:41:11 → `exited` 19:44:54, WO-40, observed) — the reload
sweep should reset pause state; it's the same marker-set hygiene work.

**Cost:** one live marker/registration probe session + a small additive
wire change + receiver polish. **Verdict: high value, low risk, and the
detection half is a prerequisite for Phase 5's design anyway. Recommended
as the first *built* follow-up of this WO.**

---

## Phase 5 — shared-object occupancy ("that bench is in use")

The reflection question the WO asks ("can station state be read?") turns
out to answer at the *Lua* layer, not the RTTR layer — from the game's own
entity scripts, extracted this session (**observed, static**):

- Stations are `UsableItem`-derived Lua entities: `AlchemyTable.lua`,
  `Smithery.lua`, `DiceInteractor.lua` (Scripts.pak). C++ twins exist
  (`C_AlchemyTable` in EntityModule, `C_Smithery` in PlayerModule — RTTI,
  WO-52) but the gating state is visible in Lua:
- **`AlchemyTable:IsUsable` refuses when `self.nUserId ~= 0`** — a live
  per-entity occupancy field the game itself gates on (it also carries
  `State.isUsedByPlayer`, and a `bOnlyNPC` property whose comment says
  outright it "block[s] player use when NPC is using"). Smithery gates via
  `Blacksmithing.CanUse(user.id, self.id)`. Start calls:
  `Alchemy.StartAlchemy(user.id, tableId)`,
  `PlayerStateHandler.StartMinigame(self.id, E_MinigameType_Blacksmithing,
  …)`, `Minigame.CanUseMinigame(user.id)`.
- So the *local* read exists twice over: (a) the station entity's
  `nUserId`/`IsUsable` for any loaded station, and (b) the player's own
  minigame entry (`PlayerStateHandler.StartMinigame` is the choke point;
  crafting minigames also have kcd.log-marker candidates — WO-38/39 both
  reference a detectable crafting state that was never isolated).

**But the design insight is that station state should NOT be synced as
station state.** Each machine has its own copy of every bench; A using
A's copy does nothing to B's copy, and there is nothing to reconcile —
stations are stateless between uses. What B actually needs to know is
**what A is doing** — which is exactly Phase 4's activity channel with a
`crafting` value plus the station's entity name/position (so B's world can
badge *that* bench). Render on B: nameplate suffix + a DrawText/label tag
on B's copy of the station ("occupied — PlayerA"), cleared on activity end.
Optionally *enforce* it (suppress B's own interactor while badged) — **not
recommended**: soft information beats hard locks when the two worlds can
desync (a stale lock on a bench would be worse than a stale label; MMOs
made the same call — crafting stations are almost never exclusive-locked).

**Cost:** rides Phase 4's channel almost entirely; the only new work is the
local detection probe (is the player's station use visible as
`station.nUserId == player.id`, a log marker, or both) and the badge
rendering. **Verdict: cheap, real, do it with Phase 4 as one "player
activity" WO.**

---

## Phase 6 — duels: declared PvP, wagers, no permanent death

### 6.1 What already exists (the surprising amount)

- **PvP damage is structurally live today**, attribution-blind: A hitting
  B's ghost drops its health natively (observed since WO-26 Phase 0), the
  Flow B sensor turns any ghost-health drop into routed 0x21 damage, and
  the recipient's agent applies it via the DLL's native
  `CombatSoul::TakeDamage` (`GameBridge.cs:2219`, read). Two caveats that
  a duel WO must fix: **the sensor runs only on the damage authority's
  machine** (WO-51 §1.2) — a duel between two non-authorities currently
  exchanges no damage — and the cross-machine hop is the same
  never-verified step as Flow B generally. A duel-scoped sensor (each
  duelist's machine watches the opponent's ghost) is a small, natural
  extension and in a 1v1 it even gains attribution for free (drops on B's
  ghost in A's world during a duel ≈ A's hits).
- **Local damage is also real:** the opponent's ghost brain fights back
  reactively and its hits genuinely hurt (player 100→57.5, WO-26,
  observed). So duel damage arrives on two rails at once — wire (real,
  clampable) and local ghost (engine-applied, not clampable from Lua).
  Double-counting and the death question both live here.

### 6.2 No-death, three rails (in escalation order)

1. **Wire clamp — free.** The mod owns the 0x22 application point
   (`ApplyPeerHit…` → `ApplyDamageAsync`); during a declared duel, clamp
   incoming duel damage so health never crosses below a floor (e.g. 5 HP),
   then end the duel. Covers ALL wire-delivered damage with zero research.
2. **Native invulnerability — bounded research.**
   `GameRules.SetInvulnerability(entityId, bool)` and `IsInvulnerable` are
   documented scriptbinds; the `GameRules` Lua global is **nil on this
   build** (WO-38, observed live), so the Lua route is dead — but the
   scriptbind's *implementation* in the DLLs necessarily calls a real
   engine setter, and disassembling a thin scriptbind to find its
   underlying call is exactly the WO-42/44 pattern. If recovered, the
   native DLL can flip it on both duelists for the duel window, closing
   the local-ghost-damage death hole too.
3. **`soul_vip_class_id` — the prompt's lead, honestly graded.** The
   mechanism is real and live-verified *for a ghost bound to a protected
   soul* (immortality floors health at 1 under real lethal TakeDamage,
   WO-25 Phase 3, observed A/B). But applying it to a *player* means
   changing the vip class of the player's own soul at runtime, and
   **nothing known writes that**: it is a static soul-table column; no
   reflected property for it has ever been seen on a live soul; and the
   one write-path precedent for soul-row-adjacent state (faction
   `SetParent`) needed a full ownership-bug fix to survive. Runtime vip
   mutation is a research question (RTTR property enumeration on
   PlayerSoul first, then native), and rail 2 reaches the same outcome
   with a cleaner, reversible flag. **Recommendation: rails 1+2; treat
   vip-class-on-player as the fallback investigation if 2's setter can't
   be found.**
   A fourth option worth one probe while in there:
   `Actor.RequestKnockOut(target)` is a documented scriptbind — a duel
   that *ends in vanilla unconsciousness* for the loser (the game's own
   fist-fight convention) would be the most KCD2-native finish available.
   Registration untested.

### 6.3 Declaration, consequences, and the honest crime problem

- **Declaration/accept:** pure wire + UI — a challenge event, an accept
  window, a countdown toast. All primitives shipped: additive wire types,
  `hud.ShowInfoText`/`ShowTutorial` (PROVEN-INGAME),
  `ApseModalDialog.OpenQuestionDialog` as the native yes/no (documented,
  render-untested — drawn-toast fallback per the WO-6 pattern). Duel state
  is mod state on both agents plus the relay (the dice-session idiom).
- **Aggro/crime suppression — the real open cost.** A ghost is a full
  crime victim (WO-34: real fines/jail, real settlement rep loss —
  observed), so dueling inside a town means witnesses, guards, and
  reputation damage on *the attacker's own machine*, and no
  crime-suppression lever is known (faction writes are the fixed-but-scary
  SetParent; nothing narrower exists on record). **Recommended design cut:
  location-gate duels** — the challenge flow requires standing outside
  settlement/witness range (the mod can check crime-relevant proximity
  crudely by NPC density), which is also period-appropriate and matches
  how MMOs zone-gate open PvP. Investigating a real crime-suppression
  lever (soul `RestrictDialog`-adjacent surface, `IsInTenseCircumstance`,
  the crime module root) is a bonus probe, not a dependency.
- **Double-counting:** during a duel, pick ONE damage rail and mute the
  other. Recommended: wire rail authoritative (it's clampable and
  symmetric), local ghost-brain damage muted — which needs the duel ghost
  to not fight back locally… which is Phase 3's receiver-suppression
  problem in miniature. Interim: accept local damage as "flavor" but clamp
  *local* death via rail 2. This interaction is the duel WO's hardest
  design decision and it should be made against WO-A's measurements.

### 6.4 Wagers

- **Fully automatable escrow, no new engine capability needed:** money =
  `inventory:CreateItem(moneyClass, …)` in decagroschen (WO-49's exact
  payout mechanism, live-verified) and removal by wuid
  (`ItemManager.RemoveItem` is registered — WO-48's live table dump; the
  WO-48 rollback already deletes gained items by recorded wuid,
  observed). Item stakes ride the WO-48 drop/claim machinery or direct
  CreateItem-on-winner + RemoveItem-on-loser. Escrow at accept (both
  agents remove the stake and record it), payout at result (winner's agent
  creates; loser's already lost it) — the both-sides bookkeeping is the
  dice-payout pattern extended.
- **The save-scumming hole, stated plainly:** a loser can reload a
  pre-duel save and keep their stake — the WO-48 reload sweep converges
  the *world* to the owner's save, and inventories are saves. Mitigation,
  not solution: agents hold a duel ledger (agent state survives reloads —
  the TCP connection itself survives, WO-28 Phase 0 observed) and re-apply
  unsettled outcomes after the reload sweep. A determined player can still
  kill the agent process. **True wager finality is impossible without
  server-authoritative inventory, which this architecture will never
  have** — the MMO reference's core persistence point, inverted. Ship the
  ledger, document the limit, and let table stakes stay modest.

**Shared-vs-individual verdict:** a duel is consensual shared content —
sync it. Its *consequences* stay personal by design: no crime export, no
death, wagers as the only durable transfer (via the already-shared item
economy). **Recommended: yes, as a WO after the Phase 4 activity channel
(duel state is an activity) — rails 1+2, KO probe, location gate, ledgered
wagers.**

---

## Phase 7 — beautification: is DrawText still the ceiling?

What WO-6 proved (all observed, `WO-6-visual-capability.md`): DrawText is
the only working Lua screen-space primitive (Draw2DLine registered but
renders nothing; DrawTriStrip unregistered; no image primitive); the Flash
UI route (`UIAction`) is real from the sandbox — `ShowTutorial` (HTML-rich
parchment panel, 774-glyph font inventory mapped) and `ShowInfoText` render;
`ShowDiceScore` is context-gated inert; `img://` is dead in tutorial text;
Route 3 (mod-shipped .gfx) was scoped but never attempted; ImGui-via-
KCD2ModLoader exists (MIT) but was declined as a hard dependency with the
wrong look.

The native toolkit changes the answer in three specific places, none of
which existed when WO-6 ran:

1. **Diagnose `Draw2DLine`'s silence at the source (cheapest, do first).**
   "Registered, callable, renders nothing" is now a *disassemblable*
   condition: decompile `CScriptBind_System::Draw2DLine` (CryScriptSystem —
   these binds carry their registration strings; the pipeline is proven)
   and read where the geometry goes. Plausible outcomes: it draws into an
   aux-geom layer that KCD2's renderer never flushes (unfixable → closes
   the vector tier honestly, forever), or it needs a mode/flag the Lua
   call can't set (→ the native DLL calls the same aux-geom interface
   directly with the right mode, and the vector tier — bars, frames,
   panels — opens up without any hook). Bounded: one function read plus
   one native experiment.
2. **Drive the Flash layer natively.** The gui module's UIElements are
   reachable objects (the 31-singleton vector, observed); CryAction's
   UIElement system is a C++ API underneath `UIAction`. Native access
   doesn't lift the *context gates* (ShowDiceScore's ActionScript checks
   don't care who calls it), so this route's real value is narrow: calling
   element functions with types Lua can't pass, and `SetVariable` on
   MovieClips of always-loaded elements (e.g. abusing the HUD's own bar
   clips). Speculative; rank below 1 and 3.
3. **Route 3 (mod-shipped .gfx element) deserves its two-unknown test.**
   The blockers WO-6 recorded were (a) authoring a loadable .gfx and (b)
   whether the engine scans mod paks for UIElements XML. (b) is a
   15-minute test (ship a copy of a vanilla .gfx under a new element
   name); (a) has a real candidate path never evaluated: the open-source
   Ruffle/JPEXS ecosystem can compile simple SWFs, and Scaleform 3.x
   `.gfx` is a tagged SWF variant — a *static* panel with named MovieClips
   (bars via `SetScale`, icons as embedded bitmaps) needs no ActionScript
   at all, since `UIAction.SetPos/SetScale/SetVisible` (all live) can do
   the dynamics from Lua. If (b) passes, this is the true "real bars,
   icons" answer — the game's own renderer, no hook, HUD-mod-compatible.
4. **The D3D12 present-hook (ImGui-class) remains the fallback of last
   resort** — proven possible in KCD2 by KCD2ModLoader (MIT), but it's a
   second rendering stack, a crash surface on every game patch, and a
   styling treadmill to not look like a debug tool. Only if 1 and 3 both
   fail AND the product genuinely needs arbitrary graphics.

**Verdict: plain text is no longer *provably* the ceiling — but nothing
above it is proven either.** One session — disassemble Draw2DLine, test the
mod-pak UIElements scan — converts both "unknown"s to answers before any
investment. Recommended as a low-priority follow-up; the current
DrawText + native-panel hybrid already clears the usability bar (WO-50
even added the release-toggle for it).

---

## Phase 8 — shared sieges (scoped, per the WO: honest scoping, not a plan)

What the engine actually does (all prior evidence, none of it new
speculation):

- **A siege is not a distinct combat system.** WO-15, live inside
  `zoufalaObranaZaBohutu` (observed): the battle runs on quest-authored
  factions on the ordinary faction tree (`…EnemyArmy` 124 members /
  `…Friendly` 42), ordinary souls with ordinary `CombatSoul` telemetry
  (`SkirmishStatistics`/`AttackersCount`, all read-only), and
  `SkirmishManager` is an empty method facade — "not a roster, not a
  battle-state object." The waves/ladders/triggers are quest scripting
  (the Quests/*.xml layer), i.e. **per-world story state**, plus two siege
  props that are — amusingly — the only `NetSerialize` implementors in the
  entire game (`C_Battlement`, `C_StoneThrowingPile`, WO-52, observed;
  useless to this project, as WO-52 concluded).
- **So "sync a siege" decomposes into exactly the known problems at a
  hostile scale:** (a) NPC-sync capacity — the ≤5-NPC/30 m tracked set was
  a measured bound, not fundamental (WO-51), but a siege is dozens of
  simultaneous combatants, an order of magnitude past anything measured;
  (b) joint combat quality — everything Phase 3 says, multiplied; (c)
  **trigger alignment** — each machine's quest script fires waves on its
  own local conditions, and nothing syncs quest-script execution; two
  machines will run the same siege at different tempos. (c) is the
  genuinely new problem class this phase adds, and it has no existing
  machinery at all.
- **The architecture answer already on record stands:** joint content
  requires both players to have independently reached it
  (`ARCHITECTURE-shared-world.md`, deliberately MMO-shaped — the reference
  doc's "personal quest states, shared encounter" hybrid). A shared siege
  is therefore: both players have the quest active, generic rank-and-file
  are shared enemies, named/quest NPCs stay personal, quest credit stays
  personal.

**Honest scoping verdict:** this phase is gated twice over — on Phase 3's
WO-A/B/C/D outcomes (if joint combat on ONE NPC is shaky, sieges are
premature by definition), and on a capacity measurement that has never been
run (raise the tracked-set bound in an empty field with synthetic peers
before believing anything about 30 NPCs). The realistic near-term product is
not a synced siege but a **"fight the same battle side-by-side"
experience**: both players in their own copies of the siege, presence
synced (already works — ghosts render inside quest battles; WO-15's
environment was exactly that), plus Phase 4's activity legibility, with the
5 nearest soldiers synced as today. True wave-level sync would need quest-
trigger sync — new infrastructure with per-world story state as its input,
which crosses the project's own shared/personal boundary and should be
approached, if ever, as "sync the *trigger moments* of an activity both
players independently own," not "sync quest state." **Defer until WO-A–D
land; revisit with their data. Fine — and expected — that this is the
answer.**

---

## Priority-ordered follow-up shortlist (this WO's output)

1. **WO: player-activity channel** (Phases 4+5): dialogue/crafting/menu
   states on the wire, nameplate + station badges, dialogue joins the pump,
   pause-state reload hygiene. Prereq probes: `IsInDialog` registration,
   dialogue kcd.log marker diff, station `nUserId` read. Small, ships value
   alone, prerequisite for duels.
2. **WO-A (from WO-51, unchanged, now unblocked by WO-55):** two-human
   joint-combat measurement + the three "one install away" E2Es. Everything
   in Phases 3, 6, 8 sharpens or re-ranks on its data.
3. **WO: ranged visibility** (Phase 2.1): prepare/execute wire events +
   render-route enumeration; fix the bow melee-leak guard.
4. **WO: dice disassembly** (Phase 1): `OverrideNextThrow` shape/timing +
   `StartDiceInner`'s options table, offline; then one live probe session
   (Minigame registration, ghost opponent, DiceInteractor spawn).
5. **WO: duels** (Phase 6): after 1 and 2 — wire clamp + invulnerability
   setter recovery + KO probe + location gate + ledgered wagers; swing-zone
   mirroring (Phase 2.2) folds in here.
6. **WO: UI ceiling test** (Phase 7): Draw2DLine disassembly + mod-pak
   UIElements scan test. Low priority, bounded.
7. **Sieges** (Phase 8): explicitly deferred pending 2's data and a
   capacity measurement.

## What this session did NOT do

No code, no pak/DLL/agent changes, no VERSION change, no live game contact
(game was not running; static reads only: PlayerModule.dll strings,
Scripts.pak entity scripts, script_bind docs, this repo). New follow-up
probes are listed inline per phase. Every prior-WO claim above cites its
source doc; every new claim is static-tier and marked.
