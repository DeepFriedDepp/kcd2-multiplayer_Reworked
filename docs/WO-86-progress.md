# WO-86 progress

Read `docs/WO-86-findings.md` first -- it carries the evidence. This file is
the state-of-play.

## Status

| Item | State |
|---|---|
| Phase 0 -- does a death event exist on the wire? | **Answered from code**: 0x14/0x15 exist since WO-4 with relay route and receiver; **no sender ever** (`SendLocalDeathAsync` had zero callers; the DLL dropped its `died` bit at the frame edge). Death was inferred per machine from health deltas only. |
| Phase 0 -- claims vs HP | **Two separate systems**, code-verified: claims route 0x26 position streams; 0x30 damage has no authority gate; neither carries death. |
| Phase 1 -- instrumentation | **Shipped** on all four surfaces (mod `NPC-DEATH`, agent `[npcdeath]`/`[npcdmg]`, relay `[NPCDEATH]`, DLL frame). Once-per-transition, never per tick. |
| Phase 2 -- root cause | **Candidates 1 + 3**, code-verified: no death event + the DLL's remaining-hp clamp makes any peer divergence permanent; WO-38 body-follow (`1450ddb`) followed a living stream with a dead local body. Candidate 2 ruled out. |
| Phase 3 -- safeguard | **Landed in Lua**: body-follow requires the *stream's* dead/KO bit; a locally-dead body under an alive stream gets no writes and one DIVERGENCE line. |
| Phase 3 -- real fix | **Landed, protocol addition**: `NpcDamageFlagFatal = 0x02` on 0x30/0x31, no `Protocol.Version` bump (additive, justified in `Protocol.cs`). Two FATAL sources (DLL `died` byte; Lua observer on witnessed alive->dead). Receiver applies `ApplyDeath` via the DLL, deduped, echo-closed. `mp_npc_deathsync on|off`, default on. |
| Phase 4 -- synthetic | **47/47** new (`Test-WO86Synthetic.ps1`); 72/72, 48/48, 35/35 regressions. `dotnet build` 0 errors. Native DLL built (327,680 bytes). |
| Phase 4 -- live | **Not done** -- no running game this session. |
| Pak / `VERSION` | **Untouched** -- maintainer's call. Lua is inert in the field until the pak is rebuilt; the new DLL is built but not deployed. |

## What changed

| File | Change |
|---|---|
| `dotnet/KcdMp.Protocol/Protocol.cs` | `NpcDamageFlagFatal = 0x02`; 0x30 block documents the flag, why not 0x14, why no version bump. |
| `native/KCDMP/pipe_server.cpp`, `pipe_server.h` | `LocalHit` frame gains trailing `[died:1]` (25 bytes); header doc corrected (0x90 was documented as "not yet emitted"). |
| `dotnet/KcdMp.Client/CombatPipe.cs` | `OnLocalHit` gains `bool died`; reads byte 24 when present; logs a FATAL frame. |
| `dotnet/KcdMp.Client/GameBridge.cs` | outbound: fatal hits bypass the noise filter, set the FATAL bit, mark the mod (`KCD2MP_NpcDeathAnnounced`), 0x14 fallback when the name lookup fails; `npc_death` and `npc_deathsync` event cases; inbound 0x31 logs every event and applies FATAL; inbound 0x27 tracks dead-bit transitions and applies a witnessed one; `ApplyRemoteNpcDeathAsync` (dedupe, Lua-first mark, `ApplyDeath`); per-connection reset. |
| `dotnet/KcdMp.Server/.../ClientSession.cs` | one `[NPCDEATH] relayed FATAL` log line on the unchanged 0x30 pass-through. |
| `kdcmp/Data/Scripts/Startup/kdcmp.lua` | WO-86 block: toggle + state tables, `mp_npc_death_observe`, `KCD2MP_NpcRemoteDeath`, `KCD2MP_NpcDeathAnnounced`, `KCD2MP_SetNpcDeathSync`; observer calls in emitter / drag sensor / puppet tick; puppet-tick safeguard + 10 s peer-declared hold; inbound/outbound dead-bit logs; cadence line counter; `mp_npc_deathsync` console command. |
| `tools/Test-WO86Synthetic.lua`, `.ps1` | new synthetic suite, 7 scenarios. |
| `docs/WO-86-findings.md`, `docs/WO-86-progress.md` | this WO. |

## Next session (live)

1. Deploy the matched set (pak rebuilt, agent, DLL) on both machines.
2. Kill a villager with player A while B watches; then the reverse.
3. Read on the killer: `[npcdeath] DLL reports a FATAL local hit` (or the
   `NPC-DEATH .. announcing` line if the DLL missed it), `[combat] sent hit ..
   FATAL`. On the relay: `[NPCDEATH] relayed FATAL`. On the watcher:
   `[npcdmg] in: .. FATAL -> ..`, `NPC-DEATH <n>: peer says dead ..`,
   `[npcdeath] in: .. -> ApplyDeath applied`, and whether the NPC visibly
   drops. On the killer afterwards: no `NPC-DEATH DIVERGENCE` line should be
   needed (the peer's copy is now dead too) -- if one appears, the death did
   not land on the peer and the line says which side disagreed.
4. `mp_npc_deathsync off` on both, repeat once, to see the pre-WO-86 shape
   with the new logging in place.
