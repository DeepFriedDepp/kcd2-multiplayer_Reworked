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
