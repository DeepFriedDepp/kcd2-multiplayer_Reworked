# WO-103 — field-session runbook

**Nothing in this WO has run against a live game.** No game process was
reachable from this coding session (same standing constraint as WO-102 and
WO-102.5's own opening sessions) -- everything below is **(code-verified)**
or **(synthetic)** until this runs. Both machines must be on a matched
WO-103 build (agent, pak, `KCDMP.dll`) -- see `docs/WO-103-findings.md` for
why a mismatched set is worse than useless here (a pre-WO-103 DLL never
answers with the extra wire bytes; an old agent never encodes them).

| toggle / command | on | off | shipped default | what it does |
|---|---|---|---|---|
| authority radius | `#KCD2MP_SetAuthorityRadius("<m>")` | -- | **300 m**, no upper clamp | not a console command -- console drops arguments (WO-94) |
| native NPC scan (candidates) | `mp_npc_scan_native_on` | `mp_npc_scan_native_off` | **on** (WO-102.5) | unchanged this WO |
| native position/yaw read | `mp_npc_read_native_on` | `mp_npc_read_native_off` | **on** (new) | position/yaw from the native push when fresh, else the live read |
| culling | `mp_npc_cull_on` | `mp_npc_cull_off` | on | unchanged this WO |
| scan known-answer check | `mp_npc_scan_compare` | | | unchanged this WO -- run before trusting `npc_scan_native` at all |
| read known-answer check | `mp_npc_read_compare` | | | **new** -- native push vs a live read for every tracked name; a real mismatch auto-disables `mp_npc_read_native` |

Bundle at the end, from both machines: `agent.log`, `kcd.log`,
`kcdmp-native.log`/`kcdmp-native.mirror.log`. `mp_summary` on both before
quitting.

---

## 0. Before anything else

1. Confirm the matched set: `NPCSCAN: first scan OK …` in
   `kcdmp-native.mirror.log` proves the DLL answers 0x0B at all; a silent
   agent-side give-up after ~100s (`MP-NPCSCAN verdict=gave-up`) means an
   old DLL that never learned the 18-byte header.
2. `mp_npc_scan_compare`: confirm `only_lua=0` before trusting anything
   downstream of the candidate list (WO-102.5's own gate, unchanged).
3. `mp_npc_read_compare`: confirm `verdict=match` (or `no-data` if nothing
   is tracked yet) before trusting the position substitution. A
   `verdict=fail-closed` here means `mp_npc_read_native` already turned
   itself off — read the `mismatches=` names it logged and stop; do not
   just flip it back on and continue, since Phase 2's own design treats any
   real mismatch as "the offset math disagrees," not noise to retry past.

---

## 1. The A/B — what Phase 0 replaced, actually measured

The whole point of Phase 0 was a baseline before Phase 2 substituted
anything. This session could not take one (no game ran). Take it now:

1. `mp_npc_read_native_off`. Walk a village for ~2 minutes with NPCs
   tracked (a few nearby, moving). Note `MP-NPCREAD path=lua n= mean_ms=
   p50_ms= p95_ms= max_ms= window_s=` lines in `kcd.log` (one roughly every
   15s while tracked NPCs exist).
2. `mp_npc_read_native_on`. Same walk, same area. Note the `path=native`
   (and possibly `path=mixed`, during the ~6s window after each scan when
   some names have fresh native data and others don't) lines.
3. **Compare `mean_ms`/`p95_ms` directly.** This is the number the whole WO
   exists to produce, and it did not run this session.
4. **Read this honestly, not hopefully**: health/dead/KO/drawn/engaged still
   call `System.GetEntityByName(name)` every tick regardless of this toggle
   (WO-103.5's job, unmapped offsets) -- so the substitution only removes
   the `e:GetWorldPos()`/`GetWorldAngles()` calls on an entity handle the
   loop was fetching anyway, not the GetEntityByName call itself. A small
   or even negligible difference here is an EXPECTED, not a failing,
   result — see `docs/WO-103-findings.md`'s "did this actually help"
   section. The substitution's real payoff completes once WO-103.5 removes
   the entity lookup entirely and this same native push covers position too.

---

## 2. The radius ceiling — test to failure

**Solo, dense town, window in focus.** WO-102.5 §6.3's own FPS reading was
retracted for exactly the opposite mistake (window unfocused, throttled by
the engine, measuring the throttle instead of the radius) — do not repeat it.

For each of **45 / 150 / 300 (default) / 600 / 1000 / beyond**, record from
`kcd.log`/`kcdmp-native.mirror.log` over ~30s standing roughly centred:

1. `#KCD2MP_SetAuthorityRadius("<m>")`. Confirm `WO1025-RADIUS set=<m>
   was=<prev>`.
2. `MP-NPCTRACK tracked=<n> culled=<n>` (Phase 0's periodic line, every
   ~15s) -- tracked is the number that matters for read cost; culled is how
   many of those are NOT being actively streamed.
3. `MP-NPCREAD path=native p95_ms=` -- watch this rise as tracked rises.
   Phase 0's design claim is that read cost scales with TRACKED, not
   streamed (culling does not help here, unlike the emit side) -- confirm
   or refute this directly against the tracked count from step 2.
4. `NPCSCAN: reply truncated -- budget=8000 bytes, matched=<n> returned,
   dropped=<n> more within radius` (native log) or `MP-NPCSCAN-TRUNCATED
   dropped=<n> returned=<n>` (agent log) -- whichever fires first. Expected
   order (state whether it holds): reply truncation (~200-400 names
   depending on length, unchanged by this WO -- see findings §Phase-2) fires
   before read-loop cost becomes the bottleneck, because the native walk
   itself is radius-independent (WO-102.5 §6.3) and only the tracked count
   scales.
5. Mod tick average (the WO-59/WO-102.5 tickstat line) -- the general
   frame-cost proxy, same as WO-102.5's own runbook used.
6. Find where it actually breaks -- a crash, a hitch that's actually felt,
   or the truncation ceiling above. **The shipped default (300m) is not
   validated by this table being run** — Phase 1 raised it on the strength
   of WO-102.5's own 150m result plus the maintainer's explicit call, not
   on a fresh measurement at 300m itself. This is exactly the gap this
   section closes.
7. **The shipped default stays whatever holds comfortably, not the largest
   number that technically ran.** If 300m already shows real cost, that is
   the finding — `#KCD2MP_SetAuthorityRadius("150")` is one line back down.

---

## 3. What this runbook cannot settle, stated plainly

Every number here (300m default, the read-substitution's real-world win,
where the ceiling actually is) is what this session could not measure
without a live game. Running §§1-2 is how they get corrected, not this
document. WO-103.5's own scope (health/dead/KO/drawn/engaged natively) is
explicitly NOT this runbook's job — see `docs/WO-103-findings.md`'s
handoff section.
