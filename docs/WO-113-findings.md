# WO-113 — findings: death without Game Over (C1 + C2), 0.27.0

Evidence marks: (observed) = seen live in this WO; (code-verified) = read in
the disassembly of the installed Modding Tools 1.5.5 binaries; (data-verified)
= read in the shipped game data; (synthetic) = a test harness, no live game;
(inconclusive) = not settled. Solo only: **nothing here is two-player
evidence.** `<game>` = the Modding Tools install root.

---

## 0. Answer first

* **Shipped (0.27.0):** in a multiplayer session with `mp_respawn on`
  (default), a lethal downing never reaches Game Over. Death, bleeding,
  poison, starvation, falls, weapons → a grave with everything but quest
  items, a 6 s black screen, a wake at the nearest blackout wake-up spot at
  least 100 m away. A fistfight loss → a knockdown: black screen, the game's
  own `StopFight` ends the fight, wake where you fell at 30 hp. An execution
  → the crime is reconciled, the punishment gameplay is ended, wake outside
  the settlement. Off, or no session: vanilla death, exactly. (observed)
* **All in native C++.** Lua owns only the `mp_respawn` toggle and the build
  marker. Every address is re-found at runtime by anchor (§4); every piece
  fails closed on its own and says so in `WO113-BUILD`.
* **Found and fixed live:** a crash opening the full map (map marks held raw
  pointers to entities a load had destroyed, §5.1); fall damage after a hit
  plus a lower teleport (§5.4); bleeding surviving the restore (§5.5); a
  fist fight that never ended (§5.8); graves floating (§5.12); respawn next
  to the killer (§5.9); a whitebox placeholder model (§5.12).
* **Deviations from the WO, all agreed with the maintainer:** wake ≥ 100 m
  from the death (not "nearest"); a 6 s black hold; grave model; the
  knockdown's fight-ender is `StopFight` (the WO's "disengage the attacker"),
  not the exclusion alone.
* **Not run:** a quest brawl (no reachable quest fistfight in the throwaway
  save), a real execution (synthetic trigger only), two players.
* **Carried forward, highest risk first:** quest scripted deaths that use a
  death-shaped Game Over id are swallowed (§7); NPCs may rob or arrest a
  player during the vanilla knockout — not our path, but still reachable by
  quests (§5.8); the black screen has no caption (§8).

---

## 1. Predictions — committed before the first two-player 0.27.0 session

Both players on 0.27.0 through the launcher, a relay, a town and its
outskirts. "A" dies or is knocked down; "B" watches. WO-110's predictions do
not apply to this layer.

| # | prediction | P |
|---|---|---|
| P1 | Both native logs carry `WO113-BUILD … guard=armed c2=installed … knockdown=disengage stop_fight=on` | **0.95** |
| P2 | A dies to an armed NPC: A never sees a Game Over; B sees A's ghost fall (0x1F bit 0) within 0.5 s and snap to the wake spot (0x3E) | **0.80** |
| P2a | …B's native log shows `mirror shown … model=yes marker=yes` and B's map shows a grave icon at A's death spot | 0.70 |
| P2b | …B cannot loot the mirror (no interaction prompt at all) | 0.90 |
| P3 | A loots the grave empty: A's cross and icon vanish within 5 s; B's within 5 s + transit | 0.85 |
| P4 | A reloads a save that predates the grave: B's mirror and icon vanish within 1 s of A's load (vanished → 0x42) | 0.70 |
| P5 | B reloads: B's mirrors of A's graves come back within 30 s (A's heartbeat) | 0.80 |
| P6 | No map-screen crash on either machine all session | 0.85 |
| P7 | A's fist knockdown: the attacker walks off after the wake (`StopFight sent`), no weapon drawn within 8 s | 0.70 |
| P8 | No death wakes A within 100 m of the death spot | 0.95 |
| P9 | A mixed 0.26.x / 0.27.0 pair is refused at the handshake with both messages | 0.98 |
| P10 | An execution, if anyone gets one: `punishment gameplay ended (disabledEvents true -> false)` and random events resume | 0.55 |

**Top failure modes, with the line that identifies each:**

1. **A quest's scripted death is swallowed** (§7): `MP-GAMEOVER id=1|26 decision=swallow`
   during a quest scene, then the quest does not advance. Fix: reload.
2. **ExecuteTeleportImpl refused mid-combat**, fallback used:
   `the spot teleport left the player … goto-shaped fallback applied` —
   expected; a second downing inside 10 s is `floored again … inside the grace`.
3. **No navmesh under the grave:** `ground snap … 4x ranges found nothing
   either` → the cross may hover.
4. **The re-approached NPC re-engages** after the 8 s exclusion (he
   remembers the assault) — `classify -> knockdown` again.

---

## 2. What shipped

| piece | behaviour | evidence |
|---|---|---|
| C1 guard | mod buff `kcdmp_death_guard` (imm=1, upr=1, non-persistent) only while in a session and `mp_respawn on`; re-checked every 250 ms (a load strips it) | observed |
| detector | health at ImmortalHealthMin (1.0) for 2 × 100 ms; stands down for 9 quest immortality buffs | observed |
| classifier | knockdown vs death (§3) | observed |
| death | fade 0.8 s → grave → cleaners + native HealBleeding → wake spot ≥ 100 m → fall damage held 3 s → 6 s black → fade in 1.2 s → 8 s targeting exclusion | observed |
| grave | StashCorpse at the navmesh ground − 0.2 m; everything but quest items (keyring stays); `conciliation_cross_d.cgf` in slot 1; map mark type 0x2B (Grave); name `kcdmp_grave_<id>_<worldms>`; saved with the game; expires after 3 game days; removed when looted empty | observed |
| knockdown | fade → restore to 30 hp → `wh::rpgmodule::StopFight` for the player's skirmish → 6 s black → wake in place → 8 s exclusion | observed |
| execution | Game Over 44 swallowed → grave → `ReconcileWithPublicFriends` → punishment gameplay reset → wake at the nearest spot outside every settlement / crime district | observed (synthetic trigger) |
| C2 | `I_GameOver::Start` vtable guard: ids 0–8 and 26 with the player alive, and 44, swallowed; everything else passes | observed |
| load sentinel | a NO_SAVE TagPoint; its disappearance = a load → graves re-found, marks re-made, vanished graves announced | observed |
| peers | 0x3E/0x40/0x42 ↔ 0x3F/0x41/0x43; mirrors are SmartObjectHolder + cross + mark, NO_SAVE, never lootable; cleared on the owner's disconnect; re-announced on connect and every 30 s | observed (synthetic peer) |
| toggle | `mp_respawn on\|off`, clean preset on, legacy off, forwarded Lua → agent → pipe 0x0D | observed + synthetic |

---

## 3. The knockdown rule (stated)

A downing is a **knockdown** only if all hold; anything else, or anything
unreadable, is a **death**:

* a recent attacker: combat history with the player within 3 s, within 10 m;
* no hostile within 10 m with a weapon in hand (`HasMeleeWeapon ||
  HasMissileWeapon`, combat history within 30 s);
* the player has no weapon in hand (sheathed counts as unarmed);
* the player is not bleeding, poisoned or starving.

After a knockdown: health 30 (stamina full), bleeding cured, not downed
again at once (observed: 30 hp held through the wake). The fight ends via
the game's own `StopFight` (§5.8); an 8 s `wh_rpg_ExcludePlayerFromTargeting`
covers the first seconds after the wake. No unconsciousness, so no robbery,
arrest or time skip from our side.

---

## 4. Addresses — every one re-found by anchor on this install (Modding Tools 1.5.5)

All verified at every injection this WO (observed); none trusted from an RVA.

| piece | address found | anchor | also checked |
|---|---|---|---|
| C_GameOver vftable | PlayerModule+0x643190 | RTTI `.?AVC_GameOver@playermodule@wh@@` | slot 1 = +0x178DD0 references "Game over is already started" and "wh::playermodule::C_GameOver::Start" |
| C_BuffManager | RPGModule+0xC94578 | RTTI + the scriptbinds by name | `call [rax+0xE0]`; slot 2 references "…AddBuffOwned"; slot 0 calls slot 2; the per-soul list `+0x5B8/+0x5C0` |
| hangover walk | PlayerModule+0x443410 | the one function referencing "Unable to find HangoverSpotsHub from sa_land (via link '%s')" | 15 instruction patterns |
| gEnv | PlayerModule+0x890340 | lifted from the walk function (`48 8B 05` then `mov rcx,[rax+0xA0]` within 16 B) | CEntitySystem / CXConsole by RTTI; SpawnEntity/RemoveEntity by string |
| fader | C_FaderController | RTTI | owns a C_BasicFader by RTTI |
| player teleport | C_Player slots 0xEE0 / 0x3B8 | RTTI `C_Player` | tail-jumps to ExecuteTeleportImpl / CorrectZOffset |
| inventory move | C_Inventory slot 0x10 | RTTI | equals the export `C_ItemHolder::TakeItem` |
| world clock | C_Calendar, gi+0x1B0, +0x68 | RTTI | SetCalendar writes gi+0x1B0; SetWorldTime owns +0x68 |
| map marks | C_UIApse / C_UIMap, slots 0x50/0x58/0x60 | RTTI + the ShowMapMarker body ("no marker object on input") | XGenAI exports `AIObjectManager`, `ai_cast_impl<C_LinkableObject>` |
| reconcile | C_RPGUtils, gi+0x138→0xB0→0x1E8 | RTTI + the RTTR global body bytes | — |
| settlement test | XGenAI area core | the `IsPointInAreaWithLabelWUID` scriptbind → core | prologue |
| bleeding cure | runner / create / configure | the `HealBleeding` scriptbind body | three byte sequences |
| StopFight | RPGModule+0x1A1020 | the RTTR registration (the one function referencing "wh::rpgmodule::StopFight"): the `lea` after the name store | function start (.pdata); takes the skirmish lock `lock inc dword [rdi+0xDC]` |
| punishment reset | ConceptModule FindNode / GetPort / Execute | exports | C_ConceptModule / C_ConceptManager by RTTI; the port's slot 15 calls `C_Node::Execute`; the State reads as an rttr bool |
| script contexts | C_ScriptContextManager slots 2/7 | WO-68's module (vftable RTTI + prologues) | used once (§5.10) |

---

## 5. New findings

### 5.1 Map marks keep raw pointers across loads — the map-screen crash (observed, code-verified)

* The maintainer opened the full map after two reloads: the game crashed
  right after `CryGFxFileOpener::OpenFile(), 'Libs/UI//ApseMap.gfx'` (observed;
  BugSplat kept only kcd.log and the save).
* `C_UIMap` slot 0x50 (GUIModule 0x5A550) stores the **raw**
  `C_LinkableObject*` in the mark (+0x10); slot 0x58 adds it to the vector
  at map+0x5D0 (+ an add count at mark+0x18, a UI element at map+0x5E8);
  slot 0x60 removes it without reading the linkable. Only the destructor
  (0x4C9E0) frees the vector; the map is part of the APSE UI object.
  (code-verified)
* A same-level load does **not** clear marks: 18 marks before a load, 18 after,
  our stale one among them (observed via the `mapdump` count).
* Fix: every world change removes our marks from the map before re-making
  them; a per-sample guard removes a mark the moment its exact entity
  instance is gone. Map opened fine after a reload with a grave and after
  one with a purged peer mirror (observed ×3, maintainer).

### 5.2 Map mark types are the POI enum (code-verified)

GUIModule 0x24200 names them: 0 Checkpoint (the player's single waypoint),
1–3 Main/Side/Micro, 4 QuestGiver, 5 ActivityGiver, 6 Hub, …, **0x2B Grave**,
0x2D ConcCross, 0x30 GeneralPoi, … (97). All 97 categories enabled
(observed). The type-0x2B mark draws a grave icon at the grave (observed,
maintainer). The game's own 17 marks in this save are all source 2 NPC marks
(QuestGiver/ActivityGiver/Hub/SkillTeacher/PoiTipster/Barber); no Checkpoint
— an earlier "waypoint near Troskowitz" sighting was one of those (observed).

### 5.3 A peer's mirror needs a WUID and a linkable (observed)

`classprobe` of runtime NO_SAVE spawns: TagPoint, SmartObject, AnimObject,
GeomEntity, RigidBodyEx, BasicEntity → no WUID, no linkable; **SmartObjectHolder**
and StashCorpse → both. StashCorpse is a two-way stash (a peer could deposit
into a NO_SAVE entity and lose items), so mirrors are SmartObjectHolder
("Default" smart-entity template, no helpers, no player actions). BasicEntity
also loads a default pyramid and physicalizes it as a pushable rigid body.

### 5.4 A hit arms the fall tracker; a lower teleport then kills (observed)

TakeDamage + a teleport 19 m down → floored again 125 ms after the wake.
Same hit + 0 m teleport → nothing; no hit + 42 m drop → nothing; hit + 19 m
with `wh_rpg_DisablePlayerFallDamage 1` → nothing. Shipped: the CVar held
during the wake teleport and 3 s after, the previous value restored.

### 5.5 Other restore defects found live (observed)

* Wound bleeding is not a buff: it survived the restore and floored the
  player again. Native HealBleeding for body parts 1–6 → `IsBleeding now no`.
* `remove_all_posions` had a wrong GUID (`cannot find buff`); fixed → 3/3 cleaners.
* `ExecuteTeleportImpl` wants the spot's **WUID**; the hub links are entity
  **GUIDs** (`Place for player teleport wuid [<invalid>…] not found`).
  Converted per call (WUIDs differ per session).
* `buffs::definition_exists` (buff manager slot 0x38) reported a loaded row
  missing — it is unreliable and no longer used for any decision.

### 5.6 NO_SAVE entities are purged by every load (observed)

A NO_SAVE mirror did not survive a reload. Used as the load signal (a TagPoint
sentinel): graves are re-found with the session off too (observed), and a
grave the new world lacks is announced removed (`is not in the new world …
peers drop it` → 0x43 at the peer, observed).

### 5.7 upr=1 is unconsciousness protection (data-verified)

The shipped `unconsciousness_protection*` rows carry `upr=1` alone. Under the
guard the player can never be knocked out — so the game's own fight
resolution, which needs an unconscious loser, never runs.

### 5.8 Ending a fistfight — three builds, maintainer-attended (observed)

| build | result |
|---|---|
| exclusion only (the WO design) | woke in place, no grave, HUD "You were knocked out." — the NPC stayed angry, drew an axe, chased |
| vanilla knockout (imm-only guard + unconscious buff) | `Skirmish event: SoulUnconscious` → both removed from the skirmish; the NPC opened a pay-to-make-it-right dialogue — the vanilla aftermath the WO rules out |
| **`StopFight`** (shipped) | `StopFight sent to the player's skirmish`; `SkirmishVictory`/`SoulRemoved`; the NPC walked away. Re-approached, he was angry and drew his axe; left alone, he went back to his routine |

`wh::rpgmodule::StopFight(const Souls&)` (code-verified): for each soul, the
skirmish manager (0x5D2A70) finds its skirmish by soul id (C_Soul
`vtbl[0]` = `this+0x40`; 0x646640), and every soul of every such skirmish
gets a StopFight message. It is the concept function quests use. The vanilla
knockout stays as a test-only fallback (`knockmode knockout`).

### 5.9 The nearest wake spot can be next to the killer (observed)

A weapon death 10 m from a spot woke the player beside the NPC, who killed
him again. Shipped (maintainer's call): the nearest spot ≥ 100 m from the
death, else the nearest; 8 s targeting exclusion from the wake. Observed after:
230–244 m, exclusion ON.

### 5.10 Brawl facts (data-verified)

* The WO premise "the quest stops the fight at health < 20" is **refuted**:
  in `fist_fights_common_library` 20 is "health at which nobody will want to
  fight" (a pre-fight dialogue gate); 70 is "the opponent bandages". Fights
  end on the loser's knockout (`delka_knockoutu` 10 s,
  `wakeupafterknockout` adds `remove_unconsciousness`).
* Only one brawl (`socky/…/hospodska_bitka`) adds
  `player_immortality_nonpersistent` — the detector stands down for it.
* `crime_suppressUnconsciousPlayerShenanigans` is a **game** context, not an
  entity context: our entity-context setter cannot resolve it (observed).

### 5.11 Execution and the punishment gameplay (observed on a synthetic trigger)

`nextnextgenpunishment`'s State `disabledEvents` is set by a punishment and
cleared only by `punishmentdone`, which an execution never reaches (data-verified).
Fired SetTrue → `Disabling random event by tag 'All'`; then `gameover 44` →
`SetFalse fired; read back false` → `Reenabling random event by tag 'All'`
(observed). The port's slot 15 (ConceptModule 0xCC580) checks CanTrigger and
calls `C_Node::Execute` on the owner node (code-verified). A real arrest and
execution was not run.

### 5.12 The grave model and height (observed, maintainer)

* `task_specific_props/religious/cross_makeshift_a.cgf`: a hand-held prop —
  lay on its side and floated.
* `graves/grave_makeshift_a_wb.cgf`: a whitebox blockout (material
  `whitebox.mtl`) — the red/white placeholder texture.
* 21 textured, level-placed candidates shown live; the maintainer picked
  **`conciliation_crosses/conciliation_cross_d.cgf`** (mesh base at −0.055 m,
  identity node transform — code-verified from the CGF).
* The navmesh can sit above the terrain: 91.01 vs 90.83 at the test grave
  (observed). Shipped: navmesh snap − 0.2 m; a 4× wider retry when the first
  projection misses (observed miss: `no navmesh under (2431.6, 1731.4, 89.4)`).

---

## 6. Phase 8 — solo smoke

| # | item | result |
|---|---|---|
| 1 | not connected: lethal hit → vanilla | **pass** — session off: `guard removed`, `Soul died`, `MP-GAMEOVER id=4 decision=pass`, Game Over screen (observed) |
| 2 | connected, `mp_respawn off` | **pass** — Lua `MP-RESPAWN-TOGGLE set=off` → agent `mp_respawn off -> DLL` → `DLL took` → guard removed → vanilla death; agent `[death] local player died -- told the relay` (observed) |
| 3 | lethal hit, bleeding, 45 m fall, poison, starvation | **pass** — each floored, classified death with the right cause, respawned at a spot; grave when carrying items; Lua timers alive (a fresh `Script.SetTimer` fired in 0.51 s; emitter heartbeat 0.03 s old after a respawn) (observed) |
| 4 | grave contents, stone, marker | **pass** — 28 moved, keyring kept, money moved (7.9); stone and icon seen (maintainer). Quest items: none in the throwaway inventory (inconclusive) |
| 5 | survives save + reload; cold relaunch | **pass** — after `wh_sys_TestSaveGame` and a reload, and after a fresh game start: 28 items, 7.9, model, mark re-made (observed) |
| 6 | loot empty → all gone | **pass** — through the loot screen: cross and icon gone within 5 s (maintainer); via Lua ×6 (observed) |
| 7 | Game Over guard both ways | **pass** — `gameover 1` alive → swallowed; `wh_pl_GameOverTest` (id 20) → pass → Game Over screen; `gameover 44` → execution (observed) |
| 8 | fist knockdown (maintainer) | **pass on the third build** — §5.8 (observed) |
| 9 | weapon death (maintainer) | **pass** — armed player vs armed NPC → death, grave 28 items, wake 244 m (observed) |
| 10 | quest brawl | **not run** — no reachable quest fistfight in this save (maintainer) |
| 11 | pipe frames and wire messages on the agent console | **pass** — 0x0C/0x0D/0x0E/0x0F/0x88/0x91/0x92/0x93 and 0x3E/0x40/0x42 ↔ 0x3F/0x41/0x43 with a real agent, a local relay and a synthetic peer (observed) |

---

## 7. Story-death catalogue (data-verified; catalogue only, per the WO)

Every scripted Game Over in `Scripts.pak`, with what the C2 policy does.
**Death-shaped ids with the player alive are swallowed and become a
respawn — a quest that expected a reload may not advance** (risk, carried).

| source | id (row) | nodes | policy |
|---|---|---|---|
| quest GameOver | 1 DiedInCombat — e.g. `kutnohorsko/erik/…/duel_s_erikem.xml` | 3 | **swallowed** (respawn) |
| quest GameOver | 26 DiedWhileUnconscious — e.g. `klaster/…/prepadak/souboj.xml` | 7 | **swallowed** |
| BT GameOver | DiedWhileUnconscious — `interrupt_attack`, `interrupt_animal_attack`, `playerUnconsciousAfterSkirmishResolve` | 5 | swallowed (the player is never unconscious under our path) |
| BT GameOver | DiedInCombat — `resolveCrimeDialogue`, `selfhelp_resolveCrimeDialogue` | 2 | swallowed |
| quest GameOver | 44 crime execution — open-world punishment and `kutnohorsko/erik/hibernables/arrest.xml` | 4 | **swallowed → execution respawn**; only the open-world punishment is reset (§5.11); a quest-specific arrest keeps its own state |
| BT / quest | 68 bohutaArrested | 2 + 8 | pass |
| quest | 10 and 39–98 (plot failures, 49 ids with nodes; 14 and 32 only in `Quests/Testing`) | 1–4 each | pass — vanilla Game Over |
| quest | Reason from a port, not a constant (`sedmStatecnych/h/game_over.xml`) | 4 | decided at runtime by the id |

The 69 rows of `game_over.xml`: 0–8 deaths, 10 LostABattle, 20 Test,
26 DiedWhileUnconscious, 39–98 plot. No drowning death exists (WO-111).

---

## 8. Not done, inconclusive, stated plainly

* **Two players: everything.** Every §1 row is a prediction.
* A quest brawl (item 10); a real arrest-and-execution; a quest story death.
* Quest items in a grave (none in the save).
* The 4× snap retry has not yet been seen to find ground (only the miss that
  motivated it); the final 0.2 m sink was not re-checked by eye.
* Robbery during a *quest's* knockout is untouched (the shenanigans context
  is a game context, §5.10).
* No caption on the black screen (the maintainer asked for "You died" /
  "You were knocked out", like the sleep screen): the game draws those
  through its fader/text-cutscene UI, not reached yet.
* `crime_suppressUnconsciousPlayerShenanigans` and the vanilla-knockout path
  remain in the DLL as test-only code.

---

## 9. Corrections to the record

* WO-111 §3.7 / this WO's brief: brawls do **not** stop at health < 20 (§5.10).
* "Map marks are not saved (re-add after every load)": true of the save file;
  in memory they **persist** across same-level loads (§5.1). Re-adding without
  removing leaks dangling marks.
* WO-111 §5.2 listed `IEntity::SetPos` as the teleport; the shipped primary is
  the game's own `ExecuteTeleportImpl` (with a WUID), the SetPos-shaped path is
  the fallback (observed refusing mid-combat once, fallback applied).

---

## 10. Open, carried forward

1. Story deaths through death-shaped ids (§7): a per-quest pass list, or pass
   while a quest scene owns the player.
2. A caption on the black screen (§8).
3. Terrain-height snap (I3DEngine elevation) instead of navmesh − 0.2 m.
4. The attacker's grudge after a knockdown (§5.8) — vanilla-like, by design
   for now.
5. `buffs::definition_exists` — find the real definition lookup or delete it.
