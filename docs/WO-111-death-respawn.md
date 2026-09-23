# WO-111 — death without Game Over

Session 2026-09-23, solo, Modding Tools build (the running 0.26.5 pak, no
DLL injected, no agent). Progress, method and gaps:
`docs/WO-111-progress.md`. Read first: `docs/WO-107-ai-suppression.md`,
`docs/WO-110-findings.md` §3.3, `docs/NATIVE-PLUGIN-findings.md`,
`docs/WO-86-findings.md`, `docs/WO-105-cryengine-reference.md`, the DLL source.

Evidence marks: (observed) / (code-verified) / (synthetic) / (inconclusive).
(data-verified) = read in the shipped `Tables.pak` / `Scripts.pak`.
"The call succeeded" is never used as "the thing happened": every live row
below was read back.
**No code shipped. No pak, no installer, no VERSION bump. Nothing ran
two-player.** Paths: `<install>` (Modding Tools install), `<saves>`, `<repo>`.
RVAs are against this install's binaries (image base 0x180000000).

---

## 0. Answer first

**Achievable natively: yes.**

**Recommended route, one line:** keep the engine's own `death_protection`
buff (`imm=1,upr=1`) on the player — `C_Soul::SetSoulState` then floors every
health loss at `ImmortalHealthMin` (1.0) *before a death can be decided* — let
the DLL treat "health at the floor" as **downed** and run the respawn
natively; put a vtable guard on `I_GameOver::Start` as the safety net for the
Game Overs that are not deaths.

* **One chokepoint decides death**: `C_Soul::SetSoulState` → the raw state
  writer → `C_Soul::OnDeathSynchronous`. Every other path into the health
  state carries no cause and cannot kill. (code-verified, §3.2)
* **The engine already ships the switch at that chokepoint**: derived stat
  `Immortality` (index 0x5D) clamps the floor to `ImmortalHealthMin`
  (param `+0x3A0`, default 1.0f). A shipped buff sets it. Warhorse's own
  `Scripts/Startup/CombatTest_startup.lua` adds `death_protection` to `Dude`.
  (code-verified + data-verified)
* **Five death sources held at 1.0 under the buff**, no `Soul died` line, no
  Game Over, a fresh `Script.SetTimer` fired: lethal `CombatSoul::TakeDamage`
  (500), bleeding, a 45 m fall, `deadly_poison`, starvation. (observed)
* **End-to-end rehearsal**: downed → grave spawned, 5 items moved,
  teleported 31.6 m, bleed and poison cleared, `remove_injuries` applied, all
  in one 2.0 ms batch → hp 100, guard kept, timers alive. (observed; Lua and
  REST stood in for the native calls — §5)
* **Toggle off = vanilla, exactly**: same save, guard removed, lethal hit →
  `Soul died 'Dude' (DR_ScriptedHit)`, GAME OVER screen, Lua timers ran 3.0 s
  more, then `Gameplay ended` and nothing fired again. (observed)
* **The gravesite is a shipped container**: entity class `StashCorpse`
  (`C_StashCorpse : C_Stash`). Spawned at runtime it has an inventory, takes
  items by WUID and **survives save + reload with its contents**. (observed)
* The standing trap held again. "Defeated, not dead" exists twice over:
  death protection, and a real player-unconscious state with its own wake-up
  (§2). The first is the clean one.

---

## 1. Phase 0 — what we already have

* **DLL** (code-verified): RTTR `Soul::GetState`/`SetState`,
  `CombatSoul::TakeDamage`, `Soul.IsDead`; `apply_death` = lethal
  `TakeDamage(100000)`; `sample_health` samples NPC health every 60 ms and
  **skips the player** (`soul != g_player`); main-thread tick =
  `WHGame.dll` IAT swap of `Framework!C_ModulesManager::Update`. No player
  death handling and **no native entity position write** exist today.
* **Player death on the wire** (code-verified): Lua
  `KCD2MP_ReadSelfVitals` reads `actor:IsDead()` → emitter v2 → agent
  `SendDeathIfNewAsync` → 0x23 → relay → 0x24 → peer `KCD2MP_SetGhostDead`
  (one death pose, `[dead - reloading]` tag) → cleared when vitals arrive
  with health > 0 (`ReloadReconcile.VitalsClearDeathTag`). WO-86's FATAL flag
  is NPC-only.
* **`mp_fake_death`** (code-verified): sets `KCD2MP.fakeDeadUntil`; the
  emitter reports "dead" for N seconds so peers react. It touches nothing in
  the engine. It cannot stop a real death and cannot produce a respawn.
* **CryEngine 5.7.1** (WO-105): stock script timers have a pause flag no
  stock code calls (§12.2); a load resets the timer manager (§8.2). Stock
  actor health/death is not where KCD2 decides death — Warhorse moved it
  into `RPGModule` souls (§3). WO-105 §19 already flagged the RPG layer as
  outside the stock source.

---

## 2. Phase 1 — the vanilla non-fatal defeats

| defeat | run? | what the player sees | where they end up | what is lost | time passes | native path |
|---|---|---|---|---|---|---|
| **player unconscious** (shipped buff `unconscious`, 60 s) | **observed** | `SkipTime.gfx` faint, `special_skiptime_fainting`, `AfterSkipTime` observer; ~2 s real time | same spot | nothing observed | **yes** — a skip-time ran; its size was not measured cleanly (the clock read ~45 game-minutes ahead of the 15× real-time expectation) (inconclusive) | `C_UnconsciousSoulBuffInstance`; skiptime id 6 `Unconscious` (type 12, forced, hidden stats and time) |
| open-world fistfight / weapon knock-out | not run (needs a live attacker) | knock-out, then the faint above | same spot, then NPC resolution | per resolver (below) | yes | `0x52FBE0` combat-hit decision → `0x70F6B0` adds the unconscious buff with `CombatHitUnconsciousDepth` 480 (code-verified) |
| NPC resolution of an unconscious player | not run | — | arrest dialogue / thrown out / left lying / **Game Over** | fine, jail, items (per crime) | — | BT `crime_playerUnconsciousAfterSkirmishResolve`, `interrupt_attack` state `playerInUnconscious` → `resolveCrimeDialogue` (authority), selfhelp (non-authority), `throwOutUnconsciousPlayer`, or `GameOver(DiedWhileUnconscious)` for enemies with `combat_neverAcceptSurrender` and no `crime_preventKillingUnconsciousHostilePlayer` (data-verified) |
| quest brawl (tavern `socky/hospodska_bitka`, training grounds, ladder) | not run | fight stops when "player down" | same spot | nothing | no | quest adds `player_immortality_nonpersistent` (`imm=1,upr=1`, the same pair as `death_protection`), watches `health < 20` + an unarmed hit → quest-level `PlayerUnconscious` state → `fightstop` (data-verified). **The game's own brawls already use death protection.** |
| surrender / yield | not run (needs input) | surrender dialogue `HRAC_SE_MI_VZDAVA_V_COMBATU` | same spot | per outcome | no | `interrupt_attack` states `playerIsSurrendering` → `playerSurrendered` → `fightIsDone`; `Crime.SendSurrenderChatResult` (data-verified) |
| arrest outcomes | not run | resolution dialogue | jail skiptime (id 5 `Jail`, type 11) / fine / stocks | money, time | jail: yes | `resolveCrimeDialogue`, `nextnextgenpunishment` (adds `remove_injuries`) (data-verified) |
| guard frisk | **observed (unplanned)** | "Show me everything!" with allow / talk / refuse options; world time paused | stopped in place | per choice | paused while in dialogue | `interrupt_frisk` (data); cause of this frisk (inconclusive) |
| drunk blackout ("sleepwalking") | not run | wake elsewhere | a `hangoverSpot` (35 % `hangoverSpot_joke`, else nearest) | random items possible | yes | BT `player_sleepWalkingTeleport`, `Player.SetAlcoTeleportTarget`, `C_PlayerModule::ValidateAlcoTeleportPoints` (navmesh check) (data + code-verified) |
| exhaustion faint | not run | faint | same spot | — | yes | `ExtremeExhaustionFaint*` params (code-verified names) |
| scripted "wake up later" (M01–M51) | not run | per quest | per quest | per quest | per quest | examples: `fist_fights_common_library/wakeupafterknockout.xml`, `klaster/.../cin_s9047r_monastery__henry_defeated.xml` (data). Catalogue only — out of scope |

**Verdict.** The unconscious state is callable (a buff) and wakes on its own,
but it runs a **world-time skip** and hands the player to NPC resolution,
which can end in a Game Over. It is a presentation, not a guard. The clean
"cannot die" state is `death_protection`, which the game's own brawls use.
The WO does not end at Phase 1, but Phase 1 pointed straight at the answer.

---

## 3. Phase 2 — the death path, health 0 → Game Over

### 3.1 The chain

| # | step | binary · RVA | what it decides | evidence |
|---|---|---|---|---|
| 1 | `C_Soul::SetSoulState(state, value, cause)` | RPGModule `0x7322C0` | refuses to raise a dead soul's health (`cannot raise health of a dead soul`); clamps to `[floor, max]`; **floor = params `+0x3A0` (`ImmortalHealthMin`) iff derived stat `0x5D` (`DerivStat_Immortality`) > 0, else 0** | code-verified; floor 1.0 observed |
| 2 | raw state writer (`+0x1B0[state]`) | RPGModule `0x720BB0` | pushes health to the actor (`vtbl[0xE8]`); **if old health > 0, a cause is supplied, and health is now ≤ 0 (`0x73DA80`) → step 3** with the reason from the cause info `+0x5C`; also holds the revive branch (clears dead flag `+0x4EC`, actor `vtbl[0x958]`) | code-verified |
| 3 | `C_Soul::OnDeathSynchronous(reason, killer)` | RPGModule `0x731270` | broadcasts module message **0x26**; stores reason `+0x638`, killer `+0x640`, time `+0x648/+0x650`; dead flag `+0x4EC = 1`; dead-souls queue; logs `Soul died '%s' (%s) killer = '%s'` | code-verified; line observed (4 earlier player deaths, 5 NPC deaths, and this WO's) |
| 4 | `C_Soul::OnDeathAsynchronous` → `0x77B9C0` → body | RPGModule `0x420FD0` → `0x731540` | module message **0x25**; actor death callback `vtbl[0x950](1)`; **if soul `+0xD78` bit 4 (the player)** → `(gi+0x130)->vtbl[0xA8]()` → `I_GameOver` slot 1 `Start(table[reason])`, table RVA `0xFDA0E0` (§3.6) | code-verified |
| 5 | `C_GameOver::Start(id)` | PlayerModule `0x178DD0` (vftable `0x643190`, slot 1) | refuses if started (`this+8`); **`SetSaveLock(7, true)`**; `BlockSounds` `0x179160`; emits the **`E_GameOver` signal** to subscribers (`this+0x18`: quest `C_GameOverTrigger`, RPG `C_EventCounter`, GUI `C_UIMenu`); state 1; UI `Show(message, type, completion)` | code-verified |
| 6 | `C_UIGameOver` shows `GameOver.gfx` | GUIModule vftable `0x47A3B0`, init `0x3954C0` | registers `OnPictureShown` → completion; hands `this+0x58` to `C_GameOver::SetUI` (slot 3) | code-verified; screen observed |
| 7 | completion | PlayerModule `0x178FF0` (via dispatcher `0x1B07B0`, lambda `0x1BABA0`) | module message **0x36**; `(gi+8)->vtbl[0x68](1,5,0,0)` (a menu request — inferred); state 2 | code-verified |
| 8 | `C_GameplayManager::EndGameplay` | Framework `0x65B40` | clears running flag `+0x20`, logs `Gameplay ended`, module message **0x4D**; **Lua timers stop here** | code-verified; stop observed |
| 9 | load prompt | GUIModule `accept_game_over` (`0x395840`) → `C_UISaveLoad::LoadLastSavedGame` `0x319180` (`wh_sys_AutoLoadLastSave`) | "Press E to Continue" → menu → load | code-verified names; screen observed |

Timing, death → `Gameplay ended`: about 3 s in every recorded case — this
WO 3.0–3.4 s (bracketed by a 250 ms Lua tick), and the four earlier player
deaths in the pre-existing logs (two combat, two bleed-outs) bracket to
roughly 3 s by their Lua timestamps. (observed) Step 7 → step 8 is by log
order; the handler that turns 0x36 into `EndGameplay` was not traced.
(inconclusive)

### 3.2 One chokepoint or many?

**One.** Each source computes its own damage; **none decides death**.

* Death is decided only in step 2, and only when a *cause* is passed.
  `SetSoulState` is the only caller that passes one. All ten other callers
  of the raw writer pass a null cause: the state copy `0x720720`, reset to
  defaults `0x720380`, `ResetBeforeSwitchLevel` `0x731840`, `C_Soul::Revive`
  `0x730FF0`, the stats update `0x730140`, and the stamina/hunger/exhaust
  timers `0x7224F0`, `0x722650`, `0x7227D0`, `0x152E60`, `0x720500`.
  (code-verified, static call graph, every caller decompiled)
* Static callers of `SetSoulState`: `C_HealthValueEffect::Apply` `0x430730`,
  `C_SoulStateEffect::Apply` `0x431780`, the regen timer `0x7221B0`. Combat
  damage arrives virtually; `CombatSoul::TakeDamage` was observed to pass the
  clamp. (code-verified + observed)
* The **only float read of `ImmortalHealthMin` in `RPGModule` is in
  `SetSoulState`** (displacement scan). (code-verified)
* Weapon blows add one step before the damage: `0x52FBE0` (CombatSoul.cpp)
  flags an **immortal** victim whose blow would cross the floor and calls
  `0x70F6B0` to knock it out with `params[0x86C + 4·immortal]`. **`0x70F6B0`
  returns immediately if `DerivStat_UnconsciousnessProtection` (0x61) > 0.**
  So `upr=1` turns a lethal blow into "floored at 1", not a knock-out.
  (code-verified; a real blow was not observed — §4)

### 3.3 What turns death into Game Over

Not a game-state change and not a script. **A player-flag branch in the
async death body calls a PlayerModule interface** (step 4), and
`C_GameOver::Start` does the rest: save lock, sound block, quest signal, UI.
`Start` has no static callers and is not exported, so **every Game Over in
the game enters through `I_GameOver` vtable slot 1**. (code-verified)

### 3.4 Why Lua timers stop — named, to the depth found

* They **do not stop at death.** Through the Game Over picture a 250 ms Lua
  chain kept firing: 13 ticks over 3.0 s after `Soul died`. (observed)
* They **stop at `Gameplay ended`** (`C_GameplayManager::EndGameplay`,
  step 8). After it, a fresh `Script.SetTimer(100)` never fired, while the
  console still answered. (observed; matches WO-110 §3.3)
* `Gameplay ended` is **the same teardown that precedes every save load**
  (three loads this session, each preceded by it). (observed) It is a
  teardown, not a pause: `C_GameProfileManager: Deactivating profile …`
  follows it by the hundred. (observed, historical logs)
* The switch inside the script system (timer manager paused, reset, or its
  update not called) was **not found**. `CScriptTimerMgr` carries only a
  profiler label, and no `CCryAction::PauseGame` line appears in the log
  around a Game Over. (inconclusive)
* **Consequence:** there is no "unpause afterwards". Interception has to
  happen before step 7 — in practice at or before step 5.

### 3.5 Where the load prompt comes from

`C_UIGameOver`'s `accept_game_over` action ("Press E to Continue") → the menu
request made at step 7 → `C_UISaveLoad::LoadLastSavedGame` (log `Loading last
saved game...`), or the save list. (code-verified names; observed screen)

### 3.6 Death reason → Game Over row (RPGModule table `0xFDA0E0`)

| DR | game_over_id | row |
|---|---|---|
| `DR_ReasonUnknown`, `DR_Last` | 0 | DiedUnknown |
| `DR_Combat`, `DR_Combat_Gunshot`, `DR_SelfHarm` | 1 | DiedInCombat |
| `DR_Starvation` | 2 | DiedByStarving |
| `DR_Collision` | 3 | DiedByCollision |
| `DR_ScriptedHit`, `DR_ScriptedDisintegrate` | 4 | DiedByScriptedHit |
| `DR_FallDamage` | 5 | DiedByFall |
| `DR_Poisoning` | 6 | DiedByPoison |
| `DR_Bleeding` | 7 | DiedByBleeding |

(code-verified; matches `Libs/Tables/rpg/game_over.xml`.) **There is no
drowning death in this build**: no `DR_` reason, no "drown" string in any
module. (code-verified)

### 3.7 Game Overs that are not deaths — they bypass any death guard

All enter through `I_GameOver::Start` directly (§3.3):

* BT `GameOver` node (XGenAIModule): `DiedWhileUnconscious` in
  `crime_playerUnconsciousAfterSkirmishResolve` and twice in
  `interrupt_attack`; `game_over_bohutaArrested` and `DiedInCombat` (behind
  the quest context `crime_killUnconsciousPlayerOnRepeatedResolve`) in
  `resolveCrimeDialogue`; also `interrupt_animal_attack`,
  `selfhelp_resolveCrimeDialogue`. (data-verified)
* Quest nodes: `C_GameOverTrigger` and the concept function "Runs game over
  with specified reason" — ids 39–98 (plot failures, crime execution 44).
  (code-verified names)
* Console `wh_pl_GameOverTest`. (code-verified)

With `upr=1` the player cannot be knocked out by a weapon (§3.2), which
removes the common `DiedWhileUnconscious` trigger. Other ways into an
unconscious player (a quest or alcohol applying an unconscious buff
directly) were not tested against `upr`. (inconclusive)

---

## 4. Phase 3 — interception candidates, ranked

Criteria: 1 no Game Over · 2 controllable afterwards · 3 every source ·
4 state clean · 5 toggleable · 6 patch resilience.

| # | route | where | 1 | 2 | 3 | 4 | 5 | 6 | side effects | effort |
|---|---|---|---|---|---|---|---|---|---|---|
| **C1** | **engine death guard**: keep `death_protection_*` (`imm=1,upr=1`) on the player; DLL detects the floor, runs the respawn | **before** the decision (inside step 1) | **PASS** (obs) | **PASS** (obs, E2E) | **PASS** 5 sources obs; weapon blow code-verified; bypass = non-death Game Overs (§3.7) | **PASS** with caveats below | **PASS** (obs) | **good** | open-world knock-outs become respawns; scripted player kills floored; quest GUID sharing | low–medium |
| **C2** | **`I_GameOver::Start` vtable guard** (PlayerModule vftable `0x643190` slot 1) | after the decision for deaths; before UI, save lock and signal for all Game Overs | PASS | **deaths: FAIL** (soul already dead, revive refused, obs); non-death: PASS | covers every Game Over source | quest `E_GameOver` signal suppressed (wanted for death-shaped ids only) | PASS | **good** | alone it leaves a dead player; **complement to C1** | low |
| C3 | vanilla unconscious: `imm` only, weapon blows knock out | inside the weapon-hit step (`0x52FBE0`) | PASS for blows (code-verified) | PASS (obs: faint, then awake) | **PARTIAL** — only weapon blows knock out; others floor (obs T8) | **FAIL** — world-time skip (obs that it runs); NPC resolution (arrest/rob/throw out); `DiedWhileUnconscious` from enemies (needs C2); knock-out resets nearby public-friend reputation (`C_ResetNearbyPublicFriendsReputationEffect`, code-verified) | PASS | as C1 | MP time-sync conflict | medium |
| C4 | detour `C_Soul::SetSoulState` (`0x7322C0`) | at the decision | as C1 | as C1 | as C1 | as C1 | PASS | **poor** — non-exported prologue patch | none over C1 | medium |
| C5 | hook `OnDeathSynchronous` (`0x731270`) and skip | after health is written ≤ 0 | PASS | **FAIL** — a 0-hp soul half into death | — | **FAIL** | PASS | poor | undefined soul state | medium |
| C6 | hook the completion (`0x178FF0`) or `EndGameplay` (`0x65B40`) | after UI, lock, signal | **FAIL** | FAIL | — | FAIL | — | — | Game Over already on screen | — |
| C7 | the lazy clamp | see below | **FAIL** | — | **FAIL** | neutral | PASS | — | — | low |

**C1 criterion 3, source by source.**

| source | result |
|---|---|
| combat entry `CombatSoul::TakeDamage` (500 hp) | floored at 1.0 (observed) |
| bleeding (shipped `test_bleeding`, ~0.42 hp/s) | floored, still bleeding (observed) |
| fall, 45 m | 100 → 1.0 (observed) |
| poison (`deadly_poison`, ~2.8 hp/s) | floored (observed) |
| starvation (hunger 0, ~0.05 hp/s) | floored (observed) |
| real weapon blow | knock-out refused by `upr` at `0x70F6B0`, damage floored at step 1 (code-verified; not observed — no attacker could be produced solo) |
| arrows / guns | `DR_Combat` / `DR_Combat_Gunshot` through the same state writer (inferred) |
| horse (fall, collision, trample) | `DR_FallDamage` / `DR_Collision` through step 1 (inferred; not run) |
| drowning | does not exist in this build (code-verified) |
| scripted kills of the player | floored like any other health loss (observed for `DR_ScriptedHit`); plot deaths may stall — out of scope, record them |
| non-death Game Overs (§3.7) | **bypass** → C2 |

**C1 criterion 4 caveats.**

* 22 scripts reference `death_protection_nonpersistent` (battles, hostages,
  duels); quests also apply `not_immortal` (`imm=0`, exclusivity 2).
  Sharing a GUID lets a quest's `RemoveAllBuffsByGuid` strip the guard; how
  `imm=0` combines with `imm=1` is unknown. (inconclusive) → use the GUID
  **no script touches**: `death_protection_cutscene`
  `6f706644-e28a-41a9-9674-5f19dea03bf1` (0 script users, data-verified),
  or a mod-owned row through the table-extension convention
  (`Libs/Tables/rpg/buff__kcdmp.xml`; the game ships `buff__dlc2_beds.xml`).
  Re-assert every few seconds.
* Use a **non-persistent** buff. The persistent `death_protection` would be
  written into the player's save and outlive an uninstall. Observed: after
  a reload the non-persistent buff is gone.
* Nothing that listens for the player's death fires: no module messages
  0x26/0x25, no `E_GameOver`, no save lock. Quests keyed on health still see
  health fall to 1 (the brawl's `health < 20` trigger still works).
* BT `KillNPC` refuses immortal targets (`Killing an Immortal?`,
  XGenAIModule `0x4E1C90`). That is NPC-side; a quest that must kill the
  player would be floored instead. (code-verified)

**C1 criterion 6.** Buff GUIDs and `ImmortalHealthMin` are data and names.
The health read is RTTR by name. The native `AddBuff` is two vtable slots:
`C_RPGModule->vtbl[0xE0]()` returns the `C_BuffManager`, then
`mgr->vtbl[0](mgr, C_Soul*, &CryGUID, nullptr)` returns the instance
(instance WUID at `+8`). Re-found by the string anchor
`wh::rpgmodule::C_ScriptBindSoul::AddBuff` (RVA `0x5EBB20`) and checked
through the returned object's RTTI (`.?AVC_BuffManager@rpgmodule@wh@@`).
(code-verified) `wh_rpg_AddBuffDebug <soul> …` exists but its second argument
is not a buff id; not a usable route. (observed)

**C2 detail.** The slot is one aligned pointer in PlayerModule's `.rdata`:
atomic to swap, like the existing IAT swap. Verify before writing: vftable
RTTI `.?AVC_GameOver@playermodule@wh@@`, slot 1 references `Game over is
already started`. Policy: for a death-shaped id (0–8, 26) **with the player
alive**, swallow it and hand over to the respawn; otherwise pass through.
Post-death revival was refused. RTTR `Soul.Revive` on the dead player →
`Soul 'Dude' will not be revived: it is not revivable.`; `actor:Revive(false)`
→ still dead, hp 0. (observed) Both executed just after `Gameplay ended`: the
REST queue delayed them about 2 s, so a revive *inside* the 3 s window was not
achieved. (observed) The refusal is a property check on the soul, not a timing
check (inferred from `0x730EA0`). `SetSoulState` refuses to raise a dead
soul's health, and `C_Soul::Revive` also refuses non-NPCs. (code-verified)
**So C2 cannot rescue a player who has actually died.**

**C7, the lazy clamp — why it loses, shown not assumed.**

* *Poll and restore from the frame hook*: death is decided **inside the
  same `SetSoulState` call that applies the damage** (steps 1–3, synchronous).
  No poller can run between the damage and the death, and a blow larger than
  current health kills before the next tick. Fails 1 and 3. (code-verified)
* *Clamp at `TakeDamage`*: a `TakeDamage` hook sees only what enters through
  `TakeDamage`. `SetSoulState` has other entries — `C_HealthValueEffect::Apply`,
  `C_SoulStateEffect::Apply`, the regen timer (code-verified) — which the
  buff-driven bleeding, poison and starvation effects use (inferred; not traced
  per source). Fails 3.
* The engine's own guard **is** the clamp — at the only place where it can
  work, before the decision.

---

## 5. Phase 4 — respawn

### 5.1 Sequence (all native, on the main-thread tick)

1. **Guard**: add `death_protection_cutscene` (or a mod row) on connect,
   after every load (non-persistent), and again every few seconds.
2. **Detect downed**: player health ≤ `ImmortalHealthMin` + ε (RTTR
   `GetState(health)`, the read `sample_health` already makes for NPCs).
3. **Grave**: spawn `StashCorpse` at the death spot; move the chosen items.
4. **Clear**: remove bleeding, poison and unconscious buffs by GUID; add
   `remove_injuries` and `remove_unconsciousness`; restore health, stamina
   and hunger.
5. **Move**: teleport to the chosen point (§5.3), on the ground.
6. **Present**: fade out before 3, fade in after 5 (optional time skip).
7. **Tell the agent**: one pipe frame (§7).

### 5.2 Primitives

| step | primitive | native reach | evidence |
|---|---|---|---|
| guard | `death_protection_*` buff | `C_BuffManager` vtable (§4) | effect observed; path code-verified |
| detect | health at the floor | RTTR `Soul::GetState(health)` | observed reading 1.0 |
| restore | health, stamina, hunger | RTTR `Soul::SetState` | observed (stamina clamps to its max, 126.67) |
| clear bleeding (buff) | `RemoveAllBuffsByGuid` | owned by `C_BuffManager`; native call not traced | observed via scriptbind |
| clear wound bleeding | `soul:HealBleeding(0..1, bodyPart)` | scriptbind exists | a real wound was not produced (inconclusive); `HealBleeding(1000, -1/0)` did nothing to a buff bleed (observed) |
| clear poison | `RemoveAllBuffsByGuid(<poison guid>)` | as above | observed for `deadly_poison` |
| clear injuries | add `remove_injuries` `46683e3b-…` (BasicTimed 1 s; vanilla bandage, mercy, punishment) | `C_BuffManager` | applied in the rehearsal; effect on real injuries not measured (inconclusive) |
| wake | add `remove_unconsciousness` `bd22f98a-…` (used by 72 vanilla scripts, e.g. `fist_fights_common_library/wakeupafterknockout.xml`) | `C_BuffManager` | data-verified use; on the player untested (inconclusive) |
| teleport | player entity position | **no native write in the DLL today**; target `IEntity::SetPos` through the entity system the DLL already walks; name-addressed alternative: the stock `goto` command in `CryAction.dll` (present, untested) | `player:SetWorldPos` observed; **a written Z is held until the body is disturbed** (T4 hovered 45 m up until an impulse) → teleport onto navmesh points or a ground-raycast Z |
| disengage | CVar `wh_rpg_ExcludePlayerFromTargeting` ("for debugging purposes") for the transition | console | exists (code-verified); untested |
| fade | GUIModule `C_FaderController` / `C_BasicFader` — the butchering/digging/alchemy pattern (fade, event at black, fade in) | GUI interface | exists (code-verified); not driven (inconclusive) |
| time passes | exported `C_SkipTime::I()` (PlayerModule); skiptime 6 `Unconscious` gives the vanilla faint | exported singleton | faint observed via the `unconscious` buff |

The rehearsal (§0) ran steps 1–5 through REST and Lua stand-ins in 2.0 ms.
(observed)

### 5.3 Respawn location — the maintainer's choice

| option | how | cost | risk |
|---|---|---|---|
| A. the death spot | no teleport; disengage enemies | none | death loop if enemies stay; needs targeting exclusion |
| B. near the other player | peer ghost position + offset (already streamed) | low | peer may be in the same fight; solo fallback needed |
| C. nearest authored wake-up point | vanilla **`hangoverSpot`** links under each level's `hangoverSpotsHub`, navmesh-checked by `C_PlayerModule::ValidateAlcoTeleportPoints` | medium: enumerate the link graph once per level (unprobed) | skip `hangoverSpot_joke` and `ignoredHangoverSpot` |
| D. nearest settlement | own table of points (or fast-travel POIs) | medium (authoring) | stale after patches |
| E. last bed / last save | position of the last sleep or save | high: tracked nowhere live | — |

Recommendation if asked: **C, then B as a co-op override** — the engine's
own "you wake up over there" points, on navmesh, zero authoring.

### 5.4 Time passing

Off by default in multiplayer. A local skip moves one machine's world clock,
which the WO-38 time sync then fights or propagates. The vanilla faint
(skiptime 6) is the presentation if a skip is wanted. The shipped game
context `crimeSuppressUnconsciousTimeskip` shows the engine can suppress
the unconscious skip. (code-verified name)

### 5.5 Presentation minimum

Fade to black, move, restore, fade in. No camera work is needed: the player
never enters a death or ragdoll state under the guard. The vanilla low-health
red vignette shows while floored and clears with the restore. (observed)

---

## 6. Phase 5 — the gravesite

* **Container: `StashCorpse`** — EntityModule `C_StashCorpse : C_Stash`,
  registered as `CGameObjectExtensionHelper<C_StashCorpse, C_Stash>`,
  exported default constructor. (code-verified)
* `System.SpawnEntity{class="StashCorpse"}` gives an entity with
  `inventory`, `inventoryId`, `interactive=true`, `bLocked=false` and
  `Lock/Phase/Database` properties. (observed)
* **Move**: `grave.inventory:AddItem(itemWUID)` moves an item out of the
  player's inventory (27 → 26, grave 1, owner cleared). The inventory bind
  has no `RemoveItem` on this build; `AddItem` is the move. (observed) The
  native function behind it was not traced. (inconclusive)
* **Persistence**: grave plus two items → `wh_sys_TestSaveGame` → reload →
  the same `StashCorpse` with both items; the entity is inside the save's
  compressed stream. Stashes load through `C_SaveExtensionManager<C_Stash>`.
  (observed; code-verified) Cold relaunch: not run. Do **not** set
  `ENTITY_FLAG_NO_SAVE` on graves.
* **Not observed**: the vanilla loot UI on it (needs a human), and any
  visible model (probably none). Give it a model (grave mound, sack) or a
  marker. (inconclusive)
* **Alternative**: drop as pickables with WO-48's `human:PlaceItem`.
  Already synced to peers, but it leaves a pile.

**What gets dropped — the maintainer's choice:**

| option | note |
|---|---|
| everything | harshest; equipped items leave the player bare |
| backpack only (unequipped) | keeps armour on; simplest fair loss |
| equipped only | punishes gear, keeps loot |
| money only, or a percentage of money | money is an item (groschen), so it moves the same way (inferred) |
| a percentage of stacks | needs a policy table |
| never quest items | always — the soul has a restore-lost-quest-items helper; do not risk them |

**Seen by the other player:** the grave exists only in the owner's world.
Private (owner loots) needs no wire. A marker on peers needs one additive
message. Shared looting needs WO-48-style claims.

---

## 7. Phase 6 — the multiplayer side

* **Today**: death → 0x23/0x24 → peers show a death pose and
  `[dead - reloading]`; vitals with health > 0 clear it.
* **Under C1** `IsDead` never flips, so 0x23 is never sent and the peer's
  ghost stays standing at the downed spot until the stream moves it.
* **Reusing 0x23 alone does not work.** `ReloadReconcile.VitalsClearDeathTag`
  is `health > 0`, and a downed player's vitals report 1.0, so the peer would
  clear the tag on the next vitals packet. (code-verified)
* **Needed, zero wire change**: one DLL → agent pipe frame (e.g.
  `0x91 LocalDowned [on:1]`). While downed the agent sets **0x1F flags bit 0
  (`isUnconscious`)**. Peers already render that as a body
  (`mp_ghost_is_corpse`, WO-38 Phase 6) and resume when it clears.
  (code-verified path) The restore clears the bit and sends health 100. The
  ghost jumps to the respawn point through the ordinary position stream
  (whether the ghost interpolator snaps rather than walks a 30 m jump:
  inconclusive).
* **Optional**: additive **0x3E `PlayerRespawned [x,y,z,reason]`** (next
  free byte per `Protocol.cs`) so peers snap at once and can show a grave
  marker. No `Protocol.Version` bump if additive.
* **Authority**: nothing cares. Claims and holds are per NPC; the teleport
  moves an anchor the owner already scans around.
* **Why it matters**: no reload → WO-110 §3.4's post-load puppet fight is
  no longer triggered by deaths. An NPC the other player killed stays dead
  (WO-86 death sync, no reload to resurrect it).

---

## 8. Recommendation, runner-up, why it lost

**Recommend C1 + C2.** C1 is the engine's own switch at the engine's only
death decision. It covered every source that could be produced solo, kept
the world, quests and save continuous, and switches back to vanilla by
removing one buff. C2 is a small, verifiable pointer swap that closes the
Game Overs C1 cannot see. Everything else is ordinary native plumbing.

**Runner-up: C3, the vanilla unconscious route.** It is the most "vanilla"
feel: the faint, the wake-up, the NPCs reacting. It lost on **criterion 4**
— it skips world time, hands the outcome to NPC crime resolution (arrest,
robbery, throw-out) and resets nearby reputation — and on **criterion 3**:
only weapon blows knock out, so bleeding, poison, falls and starvation still
need C1's handling. Hostile NPCs can still call `DiedWhileUnconscious`, so it
needs C2 as well. C3 is C1 plus side effects we do not control.

**Tempting and wrong: C2 alone** ("block the Game Over, then revive"). By
step 5 the soul is dead, the death is broadcast (0x26, 0x25), weapons are
dropped, and every revive path refuses the player — observed and
code-verified.

---

## 9. Effort for the implementation WO

| piece | days |
|---|---|
| guard: apply, verify (RTTI and vptr checks, fail-closed), re-apply after load and periodically | 1 |
| downed detector on the frame tick (player health via RTTR, debounce) | 0.5 |
| respawn executor: native teleport (`IEntity::SetPos`, or `goto`), RTTR restores, buff removal through `C_BuffManager`, `remove_injuries` / `remove_unconsciousness` | 2 |
| grave: native `StashCorpse` spawn, native inventory move (trace it), model/marker, drop policy | 1.5 |
| C2: vtable-slot guard, whitelist, alive check, loud log | 1 |
| agent + wire: pipe frame, 0x1F unconscious bit while downed, optional 0x3E | 0.5 |
| synthetic suites, solo live gates, one two-player run | 2 |
| **total** | **≈ 8.5**, splittable: (a) guard + respawn + C2, (b) grave + MP |

---

## 10. Side effects and risks to carry forward

* Open-world fistfight and knock-out defeats become respawns (`upr` blocks
  vanilla knock-outs). If that should stay vanilla, drop `upr` during
  unarmed skirmishes — maintainer's call.
* Scripted story deaths of the player would be floored; a quest may stall.
  Out of scope: catalogue any that are found.
* Enemies keep swinging at a 1-hp player until the respawn (≤ one detector
  tick).
* What an NPC fight does after the player teleports away was not observed
  (no fight could be produced solo). (inconclusive)
* The unconscious-buff test left the player in a guard frisk dialogue that
  paused world time; `wh_dlg_ForcedDecision` wants a decision id, not an
  index. (observed; cause inconclusive)

---

## 11. Dependencies found (for the shared-save / autosave WO)

* The guard is non-persistent: re-apply after every load (detect via the
  PlayerSoul pointer or `Gameplay started`).
* Graves are saved in the player's save: a shared-save design has to carry
  them.
* Vanilla Game Over takes save lock type 7; C1 never triggers it. Framework
  exports `C_PlayerProfileWHManager::SetSaveLock` / `AddScriptSaveLock` —
  the lever to block saves during the respawn transition.
* Throwaway saves written this WO: `<saves>/playline1/quicksave025.whs` and
  `quicksave026.whs` (the latter holds a test grave). Both safe to delete.

---

## 12. Address index

| what | binary | RVA |
|---|---|---|
| `C_Soul::SetSoulState` (clamp) | RPGModule | 0x7322C0 |
| raw soul-state writer (death decision) | RPGModule | 0x720BB0 |
| `C_Soul::OnDeathSynchronous` | RPGModule | 0x731270 |
| `C_Soul::OnDeathAsynchronous` → async body | RPGModule | 0x420FD0 → 0x77B9C0 → 0x731540 |
| DR → game_over table | RPGModule | 0xFDA0E0 |
| weapon-hit knock-out decision | RPGModule | 0x52FBE0 |
| apply knock-out (refuses under `upr`) | RPGModule | 0x70F6B0 |
| `C_Soul::Revive` / its refusals | RPGModule | 0x730FF0 / 0x730EA0 |
| params init (`ImmortalHealthMin` 1.0 @ +0x3A0; depths 60/120 @ +0x86C/+0x870) | RPGModule | 0x378240 |
| derived-stat names (base 61; Immortality 0x5D; UnconsciousnessProtection 0x61) | RPGModule | 0x4DB830 |
| `C_ScriptBindSoul::AddBuff` | RPGModule | 0x5EBB20 |
| `C_GameOver` vftable / `Start` / `IsStarted` / `SetUI` | PlayerModule | 0x643190 / 0x178DD0 / 0x179130 / 0x179280 |
| Game Over completion / dispatcher / lambda | PlayerModule | 0x178FF0 / 0x1B07B0 / 0x1BABA0 |
| `C_GameOver::BlockSounds` | PlayerModule | 0x179160 |
| `C_SkipTime::I()` (export) | PlayerModule | 0x4C3AD0 |
| `C_UIGameOver` vftable / init | GUIModule | 0x47A3B0 / 0x3954C0 |
| `C_UISaveLoad::LoadLastSavedGame` | GUIModule | 0x319180 |
| `C_GameplayManager::EndGameplay` / `StartGameplay` | Framework | 0x65B40 / 0x65A90 |
| `C_PlayerProfileWHManager::SetSaveLock` | Framework | 0xED970 |
| BT `C_KillNPC::OnInit` ("Killing an Immortal?") | XGenAIModule | 0x4E1C90 |
| BT `GameOver` node reasons | XGenAIModule | 0xEE1E70 |

Buff GUIDs used or cited: `death_protection_cutscene`
`6f706644-e28a-41a9-9674-5f19dea03bf1` · `death_protection_nonpersistent`
`0f6bc79a-fc67-4aab-a797-4a9d4e4c2dc5` · `death_protection`
`c7c79394-cd16-4d86-a029-f8a5f6623f9d` (persistent — avoid) ·
`player_immortalityOnly_nonPersistent` `89739dbc-fb20-4a28-8b70-986ab9b5f79a` ·
`test_bleeding` `b0247507-ca18-4277-a037-ee3a9274e625` · `deadly_poison`
`8544ebca-1e30-400c-b31c-2a1839f1cab8` · `unconscious_nonpersistend`
`f8d60fe4-e2c1-420a-946a-213e1cd09265` · `remove_injuries`
`46683e3b-e261-412f-b402-99ee17dda62a` · `remove_unconsciousness`
`bd22f98a-e61f-4d83-b39c-79d1d85b6b91`.
