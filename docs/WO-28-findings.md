# WO-28 — shared combat: player health, NPC hits, and death

Built and investigated 2026-08-07 against the live KCD2 Modding Tools build,
save `playline2`, human at the machine throughout. Evidence discipline as in
WO-11/13/26/27: **observed / read-but-unrendered / inconclusive**, never
rounded up.

Implements `docs/WO-26-shared-combat-design.md`. Where this deviates from that
document, the deviation is stated and argued rather than left to be discovered.

**Bottom line up front: Phase 0 was not groundwork, it was the most valuable
part of the session.** It found that a mid-session save reload leaves the relay
connection and the mod's Lua globals completely intact — and *also* that it
permanently kills the player's outbound emitter and destroys every ghost body
while the mod's bookkeeping still claims they exist. Both had been live in the
shipped build since WO-13 and neither was known. Flow C is built on the
measured behaviour plus fixes for both, not on an assumption.

---

## Phase 0 — what a save reload actually does

**Method.** `tools/Test-ReloadBehaviour.ps1` (new). One synthetic peer against
the real relay and the real agent, walking a 4 m circle at 10 Hz so "the ghost
froze" cannot be confused with "the peer stopped walking" (the trick
`Bot-WalkingGhost.ps1` established in WO-13). It records a 1 s-resolution
timeline of four independent things while the human reloads a save by hand from
the game's own menu:

- Ghost (`0x02`) packets arriving for the human's ghost id, and any Disconnect
  (`0x06`) for it — the relay only broadcasts that when an agent's socket
  actually drops, so it is a direct answer to "did the connection survive".
- `KCD2MP.ghosts` count.
- All three tick heartbeats (`_interpAliveAt` / `_emitAliveAt` /
  `_labelAliveAt`) **and** their `*Running` flags — the exact pair WO-13 found
  disagreeing.
- Whether the peer's own ghost entity `kcd2mp_<id>` is still standing, read
  **from the world by spawn name**, not from `KCD2MP.ghosts` agreeing with
  itself.

260 s window, reload at t≈63. Full timeline archived as the run's CSV.

### Q1 — does the reloading player's agent stay connected? **Yes.**

The peer's only wire event in the whole window:

```
t=0.1 NAME id=11 'M31'  <- a peer (re)joined the relay
```

No `DISCONNECT` for id 11 at any point across 259 s spanning the reload. The
agent's TCP connection to the relay survives a save load untouched; no
reconnect happens and none is needed. **Observed.**

### Q2 — does the mod's Lua state survive? **The globals do. The timer chains do not.**

`KCD2MP.ghosts` read exactly `1` in every sample before, during and after the
reload. A re-run of `kdcmp.lua`'s startup assigns `KCD2MP = {}` and would have
reset that table to empty, so the mod's Lua state was **not** torn down and
rebuilt. `MOD INIT` occurrences in the log tail also went 0 → 0 across the
window, which agrees; the ghosts count is the stronger of the two, since the
log-tail window is a bounded read and its absence alone would not prove much.

The timer chains are a different story:

```
t      interpAge  emitAge  labelAge  running   myGhostEnt
62.9   0.83       0.83     0.82      111       1
64.2   2.18       2.18     2.17      111       1
65.6   ?          ?        ?         ?         ?          LUA CALL FAILED (loading)
72.0   11.31      11.31    11.30     111       0
77.6   15.54      15.54    15.53     111       0
79.1   0.01       17.06    0.01      111       0     <- interp+label recover
115.1  0.04       53.08    0.04      111       0
259.1  0.04       197.05   0.04      111       0     <- emitter never recovers
```

Read plainly:

- **All three chains die at the reload while all three `*Running` flags stay
  `1`.** WO-13's finding reproduced exactly, five work orders later.
- **Interp and label self-heal after ~17 s**, which is WO-13's fix working:
  the agent re-arms `KCD2MP_StartInterp()` every 250 ticks and the liveness
  check lets it restart over a dead chain.
- **The emitter never self-heals.** `emitAge` climbs monotonically to 197 s and
  was still climbing when the window ended.

### Q3 — what does the other player see? **Two independent failures.**

**The reloading player goes silent, permanently.** Zero Ghost packets arrived
for id 11 in the 197 s after the reload. This follows directly from the dead
emitter: it is that client's only outbound channel, so with it dead the agent
has nothing to send and the player simply stops existing for every peer.

**The reloading player's own view of everyone else loses its bodies but keeps
its labels.** `myGhostEnt` read `0` continuously from t=72 to t=259 — 187 s —
while `KCD2MP.ghosts` still read `1`. The human, watching, at the time:

> *"the ghost is invisible for me but I can see its nametag continuing in the
> same path"*

Instrument and eyewitness agree, and together they identify the mechanism
precisely: `istate` keeps taking position packets and `KCD2MP_InterpTick` keeps
writing `labelCache` from it, with no body under the label.

### Q4 — root causes, and the fixes

**Bug 1 — the emitter is never re-armed after a save load.**
WO-13 fixed half of this and the half it fixed hid the other half.
`KCD2MP_StartEmitter` got the same liveness check as `KCD2MP_StartInterp`, so
it *can* restart over a dead chain — but nothing ever calls it again.
`GameBridge`'s periodic re-arm sent only `KCD2MP_StartInterp()`, and
`LogTailGameTransport._emitterStarted` latches `true` on first success so
`StartAsync` never re-issues it either. Ghosts visibly recovering after a
reload made the whole thing look fixed.

*Fix:* the periodic re-arm now sends `KCD2MP_StartEmitter(<interval>)`
alongside `KCD2MP_StartInterp()`. Both are idempotent and liveness-checked, so
the added cost is a stamp comparison on a 250-tick cadence.

**Bug 2 — a save load destroys ghost entities while the mod keeps a stale
reference to them.** `KCD2MP.ghosts[id].entity` is a Lua value; nothing about
the world unload reaches in and clears it. So it stays non-nil, and
`KCD2MP_UpdateGhost`'s own respawn test (`if not ghost or not ghost.entity`)
reads "present" forever.

*Fix:* `KCD2MP_ReconcileGhosts()` (new) looks each ghost up in the world **by
spawn name** — never the display name, which WO-26 established is not a key
anything resolves by — and drops the bookkeeping for any whose entity is gone,
so the very next position packet respawns it through the ordinary path. It
deliberately does *not* call `KCD2MP_RemoveGhost`: there is no entity left to
remove, and the display name and menu/health/death tags are all still correct
for that player. The world lookup is too expensive for the 20 ms interp path,
so the agent drives it on a 500-tick cadence, the same shape as WO-13's
re-arm.

**Bug 3 — per-ghost WO-28 state outliving a ghost id.** Relay ids are
reassigned per connection. A leftover sampler baseline would read as an
enormous first delta against the next occupant of that id and fire a fake hit.
Cleared in `KCD2MP_RemoveGhost` alongside the existing `ghostInMenu` cleanup,
and in `KCD2MP_ReconcileGhosts`.

### Gate 0 — result

**Passed, and it changed Flow C's shape.** The prompt posed the outcome as
either "send a death packet, let the game's own reload happen, done" or "send a
death packet, then also do X." It is firmly the second: the connection and the
mod's globals need nothing, but without the two fixes above a player who dies
and reloads **never transmits again for the rest of the session**, which would
make a death notice actively worse than none — peers would be told someone died
and then watch them never come back.

---

## Wire protocol

Seven new type bytes. `0x1F`–`0x24` are the design document's own numbering,
confirmed still free by reading `Protocol.cs` rather than trusting the design
doc (`docs/PROJECT-STATE.md` §3 still said `0x1C`, which is stale — it predates
`0x1C`–`0x1E`).

| Type | Dir | Name | Payload | Len |
|---|---|---|---|---|
| `0x1F` | C→S | PlayerStateUp | `[health:4f][stamina:4f][flags:1]` | 9 |
| `0x20` | S→C | PlayerStateDown | `[ghostId:1][health:4f][stamina:4f][flags:1]` | 10 |
| `0x21` | C→S | PlayerHitUp | `[targetGhostId:1][health:4f][stamina:4f][flags:1]` | 10 |
| `0x22` | S→C | PlayerHitDown | `[health:4f][stamina:4f][flags:1]` | 9 |
| `0x23` | C→S | PlayerDeathUp | *(empty)* | 0 |
| `0x24` | S→C | PlayerDeathDown | `[ghostId:1]` | 1 |
| `0x25` | S→C | CombatRole | `[isDamageAuthority:1]` | 1 |

**Next free type byte: `0x26`.**

`0x21` is **routed, not broadcast** — it reaches only the player it names, and
the relay drops the `targetGhostId` on the way, since the recipient does not
need telling it is about themselves. `health`/`stamina` there are **loss
amounts** (positive magnitudes), matching `CombatSoul::TakeDamage`'s own
argument semantics at the far end.

### `0x25 CombatRole` — a gap in the design document, filled

The design doc states Rule 2 ("NPC-versus-player combat is authoritative on the
session host") but never says how a client learns whether it *is* that host,
and the agent has no notion of one: `ClientConfig` knows a relay address and
nothing else. Inferring it from that address being loopback was considered and
rejected — it is true for the launcher's own Host flow and silently wrong for
anyone who starts the agent by hand, and the failure mode is invisible (nobody
holds authority, NPC hits quietly never cross).

So the relay says so explicitly. It designates the **lowest-id ready client**
and announces the current answer to everyone on every membership change. That
is derived from the connection set the relay already tracks — it is not world
state, and the relay stays stateless in the sense that matters.

Defining the role on the connection set rather than on "who started the relay
process" also means it keeps having an answer after the host leaves, which
matters: the design doc flags Rule 2's real cost as "if the host's world is
paused or its NPCs are not ticking, NPC combat stops mattering for everyone."
Authority moving on disconnect does not fix the paused-host case, but it does
fix the departed-host case, which would otherwise be permanent.

### Protocol version deliberately **not** bumped

`Protocol.Version` stays at 6. Every packet above is additive: a client
predating this layer never sends `0x1F`/`0x21`/`0x23` and its receive loop
falls through on the types it does not know. Such a session degrades — ghost
health stops updating, NPC hits stop crossing — rather than breaking. Bumping
would instead make the relay **hard-refuse** those clients at Handshake, which
is a strictly worse outcome for an optional feature, and would invalidate the
version pin in every existing test script for no benefit.

---

## Phase 1 — Flow A, continuous player health

### The emit line, `v1` → `v2`

```
[KCD2-MP-DATA] v2 <seq> <clock> <x> <y> <z> <rotZ> <flags> <health> <stamina>
                     flags: 1=riding  2=sneaking  4=dead  8=unconscious
```

`LogTailGameTransport` parses **both** versions. This is not defensive
programming for its own sake: the pak and the agent are separately installed
and update independently (the pak via `tools/Build-And-Install-Mod.ps1`, the
agent via the installer), so a new agent reading an old pak's `v1` lines is an
ordinary state. It degrades to "health unknown" — `PlayerState.Health` is
`float?` and null means *unknown, leave it alone*, never rendered as a zero
that would read as a dead player.

Flag bits 2 and 3 are trusted **only** on a `v2` line. A `v1` emitter leaves
them clear, which would otherwise read as a positive "not dead" it never
actually asserted.

### The bindings were measured, not guessed

Every read was enumerated and executed against the running game before being
committed to, and the obvious names are wrong here. Confirmed present:

| binding | live value |
|---|---|
| `player.actor:GetHealth()` | `100` |
| `player.soul:GetState("stamina")` | `126.667` |
| `player.actor:IsDead()` | `false` |
| `player.actor:IsUnconscious()` | present on the actor metatable |

Confirmed **absent**, recorded so nothing reaches for them again:
`player.actor:GetStamina`, `player.soul:IsDead`, `player.soul:IsUnconscious`,
`player:IsDead`, `player.human:IsDead`.

One of these is a trap worth naming: `player.soul:GetState("dead")` and
`GetState("unconscious")` **return `nil` rather than erroring**. That is the
more dangerous shape — a `pcall` around them succeeds and yields a falsey "not
dead" that was never measured. Death detection built on them would have looked
like it worked and reported nothing, forever.

### What the receiver does with it

The owner's health is **rendered, not reconciled**: it is written to
`KCD2MP.ghostHealth[id]` and shown on the nameplate as `<name>  73 HP / 41 ST`.

`KCD2MP_SetGhostHealth` deliberately does **not** write the ghost entity's own
health. Lua health writes are inert in this sandbox
(`docs/PROJECT-STATE.md` §2), and the ghost's local health is a separate, local
fact — worlds are not shared, and the honest deliverable is that every peer can
*see* the right number, not that two simulations are forced to agree. This is a
conscious departure from the design doc's "receivers set the ghost's health
from this", and it is the difference between shipping a rendered number and
shipping a native write that was never proven to exist.

It does still reset the Flow B sampler baseline and set the one-shot skip flag,
so guard 2 holds whether or not such a write is ever added later.

### Rate

Sent on a change of ≥ 0.5 in health or stamina, floored at 250 ms between
change-driven sends, plus an unconditional 10 s heartbeat so a peer who joins
after this player's last health change still converges — the relay is stateless
and replays nothing, exactly as for appearance.

---

## Phase 2 — Flow C, player death

`0x23` is sent by the **dying player's own client**, latched to exactly one
packet per life. The emitter reports `dead` on every frame for as long as the
death screen is up, so without the latch that is ~50 packets a second. The
latch clears when the emitter reports the player alive again — which is exactly
what a completed save reload looks like from the agent's side, so nothing extra
has to detect the end of a death.

A receiving peer tags the ghost `[dead - reloading]` and **leaves the entity
standing**. Removing and respawning it would cost a full spawn cycle for a
player who will be back within seconds, and — before WO-27's dedupe fix — that
respawn path was exactly how duplicates appeared. The tag clears automatically
the moment that player's vitals start arriving again.

Health is suppressed on the nameplate while dead: a dead player's last health
figure is stale by definition, and showing both would be two answers to one
question.

Per Gate 0, this phase also carries the two reload fixes. A death notice that
arrives and is followed by that player never transmitting again is worse than
no death notice at all.

---

## Phase 3 — Flow B, an NPC hurts a player

### Sensor

`KCD2MP_InterpTick` already walks every ghost every 20 ms, so it samples
`ghost.entity.actor:GetHealth()` there and diffs it — the design doc's own
choice, and it needs no native hook and no DLL injection, which keeps the whole
feature testable with one machine.

A drop is reported on the existing log-tail event channel as
`[KCD2-MP-EVT] v1 <seq> ghost_hit <ghostId> <healthLoss>`.

Stamina is deliberately **not** sampled and is sent as 0: there is no confirmed
Lua stamina binding for a *ghost* (`GetState` is a soul call and the ghost's
own soul is a different object), and inventing one would drain a real player's
stamina on a guess.

### Guards

| # | Guard | Where enforced |
|---|---|---|
| 1 | only the damage authority reports hits | mod does not sample at all (`KCD2MP.hitSensorOn`); agent refuses to send; **relay drops it anyway** |
| 2 | a delta caused by an inbound authoritative write is not a hit | `KCD2MP_SetGhostHealth` sets a one-shot skip flag, consumed by the next sample |
| 3 | only negative deltas are hits | mod (`delta < HIT_MIN_DELTA` returns) and agent (`healthLoss <= 0` returns) |

Guard 1 is enforced three times for one rule because getting it wrong does not
look like a bug — it looks like players taking N times the damage they should
in an N-peer session.

### Receiver

Applied to the real local Henry through the DLL, not Lua, for the same reason
all damage is. The soul is addressed by
`4c2dcffb-dea1-6263-72d7-b39f4db2d8b5` (`player_henry`) — the same value on
every installation, which is precisely what makes it useless as a cross-client
*identifier* (WO-26 Phase 1) and exactly right as a local "the player, here"
lookup.

An arriving `UnknownStat` (-1) stamina is floored to 0 rather than forwarded:
passing a negative into `TakeDamage` would *restore* stamina.

The recipient does not reply. Their next Flow A broadcast carries the new
authoritative health, which is what corrects everyone — including the sender,
whose locally-damaged ghost health is deliberately not treated as truth.

---

## Phase 4 — the ghost's own attacks (design doc §5)

**Option (i), leave it as-is, is confirmed still the right call**, and Phases
1–3 strengthen rather than weaken the case.

Flow B is a pure *sensor* on ghost health: it reads a drop and reports it. It
never inspects, alters or depends on what the ghost's AI chooses to attack. So
nothing built here creates a new reason to suppress ghost-initiated attacks,
and nothing here would be simplified by suppressing them. The divergence option
(i) accepts — a ghost can kill NPCs its owner never attacked, in the host's
world only — is unchanged in kind and in size by this WO.

Option (ii) remains blocked on the same missing lever the design doc names: no
mechanism narrower than `NoAI` is known, and `NoAI` would also stop the ghost
being a valid target, which would break Flow B outright. It stays a research
task of its own and was not attempted.

---

## Verification

### Before any test ran

The whole `0x25` round trip was already working on an ordinary connect, with
nothing prompting it. Immediately after the human relaunched and clicked
Connect:

```
[KCD2-MP-DATA] v2 802 127.387 2348.644 2088.040 111.602 3.0998 0 100.00 126.67
KCD2MP.hitSensorOn = true
```

The emit line is `v2` and carries real health and stamina; and the relay
designated this client, the agent received the CombatRole packet, and the mod
was told — three processes, no test harness involved.

### Gate 1 — Flow A. **Passed, live.**

From `tools/Test-PlayerVitalsE2E.ps1` (17/17), the Flow A rows:

```
PASS  the mod is emitting v2 state lines
PASS  the v2 line carries a real health reading
PASS  the ghost's stored health is the value the peer sent      (42.5)
PASS  the ghost's stored stamina is the value the peer sent     (33.0)
PASS  the rendered nameplate shows the health
PASS  a later value replaces the earlier one                    (88.0)
```

The nameplate assertion reads `KCD2MP.labelCache[id].name` — the string the
player actually sees — not only the table behind it.

**`v1` compatibility is confirmed, not assumed.** Tested deterministically
rather than by racing the live emitter: stop the emitter, inject one `v1` line
into `kcd.log` with an unmistakable position, and check whether that position
comes back around the relay to the synthetic peer as a Ghost packet. It does.

```
PASS  a v1 emit line is still parsed and its position reaches peers
PASS  the v2 emitter restarts cleanly afterwards
```

That is a real end-to-end proof of the mixed-version path: an old pak's line
was parsed by the new agent and propagated normally.

### Gate 2 — Flow C. **Passed, live, both halves.**

Wire behaviour, from `Test-PlayerCombat.ps1`:

```
PASS  PlayerDeathUp reaches every other peer
PASS  PlayerDeathUp is not echoed to the player who died
PASS  PlayerDeathDown names who died, in one byte
PASS  a repeated death is forwarded, for the receiver to treat as idempotent
```

Game behaviour, from `Test-PlayerVitalsE2E.ps1`:

```
PASS  the ghost is tagged dead
PASS  the nameplate says so, and drops the now-stale health figure
PASS  a repeated death changes nothing (idempotent)
PASS  the death tag clears once that player's vitals arrive again
```

**The second half — the dying player's ghost reappearing at the post-reload
position — is the part Phase 0 existed for, and it was verified by re-running
the Phase 0 harness against the fixed build with the human reloading again.**

```
t      peerGhosts  interpAge  emitAge  labelAge  myGhostEnt
54.5   21          0.02       0.02     0.01      1     walking normally
64.5   0           ?          ?        ?         ?     LUA CALL FAILED (the reload)
70.9   0           11.17      11.17    11.17     0     broken exactly as before
74.2   0           14.00      14.00    14.00     0     still broken
75.6   10          0.01       0.01     0.01      1     ALL THREE ALIVE, BODY BACK
77.7   35          0.01       0.01     0.01      1     fully recovered
```

Before the fixes the emitter was dead for 197 s and still climbing, and the
ghost entity gone for 187 s, when the window ended — both permanent. After, both
recover in **~14 s**, bounded by the 250/500-tick re-arm cadences.

The human, watching, unprompted:

> *"Walked around for a bit, and the body recovered. Stuttered for a second and
> reappeared, not just the nameplate"*

Instrument and eyewitness agree, and the eyewitness covers exactly the thing the
instrument cannot: that it was the **body**, not another walking label.

*(A later stretch of the same run shows `peerGhosts` back at 0 while `emitAge`
stays at 0.04. That is the human standing still — the agent only pushes position
on change — and it is now distinguishable from the failure precisely because the
heartbeat is healthy. Under the old build the two looked identical.)*

### Gate 3 — Flow B. **Guards passed individually. Cross-machine step UNVERIFIED.**

Each guard isolated, from `Test-PlayerVitalsE2E.ps1`:

```
PASS  GUARD 1 host-only: no hit is reported while this client lacks authority
PASS  GUARD 3 sign: a POSITIVE delta (regeneration) is not a hit
PASS  GUARD 2 echo: a drop caused by an inbound authoritative write is not a hit
PASS  the inbound-write path is what sets the skip flag
PASS  POSITIVE CONTROL: a genuine negative delta IS reported as a hit
```

The positive control matters more than the three guards: without it, all three
could pass because nothing ever fires. It confirms the sensor does report a
genuine negative delta under exactly the conditions the guards otherwise
suppress. Guard 2's test also verifies that the *production* write path
(`KCD2MP_SetGhostHealth`) is what sets the skip flag, rather than the test
setting it by hand and proving nothing.

Relay-side gating, from `Test-PlayerCombat.ps1`:

```
PASS  first client is told it holds damage authority
PASS  second client is told it does NOT hold damage authority
PASS  the holder is re-told it still holds the role when someone joins
PASS  the authority's PlayerHitUp reaches the player it names
PASS  it reaches NOBODY else (routed, not broadcast)
PASS  PlayerHitDown drops the targetGhostId and keeps the loss amounts
PASS  a PlayerHitUp from a NON-authority is dropped by the relay
PASS  a PlayerHitUp aimed at the sender itself is dropped
PASS  a hit for a departed player is dropped and the relay keeps working
PASS  damage authority moves to the next-lowest id when the holder disconnects
PASS  the NEW authority's hits are now accepted
```

**What is NOT verified, stated plainly.** The end-to-end step — an NPC in one
player's world attacking their local copy of another player's ghost, and that
damage arriving as real health loss on the second player's own Henry in their
own game — **was not tested and is not claimed.** It needs two machines running
two real games and there is one machine here with no second player
(`PROJECT-STATE` §6). Specifically untested:

- that the DLL's `TakeDamage` against `player_henry`'s guid resolves to the
  local player rather than one of the other two souls carrying the `player`
  soul class (WO-26 found a second soul, "Dude", sitting at the player's exact
  position with its own GUID — pointer and GUID comparison traps are already
  documented in `PROJECT-STATE` §5);
- that a real NPC attacking a real ghost produces a health drop the 20 ms
  sampler actually catches at a useful magnitude;
- the round-trip latency of hit → owner → Flow A correction → everyone.

Everything up to that boundary is verified. The boundary itself is marked
unverified rather than skipped silently, per the WO's own instruction.

### Regression — all existing suites green

| Suite | Result |
|---|---|
| `Test-Combat.ps1` | 14 / 0 |
| `Test-Sessions.ps1` | 22 / 0 |
| `Test-Dice.ps1` | 10 / 0 |
| `Test-Pause.ps1` | 10 / 0 |
| Farkle xUnit | 59 / 0 |
| `Test-PlayerCombat.ps1` (new) | 21 / 0 |
| `Test-PlayerVitalsE2E.ps1` (new) | 17 / 0 |

Run against an isolated relay on port 7782 so the live session was never
touched. `Test-Pipe.ps1` was **not** run: it deals real damage to a live NPC and
needs `KCDMP.dll` injected, and `native/` is untouched by this WO — skipped
deliberately rather than run for a checkbox.

### One trap re-encountered

PowerShell variables are case-insensitive, so `$ack` shadowed the `$ACK`
constant and every handshake in the new test script "failed" against itself.
This is already recorded in `PROJECT-STATE` §5 and it still cost time. Noted at
the site in `Test-PlayerCombat.ps1`.

---

## Files touched

- `dotnet/KcdMp.Protocol/Protocol.cs` — `0x1F`–`0x25`, payload lengths, flags,
  rate constants, `UnknownStat`
- `dotnet/KcdMp.Server/Features/ClientHandling/ClientSession.cs` — accept
  `0x1F`/`0x21`/`0x23`, enqueue `0x20`/`0x22`/`0x24`/`0x25`
- `dotnet/KcdMp.Server/Features/ClientHandling/ClientHandler.cs` —
  `DamageAuthority` / `IsDamageAuthority`
- `dotnet/KcdMp.Server/Features/Tcp/TcpBroadcastService.cs` — broadcast/route
  helpers, `BroadcastCombatRole`
- `dotnet/KcdMp.Server/Features/Tcp/TcpSocketService.cs` — re-announce the role
  on disconnect
- `dotnet/KcdMp.Client/IGameTransport.cs` — `PlayerState` gains
  `Health`/`Stamina`/`IsDead`/`IsUnconscious`, all nullable
- `dotnet/KcdMp.Client/LogTailGameTransport.cs` — dual `v1`/`v2` parsing
- `dotnet/KcdMp.Client/GameBridge.cs` — Flows A/B/C, `CombatRole`, and the two
  Phase 0 reload fixes
- `kdcmp/Data/Scripts/Startup/kdcmp.lua` — `v2` emitter, vitals reads, ghost
  health/death rendering, Flow B sampler and guards, `KCD2MP_ReconcileGhosts`,
  three console commands
- `tools/Test-ReloadBehaviour.ps1` (new) — Phase 0
- `tools/Test-PlayerCombat.ps1` (new) — relay-level, no game
- `tools/Test-PlayerVitalsE2E.ps1` (new) — end-to-end against the real game
- `docs/WO-28-findings.md`, `docs/WO-28-progress.md`, `docs/PROJECT-STATE.md`

No change to `VERSION`, no installer build, per `docs/VERSIONING.md`.
