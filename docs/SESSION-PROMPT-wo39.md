# Session prompt — WO-39: combat visibility first, then everything else WO-38 found

Paste everything below the rule into a fresh session, working directory
`C:\Users\Jonasty\Documents\KCD2_MP`. Prefix commits `WO-39:`.

---

## Priority, stated plainly so it survives a long session

Combat visibility (Phase 1) is the reason this WO exists. It's the single
biggest gap a real tester will notice — most of what two people actually do
together is fight, and right now an observing player sees a friend standing
still with their arms down through an entire real fight. Phases 1–3 (combat
visibility, per-entity authority, knockout/death correctness) are combat
correctness as a group, not three unrelated items. If this session runs long,
protect Phases 1–3 and cut from the bottom of the list — never the reverse. A
clean, well-tested combat fix and nothing else is a better outcome than ten
shallow fixes and a rushed combat implementation.

Explicitly out of scope, on purpose: the crime/reputation cross-machine
question and "players are fully Henry" — both were flagged in
`docs/WO-38-gaps-and-next-WOs.md` (items L and M) as needing their own
dedicated design work, not a bolt-on here. Don't pick them up even if time
allows.

## Before anything else

1. Confirm the game actually launches this session. WO-38's main session ran
   game-less; its same-day live battery (see the findings addendum) ran
   against a live game — so both modes have precedent. Check first, because
   it changes how much of this WO is buildable-and-testable versus
   buildable-only.
2. Confirm save disposability — ask, don't assume.
3. Read `docs/WO-38-findings.md` in full, **including the live-battery
   addendum** — every phase's root-cause analysis here builds directly on it,
   don't re-derive what it already found (and don't inherit the main
   session's game-less framing: Phase 1 time sync is live-verified, Phase 8's
   map-marker routes are live-confirmed dead).
4. Read `docs/WO-38-gaps-and-next-WOs.md` (the tiered gap document) in full —
   this WO implements Tier 1 items A and C, Tier 2 items D/E/F/G/H, and
   Tier 3 items I/J/K/N, plus the shipped-but-unverified horse work and the
   small live checks WO-38's addendum left open. Item B (map markers) is
   included but is explicitly the most open-ended item — lowest priority, cut
   it first if needed.
5. Same testing reality as WO-38: no real second human this session. Every
   test uses a synthetic peer, a second local agent, or (for combat
   specifically) a real player fighting while a synthetic/second-agent ghost
   is watched. State which was used for every result — don't imply two-human
   verification that didn't happen.
6. The installer lifecycle suite (41 tests) cannot run from the assistant's
   shell (AppData sandbox redirection, project memory) — it is human-run
   only. Plan suite verification accordingly.

## Phase 1 — combat visibility (the actual point of this WO)

Per `WO-38-findings.md` Phase 4: the emit line carries position, rotation,
riding/sneaking, health, stamina, dead, unconscious — nothing about combat
has ever been shared. This phase builds that.

### 1.1 — find what's actually playable

`Human.DrawWeapon()` is **documented** (WO-23 read it in the shipped
scriptbind pages) but was never observed live — verify it is actually
registered on this build before designing around it. This is the exact
documented-vs-registered trap that killed `GameRules.AddMinimapEntity` in
WO-38's live battery; check registration first, then effect. The open
research question: which combat animations (swing, block, hit-reaction,
stagger) are reachable via `StartAnimation` versus locked behind the
Mannequin system this build actually uses. Use the same probe pattern WO-38
already used for jump/death poses (candidate name lists, verify each against
this build, never assume a name plays just because it looks right) — don't
invent animation names.

### 1.2 — design the wire extension

Minimum real scope: weapon drawn/sheathed state, and a swing/attack event
that drives a combat animation on the receiving ghost. Block/stagger/hit-
reaction if 1.1 finds them reachable — state clearly what's included and
what's deferred if the full set isn't achievable this session.

Follow existing wire conventions (next free type byte is **0x2C**,
documented in the protocol table same as every prior addition). Decide
explicitly whether combat-animation state rides the existing emit channel or
needs its own lower-frequency packet (swings are discrete events, not
continuous state — probably closer to the NPC-hit packet shape than the
position stream).

### 1.3 — build it

Real code, both directions: local combat state detected and sent, remote
combat state received and played on the ghost.

### 1.4 — test as thoroughly as solo testing allows

Synthetic peer or second local agent triggering combat state, watched on the
primary screen — confirm the ghost actually swings/reacts instead of
standing still. If a real player is available to fight while watching a
synthetic/second-agent ghost, use that too.

Also test the WO-38 item O case directly: a real player fighting an NPC that
is simultaneously being driven by the NPC-sync stream (WO-32) — does combat
work correctly on a puppeted NPC, or does the position stream fight the
combat animation the same way it fought free movement before WO-38's
smoothing fix? This was flagged unobserved in the gap list — observe it now,
as part of combat correctness, not a footnote.

### 1.5 — regression check, explicit

Confirm this doesn't break: WO-28's health/death reporting, WO-26/27's
always-on reactive aggro, WO-38's death-pose fix. Combat visibility is
additive information — verify it stays that way.

### Gate 1

What's built, what's confirmed working (and how — synthetic peer vs real
fighter vs both), what's deferred and why. This is the deliverable this whole
WO is judged by.

## Phase 2 — per-entity authority (Tier 1, item C)

Today exactly one client's world dictates all NPC state. A non-authority
player's drag/knockout/kill exists only locally. Design and build a handoff:
the player actively interacting with a body/NPC becomes authoritative for
that entity's stream while acting on it.

Reuse the existing precedent, don't invent a new arbitration shape: the
TimeSkip relay logic (`docs/WO-38-findings.md` Phase 1) already solved
"first claim wins, others join" for a similar single-owner problem — adapt
that shape rather than designing from scratch. Real race questions to
resolve: what happens if the current authority and a second player both act
on the same body near-simultaneously; how a handoff is detected and
broadcast; what happens if the new authority disconnects mid-action.

This design **supersedes** WO-38 Phase 6's authority-side corpse drag-follow
(the one-shot >0.5 m placement in the NPC puppet tick) — subsume it into the
handoff model deliberately; don't leave the two mechanisms coexisting by
accident.

Test with synthetic peers, the same way `Test-TimeSkipRelay.ps1` verified
the time-skip arbitration — wire-level verification of the handoff logic is
achievable solo.

## Phase 3 — knockout/death replication correctness (Tier 2, item F)

Does a replicated hit (the 0x12 damage path, by health/stamina numbers)
actually reproduce unconsciousness on the receiving machine, or just the
numbers? Same question for a replicated kill producing clean death. Test
directly: synthetic peer sends the exact 0x12 sequence a real knockout
produces, read `IsUnconscious()`/`IsDead()` back on the local copy. If it
doesn't reproduce the state itself: that's a real gap, fix it — WO-38
already added `0x26` flags bit 1 for the NPC-sync path; determine whether
the player-damage path needs the equivalent.

## Phase 4 — horse sync live verification (shipped in 0.12.6, never observed)

WO-38 Phase 5's horse-adoption code shipped with its engine behaviour
entirely live-gated. Verify on one machine, with a synthetic peer:

1. **`human:ForceMount` onto a WORLD horse** — only ever observed onto a
   mod-spawned proxy. Set a ghost's horse identity to a real nearby horse's
   name (`KCD2MP_SetGhostHorse`), flip its riding flag, and observe whether
   the adoption + mount actually happens.
2. **Stream-vs-horse-AI** — does driving an adopted world horse's position
   win against its own AI the way it does for human NPCs (WO-32), or does
   the horse fight the stream?
3. **Gait selection at speed** — do `relaxed_walk`/`relaxed_gallop` actually
   play on a driven Horse-class entity, and do the thresholds look right?
4. **Release behaviour** — on dismount, does the released world horse return
   to normal (interactable, own AI) rather than staying wedged?

Also check the WO-38 video (`Downloads/TestingEvidence.mp4`, if frame
tooling is available this session) for Section D's unexplained "the horse
is also gray for PB" line — no code path found matches it, and one frame
may settle whether it was a misreport.

## Phase 5 — the forge bug (Tier 2, item D)

Confirm or kill the hypothesis from `WO-38-findings.md` Phase 9
(environmental damage to a ghost standing in the forge, relayed
attribution-blind by Flow B) before attempting any fix. Stand a
synthetic-peer ghost at a lit forge, watch its health and `[playerhit]`
traffic. If confirmed: fix on the evidence (candidates already named —
suppress the relay while the target's owner is in a crafting minigame,
detected via a kcd.log marker the same way WO-11 found `AfterSkipTime`; or a
damage-rate sanity cap). If not confirmed: say so plainly, don't ship a
guess.

## Phase 6 — the stuck combat-distress barks (Tier 2, item E)

WO-38 built `mp_ghost_ignorant on|off` as an A/B probe. Run it for real this
session: aggro a real NPC onto a ghost (per WO-26 mechanics), confirm
whether `AI.SetIgnorant` stops the barks and whether the ghost stays a valid
combat target. If both hold: ship it as the default for ghost spawns — this
is the behavior-change approval the gap list flagged as needing a decision,
and "barks loop forever" is bad enough that fixing it by default is the
reasonable call if the A/B comes back clean. If targeting breaks: don't ship
it default-on; keep it as a manual toggle and say so.

## Phase 7 — clothing: the shirt/pants source gap (Tier 2, item G)

Equip a shirt/pants combo, read `EquippedArmorsByClassId` back. If the class
ids are absent, walk `EquipmentManager`'s sibling maps at depth 1 for a
third source (the WO-10 weapons precedent — same pattern, same low risk).
Add the missing source to the poll if found.

## Phase 8 — skip-kind detection, second attempt (Tier 2, item H)

`kcd.log` was a confirmed dead end (WO-38 diffed a real bed sleep against a
real wait at verbosity 4 — nothing distinguishes them). Try detecting the
bed interaction directly instead: player stance/position at skip start,
proximity to a `Bed`-class entity, or a savegame-creation signal. If found:
wire it into the existing `LastSkipKind` extension point WO-38 already left
for exactly this. If not found after a real attempt: leave every skip
reporting as "passed time to," state why plainly.

## Phase 9 — WO-38 live-battery leftovers (small, do as one batch)

Three short checks the WO-38 addendum explicitly left open, all needing only
this one machine:

1. **A real long fast travel** — the clock-jump watcher was verified against
   an *emulated* advance only; the one real fast travel that session was too
   short (correctly ignored). If the save has a distant unlock, do one long
   trip and confirm exactly one announced instant skip.
2. **Quest-timer interaction with forced skips** — never exercised. With an
   active timed quest on the save (if any), force a large forward jump and
   note what the quest log/timer does. Report only; no fix expected.
3. **The residual-phasing tug-of-war** (`WO-38-findings.md` Phase 2,
   mechanism 1) — drive an NPC puppet toward a target deliberately far from
   where its own local AI wants to be, and observe the 50 ms lerp-vs-AI
   fight directly. This is the solo half of the phasing re-test: it either
   reproduces the "vibrating between two positions" report (→ tune the
   puppet write: harder pin, or `AI.SetIgnorant` on puppets) or shows the
   stream holds. The two-human half (converged clocks, real session) stays
   with the testers.

## Phase 10 — the diagnostics bundle (Tier 3, item K)

The highest-leverage process fix on the whole list: WO-38's testers sent
logs with zero game telemetry in them, entirely by accident. Build a
"collect logs" action in the launcher — `kcd.log`, the agent's output, and
`app.log`, zipped into one file a tester can just hand over. Note: the
agent's console output is likely not currently captured anywhere — adding
file logging to the agent is probably part of this item, not a given; check
first.

## Phase 11 — launcher crashes and log noise (Tier 3, items I/J)

1. Investigate the two silent sub-second launcher crashes from
   `PlayerA.log` (33 boot lines, no exception, twice) — real evidence exists
   in the log already committed from WO-38; start there before trying to
   reproduce blind.
2. The render-amplification issue (every state change triple-renders the
   modal tree, ~80% of both testers' logs) — add a log-once guard and error
   backoff if the cause is straightforward; don't let this turn into a deep
   Blazor-rendering investigation at the expense of Phases 1–3.

## Phase 12 — map markers (Tier 1, item B — lowest priority, cut first)

Both previously-known routes are confirmed dead (`GameRules`/`Map` nil,
`AddMinimapEntity` unregistered — probed live in WO-38 with a ghost
present). Enumerate the map UI's own `UIAction` surface for an element name
and exposed functions, the same way the dice board's real panel was found in
earlier work. If nothing renders after a genuine attempt: state that plainly
and stop — this is explicitly the item to drop if the session is running
long, per the priority note at the top.

## Phase 13 (quick measurement, if time allows) — NPC sync scale (item N)

The current 5-NPC/30m bound was a measured limit, not a fundamental one. If
time permits after Phases 1–3 are solid: measure the actual client-side
apply-path cost at 8–10 NPCs, not just relay bandwidth (WO-32 already showed
bandwidth isn't the bottleneck). Report the number; don't change the cap
without discussing it first.

## What this session does NOT do

- No work on items L (crime/reputation cross-machine) or M (players are
  fully Henry) — explicitly deferred to their own future design WOs.
- No `VERSION`/release changes — `docs/VERSIONING.md`.
- Don't let Phase 12 (map markers) or Phase 11 (launcher polish) consume
  time that Phases 1–3 need — protect combat correctness first.
- Don't default-ship Phase 6's `SetIgnorant` fix unless the A/B genuinely
  confirms targeting still works.

## Definition of done

- `docs/WO-39-findings.md`: one section per phase reached, Phase 1 given the
  most detail regardless of length, every test result stating synthetic-peer
  vs real-fighter-observed, gate results precise.
- Any phase not reached: stated exactly what's left, not glossed over.
- **`docs/WO-38-tester-checklist.md` revised** to match what actually shipped
  after this WO — its combat item currently says "not fixed this round,
  expectation check only," which will be wrong; the checklist must stay the
  single up-to-date battery a tester receives, not accumulate stale rounds.
- All existing suites green, including anything WO-38 added
  (`Test-TimeSkipRelay.ps1`); the installer lifecycle suite is human-run
  only, noted above.
- `docs/WO-39-progress.md` appended.

## How I want you to work

1. Combat correctness (Phases 1–3) is what this session is for — protect it
   if anything has to be cut.
2. Verify by observed effect (a ghost visibly swinging, a state actually
   reproducing) — not by a packet being sent successfully.
3. State plainly which tests used a synthetic peer versus a real fighter.
4. A genuinely closed investigation (forge bug not confirmed, map markers
   still dead) is a valid, complete result — don't force a fix.
5. Terse.
