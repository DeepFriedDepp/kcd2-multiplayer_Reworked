# WO-40 — an hour of real footage, every finding, gate lifted where earned

Worked 2026-08-20. Source evidence: `docs/WO-40-footage-findings.md` (committed
verbatim) and the first-ever **real log bundles from both machines** of the
same session — `docs/WO-40-test-logs/host/` (PA, "josesitoo") and
`.../joiner/` (PB, "emmanuelcool"), 2026-08-18, ~18:20–20:30 local. Unlike
WO-38's logs, these carry real game-side telemetry. Both bundles were read in
full (host: 64,267 + 21,180 agent lines; joiner: 56,632 + short final run; all
four app logs). Evidence discipline: **observed / read-but-unrendered /
inconclusive**, never rounded up.

Game available this session; save declared disposable by the human.

---

## Phase 0 — the host's two crashes: REAL, and both correlate with the ghost-mount path

### What the bundles establish

- **The launcher never crashed.** All 12 completed launcher runs on the 18th
  carry the WO-39 `=== Launcher exiting (clean) ===` marker, both machines.
- **Both reported crashes are real game-process deaths**, not manual closes:
  the host's kcd.log position feed stops mid-frame with `read=0ms` health,
  the KCDMP.dll pipe dies ~1 s later, and no menu was open either time
  (last local pause exits were 19:24:43.778 and 20:22:26.685).

**Crash #1 — 19:25:05.** Host galloping (`riding=True`), feed healthy:

```
19:25:05.014 [pos] 1299.2 2073.9 12.5  rot=1.64  riding=True  read=0ms   <- LAST frame ever
19:25:05.172 [ghost 4] ... riding=True                                   <- PB mounts (False->True flip)
19:25:06.732 [combat] pipe reader exited
```

**Crash #2 — 20:23:54, ~1.5 s after PB's ghost 7 respawned already-riding:**

```
20:23:53.384 [name] ghost 7 = emmanuelcool
20:23:53.664 [appearance] unequip a8b22da0-... on kcd2mp_7 failed: 404 (Not Found)
20:23:53.857 [ghost 7] ... riding=True                                   <- fresh spawn, riding flip
20:23:54.303 [pos] 1120.5 1939.0 23.6 ... read=0ms                       <- LAST frame ever
20:23:55.354 [combat] pipe reader exited
```

**The correlation:** the two agent logs contain exactly **five** ghost
riding=False→True transitions all session (19:20:44, 19:52:07, 20:10:26 — no
crash; 19:25:05 and 20:23:53 — crash within ~1.5 s). The inbound mount path is
`KCD2MP_UpdateGhost(riding=True)` → `KCD2MP_SpawnHorse` → world-horse adoption
(`System.GetEntityByName`) → **`human:ForceMount(horse.id)` on a 400 ms
timer** — for crash #2 the ForceMount timing lands exactly on the last frame
(mount receipt 53.857 + delivery + 400 ms ≈ 54.3; game died at 54.303+).
For crash #1 the receipt lands 158 ms after the last logged frame — but the
game buffers kcd.log writes, so unflushed final frames are expected at a hard
crash; the timing is consistent, not probative.

**One concrete aggravator for crash #1:** PA was actively riding when PB's
mount flip arrived. PB's horse identity in that window is lost (log rotation),
but PA had `ttkc_horse_1` mounted minutes earlier and the joiner's next run
used `ttkc_horse_2` then `ttkc_horse_1` — the adoption code had **no guard
against adopting and ForceMounting a ghost onto the horse the local player is
currently riding.** WO-39's live ForceMount test (which passed) used a free
stable horse; an occupied one was never tested.

No BugSplat/dump/exception text exists anywhere in the bundles.

### Verdict and fix (gate: NOT used — normal diagnosable bug class)

The evidence supports "the inbound ghost-mount/adoption path can kill the game
under specific conditions (occupied target horse; mount racing a fresh spawn +
equip burst)". Native crashes cannot be pcall-guarded, so the fix is to not
make the dangerous call:

1. **Occupied-horse guard**: never adopt the horse the local player is
   currently mounted on (`KCD2MP._mountedHorseName` already tracks it) —
   fall back to the proxy horse.
2. **Fresh-spawn guard**: never ForceMount a ghost younger than 3 s; the
   mount defers and retries instead of racing spawn/equip initialization.
3. **`mp_horse_adopt off` escape hatch** for testers if crashes persist —
   turns all adoption off (proxy-only), separating "adoption crashes" from
   "ForceMount crashes" in the field.

Stated per the audit rule: **mitigation for the strongest evidence-correlated
suspect, not a proven root cause** — no crash dump exists to prove the faulting
call. Both fixes are cheap, reversible, and the escape hatch makes the field
diagnosis decisive either way.

### The bundle itself had two collection bugs (fixed this session)

- **`config.json` was missing from both bundles**: `LogBundle` collects
  `Globals.ConfigFilePath` = `%AppData%\KCDMP_Launcher\config.json`, but the
  launcher actually persists its settings to **`settings.json` in the
  launcher's working directory** (`Home.razor.cs` `SettingsFileName`). The
  bundle now collects the real file.
- **`kcd.log` was missing from both bundles**: the bundle trusted
  `GameRootOf()` (a steam_appid.txt walk-up that silently falls back to the
  exe's own directory), while the agent proved the log's real location at the
  same moment (`[KcdLog] kcd.log = C:\Program Files (x86)\Steam\steamapps\
  common\KCD2Mod\kcd.log`). The bundle now walks up from the game exe looking
  for `kcd.log` itself, then falls back to a Steam-library scan (the agent's
  own locator logic).
- Also: the agent's one-back log rotation destroyed the first ~28 minutes of
  the host's session (id sequence proves a pre-19:08 run existed). Rotation
  is now two-deep (`agent.prev.log`, `agent.prev2.log`) and the bundle
  collects both.

---

## Phase 1 — repo investigations (done first; results feed every later phase)

Full reports from three parallel investigations; clones live in the session
scratchpad, nothing vendored. Licensing: KCSE/libKCD2 are **GPL-3.0** (study
as documentation only — copying code/headers would impose source-disclosure
obligations; any wholesale reuse needs the human's deliberate license
decision); kcd2lua and kcd2db are **MIT** (adoptable); lua-fork,
KCD2ModLoader-docs, kcd2-mod-docs, Blender toolkit remain unlicensed/mixed —
study only.

### KCSE / libKCD2 (JerryYOJ) — the native Mannequin lever, mapped

- Targets **retail** `WHGame.dll` 1.5.6 via a `dinput8.dll` proxy (loads
  before engine init; vfunc-swaps `CCryAction::CompleteInit` for a
  pre-main.lua window our post-launch injection can never see). Address
  resolution is an SKSE-style address library keyed per build — whose
  generator is NOT in the repo (author-dependent per patch).
- **Nothing in KCSE/libKCD2 hooks Mannequin/animation today**, but libKCD2's
  RE'd headers document the exact route we lack: entity → actor →
  `I_AnimationController::QueueAction(action, time, restartInstalled)`
  (WH wrapper, vtable slot [1]) or `IAnimatedCharacter::GetActionController()`
  (slot [37], `CAnimatedCharacter::m_pActionController` at +0x80), with
  KCD2's real `IActionController::Queue` at **vtable+0x98** (the SDK header
  order is interfuscator-shuffled and unusable). `C_CallbackAction` (the WH
  fragment action, byte-mapped: fragmentID +0x38, tags, priority, lifecycle
  delegates) is the object to construct.
- Key transfer fact: our Modding Tools build **exports mangled C++ symbols**
  (NATIVE-PLUGIN-findings §1), so these entry points may be directly
  `GetProcAddress`-able here — strictly better than retail's address library.
- Their `S_DamageEventData::Dispatch` hook (Floating Damage plugin) is proven
  prior art for **attributed** damage events — the attribution our Flow B
  explicitly lacks.

### Game's own scripts/data sweep (Scripts.pak, Tables.pak, Animations.pak)

Extraction artifacts left in the scratchpad; full report in the session log.
Headline findings, each mapped to a phase:

- **Weather (→ Phase 3): SOLVED as a surface.**
  `EnvironmentModule.BlendTimeOfDay(profileName, blendDurationSec, force)` —
  officially documented scriptbind, used by Warhorse's own perf scripts and
  debug weather quest (`#EnvironmentModule.BlendTimeOfDay('foggy_storm',0,true)`).
  Plus `ForceImmediateWeatherUpdate()`, `RebuildClouds()`,
  `GetRainIntensity()` (the only read), `ForceWindDirection(f)`, cvar
  `wh_env_RainIntensityOverride`. Profile ids in
  `Libs/Tables/time_of_day_profile.xml` (33 named profiles:
  `cloudless_sunny` … `foggy_storm` … `summer_overcast_C`). **There is no
  current-profile getter** — a sync design must track what it sets.
- **Jump/vault (→ Phase 8):** the game's vault is Mannequin fragment
  `LedgeGrab` (tags `floor+vault+over/up/drop`, walk/run/sprint variants) and
  jump is `MotionJump`; the `JumpOver` fragment plays
  `relaxed_jump_over_obstacle_idle_high`. Raw one-shot .caf names for the
  proven StartAnimation route: `relaxed_jump_idle`,
  `relaxed_jump_over_obstacle_idle_low`/`_high`, run/walk variants.
- **Sleep pose:** `sleeping_bed_idle_player` (the player's own bed-sleep
  idle), transitions `laydown_bed_left/right`, ground variants.
- **Choke/KO (→ Phase 6 miscue):** paired master/slave clips —
  `combat_takedown_back_<atk>_<vic>_{m,s}`,
  `stealth_kill_hand_stand_success_start_{m,s}`, etc.
- **Combat:** the shipped Lua never plays melee swings — combat animation is
  brain→native (`MeleeOffenseAutomationDecorator`→`CombatAction`). But
  `human:PlayAnim(fragmentName, tags)` is the Lua mirror of the brain's
  one-shot `AnimationAction` node (used by the game with fragments like
  `BattleVictory`), and **WO-39 only ever called it with empty tags**.
  `AI.SetAnimationTag(entityId, tag)` also exists. Untested levers before any
  native escalation.

### lua-fork / kcd2lua / kcd2db / mod-docs

- **lua-fork**: CryEngine-5.2.3-family Lua 5.1.1 with **float lua_Number**
  (32-bit — numbers >2^24 lose precision in the sandbox; relevant to any id
  math), IDSIZE 64, and `storedebug=0` (why Lua errors have no line numbers;
  a one-write native patch flips it — dev-QoL candidate).
- **kcd2lua (MIT)**: save-file→runs-in-game-in-one-frame hot-reload via the
  game's own loadfile+pcall on the game thread. Proof the dev loop can skip
  pak rebuilds; the cleanest adoption for us is ~30 lines in our own DLL
  calling `IScriptSystem::ExecuteBuffer` from a file watcher. Also proves
  the game's `luaL_loadfile` still loads arbitrary OS paths.
- **kcd2db (MIT)**: SQLite persistence registered the official
  `CScriptableBase` way; its standout primitive for us is
  `IGameFrameworkListener::OnSaveGame/OnLoadGame` — **a reliable native
  save/load callback**, exactly the event that silently kills our Lua timer
  chains today.
- **mod-docs (muyuanjin)**: retail-1.5 live Lua state dump shows
  `AI.GetFactionOf`, `AI.SetFactionOf`, `AI.AddPersonallyHostile` /
  `RemovePersonallyHostile` / `IsPersonallyHostile` **all exist** —
  correcting this project's "GetFactionOf does not exist" note (WO-34 probed
  a wrong signature). Directly relevant to Phase 9. Also documented:
  `PlayerStateHandler.PlayAnimationAction(...)` (state-machine-integrated
  one-shots), `cheat_set_weather` console command, `System.AddCCommand`
  patterns, and verified WHGame vtable corrections.

**Carried forward:** Phase 3 uses BlendTimeOfDay; Phase 6 tries
PlayAnim-with-tags/SetAnimationTag before anything native, with libKCD2's
QueueAction map as the documented escalation; Phase 8 uses the found clip
names + fragments; Phase 9 retests the faction/hostility binds with correct
signatures.

---

## The session's cross-cutting log discoveries (feed Phases 4, 5, 6, 10)

1. **The day/night desync mechanism, captured end-to-end.** PA died in the
   guard fight 19:42:44, reloaded, and broadcast `kind=0 t=550817` at
   19:44:30 — **88,060 world-seconds (~24.5 h) behind PB's clock** (PB
   reported t=638877 one millisecond earlier). Backward writes are
   engine-forbidden (WO-38), so PB stayed at night — and **no inbound
   timeskip ever reached PB again for the remaining 35 minutes**. Reload
   also produced no skip event of its own on any of PA's three or PB's three
   death-reloads. (→ Phase 4.)
2. **Soul-guid resolution is bimodal across installs.** PA's guard-fight
   damage stream: **571/571 events unresolvable on PB** ("soul not loaded
   here"); PA's choke-out 20:14: **176/176 applied**. The per-save-Guid
   problem WO-39 Phase 3 predicted, observed in the wild, per-NPC. (→
   Phase 5/6 territory; also the strongest candidate mechanism for "the NPC
   does nothing for the observer".)
3. **A zero-damage hit flood exists.** 1,025 of PB's 1,058 outbound hit
   events carried `0.0` damage (up to ~26 events/sec across 3 souls
   simultaneously); host mirror shows the same shape (568/571 zero on one
   soul). The DLL hit hook fires per contact frame. The 20:14 applied-flood
   (176 events/18 s) coincides with PB's worst engine stall (ping 3954 ms on
   localhost) — **immediately before the footage's global animation
   collapse.** (→ Phase 5.3 lead + an independent fix: damage>0 gate.)
4. **Appearance failures are item-specific, not directional-by-design.**
   PB could never equip two of PA's item classes on PA's ghost
   (`73b9efe7-…` — four full 10 s retry cycles; `a8d552a9-…` — one), while
   everything else applied. The host's own equip failures appear only
   post-crash (game HTTP dead — noise). (→ Phase 10 pivot: identify those
   item classes and why ghost-equip fails for them.)
5. **NPC-sync telemetry is completely dark in agent logs** — every claim/
   release/puppet line lives in kcd.log, which the bundle didn't collect
   (bug fixed above). Phase 5's forensic half must run live.
6. **Pause tracking misses dialogue** (PB's 79 s dialogue freeze produced no
   pause event) **and smears across death-reload** (`entered` 19:41:11 →
   `exited` 19:44:54 spanning PA's death+reload). (→ Phase 2 adjacent.)

---

## Phase 2 — the pause-freeze regression, NPC-sync side — **FIXED BY REAPPLYING WO-13's PATTERN (gate: not used)**

Exactly the WO's prediction: `KCD2MP_InterpPump()` (what the agent pumps
during a local menu) drove `KCD2MP_InterpTick` and the horse transforms —
and never `KCD2MP_NpcPuppetTick`, a second `Script.SetTimer(50)` chain that
freezes with every menu. The pump now also drives the puppet tick, throttled
to its native 50 ms cadence (its lerp/speed math assumes 50 ms, and
per-tick StartAnimation gets worse, not better, when run faster — WO-39's
stomping lesson). No new mechanism, no invention: the same fix, applied to
the tick it never covered.

Recorded, not fixed: **dialogue freezes the world without tripping the
pause detector** (PB's 79 s dialogue window produced no pause event and a
79 s position-stream gap), and the pause state machine smears across a
death-reload (`entered` 19:41:11 → `exited` 19:44:54 across PA's death).
Both are detection gaps in the kcd.log marker set, not pump bugs; left as
follow-up leads with the evidence cited.

## Phase 3 — weather sync — **BUILT + WIRE-VERIFIED (gate: not used; the pattern adapted, honestly)**

The time-sync shape ("detect a local change, broadcast, arbitrate") does
NOT transfer verbatim, for an engine reason found in Phase 1:
`EnvironmentModule.BlendTimeOfDay(profile, blendDur, force)` is a
documented, Warhorse-used WRITE, but there is **no current-profile read**
(`GetRainIntensity()` is the only readback), so nobody can detect vanilla
weather changing. The session's weather is therefore **mod-arbitrated**:
the damage-authority holder (existing single role, relay-managed failover)
picks from a curated weighted pool every ~20 min (half the rolls keep the
current profile), applies locally, broadcasts `0x2E WeatherUp
[nameLen][profile][blendSec:2]`; receivers apply on change; a 2-min
heartbeat converges late joiners. **Silent with no live peers** — solo
weather stays vanilla. `--no-weather-sync` opts an agent out; `mp_weather`
probes locally.

- Wire-verified: `Test-TimeSkipRelay` T15 (broadcast, no own-echo) — suite
  26/26 PASS.
- Live-gated: whether BlendTimeOfDay renders on this build (the bind is in
  the game's own perf scripts, so risk is low), and the blend-duration
  units (undocumented; Warhorse passes 0/1).

## Phase 4 — reload as the fourth time trigger — **BUILT (gate: not used)**

The bundles caught the whole mechanism: PA died 19:42:44, reloaded, and
broadcast t=550817 — **88,060 world-seconds (~24.5 h) behind PB**, one
millisecond after PB's own done. Backward writes are engine-ignored, so PB
could never apply it, and no inbound skip reached PB for the remaining 35
minutes. Reloads themselves emitted nothing (all six death-reloads across
both players are invisible to the skip detector).

Since receivers cannot go back, **convergence is forward and belongs to the
reloader**: the clock-jump watcher now detects backward jumps (only a save
load makes one) and the reloading client fast-forwards ITSELF to
max(own pre-reload clock, newest peer-reported skip time extrapolated at
the live-confirmed ratio 15) — applied quietly with a "Clock re-synced"
toast, never broadcast. **Solo reloads are left alone** (no live peers = a
player who wanted that earlier time). Also fixed from the same evidence:
the double-report bug (PB's 19:44:23 bed sleep emitted BOTH kind=2 and
kind=0 — a jump that settles inside a skip/apply window is now swallowed).

## Phase 5 — NPC-sync entity lifecycle — **DIAGNOSED FROM EVIDENCE + FOUR FIXES (gate: NOT earned — stated with the reasoning)**

The WO named this the likeliest gate user. After the investigation, the
claim/authority model did NOT need structural change — each finding
resolved to a specific, cheaper mechanism:

1. **Double-render ("two guards phased into each other")**: NPC-sync
   never spawns entities — `KCD2MP_ApplyNpcState` drives an existing
   same-named entity or does nothing. A puppet duplicate is impossible by
   construction. The economical mechanism: **schedule divergence** — the
   footage moment sits inside the 24.5 h day/night window, where PB's
   world legitimately staffs the gate with a different guard while PA's
   stream drags PB's copy of PA's guard to the same post. Two real local
   entities, one spot. Phase 4's convergence attacks the root; labeled
   best-explained-by, not proven (no kcd.log existed to prove it — that
   collection bug is fixed).
2. **Three-point phasing**: not resolvable from the dark logs. Built
   instead: `mp_npc_fight` — a per-puppet tug-of-war meter that counts
   how often the entity is found away from where we last wrote it and
   CLUSTERS the positions it kept appearing at. Distinct clusters =
   distinct writers; the next field bundle answers this with data.
3. **Global animation collapse**: the strongest lead is load-correlated —
   the 20:14 applied-damage flood (176 events/18 s) coincided exactly with
   PB's worst engine stall (ping 3954 ms on localhost), minutes before the
   collapse; and 1,025 of PB's 1,058 outbound hit events carried 0.0
   damage (bursts of ~26/s across three souls at once). Fixes: **hits that
   moved no health and no stamina are dropped at the sender**, and the
   puppet tick's looped locomotion now restarts on tag change + 1 s
   refresh instead of 20x/sec. Labeled: strong correlation, mechanism not
   proven — the anim-churn fix is also independently correct.
4. **The per-save-Guid problem (WO-39's flagged premise, now confirmed in
   the field)**: PA's guard-fight damage failed to resolve on PB 571/571
   times while the choke applied 176/176 — per-save guids match for some
   NPCs and not others. Built: **name-addressed NPC damage (0x30/0x31)** —
   sender translates guid→soul-name once via the reflection REST (the
   route the DLL itself uses), receiver translates name→ITS local guid
   (the shipped `SoulsByName` read), applies through the existing DLL
   pipe. 0x12 stays as fallback; ghosts stay guid-addressed (a kcd2mp_N
   name means a different entity per machine); caches clear on reload.
   Wire-verified (T16). This is the fix behind "PB knocked an NPC out and
   PA's copy kept walking", behind the guard that "did nothing" for PB,
   and it is what lets KO replication work cross-install.

**Why the gate was not used**: every mechanism located was addressable
inside the existing single-authority + per-entity-claim model. Nothing
found suggests the claim model itself loses races or double-renders; what
failed was identity (guids), time (schedule divergence), and load (event
floods) — all fixed at their own layers.

## Phase 6 — combat visibility on NPC puppets + cue quality — **EXTENDED + MISCUE FIXED; the Mannequin ceiling gets a mapped escalation path, not yet an invention**

Shipped (all read-but-unrendered until the live battery):
- 0x26 flags grow **bit 2 (weapon drawn)** — read via `IsWeaponDrawn` on
  the authority, applied via the same DrawWeapon/HolsterWeapon calls WO-39
  live-verified on ghosts; a drawn puppet idles in the WO-39 guard stance
  (human-confirmed correct read there) instead of standing slack.
- **bit 3 (swing cue)** — an NPC's real swings are invisible to Lua, but
  the moment that matters is visible: the authority's own health dropping,
  attributed to a drawn tracked NPC within 4 m. Receivers play the ghost
  swing cue as a **pinned one-shot** (puppet writes pause during any
  one-shot — the WO-39 stomping lesson applied to this second path).
- **KO transitions next to a ghost play paired takedown clips** (victim
  clip on the NPC, master clip on the nearest ghost within 2.5 m) — real
  .caf names from the Animations.pak sweep
  (`stealth_kill_hand_stand_success_start_m/_s`,
  `combat_takedown_back_nw_nw_m/_s`), findAnim-probed so a missing name
  degrades to the existing freeze.
- **The choke miscue is fixed at the source**: the `block` input also
  fires during weaponless grabs, which is why PA's choke rendered as a
  phantom shield-block. A block cue with no weapon drawn is never emitted.

On quality: WO-39's `PlayAnim` failures all used EMPTY tags. Phase 1
recovered the real tag vocabulary (`LedgeGrab` + `floor+vault+over`,
sleeping tags, fragment catalogs) and `AI.SetAnimationTag` — genuinely
untried levers that cost nothing to probe (`mp_combat_frag <frag> <tags>`,
new `mp_anim_tag set|clear <tag>`). **The invention gate is NOT used yet**:
if the tagged-PlayAnim probes also fail live, the mapped escalation is
libKCD2's verified route — `I_AnimationController::QueueAction` (WH
wrapper, vtable slot [1]) / `IAnimatedCharacter::GetActionController()`
(slot [37], `m_pActionController` +0x80, KCD2's real `Queue` at
vtable+0x98), potentially GetProcAddress-able in our exports-rich Modding
Tools build — **with the GPL-3.0 caveat: reuse as documentation and
re-derive, or the human makes a deliberate license decision first.**

## Phase 7 — knockout-then-carry — **STATE DISAGREEMENT DIAGNOSED + CARRY FLAG ADDED (gate: not used)**

The footage's mechanism decoded from the logs: PB's KO never applied on PA
(PB's 100.0 one-shot hits at 19:39 were guid-addressed and `fb85539d…`
failed to resolve at 19:40:24) — so PA's copy stayed alive and walking,
and PA's authority stream dragged PB's grounded body along the walking
path ("walking but on the ground as if knocked out"). The primary fix is
Phase 5's 0x30 layer (the KO state now crosses). On top: `npc_drag` flags
gain **bit 4 (carried)** — a downed body moving glued to the player
(<1.5 m) — and receivers follow carried bodies smoothly per tick instead
of half-metre teleport steps (the "phases upward onto shoulders" read).

## Phase 8 — jump and fence-vault — **REAL CLIP NAMES FOUND AND SHIPPED IN THE PROBE LISTS (gate: not used)**

The Animations.pak sweep produced what WO-38/39 lacked: real one-shot .caf
names. `JUMP_ANIMS` is now led by `relaxed_jump_idle` (+ start/land pairs,
run/walk variants); new `VAULT_ANIMS` carries
`relaxed_jump_over_obstacle_idle_low/_high` — the exact clip the game's
own `JumpOver` fragment plays (read from kcd_male_database.adb). The
existing airborne detector plays whatever probes out; `mp_combat_probe`
now dumps JUMP/VAULT/TAKEDOWN probe results so the live battery settles
rendering in one command. The Mannequin route (`human:PlayAnim('JumpOver',
'')`, `MotionJump`) is the quality upgrade to try live — it carries the
proc layers (ground alignment) a raw clip lacks.

## Phase 9 — ghost-brain crime/aggro (WO-36's territory) — **PREVENTED BY DEFAULT + REMEDIATION + CORRECTED MEMORY (gate: not used)**

What happened is exactly WO-22's predicted class: the ghost is a real
soul-backed NPC, the pickpocket-caught stimulus fired its brain's authored
crime-victim response, and the engine marked PA personally hostile —
persistently, because no player ever resolves the incident.

- **Ghosts are now stimulus-deaf by default** (`KCD2MP.ghostsIgnorant =
  true`). The chain that earned a default flip: WO-38 recommended it
  ("a ghost has no player behind its reactions"), WO-39 live-verified
  `AI.SetIgnorant` is targeting-safe (an ignorant ghost stays hittable
  and still fights back — damage response is not a stimulus), and this
  footage showed the cost of off. `mp_ghost_ignorant off` reverts; this
  remains the human's product call to overturn.
- **`mp_ghost_calm`**: probes `AI.GetFactionOf/SetFactionOf/
  AddPersonallyHostile/RemovePersonallyHostile/IsPersonallyHostile/
  ResetPersonallyHostiles` registration (the retail-1.5 state dump lists
  them ALL — correcting WO-34's "GetFactionOf does not exist", which was
  probed on a guessed signature) and clears per-pair hostility on every
  ghost — the remediation for an already-aggroed ghost.
- WO-36's wider crime-cost measurements (fines/rep/bounty numbers per
  crime against a ghost) remain unrun — they need the two-human session
  and a disposable save on the tester machines, and they are a
  measurement, not a bug. Explicitly still open.

## Phase 10 — clothing sync — **THE "DIRECTIONAL REGRESSION" DECODED AS ITEM DATA, NOT ARCHITECTURE (gate: NOT earned, and the evidence says why)**

The WO flagged this as the third gate candidate ("a symmetric system
failing asymmetrically"). The bundles say otherwise:

- The only real equip failures were **item-specific**: `a8d552a9…` =
  `alias_prepadeni_collarChain` — an **ItemAlias of a quest item**
  (`IsQuestItem="true"`) — and `73b9efe7…` = `GambesonShort02_m03_E1` (a
  variant Armor row); four full 10 s retry cycles, joiner side.
- The host's crash-interrupted retry list for PB's ghost maps to
  **alias_prepadeni_mailLong, legsPlate, brigandine, collarChain** — PB's
  outfit was largely quest-alias pieces from one ambush quest. **The
  direction tracks who wears alias items, not who holds authority.**
- Fix shipped: receivers substitute all 40 shipped ItemAlias classes with
  their source items before diffing/equipping (an alias looks identical
  to its source).
- Honest discrepancy, recorded: the logged equip-level failures were in
  the A→B direction, while the footage reports B→A looking worse. The
  B→A gap is therefore either render-level (equip succeeds, visual
  missing — the WO-38 shirt/pants shape) or the alias pieces rendering
  blank; the live battery re-tests under combat/claim load per the WO's
  instruction, now with kcd.log actually collected.
- `GambesonShort02_m03_E1`'s failure mechanism is unexplained (a plain
  Armor row); flagged for a live CreateItems/EquipItem probe of that
  exact class id.

---

## The gate, audited (the WO's own requirement)

**Used nowhere as a first resort; used nowhere at all, in the strict
sense.** Every phase closed inside existing patterns:
- New wire messages 0x2E–0x31 are extensions of the existing protocol,
  reusing the relay conventions verbatim (HorseInfo/NpcState shapes), both
  wire-verified in the standing suite.
- The one place invention is mapped and waiting is the Mannequin ceiling
  (Phase 6): IF the newly-found tagged-PlayAnim/SetAnimationTag levers
  fail live, the libKCD2-documented native QueueAction route is the
  design — with the prior attempts already citable (WO-39's
  StartAnimation blendspace failures, WO-39's PlayAnim-with-empty-tags
  failures, and this session's tag-vocabulary probes once run). That
  decision plus its GPL implications belong to the human.

## The PA/PB asymmetry, answered directly

Does this session reduce how much worse PB's experience is, structurally —
or just patch symptoms? **Both, and here is the split:**
- **Structural**: reload convergence (Phase 4) removes the single biggest
  divergence generator (24.5 h clock gaps → schedule divergence → most of
  the "tug-of-war"/"two guards" classes); name-addressed damage (Phase 5)
  makes PB's actions actually LAND in PA's world, which was half of what
  made PB's world feel second-class; menu-pumping the puppet tick
  (Phase 2) removes a whole PB-side freeze class; the zero-damage gate
  removes a load source that hit PB hardest (the stall before the
  animation collapse).
- **Still one-sided by design**: NPC simulation authority remains PA's.
  PB's NPCs are still puppets of PA's world within 30 m of PA. The
  footage's residual "PB sees phasing" class will shrink with converged
  clocks but not vanish; `mp_npc_fight` now measures exactly what is
  left, so the next decision (per-entity authority by proximity — the
  real structural candidate) can be made on numbers instead of feel.

## Suites

- `Test-TimeSkipRelay.ps1`: **26/26 PASS** (T1–T14 unchanged, new T15
  weather, T16 name-addressed NPC damage).
- Solution builds clean (agent, relay, launcher; pre-existing warnings
  only). Pak rebuilt and installed locally.
- Live battery: pending (game confirmed available, save disposable).
