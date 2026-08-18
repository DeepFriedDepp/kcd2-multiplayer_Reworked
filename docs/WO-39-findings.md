# WO-39 — combat visibility first, then everything else WO-38 found

Worked 2026-08-18. **The game was available for the whole session** — a live
battery ran on the real 0.13.6 stack (launcher, agent, relay, game), with the
human at the machine eyeballing every visual claim. Evidence discipline as
always: **observed / read-but-unrendered / inconclusive**, never rounded up.

**No test involved a real second human.** Every cross-machine result used
synthetic TCP peers against the real relay and the real agent, plus (for
combat specifically) the real player fighting while a synthetic-peer ghost was
watched. Each result below states which. The 0.13.6 release (user-chosen
version, built mid-session at the human's request) contains everything here.

---

## Phase 1 — combat visibility (the point of this WO) — **SHIPPED + LIVE-VERIFIED, with one honest ceiling**

### 1.1 What is actually reachable on this build (all probed live)

- **All four Human binds are REGISTERED and work**: `IsWeaponDrawn()` (reads
  false sheathed, flips on a real draw — observed), `DrawWeapon()` (visible
  weapon-out on a ghost, re-confirmed), `HolsterWeapon()`, `PlayAnim()`.
  The documented-vs-registered trap did not bite here.
- **Real melee input names, from the mp_log_actions live pass**: a swing is
  one `attack_primary_mouse` press/release pair; blocking is `block` firing
  activation `hold` (spammed per frame) and `release` — **never `press`**,
  so the shipped handler edge-detects the first hold. `attack_abort` fires on
  releases and is deliberately not treated as a swing.
- **Which combat animations render via `StartAnimation`, established by
  playing them at a live ghost while the human watched** (~7 eyeball rounds):
  - Full swings are **Mannequin-locked**: every real strike is a `1d-`
    parametric blendspace that "starts" (returns true) and never renders;
    the plain `natk_*_upper` clips are upper-guard partials that read as
    blocking; `Human.PlayAnim` with the real fragment names (`FreeAttack`,
    `CombatAttack`, `CombatHit`, `FreeBlock`) executes fault-free and renders
    nothing on a ghost.
  - What DOES render and read correctly: **guard idles**, **`blk` block
    reactions**, **hit flinches**, and **guard transitions**. Naming decode
    that unlocked it: `lg`/`rg` = left/right guard (`rg` raises the sword
    arm and reads right; `lg` raises the empty left arm — the "blocking with
    an invisible shield" the human reported), `sz` = distance zone, `az`/`dz`
    = attack/defense zone.
  - Sources: the real Mannequin databases (`kcd_male_combat_database.adb`,
    `kcd_male_combat_generated.adb`), extracted from `Animations.pak` on disk
    after `System.LoadXMLFile`/`ScanDirectory` proved dead from Lua.
- **Two stomping mechanisms found and fixed, both confirmed live**:
  1. `KCD2MP_UpdateAnimation` restarts locomotion every 20 ms tick and kills
     a one-shot before a frame renders → one-shots now set a
     `oneShotUntil` window the animation loop respects.
  2. The per-tick `SetWorldPos` writes ALSO interrupt one-shots (swings
     played on a stationary unstreamed ghost and never on a streamed one) →
     a one-shot now **pins the ghost** (≤1.5 s, istate keeps integrating
     underneath, catches up after). This also killed the up/down z-snap
     jitter reported during blocks.

### 1.2 The wire

`0x2C CombatEventUp [event:1]` / `0x2D CombatEventDown [src:1][event:1]` —
discrete events (0=drawn 1=sheathed 2=swing 3=block), the PlayerHit shape,
NOT a widened Position. Cosmetic by construction: no damage flows through
this layer, so a spoofed event can wave a sword and never hurt anyone.
Broadcast, no authority gate (a fact about the sender, like HorseInfo).
Drawn-state 30 s heartbeat for late joiners; sheathed is the default and is
not heartbeated. Swings rate-limited mod-side (150 ms). Next free byte: 0x2E.

### 1.3 What ships on the ghost

- draw → `DrawWeapon` (real equipped weapon out), sheathe → `HolsterWeapon`.
- weapon-ready **right-guard idle** while drawn
  (`combat_rg_sz1_idle_lngsw_player`) — human-confirmed correct read.
- block → `combat_rg_sz1_dz0_blk_slash_lngsw` — human-confirmed correct read.
- swing → fast right-to-left **guard transition** at 1.6×
  (`combat_rg_sz1_idle_to_lg_sz0_idle_lngsw`) — human-verdict "usable" as an
  attack read at a few metres. **This is a cue, not a true swing** — real
  swings stay Mannequin-locked on this build; stated as the honest ceiling,
  deferred until someone finds a Mannequin-level lever.
- `Human.PlayAnim` escape hatch stays behind `mp_combat_frag` for future
  live tuning. New commands: `mp_combat_probe`, `mp_ghost_combat`,
  `mp_log_actions`, `mp_combat_frag`.

### 1.4 Test results, stated per mode

- **Wire (synthetic peers, no game)**: `Test-TimeSkipRelay.ps1` T9 — draw +
  swing broadcast in order, no own-echo. PASS.
- **Outbound E2E (REAL FIGHTER + synthetic peer)**: the human's real draws,
  swings and blocks arrived at a listening synthetic peer as the correct
  event bytes, repeatedly (`Test-CombatVizE2E.ps1`, three runs). This is the
  full mod → agent → relay → wire path under real combat input. VERIFIED.
  (An explicit sheathe event was never isolated on the wire — the human
  re-drew rather than sheathed during listen windows; the transition
  detector is symmetric, so this is noted, not worried about.)
- **Inbound E2E (synthetic peer → real ghost, human watching)**: draw and
  the guard idle render over the wire; swings/blocks render as partial cues
  after the pin fix ("not full animations but looks like he is trying to
  swing"). The ghost facing away and snapping was a HARNESS artifact — the
  synthetic peer streams the player's own rotation; a real peer streams the
  fighter's actual facing.
- **Item O (combat on a puppeted NPC)**: NOT observed as specified — no
  second real player to run the NPC stream during a fight. What the session
  did establish live: the puppet stream holds an NPC pinned with no
  vibration (Phase 9.3), and a KO'd/dead puppet freezes (WO-38 code, still
  in place). The direct fight-a-puppeted-NPC observation stays with the
  two-human round.

### 1.5 Regression check

- WO-28 health/death reporting: emit line v2 unchanged; ghost vitals and
  `[dead - reloading]` untouched. The E2E sessions ran the full emit path
  throughout with no health regressions observed.
- WO-26/27 reactive aggro: live-reconfirmed incidentally — the test ghost
  fought back and hurt the real player twice when attacked (no toggle, as
  shipped). NEW observation: the ghost's own attack animations barely render
  — our locomotion loop stomps the brain's attack anims, the same mechanism
  1.1 fixed for one-shots. Follow-up candidate: suppress the loop while the
  ghost's own brain is in combat.
- WO-38 death pose: code path untouched by the pin change (corpse freeze
  branches before the one-shot branch). Not re-eyeballed this session.

### Gate 1

Built, shipped in 0.13.6, outbound verified with a real fighter, inbound
verified over the wire with draw/guard confirmed visually and swing/block as
partial cues. Deferred, stated plainly: true swing fidelity (Mannequin-locked),
hit-reactions-on-being-hit (event exists in the enum, no emitter yet), and the
two-human item O observation.

---

## Phase 2 — per-entity authority migration (item C) — **SHIPPED + WIRE-VERIFIED + LIVE-SPOT-CHECKED**

Design, deliberately packet-free: a non-authority CLAIMS an entity by sending
`NpcStateUp` for it. The relay's per-entity table (first claim wins, by relay
arrival order — the TimeSkip shape) routes that entity's stream from the
claimant and mutes the global authority's packets for it, which is also what
closes the echo loop. Claims refresh per packet, expire after 5 s of silence
(`NpcClaimTimeoutSeconds`), and clear on the claimant's disconnect. Receivers
are untouched: the WO-38 body-follow one-shot in `KCD2MP_NpcPuppetTick` is now
THE apply path for any sender — the authority-only drag-follow is subsumed,
not coexisting.

Mod side, the dragger's emitter: `mp_drag_sensor` — a downed hand-placed human
within 6 m that moves >0.3 m between 500 ms samples, where the move does not
match the inbound puppet stream's target, is being manipulated locally; its
state is emitted as `npc_drag` (agent sends it as 0x26 with the authority gate
skipped) at the ordinary cadence with a 3 s tail.

- **Wire (synthetic peers)**: T10–T14 — claim granted to a non-authority,
  authority muted for the claimed body, authority default stream intact for
  unclaimed entities, expiry restores the authority, claimant disconnect
  releases immediately. 22/22 PASS.
- **Live (synthetic peer + real game)**: a NON-authority peer's stream drove
  a real NPC (`ttkc_jakes`) in the authority's world end to end — the claim
  path works against the running stack, not just the test relay.
- **Live-gated, stated**: whether the drag thresholds match a real vanilla
  body-carry (the engine's carry mechanics were never observed from Lua) —
  solo-untestable because the local player is always the authority here, and
  the drag sensor only runs on non-authorities. Two-human item.

Races resolved per the WO: simultaneous action → relay arrival order;
handoff detection → the claim IS the stream; claimant disconnect → immediate
release (T14).

---

## Phase 3 — knockout/death replication (item F) — **ANSWERED, plus a real discovery**

All synthetic-peer + real-game, single machine:

- **A real knockout's wire shape** (captured from the human choking out a
  real NPC): NINE health-only 0x12 hits — `staminaLoss=0.00` in every one —
  flags=1, ~84 total health loss, **no death packet, no knockout packet**.
  Unconsciousness never crosses the wire; it is the engine's own low-health
  decision.
- **Replication reproduces the STATE**: replaying a health drain at a second
  NPC over the wire produced `hp=1, ko=true, dead=false` — the engine clamps
  at 1 hp rather than dying, and flips real unconsciousness itself. The
  player-damage path needs NO equivalent of 0x26 flags bit 1: driving the
  numbers reproduces the state.
- **THE gap found: the wire targetGuid is the per-save Soul `Guid`, NOT the
  `SharedSoulGuid`** Protocol.cs documents. Proven twice: the captured KO
  packets carried `ttkc_jakes`' per-save Guid (his SharedSoulGuid is a
  different value), and SharedSoulGuid-addressed packets do not apply at all
  while per-save-Guid-addressed ones do. Cross-install damage sync therefore
  depends on per-save Guid stability across saves/installs — **unknown, and
  the strongest candidate yet for the WO-38 report's "PB knocked an NPC out
  while PA's copy stayed alive"**. Flagged for the two-human round: capture
  the same NPC's wire guid on both installs and compare. If they differ, the
  candidate fix is agent-side Guid↔SharedSoulGuid translation via the
  reflection API (no DLL change needed) — deliberately NOT built on an
  unconfirmed premise.

---

## Phase 4 — horse sync live verification — **THE FOUR GATED QUESTIONS ANSWERED**

Synthetic peer + real game, human watching (`Test-HorseAdoptE2E.ps1`):

1. **`ForceMount` onto a WORLD horse: WORKS.** The ghost mounted the real
   `ttkc_horse_3` (authored stable horse); no proxy was spawned.
2. **Stream vs horse AI: the stream wins.** The mounted pair genuinely
   travelled the driven 15 m path and back.
3. **Gaits: DO NOT render** on a live-brained adopted horse ("no
   animations"), plus lateral jitter and ground clipping under the 8 ms
   transform loop (partly a harness artifact — the peer streamed a constant
   z). Render polish deferred to a follow-up WO; hypotheses recorded: the
   8 ms `SetWorldPos` cadence interrupting anims (the Phase 1 mechanism),
   and/or the real horse's own Mannequin overriding `StartAnimation`.
4. **Release: CLEAN.** On dismount the world horse returned to normal —
   interactable, own AI (human-confirmed).

The `TestingEvidence.mp4` frame check for Section D's "gray for PB too" line
was not done — no frame tooling was installed this session either.

---

## Phase 5 — the forge bug (item D) — **NOT CONFIRMED, NOT KILLED — deferred at the human's direction**

The test was mounted live (a synthetic-peer ghost pinned at a real forge's
fire spot over the wire, with the peer listening for relayed 0x22 damage) but
the human aborted the observation before it completed (no materials for the
smithing minigame; ~11 PM in-game so the fire state was unverified). Per
their direction: **the hypothesis remains unconfirmed, no fix is shipped, and
this has not been fully explored beyond WO-38's code analysis.** The
harness (`scratchpad`-grade, shape preserved in this doc) is trivial to
re-mount: pin a ghost at a lit forge, watch 0x22 to its owner and its local
health.

---

## Phase 6 — the stuck barks (item E) — **BUG DOES NOT REPRODUCE; SetIgnorant IS TARGETING-SAFE**

Live, real player attacking a real ghost:

- Baseline (ignorant off): the ghost barked during combat and **went quiet
  after** — the WO-38 "barks loop forever" report does not reproduce on
  0.13.6. (Whether the Phase 1 pin changes or different conditions — bandit
  soul, longer fight — made the difference is undetermined.)
- A/B (ignorant on): the ghost **stayed hittable and kept reacting** —
  `AI.SetIgnorant` does not break the ghost as a combat target.
- Decision per the WO's own rule: with no reproducing bug, nothing ships
  default-on. `mp_ghost_ignorant` remains a manual toggle, now known
  targeting-safe if the loop ever reproduces in the field.

Bonus observation recorded: the ghost fought back (WO-26/27 reconfirmed) but
its own attack animations barely rendered — our locomotion loop stomps the
brain's combat anims. Follow-up candidate, not built.

---

## Phase 7 — shirt/pants (item G) — **CLOSED: no missing source map exists**

Live, single machine: `TunicLong01_m01_C` + `HoseJoined01_m01_C` created and
equipped on the player via the reflection API → **both class ids appear in
`EquippedArmorsByClassId`** (the existing outbound read). Both then equipped
onto a ghost soul → read back present AND **visually rendered on both player
and ghost** (human-confirmed). There is no third equipment map to add; the
WO-38 tester report does not reproduce on 0.13.6 — consistent with WO-38's
own leading explanation (the half-applied 0.11.8 install that day).

---

## Phase 8 — skip-kind detection (item H) — **SECOND ROUTE FOUND AND SHIPPED**

The bed interaction is directly detectable: a usable bed presents a
**`BedTrigger`-class entity** (observed live, 1.1 m from the player standing
at a tavern bed). Shipped: the mod polls a 3 m sphere at 1 Hz on the emit
tick, emits `bed_near` transitions; the agent holds the latest value and
picks the kind at skip start — **at a bed = sleep ("slept till"), marker
skip elsewhere = wait ("passed time to"), clock-jump = fast travel**
(unchanged). All three kinds now resolve; kind=unknown retires from normal
operation. Wire verification of sleep/wait kinds rides the final install
round (the kind picker lives agent-side and needs the new agent running).

---

## Phase 9 — WO-38 live-battery leftovers — **ALL THREE ADDRESSED**

1. **Long real fast travel** (real player): exactly ONE announced instant
   skip on the wire — `kind=fast-travel, worldTime=601558` — captured by a
   synthetic listener. The clock-jump watcher behaves on a real long trip.
2. **Quest-timer interaction**: not exercisable — no timed quest on this
   save. Recorded, not glossed.
3. **Residual-phasing tug-of-war** (synthetic peer driving a real NPC 10 m
   off-anchor for 30 s): the >5 m gap rule snapped him to the target, then
   he **pinned steady — no vibration, no tug-of-war**. Mechanism 1 of the
   WO-38 phasing account did not reproduce solo. Noted: after release the
   engine did NOT re-anchor him (he stayed at the driven spot, idle) —
   WO-32's "restores within 3 s" is evidently schedule-dependent, not
   guaranteed. The two-human half (converged clocks, real session) stays
   with the testers.

---

## Phase 10 — diagnostics bundle (item K) — **SHIPPED**

- The agent now tees all console output to `agent.log` next to the exe
  (previous run rotated to `agent.prev.log`), timestamped in the file copy;
  the console stays byte-identical. Failure to open the file degrades to
  console-only, never fatal.
- The launcher's REPORT A BUG modal gains **COLLECT LOGS**: kcd.log (from
  the configured game root), agent.log + agent.prev.log, the two newest
  app logs, and config.json, zipped to the Desktop with a timestamp — all
  opened with full sharing since three of those files are held open by
  running processes. Partial bundles beat no bundle: missing files are
  skipped.

---

## Phase 11 — launcher crashes + log noise (items I, J) — **RESOLVED / MITIGATED**

- **The "two silent sub-second crashes" are unproven crashes.** Both
  33-line boots end cleanly after the first full render pass, and the
  launcher never logged ANYTHING on a normal exit — so a fast manual close
  produces exactly the reported signature. The timeline (four boots in 42 s
  at 11:44, during the dead-master-server fight) points at manual restarts.
  Shipped: a `=== Launcher exiting (clean) ===` marker — any future boot
  that ends without it is real crash evidence instead of a guess.
- **Render/log noise**: the per-component render narration was ASP.NET
  Core's own Debug logging (~80% of both testers' files). Shipped: a Serilog
  `MinimumLevel.Override("Microsoft.AspNetCore.Components", Information)` —
  the launcher's own Debug lines stay. The triple-render itself (a Blazor
  cascade) was deliberately not chased, per the WO's instruction. The
  31-identical-stacks master-server pattern was already downgraded to
  Debug/Warning by WO-38's connectivity fix.

---

## Phases 12 (map markers) and 13 (NPC scale) — **CUT, per the WO's priority rule**

The session ran long on Phases 1–9; the prompt's instruction is explicit —
protect combat correctness and cut from the bottom. Map markers remain where
WO-38's live battery left them (documented routes dead; the map-panel
UIAction enumeration unstarted). The NPC apply-cost measurement at 8–10 NPCs
remains unmeasured; the 5-NPC/30 m cap is unchanged.

---

## Suites

- `Test-TimeSkipRelay.ps1`: **22/22 PASS** (T1–T8 unchanged, new T9 combat
  events, T10–T14 per-entity claims). Synthetic peers, no game.
- `Test-ReleaseVersion.ps1`: **6/6 PASS**. `Test-InstallerDetect.ps1`:
  **21/21 PASS**.
- Farkle suite: run at release build time (unchanged code).
- Installer lifecycle suite (41 tests): **human-run only** (AppData sandbox
  redirection) — to be run before distributing 0.13.6.
- New harnesses checked in: `Test-CombatVizE2E.ps1` (Phase 1 E2E, needs the
  live stack + a human), `Test-HorseAdoptE2E.ps1` (Phase 4, same).

## The 0.13.6 release

Version chosen by the user mid-session. Contains: the combat visibility
layer, per-entity authority, skip kinds, the diagnostics bundle, launcher
log fixes, and every live-tuning fix above. The installer artifacts are
rebuilt at session end so they carry the final pak; the installer lifecycle
suite and actual distribution remain the human's.
