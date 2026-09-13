# WO-88 progress

Read `docs/WO-88-findings.md` first -- it carries the evidence. This file is
the state-of-play.

## Status

| Item | State |
|---|---|
| Phase 0 -- logs read before theory | **Done**, both machines + relay. Death/reload timeline pinned to `kcd.log` line numbers and agent timestamps (findings §0.1). |
| Phase 0 -- shared root cause for 1/2/4? | **No.** Same trigger (death → reload), three separate defects in three layers (§0.6, confirmed by code §1.5). |
| Finding 1 -- ghost death-state | **Reported symptom not reproduced** in the logs: 11/11 death tags cleared, locomotion resumed each time. **Inverse defect fixed**: the dying tick's own `health=0` vitals cleared the tag within ms (2/6 joiner deaths). Clear now requires `health > 0`. |
| Finding 2 -- appearance | **Root cause + fix**: per-ghost applied/known sets outlived the respawned body; the `ghostid` respawn edge now resets them and re-applies the peer's last outfit. Field timing matches on both machines. |
| Finding 3 -- dialogue jitter | **WO-80 premise refuted on evidence**: a 48 s real dialogue suspended nothing (DATA + NPC emitter continuous). Pump NOT extended. Live `IsInDialog` probe shipped as `mp_probe_dialog` (read-only). Actual mechanism (heartbeat-only stream from stationary authority NPCs vs the watcher's puppet) named and handed to the WO-63/WO-64 work (§2.3). |
| Finding 4 -- world time | **Two root causes + fixes**: (a) lost one-shot convergence at host reload #5 (REST outage swallowed the batch; 15,808 game-s) -- convergence now outstanding-until-proven with re-send; (b) stale private "session clock" -- periodic 60 s quiet announce, receivers skip reports within natural skew. |
| Phase 4 -- synthetic | 21/21 new xunit (`KcdMp.Client.Tests`); Lua regressions 47/47, 72/72, 48/48, 35/35; build 0 errors. |
| Phase 4 -- live | **Not run** -- no game this session (ports 1403/4600 closed). |
| `VERSION` / pak / DLL | **Untouched.** Agent change ships with the next agent build; the Lua probe is inert until the pak is rebuilt. |

## What changed

| File | Change |
|---|---|
| `dotnet/KcdMp.Client/ReloadReconcile.cs` | new -- the four decisions as pure functions |
| `dotnet/KcdMp.Client/GameBridge.cs` | vitals-gated death clear; `_ghostLastAppearance` + respawn re-dress on `ghostid`; outstanding reload convergence with re-send/expiry; periodic quiet clock announce; skew gate on quiet applies; per-connection resets |
| `kdcmp/Data/Scripts/Startup/kdcmp.lua` | `KCD2MP_ProbeDialog` + `mp_probe_dialog` |
| `dotnet/KcdMp.Client.Tests/*` | new xunit project, added to `KCD2-MP.sln` |
| `docs/WO-88-findings.md`, this file | evidence + state |

## Deploy note

Matched set is **agent only** for the fixes (`KcdMpClient.exe` from
`KcdMp.Client`); no protocol, relay or DLL change. The pak rebuild is only
needed for `mp_probe_dialog`. Both peers need the new agent for the periodic
clock announce to converge the session (an old peer still announces at
connect and applies forward-only, so mixed versions degrade to today's
behaviour, not worse).

## For the next field/live session

1. Die and reload with a peer connected. On the peer: `GHOST_DEATH dead=true`
   must stay up until your first `[vitals] sent health=100` (never cleared
   by the `health=0` line); `[appearance] ghost N: body respawned … re-applying`
   must appear on YOUR machine after your reload, followed by `+K -10`
   (K = peer's item count); your agent must log `reload: converged (clock …)`
   within ~10–20 s of `converging forward`, or `re-sending the convergence`
   lines until it does.
2. Watch a peer's clock: `[timeskip] <peer> -> worldTime=… (quiet) within
   skew … not applied` about once a minute while in sync; a real apply only
   after someone reloads or skips.
3. Run `mp_probe_dialog` outside a conversation, then inside one. Record
   the four `type=` / `ok=` / `val=` lines. Also confirm the DATA stream keeps
   flowing during the conversation (it did in these logs); if it ever stops
   on some build, WO-80's aggregate gets a dialogue term -- not before.
4. If jitter around a player in dialogue is seen again, note WHICH NPC and
   check its `NPC-SYNC packet cadence` on the watcher: heartbeat-only
   (~2000 ms mean) means the authority's copy is standing still and the
   puppet is being pinned -- WO-63/64 territory.
