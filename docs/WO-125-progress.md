# WO-125 progress

Session 2026-09-25/26, solo, mostly unattended. Findings:
`docs/WO-125-findings.md`. Runbook: `docs/WO-124-first-shared-world-runbook.md`
(updated). **Dormant** unless the host runs a shared world; no installer, no
VERSION bump, protocol still v9 (no new type byte; next free stays 0x58).

## 1. Phases

| phase | state | where |
|---|---|---|
| 0 where a snapshot comes from | Route A (QuickSave of the joiner's copy), live; round trip byte-level; FreezePlayline tested, not shipped | findings §1, §3.3 |
| 1 the Henry file store | done; keep 100; atomic + read-back; md5 = footer MD5 | findings §2 |
| 2 first-join choice, "own" | done, live (launcher JSON/POST, console); no-own-save way out = exit file → main menu | findings §3 |
| 3 Start fresh | a new game's first Henry save on the joiner's machine; built-from-game-data refused (does not load) | findings §4 |
| 4 paired snapshots | done, live; quit notice replaced; Quit hook not done | findings §5 |
| 5 rejoin | done, live (branch replay, pair by md5) | findings §3.2 |
| 6 host reload takes the joiner along | done, live (in-world rejoin) | findings §6 |
| 7 non-Henry detect + refuse | done; save test + live name; refusal live | findings §7 |
| 8 cleanup | `mp_henry_files`, `mp_henry_reset`, 90-day rule, prune | findings §0 (13) |

## 2. Code

* `WhsSave.cs` / `WhsSave.Wo125.cs`: the splice takes `HenryParts` (from a save,
  a stored block, a fresh source); `SpliceParts`/`CheckParts`; the story stat
  written/inserted/removed; Henry blocks (`SerializeBlock`/`ParseBlock`,
  `DiffBlocks`); `ReadSeed`/`ReadSeedFromFile`/`SeedTag`; `PlayerOf`
  (Henry / Godwin / first Henry save); research `FreshDefaultParts`. CLI
  `--save-tool extract|splice-block|splice-fresh|blockdiff|seed|who`.
* `HenryStore.cs`: per-world store, pick by branch, prune, 90-day rule,
  delete, sweep ledger, move-out (`<data>/henry/swept`, newest 8).
* `GameBridge.Wo125.cs`: host identity + branch (`<data>/host-branch.json`),
  identify save, reloading notice, branch replay; joiner identity, choice,
  "own" saves, source selection, snapshot pipeline, leak handling, sweeps,
  exit file, rewind/rejoin, commands.
* Edits: `GameBridge.Wo124.cs` (tick gates, restore/bring/fresh source,
  placement playline, step 0, leave route, quit notice, menu gate after a
  quit, session mode re-told at the menu), `GameBridge.Wo123.cs` (identity in
  the status, not-Henry refusal, branch replay before the offer, state 9,
  offer md5 kept), `GameBridge.Wo122.cs` (snapshot/leak capture, host identity
  per save, branch entries in), `GameBridge.cs` (start sweep, events, menu-safe
  Lua), `VersionIpcServer.cs` (`/join-choice`).
* Protocol: state 9, session identity in joinId/arg, WorldSaved branch bit,
  JoinAbort 18–20, reasons appended.
* Lua (`kdcmp.lua`, WO-125 section): `KCD2MP_Wo125Snapshot`,
  `KCD2MP_Wo125PlayerIsHenry`, `KCD2MP_Wo125LastLoaded`, `KCD2MP_Wo125Reset`,
  `KCD2MP_Wo125Files(Show)`; `mp_join_henry` takes `fresh` and sends the answer;
  commands `mp_henry_reset`, `mp_henry_files`; marker `WO125-BUILD`. Pak rebuilt.
* Launcher: the two buttons on `choose`, `NetService.PostJoinChoiceAsync`.
* Tests: `Wo125Tests.cs` (24, synthetic saves and seeds; `WhsSaveTests`'
  builder gained seed / Godwin / first-save / no-story options),
  `Test-WO125Synthetic` (38).
* Tools: `synthpeer --join-host125` (`Host125.cs`), `tools/wo118/join125.py`.

## 3. Decisions taken (unattended)

* **Route A** (QuickSave), not a native read: the only route that carries
  perks, map, statistics and tutorials exactly; the ledger + start sweep cover
  its crash window.
* **The seed rides in the session status's unused joinId**, the branch in
  WorldSaved with a kind bit: no new type, no version bump. Cost: a WO-124 host
  leaves a WO-125 joiner waiting.
* **Keep 100 snapshots per world** (the host's autosave rotation).
* **Pick = newest pair on the host's branch**, the host tracking parents across
  sessions, then the spec's newest-snapshot fallback.
* **The join save pairs with the Henry just loaded** (a real host save the
  joiner has not played in yet), so a reload to it rewinds right.
* **Snapshot gate 3 s** after the host's save arrived; later = no pair (loss).
* **Start fresh = a new game's first Henry save on the joiner's machine.** The
  engine-built record does not load; there is no other clean source.
* **No-own-save way out = the exit file** (failed load → main menu), preferred
  per the WO; the launcher explains the box.
* **Swept files are moved, not deleted** (`<data>/henry/swept`, newest 8).
* **The leave target must be in the engine's cached list** (rescan first).
* **Step 0 after every join load** (`wh_sys_LastLoadedSave`).
* **Hosts stay silent while loading**; a world switch seen mid-join waits.
* **Quit hook not built** (process exit; not clean).
* **FreezePlayline not shipped** (it blocks the snapshot's QuickSave).

## 4. Live method and side effects

* Modding Tools build, Steam up; `kcd.log`, its backup and the native mirror
  log copied to the session scratchpad before every relaunch. Launches: 10
  (Phase 0 probe; nine for the live tests; the host run reused the last one). One game crash (§8.1 of the
  findings; BugSplat's reporter closed without sending). The session machine
  itself crashed once mid-run; the working tree and the scratchpad survived,
  the playlines were checked clean afterwards.
* `KCDMP.dll` (WO-124 build, unchanged) injected at the main menu with
  `KCDMP_LauncherInjector`, a new file name per launch. Pak rebuilt with the
  game closed (`Build-And-Install-Mod.ps1`).
* Local relay 7778; synthetic host first (id 0), agent second; agents and the
  relay run from copies of their build folders; `KCDMP_DATA_DIR` in the session
  scratchpad (never the repo).
* Observation: REST console, kcd.log, the native mirror log, the agent's
  `/join-status`, and captures of the game window only (PrintWindow). **No key
  or mouse input.** Game quit with `System.Quit()` every time.
* Host worlds served: scratchpad **copies** of `playline1/quicksave038`, `035`,
  `036`, `033`, `030` (world A), a copy of `quicksave038` re-seeded with a
  synthetic seed (world B), a re-seeded copy of a prologue save (the non-Henry
  stand-in; the maintainer then ruled prologue saves out).
* Items given in world: apples (1) and pears (2) via `inventory:CreateItem`.
  Daytime throughout (08:49–17:09 in-game). No fights, no NPC touched.
* Save files created and removed (every one checked gone; the playlines are
  back to their original sets):
  * Phase 0: `playline2/quicksave023`–`026`, `quicksave039` ×2, `quicksave023`
    (again), `quicksave040` (a planted copy of `quicksave022`),
    `mpworld12500001`–`004`, `mpexit12500005`.
  * Live tests: every snapshot QuickSave (`playline2/quicksave023`, moved to
    `<data>/henry/swept`), one leak test QuickSave, every `mpworld*`/`mpexit*`
    (one left by a race, moved out by the next agent start), hand-placed copies
    `playline2/quicksave038` (host world, re-timed) and `playline3/save099`
    (prologue, re-timed), `playline2/autosave031` (written by the game in the
    joiner's own world), `playline1/autosave059`/`060` (the real-host run).
* Real saves loaded directly: `playline2/quicksave022` (WO-124 throwaway),
  `playline1/quicksave038`, `playline1/autosave059` (written by this run),
  `playline3/permanent001` (the prologue; host run only; the maintainer then
  asked to avoid it). None modified (sizes and dates checked).

## 5. What is left

1. The first two-machine session (runbook).
2. The launcher's two buttons looked at on screen.
3. A real host across an agent restart and with its scheduled autosave while a
   joiner is in.
4. The Godwin mid-game stretch on 1.5.5 (no save of it exists here).
5. The quest sync WO: what joiners do in non-Henry stretches.
