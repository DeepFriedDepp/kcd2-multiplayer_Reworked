# WO-124 progress

Session 2026-09-25, solo, unattended. Findings: `docs/WO-124-findings.md`.
Runbook for the first two-machine session:
`docs/WO-124-first-shared-world-runbook.md`. **Dormant** unless the host runs a
shared world; no installer, no VERSION bump, protocol still v9.

## 1. Phases

| phase | state | where |
|---|---|---|
| 0 starting a join (mode from the host, menu detection, auto request, "go to the menu") | done, live | findings §1 |
| 1 which Henry (newest own save, override, none) | done, live | findings §2 |
| 2 splice in the agent | done, live | findings §3 |
| 3 place, rescan, load, delete, Continue | done, live | findings §4 |
| 4 lock, guard, Henry check, beside the host, Ready | done, live | findings §5 |
| 5 playing, quitting, host gone | done, live; **no exit to the main menu exists** | findings §6 |
| 6a avatar on the horse / 6b detach after a conversation | done, live + synthetic, separate commits | findings §8 |

## 2. Code

Commits on `main`: `f09be12` (the RTTR re-walk), `7b803ba` (the join),
`dc7aa85` (6a), `fbc890e` (6b), then these docs.

* Native (`native/KCDMP`): `savelist.cpp/.h` (the save-list rescan by
  Framework exports, two lifted offsets, research trigger), `join_native.cpp/.h`
  (placement beside the host, fall-damage hold), pipe 0x1C/0x8C JoinPlace,
  0x1D/0x8D SaveList, 0x1E/0x8E JoinGuard; `rttr_abi.cpp` lazy re-walk.
* Agent: `GameBridge.Wo124.cs` (the whole joiner flow + the host's mode
  announcement), `CombatPipe.cs` (the three pipe calls), `GameBridge.cs`
  (connect at the menu, the menu gate, tail events), `LogTailGameTransport.cs`
  (`SaveLoadAccepted`, `LoadFailedToMenu`, `MainMenuShown`, `GameQuit`,
  `ScanAtMainMenu`, the unterminated event line), `HttpGameTransport.cs`
  (`ReadGameTimeAsync`, `ReadWorldLoadedAsync`, the yaw poll without a player),
  `GameBridge.Wo123.cs` (effective mode, status `session`, abort routing, the
  received world off the frame loop), `GameBridge.Wo122.cs` (the lock follows
  the host's mode and the joined world; the saves watch while joined).
* Protocol: JoinAbort 12–17, JoinStatus state 8 `session`, busy reasons
  appended. No new type, no version bump.
* Lua (`kdcmp.lua`, WO-124 section after WO-123): `KCD2MP.w124`,
  `KCD2MP_Wo124SessionMode/Where/Lock/Henry/Msg/LoadGame`, `KCD2MP_SetJoinHenry`,
  command `mp_join_henry`, marker `WO124-BUILD`; `KCD2MP_HostOnlyLock` and
  `KCD2MP_JoinRequest` accept the host's mode. 6a: `KCD2MP_GhostIsMounted`,
  `KCD2MP_GhostDismount(Retry)`, the bind gate. 6b: `detachPending`,
  `KCD2MP_NpcDetachRetry`. Pak rebuilt per commit (from LF Lua).
* Tests: `Wo124Tests.cs` (22, synthetic files), `Test-WO124Synthetic` (28),
  `Test-WO124FixesSynthetic` (24).
* Tools: `synthpeer --join-host` = a synthetic WO-124 host (`--shared`,
  `--host-pos`, `--serve`, `--corrupt-chunk`, `--leave-after-ready`), plan line
  `ride <t0> <t1>`; `tools/wo118/join124.py`.

## 3. Decisions taken (unattended)

* **Leaving after the load = the joiner's own newest save**, not the menu:
  KCD2 has no safe exit to the menu (`disconnect` crashes, Quit exits, only a
  failed load returns). A player is never stuck, keeps their own game, and
  their saves are untouched. The failed-load route is described for the
  maintainer (findings §6.3).
* **The "already in a world" message says how to get to the menu in KCD2**:
  "Your host is in a shared world. Quit, start the game again and wait at the
  main menu to join." (the WO's "Return to the main menu" has no action
  behind it).
* **The mode rides on JoinStatus** (state 8, joinId 0) instead of a new type:
  the relay already routes host → one peer; no protocol bump; nothing new is
  sent until a host has run a shared world.
* **The agent connects at the main menu** (it must, to learn the host's
  mode), with its world pushes held until a world loads. Consequence noted:
  with a remote relay the first player to connect becomes the authority
  (findings §9.3).
* **The joiner's save lock follows the joined world**, not the connection
  (with a WO-124 host); with an older host, WO-122's behaviour.
* **No own save: the automatic path does not ask** (the host is never paused
  for nothing); the manual path asks and aborts, so the host-resume case is
  still exercised.
* **The Henry check compares money and every item class/amount**; skills are
  logged only (XP encoding undecoded). A mismatch leaves the world.
* **Placement failure is not fatal** (no ground in 8 directions → the joiner
  keeps the spliced spot and Ready is sent); a lock or guard failure is.
* **The DLL's walk is retried lazily** rather than re-ordering the plugin's
  startup (the first tick at the menu is fine for everything else).
* **Kept the gameplay tick for the save list** after finding it live at the
  menu; the `C_Game::Update` vtable hook and file mailbox written first were
  dropped before the first commit (not needed).

## 4. Live method and side effects

* Launches of the Modding Tools build (Steam up; `kcd.log`, its backup and the
  native mirror log copied to the session scratchpad before every launch):
  eight. Probe 1 ended in the `disconnect` crash (BugSplat's reporter was
  closed without sending); the others quit with `System.Quit()`.
* `KCDMP.dll` builds injected by hand at the main menu with
  `KCDMP_LauncherInjector`, a new file name per build. The installed pak was
  rebuilt (`Build-And-Install-Mod.ps1`) with the game closed.
* Local relay on 7778; the synthetic host first (id 0), the agent as joiner
  (id 1); agent and peers run from copies of their build folders;
  `KCDMP_DATA_DIR` = `tools/wo118/data124` (git-ignored).
* Observation: REST console, kcd.log, the native mirror log, and captures of
  the game window only (PrintWindow). **No key or mouse input was sent.**
* Saves:
  * host world served: a scratchpad COPY of `playline1/quicksave038`
    (throwaway); never in the repo, never logged by path.
  * `playline2/quicksave022`: a fresh throwaway made from `playline2/save021`
    (loaded, `Game.QuickSave()`); the joiner's newest own save for every run.
    Safe to delete.
  * `playline2/mpworld<id>.whs`: placed 9 times (once by hand for the rescan
    probe, 8 by the flow), each deleted (3 by the early-delete bug, which is
    how the failed-load route was found). None left (checked).
  * `playline2/quicksave023`: written by my own console `wh_sys_TestSaveGame`
    in the host's world (a lock probe); **deleted** at once; Continue checked
    back on `quicksave022`.
* In-world: no fights, no townsfolk touched; daytime (8:43–17:21 in-game).
  A synthetic rider's avatar mounted and dismounted beside the player; three
  talking NPCs were puppeted (paused) and released.

## 5. What is left

1. The first two-machine session: the runbook.
2. The launcher banner itself (the JSON was read, the window not looked at).
3. `wh_sys_FreezePlayline` as a second lock (findings §9.1).
4. A skill check once the XP encoding is decoded.
5. WO-125: the Henry file, rejoining with saved progress.
