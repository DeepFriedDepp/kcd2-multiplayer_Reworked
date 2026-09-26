# WO-129 progress: the 0.30.0 build

Session 2026-09-26, solo, mostly unattended. Findings:
`docs/WO-129-findings.md`. Tester page: `docs/TEST-0.30.0.md`. Runbook:
`docs/WO-124-first-shared-world-runbook.md` (updated).

## 1. Phases

| phase | state | where |
|---|---|---|
| 0 reproduce solo | slide reproduced on 0.29.9 with a synthetic peer on flat ground (observed) | findings §0, §2 |
| 1 bisect + skew | both ends of the range slide → no first bad commit; one local-vs-remote stamp, fixed | findings §0, §3 |
| 2 root cause + fix | probe DLL: the movement controller overwrites pseudo-speed before the tag update; tag-update hook | findings §0 |
| 2 clamp, swings, sinking | clamp observed; capture fix code-verified; sinking not reproduced | findings §3, §4, §7 |
| 3 graves, anchors, launcher, Discord | built; graves + anchors + join bar observed; launcher + Discord synthetic | findings §5, §6, §8, §9 |
| 4 gates, installer, docs | green; `release\KCDMP-Setup-0.30.0.exe` built here; live gait gate GREEN on its DLL | findings §10 |

## 2. Code

* Native `motion.cpp`: the `UpdateMannequinTags` entry hook
  (`on_update_tags`, installed from the slot-0xC98 body with byte anchors; the
  gait piece stays disarmed without it). The class and clamp come from the
  body's own engine range (`body_range`, cached 0.5 s). Velocity is smoothed
  from the rendered motion. A lock-free per-actor table is read on the main
  thread and the job workers. `WO121-GAIT` now logs `speed_mps class range
  tags_applied`. Status adds `tags=`, `tags_applied=`, `gait_slots=`.
* Native capture: `as_combat_actor` (+8 base), per-reason drop counters and
  `WO129-CAPTURE drop` lines.
* Native `gait_logic.h` (new): the pure half (bands, clamp, the engine's
  mapper, the table). `inline_hook::install_this`. `npc_drive.cpp` passes the
  puppets' velocity.
* Native `respawn_actions.cpp`: graves arm on static anchors; `graves live`
  line.
* `native/tests` (new): `KCDMP_NativeTests.exe`, 33 checks, gated in
  `Build-Installer.ps1`.
* Lua:
  - `KCD2MP_Wo129SharedAnchors`: shared world hosted here → together forced,
    every player an anchor.
  - `KCD2MP_JoinBarText`: the host bar's stage + seconds + ladder.
  - Pak rebuilt.
* Agent:
  - `Wo129.HostStampAgeMs`; `MP-WORLDSAVED … skew_removed=`.
  - `DiscordPresence.ForgetCachedAssets`.
* Launcher:
  - `Models/AgentStatusBanner.cs` (new; the two DTOs moved here).
  - `PollAgentStatusAsync` with its own token (`agentPollCts`), per-iteration
    catch, `Agent status:` log lines. The old join poll and
    `RefreshConnectionStatusAsync` are gone.
* Tests: `Wo129Tests.cs` (12), `Test-WO129Synthetic` (26), WO-123 bar checks
  updated to the new wording.
* Tools (never shipped):
  - `tools/wo129/gait_gate.py` (the live gate).
  - avatarpeer: `move … [zEnd]` and `--skew-ms`.
* `tools/Verify-Install.ps1`: 0.30.0 markers (native tag hook, skew line,
  join bar, shared anchors).
* `VERSION` = 0.30.0, and nothing else carries the number.

## 3. Decisions taken (unattended)

* **No bisect past the endpoints.** `dd7ab9b` slid like `2b3561e`, so the
  regression premise was false. I spent the time on the engine instead of on
  the commits between them.
* **Hook the tag update, not the movement controller.** The controller's
  write is how every NPC's own movement reaches its tags. Re-applying at the
  reader's entry, only for bodies we drive, changes nothing for any other
  actor.
* **Writer XFORM flags left as shipped.** The engine's real-speed cap did not
  bite in the probe runs (observed), and changing the physics flags touches
  every write.
* **Graves arm without a world.** The live objects are fetched at use, which
  every grave path already did. Refusing at use is the same as refusing at
  arm time.
* **Shared world → always together.** This is the smallest change that keeps
  the joiner's NPCs, and no leash is involved. The anchor cost with two
  anchors was measured first (findings §6).
* **Launcher poll on the agent's lifetime.** The panel's CLOSE button stays
  as it is; it just no longer owns the status poll.
* **No live swing.** It needs a real mouse click on the maintainer's desktop.
  It goes to the two-player runbook instead.
* **Sinking: one try, then left.** As the WO allowed.
* **The WO-123 bar checks were rewritten, not deleted.** WO-129 replaced
  that bar on purpose. Every check that was there still has an equivalent.

## 4. Method (reproducible)

* Game: Modding Tools `KingdomCome.exe`, started minimized, its window kept
  at the bottom of the Z order and never activated. Captures are window-only
  (`PrintWindow`, full content). No key or mouse input went into the game;
  everything went through the console API.
* Save: the throwaway `playline1/quicksave036` (WO-121's). The scene: Henry
  moved to a flat 12 m line, `e_MergedMeshes 0` (grass hidden, render only)
  while shooting, `sys_SleepIfInactiveWH 0` where fps mattered. Both were
  restored before every quit.
* Peer: `tools/wo121/avatarpeer` over a local relay and a host agent. The
  stream's z is on the ground: a floating avatar plays no locomotion at all
  (`flying=N/N` in `MP-NPCPULL` gives it away). This trap cost one invalid
  run.
* Joiner-side NPC copy: the real game as joiner, with WO-118's SynthPeer as
  the host streaming a walking `ttkc_man_2`.
* Probe DLLs (scratchpad only, never committed): inline hooks on
  `SetPseudoSpeed`, the tag update and the controller. They showed the write
  order within a frame.
* The live gate: `python tools/wo129/gait_gate.py <peer.ctl> 2452 2092 118.36
  3.927` (`KCD2MP_INSTALL` = the game folder), with the MANN watch on the
  avatar. On the installer's own `KCDMP.dll`: **GATE GREEN**, 9/9, 8/8, 9/9
  (observed). On the 0.29.9 DLL: **GATE RED**, 0/9, 0/9, 0/8 (observed). The
  gate was fixed twice before those runs:
  - its windows had counted the previous speed's samples;
  - the old DLL's logger collapses identical lines and flushes them only when
    the line changes, so each window is now read after the stop.
  It was then rerun on both DLLs. Three extra game launches, no saves
  written.

## 5. Side effects

* Saves: `playline1/autosave059` and `autosave060` (throwaway playline: the
  shared-world identify save and the synthetic join's save). `playline2`,
  the maintainer's, is untouched.
* One `test_soldier_ai` spawned beside the avatar for a swing attempt, then
  removed. No townsfolk attacked. One lethal hit on Henry in the throwaway
  save, for the grave check.
* `mp_spawn_armor` never used. The game quit with `System.Quit()` each time.
* No commits outside this WO. The scratch worktrees were removed.

## 6. For the next WO

* The two-player items in `docs/TEST-0.30.0.md` section 5. The live swing
  each way is the one that matters.
* After a swing, read the capture counters (`cap_attack`, `cap_drop_*`,
  `cap_via_base8`). If `cap_attack` is still 0, the reason counters name the
  cause.
