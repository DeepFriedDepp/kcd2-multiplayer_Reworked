# WO-90 progress

Read `docs/WO-90-findings.md` first — it carries the evidence. This file is
the state-of-play.

## Status

| Item | State |
|---|---|
| Phase 0 — master timeline | **Done.** Three log bundles aligned to wall clock, each offset anchored on an agent event and verified against a second independent anchor at the far end of the session (host: 0.02 s). The j1/j2 relationship corrected: they are not "before and after" — `j2/agent.prev.log` is the *same* agent process as `j1/agent.log`, running 80 s longer, and is the best record of the crash. |
| Phase 0 — the quest-objective signal | **New.** `questNameOverride` on every checkpoint save is a byte-identical cross-machine quest+objective key. Never used before in this project. It produced the first measurement of how far apart two players' stories were: the joiner went from behind, to **9m 24s ahead**, to 2.6 s apart, in one session. |
| Phase 1 — does quest state exist as a synced concept? | **Answered: no, in any form.** Zero hits for quest/objective/journal/chapter/cinematic/camera across Lua, C#, C++. Only a Rendered-cutscene *pause* detector and a read-only dialogue probe exist, and neither is story state. |
| Finding 1 — invisible prologue ghost | **Mechanism ESTABLISHED: the body had no character instance on slot 0.** Its animation probes resolved nothing, the engine printed `Combat actor init failed for actor 'kcd2mp_1'` 24 times against that one entity (the only body in the session that ever failed it), and it never once appears in an animation-queue overflow while the visible ghost appears 1,121 times. Both starting hypotheses refuted. The *cause* of the missing character is not established — a detector for it ships. The prompt's premise ("does ghost creation hardcode Henry?") is refuted outright. |
| Finding 2 — the crash | **Located precisely in time, cause not recoverable.** The game stopped writing `kcd.log` and stopped native sampling at ~20:44:10, inside level-load finalisation; the agent ran healthily for three more minutes with `[ping]` climbing 39 ms → 18.5 s. Partial fit to WO-58's hang shape, no identified trigger. Three concrete things named that would settle it next time. |
| Finding 3 — host pulled into the joiner's cutscene | **Root-caused and FIXED.** The engine's per-conversation `DialogTwin_*` stand-ins — including `DialogTwin_Dude`, which carries the conversation camera — were being tracked, claimed and puppeted as ordinary world NPCs by both machines. |
| Finding 4 — animation + helmet | **Both answered.** Jankiness is this project's already-flagged residual ghost-interpolation gap, now with numbers. The helmet is a 38m 28s story-beat gap, not an appearance-sync hole — though the NPC-appearance coverage hole is real and recorded separately. |
| Findings 5/6/8 — the core | **Root-caused and FIXED.** Not render jitter: a constant 57.24 m disagreement between two stable attractors, sustained 38 s, because the two players were at different beats and the claim layer has no notion of an NPC being in use by its own world's story. |
| Finding 7 — crouch flicker | **Maintainer's hypothesis REFUTED, and the real mechanism proved by the engine.** Zero `[CLAIM-CONTESTED]` lines all session. 554 animation-queue overflows on that NPC show this mod's standing clips and the quest brain's crouch clips queued onto one body until the 16-entry queue overflows. The puppet renderer's whole tag vocabulary is five values with no crouch. |
| Phase 3 — feasibility of the mutual-acceptance gate | **Verified against the retail binary, and it holds for exactly one class of beat.** No quest scriptbind exists on this build at all; no cutscene hold exists; there is no usable pre-roll. But `RestrictDialog` on the **beat NPC** (not the player) is a real gate for player-initiated conversation, and three engine-level levers may cover the rest. Designed, not built — every primitive is unverified and the failure mode hard-blocks both campaigns. |
| Phase 3 — what shipped instead | **Five changes** — three that address the damage rather than the beat timing, plus two correctness fixes the investigation turned up. See below. |
| Phase 4 — verification | **377 checks, 0 failures.** Synthetic + unit only. **Nothing here is live-verified** — no game process was reachable this session. |
| `VERSION` | **Unchanged**, per `docs/VERSIONING.md`. |

## What changed

| File | Change |
|---|---|
| `kdcmp/Data/Scripts/Startup/kdcmp.lua` | `mp_is_excluded_npc_name` + its use on all four NPC-sync paths; the divergence release in `KCD2MP_NpcPuppetTick`; `KCD2MP_SetNpcDiverge` + `mp_npc_diverge`; the `IsDialogRestricted` argument fix; the spawn-time `GetCharacterFileName(0)` read-back. |
| `dotnet/KcdMp.Protocol/Protocol.cs` | `NpcDialogTwinNamePrefix`, `IsNeverSyncedNpcName`; `0x37 StoryBeatUp` / `0x38 StoryBeatDown` + their spec, `MaxStoryBeatTextLen`, `StoryBeatKindObjective`. |
| `dotnet/KcdMp.Client/StoryBeat.cs` | New. Pure parse/display/compare functions. |
| `dotnet/KcdMp.Client/LogTailGameTransport.cs` | `StoryBeatDetected` event + `LastStoryMarker`, change-gated. |
| `dotnet/KcdMp.Client/GameBridge.cs` | Send/receive 0x37/0x38, per-peer objective, divergence toast, per-connection reset, new-peer announce. |
| `dotnet/KcdMp.Server/.../ClientHandler.cs` | Never-synced check moved to the top of `RouteNpcState`, ahead of the damage-authority branch. |
| `dotnet/KcdMp.Server/.../ClientSession.cs` | 0x37 dispatch, `EnqueueStoryBeat`, widened reject log text. |
| `dotnet/KcdMp.Server/.../TcpBroadcastService.cs` | `BroadcastStoryBeat`. |
| `tools/Test-WO90Synthetic.{ps1,lua}` | New, 70 checks. |
| `dotnet/KcdMp.Client.Tests/StoryBeatTests.cs` | New, 25 checks. |
| `docs/WO-90-findings.md`, this file | New. |

Not changed on purpose: `VERSION`, `kdcmp/Data/kdcmp.pak`, the native DLL, the
ghost interpolation path, `ProcessPauseMarkers`.

## The three shipped changes, in one line each

1. **Never sync what was never shareable.** `DialogTwin_*` and `kcd2mp_*` are
   refused on every path, on both clients and at the relay — including the
   damage authority's stream, which previously bypassed the name gate entirely.
2. **Stop fighting a world that disagrees.** When the local engine drags a
   puppeted NPC more than 8 m from our last write three times in 30 s, the
   receiver releases the puppet and stands off for 60 s. One-sided, no wire
   change, self-healing. `mp_npc_diverge off` restores the old behaviour.
3. **Tell the players.** The first quest-state wire format this project has
   had, carrying the engine's own objective key, so each client can name the
   divergence it is already reacting to.
4. **Fix a readback that never ran.** `soul:IsDialogRestricted()` was called
   with no argument where the engine expects the asker's entity id — a script
   error at every ghost spawn on all three machines, swallowed by its `pcall`,
   with the log still printing a verdict. It is also the primitive any future
   beat gate would stand on.
5. **Detect finding 1 at the moment it happens.** A ghost with no character
   instance now logs `SPAWN NO MODEL` at spawn instead of being reconstructible
   only afterwards from animation-probe failures.

## Why the gate as specified was not built

The maintainer's design — hold the beat for both players until both accept —
was verified against the retail binary before being accepted, and the answer
is narrower than the ask. There is **no quest scriptbind on this build at
all** (`C_ScriptBindQuest` and the whole `QuestSystem` table are 0-hit across
all four retail binaries), no cutscene hold, and no usable pre-roll — the
earliest cutscene marker is an adjacent log line carrying no identifier.

But it is not nothing. `soul:RestrictDialog` gates **being spoken to**, so
applied to the **beat NPC** on both machines it would genuinely stop both
players entering a conversation, and release atomically. That covers
player-initiated beats; three engine-level levers (`wh_dlg_Enable`,
`wh_dlg_RequestMaxDistance`, `ActionMapManager.EnableActionMap`) might cover
the quest-forced ones too.

It is designed here and not built, for one reason: every primitive it stands
on is unverified on this build, and the failure mode is the worst available —
a restriction that fails to lift leaves an NPC permanently un-talk-to-able and
hard-blocks both campaigns. The one piece of it this mod already used had a
malformed readback that went unnoticed across two work orders, and is fixed
here. Full evidence in findings §3.2.

The more important finding is that it would not have been the right fix even
if it were buildable. Beats firing independently is harmless on its own; the
damage came from the mod's own sync layer overwriting a world that was
legitimately using its NPC. That layer is entirely ours, and fixing it needs
no engine cooperation and no agreement between clients — which is what shipped.

An objective-marker *gate* was also considered and rejected on evidence: for
all but the last minute of the thirty-one during which one player held and
dragged the other's story NPCs, both clients' last-known objective was the
same string. Gating on it would have been silent through the incident.

## Deploy note

`kdcmp.lua` changed, so **`kdcmp.pak` must be rebuilt before any of the Lua
half is live** — editing the source does nothing to a running game until
`tools\Build-And-Install-Mod.ps1` repacks it and the game restarts. The pak is
deliberately not rebuilt in this commit, following WO-88/WO-89 precedent
(source change now, pak rebuilt at the release cut, with the version the
maintainer chooses).

Matched set as always: pak + agent + relay must all be deployed together. The
0x37/0x38 layer is additive — an older peer never sends it and ignores it on
receipt — so a mixed-version session degrades to "no story telemetry" rather
than breaking. The Lua exclusion's inbound half was written precisely for that
case: it refuses a stand-in stream from an older peer that still sends one.

## What needs a live two-player session

Everything in "what changed" is synthetic-verified only. In rough priority:

1. **The divergence release.** Does handing the NPC back actually look right to
   both players, and is 8 m / 3 hits / 30 s / 60 s the right shape? The
   thresholds are set from one session's numbers (ordinary contention
   0.05–0.6 m, the story divergence 57.24 m) and `mp_npc_diverge <metres>`
   exists so the field can retune without a rebuild.
2. **The `DialogTwin_` exclusion.** Confirm that conversations no longer yank
   either player's camera, and that nothing depended on those entities syncing.
3. **The story-beat toast.** Confirm the objective key parses live and that the
   toast is informative rather than noise.
4. **Finding 1** — the five-minute prologue check in findings §2.1.
5. **Finding 7's A/B** — `mp_npc_smooth off` during a crouch beat.
