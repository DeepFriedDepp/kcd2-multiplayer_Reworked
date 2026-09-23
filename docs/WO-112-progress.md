# WO-112 — progress: what ran, what did not, what blocked it

Session 2026-09-23, solo. Findings and design: `docs/WO-112-split-save.md`.
**No code shipped. No pak rebuilt. No installer. No VERSION bump. Nothing ran
two-player.** Committed: the two docs and one read-only analysis tool,
`tools/Read-SaveAnatomy.py`. Paths: `<install>`, `<saves>`, `<repo>`,
`<scratch>` (the session scratchpad, not committed).

## 1. What ran

| phase | status | note |
|---|---|---|
| read-first docs | done | WO-109 audit §1.2/§1.4 + progress §2, WO-110 findings, WO-96/97/98/99/99.5, WO-48 (both), WO-111 (both, in full), `ARCHITECTURE-shared-world.md`, NATIVE-PLUGIN head, DLL `local_state.cpp`, `pipe_server.h`, `rttr_abi.h`. `docs/WO-113-findings.md`: absent |
| 1 — save anatomy | **done** | every block classified or listed as not understood (findings §1.2) |
| 2 — Henry read/write | **done** | live probes + a save/parse/reload round trip for the writes that matter (findings §2) |
| 3 — one world save | **done (design)** | pause, save cost, locks and slot behaviour measured live; transfer designed |
| 4 — decisions | **done (design)** | every settled decision designed; open choices laid out as options |
| 5 — WO-111/113 | done | findings §5 |
| deliverables | done | two docs + tool |

## 2. The offline work (no game needed)

* **Tool** `tools/Read-SaveAnatomy.py` (read-only, stdlib only). Rewritten
  from scratch; WO-109's scratch scripts were not in the repo. It
  implements:
  * inflate;
  * the TLV tree;
  * the hashed-key token decoder (FNV-1 keys, script tables);
  * the soul list and the `player_henry` decoder;
  * block diff, pattern find, `GameState` entity dump;
  * **footer verify**: the MD5 check, reproduced on all 223 saves on disk.
* **Save sets used**:
  * playline1 `quicksave021`–`030` (1.5.5);
  * playline2 `save021` (1.5.5, the other playthrough);
  * playline0 `save245` (1.1.1, late game);
  * playline3 `autosave003`.
* **Diffs**: `q021→q022` (1 min), `q025→q026` (25 min, WO-111's grave
  session), `pl1 vs pl2` (different playthroughs). Findings §1.5.
* **Module tag map**: a byte scan of every Modding Tools DLL for the `0x73xx`
  immediates; each tag occurs in exactly one module. The game's own save log
  later named the same modules per chunk.
* **Key-name dictionary**: FNV-1 over all ASCII/UTF-16 identifiers in the
  module DLLs (265k strings), for decoding `GameState`. It stays in
  `<scratch>`; only the confirmed names are embedded in the tool.
* **GUID labels**: built at run time from `Tables.pak` (`--tables`); no game
  data is committed.
* **Ghidra**: WO-111's analysed projects (Framework, GUIModule, PlayerModule,
  RPGModule, WHGame), opened **read-only** with WO-111's `WO111Tool.java`
  plus one new immediate-scan script (`<scratch>`). It found the soul
  serializers and loaders (findings §9).
* **Footer**: CryEngine's reference source (`<ENGINE_REF>`, read-only, not
  reproduced) names the XMLCPB `'PBX0'` footer and its MD5 rule. The rule was
  then **reproduced independently** on the real saves.

## 3. Research agents (parallel, read-only)

Four background agents ran read-only against the paks, binaries and saves.
They wrote only to `<scratch>`; none edited the repo or launched the game.

| agent | scope | result used in |
|---|---|---|
| A | crime authority, crime pipeline, outlaw state, fines/punishment, dialogue time pause, skiptime, knock-out reset | findings §4.3, §4.4 |
| B | quest-item identification, `quest_items` modules, `ReclaimQuestItems`, M01–M51 census (21,649 quest graph files parsed) | findings §2.3 |
| C | horses (ownership, saddlebags, whistle, mount, theft), merchants (stock, gold, trade flow) | findings §4.1, §4.2 |
| E | save locks (types, blocking matrix, request fate), save triggers, playlines and slot selection, menu load path, pause facilities, save cost | findings §3 |

**Spot-checked first-hand before use:**
* IsQuestItem counts 195/73/20 (Tables);
* `DialogInstance` (DialogModule, 22×);
* `ReclaimQuestItems`, `CallHorse`, `C_RiderPlayerControl` (EntityModule);
* lock type names `IntermissionGate`/`CartMounting`/`PlayerStateHandler` and
  `wh_sys_FreezePlayline` (Framework);
* `crime_stimulus` (XGenAI);
* `crime_isAuthority`: 145 refs in 90 `AI/crime/*` trees + Storm contexts;
* `crime_punishmentType` enum (no jail) in `IPL_GameData.pak`;
* 6 `inventory_shop_money_N` presets.

Agent E's save-lock and slot claims were confirmed **live** where it
mattered: script lock vs autosave vs QuickSave, the lock wiped by a load,
no rescan on `wh_sys_LoadGame`. The rest of the agents' statements carry
their own marks in the findings.

## 4. The live session (solo, throwaway saves)

Launch: Steam already up. `KingdomCome.exe` (Modding Tools) started as the
launcher does (working directory = `<install>`, no args); console API up after
~15 s. `kcd.log` and `logbackups/kcd.log` copied to `<scratch>` before
launch. No DLL, no agent: REST `:1403` (RTTR) and `ExecuteString` (`#`-Lua)
stood in for native calls. Quit with `System.Quit()`.

| # | probe | result |
|---|---|---|
| L0 | `wh_sys_LoadGame 1 quicksave025` from the menu | `Gameplay started` after **68 s** (cold) |
| S0 | `wh_sys_TestSaveGame` → **`quicksave027`** (fresh throwaway) with a 100 ms Lua heartbeat | generation **44 ms**, CryAction serialize 63 ms, 1,427,154 B file / 4,476,836 B stream; one heartbeat gap 121 ms; per-module sizes and chunk numbers 502/504/505 in the log |
| R1 | bind registration (`type()`) across inventory, ItemManager, soul, actor, player, Calendar, DialogModule, Statistics, RPG, Variables | table in findings §2 (10 documented binds missing) |
| R2 | RTTR members of the player soul (REST paths) | `Inventory`, `EquipmentManager`, `PersistentData.RPGStats`, `Buffs`, `FactionNode`, `CombatSoul`, … ; no perk member |
| W1 | Lua `CreateItem` onion ×3 | +1 (non-stackable food; matches WO-48) |
| W1b | RTTR `Inventory.CreateItems` pear ×2, herb ×4, `ShowUINotification=false` | pear 1→3 (2 items), herb 6→10 (one new stack); nothing logged |
| W2 | `DeleteItemOfClass` onion 2, `DeleteItem` pear, `ItemManager.RemoveItem` pear, herb stack −3 | 3→1, 3→2, 2→1 (`HasItem` false), 10→7 |
| W3 | `RemoveMoney(1.5)`, `CreateItem(Money, …, 15)`, RTTR `GetMoney` | 7.9→6.4→7.9; RTTR 79 units |
| W4 | `actor:UnequipInventoryItem` / `EquipInventoryItem` (hood) | RTTR `EquipmentManager` 7→6→7 |
| S1–S3 | stats with full names; thresholds 100+40·(L−1); `SetStatLevelDebug("strength",3)`; `AddStatXP(590.9375)` | lowered to L3; restored to L5 p0.7266 (target 0.7344: 2/256 short) |
| P0–P6 | `HasPerk` on 8 perks incl. owned ones; `AddPerk` codex ×2 + indulgence; `RemovePerk(def)` | `HasPerk` always false; `AddPerk` returned nil. **The saved file** showed the adds and the removal (below) |
| B1–B4 | `AddBuff` hangover / injured_left_arm / death_protection_cutscene; `RemoveBuff(handle)` | only the guard buff appeared in RTTR `Buffs`; `RemoveBuff` false |
| ST1 | `Statistics.Set("ApplesConsumed", 42)` | RTTR still 6; saved file still 6 |
| S4 | `wh_sys_TestSaveGame` → **`quicksave028`**; offline diff 027→028 | perks: +`codex_char_lichtenstein`, +`codex_gen_desatek`, −`codex_char_hanush`; items and money as written; strength 24568→24320 |
| — | an unplanned fight after `quicksave028` | night + AFK Henry without a torch: guard `ttkc_man_7` repeated the vanilla no-torch reaction, then attacked (2 attackers). The guard buff held health at **1.0**. `quicksave028` carries the escalation: after reloading it, the attack resumed |
| L1 | `wh_sys_LoadGame 1 quicksave028` (in-process) | 12.2 s. Round trip read back: money 7.9, onion 1, pear 1, herb 7, strength L5 p0.7266, hood equipped |
| A1–A3 | `AddBuff(on_washed)`, `AddInjury(0.4,"arm_left")`, `Statistics.Increment` | on_washed absent; `injured_left_arm` present; statistic unchanged |
| L2 | `wh_sys_LoadGame 1 quicksave027` + clock to 10:00 + guard | 18.1 s; 0 attackers |
| T1 | `SetWorldTimeRatio(0)` for 4–5 s, NPC positions, heartbeat | clock frozen, NPCs moving (4–10 m), timers firing (78→155), `IsWorldTimePaused` false; ratio restored to 15 |
| D1 | control: `ForceDialog(ttkc_man_5, player)` unsuspended | both in dialogue, `WAITING_FOR_INTERACTION`, `IsWorldTimePaused` **true**; closed with `human:InterruptDialogs()` |
| D2 | `wh_ai_PauseNPC ttkc_man_5` (engine: `Can't update suspended node!`) + `ForceDialog` | identical to D1 |
| D3 | suspended: `npc.human:RequestDialog(player)` | registered (`id 2961`), never attempted, timed out |
| D4 | `wh_ai_ResumeNPC`, then the same request | attempted (`Attempting to start new dialogue … 'Ex: Dude; Ex: ttkc_man_5'`), timed out (no player input). The stale `2961` was tried at resume: `not in pending request list` |
| Y1 | copy `quicksave027` → new `<saves>/playline9/`, `wh_sys_LoadGame 9 quicksave027` | nothing happened (no load, no error) |
| Y2 | copy → `<saves>/playline1/quicksave091.whs`, `wh_sys_LoadGame 1 quicksave091` | nothing happened |
| Y3 | cvars `wh_sys_DebugSaveLock`, `PlaylineSavegameCount` (100), `LastLoadedSave` (a path), `GameSaveName`/`GameSaveId` (empty), `NoSavePotion`, `FreezePlayline`, `NoPlaylineDeleting` | read |
| Y4 | `wh_sys_TestSaveGame` (→ `quicksave029`), retry Y2 | still not loadable: a game-written save does not rescan either |
| K1 | `Game.AddSaveLock("kcdmp_wo112_probe", …)` then `Game.SaveGameViaResting()` | no save written, nothing logged |
| K2 | `wh_sys_TestSaveGame` under the lock | **`quicksave030`** written |
| K3 | duplicate `AddSaveLock` before and after `wh_sys_LoadGame 1 quicksave030` | false before, **true after**: the load wiped the lock; lock removed afterwards |
| M1 | `RPG.GetLocations()` | 33 location objects, `GetName` works, no discovery flag |
| Q | `System.Quit()` | process gone within 6 s |

## 5. Decisions taken

* **Probe on a fresh throwaway** (`quicksave027`), written at once after
  loading WO-111's `quicksave025`, as WO-111 did.
* **The saved file is the ground truth for writes.** Several read binds are
  broken or absent (`HasPerk`, statistics), so every write that mattered was
  checked in a save parsed offline, then reloaded.
* **No native code, no DLL build.** RTTR over REST and Lua stood in for native
  calls. The native reach of each is stated per row (RTTR = what the DLL
  already calls by name).
* **The unplanned fight was not debugged beyond its cause.** The log showed
  the vanilla no-torch escalation. The session moved to a clean save and set
  the clock to daytime.
* **The slot question was settled with copies only.** The copies were deleted
  and the real saves never moved.
* **S3 (splice) is recommended but not built.** The prompt said "assess, don't
  build". The MD5 reproduction is analysis, and no modified save was written.

## 6. Not done, inconclusive, stated plainly

See findings §8. In short:
* two-player;
* a live load of a modified save;
* the raw XP encoding;
* why two `AddBuff` calls did not apply;
* the real talk key on a suspended NPC;
* the quest-item self-heal;
* Save & Quit under the lock;
* the menu-load path with a rescanned file;
* horse/whistle/saddlebag binds (not run).

The peer-test logs of 2026-09-22 were **not** requested or read; the design
uses the prompt's evidence summary as given.

## 7. Side effects on the machine (disclosed)

* **Saves written** in `<saves>/playline1`:
  * `quicksave027` (clean throwaway);
  * `quicksave028` (contains the guard escalation and the test perk/item
    changes);
  * `quicksave029` and `quicksave030` (after the daytime reload; `030` was
    written under the probe lock).
  All are safe to delete. WO-111's `quicksave025`/`026` are untouched.
* **Created and deleted**: `<saves>/playline9/` (one copy) and
  `playline1/quicksave091.whs` (one copy). Neither remains.
* **World-state edits inside the throwaway saves**: world time moved with
  `SetWorldTime` (+12 h, +5 h, +11.6 h); items created/deleted; perks
  added/removed; a strength level lowered and restored (2/256 short); an
  `injured_left_arm` injury added. All in throwaway saves only.
* **Accidental REST invocations.** REST `GET` on a method name invokes it. A
  name probe hit `Revive` (engine refused: "not revivable") and `SetState` /
  `SetSkillLevel` without arguments (connection reset; health and skills read
  unchanged afterwards).
* **`kcd.log` rotation.** The launch moved the previous `kcd.log` into
  `logbackups/`, which holds one file. Both previous logs were copied to
  `<scratch>` first; the session's own log was copied at the end.
* **Steam** was already running and was left running.

## 8. Tooling notes (for the next session)

* **REST `GET` on a method name invokes it.** Probe member names only with
  names known to be read-only, or with `?info` (which resets the connection
  on some types: `Soul`, `RPGStats`, `DerivedStatsByName`, `Statistics`
  containers).
* **The listener resets connections intermittently.** A reset can arrive
  after the command ran. For writes, prefix a unique `BEGIN <token>` log line
  and resend only if the token is absent. A blind retry double-applied one
  create in this session.
* **Stat and skill names must be written in full** (`strength`); the
  documented short names (`str`) return nothing.
* `DialogModule.ForceDialog` opens a real dialogue UI and pauses world time;
  close it with `player.human:InterruptDialogs()`.
* **Leaving Henry AFK in a town at night escalates to a guard fight** (no
  torch). Keep the guard buff on and set the clock to day before long probes.
* **Bash heredocs turn `\0` into a literal NUL byte** in Python source
  (WO-108's note, again). Patch with a byte-level replace or the Edit tool.

## 9. End gate

* **Committed**: `docs/WO-112-split-save.md`, `docs/WO-112-progress.md`,
  `tools/Read-SaveAnatomy.py`, with the `WO-112:` prefix, pushed to
  `origin main`.
* **Privacy sweep** of all three files (user name, home paths, host names,
  IPs, DDNS, Steam ids, the save header's `UserName`/build-computer fields):
  results in the commit notes of this session.
* The tool never prints the save header's user or build-computer fields.
