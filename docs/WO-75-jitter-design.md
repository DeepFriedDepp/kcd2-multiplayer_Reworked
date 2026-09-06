# WO-75 — NPC puppet jitter: independent design investigation (Part 2)

Design document. **No code was written for this fix.** Evidence tiers as in
Part 1: (observed) · (code-verified at `8e836c5`) · (read-but-unrendered) ·
(inconclusive). Field data from the pending two-machine session does not exist
yet; WO-69's numbers are single-machine and are used as such.

Required reading was read directly, not from summaries: `WO-63-findings.md`,
`WO-64-findings.md` Phase 1, `WO-69-findings.md`, and the puppet/ghost ticks in
`kdcmp.lua` (`KCD2MP_NpcSyncTick`, `KCD2MP_ApplyNpcState`,
`KCD2MP_NpcPuppetTick`, `KCD2MP_UpdateGhost`, `KCD2MP_InterpTick`,
`KCD2MP_InterpPump`, `tickAlive`), plus the agent hops those packets cross
(`GameBridge.cs` receive loop and position loop, `HttpGameTransport.cs`
batching, `LogTailGameTransport.cs` tail).

---

## 1. Where this agrees with the inherited plan

- **D1 is real and is the dominant *steady-state* term.** (code-verified)
  `emitMs = 250`, apply tick 50 ms, first-order lerp 0.5 with no velocity or
  prediction: rendered per-tick speed decays `10·D·0.5^k` inside every packet
  gap. WO-69's term-for-term match against the field anim log (observed by
  WO-69) is the right reading. Nothing here re-argues it.
- **Authority and presentation are different layers** (WO-63 §3.1). A stable
  stream still dashes; an unstable stream cannot be fixed by smoothing. Agreed.
- **The WO-63 ordering gate protects real evidence.** Raw footage of WO-60
  under load is worth more than one release cycle. Agreed on intent; §6
  proposes a way to honour it without serialising.
- **All seven WO-70 constraints are earned and are kept** (§5), with one
  re-grading (constraint 6's send-side half) that is an evidence statement,
  not a relaxation.
- **Latency of the puppet stream is cosmetic-dominant** (WO-63 §2.3): damage is
  name-addressed against the local copy, so the rendered puppet is the hitbox.
  Agreed — and it is the property that makes §4's recommendation safe.

## 2. What the material shows that the inherited frame did not weigh

### 2.1 The delivery path, hop by hop, with the numbers that exist

(code-verified unless tagged)

| hop | mechanism | cadence / cost |
|---|---|---|
| Lua emitter | `Script.SetTimer(250, KCD2MP_NpcSyncTick)`; per NPC: `moved > 0.05 m` or hp/flag change or 2 s heartbeat; timer fires on frames so ≥250 ms | 4 Hz nominal per moving NPC |
| game → agent | `System.LogAlways` writes an EVT line to `kcd.log`; agent tails with a 5 ms poll | sub-frame; buffered by the game's log writer (WO-40 read) |
| agent → relay | one 0x26 per EVT line, no coalescing | ~37 B |
| relay | route (claim gates) then fan-out; `NpcStateDown` is not coalesced by PR #1's queue (only `Ghost` is) | RTT p50 16 ms in WO-69's field data (observed by WO-69) |
| receiving agent → Lua | one `KCD2MP_ApplyNpcState(...)` statement appended to the batch; **flushed once per position-loop iteration**, which awaits the HTTP round trip | loop ≈ 10 ms delay + read + RTT |
| `ExecuteString` round trip | measured in the field by the interp pump's own rate line | **~18 ms p50** (observed, n=56; §0 of Part 1) — not the 60–130 ms WO-30/38/63 carry |
| Lua apply | target overwritten; render tick 50 ms | arrival jitter on a 250 ms period ≈ ±40 ms |

Two consequences the plan did not have:

- **Delivery latency is ~40–60 ms, not ~150–400 ms.** WO-63 §2.3's "already up
  to ~400 ms behind" rested on WO-30's PowerShell-measured RTT. The puppet's
  age at render is dominated by the 250 ms emit period itself. That moves the
  lever: the emit period is the latency budget, the renderer is the smoothness
  budget, and they can be designed separately.
- **Ghost "bursts" are explained, and puppets do not get them.** Ghost packets
  arrive at 20–45 Hz (observed emitter rate 41–45 lines/s; 5 cm change gate),
  and the receiver flushes every ~28 ms, so two ghost packets often land in one
  batch and reach Lua microseconds apart — WO-38's burst-guard case. A 4 Hz
  puppet stream never does this unless the *sender* is duplicated. So the
  ghost path's burst-guarded velocity estimator was built for a regime the
  puppet stream is not in.

### 2.2 The ghost path is tuned for a ~30 Hz stream and its DR reaches 60 ms

(code-verified) `DR_MAX = 3` ticks × 20 ms = 60 ms lookahead; factor 0.5 per
20 ms; velocity from arrival `dt` with a burst guard. WO-63 §2.1 already saw
the mismatch — a 250 ms gap needs ~250 ms of prediction — and proposed capping
DR at 150 ms "accepting a residual ease-out tail". That is the inherited plan
conceding it will not remove the artifact, only shrink it. At 4 Hz,
**extrapolation is the wrong tool**: it must guess a quarter-second ahead from a
velocity measured over a jittered quarter-second, and it overshoots by up to
one period of travel at every stop or turn.

### 2.3 The textbook shape for a low-rate stream is interpolation-behind, not extrapolation

Render the puppet at `now − delay` along the segment between the two most
recent samples, with `delay ≈ 1.2 × period`. Speed along a segment is
`|P_n − P_{n-1}| / segmentDuration` — **constant**, so the rendered velocity
never modulates and the anim tag derived from it never churns. There is no
velocity estimator to get wrong, no overshoot, no direction damping to tune.
The cost is a fixed ~300 ms of added lag at 4 Hz, which §1 already grades as
cosmetic on this channel.

External precedent (read-but-unrendered, WO-64 Phase 1 source-read of
KCD2Online `client.cpp`): snapshot history, adaptive delay `1000/rate + 10 ms`,
lerp between samples, ≤60 ms extrapolation past the newest, 5 m snap. Same
shape. Not observed running here.

### 2.4 Is 4 Hz a constraint or a choice?

(code-verified) It is a Lua literal (`kdcmp.lua:1861`), set in WO-32 with the
comment "position lerp on the receiver smooths the gaps, same as ghost
interp" — i.e. chosen on the belief the receiver would hide it. Not
configurable at runtime; no console command; changing it is a pak rebuild.
WO-32's cost model at the 5-NPC/30 m cap: worst case 20 pkt/s ≈ 740 B/s per
direction. Raising to 10 Hz:

- wire: 50 pkt/s ≈ 1.9 KB/s up, ×(N−1) fan-out — still under one player's
  position stream (WO-32's own comparison);
- sender: ~8 engine reads per NPC per tick → 400/s at 5 NPCs, plus 50
  `kcd.log` lines/s on top of the emitter's ~43/s (doubles mod log volume;
  WO-39's log-volume caution was about the *receiver's* per-packet `mp_log`,
  which stays off);
- receiver channel: statements ride the existing per-tick flush; `MaxBatchChars`
  4000 is never approached; **zero extra round trips** ("payload is free",
  WO-1 measured);
- Lua apply: 50 `GetEntityByName` + table writes per second — noise.

So 4 Hz is a tunable whose cost at the current cap is negligible on every hop.
The "busiest channel" objection does not bind: the channel charges per batch,
not per statement. What a raise buys under §2.3 is *latency* (delay shrinks
from ~300 to ~120 ms), not smoothness. Adaptive cadence keyed on the existing
engaged bit (flag 32) is cheap to add later; it is not needed for the jitter.

### 2.5 D3 is a general mechanism, and a structural fix exists that needs no confirmation

(code-verified) `tickAlive` calls a chain dead when its stamp is older than
1.0 s. A local menu suspends every `Script.SetTimer` (WO-12/13 observed) but
`ExecuteString` keeps executing. The agent re-arms `StartInterp`,
`StartEmitter`, `StartNpcSync`, `StartItemSync` every **2.5 s** (PR #1 made
this wall-clock; against the committed logs' ~20 ms loop the previous effective
period was ~5 s, so PR #1 doubled the re-arm rate). Each re-arm during a menu
longer than ~1 s starts a second chain; on menu close every suspended chain
resumes alongside the new ones. The puppet chain has a second entry:
`KCD2MP_ApplyNpcState → StartNpcPuppet` on every inbound packet. WO-69's
gen-token instrument covers the puppet chain only.

Evidence status:
- (observed, WO-69's bundle) 114 `puppet tick started` vs 39 `stopped`, runs
  of up to nine starts with no stop.
- (read-but-unrendered, WO-54 live notes) "timer chains being restarted on
  every menu close, not just resumed — not diagnosed further".
- (observed, this session) The WO-58 bundles show exactly one interp chain
  (heartbeat every 5.3–6.6 s, no acceleration) and exactly one `Interp tick
  started` — and **zero menu opens**, so they neither confirm nor refute the
  mechanism; they confirm the single-chain baseline the mechanism departs from.
- (inconclusive) Two chains alive at once has never been directly observed.

Because every tick advances by a **fixed per-tick factor** (0.5 lerp, `ticks ×
0.020` DR), N chains multiply the advance N-fold per 50 ms — WO-69's "near-
instant snap then a wait". A **time-based tick** — advance by real elapsed
`os.clock()` since the last write, not by "one tick" — makes a second chain a
no-op (it sees ~0 elapsed). This fixes D3 for the puppet path structurally,
also fixes the menu pump's rate mismatch (pump runs at 22 Hz against math
assuming 20 Hz), and does not depend on proving the leak first. The WO-69
instrument stays as the proof, `mp_npc_chainfix` stays as the hygiene switch.

The same mechanism reaches the **ghost** interp chain. Prediction for the
field session, testable from existing log lines with no new code: after a
menu of ≥3.5 s, `Interp tick started` increments and the `TICK_ALIVE`
interval (timestamped by the nearest `[KCD2-MP-DATA]` line's `os.clock`)
shrinks by the chain count. Recipe in `WO-75-progress.md`. If confirmed,
that is a ghost-jitter source nobody has named: it would grow with every menu
and reset only on a save load. Fix shape is the same (time-based advance);
ghost path changes stay out of this design per constraint 1.

### 2.6 The send-side "same shape" attribution does not survive the emitter's gate

(code-verified) In `KCD2MP_NpcSyncTick`, the emit is gated by `moved` (>5 cm
since `t.lastX/Y/Z`), `hpChanged`, `heartbeat` (≥2 s since `t.lastSentAt`),
`koChanged`, `drawnChanged`, `engagedChanged`, `swingCue`, or first death —
and every one of those `t.*` fields is updated in the same statement block
after the emit. Two leaked chains firing in the **same frame** share `t`: the
second sees `moved=false`, `heartbeat=false`, every `*Changed=false`, and
`swingCue=false` (the `_npcSyncPrevPlayerHp` edge was consumed by the first).
It cannot emit. A chain leak therefore produces *interleaved distinct*
coordinates at up to N×4 Hz for a moving NPC — never byte-identical
same-frame pairs. WO-69's "12,412/12,412 consecutive same-NPC pairs inside one
frame carrying byte-identical coordinates" is not that mechanism.

(observed) The pre-WO-60 `npc_state` path shows 0 duplicates in 2,231 lines
across the WO-58 bundles. (inconclusive) The mechanism behind WO-69's
`npc_claim` shape is not derivable from current code; candidates examined and
found *not* to duplicate: the agent's single `GameEvent` subscription
(`SelectTransportAsync` runs once per process), the tail's whole-line
consumption, the relay's single `EnqueueNpcState` per target. What remains is
either something in that bundle's environment (a second agent process on the
same `kcd.log`, which WO-27 observed once before) or a path this session did
not find. **Design consequence:** do not build a send-side "chain fix" against
a mechanism the code says cannot produce the observed shape; capture the raw
EVT lines with their `seq` field in the field session and characterise the
duplication first. Constraint 6's receive-side half stands; its send-side
half is re-graded from "probable" to "unexplained".

### 2.7 Animation churn is separable from position smoothing

(code-verified) The puppet's anim tag is recomputed every 50 ms from the
per-tick rendered displacement (`spd = |Δ|·0.5/0.05`) with **no hysteresis**
(the ghost path has `calcAnimTag` with up/down bands and a 0.4 smoothed speed;
the puppet path inlines raw thresholds). Even with positions still dashing,
deriving the tag from the segment speed with the ghost's hysteresis kills the
`run→walk→idle` cycle on its own. This is the cheapest visible win and it is
constraint 3 done deliberately rather than as a side effect.

## 3. Where this refines or disagrees with the inherited plan

| inherited | this design | grade |
|---|---|---|
| Port the ghost velocity estimator + DR (cap ~150 ms) + direction damping onto the puppet tick | **Disagree on tool, agree on layer.** Replace the puppet's exponential lerp with snapshot interpolation-behind (§2.3). No velocity estimator, no DR, no damping. The ghost pieces stay where they are. | code-verified arithmetic (§2.2) + read precedent (§2.3); not observed |
| "Hold the cadence raise until the ported interp has been watched live — the cheaper change should fail first" | **Refine.** The receiver change is the one that fixes smoothness; the cadence raise fixes latency and costs nothing measurable at the cap (§2.4). Keep the order (receiver first) but for the right reason: one variable at a time in the footage, not cost. | code-verified |
| D3: confirm with the instrument, then fix behind `mp_npc_chainfix` | **Refine.** Keep the instrument; add the structural fix (time-based advance) that is correct whether or not the leak fires, and note the mechanism reaches every re-armed chain (§2.5). | code-verified mechanism; leak itself inconclusive |
| Send-side duplication "same mechanism, same fix shape" | **Disagree.** The `moved` gate rules the chain-leak mechanism out for the observed shape (§2.6). Characterise before fixing. | code-verified negative; shape's cause inconclusive |
| Delivery is bursty 60–130 ms and adds to puppet lag | **Correct the premise.** In-process RTT ≈ 18 ms observed; puppet lag is the 250 ms period. Conclusion (cosmetic) unchanged. | observed (committed logs) |
| Run the D1-vs-D2 discriminator first (`Test-NpcSyncE2E` Phase 3 + `AI.SetIgnorant`) | **Agree, with a fix-first.** Phase 2 of that script asserts pre-WO-39 relay behaviour and now fails (Part 1 §5); skip or repair it before Phase 3 is trusted. | code-verified |
| D2, if it dominates, makes the interp port "the wrong lever" | **Refine.** D2 lives *between* our writes and is invisible to a bookkeeping-based renderer whichever shape it has (WO-63 §2.2 is right). Interpolation-behind does not worsen D2 and its lag does not feed it. If D2 dominates, suppression is *additional*, not *instead*. | code-verified structure |

## 4. The design

Receiver-side, Lua only, puppet path only, no wire change in step 1. Every
step is independently shippable and independently observable.

### Step 0 — prerequisites (already shipped, nothing to build)
- Field session captures: `NPC-SYNC packet cadence` lines, any
  `CHAIN LEAK CONFIRMED`, `NPC-FIGHT` displacement lines, raw `[KCD2-MP-EVT]`
  lines with `seq`, and the `TICK_ALIVE`/`Interp tick started` recipe (progress
  doc). Both machines, whole session (WO-60's tester ask, still unmet).
- WO-60 raw footage of a claimed NPC under two-player pressure (the WO-63 gate).

### Step 1 — puppet renderer: time-based snapshot interpolation
In `KCD2MP_ApplyNpcState` (per puppet `p`):
- keep a 3-deep ring of samples `{x,y,z,rot,at=os.clock()}`; on push, if the
  XY step from the previous sample exceeds 5 m keep the existing snap
  behaviour (clear the ring, set `cx/cy/cz/cr` to the packet);
- do **not** compute velocity.

In `KCD2MP_NpcPuppetTick` live-puppet branch (dead/KO/carried/one-shot branches
unchanged):
- `renderAt = now − DELAY`, `DELAY = 0.30` s (1.2 × nominal period; tunable
  constant next to `emitMs`, documented as coupled to it);
- find samples `a,b` with `a.at ≤ renderAt ≤ b.at`; `t = (renderAt − a.at) /
  max(b.at − a.at, 0.05)`; if `renderAt > newest.at` hold at newest (no
  extrapolation past the newest sample — an NPC that stopped emitting has
  stopped moving, by the `moved` gate);
- segment duration for the **speed** is `min(b.at − a.at, 0.30)` so a packet
  arriving after a `moved`-gated silence does not slide slowly (§2.3);
- `cx,cy = lerp(a,b,t)`; `cz = b.z` (packet-direct, as now); `cr =
  lerpAngle(a.rot, b.rot, t)` (replacing the per-tick 0.5 yaw lerp WO-69 landed
  with the same helper on a time base);
- **time-based advance**: nothing here depends on "one tick"; a second chain or
  a fast pump computes the same `renderAt` and writes the same position. This
  is the D3 fix (§2.5). Keep `KCD2MP._npcPuppetPumpAt` throttling as is.
- `spd = |b − a| / segmentDuration` (constant along the segment); anim tag via
  a copy of the ghost `calcAnimTag` hysteresis (copied, not shared — constraint
  1), horse gaits unchanged.
- Write `p.lastWroteX/Y` as now so the `NPC-FIGHT` diagnostic keeps working;
  never read `GetWorldPos()` into the render path (constraint 4).

Gate: `mp_npc_smooth on|off`, **default off** in the first build so the field
session films raw first, then flips live for the A/B (the WO-69
`mp_npc_chainfix` pattern). Default on only after the gate footage exists.

Expected visible result: continuous motion at the NPC's true average speed,
~300 ms behind truth, no periodic anim churn, immune to chain count. Expected
cost: two `os.clock()` reads and one ring walk per puppet per tick.

### Step 2 — emit cadence (wire-side, one literal, deferred until Step 1 is filmed)
- `emitMs 250 → 100` for NPCs that `moved`; idle NPCs still cost only the
  heartbeat. Optionally per-NPC: `100` while flag 32 (engaged) or within 12 m
  of the local player, `250` otherwise — the tick runs at 100 ms and gates
  per NPC on `now − t.lastSentAt`.
- Adjust `DELAY` to 1.2 × the new period (120 ms). Nothing else changes;
  interpolation-behind is rate-agnostic.
- Why after Step 1: so the footage isolates one variable, and because Step 1
  alone should already remove the reported symptom. The cost argument for
  holding it (WO-63) is withdrawn; the sequencing argument stands.

### Step 3 — D2, on the discriminator's verdict (separate track)
- Fix/skip `Test-NpcSyncE2E` Phase 2, run Phase 3 with and without
  `AI.SetIgnorant`, read `NPC-FIGHT` lines in the field.
- If displacement between writes is large: the `Activate(false)` pilot (WO-64
  WO-E, WO-67's five vtable hypotheses, verify-first on our build). Step 1 is
  unaffected either way; it neither hides nor amplifies D2.

### Step 4 — housekeeping that falls out of the analysis (not part of the fix)
- Fix `raw_vx` at `kdcmp.lua:3589` (Part 1 §3) so ghost `pkt#` lines exist in
  the next bundle.
- Consider stamping `_interpAliveAt`/`_npcPuppetAliveAt` from the pump while a
  local menu is open, so re-arms during menus stop minting chains at the
  source. WO-13's reason for not stamping (a dead chain must not look alive)
  is satisfied because the pump stops when the menu closes. Cheap, but it is
  a ghost-path touch — separate change, separate verification.

## 5. The seven WO-70 constraints, one by one

1. **Copy the math, do not share a helper with the ghost path.** Kept. Step 1
   copies `lerpAngle`'s use and `calcAnimTag`'s bands into the puppet block;
   nothing in `KCD2MP_InterpTick`/`KCD2MP_UpdateGhost` changes.
2. **Re-derive `spd` in the same change.** Kept and made the point: `spd`
   becomes segment speed with hysteresis in the same edit as the position
   change; every threshold re-tunes deliberately.
3. **Never derive velocity from `GetWorldPos()` readback.** Kept. No velocity
   exists; render state is bookkeeping only; readback stays diagnostic.
4. **Do not port the floor raycast.** Kept. `getFloorZ` is declared after the
   puppet tick and would bind nil; Z stays packet-direct.
5. **Fix the chain leak and instrument before tuning.** Kept in substance;
   the instrument is shipped and stays; the fix becomes structural (time-based
   advance) so it is correct before confirmation. No numeric tuning in Step 1
   depends on a cadence figure except `DELAY`, which is set from the *nominal*
   period and is safe on either side of ±40 ms.
6. **Same for the send side.** Re-graded, not relaxed: the receive-side leak
   mechanism is code-verified; the send-side "same mechanism" claim is
   code-verified *not* to produce the observed shape (§2.6). Instrument first
   still applies — with the specific instruction to preserve raw EVT `seq`.
7. **Run the D1-vs-D2 discriminator before investing in the port.** Kept, with
   the Phase 2 repair noted. The recommended Step 1 is smaller than the port
   it replaces, so the discriminator's outcome changes Step 3, not Step 1.

## 6. What this design does not resolve, and what would decide it

- **Whether interpolation-behind reads better than DR to a human.** The
  arithmetic says so; nobody has watched either on a puppet. The field session
  with `mp_npc_smooth` flipped live is the decider. Fallback if it reads worse:
  the inherited DR port at Step 2's 10 Hz, where it is in the ghost path's
  proven regime.
- **Whether D3 fires at all**, and on which chains. Deciders: `CHAIN LEAK
  CONFIRMED` (puppet), and the `TICK_ALIVE`-interval recipe (ghost). Step 1
  is correct either way.
- **The cause of WO-69's send-side duplication.** Decider: raw EVT lines with
  `seq`, both machines, plus the relay's `[WO66-REJECT] stale-owner` count for
  that session (a second agent on one `kcd.log` would show there).
- **D2's magnitude.** Decider: `NPC-FIGHT` lines at the WO-69 5 cm threshold
  plus the Phase 3 discriminator.
- **Whether WO-60 claims flap under real two-player pressure** — the WO-63
  gate's own question. Decider: raw footage, `NPC-SYNC tracking/untracking`
  churn, relay claim lines. Nothing in this design touches it.
- **The WO-32 vs WO-39 release behaviour** (engine re-anchors within 3 s vs
  did not re-anchor). Affects the release/resnap oscillator, not Step 1.
  Decider: watch a puppet after its stream goes silent, both worlds.

**Explicit confirmation.** No code was written for this fix. The WO-63 gate —
live-verify WO-60 raw before shipping any puppet presentation change — is not
bypassed by this session existing: Step 1 is specified to ship **default-off**
so the raw footage is filmed first; flipping the default is a decision gated
on that footage, and it is the maintainer's.
