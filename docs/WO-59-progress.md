# WO-59 — progress

## 2026-08-26 — full session

Nine post-0.17.5 reports investigated as five threads; grouped items checked
for shared causes before any fix, per the WO.

**Evidence baseline established first**: no post-WO-58 tester logs exist on
this machine (full-tree + Desktop/Downloads sweep) — everything this session
concluded is code-anchored or synthetic-wire-anchored and labelled as such.
0.17.5 confirmed to have shipped all WO-58 fixes as one matched set.

**Thread A (tracking/authority)**: jitter (A1) left open between two known
mechanisms — restart-cascade release/resnap vs. WO-38's boundary-flapping
oscillator — the latter fixed by rescan hysteresis (exit radius 1.5×, 8 m
sticky bonus). Clothing asymmetry (A2) root-caused twice: the host-outbound
interference the WO pointed at is WO-54 §5.1's local REST timeouts, whose
partial reads went out as real outfit changes (fixed: failed-half ⇒ null ⇒
skip); and a WO-58 regression shipped in 0.17.5 — a timed-out final verify
read mass-blacklisted whole item batches per ghost lifetime (fixed: failed
reads prove nothing + 10 min blacklist TTL). One-sided combat (A3) is the
documented WO-51 radius/cue design gap, not a new bug. **Design verdict
delivered as asked**: the host-centred tracking model should change to
per-NPC proximity/engagement authority via the existing claim table
(WO-51 option 2 shape); not implemented blind this session — next
two-human session should run WO-A's measurements and a prototype together.

**Thread B (reload/time)**: day/night desync root-caused — no aliasing bug;
there was simply **no connect-time clock exchange at all** and applies are
forward-only, so un-slept sessions never converged. Fixed the general case:
`TimeSkipPhaseSync` (0x28 phase 3) announced at connect + on new peer,
relayed done-quiet, forward-only apply, >1 h jumps get one neutral message.
Wire-verified against a live relay (new T5b; suite 29/29). The invisibility
mystery got two mechanisms: change-gated positions with no heartbeat (fixed:
2 s heartbeat) and Reconcile accepting a save-embedded imposter body because
the name still resolved (fixed: entity-identity comparison). Shared-cause
verdict: same trigger class as WO-58's gender fix (reload carries state the
trigger points never see), three distinct defects, one reload fires all —
which is why the WO-38 Section G report contained both symptoms at once.

**Thread C (ghost crime witness)**: SetIgnorant was applied once at spawn
with the result discarded and never re-asserted; crime-witness coverage was
always documented untested (WO-32 §1f; WO-36 never ran). Fixed the closable
half (spawn-result logging + 2.5 s re-assert with failure logging) and made
the open half decidable from the next field bundle. The silent kill is the
known WO-39 render gap (brain attacks deal real damage, animations stomped;
the native swing path is wire-triggered only); the bark is the donor soul's
authored voice. No patch-scale fix exists for the render gap — WO-51
option 3 territory.

**Thread D (FPS)**: undeterminable — no logs exist; the "alt-tab base-game
issue" is not documented anywhere in-repo (recorded as prompt-sourced,
unconfirmed). Shipped a `tickstat` frame-rate-floor sampler in the emit tick
(SetTimer is frame-quantized, so degraded tick deltas ARE the frame time)
so the next report carries numbers in the bundle.

**Thread E (chickens)**: confirmed working as designed — the sync filter is
exactly `NPC`/`NPC_Female`/`Horse`; animals never in scope; tester note
added.

Builds clean (both solutions); Farkle 59/59; Test-TimeSkipRelay 29/29
including the new sync-phase case. No VERSION change. Lua changes inert
until the pak is rebuilt; agent/relay changes need a matched-set publish.

Full detail: `docs/WO-59-findings.md`.
