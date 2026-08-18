# WO-38 — the first real 20-minute two-player test: findings

Worked 2026-08-18. **The game was not available this session** (the human could
not launch it), so this WO ran as: read all the real evidence, build everything
buildable, verify everything verifiable without the game, and document every
live-gated step precisely. Evidence discipline as always: **observed /
read-but-unrendered / inconclusive**, never rounded up.

**No test in this session involved a real second human.** Everything verified
here used synthetic TCP peers against the real relay (no game process at all).
Genuine two-human verification is the follow-up external testing pass; the
checklist for it is `docs/WO-38-tester-checklist.md`.

Source report: `docs/WO-38-source-report.md` (checked in verbatim before this
session). Testers' logs: `docs/WO-38-test-logs/PlayerA.log` / `PlayerB.log`
(copied from Downloads and committed first). The raw 20-minute video exists at
`C:\Users\Jonasty\Downloads\TestingEvidence.mp4`; no frame-extraction tooling
(ffmpeg) is installed locally, so it was not consulted this session — noted
per-phase below where a frame would settle something.

---

## Phase 0 — what the two real log files actually contain

Both files were read **in full** (6,748 and 4,687 lines). The result is a
significant negative, stated plainly:

**Neither log contains any gameplay or multiplayer telemetry at all.** They
are the *launcher's* Serilog output only — Blazor component-render chatter,
master-server HTTP discovery, and nothing else. Exhaustive keyword sweeps
(NPC, ghost, horse, cloth, calendar, combat, forge, corpse, packet, relay,
peer, inject, save — 30+ terms) returned **zero matches in both files**. The
game-side evidence for all ten reported sections therefore does not exist in
these logs; the play blocks appear only as silent gaps (PlayerB: 52.3, 96.7
and 68.8 minutes; PlayerA: two ~12-minute idle windows inside its one healthy
session). Every per-phase "check the logs at that timestamp" instruction in
the WO prompt resolves to: **absence of evidence, recorded as such.**

What the logs DO establish (real, observed, both machines):

- **Both testers fought a dead master server for ~4.5 hours.** `localhost:5000`
  refused every connection (SocketException 10061): 31 identical errors on A
  (09:59–14:59), 22 on B (10:43–15:09), across 30 launcher restarts on A and
  16 on B. Fixed at ~15:55 when a new `EnsureLocalMasterServerAsync` code path
  appeared (config moved to `127.0.0.1:5100`, local master auto-spawned).
  **Zero errors after the fix on either machine.**
- Player A hosted at `10.0.0.35:5273`; B's probes to it succeeded 16 of 18
  times (one 5s timeout on a stale public entry `193.186.4.235`, one refusal
  at 15:56:26 when A was not yet listening).
- PlayerA.log shows two **silent sub-second launcher crashes** (11:44:23,
  14:58:00 — exactly 33 boot lines each, no exception logged). Not chased this
  session; noted as a real, unexplained launcher defect.
- Every master-server error triggers a triple full re-render of the whole
  modal tree (~30 log lines per error; ~80% of both files is render chatter).
  A logging/perf cleanup candidate, not a WO-38 item.

**Implication for the launcher:** the mod's game-side diagnostics
(`kcd.log`, agent console) were either not collected or not requested from
the testers. The tester checklist now tells testers exactly which files to
send back, so the next real session is not dark.

---

## Phase 1 — day/night time synchronization — **BUILT + WIRE-VERIFIED; live steps gated**

### What the evidence supports

- The WO asked for real observed clock-gap numbers from the logs first: **the
  logs contain no time data at all** (Phase 0). The design gap numbers come
  from the report text instead: sleeping diverges clocks by *hours* (Section
  F), fast travel by ~3 in-game hours per trip (Section H).
- `Calendar.SetWorldTime` is this project's **one previously live-verified Lua
  world mutation** (ARCHITECTURE-shared-world.md: `t+3600` moved the clock
  exactly one hour, then restored — observed in that session, not re-run in
  this one).
- The shipped scriptbind docs (checked this session) add two hard constraints:
  `SetWorldTime(int)` is whole seconds from level start and **"Must not be set
  backwards"** — so every apply in this design is forward-only; and the
  `SkipTime` scriptbind is UI-strings only — **there is no programmatic
  "trigger a real skip" surface**, so the WO's option 2 (trigger a vanilla
  skip to a target) is closed on the documented surface. `Game.WarpTime` is a
  time-*speed* effect (slow-motion/speed-up), not a targeted skip.
- A world day is 86,400 world-seconds — consistent with the prior observation
  (388805 % 86400 = 43205 s = 12.0014 h against the hour 12.0015 read in the
  same probe). Read-but-unrendered; one live read confirms it.

### What was built (all committed)

- **Wire** (`Protocol.cs`): `0x28 TimeSkipUp` / `0x29 TimeSkipDown` —
  `[phase][kind][worldTime:4]`; phases start / done / done-quiet; kinds
  sleep / wait / fast-travel / unknown. Deliberately **not** gated on Rule 2's
  damage authority — any player's sleep counts, per the WO.
- **Relay** (`ClientHandler` + `ClientSession`): the session's **one active
  skip**. First `start` to arrive owns it (deterministic by relay arrival
  order — never by comparing finished results); anyone else who starts while
  it is active is **joined** (their start is dropped, their membership
  recorded). The owner's `done` is broadcast announced; a joined player's own
  `done` — during the skip or within a 120 s grace window after it — is
  broadcast **done-quiet** (applied, no toast). A bare `done` from nobody's
  skip is an instant skip (the fast-travel shape) and is announced. Owner
  disconnect and a 180 s timeout clear into grace, so a crashed sleeper cannot
  wedge the session.
- **Agent** (`GameBridge`/`LogTailGameTransport`): skip start/end detected
  from the `AfterSkipTime` kcd.log markers WO-11 confirmed live (a new
  `SkipTimeStateChanged` event beside the existing aggregate pause signal);
  on end, the resulting clock is read via a new `KCD2MP_ReportWorldTime()` →
  `time_now` game event and sent as the done. A **clock-jump watcher** (10 s
  poll of the same reading) catches marker-less advances — fast travel was
  never confirmed to emit `AfterSkipTime` — reporting one settled jump as one
  instant skip, with agent-local loop guards (own-skip suppression, 30 s
  suppression after applying an inbound skip) so applied skips can never echo.
- **Mod** (`kdcmp.lua`): `KCD2MP_ApplyTimeSkip` — forward-only
  `Calendar.SetWorldTime`, and the toast on the existing
  `KCD2MP_ShowInteractionMsg` DrawText slot: `"<name> slept till 8:00 AM"`
  (kind 0) / `"<name> passed time to 8:00 AM"` (every other kind). Quiet
  applies show nothing; the initiator sees nothing (the relay never echoes).

### The overshoot case, decided and stated

If B joins A's skip and B's own vanilla skip lands *past* A's target (B slept
10 h from 10:05 pm, A's target was 8:00 am), B **cannot** be pulled back — the
engine forbids backward writes. The session converges **up** to B's result
instead, silently (done-quiet). Residual divergence after any exchange is
bounded by overshoot minutes, never by hours. This is the closest achievable
shape to the WO's "B wakes at the same moment as A" under the engine's
documented constraint, and it is deterministic and single-notification.

### Verified this session — `tools/Test-TimeSkipRelay.ps1`, 15/15 PASS

Synthetic peers against a relay the script starts itself (**no game, no
agent**): first-claim broadcast; join-not-race (second start silent); owner
done announced; joined done forwarded quiet; bare done announced (fast-travel
shape); duplicate starts absorbed; grace surviving owner disconnect; plus the
Phase 5 horse packets. This is real wire-level verification of the
arbitration rules — it is **not** verification that clocks move in a real
game.

### Live-gated (exact steps in the tester checklist and below)

1. Re-verify `Calendar.GetWorldTime`/`SetWorldTime` on this build, including a
   **large forward jump (10 h)** — the prior observation was +1 h.
2. **Side effects of a forced jump** (WO step 3) — hunger/thirst/fatigue,
   quest timers, mid-combat/mid-dialogue behaviour. *Nothing is known about
   these; they were not observable this session and are reported as
   unknown, not as absent.* The vanilla skip applies need changes; a bare
   clock write plausibly does not — which may actually be the less jarring
   behaviour for the receiving player, but that is a hypothesis.
3. The **bed-vs-wait kcd.log marker diff** (sleep in a bed; use wait; fast
   travel; diff the log). Until a distinguishing marker is found, every skip
   reports kind=unknown and receivers use the "passed time to" wording. The
   plumbing for kind is complete end-to-end; the detection table
   (`LogTailGameTransport.LastSkipKind`) is the one extension point.
4. E2E with the real agent: peer sleeps → this clock advances (read
   `GameplayTime` back via REST on both sides, not the UI), toast wording and
   initiator-sees-nothing.

**Gate 1: built, and the relay-arbitration half is verified working on the
real wire. The in-game half is genuinely untested — not claimed.** No blocking
obstacle was found; the one designed-around constraint (no backward writes)
is documented above.

---

## Phase 2 — NPC phasing re-test — **LIVE-GATED; mechanism analysis done**

The re-test this phase exists for (reproduce Section C/G with clocks
converged) **requires the game and could not run**. What this session
contributes is a code-level account of the reported symptom, so the live
session tests hypotheses instead of hunting:

1. **Time divergence is a sufficient cause for most of Section C/F phasing.**
   A puppet is written every 50 ms with lerp 0.5 toward the authority's
   position, while its own local AI — on a diverged clock, wanting to be
   somewhere else entirely (night schedule vs day) — pulls it back between
   writes. WO-32 measured "stream wins completely" against an *idle* NPC
   whose own anchor matched; a hard-diverged schedule is exactly the
   condition under which the tug-of-war becomes visible at write frequency —
   "phasing between 2 positions", as reported. Section F explicitly observed
   the phasing alongside the day/night mismatch.
2. **Boundary flapping is a second, independent oscillator:** an NPC near the
   authority-player's 30 m radius edge is tracked/untracked on the 2 s rescan;
   each release (3 s silence) lets the engine restore it to ITS schedule
   position — far away under clock divergence — then re-tracking snaps it
   back. Period ~5 s. With clocks converged both positions nearly coincide
   and the flapping becomes invisible.
3. **A genuine dueling-authority race exists as a documented possibility but
   with only one observed instance ever:** WO-32's one intermediate-run
   anomaly (a non-authority NpcStateUp applied once during a relay swap,
   never reproduced, working hypothesis: a half-joined session made the peer
   legitimately the lowest-id *ready* client). The relay-side drop rule was
   verified four consecutive runs after. If phasing survives converged
   clocks, this is where to look — specifically agent reconnect windows
   (`IsReady` flapping) — not the steady-state path, which is single-writer
   by construction.
4. **Section G's "PB invisible to PA" after PA's save reload** is NOT
   explained by any code path found: the reconcile + re-arm machinery
   (WO-13/WO-28) should respawn PB's ghost within seconds once packets flow.
   Candidates for the live session: (a) PB standing still — position packets
   are change-gated, and a stale ghost row with no inbound movement never
   respawns; (b) a spawn failure with no visible retry. The NPC-side half of
   that report ("the attacking NPC disappeared for PB") IS explained: PA
   (authority) reloading stops the 0x26 stream, PB's puppet is released after
   3 s and reverts to PB's own world state — under diverged clocks, somewhere
   else entirely.

**Gate 2: open — blocked on the game.** The specific live procedure is in the
tester checklist (watch one wandering NPC from both sides after a synced
sleep; then repeat across an agent reconnect).

---

## Phase 3 — ghost animation smoothing + jump — **BUILT; live eyeball gated**

Three defects found by reading the interp path against the delivery channel's
real measured behaviour (WO-30: batched ExecuteString, 60–130 ms warm), all
fixed in `kdcmp.lua` (committed):

1. **Velocity zeroing on burst packets.** Updates arrive in bursts (the agent
   flushes batches per tick), so consecutive `KCD2MP_UpdateGhost` calls often
   land microseconds apart. dt < 5 ms used to set raw velocity to zero and
   halve the smoothed estimate every burst — the dead-reckoning input
   oscillated between 0 and real. Burst packets now leave the estimate alone.
2. **Dead-reckoning snap-back — the literal "two steps forward, one step
   back".** The render target was projected up to 60 ms ahead of the last
   packet, then **reverted to the unprojected position** the moment the gap
   exceeded 3 ticks — which bursty delivery makes routine. Every revert
   stepped the target backward by the projected amount and the 0.5 lerp
   faithfully rendered it. The projection now holds at its cap instead of
   reverting; the next packet overwrites it.
3. **Backward corrections rendered at full strength.** A correction opposite
   the direction of travel is almost always jitter (stale/regressed target),
   not the player moonwalking; those are now damped (factor 0.15 vs 0.5).

**Jump (the stationary-vertical-teleport report):** animation selection only
ever saw horizontal speed, and the floor snap-down actively flattened any arc
under 2 m. Now: vertical rate is tracked from packet z-deltas; while airborne
(vz > 1.2 m/s, held 0.6 s) the snap-down is suppressed and a jump animation
plays **if the probe list finds one on this build** — the established
findAnim pattern, where an unconfirmed name can never play and none-found
falls back to locomotion (legs keep moving), which is still strictly better
than the reported stiff teleport.

**Verification status: the code paths are exercised by any live session
automatically, but nobody has SEEN the result.** Smoothness is an eyeball
property; the checklist has a specific walk/sprint/jump observation item.
None of the jump-animation candidate names is confirmed to exist.

---

## Phase 4 — combat visibility — **ROOT CAUSE DETERMINED FROM CODE; cue built**

**It is a missing sync channel, not a bug in applying something sent.**
Determined by inspection, and the code is unambiguous: the emit line carries
position, rotation, riding/sneaking flags, health, stamina, dead, unconscious
— nothing else. The ghost's animation is selected purely from rendered
horizontal speed (idle/walk/run/sprint/sneak). **No combat state, weapon
state, swing, block, or hit reaction has ever been captured or transmitted.**
The observing player sees a ghost standing still with arms down because that
is, faithfully, everything the protocol knows.

What sharing it would take (stated, not built — deliberately out of scope
this session): a combat-stance flag (Human.DrawWeapon exists per WO-23 for
the drawn/sheathed half) plus swing events driving combat animations on the
ghost. Real design work with real unknowns (KCD2 combat animations are
Mannequin-driven); it needs its own WO.

**The frozen-standing-body-on-death report is the WO-28 design working as
designed** — `KCD2MP_SetGhostDead` deliberately leaves the body standing so a
player back in seconds costs no respawn cycle, and the `[dead - reloading]`
nameplate tag exists in code and is applied. The tester plausibly never saw
the tag because nameplates are distance-scaled and hidden in several states.
**Built this session:** a body-level cue — on the owner-death transition the
standing ghost now gets a one-shot fall/lie pose from a probed candidate
list (same can't-misfire pattern as the jump list; none of the names is
confirmed on this build). Freeze semantics unchanged.

---

## Phase 5 — horse synchronization — **BUILT + WIRE-VERIFIED; engine behaviour gated**

The old mechanism, from code: riding existed only as a boolean on the
position stream. On riding-start the receiver spawned a generic `Horse`-class
entity — **default appearance, which is the report's grey horse** — mounted
the ghost on it, drove it, and deleted it on dismount. Nothing else ever knew
it existed (the report's "can see it but cannot mount it or hit it"), and an
unmounted horse had no representation at all. Section D is a faithful
description of exactly this code.

Built (all committed, wire half tested):

- **Identity on the wire:** `0x2A HorseInfoUp` / `0x2B HorseInfoDown` — the
  ridden horse's authored entity name (the same cross-client key as NPC
  sync), captured from the riding check's Method 0, which already had the
  mounted entity in hand. Sent on mount change + 30 s re-emit; empty name =
  dismounted or unreadable (runtime-spawned horses have per-save names that
  deliberately do not travel). Wire-verified in Test-TimeSkipRelay T8.
- **Adoption on the receiver:** a same-named local `Horse` entity is adopted
  as the ghost's mount instead of spawning the proxy — right look, and a
  real, interactive horse that is **released, never deleted**, on dismount.
  A late-arriving identity swaps an already-spawned proxy in place. The
  proxy remains the fallback.
- **Idle horses:** the NPC-sync rescan now includes `Horse`-class entities
  (same 30 m/5 cap, sharing the cap with humans), so a peer's unmounted horse
  that exists in both worlds converges *before* anyone mounts it. Two
  double-driver guards: the local player's own mount is excluded from the
  emit set (its position is implied by the rider's stream), and an adopted
  mount is ignored by the puppet path.
- **Horse gaits:** Horse-class puppets get `relaxed_idle`/`relaxed_walk`/
  `relaxed_gallop` (names recorded as confirmed by the old `mp_scan_horse`
  probes) instead of humanoid locomotion.

**Live-gated, stated exactly:** `human:ForceMount` onto a *world* horse (only
ever observed onto a mod-spawned one); whether a position stream wins against
a real horse's AI (WO-32 proved it for human NPCs only); gait choice at
speed; and whether a peer's *player-owned* horse exists under a stable
authored name in the other install at all. One honest limitation by design:
a horse that genuinely does not exist in the observer's world can only ever
be the proxy — this layer never spawns real content.

**The "gray for PB too" line in Section D is not explained by any code path
found** — the mod never touches the rider's own horse on the rider's own
machine. This is the single place where the 20-minute video would help most;
flagged for the human rather than guessed at.

---

## Phase 6 — knockout + corpse dragging — **BUILT; design call flagged**

- **Knockout is now a freeze condition everywhere death was** (committed):
  `actor:IsUnconscious()` — the read WO-28 already shipped for self-vitals —
  now freezes (a) a ghost knocked out in this world, (b) a ghost whose owner
  reports unconscious (0x20 flags bit 0), and (c) an NPC puppet knocked out
  locally **or** flagged knocked-out by the authority (new `0x26` flags
  bit 1, emitted from the authority's own `IsUnconscious` read). Section G's
  "knocked out but still walking" was precisely the puppet stream driving a
  KO'd body, and only `IsDead()` being checked.
- **Corpse drag-follow, the WO-34 tension, resolved for the case that is
  clean:** the ghost stream must stay frozen for corpses (its source is the
  live owner's position — WO-34's reasoning stands untouched). But the
  NPC-sync stream's source IS the body's actual location in the authority's
  world, so a dead/KO puppet now **follows a stream move > 0.5 m as a
  one-shot placement** — no animation, no per-tick lerp fighting the local
  ragdoll. The authority dragging a corpse now syncs.
- **The design call, flagged and not decided** (per the WO's instruction):
  a **non-authority** player's drags still cross no machine — only the
  authority emits NPC state, and the report's dragger (PB) was not the
  authority. Making the dragger authoritative for the body they are carrying
  means per-entity authority migration — a real architectural extension of
  the single-authority model (WO-26 §3 / WO-32), with its own race questions.
  That is the human's call, not this session's.
- Also honestly recorded: the knockout itself did not cross machines in the
  report (PA's copy stayed "alive and well" while PB's was KO'd). The 0x12
  damage path replicates health/stamina loss by soul GUID, but whether a
  replicated stamina hit reproduces *unconsciousness* on the other machine
  has never been observed. Live question, in the checklist.

---

## Phase 7 — clothing gaps + stuck distress dialogue — **INVESTIGATED; A/B probe built**

**Shirt/pants never appearing:** the outbound read is
`EquippedArmorsByClassId` + `EquippedWeaponsByClassId` (WO-9/WO-10), and the
prime hypothesis is that some garment classes live in a *third* equipment
map this poll never reads. Cannot be settled without the reflection API; the
live probe is one step (equip shirt/pants, read `EquippedArmorsByClassId`,
see whether the class ids appear; if not, walk `EquipmentManager`'s siblings
at depth 1). The receiver's retry machinery only retries what arrives, so a
class missing at the source is invisible to every downstream layer —
consistent with "belt and boots appeared, shirt and pants never did".

**The 5-minute delay observed once:** no mechanism in the code produces a
5-minute convergence (3 s poll, 30 s heartbeat, bounded retries). One real
candidate from the same day's history: the testers' first 0.11.8 install had
**silently half-applied** (WO-32 addendum — old agent DLLs under a new pak,
found and fixed that afternoon, install-gate hardening shipped because of
it). A mixed build mid-session would produce exactly this kind of
inconsistent-latency behaviour. Unprovable retroactively; recorded as the
leading explanation, with the checklist asking testers to confirm
`Verify-Install.ps1` passes before the session.

**The stuck combat-distress barks (B.1):** the voice is the donor soul's
authored voice set (WO-34 §1.6) firing on the ghost's real combat-stimulus
state; the loop plausibly never clears because the distress behaviour wants
the body to flee and the interp tick pins it in place, so the state never
resolves. **Built:** `mp_ghost_ignorant on|off` — `AI.SetIgnorant` (the
registered, documented stimulus-deafness lever from WO-32 §1f) applied to
all ghosts including new spawns, as a **live A/B**: (a) do the barks stop,
(b) do NPCs still attack the ghost. Not defaulted on, because if it also
blocks being a combat *target* it would silently regress WO-26/27's
always-on reactive combat — the A/B tests both edges in minutes.
**Recommendation, stated not implemented:** if the A/B shows SetIgnorant is
safe for targeting, ghosts should probably be stimulus-deaf by default —
they have no player behind their reactions, and every stimulus response
(barks, alerts, flee-urges) is noise. That is a scope expansion the human
should approve first.

---

## Phase 8 — map markers — **SURFACE FOUND; probe built, feature gated on it**

New finding from the shipped scriptbind docs:
**`GameRules.AddMinimapEntity(entityId, type, lifetime)`** (and
`RemoveMinimapEntity`) is documented — and it is exactly the right shape,
because each connected player's ghost is already a real local entity whose
position the mod keeps synced: marking the **entity** makes the marker move
for free, no new sync channel, no coordinate math. `Map.CallScript(name,
param)` also exists as a second, darker route into the map UI.

The risk is the known documented-vs-registered gap (`Actor.SetAIBrainId` was
documented and absent; most AI writes are registered and inert), against
KCD2's custom map UI rather than the Crysis minimap this bind was born for.
**Built:** `mp_map_marker <type|sweep>` — probes the bind on every ghost
(registration check, then AddMinimapEntity with the given icon type, or a
0–15 sweep), one console command in a live session with the map open. If any
type renders, the shipping feature is a three-line addition to
`KCD2MP_SpawnGhost` + cleanup in `KCD2MP_RemoveGhost`. If none renders, the
next lead is `Map.CallScript`, and failing that this needs the launcher-side
map (a real feature design), which is beyond a probe.

Also affirmed per the WO: nameplates fading past ~50 m is correct behaviour
and was not touched.

---

## Phase 9 — the forge bug — **MECHANISM HYPOTHESIS FROM CODE; no fix shipped, deliberately**

- **The logs first, as instructed: they contain nothing** — no game-side
  telemetry exists in either file (Phase 0), so the "read everything around
  the real timestamp" instruction cannot be executed against this data. The
  reported damage event does not appear anywhere.
- **Code-path analysis — there is exactly one mod mechanism that can hurt a
  player who was not hit in their own world:** WO-28 Flow B. The authority's
  client samples every ghost's local health each interp tick and reports any
  drop; `SendPlayerHitAsync` has two guards (authority-only, positive delta)
  and **no attribution of any kind** — it cannot distinguish an NPC's sword
  from fire, falling, or collision damage. `ApplyPlayerHitAsync` then applies
  the loss to the real Henry through the DLL, unconditionally.
- **Hypothesis (one hypothesis, not a conclusion):** in the approaching
  player's (= authority's) world, the forging player's ghost stands in the
  raw player position at the anvil with no forging animation — plausibly
  intersecting the forge's hot volume. Environmental damage ticks the ghost's
  health down; Flow B faithfully relays each tick to the forging player as
  real damage. "PA approaches" gates it because PA's proximity is what makes
  the forge area (and/or the ghost's physics contact with it) actually
  simulate. The reported coupling to hammer swings may be perception, or the
  emitted position micro-moving during the minigame; undetermined.
- **Why no fix is shipped:** the WO's own instruction, and the honest state
  of knowledge — the hypothesis is unverified, and every candidate mitigation
  (rate-limiting Flow B, damage-type filtering) either needs attribution the
  engine does not expose (`NATIVE-PLUGIN-findings.md`: TakeDamage creates no
  combat history) or would blunt real NPC hits. **Live verification is
  cheap and specific:** stand a ghost at a lit forge in the authority's
  world, watch `[playerhit]` lines in both agents' consoles and the ghost's
  health via `mp_vitals`. If health ticks down with no NPC in sight, the
  mechanism is confirmed and the fix discussion (e.g. suppressing Flow B
  while the target's owner is in a crafting minigame — detectable from
  kcd.log markers, same WO-11 pattern) can be had on evidence.
- The video would show whether the ghost visibly clips the forge; noted for
  the human.

---

## Suites

- `tools/Test-TimeSkipRelay.ps1` (new): **15/15 PASS** (time-skip arbitration
  7 scenarios + horse identity round-trip; no game needed).
- Farkle: **59/59 PASS**. Installer detection: **21/21 PASS**.
- Installer lifecycle suite (41 tests): **not run** — it performs real
  installs, and this shell's `%LocalAppData%` is sandbox-redirected (WO-32
  addendum; project memory). It must be run by the human, unchanged, before
  any release build.
- Game-dependent suites (`Test-NpcSyncE2E`, vitals, appearance, reload):
  **not run** — no game this session. Nothing in this session's changes
  alters their pass conditions except NPC-sync now emitting horses (the E2E
  asserts on specific human NPCs and is expected to still pass; stated as
  expectation, not result).

## Addendum — the live battery, run same-day on the real 0.12.6 stack

The human installed 0.12.6 (Verify-Install PASS), launched through the
launcher, and sat at the machine. Results, all **observed live**:

**Phase 1 — VERIFIED END TO END.**
- `Calendar.GetWorldTime` is the real day/night clock (86,400 s/day confirmed
  exactly: 569978 % 86400 = 51578 s = 14.327 h against GetWorldHourOfDay =
  14.3273; ratio 15). **The REST-reflected `Calendar` attributes are NOT the
  world clock** — GameplayTime/GameTime reflect session play time in ms.
  WO-25's Calendar lead was real but named the wrong values; the Lua bind is
  the only correct surface.
- +1 h and +10 h forward writes landed exactly (574284 → 610284, hour 15.5 →
  1.52 AM). **A backward write is silently ignored by the engine** (call
  succeeds, clock unchanged) — the forward-only design is engine-enforced.
- **Side effects: none found on needs.** hunger 82.1255 / exhaust 70.658
  byte-identical across the +10 h jump; hp/stamina unchanged. A forced clock
  write does NOT apply the need-drain a vanilla sleep does — the receiving
  player pays nothing for someone else's sleep. Quest-timer interaction not
  specifically exercised.
- **Outbound skips, human-performed:** a real bed sleep and a real wait both
  produced start+done pairs on the wire, captured by a synthetic listener
  peer (sleep resolved to 7:53 AM, wait to 10:59 AM). Real agent, real relay,
  real markers.
- **Inbound applies:** three synthetic-peer skips applied to the human's
  running game (`ApplyTimeSkip: ... (written)` each time, clock read-back on
  target), toast seen by the human.
- **Clock-jump watcher:** a real short fast travel advanced the clock ~40
  in-game minutes and was **correctly ignored** (below threshold). An
  emulated fast-travel advance (+300 s every 2 s for 30 s) was reported as
  exactly ONE settled instant skip, kind=fast-travel, once no inbound-apply
  suppression overlapped it — and an earlier run during the suppression
  window was correctly swallowed, which live-verifies the echo guard too.
- **Bed-vs-wait kind marker: a real negative.** kcd.log at verbosity 4 was
  diffed around a real bed sleep vs a real wait (±80 to ±350 lines, keyword,
  set-difference and audio-RTPC passes): no discriminating line exists. A
  new `sqc_ptag_skiptime` RTPC bracket was found (both kinds). Kind stays
  unknown → generic "passed time to" wording, permanently unless a different
  detection route is found.
- **Toast restyled at the human's direction** ("middle of the screen using
  the standard KCD2 font... top left is not immersive"): now
  `UIAction.CallFunction("hud", -1, "ShowInfoText", ...)` — the dice
  overlay's own native surface — with DrawText as fallback. Human-confirmed
  live in the centered native style. (Also learned: a hot-patched function
  cannot call the pak's `local mp_log` — the first patch crashed silently
  after the clock write; errors inside the agent's batched ExecuteString
  chunks vanish without a kcd.log line.)

**Phase 8 — CLOSED as not achievable on the documented surfaces.**
`GameRules.AddMinimapEntity` is **not registered** on this build
(`GameRules` itself is nil, `Map` is nil — probed live with a ghost present).
`UIAction` is registered, so a map-panel route may exist, but that is its own
research WO. The mp_map_marker probe stays in the pak for future builds.

**Also verified incidentally:** synthetic peer → real relay → real agent →
ghost spawned as a real soul (`kcd2mp_2` etc.) next to the human's player —
the full presence path on 0.12.6.

Still genuinely two-human-gated: everything in the tester checklist (the
phasing re-test, horse adoption on two real installs, the forge observation,
the mp_ghost_ignorant A/B under real combat, shirt/pants classes).

## What is left for a follow-up session (in order)

1. The Phase 1 live battery: Calendar round-trip + 10 h jump + side effects;
   bed/wait/fast-travel marker diff (fills in the kind wording); agent E2E.
2. Phase 2's actual re-test with converged clocks (it was never possible to
   run it here).
3. The three probes: `mp_map_marker`, `mp_ghost_ignorant` A/B, the forge
   ghost-at-anvil observation; plus the shirt/pants EquipmentManager read.
4. Phase 5 live: ForceMount onto a world horse, stream-vs-horse-AI, and the
   video check on Section D's "gray for PB too" line.
5. Rebuild + install (`Build-And-Install-Mod.ps1` + Setup) — **nothing in
   this session is live until the pak is rebuilt and the game restarted**
   (project memory: editing kdcmp.lua does nothing live), and the human owns
   the version string for any release (docs/VERSIONING.md).
