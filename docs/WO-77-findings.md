# WO-77 — NPC puppet jitter fix: WO-75 design Steps 1 and 2, implemented

Implementation session, 2026-09-10. Executes `docs/WO-75-jitter-design.md`
§4 Steps 1 and 2 as specified; nothing in that design is re-derived or
re-argued here. Companion: `docs/WO-77-progress.md`.

Evidence tiers, same discipline as WO-75/WO-76:
**(observed)** seen this session — a command run, a suite executed, a value
printed ·
**(code-verified)** read directly in the source tree ·
**(read-but-unrendered)** stated by a prior doc, not re-checked here ·
**(inconclusive)** the evidence does not settle it.

Privacy: no real IP, hostname, personal name or user-specific path appears
in this document. Working-directory paths are written as `<working
directory>`.

---

## 0. Ground truth (Phase 0)

- (observed) `git pull` on `main`: already up to date at `c91e592` ("WO-76:
  findings and progress docs"), so WO-76's seven commits were present
  before any edit here.
- (observed) `docs/WO-76-findings.md` exists. Its §3 states Phase 3 — the
  D1-vs-D2 discriminator (`Test-NpcSyncE2E.ps1` Phase 3 with and without
  `AI.SetIgnorant`) — was **not run**: no live game, no data gathered, none
  fabricated. **There is no discriminator result to read.** Steps 1 and 2
  proceed regardless, per the design's own reasoning (§3: interpolation-
  behind "does not worsen D2 and its lag does not feed it").
- (code-verified) `tools/Test-NpcSyncE2E.ps1` Phase 2, read directly (lines
  217–229): it asserts the **post-WO-39** behaviour — a non-authority's
  claim on an unclaimed NPC is broadcast and moves the real NPC (`$moved`),
  and a puppet is created (`npcPuppets` count ≠ 0). It no longer asserts
  the pre-WO-39 drop. That matches WO-76 §2 item 1's description of its
  own fix. Whether the *relay* really behaves that way was not executed
  here (needs a live game); the script's assertion is what was checked.
- (observed) `docs/WO-75-jitter-design.md` read in full. Steps 1 and 2 below
  cite it by section.
- (observed) No live game, relay-under-game-load or injector this session:
  everything marked observed below ran against synthetic peers, a
  source-built relay, or a stubbed Lua VM.

---

## 1. Step 1 — the puppet renderer (`kdcmp.lua`)

All in `kdcmp/Data/Scripts/Startup/kdcmp.lua`, puppet path only. The ghost
path (`KCD2MP_InterpTick`, `KCD2MP_UpdateGhost`, `calcAnimTag`,
`KCD2MP_UpdateAnimation`) is untouched; `git diff` confirms no hunk lands in
those functions (observed).

What was built, item by item against the WO-77 spec:

1. **Ring of samples.** `mp_npc_ring_push` keeps a 3-deep ring per puppet
   of `{x,y,z,rot,at=os.clock()}`, pushed from `KCD2MP_ApplyNpcState` after
   the existing `lastPacketAt` stamp. An XY step over 5 m from the previous
   sample clears the ring and jumps `cx/cy/cz/cr` to the packet — the
   pre-WO-77 snap, kept; a teleport is never smoothed.
2. **Render at `now − DELAY`.** `mp_npc_smooth_render` finds the two ring
   samples bracketing `renderAt`, lerps XY and `lerpAngle`s yaw between them
   on that time base, Z packet-direct. Past the newest sample it **holds at
   the newest** — no extrapolation, ever. Before the oldest (a ring that is
   still filling) it holds at the oldest.
3. **Speed segment capped at DELAY.** The segment's effective start is
   `max(a.at, b.at − DELAY)`. Implementation decision, stated: the design
   text (§4 Step 1) names this cap for the *speed* only; here it is applied
   to the position `t` as well, so a packet arriving after a moved-gated
   silence renders as one DELAY-long move at the implied speed **and** the
   anim tag reads that speed — position and speed always describe the same
   segment. Rendering the position over the raw silent gap would instead
   produce a jump to ~90 % of the way followed by a short slide, which is
   the artefact §2.3 exists to avoid. Verified in scenario (f) below.
4. **`spd` is the segment speed**, constant along the segment. The anim tag
   comes from `mp_npc_anim_tag`, a **copy** of the ghost path's `calcAnimTag`
   with copied bands `NPC_ANIM_UP = {1.0, 2.5, 4.0}` / `NPC_ANIM_DOWN =
   {0.4, 1.8, 3.2}` (stance-free). Not a shared helper — WO-70 constraint 1.
   This deliberately changes the puppet's thresholds (old raw: walk 0.3,
   run 3.0, sprint 5.5; new: the ghost's hysteresis bands) — constraint 2,
   re-derive `spd` in the same change. The legacy path keeps the old raw
   thresholds so `mp_npc_smooth off` really is the old renderer. Horse
   gaits are unchanged.
5. **Yaw via `lerpAngle` on the time base**, replacing the WO-69 per-tick
   0.5 factor on the smooth path (the legacy path keeps it).
6. **Time-based advance.** Nothing on the smooth path computes "one tick's
   worth"; every value derives from `os.clock()`. A second chain, a leaked
   chain, or the menu pump's faster cadence recomputes the same `renderAt`
   and writes the same position — the D3 structural fix (design §2.5),
   proven synthetically in scenario (c). `KCD2MP._npcPuppetPumpAt`
   throttling and the WO-69 gen-token instrument are left exactly as they
   were; `mp_npc_chainfix` still works as the hygiene switch.
7. **No `GetWorldPos()` in the render path, no floor raycast.** The only
   entity read added is none: the creation-time `e:GetWorldPos()` the old
   code already made for `cx/cy/cz` now also seeds the ring (see 8). The
   `NPC-FIGHT` diagnostic's readback is unchanged and still compares
   against `p.lastWroteX/Y`, which the smooth path still writes.
8. **Creation seed** (implementation decision, stated): a new puppet's ring
   is seeded with the entity's current position stamped `now − DELAY`, so
   the first packet renders as a DELAY-long slide from where the puppet
   actually is onto the stream rather than a pop. A first packet more than
   5 m away snaps, as before.
9. **Anim hold grace** (implementation decision, stated): while the
   renderer holds at the newest sample because the next packet is merely
   late — jitter past DELAY — the anim keeps the last segment's speed for
   `NPC_SMOOTH_ANIM_GRACE_S = 0.06 s` before reading the hold as a stop.
   Position is unaffected (it holds regardless). Without this, a 130 ms gap
   against a 120 ms delay flicks walk→idle→walk for one tick — the exact
   churn Step 1 exists to remove. Scenario (e) shows holds occurring and
   the anim not churning through them.
10. **Gate:** `mp_npc_smooth on|off` (`KCD2MP_SetNpcSmooth`, registered next
    to `mp_npc_chainfix`), **default ON** — see §3. The ring is pushed
    regardless of the toggle so a live toggle-on has data to render from.
    Off restores the pre-WO-77 lerp verbatim (kept as the `else` branch,
    not re-implemented).

Parsed and loaded in full under a Lua VM with the engine stubbed, 0
swallowed `pcall` errors across every scenario (observed, §5). **Not run in
the game's own Lua VM** — none available. The constructs used (tables,
`table.remove`, `math.sqrt`, `string.format`) all appear elsewhere in the
file already.

## 2. Step 2 — emit cadence

- (code-verified, now) `KCD2MP.npcSync.emitMs` 250 → **100**. The per-NPC
  gate in `KCD2MP_NpcSyncTick` (`moved` > 5 cm, hp/flag change, 2 s
  heartbeat) is untouched, so an idle NPC still costs only the heartbeat.
  The simple global bump, as directed; the adaptive per-NPC variant
  (100 ms engaged/near, 250 ms otherwise) is noted in the config comment as
  a future refinement and **not built**.
- **DELAY is derived, not tuned:** `KCD2MP_NpcSmoothDelayS()` returns
  `emitMs / 1000 × 1.2`, read at call time — 0.120 s at 100 ms. Scenario (d)
  asserts it tracks a changed `emitMs`. The console command logs the
  derived value so a live session can read it back.
- **Unconditional.** The raise is send-side — what this client transmits
  about its own locally-simulated NPCs — and is not behind `mp_npc_smooth`.
  Nothing in the code structure made that awkward; the emitter and the
  renderer never touch each other's state.
- (code-verified) The relay's WO-66 plausibility gate (`MaxSpeedMps` 40 ×
  elapsed + 2 m slack, `appsettings.json`) is unaffected: a 10 Hz stream
  moves less per packet than a 4 Hz one, so it is strictly easier to pass.
- (code-verified) The agent's `npc_state`/`npc_claim` handler
  (`GameBridge.cs` ~3125) has no rate limiter; each EVT line becomes one
  0x26. The design's cost arithmetic (§2.4) is read-but-unrendered here —
  no traffic was measured this session.
- **Sequencing deviation, recorded:** the WO-75 design wanted Step 2
  deferred until Step 1 had been filmed ("one variable at a time"). This
  work order explicitly bundles them; that is the maintainer's call and it
  is followed. Consequence: the first field footage cannot separate the
  renderer's contribution from the cadence's. `mp_npc_smooth off` still
  isolates the renderer live; the cadence has no runtime toggle (a pak
  rebuild, as before).

## 3. Default ON — the override, and what still catches an ownership bug

`mp_npc_smooth` ships **ON**. This overrides the WO-63/WO-75 recommendation
to ship default-off so the field session films the raw renderer first.

Reasoning: two weeks of 0.19.0 being available produced **zero** tester
sessions. The pre-fix jitter is unpleasant enough that nobody voluntarily
generates the very observation the default-off gate required — a circular
dependency the gate could not resolve on its own. Shipping the fix on is a
deliberate trade of one visual detection channel for adoption.

What this change does **not** do: it does not touch the WO-60
claim/ownership system — not the relay's per-entity claim table, not the
engagement hold, not the emitter's `npc_state`/`npc_claim` split. It neither
fixes nor worsens a real ownership bug; it only removes the visual symptom
(a puppet snapping between two senders' positions) that would let a player
notice one by eye.

The system's existing diagnostics remain fully able to catch a real
ownership bug in any future log, and all three are **rendering-independent
and untouched** by this change (code-verified, this session):

| marker | where | what it shows |
|---|---|---|
| `[WO66-REJECT]` | relay log — `ClientSession.cs` (speed / rotation rejects) | a claim holder's update failed plausibility; a second sender fighting for one entity shows up here as stale-owner/speed rejects |
| `GET api/information/npc-validation` | relay HTTP — `InformationController.cs`, counters in `NpcValidationCounters.cs` | the same rejects as lifetime counters, readable without log access |
| `NPC-SYNC tracking` / `NPC-SYNC untracking` | `kcd.log` — `mp_npc_rescan` in `kdcmp.lua` | tracked-set churn on each machine; an entity flapping between machines tracks/untracks repeatedly |

**Recommendation:** any future field logs — however they arrive — get a
quick grep of those three markers before anyone reads the footage.
Additionally still present and rendering-independent: the `NPC-FIGHT`
displacement lines (WO-69 threshold) and `NPC-SYNC CHAIN LEAK CONFIRMED`.

## 4. Step 3 — the priority call

**Undetermined.** No discriminator data exists: WO-76 §3 did not run Phase
3 (no live game), and none was available to this session either. Nothing
here is fabricated or inferred in its place.

What the call would be, once the data exists (so the next reader does not
have to re-derive it):

- If the suppressed-brain NPC is **not meaningfully smoother** than the
  unsuppressed one → D1 (now fixed by Steps 1–2) accounts for the whole
  problem; the native `IEntity::Activate(false)` suppression pilot
  (WO-64/WO-67) can be deprioritised or dropped from the near-term roadmap.
- If it **is meaningfully smoother**, with numbers → D2 is real and
  material; the pilot stays a live priority.

**Recommendation:** run WO-76's Phase 3 (or `Test-NpcSyncE2E.ps1` Phase 3
directly, with and without `AI.SetIgnorant` on the two hand-placed NPCs)
**before scheduling any Step-3 work**. Note that with Steps 1–2 shipped the
test becomes *more* discriminating, not less: the D1 jitter both NPCs used
to share is gone, so any residual difference between them is D2 alone
(reasoning from the design's structure, not an observation). The
`NPC-FIGHT` lines remain the in-field D2 instrument.

Why Step 3 stays unbuilt regardless of the answer: Steps 1 and 2 are
Lua-only — the worst case on a bug is a visual glitch. Step 3 reaches into
compiled engine code to suppress a puppet's AI; a bug in its restore path
can strand an NPC permanently deactivated in a live world — a different
risk class, needing its own session with offset verification on this build
(WO-67 already showed retail offsets are hypotheses here, not facts) and
exhaustive restore-path testing. Urgency informs scheduling, not scope.

## 5. Verification (Phase 2)

### 5.1 Synthetic stream test — `tools/Test-NpcSmoothSynthetic.ps1` (+ `.lua`)

New, alongside `Test-NpcSyncE2E.ps1`. It runs the **real** `kdcmp.lua`
(spliced in unmodified) under MoonSharp — a pure-.NET Lua interpreter,
restored from NuGet on first use (observed: restore + load worked; the
package is a **test-only** dependency, nothing shipped changes) — with
`System`/`Script`/entities stubbed, `os.clock` replaced by a fake clock, and
`pcall` wrapped so anything the mod's own `pcall`s would swallow is
recorded and asserted empty. It then drives `KCD2MP_ApplyNpcState` and
`KCD2MP_NpcPuppetTick` and asserts on what the puppet entity was told to
render.

(observed) **39/39 passed.** Per the WO's four required assertions plus the
extras that fell out of the implementation decisions:

| # | scenario | asserts | result |
|---|---|---|---|
| (a) | steady 1.5 m/s, packets every 100 ms, ticks every 50 ms, 2 s | rendered x == `v·(now − DELAY)` at every tick after warm-up (1e-6); per-tick advance constant (`v·0.05`), no decay inside gaps; exactly 1 anim transition (idle→walk); ≤ 4 `StartAnimation` calls (got 2) | PASS |
| (b) | stream stops at x = 3.0, tick on for 0.5 s | never > 3.0; exactly 3.0 once `renderAt` passes the newest sample; anim settles to idle with one transition | PASS |
| (c) | (a)'s schedule, but 3–4 tick calls per step through the real chain entry, including one with a **stale generation** (a confirmed leaked chain, `mp_npc_chainfix off`) | every write at every step equals (a)'s single-chain write (1e-9); total displacement identical (2.82 vs 2.82); the leak line was logged (instrument intact) | PASS |
| (d) | DELAY derivation | `emitMs == 100`; `KCD2MP_NpcSmoothDelayS() == 0.120`; becomes 0.300 when `emitMs` is set to 250; `KCD2MP_StartNpcSync` schedules the emit tick at 100 ms; `mp_npc_smooth` defaults ON | PASS |
| (e) | 19 arrival gaps between 60 and 170 ms, packets landing *between* ticks | x never moves backwards; never passes the newest sample; hold-at-newest ticks did occur (4 of 42 — the grace path was exercised); exactly 1 anim transition | PASS |
| (f) | idle 1.5 s, then one packet 0.4 m away | x = 0 / 0.1667 / 0.3333 / 0.4 at +0 / +50 / +100 / +150 ms — a DELAY-long move, no slow slide; tag reads `run` (3.33 m/s) | PASS |
| (g) | 10 m step | snaps immediately; ring cleared to one sample | PASS |
| (h) | yaw 3.0 → −3.0 | lerps through ±π (3.085, 3.227), not through 0 | PASS |
| (i) | `mp_npc_smooth off` / `on` | off: legacy 0.5 lerp (x = 0.5); the toggle logs "interp delay 120 ms"; on again: renders from the ring (x = 0.30) | PASS |

Every scenario also asserts zero swallowed Lua errors in the render path.

### 5.2 What this does not prove

- **How it looks and feels to a human** watching real combat on a puppet.
  The arithmetic says continuous motion at true average speed, ~120 ms
  behind; nobody has watched it. This remains genuinely open.
- **Whether WO-60's claim system holds up under real two-player pressure.**
  Nothing here touches it and nothing here tests it. Also open.
- **That the game's Lua VM accepts the code.** MoonSharp is not CryEngine's
  Lua 5.1; the file loads clean under MoonSharp, and the constructs used
  are ones the file already relied on, but the live game was not available.
- Shipping default-on is a deliberate trade of visual detection for
  adoption, **not** a claim that either open question is resolved.

### 5.3 Existing suite set (regression)

All (observed), this session, against a Debug relay built from this tree:

| suite | result | relay |
|---|---|---|
| `Test-Sessions.ps1` | **22/22** | long-lived relay on 7778 |
| `Test-Combat.ps1` | **14/14** | same relay |
| `Test-Dice.ps1` | **15/15** | a **fresh** relay on 7778, stopped after |
| `Test-NpcClaimValidation.ps1` | **29/29** | self-starting |
| `Test-TimeSkipRelay.ps1` | **35/35** | self-starting |
| `Test-ItemSyncRelay.ps1` | **11/11** | self-starting |
| `Test-NpcSmoothSynthetic.ps1` | **39/39** | none (stubbed Lua VM) |

None of these exercise `kdcmp.lua`'s puppet path except the new synthetic
suite; they confirm the .NET side is unchanged (it is — no .NET file was
edited).

`dotnet build dotnet\KcdMp.Server -c Debug`: 0 warnings, 0 errors
(observed).

## 6. What this session did not do

- No engine, protocol, relay, agent, or native change. `git diff --stat`
  touches `kdcmp.lua`, two new `tools/` files, `README.md`,
  `docs/PROJECT-STATE.md`, and the two WO-77 docs only.
- No `VERSION` change (still `0.19.0`); the maintainer's call.
- No live game, no field footage, no two-machine session; `Test-Pipe.ps1`
  and the live-game E2E suites not run (none available).
- Step 3 not built (§4). Adaptive per-NPC cadence not built (§2).
- The ghost-path housekeeping the design lists as Step 4 (stamping alive
  from the pump during menus) not touched — a ghost-path change, separate
  verification.
- Did not repeat WO-76's Phase 3 by any synthetic substitute; the
  discriminator needs a real NPC brain to suppress.
