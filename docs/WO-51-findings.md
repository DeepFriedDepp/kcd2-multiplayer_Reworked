# WO-51 — what would it actually take for NPCs to be identical, always, for everyone?

Worked 2026-08-25 (Fable 5). Design document only — no code, no prototypes, no
VERSION change. Every claim below carries its evidence tier: **observed /
read-but-unrendered / inconclusive**, never rounded up. "Read" here means read
from this repo's docs or current source this session, with the file named.

**Bottom line up front.** The user's hypothesis — that per-entity authority
gets worse under joint combat — turns out to aim at the wrong mechanism:
per-entity claims *do not participate in combat at all* today (they fire only
for dragged bodies, read from `ClientHandler.cs:202-208` and
`kdcmp.lua:2076-2079`). The real joint-combat exposure is three other things:
an unsuppressed puppet brain fighting the stream (observed, WO-49), a
never-verified NPC→non-authority damage path (Flow B, unverified since WO-28),
and engagement asymmetry baked into the cue design (read, `kdcmp.lua:2100`).
The recommendation (Phase 3) is: measure joint combat on the current build
first — every field observation predates every relevant fix — then build
receiver-side brain suppression and combat-scoped claims, in that order, and
do **not** build the dedicated third instance, for a reason that survives
scrutiny: the engine only simulates AI near its own local player, so a parked
instance cannot be the truth for players who are anywhere else.

Also stated up front, because the WO's bar demands it: **"the exact same NPC,
doing the exact same thing, for every player, all the time" is not reachable
by any architecture available to this project.** What is reachable is *one
authoritative state* per NPC (position, health, KO/death, engagement) with
rendered approximations everywhere else. Frame-identical behaviour would need
deterministic lockstep or engine-level netcode, neither of which exists in
KCD2, and even a perfect dedicated server would still hand observers an
approximation (interpolated positions, cued swings). Every option below is
honestly graded against that ceiling, not against a fantasy of pixel identity.

---

## Phase 1 — everything this project knows, in one place

### 1.1 The structural root cause (WO-26 onward)

Each peer runs a complete, independent single-player simulation; NPCs were
never network entities (`WO-26-shared-combat-design.md` §2 — read). Every NPC
therefore exists N times, once per machine, each copy with its own brain,
schedule, health, and crime state. Everything since WO-26 is a patch layer
that makes *one* copy's state win and the others render it:

- A continuous 50 ms `SetWorldPos` stream beats the local AI completely, with
  no suppression — proven on a fighting ghost (byte-identical position from
  full health to death, WO-26 Phase 3, **observed**) and on a real scheduled
  NPC (WO-32 Phase 1b, **observed**). One-shot writes do not hold (WO-32 1a,
  observed).
- The tug-of-war is what happens *between* those two facts: the local brain
  still runs, still wants the NPC somewhere else, and pulls between writes.
  It becomes visible exactly when the local brain's desired state diverges
  hard from the stream — WO-38 Phase 2's mechanism analysis (read), field-
  confirmed by the WO-40 footage under a 24.5 h clock divergence (observed).
- This is structural, not incidental: any receiving machine is running a
  second simulation of the same NPC whether we like it or not. The stream
  can pin position; it does not pin *intent*.

### 1.2 What "per-entity authority" actually is today, and what it was tested against

Precision matters here because the WO's central worry names this mechanism.

- **The global authority (Rule 2)** — one per session, the lowest-id ready
  relay client (`0x25 CombatRole`, WO-28). It alone emits `NpcStateUp`
  (0x26) for the ≤5 nearest human NPCs within **30 m of its own player**
  (`kdcmp.lua:1917`, read). It alone runs the ghost-health hit sensor
  (Flow B). Authority moves only on relay membership change — never
  per-fight, never per-packet.
- **The per-entity claim table (WO-39 Phase 2)** — a non-authority that sends
  `NpcStateUp` for an entity claims it; first claim wins by relay arrival
  order; refreshed per packet; expires after 5 s silence
  (`ClientHandler.cs:216-253`, read). But the **only** code path on a
  non-authority that ever sends NPC state is `mp_drag_sensor` — a *downed*
  (KO/dead) body being physically moved by the local player
  (`kdcmp.lua:2076-2079`, read). **A non-authority fighting a live NPC never
  claims it.** In joint combat the claim table is inert by construction.
- **What it was tested against**: WO-32's E2E drove one idle scheduled
  civilian with synthetic peers (observed); WO-39's T10–T14 verified claim
  grant/mute/expiry/disconnect on the wire and one live non-authority drive
  of a real NPC (observed). WO-39 Phase 9.3 drove a real NPC 10 m off-anchor
  for 30 s — pinned steady, no tug-of-war, *solo* (observed).
  **Simultaneous, continuous engagement of one NPC by two players was never
  part of the design (WO-49 declares it explicitly out of scope,
  `WO-49-findings.md:139-144`) and never part of any test.** All coverage was
  sequential or exclusive: one driver, an otherwise-idle target.

So the honest restatement of the user's concern: it is not that authority
*flaps* in joint combat — nothing moves it there — it is that the model has
**no design at all** for the second engaged player. They fight a puppet.

### 1.3 How suppressed is a puppeted NPC, really? (the WO-49 lens)

Not suppressed. The puppet layer overwrites position/rotation 20×/s and
re-asserts the drawn state every 1.5 s; everything else of the brain runs:

- WO-26 Phase 3 (observed, on a ghost): a position-pinned entity's combat AI
  stays *fully engaged* — registers attackers, arms itself, issues decisions —
  it just cannot do footwork. "A punching bag with a combat brain."
- WO-49 (observed, on a real world NPC): mid-test, the puppet's own brain
  **re-holstered the weapon the stream had drawn** and walked him back toward
  his wall lean. The shipped fix is a 1.5 s polling *re-assert*, i.e. a
  correction loop, not suppression — the brain fights on and loses every
  1.5 s. That is the shipped state of the art.
- WO-39/WO-40 (observed): a brain-in-combat Mannequin **eats StartAnimation
  one-shots** — the five clips that render on a calm ghost render nothing on
  a fighting one. So exactly when joint combat happens, the cue layer is at
  its weakest.
- Levers inventory: `AI.SetIgnorant` is registered, live-verified
  targeting-safe, and **ghosts are stimulus-deaf by default since WO-40** —
  but damage response is not a stimulus, so an ignorant brain still fights
  when hit (WO-39 Phase 6, observed). `Actor.SetAIBrainId` is documented but
  **not registered** on this build (WO-32 1f, observed). `NoAI` would also
  remove targetability — too blunt (read, WO-26 design §5). Lua AI writes are
  otherwise inert (project memory, standing). Native-side, nothing has ever
  attempted brain suppression, but the native toolchain is proven: RTTR
  mutation works (NATIVE-PLUGIN-findings), the Modding Tools DLLs export
  mangled symbols, and WO-42→47 built a working native combat-action
  injection (`ghost_swing` via `GetOrCreateCombatActor` + QueueAction,
  live-verified per weapon). Suppression at the brain/scheduler level is
  unexplored territory with a proven method of exploration.

### 1.4 Indirect divergence factors — closed, mitigated, or live

| factor | mechanism | status |
|---|---|---|
| Clock divergence (sleep/wait/fast-travel) | skip sync 0x28/0x29, forward-only | **closed for skips** — live-verified E2E on 0.12.6 (WO-38 addendum, observed) |
| Clock divergence (death-reload) | reloader self-fast-forwards (WO-40 Phase 4) | **mitigated, unverified live** — built + wire-verified only; the agent-side E2E was "one install away" (WO-40:589) and no later doc closes it |
| Weather | mod-arbitrated 0x2E/0x2F; BlendTimeOfDay | **mitigated with a hole**: apply path live-verified; arbiter E2E never run; and there is **no weather read**, so vanilla drift between heartbeats is undetectable by design (WO-40 Phase 3, read) |
| Per-save Guid instability (damage lands on nobody) | name-addressed 0x30/0x31 | **mitigated, unverified cross-machine** — field-confirmed root cause (571/571 unresolvable, observed); fix wire-verified (T16); no two-machine E2E since |
| Save reload killing sync | WO-28 re-arm fixes | **closed for the emitter** (observed, ~14 s recovery); puppets release after 3 s and re-track on resume — a bounded blink, not a divergence |
| Reconnect ghost duplication | WO-27 dedupe + launcher duplicate-agent fix | **closed** (both live-verified) |
| Authority mis-grant during reconnect | the one WO-32 anomaly (IsReady half-join) | **inconclusive** — observed once, never reproduced; drop rule verified 4× after |
| Menu/pause freezing puppet ticks | InterpPump now drives the puppet tick | **closed** (WO-40 Phase 2, read-but-unrendered) — but **dialogue freezes the world undetected** (79 s gap, observed) — **live** |
| Zero-damage hit floods (engine stall → anim collapse) | damage>0 gate at sender | **mitigated** (strong correlation, mechanism not proven — WO-40's own label) |
| Quest-alias clothing | alias→source substitution | **closed at the equip layer** (live-reproduced + validated) |
| Ghost brains reacting to stimuli (pickpocket aggro) | ghostsIgnorant default | **closed by default** (WO-40 Phase 9) |
| Radius gap: an NPC >30 m from the **authority's player** is never synced at all | none | **live, by design** — the tracked set is centred on one player (`kdcmp.lua:1917`); two players fighting away from the authority get zero NPC sync |
| Engagement asymmetry: NPC swing cues fire only when the **authority's own** health drops | none | **live, by design** (`kdcmp.lua:2100`) — an NPC attacking the non-authority renders no swing for anyone |
| NPC→non-authority damage (Flow B: NPC beats on your ghost in the authority's world, you take the damage) | 0x21/0x22 | **built WO-28, guards individually verified, cross-machine step NEVER verified** — no later doc claims it; also attribution-blind (the forge-bug class, still unconfirmed either way) |
| Health convergence on a shared NPC | damage-event replication only (0x12/0x30); the 0x26 `hp` field is stored, never written (`kdcmp.lua:2194`, read — Lua health writes are inert) | **live gap**: two copies whose health is converged only by event delivery, with no reconciliation and no kill/loot arbitration — WO-49's own explicit open item |

### 1.5 What is actually known about joint engagement

Exactly one field observation exists, from the 2026-08-18 footage
(`WO-40-footage-findings.md:53-58`, observed): PA fighting an NPC, PB joins —
"the moment that PB jumped into the fight, the NPC looked as if he was laying
down halfway phased through the ground, while PA continued to fight a real
attacking NPC." Conditions: 0.13.x build, a 24.5 h clock divergence in
effect, before name-addressed damage, before reload convergence, before
stimulus-deaf ghosts, before the WO-49 re-assert.

That is the complete corpus. **Every fix relevant to joint combat postdates
every field observation of it.** No synthetic test has ever mounted two
simultaneous engaged drivers either — WO-39's claim tests muted one stream
while another drove; nobody ever fought over one entity. The state of
knowledge is: joint combat looked broken once, under conditions we have since
partially repaired, and has never been looked at since. Anything stronger is
rounding up.

### 1.6 The complete problem shape, in one statement

For an NPC to look "the same" to two players, five separate things must hold,
and today they fail independently:

1. **One position/pose truth** — holds within 30 m of the authority
   (observed), fails outside that radius (by design), and blinks on
   reload/menu/dialogue windows (mostly closed; dialogue still open).
2. **One behavioural truth** — fails structurally: the receiver's local brain
   is unsuppressed and fights the stream (observed, WO-49); rendering of the
   authoritative copy's behaviour is cue-grade (swing cues, drawn state), and
   cues are asymmetric (authority-hit only) and suppressed exactly during
   fights (Mannequin eats one-shots).
3. **One health/death truth** — event-converged only; unverified
   cross-machine since the 0x30 rework; no arbitration for simultaneous
   kills, loot, or XP; KO replication reproduces state but was proven on one
   machine only.
4. **One world-context truth** (clock, weather, crime) — clock closed for
   skips, mitigated-unverified for reloads; weather mitigated with an
   unavoidable blind spot; crime/reputation deliberately per-machine (open
   design question since WO-32, unchanged).
5. **A second engaged player's fight must be real** — no design exists. The
   non-authority fights a position-pinned puppet whose brain is a third
   participant; their incoming damage path (Flow B) has never been observed
   working across machines; their view of the NPC's attacks is silence.

---

## Phase 2 — the option space, honestly

Grading key: **cohesive** = does every player see the same thing (against the
§ceiling above); **effective** = does it specifically fix simultaneous joint
engagement; **efficient** = engineering + operational cost.

### Option 1 — revert to a single, fixed, permanent authority (no claims)

- What it actually means here: today's model minus the drag-claim table. The
  claim table is ~60 relay lines plus the drag sensor.
- **Cohesive**: no better than today — the claim table is not a source of
  combat inconsistency, because it never fires in combat (§1.2).
- **Effective for joint combat**: no effect whatsoever. The joint-combat
  problems (§1.6 items 2, 3, 5) exist entirely inside the single-authority
  model.
- **Efficient**: trivially cheap, and strictly negative value — it would
  re-break the one thing claims verifiably fixed (a non-authority dragging a
  body, live-verified WO-39) to buy nothing.
- Verdict: **rejected on the evidence.** The premise that per-entity handoff
  is a live combat risk is not supported by the code as it stands. If field
  data ever shows claim flapping (the `mp_npc_fight` meter exists precisely
  to catch multi-writer clusters), the cheap fix is a claim-grant hysteresis,
  not a revert.

### Option 2 — harden the per-entity model: combat-scoped claims with a hold

- Design sketch: generalize the existing drag claim into an **engagement
  claim** — a client whose player is actually fighting an NPC (signals that
  already exist: the DLL's LocalHit on that NPC, `AttackersCount`, weapon
  drawn within engagement range, the 0x2C combat events) claims it;
  first-claim-wins at the relay exactly as today; the claim is **held** while
  the fight lasts (refreshed by combat signals, not just packets) and
  released on disengage/death, with hysteresis so packet reordering cannot
  move it mid-fight. "Both actively engaged" needs no special detection —
  the second engager's claim attempt is simply dropped by the standing rule
  the relay already enforces (first claim wins, refreshes hold it).
- Handoff boundary: the loser of the claim keeps applying the winner's
  stream — the receiver path is already sender-agnostic (WO-39: "the WO-38
  body-follow one-shot is THE apply path for any sender", read). The
  dangerous moment is claim expiry mid-fight (claimant crash/reload): the
  entity falls back to the global authority's stream within 5 s — the same
  bounded blink as a reload, acceptable.
- **Cohesive**: better than today for the *nearest-player* problem — the
  player actually in the fight becomes the truth for it, which also fixes the
  radius gap (§1.4) for fought NPCs: the engine simulates AI properly near
  its local player, so authority-by-engagement puts the simulation where the
  fidelity is. This matters more than it looks: it is the only option that
  addresses the fact that **the global authority's world may not even be
  simulating an NPC that is far from the authority's player** (AI quiet at
  340 m, WO-26, observed-unattributed).
- **Effective for joint combat**: partially. It guarantees authority
  stability during the fight (the flapping the user feared becomes
  impossible by rule) and puts truth with a player who is actually there.
  But the second engaged player still fights a puppet — option 2 does not
  touch §1.6 items 2/3/5. On its own it hardens the skeleton of a fight
  whose flesh is still missing.
- **Efficient**: modest — relay rules extension (the table and conventions
  exist), an engagement detector mod-side, tests in the standing T-suite
  shape. The genuinely new design work is the release condition ("fight
  over") and hysteresis constants. No new ongoing cost.

### Option 3 — deeper AI suppression on the receiving side

- The evidence that this is the single biggest fidelity lever: every observed
  brain-vs-stream artifact (§1.3) is receiver-side — the re-holster, the
  pinned-but-engaged brain, the Mannequin eating cues mid-fight, the pre-fix
  tug-of-war oscillator. A puppet whose brain is genuinely off is just a
  rendered actor; the whole class dies at once, including artifacts nobody
  has catalogued yet.
- Routes, in escalation order: (a) exhaust the registered Lua surface
  (SetIgnorant is already on; probe schedule/behaviour detachment
  combinations never tried in concert); (b) **native suppression research** —
  find the brain/scheduler tick for one actor and gate it while puppeted, the
  same disassembly discipline that produced ghost_swing, with libKCD2's
  layouts as the map and exported symbols as anchors. Nothing here is proven;
  the *method* is proven. (c) The fallback that already half-works:
  re-assertion loops per fought-over state (WO-49's pattern, extended beyond
  drawn-state). This is a treadmill, but it is a shippable treadmill.
- **Honest limits, as the WO demands**: suppression fixes the receiver's
  local brain fighting the stream. It does **nothing** about which simulation
  is truth, nothing about Flow B being unverified, and it creates one new
  obligation: a fully suppressed puppet **cannot hurt the local player at
  all**, so every NPC→non-authority hit must arrive via Flow B — making the
  never-verified path load-bearing. Suppression and Flow B verification are
  a package, not separable.
- **Cohesive/effective**: high for what players actually *see*; incomplete
  alone. **Efficient**: the native route is a real research WO with
  crash-risk iterations (the SetParent/ForceMount class), but bounded scope —
  one function to find and gate.

### Option 4 — a dedicated, always-on third instance as the one source of truth

- The attraction is real: exactly one truth, no player is second-class,
  authority never moves. And the entry cost is lower than it looks — under
  the existing Rule 2 the instance would *automatically* be the world
  authority just by connecting first (lowest ready id); no rework of the
  authority concept is needed at all. Player damage already feeds in
  (0x30/0x12); player presence already feeds in (ghosts).
- **The disqualifying problem, and it is engine physics, not effort**: the
  authority's tracked set is 30 m around *its own player* because that is
  where the engine actually simulates — AI activity is proximity-gated
  (WO-26, observed at 340 m; the whole schedule/streaming system is built
  around the local Henry). A parked headless Henry is a 30 m bubble of truth
  in one field somewhere. For it to arbitrate the fight *you* are having, it
  would have to be teleported to you — and with two player groups in two
  towns it cannot be in both. The "cleanest single truth" collapses into
  "a third player who has to stand next to whoever matters most."
- Remaining costs, stated so nobody underprices them later: a third full
  game license and Steam account; a Windows machine with a GPU (no headless
  or dedicated-server mode exists or has ever been hinted at in this
  project's research); the instance must be babysat through menus, saves,
  crashes; save-state and quest-state on it diverge from everyone; and every
  session needs it running before anyone joins (or authority lands on a
  player anyway and you have built nothing).
- Input rework is *not* the big cost (damage/positions already cross); the
  big cost is that the truth it produces is only high-fidelity within 30 m
  of a Henry nobody is playing.
- **Cohesive**: in the abstract, the best; in this engine, no better than
  option 2's engaged-player authority and usually worse. **Effective**: only
  for fights that happen inside its bubble. **Efficient**: the most
  expensive option on every axis, including permanently (a machine that must
  always be on).
- Verdict: **not worth building against this engine.** The one future that
  revives it: a genuine headless/server mode, or an engine-level way to force
  full-fidelity AI simulation far from the local player. Neither is known to
  exist.

### Option 5 — what the synthesis itself surfaces: "the authority's world is already the shared arena — finish it"

The overlooked fact: in the authority's world, **both** players already
exist — one as the local Henry, one as a ghost doing real 50 ms footwork
mirrored from its owner, targetable, stimulus-deaf but combat-responsive,
now swinging with real native animations (WO-45/46/47, observed). An NPC
there can genuinely fight two player-shaped opponents at once. The shared
fight *already happens*, in one world. What was never finished is the
**return path** — making the non-authority's experience of that fight real:

1. **Flow B, verified and hardened** — the NPC's hits on your ghost becoming
   your real damage is the entire mechanism by which the shared fight
   reaches you, and it has never once been observed working across machines
   (§1.4). Attribution (libKCD2's `S_DamageEventData::Dispatch` prior art,
   GPL-caveated, or a re-derived equivalent) would also close the forge-bug
   class and let hits carry direction/type for proper reactions.
2. **Symmetric cues** — emit the swing cue on *ghost*-health drops too
   (the sensor already samples ghost health every tick for Flow B; the cue
   is one flag away), so the NPC visibly attacks whoever it is attacking.
3. **Receiver-side suppression (option 3)** so the puppet stops being a
   third combatant in the non-authority's world.
4. **Combat-scoped claims (option 2)** so the arena is always the world of
   a player who is actually in the fight, not a distant authority.

This is not a new architecture — it is the honest completion of the one that
exists, and each piece is independently testable and independently valuable.

---

## Phase 3 — the recommendation

**Build, in this order:**

1. **WO-A (measure, two humans, ~one session): joint combat on the current
   build, converged clocks.** Two players fight one NPC together near the
   authority; then near the non-authority; then 100 m from the authority.
   Instruments already exist: `mp_npc_fight` clusters multi-writer positions,
   agent logs carry claim/authority lines, kcd.log is now collected by the
   bundle. Also close the three "one install away" E2Es while the bodies are
   available (reload convergence, weather arbiter, 0x30 damage). Rationale:
   the entire field corpus on joint combat is one paragraph filmed under a
   24.5 h clock bug on a build five releases old. Building architecture
   against that would be building against noise.
2. **WO-B: Flow B verification + symmetric swing cues.** Small, and it is
   the load-bearing dependency of everything after it (§option 3 limits).
   If Flow B cannot be made to work reliably, deep suppression is *blocked*,
   not just weakened — that discovery must come early.
3. **WO-C: receiver-side brain suppression research** (Lua surface first,
   then the native gate). The single biggest visible-fidelity win under
   every architecture considered; kills the WO-49 class wholesale instead of
   re-assert-by-re-assert.
4. **WO-D: combat-scoped engagement claims with a hold** (option 2), tuned
   with WO-A's numbers. This is where the user's original concern gets its
   real answer: authority provably cannot move mid-fight, by rule, and truth
   sits with a player who is present.
5. **Do not build option 4** (dedicated instance) and **do not do option 1**
   (revert). Reasons in Phase 2; both survive the strongest steelman I could
   give them only by ignoring the engine's proximity-gated simulation and
   the code's actual claim semantics respectively.

**What would change this recommendation:**

- If WO-A shows joint combat near the authority is *already acceptable* on
  the current build → demote WO-D to backlog; WO-B/WO-C alone likely carry
  the product bar ("usually consistent" may in fact already be closer than
  the one 0.13.x observation suggests).
- If WO-A shows genuine multi-writer flapping (distinct `mp_npc_fight`
  clusters from distinct senders) → promote WO-D ahead of WO-C, and
  re-examine the WO-32 IsReady anomaly as a live mechanism rather than a
  one-off.
- If WO-B finds Flow B unfixable (e.g. the ghost-health sampler misses real
  hits at useful magnitude) → the non-authority cannot be hurt by the shared
  fight at all, deep suppression becomes untenable (§option 3 limits), and
  the fallback posture is: suppress *nothing*, keep the puppet brain as the
  local damage-dealer, accept behavioural divergence, and spend the budget
  on cue fidelity instead. That is a genuinely different product and the
  decision point should be explicit.
- If a headless/dedicated-server mode ever surfaces (engine update, new
  tooling) → re-run the option 4 analysis; its disqualifier is empirical,
  not eternal.
- If native brain suppression proves impossible after a real attempt →
  WO-C degrades to the re-assert treadmill (WO-49's pattern, extended),
  which is worse but shippable; the ordering above still holds.

**The honest product statement this implies:** the reachable end state is
"one shared fight, one shared outcome, everywhere a player is actually
looking" — authoritative position/health/death/engagement, rendered
approximations of moment-to-moment behaviour, and known blind windows
(dialogue, reload blinks) driven toward zero. That is short of the WO's
stated bar, and no option on the table — including the most expensive one —
actually reaches that bar. The bar itself should be re-set to the reachable
statement above, deliberately, by the human.
