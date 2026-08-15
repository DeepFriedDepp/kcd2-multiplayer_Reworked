# WO-32 — can NPCs actually be synchronized across players' worlds?

Investigated 2026-08-15 against the live KCD2 Modding Tools build, human at the
machine for the live phases. Evidence discipline as in WO-26/28/34: **observed /
read-but-unrendered / inconclusive**, never rounded up.

**Bottom line up front: yes — and by a much cheaper mechanism than the one the
WO budgeted for.** A real, hand-placed NPC needs **no AI suppression at all**:
a continuous 50 ms position stream wins against its AI completely (the same
finding WO-26 made for ghosts, reproduced on a real NPC), and stopping the
stream is a complete, clean release — the engine restores the NPC to its own
schedule by itself within ~3 s, dialogue intact, no crime/faction/reputation
contact. The mechanism was wired into real code this session: type bytes
`0x26`/`0x27`, host-authoritative via WO-28's existing Rule 2 role, behind an
off-by-default `mp_npc_sync` toggle, bounded to 5 NPCs within 30 m.

---

## Phase 0 — scope and the vetted test NPC

**Bound: `radius = 30 m` around the local player, `maxTracked = 5` NPCs.**
Reasoning: 30 m covers a street scene (the WO-34 test area's whole tavern
frontage fits inside it); 5 NPCs is the Phase 2 scale target and the shipped
cap is set to exactly what was measured, not beyond it.

**Test NPC: `ttkc_man_16`** (Troskovice), vetted before anything touched it:

| check | result | source |
|---|---|---|
| faction | `trosecko_settlements_troskovice_commonFolk_tavern` | `soul__ttkc.xml` |
| full faction ancestry | tavern → commonFolk → troskovice (`settlement`) → trosecko_settlements → trosecko → civilians — **no `publicEnemy`, no soldier labels anywhere** | `FactionTree.xml`, walked node by node |
| social class | 83 = `varlet` ("Hired hand" — same UIName family as WO-34's control) | `social_class.xml` |
| crime role | 1 = `civilian` (not soldier, not renegade) | `soul_crime_role.xml` |
| VIP class | 0 — ordinary, killable | `soul__ttkc.xml` |
| brain | `4b914d1c-…` = `npc_basic` | `brain.xml` |
| quest references | **none** — the GUID and name appear only in its own soul row, its inventory preset, and skald skill/stat rows | grep across the full extracted `Tables.pak` |

**Control NPC: `ttkc_man_10`** (musician, crime role civilian, same street,
~5 m from the test NPC), observed unmodified under the same conditions in the
same session — the WO-34 discipline, applied as required.

Guards (`ttkc_man_2`, `ttkc_man_5`, class 101 = guard/soldier role) were
identified in the same sweep and excluded.

---

## Phase 1 — the load-bearing question, answered live

All live evidence from one session, mod v0.11.6-dev pak, save loaded, human
present. The test NPC started seated at a tavern bench at
`2329.27, 2081.55, 110.48` (byte-identical across a 30 s / 10-sample baseline;
the control identically stationary at `2334.71, 2080.19, 110.50`).

### 1a — a single external position write does NOT hold

`SetWorldPos(+2 m)` on the real NPC: the write **lands** (immediate read-back
`2331.27` — engine-resolved position, not the call's return) and the engine
restores the NPC to its **byte-identical** anchor within 1.5 s (next sample:
`2329.27, 2081.55, 110.48`). One-shot writes are worthless for sync.

### 1b — a continuous 50 ms stream wins completely, with NO suppression

An InterpTick-shaped drive (SetWorldPos every 50 ms, target advancing
0.02 m/tick) moved the NPC 4 m over 10 s with the read-back position matching
the written target **in every sample** (9 samples logged, `rb == tx`
throughout). No AI suppression of any kind was active. This is the same result
WO-26 Phase 3 got on a fighting ghost (pinned byte-identical from full health
to death), now shown on a real scheduled NPC.

### 1c — release is automatic and clean

Stream stopped → the NPC was back at its byte-identical schedule anchor within
one 3 s sample and stayed there (10 samples). No restore code exists or is
needed: **"release" is simply "stop writing."**

### 1d — side effects checked, none found

- **Crime/reputation/faction:** after two drives, the test NPC's buff list was
  empty of everything except perks; the control's showed only its pre-existing
  `npc_drunkenness`; the player's showed no `crime_*` anything. No guard
  reaction, no `crime_interrupt_*`, nothing. (Contrast: WO-26 0a, where a
  single player-thrown punch immediately produced `crime_interrupt_confronting`
  — the machinery is demonstrably sensitive, and it stayed silent here.)
- **Dialogue:** human talked to the NPC normally after release — *"I can still
  talk to him."* Dialogue DURING a drive was not tested. Stated as untested.
- **Nearby NPCs:** *"Nobody reacted to him."* (human eyewitness, same drive).
- **Collision:** *"he phased through another NPC"* — SetWorldPos ignores
  collision, exactly as it does for ghosts. Inherent to the mechanism, not new.
- **The control** never moved (byte-identical before/after) and kept its
  ordinary state throughout.

### 1e — animation works the same as on ghosts

Without animation the NPC slides in the pose of its current activity —
observed: *"keeping his position static as if he was still sitting"* (he was
seated at a bench when the drive started). With
`StartAnimation(0, "3d_relaxed_walk_turn_strafe", …)` driven per tick —
exactly the ghost pattern — the human saw him **walking**. Stutter was visible
in both drives; attributed to the raw test harness writing absolute targets at
50 ms with no interpolation (the shipped ghost path lerps at 20 ms and looks
right); recorded as **read-but-unrendered** that the shipped interp smooths
this for a real NPC — the E2E drive below runs through the real interp path,
but nobody eyeballed it at speed this session.

### 1f — the suppression question the WO actually asked

The WO asked "can its own local AI be suppressed?" The live answer made the
question moot for position control — the stream wins with the AI fully awake —
so suppression was researched but deliberately not exercised:

- `AI.SetIgnorant(entityId, 0|1)` — **registered** in this build (`function`),
  documented as "ignore system signals, visual and sound stimuli." Untested.
  The obvious lever if a puppeted NPC's stimulus reactions (barks, alerts)
  ever need silencing.
- `Actor.SetAIBrainId(id)` — in the shipped scriptbind docs, and the brain
  table has plausible inert donors (`kcd1_npc_deadBody`, `so_dummyObject`) —
  but the binding is **not registered on this build** (`e.actor.SetAIBrainId`
  is nil on a live NPC). Same registered-vs-documented gap as
  `System.DrawTriStrip`. Do not plan around it.
- `GameRules.FreezeEntity` — documented (Crysis-era freeze+vapor semantics),
  not probed. Almost certainly the wrong tool even if live.

### 1g — the cheap alternative (synced-trigger divergence)

Not testable as designed with one machine — it needs two independent worlds
running the same NPC. What this session's data does say: an idle scheduled NPC
is **already naturally convergent** across worlds — it sits byte-stationary at
an authored anchor (1a/1c), and both installs share the same authored
schedule data. So for idle/routine NPCs, "do nothing" is already a weak form
of sync, and the streaming mechanism only needs to cover NPCs that are
actively diverging (combat, alerts, crowd reactions). That materially shrinks
the real bandwidth problem, but the divergence-rate question itself remains
**open, honestly** — it needs two real machines.

### Gate 1 — verdict

**Puppeting works, with real but non-blocking side effects** (collision
phasing; visual stutter pending the real interp path; dialogue-during-drive
untested). Per the WO's instruction, this was built for real in the same
session — next section.

---

## What was actually built

### Wire protocol (v6 unchanged — additive, same reasoning as WO-28)

```
C→S  0x26  NpcStateUp:   [nameLen:1][name:UTF-8][x:4f][y:4f][z:4f][rotZ:4f][health:4f][flags:1]
S→C  0x27  NpcStateDown: [sourceGhostId:1] + upstream body verbatim
                          flags bit 0: dead in the authority's world
```

- **Identity = authored entity name** (validated `[A-Za-z0-9_]+` at three
  layers: emitter, agent send, agent receive-before-Lua-interpolation — relay
  data must never reach a Lua string literal unchecked). Names are shipped
  level content, byte-identical per install, and are the only key Lua can
  resolve cheaply (`System.GetEntityByName`). Soul GUIDs would need a REST
  round trip per apply.
- **Authority = WO-28's Rule 2 holder** (`0x25 CombatRole`, lowest-id ready
  client). The relay **drops** an `NpcStateUp` from anyone else — enforced in
  `ClientSession` exactly where `PlayerHitUp`'s authority gate lives, and the
  emitting mod additionally gates on `KCD2MP.hitSensorOn` so a non-authority
  never sends. Verified live in Phase 2 of the E2E below.
- The receiver **never spawns**: a name not loaded in this world is ignored.
  This layer moves existing NPCs only.

### Mod (`kdcmp.lua`)

- **Emit side** (authority only, `mp_npc_sync on|off`, **off by default**):
  a 250 ms tick tracks the ≤5 nearest human NPCs within 30 m (rescan every
  2 s), excluding ghosts/horse-ghosts **by registry reference, not name** —
  `ApplyGhostName` renames ghost entities to player nicks (WO-26), so a name
  test would miss them. Emits `npc_state` on movement > 0.05 m, on a health
  change > 0.5, on death, or on a 2 s heartbeat.
- **Apply side** (`KCD2MP_ApplyNpcState`): puppets are driven by a 50 ms tick
  with the ghost interp's exact shape — lerp factor 0.5, teleport on > 5 m
  gaps, speed-derived animation with the ghost thresholds. A puppet whose
  stream goes silent for 3 s is **released** (entry dropped, engine takes the
  NPC back — the Phase 1c mechanism). WO-34's corpse rule is applied from
  birth: a puppet that is dead in either world (authority's flag OR local
  `actor:IsDead()`) gets no position writes and no animation.
- **Save-load resilience** (WO-13): both new chains carry liveness stamps;
  the agent re-arms the emit chain on the same cadence it re-arms the
  interp/emitter chains; the puppet chain self-restarts on the next packet.

### Agent / relay (`GameBridge.cs`, `ClientSession.cs`, `TcpBroadcastService.cs`)

`npc_state` event → validation → `0x26`; `0x27` → validation → batched
`KCD2MP_ApplyNpcState` call. Relay: authority check + broadcast-to-others,
verbatim-body convention, same as PlayerState.

---

## Phase 2 — E2E test and measured cost

`tools/Test-NpcSyncE2E.ps1` — synthetic peer against the real relay, real
agent, real game (the project's standard one-machine E2E shape). Three phases:
emit side (real NPCs streamed out match their engine positions), authority
guard (a non-authority `NpcStateUp` is dropped and moves nothing), apply side
(the peer becomes authority via an agent restart, drives the real `ttkc_man_16`
over the real wire, and the engine-resolved position is asserted to track,
release, and restore).

**Final run: 15/15 PASS** (after the harness fixes below), with the authority
drop additionally confirmed in the relay's own log
(`[!] 'wo32-npc-peer' sent NpcStateUp without holding world authority --
dropped.`) rather than only by the NPC not moving. The apply-side drive moved
the real `ttkc_man_16` from its anchor `2329.27, 2081.55` into the driven
region (>2.5 m east, tracking confirmed mid-drive), with exactly one puppet
active; 3 s after the stream stopped the puppet was released and the engine
returned the NPC to within 1.5 m of its anchor. Post-test read-back: 0
puppets, 0 ghost rows, NPC byte-identical at `2329.27, 2081.55, 110.48`,
hp 100.

Three harness/environment traps this session hit, recorded so nobody re-hits
them:

1. **A stale relay invalidates a wire test silently.** The first run went
   against the *old installed* relay (`AppData\Local\KCDMP\KcdMpServer.exe`),
   which skips unknown type bytes — no 0x27 ever, and an authority-guard
   "pass" that proved nothing. Check `Get-Process ... | Select Path` before
   trusting any wire test.
2. **Quiet-window Drain hangs while the player moves** — the Ghost stream
   never goes quiet. This script's Drain carries a hard cap; the older E2E
   scripts' Drains have the same latent issue.
3. **One unexplained anomaly, stated honestly:** in one intermediate run
   (old-relay chaos just swapped out, agent auto-reconnecting), a
   non-authority peer's NpcStateUp *was* applied — observed once, never
   reproduced across four later runs on the observable stack, where the drop
   fired every time. Working hypothesis: the agent's auto-reconnected session
   had not completed its handshake (`IsReady=false`), making the peer
   legitimately the lowest-id *ready* client — i.e. the relay behaved
   correctly against a half-joined session, not incorrectly. Not confirmed;
   that relay instance's console is gone. The enforcement point itself is
   verified (relay log warning, four consecutive runs).

### Measured transport cost

Measured from the live emitter (counted `npc_state` lines per enable window,
5 NPCs tracked, ordinary Troskovice street activity):

- **Observed: ~3.5–4 packets/s total** for 5 tracked NPCs (~46–48 emits per
  ~13 s window) — the change gate does most of the work, since idle NPCs cost
  only the 2 s heartbeat.
- **Worst case by construction: 20 packets/s** (5 NPCs × 4 Hz, all moving).
- Packet size at typical name length (11–13 chars): ~37 bytes framed →
  **~150 B/s observed, ~740 B/s worst case** per direction. For comparison
  the existing per-player position stream is up to 50 Hz × 20 B = 1,000 B/s:
  **a synced street scene costs less than one player's position stream.**

Extrapolation to "a full town" (~50 NPCs, cap and radius lifted — NOT built,
NOT measured): ~7.4 KB/s worst case per direction on the wire, which the TCP
relay would not notice. The realistic ceiling is not bandwidth but the
receiving side: each inbound packet becomes one batched `ExecuteString` call
(WO-30 measured that channel at ~60–130 ms warm RTT, amortised by batching),
and each puppet costs a `SetWorldPos` + `StartAnimation` every 50 ms inside
the game. At 5 puppets this is noise; at 50 it is unmeasured territory, and
the Phase 0 bound stays until someone measures it.

---

## Phase 3 — authority and the crime/reputation question

- **Host authority**: inherited from WO-26 §3 / WO-28 rather than re-decided —
  the relay's existing Rule 2 role is reused outright, so there is exactly one
  world authority per session and it moves automatically when the holder
  leaves. The known cost stands: NPC sync stops mattering when the authority's
  world is paused or unloaded.
- **Crime/reputation state stays per-machine.** Stated plainly as the
  simplification the WO allowed, not a full answer: position/behaviour of a
  synced NPC now follows the authority's world, but wanted status, witnesses,
  bounties and reputation remain each player's own (WO-34 §5.2's status quo).
  The seam this leaves: a guard puppet can be seen chasing the authority's
  criminal by a player in whose world no crime exists. That is a visual
  oddity, not state corruption — no penalty crosses machines. The full
  "whose crime state wins" question remains open and is WO-36's natural
  neighbour.
- **Shipped shape: off-by-default toggle (`mp_npc_sync`), bounded 5 NPCs/30 m.**
  The WO's final gate — ship on-by-default versus keep as a tested,
  toggleable feature — was put to the human at session end;
  their answer is recorded in WO-32-progress.md.

---

## What this closes and what it leaves open

**Closed:**
- Real NPCs can be puppeted from network data with no AI suppression, no
  side effects on crime/reputation/dialogue observed, and automatic clean
  release. (Live, observed, with a control.)
- `Actor.SetAIBrainId` is not registered on this build.
- The wire mechanism exists, host-authoritative, tested end to end.

**Open, stated honestly:**
- Dialogue *during* an active drive — untested.
- Visual quality of the shipped interp path on a real NPC at speed — the E2E
  asserts positions, not looks; needs an eyeball pass.
- Divergence rate of unsynced NPC copies across two real machines (1g) — needs
  two machines, same as every cross-machine claim since WO-28.
- Combat-state NPCs: everything here drove a scheduled civilian. A fighting
  NPC's position will obey the stream (WO-26 Phase 3 proved that much on a
  fighting ghost), but what its combat AI does about being teleported
  mid-swing was not observed.
- Scale beyond 5 NPCs / 30 m: deliberately not attempted (Phase 0 bound).
