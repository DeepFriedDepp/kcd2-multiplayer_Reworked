# WO-115: S3 splice go/no-go

Session 2026-09-25. Solo, one machine, Modding Tools build 1.5.5 with the
installed pak loaded. No DLL, no agent, throwaway copies only. Progress, method
and side effects are in `docs/WO-115-progress.md`. Settled decisions are in
`docs/DECISIONS-coop-design.md`.

Evidence marks: (observed) / (code-verified) / (synthetic) / (inconclusive).
(save-verified) means decoded from a real `.whs` with
`tools/Read-SaveAnatomy.py`. Paths are written as `<saves>`, `<install>`,
`<scratch>`.
**No mod code shipped. No pak, no installer, no VERSION bump.**

---

## 0. Verdict: **GO**

* **The spliced file loads.** The splice reached `Gameplay started` with no
  load error of its own, twice: cold from the main menu (the copy with one
  MD5 byte flipped, otherwise identical) and in-process as `mpworld115`.
  (observed)
* **The Henry is exactly the joiner's.** Every category matches the joiner's
  own save loaded live in the same session: inventory, money, equipment,
  skills, stat progress, vitals and buffs. Perks match in the saved file.
  (observed, §3)
* **The world is exactly the host's.** Clock, NPCs, Henry's position and
  renown come from the host. After ~12 minutes and a save, quest state is the
  host's world moving forward. (observed, §3.3)
* **It survives a save and a reload.** The game's own save of the spliced
  world parses as the same Henry plus the session's deltas. It reloads to the
  same live state, in-process and after a cold relaunch. (observed, §4)

The fallback (S1, S2) is not needed. Four things carry forward. None of them
blocks S3.

| # | carry-forward | why it matters |
|---|---|---|
| 1 | **The game does not check the MD5 footer** (§5) | the transfer must verify the file itself. A corrupt file loads silently |
| 2 | **The quest-item A/B experiment could not run** (§6) | neither stand-in Henry holds a quest item, and no 1.5.5 save on disk has one on Henry. Variant C (synthetic) showed the engine keeps an orphan quest-class item, so the strip is required |
| 3 | **Persistent buffs may carry world-clock timing** (§3.4) | the joiner's clock differed from the host's by 4.7 days. A buffed stat level drifted slightly. Durations were not checked |
| 4 | **Three blocks were found that WO-112 did not list** (§2) | key bindings `7302/000B` (Henry's), soul field `0x1300` (a joiner-world reference, dropped by the game) and bed POIs inside `352D` (world) |

---

## 1. Stand-ins

| role | save | notes |
|---|---|---|
| host world | playline1 `quicksave027` (copy) | WO-112's clean throwaway. Troskowitz, 16:55, early game |
| joiner Henry | playline2 `save021` (copy) | a different playthrough, so this is the first-join import case. Same build. The joiner's world clock is 4.7 in-game days ahead of the host's |

Both originals were hashed before and after the session and did not change.
(observed)

---

## 2. The block table as tested

`tools/Splice-SaveHenry.py splice <host> <joiner> <out> --tables <Tables.pak>`.
The zlib blocks are rebuilt at 32 KB raw each, as the game writes them. The
host's description header is kept byte for byte and the MD5 footer is
recomputed. Every ancestor TLV length is fixed. The tool's own `check`
re-derives each row below from the three files.

| block | source | tested result |
|---|---|---|
| `player_henry` soul record (`0x115E`) | joiner | taken whole, then the two host fields below are written into it (save-verified) |
| … stat id 8 `storyProgress` | host | written. **Not discriminating here:** both saves hold 33792 (synthetic) |
| … `0x12FF` renown | host | the joiner's 16-byte record is replaced with the host's 81-byte one. Live `PlayerRenown` = **0.35** (the joiner's own save reads 0) (observed) |
| … quest-class items | joiner's removed. Variant A adds none, variant B adds the host's | neither Henry holds any, so A and B are **byte-identical** (§6) |
| … `0x1300` (**new**) | joiner, carried | Only the joiner's Henry has this field. It names an id that exists only in the joiner's world (paired with Henry in the joiner's RPGModule `3531`). It loaded with no log line, and **the game dropped it at the next save** (observed). Meaning: (inconclusive) |
| RPGModule `352E` statistics | joiner | carried. The counters kept advancing normally (observed in the resave) |
| RPGModule `352D` map knowledge | joiner | carried. **Mixed, not pure Henry:** after the save every joiner record was still there, plus 163 duplicate "BED POI" records that also exist in the host save. Beds re-register when their area streams in (observed) |
| PlayerModule `7309/0000` tutorials, `7309/0001` fog | joiner | both carried and unchanged by the save (observed) |
| GUIModule `7301` journal UI | joiner | carried and unchanged by the save (observed) |
| EntityModule `01f9/7302/0002` player item list | joiner | a list of Henry's item instance GUIDs. After the pickup it changed. Likely the inventory's "new item" marks (inconclusive) |
| EntityModule `01f9/7302/0000` | **host** | the joiner's copy holds a 54-byte record that names a joiner-world soul, so the host's (empty) copy was kept |
| EntityModule `01f8/7302/000B` **key bindings (new)** | **merged** | `[8-byte header][0x05AD × (owner soul GUID, 9 bytes, key item instance GUID)]`. In both saves every entry names one of Henry's own `keyname_home` keys. Host entries naming a host Henry item are dropped; joiner entries naming a joiner Henry item are added. The joiner's two bindings survived the save (the header changes on every save) (save-verified) |
| `GameState` (incl. `Dude` position) | host | live position = the host Henry's spot (observed) |
| companion list `1160`, XGenAI incl. the `Dude` brain | host | unchanged |
| everything else (quest state, graves/stash `0006`, quest-item manager `000A`, factions, shops, weather …) | host | byte-identical to the host save in the spliced file (save-verified) |

Offline checks on the output (observed):
* `Read-SaveAnatomy.py verify`: OK.
* `Read-SaveAnatomy.py diff host out --souls`: only the rows above differ.
  1 of 6,369 souls changed (`player_henry`); `player_bohuta` is unchanged.
* `henry` on the output: the joiner's 34 items, 54 perks, stats and skills;
  the host's renown and story stat.
* Controls: `check` passes on the real splice. It **fails** with 14 errors
  when the host save is given as the output, and it **fails** on variant C
  (an extra item). The tool refuses to write over an input, and the same
  inputs give byte-identical output.
* A second pairing, offline only (playline1 `quicksave035` + playline2
  `permanent014`), also passes `check`. That joiner has no equipped-instance
  list, which the first version of the tool crashed on; it is fixed.

Graves: neither stand-in holds a grave (the `0006` stash block is the same
259 bytes in both). The splicer copies `0006` from the host by construction,
and `check` enforces it. No grave was tested live. (inconclusive)

---

## 3. Live after load (`mpworld115`)

Method: the joiner's own save021, the host's quicksave027 and the spliced
file were loaded one after another in one session. Each got the same snapshot
within seconds of `Gameplay started`:
* Lua inventory, stats, skills and vitals;
* RTTR REST buffs, equipped armour and weapons, renown and money;
* NPCs within 40 m.

### 3.1 Henry = the joiner's (observed)

| category | joiner's save021 live | spliced live | verdict |
|---|---|---|---|
| inventory | 34 items + the live-only keyring (class, amount) | identical list | exact |
| money | 15.1 (RTTR 151) | 15.1 (151) | exact |
| equipment | 5 armour (hood, gambeson, hose, boots, belt) + torch + hunting sword | identical | exact |
| skills (23) | level + progress | identical to 6 decimals | exact |
| stats (4) | progress 0.648438 / 0.976562 / 0.718750 / 0.367188 | identical | exact. The printed **level** is buff-modified (drunkenness): 6.4696 vs 6.4353, see §3.4 |
| vitals | hp 31.02, stamina 89.683, exhaust 89.935, hunger 76.660, alcoholism 5.962 | identical | exact |
| buffs | drunkenness, oversleep + transient (damaged gear, illuminance, visor) | identical set | exact |
| injuries | none | none. The host Henry's two leg injuries are **gone** | exact |
| perks / codex | no live read | resave parse = the joiner's 54, none added or lost | exact (save-verified) |

### 3.2 From the host (observed)

* Position `2325.14, 2052.71, 109.06`: the host Henry's spot. The joiner
  stood elsewhere in their own world.
* `PlayerRenown` = 0.35 (the host's; the joiner's own save reads 0).
* World clock: 579320, against the host save's 579321. The joiner's world
  was at 981675.
* NPCs within 40 m: the same names and positions as the host save, within the
  movement of the first second. One NPC on the 40 m edge differs each way.

### 3.3 No corruption in `kcd.log` (observed)

* The spliced load window was compared with the host-original load window,
  after normalising numbers and GUIDs:
  * no new error or warning about souls, items, perks, buffs, Dude or the
    inventory;
  * the drunkenness material effect is added on the spliced load, as it is
    for the joiner.
* One error appears only in the spliced window:
  `zranenyLovci…removeNPCMetaroleConextNotSet … invalid port`. It is written
  while the **previous** world tears down. It follows the teardown of both the
  original quicksave027 and a spliced copy, and it is absent after the
  joiner's world. It is not caused by the splice.
* 23 × `failed to read value from Awake port` are printed on **every** load
  (originals included, and in older sessions' logs). Vanilla.
* Every load prints a `SAVE GAME HISTORY` line with the account name of the
  machine that wrote the save. This matters only if logs are shared publicly.

### 3.4 Buff timing: open (inconclusive)

* The stat level shown under drunkenness differed slightly: joiner 6.4696,
  spliced 6.4353. Alcoholism (5.962) and base progress were identical. Over
  the session the buffed level moved non-monotonically (7.37 → 6.57), so the
  level is not a clean reading.
* Persistent buff records (`0x12FB/0x0928`) carry 8-byte fields that may be
  world-clock stamps. The joiner's clock was 4.7 days ahead of the host's, so
  a buff could last longer or shorter after the splice.
* Not checked: all three persistent buffs had expired by the resave, because
  the session skipped time 15 h for daylight.
* Next test: splice a Henry with an injury or a potion buff, and compare the
  remaining duration live against the joiner's own save.

---

## 4. Play, save, reload

### 4.1 The session (≈12 min wall clock, 13:56 → 14:09)

| step | how | result |
|---|---|---|
| daylight | `Calendar.SetWorldTime` to 09:00 next day (a world mutation in the throwaway) | done (observed) |
| pick up an item | `human:PlaceItem` put an apple into the world, then `PickableItem:Use(player)` (the interactor's own path) | apples 4 → 3 → 4, world entity gone (observed). `human:PickUpItem` returned but did nothing (observed) |
| buy or sell | **not run.** There is no trade scriptbind (`Shop.*` and the transaction binds are absent); a trade needs the UI and a human | stand-in `inventory:RemoveMoney(1)`: 15.1 → 14.1 (observed) |
| take a hit | `soul:DealDamage(5, 5)` | hp 31.02 → 26.02 (observed) |
| idle | 18 samples at 30 s | no attack, hp steady, clock running (observed) |
| save | `wh_sys_TestSaveGame` → **`quicksave037`** | written, MD5 verifies (observed) |

### 4.2 The resave, parsed (save-verified)

| check | result |
|---|---|
| inventory | 34 items. The only class/amount change is money 151 → 141 |
| perks | = the joiner's exactly |
| stats | as spliced, except speech raw XP 48384 → 49408. The cause of the gain is unknown (inconclusive) |
| states | hp 26.02 (the hit); other states drifted normally |
| persistent buffs | none: all expired after the 15 h skip |
| `0x12FF` renown | 0.35 kept. One inner u32 changed (`1f111e9d` → `74fd1899`), likely a per-save value |
| `0x1300` | gone (dropped by the game) |
| key bindings `000B` | the joiner's two entries kept (header re-rolled) |
| tutorials, fog, journal | = the joiner's |
| map knowledge | the joiner's records + 163 bed POIs (§2) |
| **quest state** `ConceptState` | host and joiner differ on 2,308 leaves. The resave matches the **host** on 2,084, the **joiner** on 2 (two timers that simply finished) and neither on 222: the host world's timers, random events and fog moving on over 15 in-game hours |
| quest module, homestead, stash/graves `0006`, quest-item manager `000A`, companions | byte-identical to the host save |
| souls | 6,368. One runtime roe deer despawned; 263 changed (NPC time) |

### 4.3 Reload (observed)

* **In-process:** `wh_sys_LoadGame 1 quicksave037` from the running spliced
  world loaded it.
* **Cold:** relaunched, loaded from the menu, `Gameplay started` in 57 s.
* Both matched the pre-save snapshot. Items (class, amount), money 14.1,
  skills, stats, equipment, buffs and renown were identical. Only food
  freshness and hunger had ticked.
* **Refinement of WO-112 §3.5:** a save the game wrote itself **is** loadable
  in the same session. Only files copied in after startup are invisible to
  `wh_sys_LoadGame`.

---

## 5. The integrity check is **not** enforced (observed)

* `mpworld115bad.whs` was the same splice with one MD5 byte flipped. It
  loaded to `Gameplay started` from the main menu.
* The log shows no warning at all: no md5, corrupt or checksum line.
* Every copy was listed at startup, the bad one included.

What a botched transfer looks like, then: **nothing**. The game accepts it.
Anything that breaks the TLV framing or zlib would fail in the loader, but a
wrong byte inside a zlib block that still inflates would load. **The join
must gate on its own check before the file is placed:** SHA-256 over the wire
plus `Read-SaveAnatomy verify` (WO-112 §3.4). The splicer's `check` is the
content gate.

---

## 6. Quest items

* **A (strip) vs B (carry the host's):** no result. Neither stand-in Henry
  holds an item of any of the 293 `IsQuestItem` classes. A scan of every 1.5.5
  save on disk (playlines 1–3 and backups) found **none** with a quest item on
  Henry. A and B produced byte-identical files. The self-heal question (does
  the engine re-create the host's active quest items on a stripped Henry?)
  stays open. (inconclusive)
* **Variant C (synthetic):** one orphan quest-class item was added to the
  spliced Henry (`pracharna_loveLetter`, not managed by any active quest).
  **It was still in the inventory after load.** The engine does not clean up
  unmanaged quest-class items on load. So the joiner's quest items must be
  stripped at splice time, which the tool does in both variants. (observed)
* **Correction to WO-112 §2.3:** the saved per-item u32 at record offset 16 is
  **not** the quest-item flag. Bit `0x2` is set on bandages, herbs and keys.
  The in-memory `C_Item+0x60` flag is a different field. The splicer
  identifies quest items by class (`IsQuestItem="true"` in `Tables.pak`).
  (save-verified)
* **To run A/B:** the host save needs an active `AddQuestItem` to the player.
  For example, save while Henry carries an early main-quest item, splice
  both ways and load each.

---

## 7. Tool

`tools/Splice-SaveHenry.py` (stdlib only; reuses `Read-SaveAnatomy.py`):
* `splice <host> <joiner> <out> --tables <Tables.pak> [--quest-items strip|host] [--bad-md5]`
* `check <host> <joiner> <out> --tables <Tables.pak> [--quest-items …]`

The tool:
* never overwrites an input (`xb` open, refuses output == input);
* refuses inputs whose MD5 does not verify, and refuses mixed builds;
* prints only the non-identifying header fields.

`Read-SaveAnatomy.py` fix: GameState token type `0x0C` (8 bytes) was missing,
so `henry` crashed on saves that hold one (this session's joiner). With the
fix, both saves' `GameState` decode to their exact end (208,810 and 206,756
tokens).

---

## 8. Not done, stated plainly

* The quest-item A/B experiment (§6). No usable save exists.
* A real trade (no scriptbind; needs a human at the UI).
* A live check of persistent buff durations across different world clocks
  (§3.4).
* Graves live (none present).
* Two-player, transfer, pause, the agent port: out of scope.
* The raw stat XP encoding is still undecoded. Exactness was shown by live
  progress equality instead.
