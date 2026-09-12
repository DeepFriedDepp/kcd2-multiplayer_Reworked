# WO-86 — NPC death/kill state does not sync

Build under investigation: **0.20.9** (`main` at `a983fd7`). No live session
this WO; one field report (two players, a villager killed by one, alive and
walking for the other, the corpse then moving on the killer's screen) and the
observation that the one available session log carried nothing about NPC
death at all (5 `CombatViz`, 1 `HIT`, 1 `DeathAnim`, 1 `CombatIdleAnim`).

Evidence discipline: **observed** (read in a log or seen live),
**code-verified** (read in the source), **read-but-unrendered**,
**inconclusive**. Nothing is rounded up. Everything below Phase 0 is
code-verified unless marked otherwise; nothing in this WO was observed live.

---

## 0. Verdict in one paragraph

NPC death was **never on the wire**. A death packet (0x14/0x15) has existed
since WO-4 with a relay route and a receiver, and **no client has ever sent
one**: the DLL computes a `died` bit per soul and drops it at the pipe frame
edge, and the agent's `SendLocalDeathAsync` had zero callers. So every world
decided "is this NPC dead" alone, from health deltas -- and the DLL reports a
killing blow as the hp the victim had *left*, so any peer copy holding more hp
survives that blow forever, with nothing to reconcile it. That is the field
report's "alive, hurt, walking". The moving corpse is a second, independent
defect in the receiver: WO-38's body-follow branch let a *locally* dead body
follow any stream move over 0.5 m without asking whether the *stream* thought
the body was dead, so a living NPC walking in the peer's world teleported the
killer's corpse along its path. The claim/authority system (WO-60/66) has no
relationship to either: claims route position streams; damage has no
authority gate; neither carries or arbitrates death.

---

## 1. Phase 0 — what exists (code-verified)

### 1.1 Does a distinct "this NPC died" event exist on the wire?

**Yes as an opcode, no as a behaviour.**

| Piece | State | Where |
|---|---|---|
| `DeathUp` 0x14 / `DeathDown` 0x15, guid-addressed | defined since WO-4, with the explicit rationale "two clients computing dead from slightly divergent health eventually disagree, and that disagreement does not self-correct" | `Protocol.cs` header, 0x14 block and the 0x23 block that cites it |
| Relay route for 0x14 | present: `BroadcastDeath` to all others | `ClientSession.cs` DeathUp branch, `TcpBroadcastService.BroadcastDeath` |
| Receiver for 0x15 | present: `_combat.ApplyDeathAsync` → DLL `apply_death` (idempotent; `IsDead` read then lethal `TakeDamage(100000)`) | `GameBridge.cs` DeathDown branch, `rttr_abi.cpp apply_death` |
| Sender for 0x14 | **`SendLocalDeathAsync` has no caller** | `grep -rn SendLocalDeathAsync dotnet` → definition only |
| DLL death detection | present: `sample_health` computes `died = hp <= 0 && !t.dead`, once per soul, and logs `LocalHit ... (fatal)` | `rttr_abi.cpp` ~1686 |
| DLL → agent frame | **drops `died`**: `send_local_hit(guid, health_delta, died)` writes guid + stamina + health, 24 bytes, nothing else; `pipe_server.h` still documented 0x90 as "not yet emitted" | `pipe_server.cpp send_local_hit` |
| Agent LocalHit handler | reads 24 bytes; no notion of death | `CombatPipe.cs ReadLoopAsync`, `GameBridge.cs OnLocalHit` |

So on the wire, death for NPCs was only ever *inferable*: from cumulative
0x31/0x13 damage applied to each world's own copy, and from the 0x26 dead flag
(below), which is presentation-only.

### 1.2 The 0x26 dead flag (bit 0) is presentation, not state

`KCD2MP_NpcSyncTick` reads `e.actor:IsDead()` on each tracked NPC and sets
flag bit 0 (WO-32). `KCD2MP_ApplyNpcState` stores it as `p.dead`.
`KCD2MP_NpcPuppetTick` uses `p.dead` only to stop lerping (and to allow
body-follow). Nothing on the receiving side kills the local copy; the NPC
keeps living under its own brain. The 0x26 `hp` field is stored (`p.hp`) and
never written anywhere -- the WO-75 §7.1 item, confirmed unchanged.

### 1.3 Damage paths and their failure modes

* Outbound: DLL `sample_health` (60 ms cadence, 64 souls within 60 m, rescan
  every 3 s) → `LocalHit` → agent → 0x30 name-addressed (0x12 guid fallback
  when the name lookup fails). Agent drops hits under 0.5 hp *and* 0.5
  stamina (WO-58).
* Inbound: 0x31 → `ResolveLocalSoulGuidAsync` (REST by name, cached) →
  `_combat.ApplyDamageAsync` → DLL `TakeDamage(stamina, health)`; the DLL
  credits the applied amount so its own sampler does not echo it. Failure
  ("no local soul answers to that name") was logged; success was not.
* **The clamp.** `drop = t.health - hp` is bounded by the victim's remaining
  hp. A 60-damage blow on a 3 hp NPC reports 3.0. A peer whose copy has 20 hp
  receives 3.0, survives at 17, and no later packet can ever fix that: the
  killer's copy is dead, so it takes no more hits and reports nothing more.
  Any prior divergence in the peer's favour (a dropped chip, a failed 0x31
  apply, a fight the peer's NPC had locally, a different save) is therefore
  permanent. This is the mechanism behind "stayed alive, hurt" --
  code-verified; the specific divergence in the field is **inconclusive**
  (no logs exist).

### 1.4 Claims vs combat: two separate systems

`RouteNpcState` (WO-60/66) decides which sender's 0x26 stream is forwarded
per entity. 0x30 is broadcast with "no authority gate -- like 0x12, any client
reports damage it observed locally" (`ClientSession.cs`). Holding a claim
confers nothing about HP or alive/dead; the damage authority (`CombatRole`
0x25, `hitSensorOn`) gates *player*-hit reporting and the default NPC stream,
not NPC damage. They do not talk to each other, and did not need to for this
WO: death is name-addressed fact like damage, so it rides the damage layer.

---

## 2. Phase 2 — which candidate the code supports

**Candidates 1 and 3 together; not 2.**

* **Candidate 1 (no death event; independent local resolution) -- confirmed,
  code-verified.** §1.1 and §1.3. The WO-4 authors predicted exactly this and
  built 0x14 for it; the sender was never wired.
* **Candidate 3 (puppet system indifferent to death, corpse dragged by a
  living stream) -- confirmed with a correction, code-verified.** The
  receiver is not indifferent; it has a dead branch (WO-32 freeze, WO-38
  body-follow). The defect is that the branch fires on `p.dead or p.ko or
  locallyDead or locallyKo` and then follows the stream target whenever it
  moves >0.5 m from the last placement -- meant for the authority dragging a
  corpse, but never conditioned on the stream's *own* dead/KO bits. With the
  killer's copy dead and the peer's copy alive and walking (flags 0), every
  0.5 m of the peer's NPC walk became a `SetWorldPos` on the killer's corpse
  ("NPC-SYNC body follow" would have logged each step -- that line was never
  looked for in the field log and the symptom was reported by eye).
  Introduced in `1450ddb` (WO-38 Phase 6). The synthetic test reproduces it
  with the toggle off (scenario f) and shows the fix with it on (a).
* **Candidate 2 (death sent but not for non-claim-holders) -- ruled out.**
  Nothing sends death regardless of claim state (§1.1).

Which player streamed the NPC in the field report is unknown. Both
topologies produce the report: if the *peer* streamed it, the killer's copy
was a puppet (excluded from the killer's emitter by `mp_npc_rescan`, so the
killer emitted no dead bit at all) and body-follow dragged the corpse; if the
*killer* streamed it, the peer received dead bit 0 → froze its writes, and
its NPC walked on under its own brain, un-killed. Either way the peer's copy
survived because only the clamped delta crossed.

---

## 3. Phase 1 — instrumentation shipped

All lines are once-per-transition or once-per-body; nothing per tick.

**Mod (`kcd.log`, prefix `[KCD2-MP] NPC-DEATH`)**

| Moment | Line |
|---|---|
| outbound dead bit first set on a tracked NPC | `NPC-DEATH <n> outbound dead bit set on npc_state|npc_claim (hp=.. flags=..)` |
| a world NPC read dead for the first time this session | `NPC-DEATH <n> first seen already dead (by emitter|drag|puppet) -- not announced` |
| witnessed alive→dead, announced | `NPC-DEATH <n> died here (by <reader>, hp=..) -- witnessed alive->dead, announcing (npc_death)` |
| witnessed alive→dead, not announced | `... -- applied from a peer via <route>` / `-- already announced by dll` / `-- mp_npc_deathsync off, NOT announced` |
| dead body reads alive again | `NPC-DEATH <n> reads ALIVE again (by ..) -- was dead; reload? clearing its death marks` |
| inbound 0x27 dead bit against local state | `NPC-DEATH <n> inbound stream says DEAD (stream hp=..) -- witnessed alive->dead on this stream | dead on its first packet here (late join / save state): freeze only; local copy IsDead=.. hp=..` |
| peer's death arriving, before the DLL apply | `NPC-DEATH <n>: peer says dead (via ..); local copy loaded|NOT LOADED, IsDead=.. hp=.., puppet=yes|no` |
| **the corpse-drag moment** | `NPC-DEATH DIVERGENCE <n>: local copy is DEAD|KO|peer-declared dead but the inbound stream says ALIVE (stream hp=..) -- corpse writes suppressed` |
| running total | the existing 5 s `NPC-SYNC packet cadence` line gains `corpse writes suppressed=N` |

**Agent (`agent.log`)**

| Moment | Line |
|---|---|
| DLL fatal bit arrives | `[npcdeath] DLL reports a FATAL local hit on <guid> (hp -..)` |
| outbound fatal | `[npcdeath] out: local kill of <guid> ... -- sending FATAL`; `[combat] sent hit .. on '<n>' (..) FATAL`; `[npcdeath] out: mod observed '<n>' die locally (hp=.., seen by ..) -- sending FATAL`; `[npcdeath] out: 0x14 guid-addressed death ...` (name lookup failed) |
| every inbound 0x31 | `[npcdmg] in: ghost <id> hit '<n>' hp -.. st -.. [FATAL] -> applied | no local soul answers to that name | no delta to apply | pipe apply FAILED` |
| inbound 0x27 dead transitions | `[npcdeath] in: 0x27 from ghost <id> says '<n>' is dead (hp=..) -- witnessed transition, killing the local copy | dead on its first packet here ...: freeze only`; `... is ALIVE again ...` |
| inbound death apply | `[npcdeath] in: '<n>' via <route> from ghost <id> -> ApplyDeath applied (or already dead here) | FAILED ...`; dedupe and toggle-off variants |

**Relay (`relay*.log`)**: `[NPCDEATH] relayed FATAL npc=.. from='..' (id=..) blowHp=..`.

**Native (`kcdmp-native.log`)**: unchanged -- `PIPE: LocalHit .. (fatal)` and
`PIPE: ApplyDeath -> dead|soul not loaded / failed` already existed.

---

## 4. Phase 3 — the fix

### 4.1 Safeguard (Lua, `KCD2MP_NpcPuppetTick`)

Body-follow now requires the **stream** to say dead/KO. A body that is
dead/KO only locally (or peer-declared dead with the DLL apply in flight,
held 10 s) gets no writes and logs the DIVERGENCE line once. Body-follow for
a stream-dead body (the WO-38 case) is unchanged -- scenario (b) proves the
placement still happens.

### 4.2 Death on the wire -- a protocol addition, justified

**`NpcDamageFlagFatal = 0x02`** on 0x30/0x31 (`Protocol.cs`). Chosen over
re-wiring 0x14 because 0x14 is guid-addressed and per-save guids are unstable
across installs (WO-40: 571/571 unresolvable); death is a fact about a
*named* NPC exactly like the damage that caused it. **`Protocol.Version` is
not bumped**: additive -- a pre-WO-86 receiver applies the carried damage and
ignores the bit, a pre-WO-86 sender never sets it (same reasoning as the
WO-28 layer's note). Relay: body forwarded verbatim, one log line. Both
client sides updated; the guid-addressed 0x14 is now also sent as the
fallback when the name lookup fails (its first caller ever).

**Sources of a FATAL (either suffices):**

1. **DLL** -- `send_local_hit` now appends `[died:1]` (25-byte frame; the
   agent reads it when present, so old/new DLL × old/new agent all
   interoperate). A fatal hit bypasses the 0.5 hp noise filter and goes out
   as 0x30 with the FATAL bit *and* the blow's delta; the agent then tells
   the mod (`KCD2MP_NpcDeathAnnounced`) so the Lua observer stays quiet.
2. **Lua observer** -- `mp_npc_death_observe(name, dead, hp, src)` is fed by
   the three places this file already read `actor:IsDead()` for world NPCs:
   the emitter (tracked NPCs), the drag sensor (bodies within 6 m) and the
   puppet tick (**the one that covers the killer whose copy was a puppet**,
   which the DLL's radius/attribution can miss). A *witnessed* alive→dead
   transition emits `npc_death <name> <hp> <src>` once; the agent sends a
   zero-delta 0x30 FATAL. First-seen-dead is never announced (no transition;
   a stranger's savegame must not kill a living NPC).

**Receiver (agent `ApplyRemoteNpcDeathAsync`)**, reached from a 0x31 FATAL or
from a *witnessed* 0x27 dead transition (first-packet-dead only freezes, as
before): dedupe per name (60 s), tell the mod first (`KCD2MP_NpcRemoteDeath`
via `ExecuteNowAsync`: logs local state, marks the death remote, flags the
puppet dead), then `ApplyDeath` through the DLL. Echo is closed twice: the
DLL credits the lethal `TakeDamage` so its sampler reports nothing, and the
remote mark keeps the observer silent when `IsDead` flips.

**Toggle**: `mp_npc_deathsync on|off`, default **on** (WO-78 precedent). Off
restores the pre-WO-86 puppet branch verbatim, stops announcing, and (mirrored
to the agent by the `npc_deathsync` event) stops applying. Live A/B in one
command.

---

## 5. Phase 4 — verification

| Check | Result |
|---|---|
| `tools/Test-WO86Synthetic.ps1` (new, 7 scenarios) | **47 passed, 0 failed** |
| `tools/Test-WO84Synthetic.ps1` | 72 passed, 0 failed |
| `tools/Test-NpcSmoothSynthetic.ps1` | 48 passed, 0 failed |
| `tools/Test-GhostInterpSynthetic.ps1` | 35 passed, 0 failed |
| `dotnet build KCD2-MP.sln -c Release` | 0 errors (2 pre-existing nullable warnings) |
| `native/Build-Native.ps1 -Config Release` | built; `native/build/KCDMP/KCDMP.dll` 327,680 bytes |
| Live game | **not available this session** -- not run |

Scenario (f) is the pre-WO-86 behaviour reproduced under the same harness:
with the toggle off, a locally-dead body follows an alive stream 5 m in one
write. With it on, scenario (a) writes nothing across eight walking packets.

### 5.1 What remains unverified (honestly)

* **That `actor:IsDead()` flips for a *killed world NPC* in the live game.**
  It is the read WO-32/38/39 already relied on for the dead/KO bits and the
  drag sensor; the KO analogue was observed to work (WO-38 Section G). A
  dead=true reading for a world NPC has never been seen in a log --
  **read-but-unrendered**. If it never flips, the Lua observer is silent and
  only the DLL's FATAL bit carries the death (which needs the new DLL
  deployed).
* **That `ApplyDeath` on the receiving machine produces a proper corpse**
  (ragdoll, lootable). Lethal `TakeDamage` was verified for NPC health writes
  in the RTTR work; a peer-triggered NPC death has never been watched.
* **That the receiver's copy actually dies when it is a puppet mid-walk**
  (the body is frozen by `p.dead` from the killer's stream while the DLL
  kills it; the two should compose).
* **The human-observed experience** -- both players seeing the same death at
  roughly the same moment -- versus what the logs can confirm. This WO fixes
  what the code proves; a live session with two machines reading the new
  `NPC-DEATH` / `[npcdeath]` lines is the next step, and the lines are now
  there to read.
* The relay pass-through of a FATAL 0x30 is unchanged code; it was not
  exercised by a synthetic peer this session.

### 5.2 Deployment note

Three artefacts change behaviour and must ship as a matched set for the full
fix: the pak (Lua), `KcdMpClient.exe` (agent) and `KCDMP.dll` (native). Any
subset degrades gracefully by construction (§4.2), but only the full set
gives both FATAL sources. The pak is **not** rebuilt and `VERSION` is
**untouched** -- the maintainer's call (docs/VERSIONING.md). The new DLL was
built here but not deployed (this shell cannot deploy it).
