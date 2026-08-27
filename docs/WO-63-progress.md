# WO-63 — progress

## 2026-08-27 — full session (design only, no code)

Question: did NPC sync ever get the ghost interpolation treatment, and how
does that relate to WO-60's proximity authority?

**Phase 1 answer: partial.** The puppet tick copied the ghost's
snap-vs-lerp core (its own comment says so, kdcmp.lua:2527) but none of the
layer that actually cured player stutter: no velocity estimate, no dead
reckoning, rotation hard-snaps, no backward-correction damping — all
code-read this session, cited line-by-line in the findings. Combined with
the 250 ms emit cadence (vs the ghost's 20 ms request), a walking puppet
mathematically renders as one ease-out dash per packet (derived — no
footage reviewed of this specific artifact).

**Phase 2:** design = port four proven ghost pieces receiver-side
(velocity estimate + jump reset, DR capped ~150 ms, backward damping,
lerpAngle); skip the floor raycast (no observed symptom to pay for).
Nuance investigated honestly: the puppet lerp integrates its own
bookkeeping and never reads the entity back, so the brain-fight is
mechanically orthogonal to smoothing — steady-state smoothing is a clean
win, but under claim flap smoothing makes the failure *less* legible
(gliding possessed-looking NPC vs a clean snap). Latency cost is real but
cosmetic-dominant: damage is name-addressed against the local copy, so hit
detection cannot regress.

**Phase 3 verdict:** the "different layers" hypothesis holds (with the
premise corrected — interp isn't wholly absent). Authority decides whether
a stable stream exists; interpolation decides how a stable stream renders;
they meet only at DR's velocity input, handled by the jump reset.
Recommendation: build both, in order — live-verify WO-60 first (still
wire-verified only), then the interp port, cadence raise held back as a
separate wire-side lever.

Output: docs/WO-63-findings.md. No code, no VERSION change.
