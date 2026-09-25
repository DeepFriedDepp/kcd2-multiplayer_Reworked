# WO-122 progress

Session 2026-09-25, solo. Findings: `docs/WO-122-findings.md`.

## 1. Phases

| phase | state | where |
|---|---|---|
| 1 owner death | done, ships ON, live-verified (synthetic peer) incl. after a load | findings §1 |
| 2 host-only saving | done, dormant; lock/load/autosave/Save & Quit live; Schnapps/sleep/quest not run | findings §2 |
| 3 host autosave + WorldSaved | done, dormant, live end to end; early-game hitch only | findings §3 |
| 4 world save on demand | done, dormant, live | findings §4 |
| 5 C# save tools | done; cross-check: stream identical, compressed bytes differ | findings §5 |
| 6 toggles, presets, marker | done | findings §6 |

## 2. Code

* Lua `kdcmp.lua`: WO-122 section after WO-86 (`KCD2MP.w122`, the toggles,
  `KCD2MP_OwnerDeathCheck/Landed`, `KCD2MP_HostOnlyLock`,
  `KCD2MP_HostWorldSave` + frame-gap monitor, `KCD2MP_SaveRefused`,
  `KCD2MP_WorldSavedIn`); hooks in the puppet tick and the one-shot resync;
  preset rows; commands; `WO122-BUILD`. Pak rebuilt.
* Agent: `GameBridge.Wo122.cs` (owner-death apply, lock driver, schedule,
  saves-folder watch + verify + WorldSaved, receiver), `WhsSave.cs` (the
  tools), `--save-tool` in `Program.cs`, `LogTailGameTransport`:
  `Gameplay started`, the engine's autosave-refused line, save generation
  time. `ApplyRemoteNpcDeathAsync` gains `bypassDedupe`.
* Protocol `ProtocolWo122.cs`: WorldSaved 0x46/0x47 (32/33 B, exact).
  Relay: forwarded only from the damage authority. No Protocol.Version bump
  (additive; the release check refuses mixed builds).
* DLL: unchanged (0.29.0 build used live).
* Tests: `Test-WO122Synthetic.lua/.ps1` (90), `WhsSaveTests.cs` (19),
  `Wo122Tests.cs` (18), relay +2. `Test-WO108Synthetic.lua`: preset count
  29 → 32. Test peer: `dead` and `saved` plan verbs, WorldSaved printout;
  plans `plan.wo122.*`.

## 3. Decisions taken (unattended)

* **Lua binds, not new DLL code**, for the lock and the save: both binds are
  one-call wrappers of the Framework exports (disassembled), and Lua works
  on retail too.
* **Autosave type for the join save**: file names are fixed per type; no
  quicksave slot used (findings §4).
* **5 minutes** default cadence (findings §3).
* **Read-back throttled to 30 s** after the live run showed each check logs
  an engine `[Error]`.
* **Owner death joiner-only**: the host's world is the truth; a host reload
  must not be undone by a joiner's stream.
* **No mod change for Save & Quit**: the engine greys it out under the lock.
* **No UI input** once the machine was seen in use: the Schnapps test moved
  to the runbook.
* **Cross-check reported as stream-identical**, not faked: the zlib encoders
  differ (findings §5.2).
* No release: only Phase 1 changes gameplay; commits only (the WO default).

## 4. Live method and side effects

* Launch: `KingdomCome.exe` (Modding Tools) from `<install>`, Steam up;
  kcd.log and the backup copied aside before every launch (3 launches).
  `KCDMP.dll` injected with `KCDMP_LauncherInjector`. Local relay +
  `tools/wo118/synthpeer`; roles by connect order (lowest id = host).
* Throwaway: loaded WO-121's `quicksave036`, wrote **`playline1/quicksave038`**
  (`wh_sys_TestSaveGame`) and used it throughout. Daytime (16:48 game time).
* Written by the tests into playline1 (throwaway): `autosave039` (control),
  `autosave040` (schedule), `autosave041`, `autosave042` (on demand). Safe to
  delete.
* World mutations in the throwaway: `ttkc_man_26` killed (twice, reloaded
  between); a pear added by RTTR (then reloaded away).
* The heavy-save attempt: `playline2/permanent001` copied to
  `playline1/wo122heavy.whs`, loaded, found to be the prologue siege (not
  Henry; the maintainer pointed this out), **deleted**; the original's
  SHA-256 is unchanged. Nothing was saved from it.
* WO-115's `quicksave027` and `save021`: SHA-256 unchanged after the session.
* Screenshots and key input were used briefly for the pause menu; stopped
  when the machine was in use. No screenshot is committed.
* Game quit with `System.Quit()`; agent, peers and relay stopped.

## 5. Runbook: what is left for a human

1. Schnapps: buy or pick up a Saviour Schnapps. `mp_shared_world on`, start
   the relay, a synthetic host (`synthpeer`, connects first) and the agent.
   Drink it: expect no new file in the playline, the potion still there, and
   the toast. Control: `mp_shared_world off`, drink: a `save%03d` appears.
2. Sleep in an owned bed under the same setup: no file, the toast.
3. Late-game hitch: on a late 1.5.5 Henry save, `mp_shared_world on` as host,
   `mp_world_save` ×3 and `KCD2MP_Wo122HitchArm(8)` ×2 as baseline; read
   `MP-WORLDSAVE hitch`.
4. Load a C#-spliced file (`KcdMpClient --save-tool splice …`, copied into a
   playline before launch) and check the Henry as WO-115 §3 did.
