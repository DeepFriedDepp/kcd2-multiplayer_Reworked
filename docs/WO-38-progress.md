# WO-38 progress

2026-08-18, one session. **The game could not be launched this session** (the
human's answer to the launch request), so the shape was: full evidence read,
build everything buildable, wire-verify with synthetic peers, document every
live-gated step. No claim below involves a real second human; wire tests used
synthetic TCP peers against the real relay with no game process.

1. **Evidence intake first**: both testers' launcher logs copied into
   `docs/WO-38-test-logs/` and committed, then read IN FULL (6,748 + 4,687
   lines, delegated full-read extraction). Headline negative: **zero game or
   MP telemetry in either file** — launcher-UI logs only. Real content: the
   4.5-hour dead-master-server saga (localhost:5000, fixed ~15:55 by the
   EnsureLocalMasterServerAsync build), 16/18 successful host probes, two
   unexplained sub-second launcher crashes on A. Save declared disposable by
   the human; video exists (`Downloads/TestingEvidence.mp4`) but no local
   frame tooling — flagged per-phase where a frame would settle something.
2. **Phase 1 (time sync) — built + wire-verified.** New scriptbind evidence:
   `Calendar.SetWorldTime` documented "Must not be set backwards" (design is
   forward-only everywhere); `SkipTime` bind is UI-strings only, so no
   programmatic vanilla-skip trigger exists — receiving side is the direct
   clock write. Wire 0x28/0x29 (start/done/done-quiet + kind byte); relay owns
   ONE active skip per session, first-come by arrival order, joiners absorbed,
   late joined dones forwarded quiet (converge-up on overshoot, single
   notification), bare done = fast-travel instant skip, 180 s timeout +
   disconnect → 120 s grace. Agent: AfterSkipTime marker edges + a 10 s
   clock-jump watcher with echo guards; mod: forward-only apply + the toast
   ("slept till / passed time to"). `tools/Test-TimeSkipRelay.ps1`: **15/15
   PASS**. Live battery documented (Calendar round trip, 10 h jump, side
   effects, bed/wait/fast-travel marker diff → kind wording).
3. **Phase 2 — blocked on the game, mechanism analysis written**: clock
   divergence + 30 m boundary flapping account for the reported phasing
   without a new authority bug; the one dueling-authority candidate is the
   WO-32 half-joined-session anomaly (reconnect windows). Section G's
   invisible-PB not explained by code; candidates recorded.
4. **Phase 3 (interp) — built**: burst packets no longer zero the velocity
   estimate; DR projection holds at cap instead of reverting (the literal
   two-steps-forward-one-back); backward corrections damped 0.15; jump =
   vz-based airborne state, snap-down suppressed while airborne, probed jump
   anim (can't-misfire candidate list). Eyeball verification gated.
5. **Phase 4 (combat visibility) — root cause from code**: a missing sync
   channel, definitively (nothing combat-shaped is ever emitted), needs its
   own WO. Frozen-standing-death = WO-28 design; built the missing body cue
   (one-shot probed fall/lie pose on owner death; tag unchanged).
6. **Phase 5 (horses) — built + wire-verified**: 0x2A/0x2B mount identity by
   authored entity name (captured from the riding check's Method 0); receiver
   ADOPTS the same-named local horse (released, never deleted) with proxy
   fallback + late-identity swap; idle horses now travel on the NPC-sync
   channel (double-driver guards both ways); Horse-class puppets get horse
   gaits. ForceMount-onto-world-horse and stream-vs-horse-AI are live-gated.
   Section D's "gray for PB too" line matches no code path — video question.
7. **Phase 6 (knockout/drag) — built + design call flagged**:
   actor:IsUnconscious freezes ghosts (local KO or owner flag) and NPC
   puppets (local KO or new 0x26 flags bit 1); dead/KO puppets follow
   authority stream moves > 0.5 m as one-shot placements (authority drags
   sync; ghost corpses stay frozen per WO-34). Non-authority drags need
   per-entity authority migration — flagged to the human, not decided.
8. **Phases 7/8/9 — investigated, probes shipped instead of blind fixes**:
   `mp_ghost_ignorant on|off` (SetIgnorant A/B for the stuck barks — checks
   the reactive-combat regression edge too); `mp_map_marker <type|sweep>`
   (GameRules.AddMinimapEntity found documented — the ghost entity is already
   position-synced, so a rendering hit makes the map feature trivial);
   forge bug = WO-28 Flow B has no damage attribution, so environmental
   damage to the ghost standing in the forge in the authority's world relays
   to the smith as real hits — one hypothesis, live observation spec'd, no
   guessed patch. Clothing: shirt/pants likely live outside the two equipment
   maps polled (one-read live probe spec'd); the 5-min delay's leading
   explanation is that day's half-applied install.
9. **Suites**: Farkle 59/59, installer detection 21/21, new wire test 15/15.
   Installer lifecycle suite deliberately not run from this shell (AppData
   sandbox redirection — human-run only). Game-dependent E2Es not run (no
   game). Deliverables: findings, this file, and
   `docs/WO-38-tester-checklist.md` (plain-language, all phases, includes
   which files testers must send back so the next round isn't dark).
10. **Not done / next session**: the entire live battery (findings §"What is
    left", in order); pak rebuild + install before ANY of this is live;
    no VERSION change (human owns the string).
