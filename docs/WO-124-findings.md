# WO-124: the join, on the joiner's side

Session 2026-09-25. Solo, one machine, Modding Tools build 1.5.5. The real
game is the **joiner**; a synthetic host (`tools/wo118/synthpeer --join-host`)
serves a copy of a real host save through a local relay. Progress, method and
side effects: `docs/WO-124-progress.md`. First two-machine session:
`docs/WO-124-first-shared-world-runbook.md`. Settled decisions:
`docs/DECISIONS-coop-design.md`.

Evidence marks: (observed) / (code-verified) / (synthetic) / (inconclusive).
Saves are named `playlineN/file`. **Dormant:** nothing here runs unless the
HOST runs a shared world. No installer, no VERSION bump, no protocol bump
(still v9).

---

## 0. Answer first

| test | result | evidence |
|---|---|---|
| 1 happy path: menu → request → receive → splice → place → load → checks → beside the host → Ready → host resumes | **works**, 4 runs; request → Ready at the host **53–61 s** | observed |
| 2 corrupted world | rejected by WO-123's SHA-256 before any splice; 0 files placed, 0 staged; host resumed | observed |
| 3 no own save | auto: no request at all, "Start a game of your own first…"; manual `mp_join_request`: world received, abort `no-own-save`, host resumed | observed |
| 4 already in a world | no request; "Your host is in a shared world. Quit, start the game again and wait at the main menu to join." (HUD + launcher) | observed |
| 5 after the join | the mpworld file gone; the engine's own Continue pick = the joiner's own newest save, right after the load **and** at the next launch | observed |
| 6 quit | no mpworld file; notice "Your progress in shared worlds isn't saved yet." in the launcher, once (marker file) | observed (first); code-verified (once) |
| 7 host disconnects | told; lock released; the joiner's own newest save loaded ("back in this player's own world") | observed ×2 |
| 8 host `mp_shared_world off` | the joiner learns "separate worlds"; nothing asked, nothing locked | observed |
| 6a avatar on the horse | dismount before the horse is released, read back, no bind while mounted | observed (synthetic rider) + synthetic |
| 6b detach skipped in a conversation | retried once the conversation ends | observed (3 NPCs) + synthetic |

**The one thing the WO assumed that KCD2 does not have: a way back to the
main menu.** Console `disconnect` crashes the game; the menu's Quit ends the
process; only a *failed load* returns to the menu (§6). Every "back to the
menu" in the WO is therefore "back to the menu" before the load, and "back to
the player's own newest save" after it. Recorded as a decision (progress §3);
the maintainer may prefer another route (§6.3).

Gates: 22 Lua suites (1,570 checks; WO-124: 28 + 24), both static Lua checks,
267 client tests (22 new), 42 relay, 59 Farkle, native build: green.

---

## 1. Phase 0: what runs at the main menu

| piece | at the menu | evidence |
|---|---|---|
| REST console (`ExecuteString`, `#` Lua) | runs | observed |
| mod Lua called from the console | runs; `System.LogAlways` reaches kcd.log | observed |
| `Script.SetTimer` (every mod chain, the emitter) | **never fires** (armed, 3 s, nothing) | observed |
| the DLL's gameplay tick (`C_ModulesManager::Update`) and the pipe | **live** (130–180 frames/s): WO-10's "not until a save is loaded" is stale on 1.5.5 | observed |
| `player`, `System.GetEntityByName("Dude")` | nil / nothing on a fresh menu | observed |
| REST Calendar GameTime | 0 on a fresh menu; **> 0 after a failed load** (the clock survives) | observed |

Built on: the agent drives everything (REST + pipe); the launcher shows the
state; the mod only answers calls.

* The agent now connects at the main menu (GameTime 0, or the log's last word
  is the menu: `PlayVideoOnly 'main_menu…` after the last `Gameplay started`).
  The log tail is used without waiting for emitter frames. Its Lua pushes are
  held until a world exists except the join's own calls (menu gate, 300+ held
  per minute with a synthetic host streaming). (observed)
* The joiner asks for the world by itself 2 s after it learns the host's mode;
  5 automatic tries per connection, then `mp_join_request`. (observed)
* The mode travels as JoinStatus state 8 `session` (joinId 0, reason
  `shared-world`/`separate`) from the host to each peer: on connect, on a new
  peer, on a toggle, every 30 s; only once the host has run a shared world, so
  separate-world sessions carry nothing new. The relay already routes it
  (host → one peer). No new type byte; next free stays **0x58**. (observed,
  code-verified)
* Launcher: the existing banner shows each state's message: "Waiting for your
  host…", "Your host is busy, you'll join in a moment.", "Receiving the
  world… 62%", "Preparing your character…", "Loading your host's world…", "In
  your host's world." (`/join-status`, observed as JSON; banner not seen: no
  launcher in this session).

---

## 2. Phase 1: which Henry

* Newest own save by the header's `SaveTime`, across `playline0..4`, engine
  names only (`WorldSaved.ParsePath`), never `mpworld*`; the pick must pass
  `WhsSave.Verify` (a newer broken file is skipped and logged). Here:
  `playline2/quicksave022` (a fresh throwaway, newest overall). (observed)
* `mp_join_henry <auto|playlineN/file>` overrides (Lua command → agent);
  refused unless `playline[0-4]/[A-Za-z0-9_]+`. (synthetic)
* Logged as `playlineN/file` only. (observed)
* No own save: the auto path never asks (the host is never paused); a manual
  request aborts after the transfer with `no-own-save` (JoinAbort 12) and the
  host resumes in 0.1 s. (observed)

## 3. Phase 2: the splice in the agent

* `WhsSave.Splice` → `Check` → `Verify` on the result, in memory: 207–248 ms
  for a 1.43 MB world + a 1.42 MB Henry; `check PASS`, 0 quest items to strip,
  key bindings `joiner_added=2`. (observed ×5)
* Any failure → JoinAbort `splice-failed` (13), nothing placed. (code-verified)
* Tables.pak for `IsQuestItem`: `KCD2MP_INSTALL`, else beside kcd.log.

## 4. Phase 3: place and load

### 4.1 The native rescan (Framework exports, fail closed)

* Framework.dll exports `C_PlayerProfileWHManager::UpdateSaveGameDescriptions`,
  `GetSaveGameDescription(Count)`, `GetCurrentPlaylineIdx`,
  `GetNewestSavedGameFromPlayline` (= GUIModule's Continue: current playline →
  newest → load) and `C_SaveGameDescription::GetFilePath`. (code-verified)
* Manager = `GetGameIface()+0x50`, lifted at runtime from WHGame's own
  `Game.AddSaveLock` bind (`call [GetGameIface]; mov rcx,[rax+imm]; call
  [AddScriptSaveLock]`); a description's base name = CryString at `+0x80`,
  lifted from `GetFilePath`'s first field read. Either anchor missing → the
  pipe answers "not armed" and the join aborts. (code-verified, observed armed)
* A file copied in after startup: listed after the rescan (idx 14 of 22),
  loaded by `wh_sys_LoadGame 2 mpworld…` from the menu. (observed)
* Pipe 0x1D → 0x8D (rescan + find + Continue's pick); research trigger
  `kcdmp-savelist-test.txt` (`list <pl>`, `find <pl> <name>`, `continue`).

### 4.2 The file

* `playlineN/mpworld<joinId>.whs` in the Henry source's playline (= the
  menu's current playline: the menu picks the playline of the newest save),
  written as `.part` then renamed, read back by SHA-256 + Verify. (observed)
* **It must stay until `Gameplay started`.** From the menu the engine prints
  `Loading saved game '…'` at once, loads the level, and reads the file only
  ~45 s later (a second `Loading saved game`, then `[CryAction] LoadGame`).
  Deleting it earlier (the first build: a 20 s wait on `[CryAction] LoadGame`)
  failed the load: "Exiting to main menu because save game loading failed."
  (observed ×3)
* Right after `Gameplay started`: deleted, rescanned (not listed), and
  Continue's pick read from the engine: `playline2/quicksave022` = the
  joiner's newest own save in that playline → OK. (observed ×5)
* **Before the delete, Continue's pick was the mpworld file** (its SaveTime is
  the host's, newer): the leak WO-112 §3.5 predicted is real. (observed)
* Stale files: swept at agent start from every playline, and before placing.
  (observed: 0 found; synthetic)

### 4.3 Times (loopback, 1.43 MB world)

| step | time |
|---|---|
| request → offer → file verified | 0.00–0.01 s transfer |
| splice + check + verify | 0.21–0.25 s |
| load command → accepted | 0.1 s |
| → the file read (`[CryAction] LoadGame`) | 44.5–52.4 s |
| → `Gameplay started` | 51.9–59.9 s (43.2 s once, straight after a failed load) |
| post-load checks → Ready | ~1.3 s |
| host: request → Ready | 53.4, 54.1, 54.8, 61.3 s |

## 5. Phase 4: in the world, before Ready (observed ×4 unless marked)

1. **Save lock**: `kcdmp_host_only` asserted, read back by the engine's
   refusal (`lock=held`).
2. **Death guard**: `session=on mp_respawn=on applied=on` (pipe 0x1E). The
   first run read `applied=off`: the DLL had been injected at the menu, its
   RTTR walk failed there and never ran again (§7.1); fixed.
3. **Henry**: money file 151 = live 15.10 × 10; 24 item classes / 50 total
   amount, 0 differing (the live-only keyring aside). The host save's Henry
   has 79 and 28 entries, so the host's Henry would fail it. Skills are read
   and logged (fencing 7:0.195, …) but **not compared**: the saved XP encoding
   is still undecoded (WO-115). (observed; skills inconclusive)
4. **Beside the host**: 3.0 m east of the host's streamed spot, navmesh-snapped
   (z 123.38 → 123.70), residual 0.00 m, fall damage held 3 s. Eight
   directions are tried; no ground anywhere = no teleport (the joiner keeps
   the spliced spot, not fatal). (observed ×3)
5. **Ready** (0x54): the synthetic host resumed. (observed)

A mismatch in 1–3 sends JoinAbort (`lock-failed` 16, `henry-mismatch` 15)
and leaves the world (§6). Observed once for step 2 (before the fix): abort
sent, host resumed, own save loaded.

## 6. Phase 5: playing and leaving

### 6.1 No exit to the main menu

| route | result | evidence |
|---|---|---|
| console `disconnect` | **fatal**: `CNetwork::SyncWithGame(eNGS_Shutdown) called recursively`, BugSplat | observed |
| pause menu Quit | `C_UISaveLoad::ExitGame` → `CSystem::Quit` (process exit) | code-verified |
| `wh_ui_ExitToMainMenu` | enables a debug "Save and exit to main menu" entry; tied to a save (the lock blocks it) | code-verified |
| a failed load | "Exiting to main menu because save game loading failed." + a "Game load failed / OK" box; the menu works after it | observed ×3 |

### 6.2 What ships

* **After the load, leaving = loading the joiner's own newest save** (the
  join's Henry source): told first, lock released, 4 s, `wh_sys_LoadGame`.
  Triggers: a failed post-load check, the host leaving the relay, the relay
  connection dropping, the host turning the shared world off, the host
  aborting mid-load. (observed: host left ×2, lock-failed ×1)
* Before the load, a failure simply stays at the menu. (observed)
* Quit from the host's world: the process ends; mpworld files swept; the
  launcher shows the notice once. At the next launch the menu's Continue is
  the joiner's own newest save. (observed)
* A joiner that loads a save of its own from the pause menu leaves the host's
  world (lock released). (code-verified)

### 6.3 For the maintainer

The failed-load route is a real way back to the menu (a listed file that
vanishes before the engine reads it). It shows an error box and relies on the
engine's failure path, so it was not shipped. If "back to the menu" matters
more than "back to your own game", that is the lever. (inconclusive as a
design)

## 7. Found live, fixed

1. **RTTR walk at the menu (all builds since the walk).** The plugin's tick
   runs at the menu, so the startup walk found no soul list, failed, and never
   ran again: `read_player_soul()` null all session → **no death guard** for a
   plugin injected before a world (the launcher injects at startup). Now it
   re-walks every 2 s until it succeeds. Separate commit. (observed)
2. **The frame loop blocked for the whole join.** The received-world handler
   awaited the splice/load task: no relay frame (positions, aborts) was
   handled for ~53 s, so step 4 found no fresh host position. Off the loop
   now. (observed)
3. **The last kcd.log line has no terminator** until the next line is
   written; at a quiet menu a mod event sat unread (the `mp_join_request`
   event). The tail now takes an event line unchanged for 300 ms, once.
   (observed)
4. **After a failed load**: GameTime > 0 and `Dude`/`player` still exist at
   the menu, so the agent thought a world was loaded. The menu is read from
   the log's history now. (observed)
5. Early file delete (§4.2). (observed)
6. Test tool: the synthetic host offered the whole-file MD5, not the footer
   MD5 (`verify-failed`). (observed)

## 8. Phase 6: the two peer-test fixes (separate commits, always on)

### 6a: the avatar and the horse

* Cause, seen live: after `ForceDismount` the body **still reads mounted**
  (the dismount animation), and the old code bound the avatar to the native
  writer on the very next tick; plus the latched `nativeMounted` could miss a
  late mount entirely (the field case). (observed + code-verified)
* Now: Riding STOP asks the body, dismounts **before** the horse is released,
  reads it back; still mounted → no bind, retry every 0.5 s; the 300 ms mount
  check does not latch a mount that landed after the stop; no bind for a
  mounted or parented avatar, ever.
* Live (synthetic rider `ride 12 32`): `MP-DISMOUNT … flag=true live=true
  force=ok after=true` → bound 0.5 s later when it read unmounted → the
  avatar walked with its stream (gait readback 0.50 m/s). (observed)

### 6b: the detach and the conversation

* Live, own world: three NPCs puppeted while talking → `skipped-dialog` →
  retried 2.7, 2.7 and 9.1 s later (`why=retry-after-dialog`); the scribe went
  `Scribe_TableListeningLoop_VAR → MotionIdle`. Silent while waiting; once.
  (observed)

## 9. Carry-forwards

1. **QuickSave passes the joiner's lock (observed).** A console
   `wh_sys_TestSaveGame` in the host's world wrote `playline2/quicksave023` —
   the shared world, in the joiner's own playline, and the newest save there
   (deleted at once; Continue back on `quicksave022`). The mod never calls it
   and a player needs the console; the joiner's agent now watches its saves
   folder while joined and logs `MP-SAVELOCK LEAK`. `wh_sys_FreezePlayline`
   (WO-112 §3.6) is the untested stronger lever.
2. **Skills not compared** (§5 step 3).
3. **Relay authority at the menu.** Every agent now connects at the menu. With
   the launcher's local relay the host's own agent stays the authority (rule 1,
   loopback); with a remote relay the first to connect wins (rule 2) —
   before WO-124 the first to load did. Runbook: host first. (code-verified)
4. **Two machines, LAN/WAN, a real host agent's pause**: not run here (WO-123
   ran the host side live).
5. **The launcher banner itself** was not looked at (JSON only).
6. The joiner's own mp_shared_world toggle no longer matters in a session with
   a WO-124 host; with an older host it still decides the WO-122 lock.
7. `JoinAbort` reasons are 12–17 (append-only); busy reasons appended after
   `clock-sync` (19).

## 10. Address index (Modding Tools 1.5.5, re-found at runtime)

| what | where | anchor |
|---|---|---|
| `C_PlayerProfileWHManager::*`, `C_SaveGameDescription::GetFilePath` | Framework exports | names |
| manager offset 0x50 | WHGame `Game.AddSaveLock` bind (0x18C990) | the call pattern |
| description name +0x80 | `GetFilePath` | `48 8B 87 imm32` then `44 8B 48 F4` |
| Continue | GUIModule 0x319180 | calls `GetNewestSavedGameFromPlayline(GetCurrentPlaylineIdx())` |
| menu playline pick | GUIModule 0x3158C0 | rescan → `GetNewestSavedGame` → `SetCurrentPlaylineIdx` |
| `QuickLoad` rescans too | Framework 0xEF760 | calls the rescan core 0x1055E0 |
| `IConsole::AddCommand` = +0x108 | Framework `wh_sys_LoadGame` registration | (found; not used) |
| `C_Game::Update` = C_Game vftable slot 8 | WHGame 0x12FEC0 | RTTI + "wh::game::C_Game::Update" (found; not used) |
