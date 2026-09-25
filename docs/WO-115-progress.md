# WO-115: progress (what ran, what did not, side effects)

Session 2026-09-25, solo, one machine. Findings and verdict:
`docs/WO-115-findings.md`. Paths are written as `<saves>`, `<install>`,
`<scratch>` (the session scratchpad, not committed).
**No mod code shipped. No pak, no installer, no VERSION bump. Nothing ran
two-player.**

## 1. What ran

| phase | status | note |
|---|---|---|
| read-first | done | WO-112 split-save (in full), progress (in full, §8 tooling), `Read-SaveAnatomy.py` |
| decisions doc | done | `docs/DECISIONS-coop-design.md`, first commit (`fc6076c`) |
| 1 — splicer | **done** | `tools/Splice-SaveHenry.py` (`splice`, `check`); offline checks pass; controls fail as they should |
| 2 — load | **done** | spliced, bad-MD5 and variant-C copies placed before launch, all listed by the scan; all three loaded |
| 3 — verify | **done** | live comparison against both originals loaded in the same session; play, save, parse, in-process reload, cold reload |
| quest-item A/B | **not run (no usable save)** | both stand-ins are free of quest items; synthetic variant C ran instead |
| deliverables | done | two docs + the tool + a one-token fix to `Read-SaveAnatomy.py` |

## 2. Offline

* Inputs copied into `<scratch>/in/` and hashed before any read, then hashed
  again at the end: playline1 `quicksave027`, playline2 `save021`.
  Unchanged.
* **Quest-class census:** 293 `IsQuestItem="true"` classes (`Tables.pak`
  `Libs/Tables/item/*`). They were matched against Henry's inventory in every
  1.5.5 save under `<saves>` (playlines 1–3 and the backups): **0 hits**.
  Playline0 (build 1.1.1, 143 saves) could not be checked: none of its
  saves has the `0x0007` inventory list in this layout.
* **Cross-reference scan:** every Henry item instance GUID was searched for
  across the whole stream. The only hits outside the soul record were
  `01f9/7302/0002` and `01f8/7302/000B`. That scan is how the key-binding
  block was found.
* **Token fix:** GameState type `0x0C` = 8 bytes (an entity-id-like value;
  one occurrence in the joiner save, `3d38c735…`, which also appears in
  `000B`). The first guess (2 bytes) was wrong: it happened to parse the host
  file, but the joiner file failed. Both files decode to their exact end with
  8 bytes.
* Outputs in `<scratch>/out/`:
  * `mpworld115` (variant A);
  * `mpworld115b` (variant B, byte-identical to A);
  * `mpworld115bad` (one MD5 byte flipped);
  * `mpworld115c` (A plus one synthetic orphan quest-class item, made by a
    scratch script, not the tool);
  * `pair2` (the second offline pairing).

## 3. Live runbook (as run)

1. Steam up; game closed. Copied `kcd.log` and `logbackups/kcd.log` to
   `<scratch>/logs/`.
2. Put `mpworld115.whs`, `mpworld115bad.whs` and `mpworld115c.whs` in
   `<saves>/playline1/`. The names have no space.
3. Launched Modding Tools `KingdomCome.exe` (working directory `<install>`, no
   args); the console API was up in 34 s. The scan logged all three files
   (`#11`–`#13`).
4. From the menu: `wh_sys_LoadGame 1 mpworld115bad` → loaded (§5 of the
   findings).
5. `wh_sys_LoadGame 2 save021` (the joiner's original) → snapshot `J_ref`.
   `wh_sys_LoadGame 1 quicksave027` (the host's original) → snapshot `H_ref`.
   `wh_sys_LoadGame 1 mpworld115` → snapshot `S_main`. Each load took 9–12 s.
6. Play (findings §4.1), snapshot `S_presave`, `wh_sys_TestSaveGame` →
   `quicksave037`.
7. `wh_sys_LoadGame 1 mpworld115c` → variant C check.
   `wh_sys_LoadGame 1 quicksave037` → snapshot `X_reload1`.
8. `System.Quit()`, logs copied, relaunched, `wh_sys_LoadGame 1 quicksave037`
   (57 s cold) → snapshot `X_reload_cold`, then quit.

Snapshot = one Lua batch (vitals, the 4 stats, 23 skills, inventory with
class/amount/health, money) + NPCs within 40 m + REST `PlayerSoul/Buffs`,
`EquippedArmorsByClassId`, `EquippedWeaponsByClassId`,
`FactionNode/PlayerRenown`, `Inventory/GetMoney`. All of these are read-only
names.

## 4. Decisions taken

* **Compare live against the originals, not against a decoder.** The raw
  stat XP encoding is still unknown. So "exact" means equal live progress
  against the joiner's own save loaded minutes earlier, not a formula.
* **`01f9/7302/0000` kept from the host** and **`000B` merged**, not taken
  whole. Both carry references into the other world. The rule is: take what
  names Henry's own items, and leave what names world objects.
* **`0x1300` carried, not stripped.** It is part of the joiner's record. The
  game dropped it by itself at the next save with no log line.
* **Daylight by `SetWorldTime`** (+15 h) before the idle period, per the
  prompt's daytime rule. It cost the persistent-buff duration check: every
  buff expired (findings §3.4).
* **No trade was faked.** Money was moved with `RemoveMoney` and labelled as a
  stand-in.
* **No death guard.** WO-113's guard is session-only (no agent here). Daylight
  in a village, with a 30 s health watch, stood in for it; no attack came.

## 5. Side effects on the machine (disclosed)

* **Saves:** `<saves>/playline1/quicksave037.whs` was written by the game. It
  is the **spliced world** (the joiner's Henry in the host world, +15 h,
  money −1, hp −5). It is now the newest save in playline1, so **Continue**
  from that playline would load it. Safe to delete.
* **Created, then deleted:** the three `mpworld115*` copies in playline1 were
  removed after the session. Each was byte-compared with its scratch
  original before deletion. Copies remain in `<scratch>/out/`.
* **Loaded but not modified:** playline2 `save021` and playline1
  `quicksave027`. Their hashes are unchanged, and playline2's listing is
  unchanged (no autosave was written).
* **In-world edits (throwaway worlds only):** clock +15 h; an apple dropped
  and picked up; a `wo115_anchor` PickableItem spawned and removed; −1.0
  money; 5 hp and 5 stamina damage.
* **`kcd.log` rotation:** two launches. Both previous logs and both session
  logs were copied to `<scratch>/logs/` before each relaunch.
* **REST connection resets** hit three times. Each command was checked by its
  log token, and none was re-sent blind.
* Steam was running before the session and left running. A running
  `KcdMpMasterServer` was left alone.

## 6. Tooling notes (for the next session)

* **`human:PickUpItem` is inert from script.** To pick something up, use the
  entity's own `PickableItem:Use(player)` (it calls `item:OnUsed`, the path
  the interact key takes). `human:PlaceItem(wuid, anchorEntity, false)` drops
  an inventory item at the anchor.
* **`Calendar.SetWorldTime` must not go backwards** (scriptbind docs).
* **The bad-MD5 file loads.** Do not rely on the game to catch a corrupt
  transfer.
* **Game-written saves join the cached save list** in the same session;
  copied-in files do not.
* **`System.GetEntityByName` of a removed entity returns nothing**, not nil.
  `tostring()` of it raises `bad argument #1`. Compare with `== nil`.
* **Git-bash rewrites `/api/...` arguments** into Windows paths. Set
  `MSYS_NO_PATHCONV=1` for REST paths without a `?`.
* **Every load prints `SAVE GAME HISTORY`** with the writing machine's account
  name. Never paste that line into a doc.

## 7. End gate

* Committed with the `WO-115:` prefix, pushed to `origin main`:
  `docs/DECISIONS-coop-design.md`, `tools/Splice-SaveHenry.py`, the
  `Read-SaveAnatomy.py` fix, `docs/WO-115-findings.md`, this file.
* No save file, log or scratch output was committed.
* Privacy sweep of every committed file (account names, home paths, host
  names, IPs, Steam ids, the save header's user/build-computer fields): see
  the commit.
