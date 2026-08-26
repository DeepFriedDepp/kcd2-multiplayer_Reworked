# WO-60 — proximity-based NPC authority, built

Evidence tiers as in WO-54/58/59, never rounded up: **observed** (a test run
this session, cited) / **code-verified** (mechanism read or written directly
in current source, not seen running) / **wire-verified** (exercised against a
real relay process on this machine, no game involved) / **inconclusive**.

Context: WO-59 Thread A's design verdict (per-NPC authority by player
proximity/engagement, generalizing the existing claim table) plus a real
two-human retest today — same jitter/one-sided-combat symptoms after WO-59's
hysteresis and clock-sync fixes were already shipped, no logs captured. Built
against that verdict as instructed; shipped with a field rollback toggle
because the fully-logged confirmation the original plan called for still does
not exist.

---

## 1. What was built

Four pieces; the mechanism itself (relay-arbitrated per-entity claims:
first-claim-wins, refresh-by-packet, expiry-on-silence, disconnect release)
is WO-39's, untouched in shape — this WO adds a new **emitter** and a new
**hold rule**, exactly as WO-51 option 2 sketched.

### 1a. The non-authority now runs the rescan/emit loop too (Lua)

`KCD2MP_NpcSyncTick` (kdcmp.lua): a non-authority used to run only the drag
sensor and return. Now, when `mp_npc_proximity` is on **and at least one peer
ghost exists**, it falls through into the exact same `mp_npc_rescan` + emit
loop the authority runs — same 30 m radius, same 5 slots, same WO-59
hysteresis, scanning around **its own player**. Emission goes out as a new
event name, `npc_claim`, which the agent routes down the existing
`asClaim: true` send path (the drag sensor's path), so the agent's
authority gate lets it through and **sending it IS the claim** — no new
relay mechanism, no claim packet. Code-verified.

What prevents claim-stealing and echo wars, by construction (all
code-verified, mechanisms pre-existing):

- An NPC someone else is actively streaming is a **puppet** on this machine,
  and puppets are excluded from the rescan (`mp_npc_rescan`, the existing
  `KCD2MP.npcPuppets` exclusion). So a claim is only ever attempted for an
  entity **nobody is driving** — the radius-gap NPCs, which is the point.
- The reverse direction self-heals the same way: when a claim wins, its
  broadcasts turn the entity into a puppet on every other machine (the
  authority included), whose rescan then drops it within one 2 s scan cycle.
  Two non-authorities racing for the same unclaimed NPC (3+ player session)
  resolve identically: relay picks the first, the loser's copy becomes a
  puppet, the loser stops emitting.
- A body the drag sensor is actively claiming is skipped by the proximity
  emit loop (`KCD2MP.dragging` check) — one claim channel per entity at a
  time from one machine.

Two deliberate side effects, both code-verified:

- **The swing-cue asymmetry closes for claimed NPCs**: the cue sampler
  (player-health-drop edge attributed to a nearby drawn NPC) now runs on the
  claimant for its claimed set, so an NPC beating on the *non-authority*
  finally emits swing cues to everyone — WO-51 §1.4's "engagement asymmetry"
  row, previously authority-only by construction.
- The `mp_npc_fight` tug-of-war meter and all receiver paths needed zero
  changes — the apply side was always sender-agnostic (WO-39).

### 1b. The engagement hold (relay) — the anti-flap design

The scenario this exists for: two players both actively, continuously
engaging one NPC. Under the WO-39 rules a claim is refreshed only by packet
arrival and expires after 5 s of silence — so any brief gap on the holder's
side (a menu pause suspends every `Script.SetTimer` chain outright, WO-12/13;
a reload kills them, WO-13) hands the entity to whichever side's packet lands
next, then back again when the holder returns. Each transition snaps the NPC
between two **diverged** simulations. That oscillator is the flap.

The hold, `ClientHandler.RouteNpcState` + `Protocol`:

- **Engagement is a wire fact, not a relay inference.** The emitter sets
  flag bit 32 (`NpcStateFlagEngaged`) when the NPC has its weapon drawn, is
  neither dead nor KO, and is within **12 m** of the emitting player
  (`NPC_ENGAGE_RANGE_SQ`, kdcmp.lua) — "a live armed NPC right next to me",
  which is this project's cheapest honest proxy for "my player is fighting
  it" using signals the emit loop already samples (drawn state, positions).
  A change in engagement state forces an immediate emit (`engagedChanged`
  joins the emit conditions), so the hold arms within one 250 ms tick of a
  fight starting rather than waiting for the 2 s heartbeat.
- **The claim table gained one timestamp**: `EngagedUtc`, the last time the
  *owner's* packet carried the bit. A claim now expires only when BOTH are
  true: silence exceeds the plain 5 s (`NpcClaimTimeoutSeconds`, unchanged)
  AND the last engagement is older than 15 s
  (`NpcClaimEngagedHoldSeconds`). While held, nobody gets the entity — not
  the global authority's default stream, not a rival claimant, regardless of
  how much competing traffic they send. A dropped rival packet updates
  nothing, so hammering cannot extend or erode anything.
- **What "quiet" means is therefore real**: the holder must stop asserting
  engagement for 15 s — not merely miss a packet — before the claim is
  eligible to move. Natural disengage (fight ends, NPC sheathes or dies, or
  the player walks off) drops the bit while packets continue, the hold decays
  in the background, and the eventual handback needs only the ordinary 5 s
  silence. A never-engaged claim (a corpse drag) has `EngagedUtc = MinValue`
  and keeps the WO-39 5 s behaviour bit-for-bit.
- **Disconnect still releases immediately** (`ClearNpcClaimsFor`, unchanged)
  — the hold protects a live holder's gap, never a dead one's.

The accepted cost, stated plainly: a holder that goes silent *mid-hold* (long
menu, reload in progress) leaves the entity streamless for up to 15 s instead
of 5. Receivers already release a silent puppet after 3 s and the local
engine takes the NPC back (WO-32, observed then), so the visible result is
brief local autonomy — the same bounded blink as a reload — never a snap war.
That trade is the design: an occasional 15 s of divergence beats an NPC
teleporting between two worlds' positions every few seconds for a whole
fight. WO-51's dialogue-freeze case (79 s, observed) exceeds the hold and
falls back to the authority; also acceptable, also deliberate.

### 1c. The rollback toggle — `mp_npc_proximity on|off`

`KCD2MP_EnableNpcProximity` + `System.AddCCommand`, the `mp_npc_sync` /
`mp_horse_adopt` pattern exactly. Default **on** (the mp_npc_sync default-on
precedent). `off` is the field rollback to pre-WO-60 host-only tracking:

- On a non-authority it clears `KCD2MP.npcTracked` on the spot, so the claim
  stream stops within one tick; the tick's fall-through gate then returns
  before the rescan every time. Standing relay claims expire on silence
  (5 s, or up to 15 s if a fight was just live) and the host's default
  stream resumes — the handback is the relay's ordinary expiry path, not a
  special case, so no hybrid state exists to get stuck in. Code-verified
  (Lua), and the handback half is **observed** on the wire (T13/T19/T20:
  authority resumes / rival granted after expiry).
- On the authority the flag is never read — its behaviour never depended on
  it — so the toggle cannot half-disable the host stream. Code-verified.
- The relay needs no toggle: with no engaged-flagged claims arriving, the
  hold never arms and the table behaves exactly as shipped in WO-39 —
  **observed** (T10–T14 all pass unmodified against the new relay, and T20
  confirms an un-engaged claim keeps the plain 5 s expiry).

Honest statement for the definition of done: "toggle confirmed working both
directions" is **code-verified on the Lua half, wire-observed on the relay
half**. No game ran this session, so the in-game flip (console command →
emission stops → puppets hand back on a real second machine) is unobserved;
it is the same gate-at-tick-time pattern as `mp_npc_sync`, which is
field-proven.

---

## 2. Test results (all observed this session)

| Suite | Result | What it proves |
|---|---|---|
| Test-TimeSkipRelay T1–T16 | pass (unchanged) | no regression: skip arbitration, WO-39 claim grant/mute/expiry/disconnect all intact under the new claim-table shape |
| **T17** two engaged claimants, sustained competing pressure (8 interleaved refresh rounds) | pass | B received exactly the holder's 9 packets, single source; every rival packet dropped; the holder never moved |
| **T18** holder silent 6 s (past the old 5 s expiry) mid-hold | pass | rival's engaged takeover dropped AND the authority's stream stays muted — the gap that used to flap no longer moves the claim |
| **T19** genuine quiet past the 15 s hold | pass | the claim finally moves (rival granted) — the hold decays, it is not a wedge |
| **T20** un-engaged claim, 6 s silence, rival claims | pass | plain 5 s expiry preserved for never-engaged (drag-class) claims; claimant→claimant handoff works |
| Test-TimeSkipRelay total | **35/35** | |
| Test-ItemSyncRelay | 11/11 | claim-echo item arbitration untouched |
| Farkle tests | 59/59 | |
| Both solutions | build clean | 0 errors (pre-existing warnings only) |

One test-harness finding worth keeping: piping a PowerShell function's
comma-wrapped array result (`,$found`) straight into `Where-Object` hands the
whole array to the filter as one item — assign first, then filter
(`Drain-NpcStatesFor` in the suite). T18's first "failure" was this plus an
undrained buffer, not the relay.

## 3. What testing did NOT happen

- **No live two-machine session** — none was available this session, and per
  the WO this does not block shipping: the relay half (the arbitration and
  the hold, where the flap risk lives) is fully wire-observed; the Lua half
  is a new gate plus an event-name switch on a field-proven loop; the toggle
  is the safety net.
- The Lua changes are **inert until `Build-And-Install-Mod.ps1` rebuilds the
  pak** and ship only as a full matched-set publish — WO-58's deploy rules,
  unchanged. No `VERSION` change (user owns versions).
- The claim/hold interplay with the DLL's native paths (ghost swings, hit
  sensor) is unchanged by construction — Flow B's sensor still runs only on
  the authority; a **claimed** NPC hurts its claimant directly in the
  claimant's own world (that fight is fully local and real, which is the
  whole point) — but this composition has never been watched live.
  Inconclusive until a real session runs.

## 4. Tester asks (carry into the next release notes)

- **Collect logs during the episode, from both machines.** Several sessions
  running have now lost their diagnostic value because no logs were captured
  — today's confirming session included. If jitter or one-sided combat
  recurs with proximity authority live, that bundle is what turns "still
  broken" into a next lead; the claim lines (`NPC-SYNC tracking`,
  `npcclaim ... dropped` on the relay, `NPC-PROX`) are all in the standard
  bundle already.
- **The rollback**: if NPC behaviour gets *worse* on this build, run
  `mp_npc_proximity off` in the console on the joining (non-host) machine —
  that alone restores the old host-centred model within seconds, no
  reinstall. Report that it was used.
- Fights near the 45 m tracking edge and fights during menu/dialogue pauses
  are the interesting cases for the hold — note them.

## 5. Design records for the next WO

- The hold constant (15 s) is a judgment call sized to menu blips and reload
  gaps, not measured — if field logs show real fights losing claims (holder
  quiet > 15 s while still fighting) or stale holds wedging handoffs, tune
  `Protocol.NpcClaimEngagedHoldSeconds` first before touching the shape.
- Engagement is emitter-side and proximity-based (drawn + alive + ≤12 m).
  The known sharper signals (DLL LocalHit attribution, 0x2C combat events)
  were deliberately not wired in — they belong to the WO-51 WO-B/WO-C track
  (Flow B verification, brain suppression), which this WO does not touch.
- Health on a claimed NPC still converges by damage events only (0x30);
  the 0x26 `hp` field remains stored-never-written on receivers. The
  kill/loot arbitration gap (WO-49) is unchanged.
