# KCD2-MP — state of the project after WO-40 (2026-08-20)

Written as an end-of-session handoff for the human. **Local only, deliberately
not committed/pushed.** Everything below is also in the repo in longer form:
`docs/WO-40-findings.md` (evidence, per phase), `docs/WO-40-progress.md`
(table + resume point). This is the parse-in-one-sitting version.

---

## 1. What is current, right now

- **`main` is pushed at `cb29529`** — 14 WO-40 commits. Working tree clean.
- **`VERSION` = 0.14.4** (your choice). `release\KCDMP-Setup-0.14.4.exe`
  (95.1 MB) is built and sitting locally, NOT pushed/published — that's
  yours. It contains fresh builds of everything below (binaries published
  at 16:32 on the 20th, pak rebuilt after the live battery).
- **Your machine still runs the installed 0.13.6 stack.** Nothing agent-side
  from WO-40 is live for you until you run the 0.14.4 Setup (close game +
  launcher + agent first — files are held open). The installer lifecycle
  suite (41 tests) and `Verify-Install.ps1` remain yours to run before
  distribution.
- **Test suites at release build time:** relay 26/26 (two new wire layers
  covered), release-version 6/6, installer-detect 21/21, Farkle 59/59.

### The evidence base this WO ran on (a first for the project)

The 2026-08-18 two-human session produced **real game-side telemetry from
both machines** — host (PA/"josesitoo") and joiner (PB/"emmanuelcool")
bundles, committed under `docs/WO-40-test-logs/` and read in full. Unlike
WO-38's launcher-only logs, these had agent logs with combat/timeskip/
appearance traffic. Two collection gaps mattered and are fixed: kcd.log and
config.json were missing from both bundles (collector bugs), and NPC-sync
telemetry lives only in kcd.log — so that layer was dark this round and
won't be next round.

---

## 2. Findings — the ten phases, compressed

**Phase 0 — your two crashes were real.** Abrupt game-process deaths, no
menu open, every launcher exit clean-marked. Both landed within ~1.5 s of an
inbound **ghost mount** (2 of only 5 mount transitions all session; crash #2
sits exactly on fresh-spawn + 400 ms ForceMount). Shipped guards: never
adopt the horse the local player is riding, never ForceMount a ghost younger
than 3 s, and `mp_horse_adopt off` as a field kill-switch. Honest label:
strongest-correlated suspect mitigated, not a proven root cause (no dump
exists) — the kill-switch makes the field diagnosis decisive either way.

**Phase 1 — repo sweep (done first, paid off everywhere).**
- Game's own data gave us: the weather write
  (`EnvironmentModule.BlendTimeOfDay` — used by Warhorse's own scripts),
  real jump/vault/sleep/takedown clip names from Animations.pak, the
  `Human:PlayAnim` TAG vocabulary, `AI.SetAnimationTag`.
- libKCD2 (GPL-3.0 — treat as documentation only) maps the native Mannequin
  route (`QueueAction`, verified vtable slots) if we ever need it — see §4.
- kcd2lua/kcd2db (MIT) prove hot-reload Lua and a native save/load listener
  are cheap to adopt later.
- Retail Lua dump proved `AI.GetFactionOf` / `SetFactionOf` /
  `AddPersonallyHostile` etc. exist — WO-34's "does not exist" was a
  mis-probe (confirmed live this session, see §3).

**Phase 2 — pause-freeze on NPCs: fixed with WO-13's own pattern.** The menu
pump never drove `KCD2MP_NpcPuppetTick`; now it does. A paused player's
puppeted NPCs keep moving. (Open lead: dialogue freezes the world without
tripping the pause detector — evidence in the joiner log, not yet fixed.)

**Phase 3 — weather sync: built, wire-verified, live-verified.** There is no
current-profile READ in the engine, so "detect and broadcast" is impossible;
weather is **mod-arbitrated**: the damage-authority holder picks from a
weighted pool every ~20 min, broadcasts (0x2E/0x2F), receivers apply on
change, 2-min heartbeat for late joiners, silent when solo,
`--no-weather-sync` opt-out, `mp_weather` local probe.

**Phase 4 — reload is now the fourth time trigger.** The bundles caught your
day/night desync end to end: PA's post-death reload broadcast a clock
**24.5 h behind** PB's, which PB could never apply (backward writes are
engine-ignored) — and no skip ever reached PB again. Fix: a backward clock
jump = reload; the **reloader fast-forwards itself** to the best-known
session clock (own pre-reload clock vs newest peer report, ratio-15
extrapolated). Solo reloads untouched. Also fixed the double-report bug (one
bed sleep emitting kind=2 AND kind=0).

**Phase 5 — the lifecycle bugs: diagnosed, invention gate NOT needed.**
- "Two guards in each other": NPC-sync **cannot** spawn duplicates (drives
  existing entities by name or does nothing). Best explanation: schedule
  divergence from the 24.5 h clock gap — Phase 4 attacks the root.
- Three-point phasing: logs were dark → shipped `mp_npc_fight`, a per-puppet
  tug-of-war meter that clusters WHERE the entity keeps being found. Next
  field bundle answers it with data.
- Global T-pose collapse: load-correlated — **1,025 of PB's 1,058 hit events
  carried 0.0 damage** (bursts of 26/s), and the one applied flood coincided
  with PB's worst engine stall minutes before the collapse. Fixed: sender
  drops zero-damage hits; puppet locomotion restarts cut from 20×/s to
  on-change + 1 s refresh.
- **The big one: per-save Soul Guids are NOT stable across installs** —
  field-proven (571/571 guard hits unresolvable on PB vs 176/176 choke hits
  applied). This is why NPCs "did nothing" for the observer and why PB's KO
  never crossed. Fix: **name-addressed NPC damage (0x30/0x31)** — sender
  translates guid→soul-name via the reflection REST (route confirmed live),
  receiver translates name→its own guid, applies through the existing DLL
  pipe. 0x12 stays as fallback; ghosts stay guid-addressed.

**Phase 6 — combat visibility extended to NPC puppets.** 0x26 flags now
carry bit 2 (weapon drawn → puppet fights in the WO-39 guard stance) and
bit 3 (swing cue — inferred from the authority's own health dropping near a
drawn NPC). KO next to a ghost plays the paired takedown clips. **The choke
miscue is fixed at the source**: 'block' inputs with no weapon drawn (=
grabs/chokes) no longer emit the phantom shield-block.

**Phase 7 — carry state.** PB's KO-carry disaster decoded: the KO never
crossed (guid problem, fixed by 0x30), and the authority's stream dragged
the grounded body. Plus: `npc_drag` bit 4 = carried (body glued to the
player), receivers follow carried bodies smoothly instead of teleport steps.

**Phase 8 — jump + vault.** Real clip names shipped
(`relaxed_jump_start`, `relaxed_jump_over_obstacle_idle_low/high`), and —
see §3 — the jump branch now leads with the `MotionJump` Mannequin fragment,
which actually renders.

**Phase 9 — the pickpocket-aggro problem.** Exactly WO-22's predicted class.
**Ghosts are now stimulus-deaf by default** (WO-39 already proved
`AI.SetIgnorant` targeting-safe: an ignorant ghost stays hittable and still
fights back). `mp_ghost_ignorant off` reverts if you want the old emergent
chaos. `mp_ghost_calm` clears per-pair hostility on an already-aggroed ghost.
WO-36's crime-cost measurements (fines/rep numbers) remain open, two-human.

**Phase 10 — the "directional" clothing regression: item data, not
architecture.** PB's outfit was largely **quest-item aliases**
(alias_prepadeni_* from the ambush quest). An alias class "equips
successfully" but never lands in the equipped map — reproduced on demand
live. Fix: receivers substitute all 40 shipped ItemAlias classes with their
source items. The one non-alias failure (GambesonShort02_m03_E1) equipped
cleanly when re-probed — recorded as unreproduced.

---

## 3. What the live battery proved on your machine (same evening)

- **Weather: verified end to end**, eyeball + engine readback. Snap mode
  (blend 0 + ForceImmediateWeatherUpdate: rain 0→0.82 in seconds) and slow
  blend (rain →0 over ~60 s) both work. You saw both directions.
- **`SoulsByGuid` REST route exists** (SoulsById doesn't) — both halves of
  the 0x30 translation are confirmed surfaces.
- **All five jump/vault/takedown clips RENDER on a calm ghost** ("hands out,
  hands forward for takedown — certainly better than statically moves
  vertically"). Same clips render **nothing** on a ghost whose brain is
  actively fighting — a real, newly-documented limit: brain-in-combat eats
  StartAnimation one-shots.
- **`MotionJump` is the first Mannequin fragment ever seen rendering** via
  `Human.PlayAnim` on a ghost. Now the jump branch's first choice.
- **Combat fragments stay locked even with tags** (CombatAttack/FreeAttack/
  MeleeAttack × lngsw/rg tags — ghost "stood completely still"). See §4.
- **All six AI hostility binds registered**; the engine's own error message
  revealed the real signature `ResetPersonallyHostiles(entityID, hostileID)`
  — shipped. `GetFactionOf` is callable but returns nil (read half thin).
- **The alias clothing failure reproduced on demand and the fix validated**
  at the equip layer.

---

## 4. The invention gate — the audit answer

**Used nowhere.** Every phase closed inside existing patterns; the new wire
messages (0x2E–0x31) reuse the relay conventions verbatim and are
wire-tested. **One escalation is now formally EARNED but deliberately not
built:** true combat-swing fidelity. Three cited failed attempts on the
existing surfaces: WO-39's StartAnimation blendspaces, WO-39's empty-tag
PlayAnim, WO-40's tagged PlayAnim (live, twice). The mapped design is
libKCD2's `I_AnimationController::QueueAction` route (verified vtable slots;
possibly GetProcAddress-able in our exports-rich Modding Tools build). It is
a WO-sized native work item, and **libKCD2 is GPL-3.0** — so the choice
between re-deriving from our own probes vs adopting their headers (with
source-disclosure implications) is a decision only you can make. That's the
next WO if swing fidelity is the priority.

## 5. The PA/PB asymmetry — did this session actually move it?

**Structurally, yes, in four places:** reload convergence kills the largest
divergence generator (clock gaps → schedule divergence → most tug-of-war
classes); name-addressed damage makes PB's actions actually land in PA's
world; the puppet menu-pump removes a whole PB-side freeze class; the
zero-damage gate removes the load spike that hit PB hardest.
**Still one-sided by design:** NPC simulation authority remains the host's.
`mp_npc_fight` now measures what's left, so the real structural candidate —
per-entity authority by proximity — can be decided on numbers from the next
tester round instead of feel.

## 6. What to do next (in order)

1. **Run `KCDMP-Setup-0.14.4.exe`** on both machines (close game/launcher/
   agent first), run `Verify-Install.ps1` and the 41-test installer suite.
2. **Publish the release** when satisfied — your call, your label.
3. **Two-human session priorities** (all now diagnosable — kcd.log gets
   collected this time): does the mount crash recur (if yes: try
   `mp_horse_adopt off` and report — that splits the diagnosis); weather
   convergence between machines; reload → "Clock re-synced" toast on the
   reloader; NPC damage/KO crossing installs (the 0x30 layer); puppet
   combat stance/swing cues + takedown pair in context; carried-body
   follow; clothing after the alias fix; `mp_npc_fight` dump whenever
   phasing is seen (that's the three-point answer).
4. **Decide the combat-fidelity WO** (§4) and the GPL posture.
5. Small open leads on file: dialogue-not-detected-as-pause; the
   GambesonShort02_m03_E1 one-off; WO-36's crime-cost measurements;
   sleep pose for sleeping players (`sleeping_bed_idle_player` is known and
   probed-in but not yet wired to the timeskip state).

## 7. Where everything lives

- `docs/WO-40-findings.md` — full evidence, per phase, gate audit.
- `docs/WO-40-progress.md` — table + live-battery addendum.
- `docs/WO-40-test-logs/` — both raw bundles.
- `docs/WO-40-footage-findings.md` — your Document 2, verbatim.
- New console commands this WO: `mp_horse_adopt`, `mp_weather`,
  `mp_npc_fight`, `mp_ghost_calm`, `mp_anim_tag` (+ `mp_ghost_ignorant` now
  default-on).
- New agent flags: `--no-weather-sync` / `--weather-sync`.
- Wire: next free byte is **0x32**.
