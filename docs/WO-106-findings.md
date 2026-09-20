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
* **Phase 2 (vector-getter table churn) done, unconditional, source only.**
  9 hot per-tick call sites converted to reusable scratch tables. No
  before/after measurement was possible without a rebuild — recorded as an
  honest gap, not a skipped step (§4.4).
* **Phase 4 (replica soul-id) is a clean DEAD END, not a width problem.**
  Tried the bare hex WUID and the correctly-padded 128-bit dashed form as
  `SharedSoulGuid` against a real world NPC's own WUID — both failed with
  `soul guid ... is not in the database`, while a known roster GUID bound
  immediately (control). **`SharedSoulGuid` indexes an authored content
  database; a live NPC's runtime WUID was never a member of it, at any
  width or encoding.** The replica stays blocked exactly as WO-104 left
  it — correctly, not from a bug. Full detail and the exact failing/
  succeeding calls in §5.
* **Phase 5 (`ENTITY_FLAG_NO_SAVE`) done and live-verified.** Applied at
  all 8 real spawn call sites in the file; the flag-setting mechanism
  itself was tested against a live disposable entity (not just compiled).
  The hidden-original half of the save hazard was deliberately left to the
  existing WO-84 sweep this session — a recorded decision, not an
  oversight (§6.4).
* An unprompted finding from the Phase 0.5 test cleanup: `mp_remove_all`
  logged `test_ghost STILL ALIVE after 4 passes` before eventually
  reporting removed — a live instance of WO-105 contradictions entry 9 (a
  refused removal becomes a hide). Not chased this session; noted in §7.

## 1. Phase 0 — the probes (all observed, live, solo)

Run via the debug console API (`http://127.0.0.1:1403/api/System/Console/
ExecuteString`, GET with a `command` query parameter — see §2 for the exact
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

This clears **Phase 4** to run — see §5 for what was tried.

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
removed immediately after with `mp_remove_all` (see §7's unprompted
finding — the removal took 4 passes before reporting success).

### 1.6 Gate table (0.6)

| phase | gated on | result |
|---|---|---|
| 1 (console placeholder) | 0.1 | **cleared, done this session (source only, not deployed)** |
| 2 (vector-getter churn) | none (unconditional) | done this session |
| 3 (ground-collider) | live two-player test | **not run — no peer tonight** |
| 4 (replica soul-id) | 0.4 | **cleared, Branch B — attempted this session, see §5** |
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

## 3.7 Live syntax check (both Phase 1 and Phase 2 changes)

No `lua`/`luac` on this machine, same gap WO-69 hit. Reused its exact
idiom: the game's own `loadfile`, compile-only, no execution, against the
live edited source file directly (not pasted through the console — the
whole file is ~500 KB, far past the transport's per-call budget).

First attempt used Windows backslash paths and failed with every
backslash silently stripped by the transport (`C:UsersJonastyDocuments...`,
no separators at all) — **not a syntax problem**, a path-escaping
artifact of this transport, worth remembering for any future live probe
that needs a Windows path. Forward slashes work fine (Windows accepts
them in file APIs):

```
#local f, err = loadfile("C:/Users/Jonasty/Documents/KCD2_MP/kdcmp/Data/Scripts/Startup/kdcmp.lua"); System.LogAlways("PROBE compile ok=" .. tostring(f ~= nil) .. " err=" .. tostring(err))
```
→ `PROBE compile ok=true err=nil`. Confirms Lua 5.1 syntax is valid for
every change through end of Phase 2 below. This is a **compile-only**
check — it does not execute the file, so it says nothing about runtime
behavior, only that the parser accepts it. Runtime behavior still waits on
a rebuilt pak (§3.5/3.6).

## 4. Phase 2 — vector-getter table churn (unconditional)

### 4.1 What changed

Per WO-105 §3.2/17.3: `GetWorldPos()`/`GetWorldAngles()` called with **no
argument** allocate a fresh Lua table every call; passing a table in
writes into it instead. Converted the four hot per-tick call sites the
brief named explicitly, each with its own file-local scratch table
(never shared across call sites, per the brief's ownership rule):

| function | call site | cadence | scratch table(s) added |
|---|---|---|---|
| `KCD2MP_EmitState` | player `GetWorldPos()` + `GetWorldAngles()` | every emit tick | `EMITSTATE_POS_SCRATCH`, `EMITSTATE_ANG_SCRATCH` |
| `KCD2MP_NpcSyncTick` | player `GetWorldPos()` (once/tick) + per-tracked-NPC `GetWorldPos()`/`GetWorldAngles()` (the MP-NPCREAD-bracketed loop) | per tick × every tracked NPC | `NPCSYNCTICK_PPOS_SCRATCH`, `NPCSYNCTICK_POS_SCRATCH`, `NPCSYNCTICK_ANG_SCRATCH` |
| `KCD2MP_NpcPuppetTick` | player `GetWorldPos()` (once/tick, target-tracking) + per-puppet `GetWorldPos()` (tug-of-war detection) | 50 ms × every live puppet | `NPCPUPPETTICK_PPOS_SCRATCH`, `NPCPUPPETTICK_AP_SCRATCH` |
| `KCD2MP_InterpTick` | player `GetWorldPos()` (once/tick) + per-frozen-ghost `GetWorldPos()` | 50 ms × every frozen ghost | `INTERPTICK_PLAYERPOS_SCRATCH`, `INTERPTICK_WP_SCRATCH` |

**9 call sites converted** out of the 84+13 = 97 total no-argument
`GetWorldPos`/`GetWorldAngles` sites WO-105 counted. The other ~88 are
one-off calls (spawn paths, console commands, setup) per the brief's
explicit instruction to leave those alone — changing all 97 for tidiness
was not the point and adds review risk for no measured benefit.

### 4.2 The ownership rule applied

One scratch table **per call site**, declared `local` at file scope
immediately above the function that uses it (so it persists as an upvalue
across calls instead of being reallocated every tick — the whole point —
while still never being visible to, or reachable from, any other
function). Every converted site reads the returned table's fields
(`.x`/`.y`/`.z`) into locals or scalars **immediately**, in the same
`pcall` closure, and never stores or returns the table itself.

**Checked deliberately before converting, per the brief's warning about
this exact trap:** every site that copies fields into a *new* table
(`KCD2MP_NpcPuppetTick`'s `p.attr[#p.attr+1] = { x = ap.x, y = ap.y, n = 1
}`) copies **scalars**, not the reused table reference — verified by
reading the surrounding ~130 lines of each converted function in full
before editing it, not just the single call line. No site was found that
returns or stores a `GetWorldPos()` result directly; all of them
destructure into locals or format strings within the same closure.

### 4.3 What was deliberately left alone

`KCD2MP_InterpTick`'s riding-check block (`GetWorldPos()` on the player and
on each nearby entity while probing for a mount) was **not** converted: it
runs once per 5 ticks (~100 ms) inside a small `GetEntitiesInSphere`
result set (typically 0-2 entities within 2.5 m), so its call volume is
roughly two orders of magnitude below the four sites above. Left as a
one-off per the brief's scope discipline ("the hot loops, not all 84
sites").

### 4.4 Measurement

**Not taken this session.** WO-103 Phase 0's `MP-NPCREAD` bracket
(`KCD2MP_NpcSyncTick`'s `readT0`/`mp_durstat_add` pair, unchanged by this
edit) is the intended before/after instrument, but comparing mean/p95 at
the same tracked-NPC count needs the **fixed code actually running**,
which needs the pak rebuilt and the game restarted (§3.5) — the same
deploy gate blocking Phase 1's live verification. **This is an honest gap,
not a skipped step**: the brief's instruction for this exact situation
("if the number does not move, say so... feeds Phase 6's ranking directly")
applies symmetrically to "the number was never measured" — recorded here
so Phase 6's audit does not accidentally treat this as measured-and-flat.
**Action for next session with the pak deployed:** run a tracked-NPC-heavy
scene, read `MP-NPCREAD` mean/p95 from `kcd.log`, compare against a
pre-Phase-2 build of the same scene if one is still available, or simply
record the post-Phase-2 numbers as a new baseline if not.

### 4.5 Synthetic coverage

No new automated test added for this phase — the brief did not ask for
one (unlike Phase 1's explicit "add checks"), and a grep-based static
check would only prove the scratch-table argument is present, not that
the ownership rule holds (that needs the kind of full-function read done
by hand in §4.2). The live `loadfile` compile check (§3.7) covers syntax
for this phase along with Phase 1.

## 5. Phase 4 — replica soul-id: DEAD END, cleanly established

**The 34/34 refusals are explained, and the fix is not reachable.** Branch
B (0.4: `soul:GetId()` is a `ScriptHandle`, 16 hex digits) is confirmed,
and the natural next steps both fail — not from a parsing bug, but from a
structural fact about what `SharedSoulGuid` actually indexes.

### 5.1 Method

Reused the exact known-answer check `KCD2MP_NpcReplicaPromote` already
uses (`r.soul ~= nil` after `XGenAIModule.SpawnEntity`) as a live, one-shot
probe, spawning disposable throwaway entities (`kcd2mp_wo106_probe_a/b/c`)
rather than touching the real promote path. Source NPC: `ttkc_man_5`,
WUID `05000000000001DC` (from §1.4).

### 5.2 Attempt A — bare undashed hex WUID as `SharedSoulGuid`

```lua
XGenAIModule.SpawnEntity({ Name = "kcd2mp_wo106_probe_a", ClassName = "NPC",
    Pos = {...}, SharedSoulGuid = "05000000000001DC", NoAI = true })
```
Result: `spawned=false hasSoul=nil`, and `kcd.log` logged:
```
[Error] soul guid 05000000-0000-0000-0000-000000000000 is not in the database
```
**This is itself a finding, independent of the outcome:** Warhorse's
`SharedSoulGuid` handler DID convert the bare hex into a dashed CryGUID for
its lookup (confirming it does route through *some* GUID-formatting path,
as WO-105 §1.2/17.4 predicted for the engine) — but it **silently dropped
every hex digit past the first 8**, turning `...0001DC` into
`...00000000`. Whether this is a genuine parser bug on this build or a
deliberate 32-bit-only legacy path is not known — not chased further,
since Attempt B below makes the question moot.

### 5.3 Attempt B — the full dashed form, built by hand

```lua
SharedSoulGuid = "05000000-0000-01DC-0000-000000000000"
```
(hipart = the WUID hex exactly, split 8-4-4 per WO-105 §1.2's byte layout;
lopart = all zero, split 4-12 — this exact construction, worked through by
hand against the WUID `0x05000000000005DD` in WO-105 §17.4, reproduced
digit-for-digit here against a different WUID.)

Result: `spawned=false hasSoul=nil`, `kcd.log`:
```
[Error] soul guid 05000000-0000-01dc-0000-000000000000 is not in the database
```
This time **every digit survived intact** (confirmed by the error message
itself echoing our exact input, lowercased) — and it still failed, with
the same "is not in the database" reason, not a parse failure.

### 5.4 Control — a known roster `SharedSoulGuid`

To confirm the negative results above are real and not a broken test
harness:
```lua
SharedSoulGuid = "cfa65480-f361-4cf8-80c5-1900b7846bc8"  -- from kdcmp.lua's own roster
```
Result: `spawned=true hasSoul=true soulId=userdata: 05000000000005E4`.
**The mechanism works** — a real, authored `SharedSoulGuid` binds
immediately, no error, no "not in the database". Also notable: the
resulting replica's own WUID (`...05E4`) is a **fresh value**, unrelated
to the GUID that was passed in — confirming a `SharedSoulGuid` and a WUID
are populated independently at spawn time, not derived from one another.

### 5.5 Conclusion — DEAD END, not a width or encoding problem

The width mismatch (WO-105 contradictions entry 3: 64-bit WUID vs 128-bit
CryGUID) was never actually the blocker. Even with the width corrected and
every digit preserved exactly (§5.3), the lookup still fails. **The real
finding: `SharedSoulGuid` indexes an authored content database of defined
character templates. A live NPC's runtime WUID was never a member of
that database, at any width, in any encoding, dashed or not — it
identifies a live simulation instance, not an authored template.** There
is no conversion to find, because there is nothing on the other side to
convert to.

This clears the question WO-105 §17.4 raised ("is a soul WUID the same
thing as a soul CryGUID at all") to a firm **no**, and closes the specific
lead §17.4 offered (`CryGUID::FromString`'s bare-hex path) — that path
exists and even partially misbehaves (§5.2), but the destination it leads
to doesn't contain what we need regardless.

**The replica stays blocked, unchanged from WO-104: 34/34 (now effectively
36/36 counting this session's two negative attempts) refuse on
`soul-id-unreadable`, correctly, because there is no value that would let
them proceed.** No code was changed in `KCD2MP_NpcReplicaPromote` this
session — the gate's shape (refuse rather than guess) was already right
per WO-104's fail-closed design, and this session found nothing that
should replace what it is refusing on.

**What would actually unblock this, for a future WO:** a native (RTTR or
DLL-side) route to either (a) read an NPC's *authored* `SharedSoulGuid`
directly instead of deriving one, if such a field exists on the soul
object, or (b) skip `SharedSoulGuid` entirely and bind the replica to the
original's identity through whatever native mechanism actually owns
"which character template is this soul." Both are native-only questions,
out of scope for a Lua-only WO.

## 6. Phase 5 — `ENTITY_FLAG_NO_SAVE` on every mod-spawned body

### 6.1 Mechanism, live-verified

New helper `mp_set_no_save(e)` (right after `mp_log`'s definition):
```lua
local function mp_set_no_save(e)
    if not e then return false end
    local ok = false
    pcall(function() e:SetFlags(ENTITY_FLAG_NO_SAVE, 3); ok = true end)
    return ok
end
```
Mode `3` = OR (set the bit) per `entity:SetFlags`'s documented mode
semantics (1=AND, 2=AND-NOT, else=OR) — adds the flag without disturbing
whatever else the engine already set on the entity.

**Live-verified the mechanism itself actually works**, not just that it
compiles: spawned a throwaway `kcd2mp_test_ghost`, called the exact same
`SetFlags(ENTITY_FLAG_NO_SAVE, 3)` line against it, and confirmed the bit
was really set by checking it against `GetFlags()`'s return with a bitmask
test (`(after % (NO_SAVE*2)) >= NO_SAVE`):
```
PROBE no_save_apply ok=true before=1.67772e+07 after=1.681e+07 hasBit=true
```
The `before` value floating around 1.6777e7 (i.e. already near the 2^24
float-precision ceiling from §1.5) is itself a reminder that this entity's
existing flags already sit close to that boundary — worth keeping in mind
for any future flag arithmetic on a heavily-flagged entity, though it did
not cause a problem here since bit 15 (32768) is far below the ceiling.

### 6.2 Where it was applied — every spawn call site, by grep, not by guess

Grepped for every `SpawnEntity` call in the file (8 real call sites,
excluding comments and `AddCCommand` help text) and added
`mp_set_no_save(...)` immediately after each one resolves to a real,
non-nil entity handle:

| site | function | body |
|---|---|---|
| `kdcmp.lua:4595` | `KCD2MP_NpcReplicaPromote` | the replica (`kcd2mp_r_*`) |
| `kdcmp.lua:5897`/`5902` | `KCD2MP_SpawnGhost` (primary + fallback) | every ghost body |
| `kdcmp.lua:5996` | `KCD2MP_SpawnGhost` (class-mismatch respawn) | the replacement body when the first spawn built the wrong class |
| `kdcmp.lua:6424` | ghost horse proxy spawn | `kcd2mp_horse_*` proxy horses (**not** an adopted real-world horse — that path returns early and is untouched, since it is a real persistent world entity, not mod scaffolding) |
| `kdcmp.lua:10168` | `KCD2MP_SpawnArmoredNPC` (also covers `mp_spawn_knight`/`mp_spawn_white_red`, which call through it) | test/demo armored NPC spawns |
| `kdcmp.lua:10405` | `KCD2MP_SpawnHorseTest` | class-name probe spawns |
| `kdcmp.lua:10662` | `KCD2MP_TestXGenSpawn` | throwaway class probe (already self-removes after 10s; this is belt-and-braces for the window before that timer fires) |
| `kdcmp.lua:10879` | `mp_item_spawn` (WO-48 dropped-item sync) | the one-tick `kcd2mp_ianchor_*` placement anchor |

### 6.3 What was deliberately NOT flagged, and why

**The finalized dropped-item entity (`mp_item_finalize`'s `placed`) was
NOT flagged.** This needed a judgment call, recorded here: the anchor
(§6.2's last row) is pure mod scaffolding, discarded within one or two
ticks either way. `placed`, once adopted, is the **engine's own real
bound pickup entity**, created through the ordinary
`inventory:CreateItem` + `human:PlaceItem` path — the same mechanism any
in-game item drop uses. Flagging it `NO_SAVE` would mean a peer's dropped
item vanishes on any save/reload, which is a **behavior regression**, not
a fix: a real dropped item persisting across a save is exactly what a
player already expects from vanilla KCD2. This is different in kind from
a replica/ghost/anchor, which are pure mod artifacts with no vanilla
equivalent.

### 6.4 The other half of the save hazard — NOT addressed this session

Per WO-105 contradictions entry 2/4 and the brief's §5.3: **flagging the
replica does not stop the ORIGINAL, hidden NPC from being saved as
hidden.** A save taken mid-promotion still persists a hidden NPC. This
session made **no change** to that half — no code changed in
`KCD2MP_NpcReplicaDemote` or the `Hide`/unhide paths, and `Invisible()`
was not tried as an alternative to `Hide()`. The brief listed this as an
explicit either/or decision (unhide-on-every-demote-path, which is
already true; `Invisible()` instead of `Hide()`, unverified whether it
saves; or accept the exposure and keep the sweep). **Decision made this
session: accept the exposure and keep the WO-84 periodic sweep**, which
already exists and already handles this class of problem (a hidden
original with no ghost behind it, from any cause) — not because the
other options were evaluated and rejected, but because they were not
evaluated at all this session, and the sweep is a working mitigation
already in production. This is the conservative, lowest-risk choice for
an unattended solo build; revisit with a real evaluation of `Invisible()`
in a future WO if the sweep's window (mid-promotion crash/hard-exit only)
ever proves too wide in the field.

### 6.5 What to test after the next rebuild

1. Spawn a ghost (`mp_spawn_test`), then `#local e = System.GetEntityByName("kcd2mp_test_ghost"); System.LogAlways(tostring(e:GetFlags()))` — confirm the printed value has the `32768` bit set (e.g. via the same modulo check used in §6.1).
2. Save and reload with a live ghost or replica present; confirm the mod body is genuinely absent afterward (not just hidden) — this is the actual end-to-end proof the flag does what §8.3 of the engine reference says it does.
3. Drop an item as a peer, confirm it is STILL there after a save/reload on the receiving side (regression check for §6.3's judgment call — a passing case here means "unchanged from before," which is correct).
4. This phase's revert, if needed: every change is one new helper function plus one call added at 8 sites — a single `git revert` removes all of it cleanly, with no interaction with Phase 1/2/4's changes (different functions, no shared state).

## 7. Unprompted finding: a refused removal became a hide (observed)

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
