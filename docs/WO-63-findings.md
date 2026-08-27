# WO-63 — NPC sync vs. ghost interpolation: gap analysis and its relation to proximity authority

Design document only. No code changed this session. All line references are
`kdcmp/Data/Scripts/Startup/kdcmp.lua` at commit 666d965 unless noted.

Evidence labels used throughout: **observed** (seen live or in footage,
per the cited WO doc), **code-read** (read in source this session, never
rendered), **derived** (follows from code-read math, not watched).

---

## Phase 1 — does the NPC puppet path interpolate, or snap?

**Answer: partial overlap.** The NPC puppet path already has the ghost
interp's *core shape* — snap on a big gap, exponential lerp otherwise —
deliberately copied (the comment at 2527 says so: "Same teleport-vs-lerp
shape as the ghost interp"). What it does **not** have is everything the
ghost path grew on top of that shape, which is precisely the part that fixed
the visible player stutter (WO-38 Phase 3). It is wrong to say NPCs "apply
positions as direct overwrites"; it is equally wrong to say they "already
have equivalent smoothing."

Feature-by-feature (all code-read):

| Mechanism | Ghost path (`KCD2MP_InterpTick`, 20 ms tick) | NPC puppet path (`KCD2MP_NpcPuppetTick`, 50 ms tick) |
|---|---|---|
| Packet-velocity estimate | Yes — dt-based, burst-guarded, smoothed 0.5 (`KCD2MP_UpdateGhost` 3311–3335) | **None** — `KCD2MP_ApplyNpcState` stores the raw target only (2333) |
| Dead reckoning / prediction | Yes — projects render target forward up to 60 ms, non-destructive, holds at cap instead of reverting (4510–4538) | **None** — target is always the bare last packet |
| Lerp toward target | 0.5 factor; corrections *against* travel direction damped to 0.15 (the WO-38 anti-rubber-band fix, 4548–4559) | 0.5 fixed, no direction awareness (2529–2537) |
| Rotation | `lerpAngle` shortest-path smoothing (4565) | **Hard snap** — `p.cr = p.tr` (2536) |
| Z | Packet-direct, plus floor raycast snap and airborne detection (4560, 4579–4602) | Packet-direct only (2535) |
| Teleport threshold | >5 m snap (4502) | >5 m snap (2530) — same |
| Velocity reset on target jump | Yes, >5 m (3343–3346) | n/a (no velocity exists) |
| Inbound cadence | ~20 ms requested (`ClientConfig.EmitIntervalMs = 20`, dotnet/KcdMp.Client/ClientConfig.cs:71), delivered bursty 60–130 ms warm (WO-30, observed) | **250 ms** emit (`npcSync.emitMs`, 1856) gated on 0.05 m movement eps (2268–2273) |

The consequence of the missing half (derived, not watched): with a 4 Hz
stream and a 0.5-per-50 ms lerp, the puppet covers ~97% of each packet gap
within the 5 ticks before the next packet arrives. A continuously walking
NPC therefore renders as one ease-out dash per packet — fast start, settle,
wait, dash — rather than continuous motion. This is exactly the artifact
class the ghost path's dead reckoning was built to erase, and the ghost
history proves the bare snap-vs-lerp shape was not enough for players
(WO-38 Phase 3's "two steps forward, one step back" and the burst-packet
velocity oscillation were both bugs *in* that bare shape).

Honesty note: no footage of an NPC puppet walking was reviewed this
session. WO-40's recorded complaints (wagon worker phasing between three
points) were about competing writers — the authority problem — not about
gap-dashing. The dash characterization is derived from the math above.

---

## Phase 2 — design, and the honest nuance

### 2.1 Design: port the proven ghost pieces

All four pieces are existing, live-verified ghost code; nothing new is
invented. Receiver-side only — no wire change, no topology change (so no
conflict with the WO-51 architecture constraints).

1. **Velocity estimate in `KCD2MP_ApplyNpcState`** — the `UpdateGhost`
   dt-based estimator verbatim (burst guard `dt > 0.005`, smoothing 0.5),
   plus its jump reset, tightened to >2 m for puppets. The jump reset also
   covers a claim-handoff discontinuity: when authority for an NPC migrates
   between two diverged worlds, the stream's position can step; a velocity
   spike from that step must not feed prediction. (Whether the 0x27
   down-path exposes the sender identity to key a reset on was not checked
   this session — inconclusive; the geometric reset needs no sender info
   and covers the same event.)
2. **Dead reckoning in `KCD2MP_NpcPuppetTick`** — the non-destructive
   project-and-hold (4510–4538). One real scaling decision: the ghost DR
   cap is 60 ms because its packet gap is ~50 ms; a full 250 ms cap for
   NPCs means up to ~1.5 m of pure guess at run speed, with overshoot on
   every direction change (rendered as a damped backward correction).
   Recommended: cap at ~150 ms (3 puppet ticks), accepting a residual
   ease-out tail, **optionally** paired with a moving-only cadence raise
   (`emitMs` 250 → ~100 while `moved` is true; idle NPCs already emit
   nothing but heartbeat, 2268–2273, so idle cost is unchanged). The ghost
   stream runs at 20 ms for one entity; five puppets at 10 Hz is well
   inside demonstrated channel capacity — but the cadence raise is an
   emitter/wire change, so it is the one piece that isn't a pure
   receiver-side port.
3. **Backward-correction damping** — factor 0.15 against the direction of
   travel (4548–4555), verbatim.
4. **`lerpAngle` for rotation** — replacing the hard snap at 2536. Cheapest
   win of the four; a 4 Hz rotation snap is a visible head-yank on any
   turning NPC (derived).

Deliberately **not** ported: the floor raycast / airborne machinery.
Puppeted NPCs are authored world entities standing on terrain identical on
both machines, Z already tracks the packet directly, and no hovering/sinking
symptom has been reported on this channel. Raycasts for up to 5 puppets ×
20 Hz is new per-tick cost with no observed symptom to pay for. Revisit only
on evidence.

Also untouched: every existing puppet special case — corpse one-shot
placement, carried-body follow, swing-cue one-shot pin, drawn-state
re-assert (2429–2499) — already bypasses the lerp path and stays as is.

### 2.2 The nuance: does smoothing help or hurt when the brain fights the stream?

Structural fact first (code-read): the puppet lerp integrates its **own
bookkeeping** (`p.cx`), never reading the entity's actual position back
into the render path — the only readback is the WO-40 fight diagnostic
(2507–2525), which is measurement, not control. So the local brain's
counter-motion lives entirely in the 50 ms windows between our writes and
is stomped by the next write *regardless of how that write's target was
computed*. Interpolation changes the trajectory of our writes; it does not
change the amplitude or frequency of the fight. The two are mechanically
orthogonal in this codebase.

**Steady-state, correctly tracked** (one stable claimant, packets flowing):
the fight contributes sub-window jitter around whatever path we write;
observed evidence says the stream wins outright at this cadence ("A
continuous 50 ms write stream WINS completely — the NPC tracked", 1825,
observed WO-32/40). Smoothing the macro path cannot worsen that jitter and
removes the 4 Hz dashing. Verdict: better, with no identified downside
beyond §2.3's latency.

**Boundary-flapping** (claim bouncing between two senders whose worlds have
diverged): the stream itself alternates between two truths. Lerp renders
each alternation as a fast glide between attractors instead of a snap; with
DR on top, each alternation also whipsaws the velocity estimate. A gliding,
direction-reversing NPC arguably reads as *more* wrong than a clean snap —
it looks possessed rather than laggy (derived; no flap footage was reviewed
with this question in mind). The honest conclusion: interpolation cannot
fix flap and mildly worsens its legibility. But this is exactly the failure
WO-60's engagement hold was built to remove at the source (claims cannot
flap mid-fight, 15 s hold — wire-verified, T17–T20), and the >2 m velocity
reset from §2.1 keeps DR from amplifying whatever residual steps remain.
Smoothing over authority instability is the wrong fix for it; removing the
instability is, and that work is already shipped.

### 2.3 The always-paid cost: rendered position lags truth

Real and unavoidable: an exponential lerp renders ~1 time-constant behind
its target (~50–100 ms at 0.5-per-50 ms), and DR claws some of that back by
looking ahead. Both numbers are small against the error this channel
already carries — a 250 ms emit cadence plus 60–130 ms bursty delivery
means the local copy is *already* up to ~400 ms behind the authority's
truth before any smoothing exists. Smoothing redistributes that error over
time; it does not meaningfully grow it.

Does it matter for combat? **No regression is possible in hit detection**
(code-read): damage on this channel is name-addressed and resolved against
the *local* copy (WO-40, 0x30/0x31) — the rendered puppet *is* the local
hitbox, so a local player's melee connects against exactly the pose they
see, smoothed or not. The cross-world disagreement (authority sees the NPC
elsewhere) is cadence-dominated, not smoothing-dominated. A smoother-moving
target is if anything easier for the attacking player's target lock to
track (derived). Verdict: the latency trade is real but cosmetic-dominant
on this channel.

---

## Phase 3 — the comparison, answered directly

### 3.1 Does the "different layers" hypothesis hold?

**Yes, with one correction to its premise.** The premise "NPCs still apply
positions as direct overwrites" is false — the snap-vs-lerp core was copied
when the puppet tick was built. What is missing is the prediction/velocity
layer and the WO-38 refinements, i.e. the half that actually cured player
stutter. The layering itself is confirmed by the code:

- Authority (WO-60) governs **which stream exists and whether it is
  stable** — claim selection, flap suppression, silence handling. Its
  failure modes are target discontinuities and gaps. No receiver-side
  smoothing fixes those, and §2.2 shows smoothing makes flap *less*
  legible, not more.
- Interpolation governs **how a given stable stream renders** — gap
  coverage between packets. Its failure mode (4 Hz ease-out dashing) exists
  even under a perfectly stable, perfectly authoritative stream, and no
  authority improvement can touch it: authority decides *whose* 4 Hz
  packets arrive, not what happens in the 250 ms between them.

They intersect at exactly one point: DR consumes stream velocity, so
authority instability poisons prediction. That is an ordering dependency,
not a conflict — and it is handled by the jump reset regardless.

### 3.2 Recommendation (direct)

**Build both; they are not in tension. Authority first — and it already
is.** Specifically:

1. **Live-verify WO-60 before touching the puppet renderer.** It is shipped
   but wire-verified only (no live session yet). This ordering is not
   ceremony: an interp upgrade landed before claim stability is confirmed
   would smooth over any remaining authority artifacts, turning a
   diagnosable snap-between-attractors into an ambiguous wobble and
   contaminating the very footage needed to judge WO-60. The fight-report
   diagnostic (`KCD2MP_NpcFightReport`) stays valid either way, but visual
   triage does not.
2. **Then port the four ghost pieces** (§2.1, items 1–4) as a small,
   receiver-only change reusing live-verified code. Expected visible win:
   walking/fighting puppets glide instead of dashing 4×/s, and turning
   puppets stop head-yanking.
3. **Hold the cadence raise** (the only wire-side piece) until the ported
   interp has been watched live — DR at a 150 ms cap may be enough on its
   own, and the cheaper change should get to fail first.

What would falsify this plan: if WO-60's live session shows claims still
flapping mid-fight, fix that at the authority layer before any of the
above — per §2.2, interpolation on top of a flapping stream is lipstick on
the wrong pig.
