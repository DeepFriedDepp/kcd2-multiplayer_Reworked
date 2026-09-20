# WO-106 — findings

Session 2026-09-19. Progress: `docs/WO-106-progress.md`. Prerequisite:
`docs/WO-105-cryengine-reference.md` + `docs/WO-105-contradictions.md`
(engine source reading, no game run). This WO is the first to act on it,
live, solo, against 0.26.2.

Evidence marks: (observed) / (code-verified) / (synthetic) / (inconclusive).
**Nothing in this WO ran two-player.** Every phase below that assumes or
would benefit from a second machine says so explicitly, and none of the
findings that follow substitute for that test.

## 0. Answer first

* **Every WO-105 Phase-0 probe ran live, solo, and confirmed its
  hypothesis** — 5/5, no refutations, no inconclusives. Full detail in §1.
* **Phase 1 (console placeholder) is fixed in source and statically
  verified.** The live game still runs the OLD `kdcmp.pak` — nothing here
  takes effect until `tools\Build-And-Install-Mod.ps1` rebuilds it and the
  game restarts. That rebuild was **not run this session** (the game must
  be closed to rebuild the pak, and the maintainer was mid-session). See
  §3.6 for exactly what to test once it is deployed.
* Phase 0.3 surfaced `Script.SetTimerForFunction` as a real function on
  this build — **not acted on this WO**, flagged for later (§1.4).
* An unprompted finding from the Phase 0.5 test cleanup: `mp_remove_all`
  logged `test_ghost STILL ALIVE after 4 passes` before eventually
  reporting removed — a live instance of WO-105 contradictions entry 9 (a
  refused removal becomes a hide). Not chased this session; noted in §5.

## 1. Phase 0 — the probes (all observed, live, solo)

Run via the debug console API (`http://127.0.0.1:1403/api/System/Console/
ExecuteString`, GET with a `command` query parameter — see §6 for the exact
transport wrinkle found this session) against a running 0.26.2 Modding
Tools session, reading `kcd.log` directly at
`D:\SteamLibrary\steamapps\common\KCD2Mod\kcd.log`. Every `#`-prefixed
string below is Lua; bare strings are plain console commands.

### 1.1 The console placeholder (0.1) — CONFIRMED

Registered two probe commands with the lowercase placeholders the source
predicts:

```
#System.AddCCommand("mp_probe_line", "System.LogAlways('PROBE line=[%line]')", "probe")
#System.AddCCommand("mp_probe_one", "System.LogAlways('PROBE one=[%1]')", "probe")
```

Then, as plain console commands:

| command | kcd.log result |
|---|---|
| `mp_probe_line hello world` | `PROBE line=["hello world"]` — no warning |
| `mp_probe_one 42` | `PROBE one=["42"]` — no warning |
| `mp_probe_line` (bare) | `PROBE line=[]` — empty, no warning |

**No `Too many arguments for:` warning at any point.** This is the
predicted result exactly: the console never refused arguments; the mod's
templates used the uppercase `%LINE`, which the engine's case-sensitive
`strstr` lookup never matches. **Phase 1 cleared to run.**

### 1.2 `ENTITY_FLAG_NO_SAVE` (0.2) — CONFIRMED

```
#System.LogAlways("PROBE no_save=" .. tostring(ENTITY_FLAG_NO_SAVE))
```
→ `PROBE no_save=32768` — a number, `2^15`. The global is registered on
this build. **Phase 5 cleared to run.**

### 1.3 `Script.SetTimerForFunction` (0.3) — CONFIRMED present, not used

```
#System.LogAlways("PROBE timerfn=" .. type(Script.SetTimerForFunction))
```
→ `PROBE timerfn=function`. It exists on this build. Per the WO-106
prompt's instruction for this probe: **recorded and stopped here** — this
is information for a future WO on the restart-gate/chain-liveness work
(`memory/kcd2mp-lua-timer-liveness.md`, `memory/kcd2mp-wo78-state.md`),
not something this WO acts on. Nothing changed as a result of this probe.

### 1.4 `soul:GetId()` on world NPCs (0.4) — CONFIRMED Branch B

Found three candidate NPCs near the maintainer via the existing
`mp_find_npcs` command (no new tooling needed): `ttkc_man_5` (class `NPC`,
male), `ttkc_barbora` and `ttkc_woman_10` (both class `NPC_Female`).

Probe, run once per name:
```
#local e = System.GetEntityByName("<name>"); if e and e.soul then local id = e.soul:GetId(); System.LogAlways("PROBE soulid name=<name> type=" .. type(id) .. " tostring=" .. tostring(id)) else System.LogAlways("PROBE soulid name=<name> no-soul") end
```

Results:

| name | class | `type()` | `tostring()` |
|---|---|---|---|
| `ttkc_man_5` | NPC | `userdata` | `userdata: 05000000000001DC` |
| `ttkc_barbora` | NPC_Female | `userdata` | `userdata: 0500000000000007` |
| `ttkc_woman_10` | NPC_Female | `userdata` | `userdata: 0500000000000123` |
| `player` (comparison) | — | `userdata` | `userdata: 0500000000000251` |

All four are **Branch B**: light userdata (`ScriptHandle`), 16 hex digits —
a 64-bit value, exactly as WO-105 contradictions entry 3 predicted for this
branch. Every digit past the leading `05` varies; the leading byte is
constant across all four samples (player included), consistent with a
Warhorse-internal type/namespace tag on the WUID rather than randomness.

Comparison value (not re-probed this session, taken from the mod's own
roster in `kdcmp.lua`): a `SharedSoulGuid` is a dashed, 32-hex-digit
`cfa65480-f361-4cf8-80c5-1900b7846bc8`-shaped string — 128 bits. The WUID
above is 64 bits. **They are confirmed different widths on this build, not
just in engine theory.** WO-104 §3.3's "same form (code-verified)" claim
is wrong; corrected per WO-105 contradictions entry 3.

This clears **Phase 4** to run — see §4 for what was tried.

### 1.5 The float bridge (0.5) — CONFIRMED

No obvious echo-bind existed for a direct number-in/number-out round trip,
so this session built one: spawned a throwaway `kcd2mp_test_ghost` via the
existing `mp_spawn_test` command (a standard, disposable test entity this
project already uses constantly — no new spawn path), then round-tripped
its entity flags through `SetFlags`/`GetFlags`, which is exactly a
scalar crossing the `ScriptAnyValue` boundary in both directions:

```
#local e = System.GetEntityByName("kcd2mp_test_ghost"); if e then e:SetFlags(0, 1); local zero = e:GetFlags(); e:SetFlags(16777217, 3); local a = e:GetFlags(); e:SetFlags(0, 1); e:SetFlags(16777219, 3); local b = e:GetFlags(); System.LogAlways("PROBE float zero=" .. string.format("%.4f", zero) .. " set16777217->" .. string.format("%.4f", a) .. " set16777219->" .. string.format("%.4f", b)) end
```

Result: `PROBE float zero=0.0000 set16777217->16777216.0000
set16777219->16777220.0000`

* `16777217` (2^24 + 1) → read back as `16777216` (2^24, rounded down)
* `16777219` (2^24 + 3) → read back as `16777220` (2^24 + 4, rounded up)

This is **exact IEEE-754 float32 round-to-nearest-even** at precisely the
predicted ceiling. Confirmed, not inferred, on this build. Test entity
removed immediately after with `mp_remove_all` (see §5's unprompted
finding — the removal took 4 passes before reporting success).

### 1.6 Gate table (0.6)

| phase | gated on | result |
|---|---|---|
| 1 (console placeholder) | 0.1 | **cleared, done this session (source only, not deployed)** |
| 2 (vector-getter churn) | none (unconditional) | done this session |
| 3 (ground-collider) | live two-player test | **not run — no peer tonight** |
| 4 (replica soul-id) | 0.4 | **cleared, Branch B — attempted this session, see §4** |
| 5 (`ENTITY_FLAG_NO_SAVE`) | 0.2 | **cleared, done this session** |

## 2. Transport note: the exact `ExecuteString` call that worked this session

Superseding the shape recorded in `docs/WO-103-findings.md` (which called
it a GET with the command in the URL) — the working call this session was:

```
curl -G "http://127.0.0.1:1403/api/System/Console/ExecuteString" --data-urlencode "command=<line>"
```

A POST with a JSON body (`{"value": "..."}`) returned HTTP 501
("Parsing the given content-type is not implemented"). A GET with `value=`
as the query key returned HTTP 400 ("Missing parameter 'command'"). The
parameter name is **`command`**, not `value`, and it must be a GET. Every
Lua line still needs the `#` prefix, exactly as WO-102.5/WO-103 recorded.
`tools\KcdApi.ps1` does not currently wrap `ExecuteString` at all (only
the reflection-browser GET endpoints) — worth adding if a future session
drives the console from PowerShell instead of ad hoc `curl`.

## 3. Phase 1 — the console placeholder typo

### 3.1 What changed, exactly

`kdcmp/Data/Scripts/Startup/kdcmp.lua`, the `-- ===== Register Console
Commands =====` block (originally lines 11028-11177):

* **Every `%LINE` inside a `System.AddCCommand(...)` call** (33 template
  occurrences across ~30 commands) changed to lowercase `%line`. Done with
  a line-range-scoped `sed` (`11028,11177s/%LINE/%line/g`), not a blind
  file-wide replace — the block boundaries were confirmed first so the
  substitution could not touch anything outside command registration.
* **Left deliberately unchanged, outside that block:** two runtime sentinel
  checks (`kdcmp.lua:1002` in `KCD2MP_WeatherCmd`, `kdcmp.lua:12558` in the
  quest-beat handler) that compare an incoming argument against the
  literal string `"%LINE"` as a "no argument was given" fallback. These
  were workarounds for the *symptom* (the literal placeholder leaking
  through unsubstituted), not part of the registration bug. With the
  template now correctly substituting, a bare command produces an empty
  string, not the literal placeholder, so these checks are now dead code —
  but harmless dead code, and touching them was not necessary or asked
  for. If they are ever cleaned up, that is a separate, purely-cosmetic
  change.
* **Rewrote the stale in-file comment** above the WO-94 quest commands
  (previously claimed, wrongly, that "the console REFUSES an argument to
  any Lua-registered command") to state the actual mechanism and point at
  `docs/WO-105-contradictions.md` entry 1.
* **Rewrote four help strings** that told the user to type
  `#KCD2MP_X(...)` "because the console drops arguments on this build":
  `mp_quest_radius`, `mp_quest_window`, `mp_quest_fire`, `mp_quest_gap`.
  They now describe the direct, working console syntax. The `#Lua` form
  still works for all of them — nothing was removed, only the misleading
  claim in the help text.

### 3.2 What was un-work-around'd (new commands added)

Per the WO-106 brief's specific list:

* **`mp_authority_radius <metres>`** — new. Wraps the existing
  `KCD2MP_SetAuthorityRadius` (WO-102.5), which previously had **no**
  console command at all, only the `#KCD2MP_SetAuthorityRadius("<m>")`
  Lua form. The function itself was already correct (`tonumber`,
  floor-clamped at 10 m, no upper clamp per WO-103); only the command
  registration was missing. The old in-code comment claiming this was
  deliberately Lua-only "because the console drops arguments" was rewritten
  to match reality.
* **`mp_together_params <enterM> <exitM> <dwellS>` (or `on` for
  defaults)** — new function `KCD2MP_SetTogetherParams`, new command. The
  WO-102.5 Phase 4 co-location hysteresis constants (`togetherEnterM=60`,
  `togetherExitM=90`, `togetherDwellS=10`) had **no runtime setter of any
  kind** before this — `docs/WO-102.5-findings.md` §4.2 flagged this
  explicitly as a gap, not a workaround, so this is new capability, not an
  un-work-around. Validates all three values are positive and rejects
  `enterM >= exitM` outright (an inverted hysteresis band would make the
  together/apart state oscillate every tick instead of debouncing) —
  mirrors the existing `KCD2MP_SetAuthorityRadius` "reject outright, don't
  just warn" pattern.
* **`mp_npc_yield`** already took `"<dispM> <ticks> <repinM>"` — it was
  registered with `%LINE` (bug), not split into an argless workaround.
  Fixing the case was the entire change needed; no new command required.
  Notably, `KCD2MP_SetNpcYield`'s own parser (line ~2789, unchanged)
  already special-cased the lowercase literal `"%line"` as a "no argument"
  sentinel — whoever wrote it had already anticipated the eventual fix.

### 3.3 The `_on`/`_off` pairs — audited, not collapsed

Per the brief: *"was it split because arguments appeared not to work, or
is it genuinely binary? Collapse only the former, and only where a single
command with an argument is actually clearer."*

Every `mp_*_on` / `mp_*_off` pair in the file (mp_authority_host,
mp_pos_native, mp_authority_pause, mp_npc_replica, mp_npc_scan_native,
mp_npc_cull, mp_npc_read_native, mp_ghost_nai, mp_ghost_noai,
mp_anim_legacy, mp_quest_on/off, mp_dice_gate, and others) was reviewed.
**All of them are genuinely binary settings**, and several (the WO-102
family, explicitly commented `-- WO-102: argless toggle pairs (the console
drops arguments) + status`) were split *because of* this exact bug.
Despite that origin, none were collapsed: a single `mp_x on|off` command
would type no faster or clearer than `mp_x_on` / `mp_x_off`, every field
runbook and this maintainer's muscle memory already reference the paired
names, and the brief is explicit that a binary toggle staying a pair is
correct, not something to churn for its own sake. **No renames, no
removals.** This is a judgment call recorded here so it can be revisited
if a future WO disagrees.

### 3.4 Synthetic coverage

New: `tools/Test-WO106ConsolePlaceholder.ps1`. Static/lexical — greps
`kdcmp.lua` directly, no game or relay needed. Two assertions:

1. No `System.AddCCommand(...)` call anywhere in the file contains the
   uppercase placeholder `%LINE` (case-sensitive match — a naive
   PowerShell `-match` is case-*insensitive* and silently passes a
   regression; this was caught and fixed during this session by first
   writing the check wrong, running it, and getting 33 false negatives
   before switching to `-cmatch`. Documented so nobody repeats it.).
2. Every command registered with a `%line`/`%1`/`%%` placeholder names a
   Lua function that is actually defined somewhere in the file (catches a
   typo'd or removed handler).

Run and passing as of this commit: 5/5 (128 commands scanned, 36
argument-taking, 307 function definitions collected).

### 3.5 What this does NOT do

**Nothing in Phase 1 touched the running game.** All of the above is a
source change to `kdcmp.lua` plus a new standalone PowerShell script. The
live Modding Tools session this WO probed against is still running
whatever `kdcmp.pak` was last built and deployed — the *fixed* templates
do not exist in that pak. This was deliberate: rebuilding requires closing
the game (`tools\Build-And-Install-Mod.ps1`'s own precondition), and the
maintainer was mid-session running the Phase 0 probes. **Not rebuilt or
redeployed this session.**

### 3.6 What to test after the next rebuild — READ THIS BEFORE PLAYING

This is a solo-built change with no two-person requirement, but it touches
every argument-taking console command in the mod (~30 commands), so a
regression here is broad, not narrow. After
`tools\Build-And-Install-Mod.ps1` and a game restart, before relying on
any of this in a real session:

1. **`mp_authority_radius 45`** then **`mp_npc_cull_on`** — confirm
   `kcd.log` shows `WO1025-RADIUS set=45.0` (not a rejection, not the old
   default of 300 silently unchanged).
2. **`mp_together_params 60 90 10`** — confirm
   `WO1025-TOGETHER-PARAMS enterM=60.0 exitM=90.0 dwellS=10.0` in the log,
   not a rejection. Then try **`mp_together_params 90 60 10`** (inverted)
   and confirm it is **rejected** with the "hysteresis band inverts"
   message and the live values are unchanged.
3. **`mp_npc_yield 0.3 10 1.0`** — confirm `NPC-YIELD ENABLED dispM=0.30
   ticks=10 repinM=1.00` in the log. This one worked via `#Lua` before;
   confirm it now also works as a bare console command.
4. **Spot-check two or three of the previously-`%LINE` toggle commands**
   that were NOT explicitly re-tested above — e.g. `mp_ghost_ignorant on`,
   `mp_debug_hud on` — typed bare, no `#` prefix, and confirm the expected
   log line with no `Too many arguments for:` warning.
5. **If ANY of the above shows `Too many arguments for:` or a silently
   unchanged value**, the fix did not take — check first that the pak
   actually rebuilt (compare `kdcmp.pak`'s timestamp/size to before) before
   assuming the source fix itself is wrong. `memory/kcd2mp-lua-deploy-
   gotcha.md` is the standing trap this points at.
6. **This is the worst case that was asked to be documented explicitly:**
   if any argument-taking command now behaves *differently* than before
   (accepts something it used to reject, or vice versa), the revert is a
   single `git revert` of this WO's Phase 1 commit — it touches only
   `kdcmp.lua`'s command-registration block and comments plus one new,
   inert-by-default test script. No other phase depends on Phase 1's
   specific command names or help text, only on the underlying case fix
   (which Phases 2/4/5 do not use at all — they are not console-driven).

## 4. Phase 4 — replica soul-id (attempted; result below)

*(filled in once attempted this session — see progress doc for live status
if this section is not yet updated)*

## 5. Unprompted finding: a refused removal became a hide (observed)

From the Phase 0.5 cleanup, `mp_remove_all` on `kcd2mp_test_ghost`:

```
[KCD2-MP] RemoveEntity ghost test_ghost STILL ALIVE after 4 passes (entityId=userdata: 00000000000C03B9 name=kcd2mp_test_ghost) t=452.001
[KCD2-MP] Removed ghost: test_ghost
```

This is WO-105 contradictions entry 9 (a sink vetoing `RemoveEntity` makes
the engine hide the entity instead of reporting failure) happening live on
this build, on an ordinary ghost, with no combat or dialogue state
involved. The mod's own multi-pass removal loop (already 4-pass verified
per WO-104 §3.2) evidently already routes around this in the common case —
the ghost WAS eventually gone — but the "STILL ALIVE after N passes"
log line is worth grepping for in any future field session: it is
independent, live confirmation that removal-then-verify is not always
one-shot on this build, exactly as the engine source predicts. Not chased
further this session; flagged for whoever next touches ghost/replica
removal code.
