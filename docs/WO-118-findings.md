# WO-118 — findings: the jitter build (0.28.0)

Session 2026-09-23 (end gate 2026-09-24), solo, against the running Modding Tools build, a local
relay and a synthetic authority peer (`tools/wo118`). Four game launches, one
throwaway save. Progress, gaps and side effects: `docs/WO-118-progress.md`.
Field page: `docs/WO-118-runbook.md`. Read first: `docs/WO-116-movement-layer.md`
§14 (the jitter root cause), `docs/WO-110-findings.md`.

Evidence marks: (observed) / (code-verified) / (synthetic) / (inconclusive).
"The call succeeded" is never used as "the thing happened": every live row
below was read back from the renderer's own position (`mp_npc_trace`, one CSV
row per frame at `CSystem::Render`) or from the engine's log.
**Nothing here ran two-player.** "Observed" means observed solo, with the
synthetic peer as the authority and this machine as the joiner. Paths:
`<install>` (the Modding Tools install), `<saves>`, `<scratch>`.

---

## 0. Answer first

* **The native per-frame write works and ships on.** KCDMP.dll writes every
  bound puppet at its frame hook (after the NPC movement pass, before anim sync
  and render): `CLivingEntity::SetParams(pe_params_pos, bRecalcBounds 0x21)`,
  then an unflagged `IEntity::SetPosRotScale`. Render equals written to
  0.000 mm on every traced frame; bFlying 0 on NPCs; 1.24 million writes,
  0 faults. (observed)
* **Phase 5 gate green** on this build (§4): walker 0 frozen frames (legacy
  75 %), seated 0.0 mm at render (legacy 65–136 mm sawtooth). (observed)
* **Detach ships on.** Stance/Unstance after the pause frees a paused NPC from
  its activity: 16 NPCs, 13 activities, pull 0.0000 at 1 m, 3 m and after the
  walk-away (30 m for five of them). Over the whole WO 68 NPCs in 75 animation
  states (activities and their transitions) detached with `changed=1`; 12
  detaches were skipped because the NPC was in a conversation (`IsInDialog`).
  Cost: a one-frame hop of 5–73 cm, away from the spot, at the detach moment.
  (observed)
* **The sender clock needed a jitter allowance — found and fixed in-WO.** With
  the fixed 120 ms delay, 40 ms + 0–60 ms jitter froze 14.8 % of frames **with**
  the sender clock and 3.4 % without it. The DLL now measures, per stream, how
  late the next sample becomes renderable and moves the render time back by its
  95th percentile (slewed at 10 %): 0 frozen frames, speed sd 0.01–0.02 m/s
  under the same jitter and 250 ms spikes. (synthetic, §3.8)
* **Cost ~6.6 µs per written puppet per frame**: 0.25 ms at 37, 0.41 ms at 61,
  0.45 ms at 70. Frame time native on vs off: no difference beyond run-to-run
  noise at 40, 64 and 80 streamed puppets. (observed, §3.9)
* **Ghost (2b): legacy 50 % frozen frames → native 0 %.** Speed wobble remains
  (sd 0.56 m/s clean, 1.04 m/s at 60 ms jitter): the position frame carries no
  sender time. A sender stamp is a protocol change; not done. (observed, §3.4)
* **New limit, pre-existing, not fixed: the agent's ingress** (§3.10). Every NPC
  sample is also pushed to Lua over the game's REST console, inside the agent's
  serial receive loop: ~680 samples/s at 75 fps, ~233/s at 25 fps. Above it the
  backlog grows and every puppet steps at the sample rate — native and legacy
  alike. 40 walking NPCs fit at 75 fps and **do not fit with the joiner's window
  unfocused** (the game's background limiter). (observed)
* **No sinking.** Slope (~8°, 1.64 m over 12 m): render Z − floor +0.04 cm, the
  engine moved the body 0.00 cm, bFlying 0/1242. Fight (drawn + a swing cue
  every 2.5 s): Z exact, bFlying 0/1399. (observed, §3.3)
* **Two pre-existing agent defects found and fixed on the way**: a fresh agent
  never pushed its first CombatRole (stale damage authority, §3.12); NPC sender
  stamps were 15.6 ms-quantized (§3.13). (observed)

---

## 1. Predictions — committed 2026-09-23, before the two-player session on this build

Same rules as WO-110 §1: both players on this build through the launcher, the
joiner loads a copy of the host's save, a town crowd, runbook followed, both
game windows focused unless a row says otherwise. "Joiner" = the machine whose
kcd.log says `MP-AUTHORITY-OWNER … authority=peer`.

| # | prediction | P |
|---|---|---|
| P1 | The joiner reports walking streamed NPCs **smooth** (no stutter, no stand-and-dash) at defaults | **0.60** |
| P1a | The joiner agent's `MP-NPCWRITE-STATUS` shows `writing` ≈ `bound` while NPCs walk | 0.80 |
| P1b | `mp_npc_native_write off` brings the stutter back, visibly (the A/B works in the field) | 0.85 |
| P1c | Someone notices a seated/working NPC hop once when it becomes a puppet (the detach moment, 5–70 cm) | 0.35 |
| P2 | NPCs the host moves away from a seat or workstation stay where the stream puts them on the joiner — no slide back, no sawtooth | **0.80** |
| P3 | No sinking report for puppets | 0.65 |
| P4 | The peer's avatar never freezes mid-walk, and its pace visibly wobbles on a real internet link | 0.55 |
| P5 | Every joiner `MP-NPCBIND … result=refused` is `reason=not-living` (no name or WUID mismatch) | 0.90 |
| P6 | No `MP-NPCWRITE DISARMED` and no `engine call FAULTED` on either machine | 0.95 |
| P7 | Joiner `MP-NPCWRITE-COST … tick_us_mean` stays below 500 | 0.90 |
| P8 | Joiner `MP-NPCBIND … jitter_allow_ms` is mostly 0–60 on the real link | 0.70 |
| P9 | If the joiner alt-tabs for > 10 s near ≥ 25 walking NPCs, puppets step and lag for a while after returning (§3.10) | 0.50 |
| P10 | After a save reload on either machine, no puppet stays frozen more than 5 s once its stream resumes | 0.70 |

**Top failure modes, ranked, with the line that identifies each:**

1. **Ingress backlog (§3.10).** Joiner agent console:
   `MP-NPCWRITE-STATUS … bound=<B> writing=<W>` with W ≪ B for more than 10 s.
   Native log: `MP-NPCPULL … max_cm=50–110 moved_frames=5–10` (the walk
   animation drifting between late samples) and `jitter_allow_ms` near 300.
   kcd.log: `MP-NPCWRITE native=healthy … (heartbeat)` repeating (each one = the
   heartbeat lapsed > 3 s). Field fix: keep the game window in front; fewer
   walking NPCs in range (`mp_cull_radius 30` on the host).
2. **Host emitter gaps.** A menu, dialogue or cutscene on the **host** suspends
   its emitter chain (WO-78): joiner puppets hold, then catch up.
   `MP-NPCWRITE npc=… event=drop reason=silence` after 4 s of silence.
3. **Swing resume step (inherited, §3.3).** In a fight an NPC snaps up to ~1 m
   when a 900 ms swing hold ends, if the host moved it meanwhile.
4. **Ghost pace wobble (§3.4).** No log line; the trace shows it
   (`mp_npc_trace kcd2mp_<id> 10`, speed sd).
5. **Bind churn.** kcd.log `MP-NPCWRITE npc=<n> native=refused|dropped reason=…
   -- Lua writes it (retry in 10s)` cycling for one NPC.
6. **Detach hop.** `MP-DETACH npc=<n> … changed=1` at the moment of the hop.

**What would show the per-frame-write diagnosis wrong:** a walker that still
stair-steps on the joiner **while** its `MP-NPCBIND` is `ok`, the status line
reads `writing≈bound` and there is no backlog. Then something else writes that
body; the joiner's `MP-NPCPULL` for it will show `moved_frames` high with
`lag_frames` low (the engine or a script moving it between our writes).

---

## 2. What shipped

| piece | commits | default / toggle | presets (clean / legacy) | evidence |
|---|---|---|---|---|
| Native per-frame writer (frame hook, anchors, ring, WUID check, per-frame write, MP-NPCPULL, trace) | d1164e4, 9aefa8f | `mp_npc_native_write on` | on / off | observed |
| Jitter allowance (per-stream need, p95, slewed) | 92023cc | always on inside the writer | — | synthetic |
| Writer cost line `MP-NPCWRITE-COST` | 4d92c14 | always | — | observed |
| Agent feed: every NPC sample to the DLL; bind/hold/config/trace/status; heartbeat | af18b09 | follows the toggle | — | observed |
| 1 ms QPC sender stamps | bd26225 | always | — | observed |
| Lua: bind, fallback on a stale heartbeat, holds for swings/takedowns, `WO118-BUILD`, commands | 4781c86 | — | rows for both toggles | synthetic + observed |
| Detach (Stance/Unstance after the pause; skipped in dialogue/cutscene) | cfea218 | `mp_npc_detach on` | on / off | observed |
| Peer ghost on the native writer | 6258502 | follows `mp_npc_native_write` | — | observed |
| First CombatRole always pushed (bug fix) | eb0436c | — | — | observed |
| Lua detectors labelled `path=legacy` | a1c5b5f | — | — | synthetic |
| Pak rebuilt | f299310 | — | — | code-verified |
| `tools/wo118` gate harness (not shipped) | 704845a | — | — | observed |

`mp_preset_legacy` = today's 50 ms Lua path with no detach (both toggles off);
`mp_preset_clean` = both on. `mp_puppet_rate` only applies on the legacy path.

---

## 3. Findings

### 3.1 Phase 0 — addresses by anchor, fail-closed (observed, code-verified)

* Resolved at every launch (4 launches, 4 injections this WO) from RTTI vftables
  (`.?AVCEntity@@`, `.?AVCLivingEntity@@`) plus the instruction bytes each slot
  must contain: `SetPosRotScale` = CryEntitySystem.dll+0x90AA0,
  `CLivingEntity::SetParams` = CryPhysics.dll+0x9C900 (slots 0x168 / 0x20;
  `GetParent` 0xD8, `GetScale` 0x160, `GetPhysics` 0x278, `GetStatus` 0x30).
  `WO118-NATIVE native_write=armed` every time.
* Any mismatch → `native_write=DISARMED`, nothing bound, Lua writes as before.
  Any engine fault inside the write → `MP-NPCWRITE DISARMED`, every puppet
  dropped back to Lua. Never triggered this WO (code-verified path; 0 faults in
  1.24 M writes).
* The transform-flag set on this build is CE3's (no IGNORE_PHYSICS): the
  physics write keeps the ground collider with bit 32; the entity write that
  follows is then a zero-length move for the physics proxy (WO-116 §14).

### 3.2 Phase 1 — samples, ring, identity (observed)

* 906 binds across four sessions, **0 WUID mismatches** (`wuid=` = `lua_wuid=`
  on every line). The only refusal: `not-living` — ~10 NPCs without a living
  physics body (three `rvacka_apprentice_*`, far `tzda_*`/`ttro_*`), retried
  every 10 s, left on the Lua path.
* Sender-clock stamping ported from Lua (rolling two-window minimum offset),
  Z interpolated on the segment, > 5 m XY step snaps, a moved-gated silence is
  clipped to one delay. Two stale-state traps found live and fixed (9aefa8f,
  §6): a restarted stream's sequence (2 s silence → restart) and a
  reconnecting source's clock (5 s silence → fresh offset).

### 3.3 Phase 2 — the per-frame write; sinking (observed)

* Walker: 0 frozen frames in every clean-link native trace (hundreds of frames
  each; under injected jitter see §3.8);
  render = written to 0.000 mm; the engine moved the body 0.00 cm between
  render(n−1) and hook(n). Step sd 0.28–0.37 cm is frame pacing
  (corr(step, dt) = 0.94, dt sd 2.5 ms at 13–14 ms); per-frame speed sd
  0.01–0.02 m/s.
* Physics lag, not pull: the physics body lags a queued write by one frame, so
  at the hook it equals the write from two frames earlier (0.00 cm, every such
  frame). Counted as `lag_frames`, never as pull (9aefa8f).
* **Slope** (a real 12 m path, 108.0 → 106.4 m, ~8°, 25 floor points, 18 s of
  passes): render Z − floor mean +0.04 cm, sd 2.1 cm (the plan's 0.5 m point
  spacing across two floor steps); hook(n+1) = written(n) in Z to 0.000 cm;
  bFlying 0/1242. Legacy on the same path: Z +0.50 cm, bFlying 0, 54.7 %
  frozen frames.
* **Fight** (`fight` mover: circling 1.2 m/s, drawn flag, a swing cue every
  2.5 s, on a flat floor): render Z = floor on every frame including the held
  ones; bFlying 0/1399. Six 900 ms holds: the engine left the body still
  (0.0 cm) and the write resumed with a 76–127 cm step — the synthetic fighter
  kept circling through its swing. **Inherited, not new**: the legacy path gives
  a puppet "no writes at all" during a one-shot window and catches up after
  (WO-39/WO-40); the native hold keeps that exactly. A real swinging NPC barely
  moves. **Fixed in 0.28.3** — the write blends out of a hold (§8).
* Lua keeps puppet start/release, pause, locomotion, weapon draw, swing cues and
  death; dead, unconscious and carried bodies stay on Lua's own behaviour (the
  DLL skips flags 0x01/0x02/0x10 and parented bodies every frame).
  (code-verified, synthetic scenarios in `tools/Test-WO118Synthetic.lua`)

### 3.4 Phase 2b — the peer's ghost (observed, synthetic)

* Traced first, as ordered: the legacy Lua path left **50.1 %** of frames
  frozen → moved to the native writer. Native: 0 frozen frames in every trace,
  render = written.
* Pace wobble: speed sd 0.56 m/s clean, 0.76 at 20 ± 20 ms jitter, 1.04 at
  40 + 0–60 ms (70 fps). The position frame (0x01) carries no sender time, so
  the ghost renders on arrival time; a linear fit to a clean run left a 3.4 ms
  timing residual (max 6.6 ms). The real stream is ~30 ms (`MP-POSCADENCE
  path=native p50_ms=30`). A sender stamp on 0x01 needs a protocol change (the
  relay's exact-length gate, WO-101); not done in a jitter-only build.
  **Corrected in 0.28.3 (§9):** the clean-link part was never arrival
  timing — the DLL stretched every 30 ms ghost segment to a 50 ms floor.
  Both are fixed (the floor, and a sender stamp on the position frame).
* bFlying reads 1 on every ghost frame, native or legacy (inconclusive: the
  ghost's body is spawned differently; nothing sinks or falls).

### 3.5 Phase 3 — detach per activity (observed)

`MP-DETACH … stance=ok unstance=ok result=<before>-><after> changed=1` for every
row. (The "detach hop" column did not reproduce after 0.28.0; the visible
start-up steps were something else, now fixed — §8.) Holds at 1 m and 3 m and the hold at the end of the walk-away: no
`MP-NPCPULL` line (max < 1 mm) except the single detach-moment frame. Walking
phases logged one-step maxima (1.9–2.5 cm, cos 1.00): the physics-lag artifact,
reclassified by 9aefa8f (walkers log no pull line since).

| NPC | activity at puppet start | walk-away | pull 1 m / 3 m / end | detach hop |
|---|---|---|---|---|
| ttkc_man_5 | Guard (guard spot) | 30 m | 0 / 0 / 0 | — |
| ttkc_man_31 | WoodChopping_loop | 30 m | 0 / 0 / 0 | — |
| ttkc_woodworker | CarpenterOut | 30 m | 0 / 0 / 0 | — |
| ttkc_man_19 | Placing (field worker) | 30 m | 0 / 0 / 0 | 6.6 cm |
| ttkc_bailiffSon | MotionMovement | 30 m | 0 / 0 / 0 | 73.3 cm |
| ttkc_man_30 | MotionMovement | 20 m | 0 / 0 / 0 | — |
| ttkc_scribe | TranscribingLoop | 6 m | 0 / 0 / 0 | — |
| ttkc_man_16 | SittingIdle (dice player) | 6 m | 0 / 0 / 0 | — |
| ttkc_man_7 | Lying (bed) | 6 m | 0 / 0 / 0 | — |
| ttkc_man_11 | SellerLoop_VAR | 6 m | 0 / 0 / 0 | 7.4 cm |
| ttkc_woman_2 | Bartender_TakeAndTapStein | 6 m | 0 / 0 / 0 | — |
| ttkc_woman_3 | HousekeeperFirewoodIn | 6 m | 0 / 0 / 0 | — |
| ttkc_inkeeper | SittingIdle | 3 m | 0 / 0 / 0 | — |
| ttkc_bartosek | Leaning_Back_Loop | 3 m | 0 / 0 / 0 | — |
| ttkc_emerich | SellerLoop | 3 m | 0 / 0 / 0 | 5.0 cm |
| ttkc_man_32 | Leaning_Back_Loop | 3 m | 0 / 0 / 0 | — |

* Over the WO (mostly the scale runs, which puppet the whole village): 68 NPCs
  in 75 distinct states detached `changed=1` — among them LumberJackSaw
  (sawyer), Carpenter, Weeding, Well, SweepingFloor, PrayKneeling, Cooking,
  Embroidery, Beggar, the Housekeeper* family (milking, spindle, basket
  weaving, feeding hens), the Bartender* family, Guest_EatingIn_Left, the
  WaitingStand* family, Scribe_TableListeningLoop, CampSnoozeLoop and the
  WoodChopping_* chain. `changed=0` only for NPCs already in motion
  (IdleToMove) and the three not-living apprentices (`<unknown>`).
* 12 `result=skipped-dialog` (ambient NPC conversations: `human:IsInDialog()`
  true). Twice an NPC was detached in `IngameDialogPose_In` — the transition into
  a conversation, `IsInDialog` still false. No cutscene skip occurred (none
  played).
* Without detach (native write alone) a seated NPC renders 0 mm but its body is
  pulled 2.2 cm/frame toward the seat (cos 1.00) between writes; with detach the
  pull is 0 and the body grounded.
* Not tested: the dice minigame mid-game.

### 3.6 Phase 4 — MP-NPCPULL (observed)

* `MP-NPCPULL npc= mean_cm= max_cm= frames= moved_frames= toward_anchor_cos=
  anchor_m= dz_mean_cm= lag_frames= flying=x/y jitter_allow_ms= window_s=` —
  every 10 s per puppet, only when the engine moved the body ≥ 1 mm since our
  write. In the scale runs it flagged exactly three things: Z settling where
  the synthetic plan held a constant Z over uneven ground (dz_mean ±1–2.5 cm,
  some bFlying frames — a plan artifact; real streams carry the owner's Z), the
  one-frame hops at bind/detach, and drift under the ingress backlog (§3.10).
* The Lua detectors (`MP-AUTHORITY-VIOLATION`, `MP-NPCZ`, `MP-NPCZ-SUMMARY`,
  `MP-NPCFIGHT`) run only inside the puppet tick's `lastWrote` block, which a
  native puppet clears. Kept, and now labelled `path=legacy` (a1c5b5f).

### 3.7 Phase 5 — the trace gate (observed)

| run | walker native | seated native + detach | walker legacy | seated legacy |
|---|---|---|---|---|
| session 1 | 0/390–446 frozen, speed sd 0.05 m/s | 0.0 mm, 0 moving frames, grounded | 75.6 % frozen, strip `0 0 0 87 …` | 136 mm sawtooth, 543/543 moving, airborne |
| session 4, scratch harness | 0/443, speed sd 0.022 | 0.0 mm, 0 moving | 75.3 % | 65 mm, 565/566 moving, airborne |
| session 4, `tools/wo118` | 0/443, speed sd 0.024 | 0.0 mm, 0 moving | 75.3 % | 83 mm, 572/573 moving, airborne |

The WO's "step sd ≈ 0.1 cm" is not met literally (0.32–0.37 cm): the step per
frame follows the frame time. The pacing-normalised figure, speed sd × mean
frame time, is 0.02 m/s × 14 ms ≈ 0.03 cm.

### 3.8 Phase 6 — network noise: the sender clock needed a jitter allowance (synthetic)

One walker through the local relay; the peer injects delay/jitter/spikes after
its sender stamp. 8 s traces, runs ≥ 12 s apart. Frozen % / per-frame speed sd.

| run | link | receiver | fixed 120 ms delay | lateness allowance¹ | shipped (need tracker) |
|---|---|---|---|---|---|
| P0 | clean | sender clock | 0 % / 0.01 | 0 % / 0.24 (26 fps) | 0 % / 0.02 |
| P1 | 40 ms + 0–60 ms | sender clock | **14.8 % / 1.23** | 0 % / 0.16 (26 fps) | **0 % / 0.02** |
| P2 | P1 + 3 % × 250 ms spikes | sender clock | **15.0 % / 1.26** | 0 % / 0.15 (26 fps) | **0 % / 0.01** |
| P3 | P2, 15.6 ms tick stamps | sender clock | 21.1 % / 1.50 | 0 % / 0.17 (26 fps) | 0 % / 0.08 |
| P4 | P2 | arrival time | 3.4 % / 0.46 | 3.0 % / 0.43 | 0 % / 0.37 |
| P5 | clean | arrival time | 0 % / 0.01 | 0 % / 0.03 | 0 % / 0.02 |

¹ an intermediate build that covered network lateness only; it missed the
drain frame (one-frame underruns at 26 fps) and arrival-stamped streams.

* **Why.** The sender clock places a sample at its sender time plus the link's
  *fastest* latency. The fixed delay (1.2 × the emit period) leaves ~20 ms —
  any later packet, a sender timer firing late, the agent's feed or the frame
  the drain waits for eats it, and the ring runs dry: a held frame, then a
  catch-up step. Arrival stamps hide this (the lateness is in the stamp) at the
  cost of pace noise.
* **The fix (92023cc).** Per stream, at the drain: need = now − the newest
  sample's stamp, i.e. how long after the newest stamp the next sample became
  renderable. A streaming 95th percentile (4 ms steps); gaps > 0.5 s are
  moved-gated silences, not counted. Render time moves back by
  (need − delay), 0–300 ms, slewed at 10 % of real time so a change never shows
  as a step. `jitter_allow_ms` in `MP-NPCBIND`/`MP-NPCPULL`: 0 on a clean link,
  18–80 ms under this jitter.

### 3.9 Phase 6 — cost at 40 and 80 puppets (observed)

Walking movers (4 m ping-pong lines), frame time from traces, writer time from
`MP-NPCWRITE-COST`. Window focused except where noted.

| streamed (bound / written) | emit | writer µs/frame mean (max) | frame ms native on | frame ms native off |
|---|---|---|---|---|
| none (baseline) | — | — | 13.48 | — |
| 40 (37 / 37) | 100 ms | 235–253 (411) | 13.51, 13.20 | 13.29 |
| 40 (37 / 37), repeat | 100 ms | 229–250 (414) | 13.98, 14.13 | 14.06 |
| 64 (61 / 61) | 100 ms | 404–407 (582) | 13.17, 13.17 | 13.14 |
| 80 (70 / 70) | 200 ms | 452–456 (819) | 14.11, 14.15 | 14.10 |
| 80 (70–71 / 10–14) | 100 ms | 115–149 | 13.27, 13.27 | 13.39 |
| 40 (37 / ~9), **minimized** | 100 ms | 88–121 | 39.1, 39.2 (26 fps) | 39.6 |

* ~6.6 µs per written puppet per frame, linear (0.25 ms → 0.41 → 0.45 ms);
  ≈ 3 % of a 13.5 ms frame at 70. The on/off difference is inside run-to-run
  noise at every size (±0.3 ms).
* 80 at 100 ms emit could not be fed (§3.10): only 10–14 of 70 written per
  frame. 200 ms emit keeps 80 inside the ingress and the allowance adapts to
  the slower stream (the traced puppet was written every frame).
* 10 of 80 refused `not-living` (fail-closed, Lua path).
* The trace itself writes its CSV on the main thread at the end: one 1.8–6.9 ms
  tick (`tick_us_max`) per trace.

### 3.10 The agent's ingress ceiling (observed; pre-existing; fixed in 0.28.3, §9)

* The agent's relay reader is one serial loop. Each NpcState packet is decoded,
  queued for the DLL (non-blocking), **and** pushed to Lua through the batched
  REST `ExecuteString`, whose flush awaits the game. Measured at the DLL:
  ~680 samples/s forwarded at 75 fps (727 emitted), ~233/s at 25 fps (367
  emitted, window minimized).
* Past the ceiling the TCP backlog grows (~2 s after 30 s at 80 × 10 Hz). The
  arrival stamp is taken after the backlog, so every sample looks late: the
  allowance hits its 300 ms cap and each puppet is written once per arriving
  sample and held in between (a stair-step at the sample rate), with the walk
  animation drifting the body between writes (`MP-NPCPULL max_cm≈105`). Lua's
  heartbeat rides the same queue and lapses > 3 s (`native=healthy` re-logged),
  so Lua briefly unbinds and rebinds. The legacy path reads the same stale
  queue: no better.
* In practice the owner emits only walking NPCs at 10 Hz (still ones every 2 s),
  so a town rarely streams more than 10–20 walkers — inside the ceiling at any
  frame rate. The risk is a crowd plus an unfocused joiner (P9).
* Fix, for a later WO: feed the DLL straight from the socket read (stamp at
  read, independent of Lua), and push Lua only the latest sample per NPC
  (native puppets need Lua for gait, flags and policy, not for positions).

### 3.11 The game's background frame limiter (methodology, observed)

KCD2 runs at ~26 fps (39 ms frames) whenever its window is not in front —
reproduced by minimizing (40.4 ms) and undone by bringing it forward (14.1 ms).
Several runs this WO landed at 26 fps before this was understood; every row
above carries its frame rate, and `tools/wo118` now focuses the window first.

### 3.12 A fresh agent never pushed its first CombatRole (observed, fixed eb0436c)

Lua kept `hitSensorOn=on` from an earlier agent: a fresh agent's first
CombatRole (false) compared equal to its own default and was never pushed. Now
the first role of every connection is pushed; verified live (`hit_sensor_was=on`
→ `HIT_SENSOR off` at once). Affects any session where an agent restarts under
a running game.

### 3.13 Sender stamps were 15.6 ms-quantized (observed, fixed bd26225)

The agent stamped NpcState with `Environment.TickCount64` (15.6 ms steps): a
clean-link walker showed speed sd 0.23 m/s from the stamps alone (0.04 m/s with
1 ms QPC stamps). P3 above shows the old stamps under noise.

---

## 4. Phase 5 gate against the shipped build

Fresh clone of `origin/main` at `66ebace`, built with `tools\Build-Installer.ps1`
(green); the game relaunched with the clone's pak installed and the clone's
`KCDMP.dll` injected; the clone's own relay and agent (`KcdMpServer.exe`,
`KcdMpClient.exe`) as relay and joiner; `tools/wo118/phase5_gate.py`: (observed)

| step | result |
|---|---|
| 1 walker, native | 0 / 478 frozen; step 1.84 cm sd 0.28; speed sd 0.020 m/s; render − written 0.000 mm; flying 0/611 |
| 2 seated, native + detach | 0.0 mm max deviation; 0 moving frames; flying 0/616 |
| 3 walker, legacy | 75.3 % frozen (the stair-step) |
| 4 seated, legacy | 58 mm median offset, 62 mm max deviation; 615/616 frames moving; flying 616/616 (the sawtooth) |

**GATE GREEN.** The same build under jitter (`noise_batch.py` P1, P2): 0 frozen
frames, speed sd 0.02 m/s.

**And on the released 0.28.0 build** (fresh clone at `c15b605`, its own pak, DLL,
relay and agent; `docs/WO-118-progress.md` §5): walker native 0/469 frozen, speed
sd 0.012 m/s, render − written 0.000 mm; seated native 0.0 mm, 0 moving frames;
walker legacy 75.3 % frozen; seated legacy 61 mm sawtooth, 615/616 moving —
**GATE GREEN**; P1/P2 0 frozen, speed sd 0.03 m/s. (observed)

---

## 5. Not done, inconclusive, stated plainly

* **Nothing two-player.** Every number is solo with a synthetic authority on
  loopback; the network noise is injected, not real.
* **80 walking puppets at the real 10 Hz** could not be fed (§3.10); cost at 80
  was measured at 200 ms emit, where all 70 bound puppets were written.
* **Ghost pace** stays on arrival time (§3.4).
* **The dice minigame mid-game** was not tested with detach.
* **bFlying on the ghost** reads 1 always (inconclusive).
* **A reload with puppets bound** was not traced this WO (the WO-110 §3.4
  post-reload write fight was not re-run against the native path).
* **The slope** found near the village was ~8°; nothing steeper was reachable
  with a clean floor profile.

---

## 6. Corrections this WO makes to the record

* The sender clock (WO-110 R6) was believed to make jittery links smoother. With
  the fixed 1.2 × delay it made them freeze **more** (14.8 % vs 3.4 %); it needs
  the allowance (§3.8). The legacy Lua path still has the fixed delay.
* NPC sender stamps were never 1 ms: they were 15.6 ms steps until bd26225.
* WO-116 §14's "DLL write at the frame hook = 0 mm" holds for the write at the
  hook's **exit** too (later than the probe's entry write), including with the
  ground collider kept.
* The Lua detectors are legacy-path instruments from this build on (§3.6).
* After 0.28.0: the ghost's clean-link pace wobble (§3.4) was the DLL's 50 ms
  segment floor, not arrival timing — a sender stamp alone left it at
  sd 0.58 m/s; lowering the floor took it to 0.02 (§9).

---

## 7. Open, carried forward

1. ~~**Agent ingress** (§3.10).~~ Done in 0.28.3 (§9).
2. ~~**Ghost sender time**.~~ Done in 0.28.3 (§9), with the real clean-link
   cause (a 50 ms segment floor).
3. ~~**Blend out of a swing hold** instead of stepping (§3.3).~~ Done in
   0.28.3 (§8).
4. ~~**The detach hop** (5–73 cm once).~~ Done in 0.28.3 (§8): not
   reproduced; the puppet-start steps it stood for are gone.
5. **Legacy path** keeps the fixed delay and the 50 ms write; it is the A/B only.
6. Two-player verification of P1–P10.

---

## 8. Follow-up after 0.28.0 (2026-09-24): no step at a swing's end or a puppet's start

Solo, the same harness (`tools/wo118`), fresh sessions on the 0.28.0 pak with
working-tree DLLs; commits `c1548ad`, `cd98a9f`, `7c1652a`, `6e01d55`, `2c5dd91`.
**Shipped in 0.28.3** (named by the maintainer).

* **Swing hold resume** (observed). Before, on the 0.28.0 build: six 900 ms
  holds, each ending in a one-frame snap of 77–134 cm (the synthetic fighter
  circles through its swing). Now: the resume step is 2.6–3.7 cm, and the
  catch-up peaks at 2.9–3.3 m/s (the stream's own speed + 2 m/s): ≤ 4.3 cm/frame
  at the 13 ms mean frame, 4.9–6.0 cm on 18–21 ms frames. (A hitchy run with
  35–41 ms frames showed up to 12.7 cm at the same speeds.)
* **Puppet start** (observed, 5 activity NPCs: two sellers, a woodchopper, a
  seated NPC, a waiting-stand NPC). The WO-118 "detach hop" did **not**
  reproduce: holding each NPC at its own spot, the renderer never moved it more
  than 0.02 cm, and the engine moved the body at most 0.53 cm when the reset
  landed. From a 1 m offset (as WO-118's plans started) two real steps appeared
  instead:
  * the Lua path wrote the fresh puppet during the one agent round trip its
    first bind takes, drawing its WO-77 seed slide at 50 ms steps — 41–64 cm per
    write;
  * the DLL's own seed (the body put into the ring one delay in the past) then
    jumped 50–55 cm in one frame — or, when it dropped the stream's only sample,
    left the body short and slid it 50 cm two seconds later on the next
    heartbeat.

  Now Lua holds a fresh puppet still until its first bind is answered (1 s at
  most; a refusal hands it over at once; a retry never holds a body Lua already
  writes), and the DLL's first write blends from the body. From 1 m: largest
  render step 3.6–3.9 cm (3 NPCs), done in ~0.5 s. At the spot: 0.12 cm. From
  3 m: done in 0.92 s. No `MP-NPCPULL` line at start any more.
  * What produced WO-118's single-frame 5–73 cm pull lines stays
    (inconclusive): today's 0.28.0 starts logged at most 0.21–0.53 cm. The
    likely mechanism — Lua's slide still writing between the DLL's bind and the
    ack reaching Lua — is what the new rule removes.
* **Mechanism** (code-verified). Wherever the writer starts or resumes a body — a
  bind, the end of a hold, a body set down or unparented — it takes the body's
  pose and lets the offset to the stream decay: exponential (τ 80 ms), never
  faster than max(2 m/s, starting offset / 0.75 s) on top of the stream's own
  motion; yaw capped at 6 rad/s; more than 5 m still snaps. This replaces the
  bind's seed, and a stale ring (stream silent > 2 s) is cleared at a bind.
  `MP-NPCWRITE-COST` now ends in `blends= blend_max_cm=` (per 10 s window).
* **Regression** (observed). Phase 5 gate GREEN three times on the new DLLs
  (walker native 0 frozen; seated 0.0 mm; the legacy stair-step and sawtooth
  return); noise P0/P1 0 frozen, speed sd 0.02 m/s; ghost batch unchanged
  (0 frozen; pace sd 0.62/0.79/1.06 m/s). Synthetic: the WO-118 suite 94/94
  (three new scenarios for the rule), every other suite green.

---

## 9. Follow-up after 0.28.0 (2026-09-24): the agent's ingress and the ghost's sender clock

Solo, `tools/wo118`, working-tree builds (agent, relay, pak, DLL); commits
`c78f9e3` … `3302ac6`. **Shipped in 0.28.3** (named by the maintainer).
Protocol stays v7 (the maintainer's call).

**The agent's ingress (§3.10)** — three pieces:

* The relay reader only reads, stamps and feeds: every frame is stamped the
  moment its bytes are in, NpcState and Ghost samples go to the DLL right
  there, and the frame goes through a channel to the old handlers (`40099a2`).
* For a puppet the DLL writes, Lua gets the latest sample at most every
  200 ms — at once on any flags (dead, KO, drawn, swing cue, carried,
  resync) or health change; the pending latest is flushed when due or when the
  puppet stops being the DLL's; full rate when the native write is off or the
  DLL drops it (`03dd36d`, `NpcLuaCoalescer`, 6 unit tests).
* Lua renders such a puppet's gait 0.24 s behind with a 0.12 s grace, so the
  lower rate reads true speeds instead of run/idle flicker, and its sequence
  jumps are not counted as gaps (`c230b43`; synthetic (o) failed on the old
  Lua: run,run,idle,…).

Observed:

| load | before (0.28.0) | now |
|---|---|---|
| 40 walkers, game minimized (25 fps) | ~9 of 37 written per frame; the traced puppet written 46/206 frames; ~233 of 367 samples/s reach the DLL | **37.0 of 37.0**; the traced puppet written 203/203 and 206/206 frames; every sample reaches the DLL (~372/s); Lua gets ~204 pushes/s; no heartbeat lapse |
| 80 walkers at 10 Hz, foreground (77 fps) | 10–14 of 70 written; the traced puppet written 67/604 frames; backlog ~2 s after 30 s | **69.0 of 69.0**; the traced puppet written 621/621 frames; every sample reaches the DLL (~752/s); Lua gets ~427 pushes/s; frame time 12.9 ms on and off; writer 463–482 µs/frame |

**The ghost's sender clock (§3.4)** — four pieces:

* Position/Ghost carry the sender's ms behind flag 0x08 after the optional
  body state: lengths 17/21/22/26 up, 18/22/23/27 down; the relay's gate takes
  the four from one list (`c78f9e3`; RelayRoundTripTests 30/30).
* The agent stamps every Position with 1 ms QPC time and passes a Ghost's
  stamp to the DLL (`3cf24a9`).
* The DLL's `render()` no longer floors a segment at 50 ms (`fee8993`) — the
  real clean-link cause: every 30 ms ghost segment was stretched, the body
  crossing it at 60 % speed and jumping the rest (per-frame speed alternating
  0.85 / 2.1 m/s).
* The DLL orders samples by the sender's clock: the ghost has no sender
  sequence, so a reordered sample used to drag the render back (`04186e5`).

| ghost run (30 ms stream) | 0.28.0 | stamp only | stamp + floor | + sender order |
|---|---|---|---|---|
| clean | 0 frozen, sd 0.56 | sd 0.58 | **sd 0.02** | sd 0.02 |
| 20 ± 20 ms jitter | 0 frozen, sd 0.76 | sd 0.59 | sd 0.02 | **sd 0.02** |
| 40 + 0–60 ms jitter | 0 frozen, sd 1.04 | 1 frozen, sd 0.53 | 2 frozen, sd 0.16 | **0 frozen, sd 0.04** |
| the same without the stamp | — | sd 1.16 | sd 0.88 | sd 0.99, 3 frozen |

Under 40 + 0–60 ms jitter the stamped ghost still starves for a single frame
now and then: 1–2 per 8 s run, 570 of 571 frames written in the last (that one
outside the scored stretch, hence 0 frozen). The DLL holds the body for that
frame; the synthetic ghost, flagged flying, then drops 17–37 cm in the engine's
next physics step and the next hook puts it back before render — the rendered
height is the same in every frame. 0.28.0 had no such hold at that jitter (it
rendered on arrival time) but a pace sd of 1.04 m/s.

**Regression** (observed): Phase 5 gate GREEN on every new DLL (walker native
0 frozen, seated 0.0 mm; the legacy stair-step 75 % and sawtooth return);
noise P1/P2 0 frozen, speed sd 0.02 m/s. Agent tests 187/187; relay 30/30;
every synthetic suite green (WO-118 99/99).

**Not fixed, stated plainly:**

* The game's REST server refuses an overlapping request with 503: one batch
  (9 statements, a heartbeat first) in ~10 minutes of heavy load. Serializing
  the agent's requests was tried and made it worse — the queue waited past the
  0.8 s timeout (36 batches lost, Lua unbound its puppets) — and was not
  committed.
* Mixed builds (code-verified): a 0.28.0 relay's exact-length gate drops the
  stamped positions (21/26 bytes) and a 0.28.0 agent drops the stamped ghost
  frames (22/27), silently, as in WO-101. Until the bump a build from `main`
  still called itself 0.28.0 and the release check let such a pair connect;
  0.28.3 closes it — the relay refuses a release mismatch at the handshake, in
  both directions. An unstamped ghost from a sender without a release field
  (a synthetic peer) still renders on arrival time.

