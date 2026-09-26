# WO-123 progress

Session 2026-09-25, solo. Findings: `docs/WO-123-findings.md` (Phase 0 GO
first). **Dormant** behind `mp_shared_world`; no installer, no VERSION bump.

## 1. Phases

| phase | state | where |
|---|---|---|
| 0 C#-spliced save loads | **GO**, live | findings §0 |
| 1 pause the host | done; clock, bodies (incl. animals), `no_input` hold, message, deferral, every resume path live | findings §2–4 |
| 2 send the save | done; v9 wire, 32 KB chunks, 256 KB window, SHA-256 + Verify both ends, staging + sweep, progress | findings §5 |
| 3 joiner ready | done; host resumes on Ready (synthetic joiner, live host) | findings §6 |
| 4 measure | loopback done (1.4 MB, 13.6 MB, 60 s pause drift); **LAN not run** | findings §5.3, §2.1 |

## 2. Code

* Protocol `ProtocolWo123.cs`: 0x48–0x57 (request, offer, chunk, ack, done,
  abort, ready, status), `JoinWire` = the one length/side table,
  `Protocol.Version` 8 → 9 (WO-122's 0x46/0x47 ride along). Next free byte 0x58.
* Relay: `ClientSession` gate from `JoinWire`, `TcpBroadcastService.RouteJoin`
  (joiner → damage authority only; host messages only from it; aborts either
  way).
* Agent: `WorldTransfer.cs` (WorldSender / WorldReceiver, no socket),
  `GameBridge.Wo123.cs` (host run loop, deferral, resume paths, joiner side,
  `/join-status`), hooks in `GameBridge.cs` (frames, peer gone, disconnect,
  load start / Gameplay started, reload convergence skipped under a join),
  `LogTailGameTransport.LoadStarted`, `VersionIpcServer` `/join-status`,
  WO-122 `RequestWorldSaveCoreAsync` returns the file + WorldSaved seq; no
  scheduled save during a join.
* Launcher: polls `/join-status`, banner "Receiving the world… 62%".
* Lua `kdcmp.lua` (WO-123 section after WO-86): `KCD2MP.w123`,
  `KCD2MP_JoinTry/Resume/ResumeStale/DeferEnd/Progress/Cancel/Request`,
  `KCD2MP_JoinBusyReason`, `KCD2MP_JoinScanNpcs` (NPCs, horses, animals),
  `KCD2MP_JoinHold` (`noinput` default), the on-screen bar with the draw-loop
  backstop, commands `mp_join_cancel`, `mp_join_timeout`, `mp_join_request`,
  `mp_join_hold`, `mp_join_hold_probe`, marker `WO123-BUILD`. Pak rebuilt
  (the working-tree Lua is LF again, as the committed pak's is).
* Tests: `Wo123Tests.cs` (14, synthetic saves only), relay +4,
  `Test-WO123Synthetic.lua/.ps1` (127). Tools: `synthpeer --join` /
  `--join-host` (`JoinPeer.cs`), `tools/wo118/join123.py`, `run123.py`,
  `drift123.py`.

## 3. Decisions taken (unattended)

* **`no_input` action map as the hold**: the engine's own fader lock;
  observed to leave only itself and the platform-interrupt map active. The
  `player`/`movement` route left `combat` live. Filters are not registered.
* **Animals paused too** (any body with a soul): the first build let hares
  run 39 m during a paused minute.
* **Chunks 32 KB, not 64 KB**: a frame's length is a u16.
* **Defer on the agent side** for a load, the 10 s after it, and a pending
  clock convergence; the mod cannot see the post-load window (§4.2).
* **No reload convergence while a join exists**: the join's save is the world
  the joiner loads (§4.1).
* **A load under a pause ends the join at the load's first line**, and a
  stale pause is resumed after `Gameplay started` (the load kills timers).
* **Fight not provoked live** (needs UI input or native skirmish code); the
  combat branch is synthetic-tested and in the runbook.
* **No release**: everything is dormant.

## 4. Live method and side effects

* Launch: Modding Tools `KingdomCome.exe` from `<install>` (started
  minimised; it later came to the foreground by itself), Steam up; `kcd.log`
  and its backup copied aside before the launch. An earlier attempt in this
  WO had launched once before (its log copied too) and quit from the game
  menu. `KCDMP.dll` (the unchanged 0.29 build) injected with
  `KCDMP_LauncherInjector`. Local relay + the agent first (id 0 = host), then
  `synthpeer --join` per scenario; a second relay on 7779 (HTTP 5274) for the
  synthetic-host ceiling runs.
* Observation: REST console only; the engine's `i_listActionMaps` overlay and
  captures of the **game window only** (PrintWindow on its handle). No key or
  mouse input was sent. No capture is committed.
* Throwaway: playline1 `quicksave043` (made from WO-122's `quicksave038` by
  the earlier attempt), loaded 4 times. Daytime throughout (16:52 → 17:51).
* Phase 0: `mpworld123.whs` (the C# splice) was placed in playline1 by the
  earlier attempt, loaded, and **removed** this session after a byte compare
  with the scratch copy. WO-115's `quicksave027` and `save021`: SHA-256
  unchanged.
* Written into playline1 by the joins and the WO-122 schedule:
  `autosave044`–`autosave058` (throwaway, safe to delete).
* In-world: pauses only; seven hares paused and resumed by hand once (the
  animal test). A live shim of the animal scan and `KCD2MP_JoinResumeStale`
  was installed in the running game (Lua globals) before the pak was rebuilt.
* The agent was restarted twice (code fixes); `join123.py down` between runs.
* Game quit with `System.Quit()`; agent and both relays stopped.

## 5. Runbook: what is left for a human

1. **Mid-combat deferral**: `mp_shared_world on`, relay, agent (connect
   first), start a fight with any NPC, then
   `synthpeer --join --ready-after 5` from `tools/wo118/synthpeer`. Expect
   JoinStatus `deferred combat` every 10 s and the pause right after the
   fight ends.
2. **Console under the hold**: during a pause press `~`; expect the console
   to open, and `mp_join_cancel` to resume at once.
3. **Keys under the hold**: during a pause try W/A/S/D, attack, Esc, Tab;
   expect nothing. After the resume all of them work.
4. **LAN**: run the relay on one machine, the host agent on it, and
   `synthpeer --join --host <relay>` on the other; read the host's
   `transfer done … MB/s` line. Then `--join-host random:13631488` for the
   ceiling.
