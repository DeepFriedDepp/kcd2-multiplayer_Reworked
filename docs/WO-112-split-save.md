# WO-112 — the split shared save

Session 2026-09-23, solo, Modding Tools build (1.5.5, the running 0.26.5 pak,
no DLL injected, no agent). Progress, method, gaps, side effects:
`docs/WO-112-progress.md`. Read first (all read): WO-109 audit §1.2/§1.4 +
progress §2, WO-110 findings, WO-96–WO-99.5, WO-48, WO-111 (both docs).
`docs/WO-113-findings.md` does not exist yet.

Evidence marks: (observed) / (code-verified) / (synthetic) / (inconclusive).
(data-verified) = read in shipped `Tables.pak` / `Scripts.pak` /
`IPL_GameData.pak`. (save-verified) = decoded from a real `.whs` with
`tools/Read-SaveAnatomy.py`. "The call succeeded" is never used as "the thing
happened": every live write below was read back, and the writes that matter
were read back **from the saved file after a save and a reload**.
**No code shipped. No pak, no installer, no VERSION bump. Nothing ran
two-player.** Paths: `<install>`, `<saves>`, `<repo>`. RVAs: this install's
binaries, image base 0x180000000.

---

## 0. Answer first

**Achievable: yes.** Every piece has a route. Most were observed working,
and the rest are code-verified with a named live test.

* **Henry is one record.** Inventory (money included), equipment, stats and
  skills, perks (the journal codex is perks), persistent buffs and injuries
  and vital states all sit in a single RPGModule soul record, `player_henry`
  (`4c2dcffb-dea1-6263-72d7-b39f4db2d8b5`). The rest of Henry is six small
  side blocks. (save-verified, §1.3)
* **The world refers to "the player" by identifiers that are identical on
  every machine:** soul GUID `4c2dcffb-…` (a database row) and entity id
  `0x7777`. A host world loaded on the joiner therefore points every "Henry"
  reference (crime memory, NPC opinion, smart-object users) at the joiner's
  local Henry. No id remapping is needed. (save-verified + observed, §1.5)
* **The save format is fully open and reproducible.** It is a nested TLV tree
  of zlib blocks with a 64-byte footer. The footer's integrity check is **an
  MD5 we can recompute**: it matched on all 223 saves on disk, across two
  builds. So "strip
  the host's Henry before sending" is feasible, not speculative.
  (observed, §1.1, §2.4)
* **Runtime stamping works for the categories that matter.** Item create and
  delete (exact and silent through RTTR), money, equip/unequip, perk
  add/remove, injuries and states were each written live, saved, reloaded and
  read back. (observed, §2)
* **The pause lever keeps the mod alive.** `Calendar.SetWorldTimeRatio(0)`
  froze the world clock while a 100 ms Lua timer chain kept firing. With
  `wh_ai_PauseNPC` for the NPCs, that is the join-gap pause. (observed, §3.2)
* **Host-only saving has a native lever.** A named script save lock blocks
  every save type except QuickSave, and **every load wipes it**, so it must be
  re-asserted after each load. (observed + code-verified, §3.6)
* **The dialogue question is answered at the mechanism level.** A
  player-initiated conversation is a request the NPC's **brain** must pick up.
  A suspended brain queues it and the request times out. So on the joiner, a
  host-owned (suspended) NPC cannot be talked to through the vanilla path.
  A forced dialogue bypasses the brain, but still waits for the player's
  interaction. (observed, §4.3.3)

**Biggest risk: world-mutating player actions on the joiner.** The joiner's
game is a full simulation. A conversation, a trade, a pickup, a crime or a
quest beat changes the joiner's local copy of the world, not the host's.
Among these:
* **Crime** keys on the local-player global `$__player`, so a ghost cannot
  commit one in the host's world. (data-verified)
* **Dialogue** needs a live brain.
* **Quest-item moves** are local events.

So "one world" holds at join time by construction. Keeping it one world
**during** a session requires routing each of these through the host
(§4, §6).

---

## 1. Phase 1 — save anatomy

Tool: `tools/Read-SaveAnatomy.py` (read-only; `map`, `henry`, `diff`, `find`,
`entity`, `verify`). Saves read: playline1 `quicksave021`–`030`, playline2
`save021`, playline0 `save245` (build 1.1.1, late game), playline3
`autosave003`.

### 1.1 Container and stream (observed)

| layer | layout | evidence |
|---|---|---|
| file | `[u32 FFFFFFFF][i32 descLen][XML C_SaveGameDescription]` + `{[i32 clen][i32 rawLen][zlib] \| [-1][rawLen][raw]}*` + 64-byte footer | `SaveGameReader.cs` (WO-96); re-confirmed |
| footer | `'PBX0'` magic + 16-byte **MD5** + zeros. MD5 = md5(whole file up to the footer + the footer with the 16 bytes zeroed). This is CryEngine's XMLCPB convention (`FILETYPECHECK`, "md5 check failed. savegame File corrupted!") | all 223 saves on disk verify: 143 build 1.1.1, 80 build 1.5.5 (observed, `verify`) |
| stream | `[u32 23]` then TLV `[u16 tag][u32 len][payload]`, nested; leaves carry raw fields | observed |
| top | `0x1F5` (501) header · `0x1F4` (500) body · `0x1FA` (506) end | observed |
| body | `0x1FB` playline random seed (507) · `0x1F6` = "chunk 502" (pre-level modules) · `0x1F7` = 503 (CryEngine data) · `0x1F8` = "chunk 504" · `0x1F9` = "chunk 505" | chunk numbers from the game's own save log (observed); `0x1FB` same within a playline, different across (observed), seed per code (code-verified) |
| module chunks | `0x7300 + n`, one per module. Each tag is an immediate in **exactly one** module DLL: 7300 Test, 7301 GUI, 7302 Entity, 7303 Quest, 7304 Shop, 7305 Environment, 7306 XGenAI, 7308 RPG, 7309 Player, 730A Concept, 730B Combat, 730C WHGame | immediate scan (code-verified); the save log names modules and sizes per chunk (observed) |
| named blobs | `0x20A7` string / `0x20A8` int / `0x20A9` blob, NUL-terminated name | observed |
| `GameState` etc. | hashed-key token stream: `[type:u8][FNV-1 32-bit key hash][value]`, `0x00` group start, `0x01` group end; types 02 string, 03 bool, 04 f32, 06 vec3, 07 quat, 08 ang3, 0B i32, 0D u8, 0F u32, 10 u64, 12 i64, 11 script table | the whole 1.98 MB `GameState` decodes, 206,356 tokens, 0 unknown (observed); key names confirmed by hash (`id`, `pos`, `name`, `class`, …) |

Save cost (observed, `quicksave027`): 4,476,836 B inflated → 1,427,154 B
file. Generation 44 ms; CryAction entity serialize 63 ms. A 100 ms Lua timer
chain stretched one tick to 121 ms. Late game (1.1.1, Kuttenberg): 12.9 MB
inflated, ~3.9 MB file (save-verified).

### 1.2 Block map

Class: **W** world · **H** Henry · **M** mixed · **meta** bookkeeping · **?** not understood.

| path | owner | class | contents | evidence |
|---|---|---|---|---|
| `01f5/*` | save | meta | binary description, used mods | observed |
| `01f4/01fb` | save | meta | playline random seed | observed + code |
| `01f6/7309` | PlayerModule | W | homestead build states (`house_*`, `room_*`, `yard_*`) | save-verified |
| `01f6/7303` | QuestModule | W | one u32 | save-verified |
| `01f6/730a` | ConceptModule | W | random-event place + `<Roots>` ConceptState XML = **all quest state** (WO-96) | save log: random events saved here (observed) |
| `01f7/{version,level,gameRules,build,Bit,checkPointName,saveTime}` | CryAction | meta | | observed |
| `01f7/Timer, TerrainState, GameTokens, FlowSystem` | CryAction | W | TerrainState grew 238 B → 297 KB in WO-111's session (cause unknown) | save-verified |
| `01f7/ViewSystem, MatFX` | CryAction | meta | | |
| `01f7/GameState` | CryAction | **M** | `BasicEntityData` (12,082 entities incl. `Dude`: id, GUID, flags, pos, rot, name, class); `NormalEntityData` (883 property sets); `Layers` (1,842); `ExtraEntityData` (2,145 game-object extensions incl. `Dude`: dirt, blood zones, `fastTravelEnabled`, view angles); timers; breakables | observed decode |
| `01f8/7302` | EntityModule | W | `0x0006` stash records keyed by entity GUID (**graves**, quest-added stash items); `0x0008`/`0x000C` per-object params; `0x000A` quest-item manager (live managed quest items, items held for the other level, per-class wear) | save-verified; grave record appeared in q026 (observed) |
| `01f8/7308/3529/1161` | RPGModule | **M** | ~6,400 soul records: 0x115E full, 0x115D short. **One is Henry.** Also `player_bohuta` (the Godwin playable-segment soul) | save-verified |
| `01f8/7308/3529/1160` | RPGModule | **M** | companion list `[master soul][companion soul]` — player horse, dog; empty in early saves | save-verified (agent, late save) |
| `01f8/7308/3530`, `352b`, `3531` | RPGModule | ? | small; 3530/3531 change minute to minute | observed |
| `01f8/7308/352c` | RPGModule | W | 1,059 faction nodes with relation/reputation records | save-verified |
| `01f8/7308/352d` | RPGModule | H (inconclusive) | 1.2–1.7k POI records, 74 location records, discovered POI types (laundry, fasttravel, shop, …) = map knowledge. POI count grew 1,550 → 1,713 across WO-111's teleports | save-verified |
| `01f8/7308/352e` | RPGModule | H | 204 player statistics (kills, distances, items used, **diet timers** that drive buffs) | save-verified |
| `01f8/7309` | PlayerModule | **M** | `0x0000` tutorials seen (H); `0x0001` per-level map fog grid (H); `0x0004` random-event director (W) | save-verified |
| `01f8/7304` | ShopModule | W | per-shop diffs only (items sold in, stock counters); stock lives in shop chests | save-verified + agent |
| `01f8/7301` | GUIModule | H | tracked quest, journal UI, custom map marker, map filter toggles | save-verified |
| `01f9/1f90` | Framework | W | global game variables (`_SaveGameVersion`, `shop_*`/`haggle_*` scratch values) | save-verified |
| `01f9/1f91` | XBehaviorModule | W | per-NPC records (name + id, hash/value pairs) | save-verified |
| `01f9/7305` | EnvironmentModule | W | weather zones + current preset | save-verified |
| `01f9/7302` | EntityModule | H (?) | list of the player's item instance GUIDs (8 in one sample); meaning unknown | save-verified |
| `01f9/7306` | XGenAIModule | **M** | 1.48 MB. The save log splits it: dictionary 219 KB, smart objects 417 KB, trigger areas 104 KB, DynamicLinkables 119 KB, **NPCManager 478 KB**, perception 17 KB, … It holds ~600 per-entity brain records, including `Dude` (faction `player`, dialog mailbox) | observed log + decode |
| `01f9/7300`, `730b`, `01f6/730c` | Test/Combat/WHGame | meta | empty or `"test"` | |

### 1.3 Where Henry lives (save-verified unless marked)

`player_henry` soul record (6.5 KB early game, 44 KB late game):

| field | contents |
|---|---|
| prefix | soul GUID ×2 (Henry's soul GUID = his shared GUID) |
| `0x1303` | flags |
| `0x12F9` | name `Dude` + entity GUID `0x7777` |
| `0x12FB/0x0927/0x1385` | stat XP, `(id, u32)` pairs; id 8 = hidden `storyProgress` (RTTR `StatsByName`, observed). Raw encoding (inconclusive) |
| `0x12FB/0x0927/0x138B` | states f32: health, stamina, exhaust, hunger, karma, alcoholism (order matched RTTR live values, observed) |
| `0x12FB/0x0927/0x138D` | skill XP pairs |
| `0x12FB/0x0927/0x137E` | **perks**: 56 in the early sample = 53 **codex entries**, 2 location perks, 1 recipe (251 late game). The journal codex is perks |
| `0x12FB/0x0926` | nine f64s (not understood) |
| `0x12FB/0x0928` | **persistent** buff instances only (the two leg injuries in the sample). Non-persistent buffs are never saved |
| `0x12FF` | opinion/renown record: total 0.35 = RTTR `FactionNode.PlayerRenown` 0.35 (observed) |
| `0x1301/0x0007` | inventory: `[instance GUID][u32][class GUID][params]`. Param 0 = **amount − 1** (money 78 saved = 79 live, observed); param 1 is not health (observed). The **KeyRing** is live-only, never saved (observed) |
| `0x1301/0x0006` | equipment: equipped instance GUIDs + preset slots |
| money | an ordinary item, class `5ef63059-…`, amount in tenths of a groschen (79 units = `GetMoney()` 7.9, observed) |

Henry's other footprints, all small: `GameState` `BasicEntity` + `ExtraEntityData`
for `Dude`; XGenAI brain record `Dude` (793 B); `352E` statistics; `352D` map
knowledge; `7309/0000` tutorials; `7309/0001` fog; `7301` journal UI;
`01f9/7302` item list; companion entries in `1160`.

Quest items are items in the inventory carrying item flag bit `0x2`. They
are **owned by quest logic** (§2.3), not by Henry.

### 1.4 Mixed blocks — the stamp risks

| block | what makes it mixed |
|---|---|
| `GameState` | one of 12k entities is `Dude` (position, rotation, dirt, view) |
| soul list `1161` | Henry and `player_bohuta` among ~6.4k NPC souls. NPC records carry opinion-of-player modifiers (`0x12FF`, timed modifiers + total; they drift between saves; semantics inconclusive) |
| companion list `1160` | Henry → his horse and dog |
| XGenAI `7306` | global AI state + ~600 brains incl. `Dude`. Henry's soul GUID appears 28×: 21 in global state (smart-object users, perception), 6 in a deer's brain, 1 in his own record |
| PlayerModule phase B | tutorials + fog (H) beside the random-event director (W) |
| `01f9/7302` | 8 of Henry's item instance GUIDs, in an EntityModule block |

World blocks that are *about* Henry (world by the maintainer's decision):
faction reputation (`352C`), per-NPC opinion (`0x12FF` in NPC souls), crime
memory and escalation (XGenAI; a guard's escalation **survived save + reload**
in this session, observed).

### 1.5 Diffs (`Read-SaveAnatomy.py diff --souls`)

| pair | result |
|---|---|
| `q021→q022`, same playthrough, 1 min | Changed: ConceptState, Timer, TerrainState, GameState, EntityModule `0008`, soul list (**82/6,373 souls**: NPC inventories `0x1301` ×45, NPC states `0x12FB` ×33, opinions `0x12FF` ×15), `3530`, factions `352C`, statistics `352E`, `3531`, XBehavior, weather, XGenAI. Unchanged: quest module, tutorials, fog, shops, journal UI |
| `q025→q026`, same playthrough, 25 min (WO-111: grave, teleports) | + one stash record (the grave's gambeson and boots) in EntityModule `0006`; POIs +163; TerrainState 238 B → 297 KB; 152 souls changed, 5 new |
| `pl1 q025` vs `pl2 save021`, different playthroughs | Same structure. 542 souls differ in content. Runtime souls (events, animals) are unique to each side (60/59). **Authored soul GUIDs identical.** The playline seed differs |

---

## 2. Phase 2 — reading and writing Henry at runtime

Live on `quicksave027`. Written values were then saved (`quicksave028`),
parsed offline, reloaded and read again. "RTTR" = the reflection layer the
DLL already calls by name (`CrySystem.dll` exports; REST `:1403` was the
probe stand-in). Bind names were checked with `type()`. **The shipped docs
over-list:** `SetStatLevel`, `SetSkillLevel`, `AddXP`,
`Calendar.SetWorldTimePaused`, `StartMonolog`, `UnlockRecipe`,
`inventory:RemoveItem`, `ItemManager.CreateItem`, `Player.Sleep`,
`EnablePlayerHorseInventory` are **not registered**. (observed)

### 2.1 Category table

| category | read route | write route | side effects | verdict |
|---|---|---|---|---|
| inventory items | RTTR `Inventory.Items()`/`ItemList` (29 live, observed); Lua `GetInventoryTable` + `ItemManager.GetItem` (class, amount, health, observed) | **RTTR `Inventory.CreateItems(class, amount, ShowUINotification=false, quality, health, condition)`**: exact amounts, silent (2 pears → 2 items; herb +4 → one stack, observed). Delete: Lua `DeleteItem(wuid,n)`, `DeleteItemOfClass(class,n)` (partial stacks), `ItemManager.RemoveItem` (all observed). RTTR `DeleteItems(descriptor)` (code only) | none in log. Quest items are refused by the engine (agent, code-verified) | **round-trips** class/amount (observed through save + reload). Health/quality: RTTR `Item.SetItemHealth` exists, not run (inconclusive) |
| equipment | RTTR `EquipmentManager` maps (observed) | Lua `actor:Un/EquipInventoryItem` (7 → 6 → 7, observed); RTTR `EquipItem`, `UnequipItem`, `EquipPlayersItem`, `UnequipAllArmor` (code) | — | **round-trips** (observed) |
| money | RTTR `Inventory.GetMoney` = 79 (observed) | Lua `RemoveMoney(1.5)` 7.9 → 6.4, `CreateItem(Money, …, 15)` → 7.9 (observed); RTTR `CreateItems(Money)` | — | **round-trips** (observed) |
| stats | RTTR `GetStatLevel(Stat)`, `RPGStats` levels (observed); Lua `GetStatLevel`/`GetStatProgress` with **full names** (`strength`; the documented `str` returns nothing, observed) | Lua `SetStatLevelDebug` **lowers** a level (5 → 3, observed). `AddStatXP` restores but landed **2/256 short** (L5 p0.7266 vs 0.7344, observed). No RTTR write | level-up notification not checked | **partial** (one progress quantum). Exact only via §2.4 |
| skills | as stats (`GetSkillLevel`, observed) | `SetSkillLevelDebug` + `AddSkillXP` registered, not run | — | **partial** (by analogy, inconclusive) |
| perks (codex, recipes, location perks) | **no live route**: Lua `HasPerk` returned false for every perk incl. owned ones (observed); RTTR has no perk member (observed 404). The saved file is the reader | Lua **`AddPerk(defGuid)`** and **`RemovePerk(defGuid)`**: the saved file gained Lichtenstein + indulgence codex and lost Hanush's (observed via `quicksave028`). The docs say `RemovePerk` takes an instance id; the definition GUID works. The native call behind the bind: not traced | codex UI notice not checked | **write round-trips** (observed in save); read = save parse only |
| persistent buffs | RTTR `Buffs` = names of active buffs (observed) | `AddBuff` took effect for `death_protection_cutscene` (in list, observed). `hangover` and `on_washed` returned instance handles but never appeared (observed; cause inconclusive). `RemoveBuff(handle)` → false (observed). Native `C_BuffManager` vtable (WO-111, code) | — | **partial** |
| injuries | RTTR `Buffs` (observed) | `AddInjury(0.4, "arm_left")` → `injured_left_arm` (observed); removal via `remove_injuries` (WO-111) | — | **partial** |
| states | RTTR `GetState` (observed) | RTTR `SetState` (WO-111 observed; stamina clamps to max) | — | **round-trips** (health survived save, observed) |
| position | native local-state read (DLL, code) | Lua `SetWorldPos` (Z hovers, WO-111); native teleport = WO-113 | — | **partial** (WO-113) |
| dirt, blood | — | `AddDirt`/`AddBlood`/`CleanDirt`/`WashDirtAndBlood` registered, not run | — | inconclusive |
| statistics | RTTR `Statistics/CountersByName` (observed) | `Statistics.Set`/`Increment` registered but **no effect** (6 → 6, observed; also unchanged in the saved file) | — | **no write route found** |
| map knowledge | save only; `RPG.GetLocations()` gives names, no discovery flag (observed) | none | — | **no route found** |
| tutorials, journal UI | save only | none | — | **no route found** (cosmetic) |
| companion (horse, dog) | `Player.GetPlayerHorse`/`GetHorseId` (registered, not run) | `SetPlayerHorse`/`ClearPlayerHorse` (registered, not run) | — | inconclusive |
| renown (`0x12FF` on Henry) | RTTR `FactionNode.PlayerRenown` (observed) | `ModifyPlayerReputation`/`SetPlayerReputationDebug` (NPC side, not run) | — | world by decision (option §4.4) |

"Native" in the design means one of three routes: an RTTR call by name (items,
money, equipment, states); the C++ function behind a scriptbind, pinned by
string anchor (perks, stats, buffs); or the soul loader (§2.4). Lua appears
here only as a probe stand-in.

### 2.2 Stamping side effects seen

* Item writes logged nothing; `ShowUINotification=false` keeps the RTTR create
  silent (observed).
* A perk add/remove logged nothing. Duplicate adds from the game's own scripts
  log `cannot add/unlock perk … to Dude` (observed).
* No quest, achievement or crime line followed any write (observed log). The
  one fight in the session was vanilla: an AFK Henry at night without a torch
  escalated a guard (`reakce_na_hrace_bez_pochodne__straz`, repeated), not a
  bind (observed).

### 2.3 Quest items

* **They are world state owned by quest logic.** An item of a quest class
  exists while an `AddQuestItem` effect for it is active. The effect places it
  (NPC, stash, slot, or `player` = Henry's soul) and moves it by switching
  effects. The engine refuses script, player and UI create/move/delete.
  (code-verified: create refusals EntityModule `0x71C738`/`0xB3FFCD`, move
  `0x881535`/`0x8CC688`, script `AddItem` `0xB3F53A`, `RemoveItem`
  `0xB409B6`; data-verified)
* **Identification**, best first:
  1. item flag bit `0x2` at `C_Item+0x60`, read by the engine's own refusals
     (code);
  2. class `IsQuestItem="true"`: 288 classes, 249/250 of those used by the 433
     shipped `AddQuestItem` nodes; RTTR `PlayerItem.IsQuestItem` (data +
     code). Weakness: quests end by giving a keepable non-managed copy of the
     same class;
  3. the save lists live managed ones in EntityModule `0x000A`.
* **Restore helper**: `wh::entitymodule::ReclaimQuestItems(Soul)` (routine
  EntityModule `0xA48780`). Quest-graph only, one shipped use; nothing calls
  it on death or load. (code + data) On load the engine itself recreates
  quest items whose effects "should have been active" (code strings). That
  self-heal was not observed.
* **Rule proposed: quest items are world-owned, and `player` means every
  Henry.**
  * Strip *managed* quest items (bit `0x2`) from the joiner's stamped
    inventory; keepable reward copies stay.
  * The host's quest state places them: `player` binds to Henry's soul, which
    is the same soul on both machines.
  * Pickups and hand-ins travel as quest-state changes (Haste triggers already
    exist: `prepadeni.05_getRing`, `naTroskach.04_presun_ruzenec_k_hraci`,
    `svatba.04_getWine`, `radzigsSword_playerHoldership`, …), never as item
    moves.
* **M01–M51 cases**: 14 of 32 main quests create quest items (94 nodes, 56
  classes incl. level-wide modules). Highest risk:

| quest | item | why |
|---|---|---|
| M12→M31→M51 | Radzig's sword | whole story; reforge changes class/quality per machine; M31 recreates it if missing |
| M06 | turquoise rosary | moves by dialogue, pickpocket or loot |
| M09 | Florian's ring, wine for Capon | guard confiscation opens an objective |
| M05 | Moravian schnaps, cooking scraps, Semine's sword | world pickups; theft tracked |
| M12 | Sigismund's orders, Trosky master keys | orders can end up on an NPC |
| M34→M35 | map, chest key, minting die, Vavak's letter, 3 ledgers | looted; handed in a quest later |
| M37a | Anna's papers (on `player_bohuta`), disguise, certificate | Godwin segment; backup moves |
| M44a | charter, bond, poison book, message, bloody knife | read-to-flag; dog tracks the knife |
| M45→M46 | mint master's key | opens the treasury |
| M46 | prison key | pickpocketed |
| M48c | lambskin shoes | consumed by cooking |
| M49 | Samuel's hunting sword | |
| M51 | Hanush's sword | done when **condition** passes a threshold after sharpening, i.e. on one machine only |

  Money is never a quest item (quest classes are non-divisible), but M03, M06,
  M07, M11, M33, M34, M37b and M44a check or take local Henry's money.
  (data-verified; full census method in the progress doc)

### 2.4 Three stamp routes

| route | how | exact? | status |
|---|---|---|---|
| **S1** field-by-field | Wipe the host's Henry in the loaded world, then apply the joiner's side file through §2.1's routes. The **wipe list comes from parsing the received save offline** (the agent has the file), because perks have no live read | items, money, equipment, perks, states: yes. Stats/skills: ±1 quantum. Statistics, map, tutorials: no route | observed per category |
| **S2** soul transplant | Feed the joiner's `0x115E` record through the game's own per-soul loader: Framework exports `C_InputChunk::Create(I_InputStream&)`, `CreateChildChunk`, `ReadBytes`; RPGModule `C_SoulList::LoadGameSoul` `0x749010` → `C_Soul::LoadGame` `0x72D740` (switch over the same field tags `0x12F8`–`0x1303`; calls `CopySoulFromDB` `0x745840`, `S_SoulPersistentData::LoadGamePostDeserialized` `0x8413B0`) | yes by construction | code-verified path. Whether the first-chunk reset `0x72D520` clears existing perks/items: **inconclusive** |
| **S3** splice before load (the "cleaner later option") | Joiner-side, before loading: replace `player_henry`'s record and the six side blocks in the received file with the joiner's, re-deflate, **re-sign the MD5**, load. The loaded world never contains the host's Henry | yes by construction; the game's own loader builds Henry | format and signature reproduced (observed). A modified save was **not** loaded live (inconclusive). The engine's quest-item self-heal on load would place world-owned quest items on the stamped Henry (code strings, inconclusive) |

**Recommendation: S3 primary, S1 fallback, S2 research.**
* S3 satisfies "stamp replaces, never merges" and "stamp fails → abort" by
  construction: splice, verify offline, then load. It is exact for every
  category, including those with no runtime route (stats raw, statistics,
  map, tutorials).
* S3 can also scrub the description header. That header carries the writing
  machine's Windows account name, which would otherwise reach the joiner
  (observed field; not quoted here).
* Its one unknown is a single live load of a modified file: WO order §7,
  item 5.

---

## 3. Phase 3 — one world save, owned by the host

### 3.1 The join flow, mechanised

| # | step | mechanism | evidence |
|---|---|---|---|
| 1 | host loads its own save | as today | — |
| 2 | joiner at main menu | nothing loaded. The menu itself sets world-time ratio 0 | code (agent) |
| 3 | joiner connects | agent ↔ relay; the game is not involved | — |
| 4a | host pauses | `Calendar.SetWorldTimeRatio(0)` (clock) + bulk `wh_ai_PauseNPC` (AI: 46 NPCs in 1 ms, WO-108) + host input hold (fader; open item) | §3.2 |
| 4b | host writes the world | `Game.QuickSave` / `wh_sys_TestSaveGame`: 44 ms; QuickSave passes script locks; engine locks (cutscene, skip-time, minigame, fast travel, player death) block it, so the host retries until `CanSave` | observed + code |
| 5 | transfer | relay chunked stream + integrity (§3.4) | design |
| 6 | joiner loads | native rescan + load from the menu (§3.5) | code-verified functions; route untested |
| 7 | stamp | S3 before load (or S1 after), then the post-load list (§3.6) | §2.4 |
| 8 | host resumes | ratio back to the value read in 4a (15 in this save); `wh_ai_ResumeNPC` for NPCs not owned by the joiner's streams; both unfrozen together on a relay "go" | observed levers |

Timing budget (observed pieces): save 0.05 s, file 1.4–4 MB, cold menu load
**67 s** (the first load after launch), in-process reload 12–18 s. The host
is paused for roughly a minute on a first join.

### 3.2 Pausing the host while the mod runs (observed)

| lever | clock | NPCs | Lua timers | verdict |
|---|---|---|---|---|
| `SetWorldTimeRatio(0)` | **frozen** (642536 → 642536 over 5 s) | keep walking (4–10 m in 4 s) | **keep firing** (78 → 155 ticks in 5.5 s) | use for the clock |
| `wh_ai_PauseNPC` | — | frozen (WO-107/108) | keep firing | use for NPCs |
| `IsWorldTimePaused` flag | stayed **false** under ratio 0 | — | — | not a pause lever; it reports calendar pause handles (dialogues, cutscenes, minigames; §4.3.4) |
| `Calendar.SetWorldTimePaused` | — | — | — | **does not exist** (string in no binary) |
| `Action.PauseGame` / in-game menu | pauses the game timer | — | **stop** | unusable (WO-110 §3.3) |

Suspension does not survive a load (WO-108). The world save written at 4b
carries unpaused NPCs, which is correct: the joiner's authority lever
suspends them as streams begin.

### 3.3 First join, rejoin, drop

| event | design |
|---|---|
| first join, no Henry file | maintainer's choice: **F1 import** the joiner's own `player_henry` + side blocks cut from their newest own save (the tool already extracts them); **F2 copy** the host's Henry; **F3 fresh** Henry from the database soul. Recommend F1, F2 as fallback |
| rejoin | the file is re-sent fresh every time; the Henry file = the last snapshot from the previous session |
| Henry file updates | during the session, the joiner's agent snapshots Henry periodically (every N min and on disconnect) through the same reads as §2.1, or through a QuickSave → parse → delete (QuickSave passes the script lock; it would write into the joiner's playline and must be deleted at once). Options for the maintainer; the parse route is exact |
| host leaves | the joiner goes to the menu. The world copy is deleted, the last Henry snapshot is kept, the joiner's solo saves are untouched |
| host reloads mid-session | the world rewinds; the joiner goes back to the menu and receives it again. Joiner's Henry: keep the latest snapshot (default) or rewind to the snapshot taken at the host save's time — maintainer's choice |
| NPC death sync bug (peer test: host streamed DEAD, joiner kept ALIVE) | once the world is one save, the **world owner's death wins**: the joiner applies death when the owner streams it, whatever its local copy says. WO-99 Phase 3's "the reloaded save is that player's truth" no longer holds. Fix in the plan (§7 item 2) |

### 3.4 Distribution

* **Size**: 1.4 MB file early game, ~4 MB late game (save-verified). Send the
  compressed file as is; re-compression gains nothing.
* **Transport**: the relay, chunked. The per-client queue is 512 KB (WO-110
  4.4), so use ≤ 32–64 KB chunks with a ≤ 256 KB window and per-window acks.
  New additive message types go after WO-113's allocations (WO-111 proposed
  `0x3E`).
* **Integrity**: SHA-256 over the wire (in the header) **plus the save's own
  MD5 footer**, checked with `Read-SaveAnatomy verify`'s algorithm before
  loading (observed on all 223 saves on disk). A mismatch aborts the join.
* **Joiner UI while waiting**: the launcher/agent window (progress, bytes,
  state). Whether mod Lua can draw at the main menu: inconclusive.
* **Throughput**: at 1 MB/s, 1.5–4 s. Negligible next to the 67 s load.

### 3.5 The mod-owned slot (code-verified by agent + observed)

* **The save list is cached.** `wh_sys_LoadGame` resolves against it, never
  rescans, and silently does nothing for a file that arrived later. Observed
  twice: a new folder `playline9` and a new file in `playline1`. Only
  playlines 0–4 exist. (code)
* **Every load switches the current playline to the loaded save's.** Continue
  and Game Over's "load last save" pick the **newest stored `SaveTime` in the
  current playline** (code, GUIModule `0x319180`). That explains the field
  symptom: a death loading "another playthrough's" save that sat in the same
  folder with a later `SaveTime`. (inconclusive for that session)
* **Native route**: `UpdateSaveGameDescriptions` `0xEF730` (rescan) →
  `GetSaveGameDescription` `0xEF630` → `LoadSavedGame` `0xEFB10` (resets
  locks). From the menu this goes through `SwitchLevelAndLoadSavedGame`
  (WHGame `0x194970`). No API takes an absolute path. (code-verified;
  untested as a route)
* **Scanner rule**: any `*.whs` **without a space** in its name is listed.
  (code)

| option | how | leak risk | cost |
|---|---|---|---|
| **O1 transient file in the joiner's current playline** | write `mpworld<id>.whs`, rescan, load, **delete right after load** and rescan. The agent sweeps stale `mpworld*` files at launch | low. Only a crash between write and delete leaves it, and the sweep catches that | lowest. **Recommended** |
| O2 dedicated playline | e.g. playline 4 | high: the joiner may use it; after a session the menu's current playline becomes 4, so Continue loads the world | medium |
| O3 space in the name | the scanner never lists it | none | needs a hand-built description for an unscanned file (inconclusive) |

### 3.6 Joiner load order and host-only saving

After `Gameplay started` on the joiner, before unfreezing:
1. **save lock**: `Game.AddSaveLock("kcdmp_host_only", …)` or native
   `AddScriptSaveLock` (Framework `0xEDB10`). **Every load wipes all locks**
   (`ResetAllSaveLocks` `0xED8A0` from `LoadSavedGame`; observed: a duplicate
   add is refused before a load and accepted after it);
2. **death guard** (WO-113's non-persistent buff; also gone after every load);
3. **stamp** (S3 happened before the load; with S1, run it here and verify by
   read-back);
4. **position** (WO-113 native teleport) if not spliced;
5. delete the transient file (O1), then report ready.

Nothing on the joiner may save or reload in between (the lock covers saves;
the agent owns loads).

**What a script lock blocks** (code-verified `CanSave` `0xEE410`; observed
where marked):

| save | under the script lock |
|---|---|
| autosave (`Game.SaveGameViaResting`, sleep, quest `SaveGame` Regular) | refused or discarded from the single queue slot (observed: no file) |
| permanent (quest `SaveGame` Important) | blocked |
| manual (Saviour Schnapps, menu Save) | dropped. The **potion is kept** when the save fails (code) |
| exit save (`Save & Quit`) | blocked. **Risk:** Save & Quit waits for the save-end message, then spins on `IsSaving` (code); the joiner may need Quit without save (inconclusive) |
| crucial-decision save | blocked; whether the dialogue waits on it: inconclusive |
| QuickSave | **passes** (observed). Only console `wh_sys_TestSaveGame` and `Game.QuickSave` reach it; the mod never calls either on the joiner |

Stronger alternative: cvar `wh_sys_FreezePlayline 1` kills every save type
including QuickSave (code). It survives loads because it is a cvar
(inference), but it is a test switch with unknown side effects. It could be
belt and braces behind the lock.

### 3.7 Host autosave cadence

* **Cost**: ~50 ms of main thread per save, early game (observed). Late-game
  cost scales with the 13 MB stream (inconclusive, not measured).
* **Triggers the game already has**: quest `SaveGame` nodes, sleep, schnapps,
  Save & Quit.
* **Proposal**: the host enqueues an autosave every 5–10 min through the
  native `EnqueueAutoSave` (Framework `0xEF9E0`, single slot, fires when
  `CanSave` passes). The engine then picks a safe moment (not during a
  cutscene, skip-time or death).
* Autosave files rotate at 100 per type (`wh_sys_PlaylineSavegameCount`,
  observed = 100).

---

## 4. Phase 4 — the decisions, designed

### 4.1 Money per-player → merchants are world

* **Where merchant state lives** (agent C):
  * stock is in the shops' `shopStash` **chest inventories** (171 shops,
    `restock_period=7`), not in merchant souls;
  * merchant gold is the ordinary money item in a shop chest
    (`inventory_shop_money_N`);
  * `C_RestockManager` restocks daily at 03:00, **randomly per machine**;
  * the save keeps only per-shop diffs (`7304`).
  (data + strings)
* **Trade binds always act on the local player**: `AcceptTransaction`,
  `DoMoneyTransaction`, `Negotiation.lua`. So the host cannot run the joiner's
  trade. (data)
* **Design**:
  1. the joiner trades locally: UI, haggle, money on the joiner's Henry;
  2. the joiner's agent sends a **shop delta** (items in/out per shop chest,
     money delta);
  3. the host applies it to its chests natively (`CreateItems`,
     `DeleteItemOfClass`, `MoveItemOfClass`, `RemoveMoney`);
  4. a contested unique item is settled first-claim-wins with rollback
     (WO-48's claim pattern).
* The host's restock is authoritative. The joiner's shop view drifts until the
  next join (v1 accepts this), or the host streams a shop's contents when the
  joiner opens it (v2).
* Per-player-looking world state stays world: `haggle_denial` on a merchant,
  shop reputation.

### 4.2 Horses

* **Model** (agent C):
  * a horse is a `Horse` entity with a soul;
  * **ownership is a companion link** (`1160`), plus `C_RiderPlayerControl`
    (`SetPlayerHorse`/`GetPlayerHorse`), plus BT `GetPlayerHorse`;
  * **saddlebags are the horse soul's own inventory** (a tab in Henry's
    inventory).
  (data + strings)
* **Authority**:
  * the world owner (host) simulates unridden horses;
  * on mount, the **rider's machine** owns the ridden horse: it stays local
    and is driven by the rider's input, while the other machine puppets it;
  * on dismount, authority returns to the host.
  Reuse the ghost-horse adoption (`mp_horse_adopt`, ForceMount guards
  WO-40/58) for the puppet side. This keeps the NPC jitter problem off the
  rider.
* **Legal riding**:
  * mounting a horse that is not your registered one runs horse-theft
    detection on the rider's machine (`crime_playerMounted`; `horseTheft` fine
    2000);
  * set `mountIsLegal` on shared horses, or apply the context
    `crime_ignoredHorseTheft_Horse` through WO-68's native context setter;
  * each machine calls `SetPlayerHorse` for its own player's horse.
* **Saddlebags per rider**:
  * **on mount**, the rider's machine moves the rider's saddlebag items (held
    in the rider's Henry file) into the horse inventory;
  * **on dismount**, it moves them back out into a hidden per-player
    container, never into the world save;
  * the other rider's bag is never in the horse while you ride.
  Encumbrance and the Horsenip perk keep working because they read the horse
  inventory. (design; inconclusive until built)
* **Whistle**:
  * natively, `C_RiderPlayerControl::CallHorse` sends `ComeToMe` to the
    *owned* horse, which runs to the hard-coded `$__player`, then teleports
    after 15 s;
  * the whistle is also an AI sound (intensity 760);
  * nothing sends a horse to a non-player.
  (data)

| variant | meaning | cost |
|---|---|---|
| **W1 (recommended)** | any whistle is broadcast; **each machine calls its own player's horse to its own player**. Both horses come, each to its rider | native on each machine; one message. Emit the whistle noise at the whistler's position on the host |
| W2 | both horses come to whoever whistled | the other horse is simulated elsewhere and the engine only targets the local player, so the mod must steer it to a ghost |

### 4.3 Crime and reputation, shared

#### 4.3.1 Committing crimes in the host's world

* **Every crime path keys on `$__player`**, the native local-player global:
  * `handleStimulusHit` (`attacker == $__player`);
  * witnessed murder in `handleAwareness_hitVolume`;
  * lockpicking and pickpocket (`Origin="$__player"`);
  * trespass (`Target=`);
  * theft and murder (`ReactionNpc=`).
  A crime record has no culprit field. **A ghost cannot commit a crime in the
  host's world.** (data-verified)
* **Injection route**: push `switch:stimulus:hit/theft/murder` messages into
  mailbox `crime_stimulus` (the quest pattern `utils/crime/*/pushstimulus_*`;
  Lua `XGenAIModule.SendMessageToEntityData`). An injected crime counts as the
  host player's, i.e. Henry's. That matches "both are Henry". (data)
* **Hits first, the prerequisite**: joiner hits arrive as health deltas with
  no attacker (peer test). The native apply must pass an attacker soul:
  `CombatSoul::TakeDamage` takes `I_Soul* Attacker`; in-process attribution is
  unverified (NATIVE-PLUGIN).

  | option | aggro | crime |
  |---|---|---|
  | A1 attacker = joiner's ghost soul + separate crime stimulus | goes to the ghost (right person) | Henry's |
  | A2 attacker = host's player soul | goes to the host player (wrong person) | automatic |

  Recommend A1.
* Theft, trespass, lockpicking and witnessed murder on the joiner are local
  events in the joiner's copy. The joiner's agent forwards `crime event (type,
  victim, witnesses, position)` and the host injects the stimulus.

#### 4.3.2 Guards treating the joiner's ghost as Henry

* **Outlaw status is not one flag.** It is made of:
  * crime records on each NPC soul, spread through the settlement faction;
  * freshness (`crime_freshViolentInformationTimer` 20 s, ×3 for murder);
  * per-soul and per-faction reputation towards the `player` faction;
  * a native `C_WantedBuff` / `IsWanted`.
  (data + code names)
* `$__player`, the `player` faction and the native player soul flag
  (`+0xD78` bit 4) have no data lever, so the ghost can't *be* Henry.
* **Design**: mirror "Henry is attacked on sight here" onto the ghost. When
  the host's guards turn on Henry, the host attaches the joiner's ghost to the
  mod's hostile faction (WO-17/27 native `SetFactionHostile`, already
  shipped), scoped to the settlement. The mirror is released when the host's
  Henry is no longer wanted there. (design over shipped levers)

#### 4.3.3 Can the joiner hold a dialogue with a host-owned NPC? (observed, one NPC, solo)

| probe | NPC unsuspended (control) | NPC suspended (`wh_ai_PauseNPC`) |
|---|---|---|
| `npc.human:RequestDialog(player)`, the organic talk request | brain picks it up: `Attempting to start new dialogue … 'Ex: Dude; Ex: ttkc_man_5'` (then times out; no player input followed) | request registered, **never attempted**, `Request timed out`; on resume the brain tried the stale request: `Attempt to start dialog id 2961 … not in pending request list` |
| `DialogModule.ForceDialog(npc, player)` | both souls in dialogue, `WAITING_FOR_INTERACTION`, world time paused | **identical** |

* **Answer**: vanilla talk requests are handled by the NPC's brain; a
  suspended brain defers them past their timeout. The joiner cannot talk to a
  suspended host-owned NPC through the vanilla path.
* `ForceDialog` bypasses the brain but still waits for the player's
  interaction state, which a console call does not supply.
* **Not tested**: the real "talk" key press (needs a human); whether lines
  play once the interaction starts on a suspended NPC.

| option | how | cost |
|---|---|---|
| **D1 dialogue handover (recommended v1)** | joiner presses talk on a host-owned NPC → joiner claims the NPC (WO-60 claim/hold) → host pauses its copy → joiner **resumes its local brain** (the resume triggers the queued request at once, observed) → the conversation runs locally → at the end the joiner re-pauses and releases | re-uses shipped machinery. The **outcome** (quest beats, reputation, items) happens in the joiner's copy and must be mirrored to the host (§6) |
| D2 host-run | the host's NPC holds the conversation with the joiner's ghost | the dialogue system targets `$__player` / the ghost has `RestrictDialog`; the joiner sees nothing. Not viable |
| D3 forced + interaction driver | `ForceDialog` + drive `SetPlayerInteractiveState` | unverified interaction; still local outcomes |

#### 4.3.4 Time pauses in dialogue

* **Every non-chat dialogue with the player as a participant pauses world
  time on that machine**: a `C_TimePauseHandle` with reason `DialogInstance`,
  DialogModule `0x684C3`. Other holders: quest `PauseWorldTime` (37 quests),
  skip-time, minigames (dice `pauseWorldTime`), in-game cutscenes, level
  load. (code) Observed: `IsWorldTimePaused` true during a forced dialogue
  with the player, with and without the NPC suspended. The game picked a
  surrender/self-help line, not a chat; an ordinary chat was not isolated.

| option | behaviour | cost |
|---|---|---|
| T1 shared pause | either player's dialogue pauses the world clock for both (the joiner reports it; the host holds a pause) | simple. The other player waits on the clock, not movement |
| **T2 world clock runs (recommended)** | ignore the `DialogInstance` pause on both machines (native: skip that reason at the calendar's pause slot) | conversations happen in running time; NPC schedules keep going |
| T3 accept local pause | the pausing machine's clock stops; WO-38 time sync snaps it forward afterwards | zero work; visible jump |

#### 4.3.5 Punishment: "the Henry in the dialogue owns the outcome"

* **Shipped crime has no jail.** The `crime_punishmentType` enum is
  unknown / pillory / beating / branding / execution (read first-hand in
  `IPL_GameData.pak` `Libs/concept/definitions.xml`). Native `C_Jail` and BT
  `Jail` are unused; skiptime `Jail` (5) is code-only. (data + code)
* The arrest dialogue `STRAZ_ZATYKANI` resolves via
  `Crime.SendResolveDialogResult`:
  * **fine**: native `Confiscate ConfiscateFine=true`; stolen items go to the
    chest linked `crime_stolenItemsStorageChest`; the paid amount is
    `crime_moneyTaken`;
  * **punishment**: quest `open_world/nextnextgenpunishment` — fast travel,
    **`AdvanceWorldTime TimeOfDay=10h`** if farther than 200 m, teleport to
    `punishment_teleportPoint`, unequip all, cutscene; pillory, beating,
    branding, or execution if already branded (`GameOver(44)`).
  (data)
* The dialogue must run on the machine of the Henry in it, with a live guard
  brain: D1's handover, on a guard.
  * **Fine** → the joiner's own money (their Henry), deducted locally;
    confiscated stolen items go to the host's chest by delta.
  * **Punishment** → that player's Henry is teleported and held locally.

| time skip option | behaviour |
|---|---|
| J1 world skips for both | host advances the clock to 10:00; the other player sees a jump |
| **J2 no skip (recommended)** | suppress `AdvanceWorldTime` for the punished player; the punishment is a fade + teleport + hold |
| J3 hold only the punished player | as J2, plus the other player is shown a status row |

* **Execution** is a non-death Game Over (id 44). WO-113's C2 guard passes it
  through, so it ends that machine's game: maintainer's call whether
  execution stays vanilla in co-op.

### 4.4 Reputation with individual NPCs

* **It lives in world state:** per-NPC opinion records `0x12FF` on each NPC's
  soul (observed drifting between saves), faction nodes `352C`, and crime
  memory in XGenAI. All of it travels with the world save, so it is shared as
  decided.
* **One value sits on Henry's own record:** `0x12FF` = renown 0.35.
  * **R1** world (stamp keeps the host's value);
  * **R2** per-player (stamp the joiner's).
  Decisions say reputation is world, so R1 is the default; R2 only if the
  maintainer reads renown as Henry's fame.
* **Per-player dependents**: shop prices, dialogue options and crime reactions
  read reputation. All are world by decision; nothing strictly per-player
  depends on it (data).
* **Knock-out reset**: `ResetNearbyPublicFriendsReputation` is built only at
  the combat-hit decision `0x52FBE0`, right after a knock-out of the
  player-flagged soul. `upr=1` (WO-113's guard) blocks it, and ghosts never
  trigger it (code). The other reset, global `ReconcileWithPublicFriends`,
  runs from the indulgence box, pilgrimage, the punishment quest and svatba:
  world events, fine.

### 4.5 Graves as world objects

* **Storage (observed, q026)**: the `StashCorpse` entity is in `GameState`,
  and its contents are a stash record in EntityModule `0x0006` keyed by the
  grave's entity GUID. It is already a world object in whichever save holds
  it.
* **Design**:
  * graves are spawned **by the world owner** (host) at the downed player's
    position;
  * the downed player's items leave that player's Henry and are created in
    the grave on the host by class, amount and health (native
    `CreateItems`), transactionally like WO-48: the owner deletes, the host
    creates, ack;
  * this replaces WO-113's peer mirror.

| owner tag option | where |
|---|---|
| **G1 (recommended)** | the grave entity's name (`kcdmp_grave_<ownerId>_<n>`); saved in `GameState` `name` (observed field) |
| G2 | an agent-side registry keyed by the grave entity GUID |

* **Only the owner loots**: on every non-owner machine, set the grave locked or
  non-interactive locally (`bLocked`/`interactive` exist on the entity,
  observed).
* **Owner never returns**:
  * **E1** persist forever (default);
  * **E2** expire after N world days;
  * **E3** unlock for everyone after N days.
  Maintainer's choice.

---

## 5. Phase 5 — meeting WO-111 / WO-113

* **Death guard after every load**, both machines: in the joiner load order
  (§3.6, step 2) and after any host load.
* **Graves** become world objects (§4.5); WO-113's mirror is the interim.
* **Save locks are shared ground.**
  * Script locks are **named**: `AddScriptSaveLock` refuses a duplicate name,
    and each removal takes only its own name.
  * Engine lock types (`SetSaveLock(type)`) are plain booleans, last writer
    wins, except type 12. (code)
  * So WO-113 must lock its respawn transition with its **own named script
    lock** (e.g. `kcdmp_respawn`), never an engine type. WO-112 holds
    `kcdmp_host_only` on the joiner. Both re-assert after every load.
* **Position**: WO-113's native teleport is the stamp's position write (S1)
  and the punishment/respawn mover.
* **Quest items**: identified here (§2.3: bit `0x2` / `IsQuestItem`) for
  WO-113's grave filter to reuse. The engine already refuses moving a quest
  item into a stash (`AddItem` refusal, code).

---

## 6. What "one world" still needs during a session

Local world mutations on the joiner, and the route for each (open work; the
plan covers each):

| mutation | route |
|---|---|
| NPC death | world owner wins (§3.3) |
| hits / crime | attacker attribution + stimulus injection on the host (§4.3.1) |
| trade | shop delta to the host (§4.1) |
| dropped items | WO-48 (shipped) |
| quest beats from dialogue or pickups | quest-state messages → host Haste triggers (WO-94/96 machinery; narrow triggers only exist for ~17 objectives, WO-97). Quests remain the largest open area |
| world time | host-owned clock (WO-38); dialogue pause policy §4.3.4 |
| horses | rider-owned while ridden (§4.2) |
| containers/stashes looted by the joiner | not designed here; same delta pattern as shops (open) |

---

## 7. Ordered implementation plan

Prerequisites first.

| # | WO | contents | depends on |
|---|---|---|---|
| 1 | **Attacker attribution** (prereq) | native damage apply passes the joiner's ghost soul as `TakeDamage` attacker; host NPC reacts; A1 crime stimulus injection | — |
| 2 | **World-owner death authority** | owner-streamed death is applied on the joiner regardless of local state | — |
| 3 | WO-113 (running) | death guard, respawn, local graves, native teleport | — |
| 4 | **Save plumbing (native)** | named script lock from the DLL + re-assert after load; `EnqueueAutoSave` cadence on the host; QuickSave on demand with its file path returned; port the `.whs` reader/verify to the agent (C#; `SaveGameReader.cs` already inflates) | 3 |
| 5 | **S3 go/no-go** (1 day, live) | splice the joiner's `player_henry` + side blocks into a host save, re-sign MD5, load solo, verify offline and live (inventory, perks, XP raw, quest-item self-heal, companions) | 4 |
| 6 | **World transfer + pause** | relay chunked file stream, SHA-256 + MD5, launcher progress; host pause (ratio 0 + bulk pause + input hold) and synchronized resume | 4 |
| 7 | **Joiner load from the menu** | native rescan + `LoadSavedGame`; O1 transient file + post-load delete + launch-time sweep; Save & Quit handling under the lock | 4, 6 |
| 8 | **Henry file + stamp** | F1 import from own save; periodic snapshots; S3 (or S1 if item 5 fails); quest-item strip; abort path | 5, 7 |
| 9 | **Dialogue handover** | D1 claim → local resume → release; time-pause policy (T2); outcome mirroring for non-quest dialogues | 1, 8 |
| 10 | **Merchants** | shop deltas, claim/rollback for unique items | 8 |
| 11 | **Horses** | rider authority, legal mount, per-rider saddlebags, whistle W1 | 8 |
| 12 | **Crime & punishment** | ghost hostility mirroring; punishment on the dialogue owner's machine; J2 | 1, 9 |
| 13 | **Graves as world objects** | host-spawned graves, owner tag G1, loot lock | 3, 8 |
| 14 | **Two-player validation** | the first peer session on the split save | all |

S2 (soul transplant) is a research WO that runs only if item 5 fails.

---

## 8. Not done, inconclusive, stated plainly

* **Two-player: everything.**
* A modified save was not loaded (S3's one unknown).
* The raw stat/skill XP encoding (`u32` per stat) was not solved.
* Why `AddBuff(hangover | on_washed)` returned handles but did not apply.
* The real talk key press on a suspended NPC.
* `0x12FB/0x0926` f64s; `3530`/`352B`/`3531`; the `01f9/7302` item list;
  the POI record flags in `352D`.
* The quest-item self-heal on load.
* `Save & Quit` and crucial-decision saves under the lock.
* Whether ratio 0 survives a save or sleep.
* Mod Lua at the main menu.
* `SetPlayerHorse`, whistle and saddlebag moves: not run.
* The main-menu load path with a rescanned file (`UpdateSaveGameDescriptions`).
* TerrainState's growth in WO-111's session.

---

## 9. Address index

| what | binary | RVA |
|---|---|---|
| `C_PlayerProfileWHManager::SetSaveLock` | Framework | 0xED970 |
| lock type names | Framework | 0xECE30 |
| `AddScriptSaveLock` / `RemoveScriptSaveLock` / `ResetAllSaveLocks` | Framework | 0xEDB10 / 0xEDEE0 / 0xED8A0 |
| `CanSave` / `InitiateSaveGame` / `EnqueueAutoSave` | Framework | 0xEE410 / 0xEFDE0 / 0xEF9E0 |
| `LoadSavedGame` / `UpdateSaveGameDescriptions` / `GetSaveGameDescription` | Framework | 0xEFB10 / 0xEF730 / 0xEF630 |
| `C_InputChunk` / `C_OutputChunk` | Framework | exports |
| `LoadLastSavedGame` / menu current-playline pick | GUIModule | 0x319180 / 0x3158C0 |
| `SwitchLevelAndLoadSavedGame` | WHGame | 0x194970 |
| `C_SoulList::SaveGameSouls` / `LoadGameSouls` / `LoadGameSoul` | RPGModule | 0x747A10 / 0x748830 / 0x749010 |
| `C_Soul::LoadGame` / first-chunk reset / `CopySoulFromDB` | RPGModule | 0x72D740 / 0x72D520 / 0x745840 |
| soul field savers (0x12F9+0x1303 / 0x12FB / 0x12FF / 0x1301) | RPGModule | 0x72CCE0 / 0x72D250 / 0x72D3D0 / 0x72D480 |
| RPG stats saver (0x137E/0x1385/0x138B/0x138D) | RPGModule | 0x720E50 |
| combat-hit decision (knock-out, reputation reset) | RPGModule | 0x52FBE0 |
| quest-item refusals / flag getter | EntityModule | 0x881535, 0x8CC688, 0x71C738, 0xB3FFCD, 0xB3F53A, 0xB409B6 / 0x9A6F30 |
| `ReclaimQuestItems` routine | EntityModule | 0xA48780 |
| dialogue world-time pause (`DialogInstance`) | DialogModule | 0x684C3 |

Identifiers: `player_henry` `4c2dcffb-dea1-6263-72d7-b39f4db2d8b5` ·
`player_bohuta` `4666cffb-dea1-6263-72d7-b39f4db2d666` · entity `Dude`
`0x7777` · money `5ef63059-322e-4e1b-abe8-926e100c770e` · keyring
`b54eaa25-f0e9-425b-8b29-1fb14a71de56` · `death_protection_cutscene`
`6f706644-e28a-41a9-9674-5f19dea03bf1`.
