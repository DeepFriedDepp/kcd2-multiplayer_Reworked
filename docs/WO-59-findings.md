# WO-59 — nine post-0.17.5 reports: shared causes found, fixes shipped, one design verdict

Evidence tiers as in WO-54/58, never rounded up: **observed** (in a log or a
test run this session, cited) / **code-verified** (mechanism read directly
from current source, file:line cited, not seen running) / **wire-verified**
(exercised against a real relay process on this machine, no game involved) /
**inconclusive**.

Privacy: PA = host, PB = joiner throughout. No real name, hostname, IP, or
handle appears below.

One fact that frames everything: **no post-WO-58 log bundle exists on this
machine.** The newest tester evidence is WO-58's own input set
(`docs/WO-58-test-logs/`, exported 2026-08-25); a full-tree scan found
nothing newer than the 0.17.5 release artifacts. Every verdict below is
therefore code-anchored or synthetic-wire-anchored, and says so. 0.17.5
itself **did** ship every WO-58 fix as one matched set (release commit +
`docs/releases/RELEASE-NOTES-0.17.5.md` verified the published agent and
rebuilt pak before packaging) — whether both testers actually installed it
is not knowable from here; the now-working version indicator (WO-58 fix 7)
is the field check.

---

## Thread A — the tracking/authority model

### A1. NPCs jittering/phasing on PB's screen

**Which oscillator fired is not determinable — no logs.** What the code
holds, three distinct mechanisms that all present as "NPCs jitter/phase for
the non-host":

1. **Restart-cascade release/resnap** (the WO instructed ruling this out
   first — it cannot be ruled in or out without logs, but the mechanism is
   real): every host game restart stops the 0x26 stream; each PB-side puppet
   is released after 3 s of silence (`kdcmp.lua`, puppet release window),
   the engine yanks the NPC back to PB's own schedule position, and the
   resumed stream snaps it away again. WO-58's freeze fixes shipped in
   0.17.5 but were explicitly never live-confirmed, so a surviving restart
   cascade would still look exactly like "the old jitter is back."
   **Code-verified**, previously field-confirmed in the WO-40 footage.
2. **Boundary flapping** — a documented ~5 s oscillator needing no restart
   and no combat (WO-38 findings: an NPC near the 30 m radius edge is
   tracked/untracked on every 2 s rescan; each release lets the engine
   restore it, each re-track snaps it back). **Fixed this WO** by
   hysteresis in `mp_npc_rescan`: an already-tracked NPC now stays eligible
   out to 1.5× radius (45 m), and tracked NPCs win near-ties for the 5
   slots via an 8 m rank bonus, so ranks 5/6 stop swapping. Code-verified
   only — the pak must be rebuilt and a two-machine session run to observe
   it.
3. **Clock divergence** amplifying the pull between stream and local brain
   (WO-38/40) — see Thread B, whose connect-time clock sync removes the
   standing multi-day divergence case entirely.

**Tester ask**: if jitter recurs on 0.17.5+, one bundle from each side
during the episode decides between 1 and 2 in minutes (restart headers vs.
`NPC-SYNC tracking/untracking` churn lines).

### A2. PB cannot see PA's clothing changes; PA sees PB's fine

**Root causes found — two code-anchored one-way mechanisms, and one of them
shipped in 0.17.5.** The WO asked for "the specific outbound-side
interference on the host's end identified before": that is WO-54 §5.1's
observation — **the host's own appearance-sync HTTP reads against its local
game timing out at 0.8 s repeatedly** while the host's game was busy (the
same session's 15 fps complaint). This session traced what those timeouts
actually *do*, and found the damage is worse than a stall:

- **Outbound (PA's side, long-standing)**: the equipped-set read is two
  REST calls merged, and each half swallowed every failure to an empty
  list (`HttpGameTransport.ReadItemClassMapAsync`). A total failure made
  the loop silently skip (including the 30 s heartbeat) — self-healing but
  gappy. A **partial** failure (one endpoint answering, one timing out)
  produced a real-looking *smaller* outfit, which the loop sent as a
  genuine change — peers then visibly stripped half of PA's clothes until
  the next good read. The host is the machine whose 1403 is busiest
  (relay + authority scans + hit sensor run there), which is exactly why
  this interference is one-way. **Fixed**: a failed half now makes the
  whole read `null` ("don't know"), and the loop skips a null poll and
  logs the outage once (`[appearance] local equipped-set read failed`).
- **Receiver (PB's side, a WO-58 regression, shipped in 0.17.5)**: WO-58's
  never-equip blacklist took its pass/fail verdict from a read that
  returned `[]` on *any* HTTP failure — so **one timed-out final verify
  read made every pending item look unequipped and blacklisted the whole
  batch for the ghost's lifetime** (`GameBridge.VerifyAndRetryAsync`).
  From that moment, PA's clothing changes involving those classes never
  applied on PB again until reconnect, while PB→PA stayed fine. This is
  the exact shape of the report, on the exact release the report came in
  against. **Fixed twice over**: (1) a failed verify read now proves
  nothing — items return to the heartbeat retry pool and nothing is
  blacklisted (a null-vs-empty distinction the transport now makes);
  (2) blacklist entries now **expire after 10 minutes** instead of
  lasting the ghost lifetime, keeping ~95% of WO-58's churn reduction
  (one 10 s retry cycle per item per 10 min, vs. one every 30 s) while
  letting legitimate changes heal.

Both fixes are **code-verified**; the causal chain (host REST timeouts →
observed) is anchored in WO-54's logs but the specific report instance has
no bundle.

### A3. Combat one-sided: PA ran to help PB, saw PB fighting nothing

**Working as currently designed, and the design is the problem.** The
guard fighting PB was never tracked if it stood more than 30 m from *PA's*
body: the tracked set is centred on the authority's own player
(`mp_npc_rescan` scans around `player:GetWorldPos()` on the authority
only), and WO-51 already recorded both halves of this report as live
by-design gaps — "two players fighting away from the authority get zero
NPC sync" and "an NPC attacking the non-authority renders no swing for
anyone" (`docs/WO-51-findings.md` §1.4, rows "Radius gap" and "Engagement
asymmetry"). No new bug here; the report is the design gap presenting in
the field, again.

### The design verdict the WO asked for, stated plainly

**Yes — the evidence now supports changing the host-centred model, and the
change should be per-NPC authority by player proximity/engagement, built
by generalizing the claim mechanism that already exists.** The reasoning:

- Three of this WO's nine reports (A1, A3, and the combat half of the
  WO-51 corpus) trace to the same single fact: truth is centred on one
  player's body. Every patch this session shipped around it (hysteresis,
  clock sync) narrows symptoms; none touches the centre point.
- The counter-argument that once justified the design — "the engine only
  simulates AI near the local player, so the authority's world is where
  fidelity lives" (WO-51 option 4's disqualifier) — argues **for**
  per-NPC nearest-player authority, not against it: the player standing
  next to an NPC is precisely the machine simulating it at full fidelity.
  A host 2 km away is streaming a low-fidelity or *unsimulated* copy, or
  (report A3) nothing at all.
- The machinery is mostly built and this session **wire-verified it
  again** (T10–T14 pass, 29/29): the relay already arbitrates per-entity
  claims — claim-by-sending, first-claim-wins, refresh-by-packet, 5 s
  expiry, authority muted while claimed. Today only the drag sensor uses
  it. The change is: the non-authority also runs the rescan/emit loop for
  NPCs near *its* player and sends them as claims; the relay needs a
  hold/hysteresis so claims cannot flap mid-fight (WO-51 option 2's
  design sketch, unchanged).
- **Not shipped this session, deliberately.** It changes joint-combat
  dynamics on every live session, cannot be observed from this shell, and
  WO-51's ordering (measure joint combat first — WO-A, which has still
  never run) exists precisely so an architecture change lands against
  data instead of against report prose. The honest cost of skipping the
  measurement forever is also now visible: the measurement keeps not
  happening while field reports accrue. Recommendation: the next
  two-human session runs WO-A's three scenarios **and** flips on a
  prototype proximity-claim build in the same sitting — the claim-table
  T-suite covers the relay half; what needs live eyes is only the Lua
  emit gate and the two-stream handoff feel.

---

## Thread B — reload/save time gaps

### B1. Day/night desync after loading a genuinely old save

**Root cause found, and it is not a broken catch-up — there is no catch-up
at connect at all.** The WO's hypothesis (mechanism designed for small
drift, breaks on multi-day gaps) is close but the failure is simpler:

- The clock is an absolute uint32 of world-seconds (days included);
  **no modular/mod-24h arithmetic exists anywhere in the sync path**
  (`% 86400` appears once, display-only). A multi-day forward write is a
  single `Calendar.SetWorldTime` and works — no aliasing bug. Code-verified.
- But 0x28 fires **only** on marker skips, settled clock jumps, and skip
  ends. Two players who *connect* with saves days apart exchange nothing:
  the divergence persists until someone happens to sleep — and then only
  the behind player converges (applies are forward-only; the engine
  ignores backward writes). Nobody slept ⇒ "persisting rather than
  converging", exactly as reported. The reload-convergence path (WO-40
  Phase 4) fires only on a *mid-session* backward jump — loading the old
  save *before* connecting is invisible to it (`_lastPolledWorldTime` is
  nulled on disconnect). Code-verified.

**Fixed — the general case, as the WO demanded**: a new `TimeSkipUp`
phase, `TimeSkipPhaseSync` (3): each agent announces its clock once when
its first post-connect world-time reading arrives, and again whenever a
new peer's ghost first appears (so both join orders converge). The relay
rebroadcasts it as done-quiet with **no** active-skip bookkeeping;
receivers apply through the ordinary forward-only path and it feeds the
reload-convergence peer-clock cache. The behind player leaps the whole
gap — hours or days — the ahead player no-ops. A quiet apply that moves
the clock more than an hour shows one neutral line ("Clock synced forward
to the session's time") so the sky doesn't change silently.
**Wire-verified** on a real relay this session (new T5b: phase 3 in →
done-quiet out to both peers, sender hears nothing, skip arbitration
untouched — 29/29). The in-game apply of a multi-day write is
code-verified only (WO-38 live-verified +10 h; nothing has live-verified
+3 days).

### B2. PB invisible to PA after a reload — the longstanding mystery

**Two mechanisms found; both closed. Shared cause with B1: same trigger,
different machinery — one reload fires both, which is why the original
WO-38 Section G report contained *both* symptoms at once** ("PB was
completely invisible... it was nighttime for PB and daytime for PA").

1. **WO-38's candidate (a), now code-confirmed**: outbound positions were
   purely change-gated (`if (!_hasPushed || HasChanged(...))`) with no
   heartbeat. After PA's reload destroys ghost entities, Reconcile clears
   the stale row within 5 s — but the respawn needs one inbound position
   packet, and a PB who is standing still (fighting in place, in a menu,
   AFK) sends **nothing, indefinitely**. PB stays invisible until they
   walk. **Fixed**: a 2 s position heartbeat (one 18-byte packet per 2 s
   of stillness), which also hands late joiners their spawn trigger.
2. **A new one, explaining WO-28's eyewitness shape** ("nametag walking
   with no body under it"): `KCD2MP_ReconcileGhosts` tested only "does
   the spawn name resolve". A reload of a save that *embeds* a same-id
   ghost body (saved with that ghost standing nearby, reloaded in the
   same session so relay ids match) destroys the tracked entity but
   leaves the name resolving — to a **different** entity. The old test
   passed forever: interp wrote to the destroyed entity, the nameplate
   walked on (it renders from the interp table), the body was invisible,
   and WO-58's stray sweep never fired (the name is tracked). **Fixed**:
   Reconcile now compares entity identity (`tostring(live.id)` vs the
   tracked `entityId`); a mismatch removes the imposter body and falls
   through to the normal clear-and-respawn path.

Both fixes code-verified; neither is live-observed (the failure needs a
two-machine reload scenario this shell cannot run).

### B1+B2 shared-cause verdict

Same class — "a reload/old save carries state the sync layer's trigger
points never see" (the WO-58 gender fix's class, as the WO suspected) —
but **not one shared defect**: the clock gap needed a missing connect-time
exchange, the invisibility needed a missing heartbeat plus a missing
identity check. They co-occur because one reload trips all of them at
once.

---

## Thread C — the ghost catching PA stealing, killing them silently

**Category confirmed: a local ghost-brain perception event, not
authority/tracking. The trigger evades the existing fix for one of two
reasons, and this session closed the closable one and instrumented the
other. The silent kill itself is a known, documented render gap — not
new.**

- The stimulus-deafness fix is a single `AI.SetIgnorant(id, 1)` applied
  **once** at spawn, pcall-wrapped, **result discarded, never re-asserted,
  never read back** (`KCD2MP_SpawnGhost`). If that one call failed or the
  engine dropped the flag, the ghost's brain was a fully perceptive crime
  witness all session with zero evidence trail. **Fixed**: the spawn call
  now logs its result, and the agent's 2.5 s re-arm cadence re-asserts
  ignorance on every live ghost (`KCD2MP_ReassertGhostIgnorance`, failures
  logged once per ghost). Code-verified.
- Whether `SetIgnorant` even *covers* crime-witness events was always
  documented as untested: the scriptbind doc promises "system signals,
  visual and sound stimuli" (WO-32 §1f, "Untested"), the WO-36 crime probe
  session that would have answered it never ran, and WO-40's default-on
  was motivated by the ghost as crime *victim* (pickpocket), not witness.
  This field report is the first evidence bearing on the question, and it
  leans **against** coverage — but with the flag never verified applied,
  it cannot separate "flag lost" from "flag doesn't cover this."
  **Inconclusive by the evidence; now decidable**: if a catch-a-thief
  reaction recurs while the logs show ignorance asserted and no failures,
  the coverage gap is proven and the answer moves to WO-36's crime-system
  probing (or a native perception gate). `mp_ghost_calm` remains the
  in-session recovery for an already-hostile ghost.
- **The silent kill**: a ghost brain's own attacks deal real damage with
  almost no rendered animation — observed live in WO-39 Phase 6 ("its own
  attack animations barely rendered — our locomotion loop stomps the
  brain's combat anims"), and structurally expected: the mod's native
  swing path (WO-45/46/47) fires only on *wire* swing events from the
  remote player's inputs; nothing observes the local brain's attack
  decisions (Mannequin-locked, no OnAction hook), and a brain-in-combat
  Mannequin eats one-shot cues. No scripted "caught you" stealth-kill
  sequence is involved anywhere in the mod. The dialogue ("I've got you
  now!") is the donor soul's authored voice set — the mod generates and
  suppresses no dialogue. So: real damage, invisible swing, audible bark —
  precisely the report. This is WO-51 option 3's territory (receiver-side
  brain suppression); no patch-scale fix exists.

---

## Thread D — the FPS reports: which of two threads?

**Undeterminable this session — the evidence to sort it does not exist.**
Findings, stated exactly:

- No post-WO-58 bundle, log, or file exists on this machine (full-tree
  and Desktop/Downloads sweep). The reporters' logs were never collected.
- The deploy question the WO said to check first: **0.17.5 was a full
  matched-set release** (Setup.exe + DirectInstall zip, agent version and
  pak markers verified at packaging per the release notes). A *partial
  install by a tester* remains possible and invisible from here — but
  WO-58's version-ipc fix means the launcher's version indicator now
  actually works in the field; both machines showing 0.17.5 rules the
  deploy class out.
- The "base-game alt-tab FPS issue already identified as probably not
  mod-caused": **no such statement exists anywhere in this repo's docs**
  (searched broadly). It presumably lives in an uncommitted conversation.
  Recorded here as prompt-sourced and unconfirmed; nothing can be
  attributed to it evidentially.
- WO-58's flood fix *reduced* one identified FPS contributor and was
  explicitly "reduced, not proven gone"; no frame-time counter has ever
  run in a session.

**Shipped so the next report is sortable**: a frame-rate floor sampler in
the mod's emit tick. `Script.SetTimer` fires on frames, so each tick's
delta is max(interval, frame time): below ~50 fps the average delta *is*
the frame time. It logs `[KCD2-MP] tickstat avg=... max=...` every 15 s
while degraded (below ~25 fps) plus a 60 s baseline — into kcd.log, which
the WO-58 bundle already collects. Zero new dependencies, pure arithmetic.

**Tester ask**: when FPS drops, note whether an alt-tab preceded it, and
Collect Logs during the episode. The tickstat lines plus the agent log
will separate mod-load (hit floods, REST churn) from a base-game issue in
one pass.

---

## Thread E — chickens (and animals) not syncing

**Working as designed — confirmed.** The NPC-sync filter admits exactly
three entity classes: `NPC`, `NPC_Female`, `Horse` (`mp_npc_rescan`;
horses deliberately, WO-38 Phase 5). Chickens, dogs, deer and every other
animal class were never in scope, and runtime-spawned ambient animals are
doubly excluded — their generated names don't travel across saves (the
WO-40 per-save-name finding; same reason runtime horses are excluded at
the protocol level). Not a bug; now written down for testers below.

---

## Tester-facing guidance (delta over WO-58's list)

- **Animals don't sync — by design.** Only human NPCs and authored-name
  horses are mirrored. A chicken behaving differently on two screens is
  not a bug report; please stop filing it.
- **Old saves with different dates are now converged at connect**: the
  player further back in time gets pulled forward to the session's clock
  within ~10 s of both being connected ("Clock synced forward to the
  session's time"). If day/night ever diverges *and stays* diverged on
  the next release (whichever version string the user cuts), that's a
  new bug — collect logs.
- **Clothing changes that stop syncing should now self-heal within
  10 minutes** at worst (usually the next 30 s heartbeat). A one-way
  clothing freeze lasting longer than that on both machines' current
  builds is a new bug — collect logs on the machine that *cannot see*
  the changes.
- **Standing perfectly still no longer makes you unspawnable** to a peer
  who reloaded. If someone is invisible for more than ~10 s while their
  connection is up, collect logs — the old known cause is closed.
- **A ghost may still catch you committing a crime.** Stealing in front
  of a peer's ghost can trigger a real witness reaction (bark + attack
  you can barely see). Mitigations shipped; if it recurs, the log lines
  `SetIgnorant at spawn` / `ReassertGhostIgnorance` in kcd.log are what
  we need — Collect Logs after any such incident.
- **FPS drops**: note alt-tab correlation, Collect Logs during (not
  after) the episode. The game log now carries `tickstat` frame-time
  lines whenever FPS is genuinely low.
- Everything here needs **both machines on the same release** (matched
  set), as always. The launcher's version indicator works now — check it.

## Fixes shipped in this WO (summary)

| # | Where | What | Evidence |
|---|---|---|---|
| 1 | `HttpGameTransport` + `IGameTransport` + `LogTailGameTransport` | equipped-set reads return null on any failed half — failed ≠ empty, partial reads can't masquerade as outfit changes | code-verified |
| 2 | `GameBridge.AppearanceLoopAsync` | null reads skip the poll, outage logged once (host-outbound interference) | code-verified |
| 3 | `GameBridge.VerifyAndRetryAsync` | failed verify reads prove nothing: no blacklist on them; intermediate failures skip the round | code-verified |
| 4 | `GameBridge` `_ghostNeverEquips` | blacklist entries expire after 10 min instead of ghost lifetime | code-verified |
| 5 | `GameBridge` position loop | 2 s position heartbeat while standing still (reload-invisibility candidate (a)) | code-verified |
| 6 | `kdcmp.lua` `KCD2MP_ReconcileGhosts` | entity-identity check: save-embedded imposter bodies removed and respawned (WO-28 nameplate-no-body shape) | code-verified |
| 7 | `Protocol` + `ClientSession` + `GameBridge` | `TimeSkipPhaseSync` (0x28 phase 3): clock announced at connect + on new peer, relayed done-quiet, forward-only apply — multi-day save gaps converge without anyone sleeping | wire-verified (T5b, 29/29) |
| 8 | `kdcmp.lua` `KCD2MP_ApplyTimeSkip` | >1 h quiet convergence shows one neutral message | code-verified |
| 9 | `kdcmp.lua` `mp_npc_rescan` | tracked-set hysteresis: exit radius 1.5×, 8 m sticky bonus (boundary-flapping oscillator) | code-verified |
| 10 | `kdcmp.lua` + `GameBridge` re-arm | `SetIgnorant` result logged at spawn; re-asserted every 2.5 s with once-per-ghost failure logging | code-verified |
| 11 | `kdcmp.lua` `KCD2MP_EmitTick` | `tickstat` frame-rate floor sampler (Thread D instrumentation) | code-verified |
| 12 | `tools/Test-TimeSkipRelay.ps1` | T5b: sync-phase relay routing case | observed (29/29 pass) |

Suites: Farkle 59/59 pass; both solutions build clean;
Test-TimeSkipRelay 29/29 against a live relay process. No `VERSION`
change (user owns versions). The Lua changes are inert until
`Build-And-Install-Mod.ps1` rebuilds the pak, and agent/relay changes
ship only as a full matched-set publish — WO-58's deploy rules unchanged.
