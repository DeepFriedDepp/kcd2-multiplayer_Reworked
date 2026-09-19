# WO-103 — native position reads, and uncap the radius

Session 2026-09-18. Builds on WO-102.5 (native NPC scan + uncapped
co-located ownership, shipped 0.25.1). Evidence marks, strict:
**(observed)** = a log or a screen; **(code-verified)** = read out of
source, a binary, or a shipped data file; **(synthetic)** = a test harness,
no game; **(inconclusive)** = exactly that. Nothing rounded up.

No game ran this session (same constraint as WO-102/WO-102.5's own opening
sessions: the environment this runs in cannot launch/inject into the game).
Everything below is **(code-verified)** or **(synthetic)** unless marked
otherwise. `docs/WO-103-field-runbook.md` is the handoff for what needs a
live game.

Scope, restated: this WO moves position/yaw reads to native and removes the
authority-radius ceiling. Health/dead/KO/drawn/engaged stay in Lua --
unmapped offsets, explicitly WO-103.5's job, not attempted here.

---

## 0. Phase 0 -- measuring what Phase 2 replaces

### 0.1 What was built (code-verified; synthetic, scenario `dd`)

* **`MP-NPCREAD path=lua|native|mixed n= mean_ms= p50_ms= p95_ms= max_ms=
  window_s=`** -- a bucketed-histogram/percentile aggregator, mirroring
  `CadenceStats.cs`'s scheme (1ms buckets, `Percentile` by cumulative count)
  but implemented fresh in Lua: **Lua cannot call the C# class**, so "reuse
  that aggregation code if it is reusable" (the prompt's own phrasing)
  resolved to "reuse the SCHEME, not the code." One difference from
  `CadenceStats`, stated plainly: that class measures the GAP between
  samples (cadence); this measures the DURATION of one bracketed span (the
  whole per-tracked-NPC loop, once per tick it runs) -- a duration
  aggregator, not a cadence one, feeding the same line shape so the A/B
  stays a single grep.
* **Classification is per-TICK, not per-NPC.** The bracket wraps the whole
  `for name, t in pairs(KCD2MP.npcTracked)` loop; within it, each NPC's read
  increments a `native` or `lua` hit counter (never a second
  `GetEntityByName` either way -- see Phase 2). A tick where every tracked
  NPC read from the push is `path=native`; all-live is `path=lua`; a tick
  straddling the ~6s freshness window with a mix of both is honestly
  reported as `path=mixed` rather than folded into either pure bucket.
* **`MP-NPCTRACK tracked=<n> culled=<n>`**, same periodic cadence (15s).
  WO-102.5's own runbook had to count `NPC-SYNC tracking`/`untracking` log
  lines by hand (findings §2.3 item 5's own named friction) -- this is
  direct.
* Both piggyback one shared 15s interval (`mp_wo103_periodic_report`,
  `KCD2MP._wo103ReportAt`), which also re-runs `KCD2MP_NpcReadCompare` while
  `readNative` is on -- see Phase 2's fail-closed design.

### 0.2 The baseline -- NOT taken

No game ran. `docs/WO-103-field-runbook.md` §1 is the A/B this WO's whole
justification rests on; it has not been run. State clearly: "native is
probably about as fast, possibly negligibly so" is this session's honest
prediction (§Phase 2.4 below), not a measured result.

---

## 1. Phase 1 -- uncap the authority radius

### 1.1 What was built (code-verified; synthetic, scenario `bb` updated)

* **Upper clamp removed.** `KCD2MP_SetAuthorityRadius` (kdcmp.lua) now
  rejects only non-numeric/NaN input and anything below the 10m floor.
  `500`/`1000`/anything finite and positive above the floor is accepted --
  the point of this WO is to find the real ceiling by testing to failure
  (`docs/WO-103-field-runbook.md` §2), not stop at a guessed one.
* **Default raised 150 -> 300m** (`KCD2MP.wo1025.authorityRadius`), the
  maintainer's original target from WO-102.5's own session. Nothing
  measured argues against it -- WO-102.5's own 150m result held cleanly
  (§6.3 there: zero violations/crashes, culling kept streaming cost to
  22-of-78) -- but 300m ITSELF has not been measured (§Phase 3 below).
  `GameBridge.cs`'s own copy of the radius (`_npcScanRadiusM`, used before
  the mod ever announces a change) is bumped to the same 300 so the two
  agree before any runtime change, same discipline WO-102.5 established.

### 1.2 Reply truncation -- a real bug found and fixed, not just surfaced

`npc_scan.cpp`'s truncation used to `break` the ENTIRE entity walk the
instant the 8000-byte reply budget was hit. Two consequences, only one of
which the prompt named:

1. **Silent drop with no count** (the prompt's own framing) -- fixed:
   `droppedCount` now counts every further class+radius+name match found
   after the budget was spent, rather than discarding them uncounted. The
   wire header (0x87) grows 14 -> 18 bytes to carry it (agent<->DLL local
   pipe only -- does not cross the relay).
2. **A latent accuracy bug the prompt did NOT name, found while fixing (1)**:
   because the old code `break`s the loop outright, `totalWalked`/
   `vptrOk`/`vptrBad`/`nameRejects` all stopped incrementing the moment
   truncation started -- so a TRUNCATED scan's own `total_walked=` figure
   in the native log was **silently short of the real entity count**,
   exactly the "a plausible result is not a result" trap this project's
   durable context already names seven instances of (WO-96/97/99.5/100/
   100.5/101/102.5). An `NPCSCAN: first scan OK total=…` line during a
   truncated scan would have read as a normal, unremarkable number while
   quietly being wrong. Fixed by the same change: the walk now always
   finishes (it was already walking every entity regardless of truncation;
   truncation only ever affected whether a match was PUSHED, never the
   cost of getting to it), so these counters are accurate whether or not
   truncation fires.
* Both native (`NPCSCAN: reply truncated -- …`) and agent
  (`MP-NPCSCAN-TRUNCATED dropped=… returned=…`) log lines are new and
  edge-triggered (fire on the 0/1 transition only, not every ~2s scan).

### 1.3 Reply size, recomputed -- unchanged, restated with real numbers

The native wire reply (0x87) **did not grow this WO** beyond the 4-byte
`droppedCount` header field -- WO-102.5's own Phase 2 already put
`x/y/z/yaw/isHorse` in every entry (`npc_scan.cpp`'s `NpcEntry` always had
these fields; the gap this WO closes is entirely in what the AGENT forwarded
to Lua, not the native/wire format). The per-name ceiling at `kMaxReplyBytes
= 8000` is therefore exactly what WO-102.5 already shipped, now stated
precisely rather than estimated: entry size is `1 (nameLen) + strlen(name) +
16 (x,y,z,yaw) + 1 (isHorse)` bytes.

| name length | entry bytes | ceiling (8000 / entry) |
|---|---|---|
| 1 char (min) | 19 | ~421 |
| ~10 chars (typical short name, e.g. `ttkc_man_2`) | 28 | ~285 |
| ~20 chars | 38 | ~210 |
| 59 chars (`kMaxNameLen`, e.g. `karavanyVeSvete_merchantCaravan_worker_1` is 41) | 77 | ~103 |

"Roughly 200 NPCs depending on name length" (the prompt's own estimate)
holds.

### 1.4 A ceiling the wire numbers above do NOT capture -- found while wiring Phase 2, self-imposed

The wire reply is not the only place a payload can be truncated. Adding
position/yaw to the AGENT-TO-LUA push (Phase 2) made a second, tighter
ceiling real: that push travels as one Lua statement over an
`ExecuteString` **GET request with the command in the URL**
(`HttpGameTransport.cs`), batched (not split) under a 4000-char budget the
transport already enforces. WO-102.5's `NpcScanMaxNamesPushed = 200` was
sized for a NAMES-ONLY payload (~20 chars/name x 200 = ~4000, deliberately
matching the batching budget -- WO-102.5 findings §2.2 says as much).
Adding `:x:y:z:yaw:isHorse` (~30-37 more chars/entry) to that SAME cap would
have pushed a 200-entry batch past 10,000 chars -- not caught by anything
in the reply-truncation accounting above, since it happens one hop later,
agent-to-Lua, not DLL-to-agent.

**Fixed by lowering the cap to 40** (worst case: `(59 + 37) * 40 + ~60`
wrapper stays under 4000). Not a "recheck kMaxReplyBytes" fix (the prompt's
own framing, which is about the NATIVE reply) -- a second, self-found
ceiling the richer payload created one hop downstream. Documented in
`GameBridge.cs` with the exact arithmetic.

**A real, named consequence**: at high tracked counts -- exactly where
Phase 3's radius-ceiling search is pushing -- the agent-push ceiling (40)
is now the TIGHTER bottleneck versus the native wire's own ~200-400. Most
tracked NPCs beyond the first 40 simply keep falling back to the live Lua
read every tick, which is correct (identical to pre-WO-103 behaviour, never
unsafe) but is not the win Phase 2 intended for them. Chunking the push
across multiple `ExecuteString` calls (rather than one all-or-nothing list)
would close this gap; not built this session -- flagged, not hidden.

---

## 2. Phase 2 -- native position and yaw

### 2.1 What was already there (WO-102.5, re-confirmed by reading the code,
not assumed)

`npc_scan.cpp`'s `scan()` already computes `x/y/z/yaw` for every matching
entity (the SAME `CEntity::m_worldTM` offsets `local_state.cpp` established,
WO-102 §1.2) and the 0x87 wire reply already serializes them per entry
(`NpcScanCodec.cs` already fully decoded them). **The entire gap was
agent-side**: `NpcScanTickAsync` (`GameBridge.cs`) read `res.Entries[i].X/Y/
Z/Yaw` into local variables and then discarded them, forwarding only
`e.Name` in the CSV pushed to Lua. This matches the prompt's own framing
exactly ("nearly free... the same memory, on a walk that is already
happening") -- confirmed, not just assumed.

### 2.2 What was built (code-verified; synthetic, scenario `dd`, 18 new checks)

* **Richer push format**: `NpcScanTickAsync` now encodes
  `"name:x.xxx:y.yyy:z.zzz:yaw.yyyy:isHorse"` per entry (colon-separated,
  comma-joined -- safe unescaped since the name gate `^[A-Za-z0-9_]+$`
  already forbids `:`/`,` and the floats never produce either).
  `KCD2MP_ApplyNativeScan` parses the WHOLE entry with one pattern, so a
  malformed entry drops entirely rather than parsing a name next to garbage
  numbers, into `KCD2MP._nativeScan.pos[name] = {x,y,z,yaw,isHorse}`.
* **One substitution point**, in `KCD2MP_NpcSyncTick`'s per-tracked-NPC
  loop: `e = System.GetEntityByName(name)` is UNCHANGED (still runs every
  tick, for every tracked name -- health/dead/KO/drawn/engaged below all
  need `e.actor`/`e.human`, WO-103.5's unmapped territory). What changed is
  ONLY where `p`/`rot` come from next: `KCD2MP._nativeScan.pos[name]` when
  `KCD2MP.wo1025.readNative` is on AND the push is fresh (same staleness
  gate `mp_npc_rescan` already trusts the name list under -- one shared
  clock, `mp_native_scan_stale_after_s()`, not a second one); otherwise
  exactly today's `e:GetWorldPos()`/`e:GetWorldAngles().z`. Everything
  downstream (`moved`/`hpChanged`/`heartbeat`/the emit itself) is untouched
  -- same shape as WO-102.5's own scan substitution.

### 2.3 The cadence question, answered

**The scan runs every 2s; the read loop runs every tick (100ms
`npcSync.emitMs`). A naive substitution would ship up-to-6s-stale positions
every tick for the ~5.9s out of every 6 the push isn't freshly re-landed.**
The prompt asked this to be answered explicitly, not waved past. It is
answered by a property of THIS substitution specifically, not by raising
any cadence or adding a second native call:

**The fallback is free.** `e` is fetched from `System.GetEntityByName(name)`
UNCONDITIONALLY, every tick, for the state-bit reads that stay in Lua this
WO. So the "fallback path" for a stale/missing native sample is not a
second, more expensive lookup -- it is `e:GetWorldPos()`/`GetWorldAngles()`
on the entity handle the loop ALREADY holds, i.e. exactly what this loop did
before WO-103 existed. There is no "regression wearing an optimisation's
clothes" because the worst case (native absent, stale, or refused) is
byte-for-byte identical to pre-WO-103 behaviour. This is why neither of the
prompt's two named options (raise the scan cadence; add a lighter
position-only call) was needed, and why "something else" was the honest
answer: raising the scan's own cadence would multiply the cost of a
main-thread-blocking 37,079-entity walk (WO-102.5 §6.2) for a freshness win
this design doesn't need, and a second native call would need a
`FindEntityByName`-by-name primitive this session did not decompile (the
prompt's "nothing here is discovery" held -- this was deliberately not
attempted).

### 2.4 Did this actually help? Stated plainly, not hopefully

**This phase's ISOLATED benefit is small, and that is an expected result of
this WO's own scoping, not a failure of it.** Because `GetEntityByName`
still runs every tick for every tracked name regardless of `readNative`
(health/dead/KO/drawn/engaged, WO-103.5's job), and because that single
scriptbind call is what the WO's own framing identifies as the expensive
part ("each a scriptbind string lookup plus a script-table construction" --
the session prompt's words), Phase 2 only removes two CHEAPER method calls
(`GetWorldPos`/`GetWorldAngles`) on an object the loop was fetching anyway.
Phase 0's A/B (`docs/WO-103-field-runbook.md` §1, not run) is honestly
expected to show a small or even negligible `path=native` vs `path=lua`
difference -- **this is not a reason to walk the substitution back**. It is
the necessary first half of a two-part payoff: WO-103.5 moving
health/dead/KO/drawn/engaged natively too is what removes
`GetEntityByName` entirely, and Phase 2's push/parse/staleness/compare
plumbing is what that WO will have ready to extend rather than build from
scratch.

### 2.5 The known-answer check, and fail-closed (code-verified; synthetic)

`mp_npc_read_compare` (`KCD2MP_NpcReadCompare`), on the model of
`mp_npc_scan_compare`: for every currently-tracked name with a native
sample, diffs it against a fresh LIVE `e:GetWorldPos()` for the SAME entity,
same tick. Tolerance scales with the push's age
(`NPC_READ_COMPARE_BASE_M + NPC_READ_COMPARE_SPEED_MPS * age_s`, 1.0m base +
3.0 m/s -- a generous jogging bound) rather than a fixed number, since a
genuinely moving NPC drifts during the push's own staleness window and a
fixed tolerance would either false-positive on a normal walking NPC or miss
a real offset-math bug by being too loose. **Disagreement means stop, not
tune** (the prompt's own words, echoing WO-43's `pcall`-succeeding trap):
any mismatch beyond the allowance fails `KCD2MP.wo1025.readNative` closed
for EVERY name, not just the mismatched one, since a wrong offset is wrong
for every entity, not one. `mp_npc_read_native_on` re-runs the check
immediately on enable (not just periodically, unlike `npc_scan_native`'s
own toggle, which only disarms on repeated agent-side refusals and never
re-verifies its answers) -- "prove it's healthy before relying on it."

### 2.6 Wire compatibility (Phase 2)

No relay change. The richer push (agent -> Lua) is a local `ExecuteString`
call, not a network packet; the wire growth Phase 1 made (0x87's header)
is agent<->DLL, over the local named pipe, and does not cross the relay
either. `KcdMp.Relay.Tests`: 13/13, unchanged (a pre-existing gate,
re-run, not touched).

---

## 3. Phase 3 -- find the ceiling: PARTIALLY RUN, live, same day

Written not-run when this WO's own code first shipped (0.26.0); the
maintainer then ran a live session the same day (§5 below has the full
account). The radius ladder itself (45 through 5000m) DID run live --
`docs/WO-103-field-runbook.md` §2's procedure, executed via the console API
exactly as WO-102.5's own field sessions were. What did NOT run: the
native-scan-specific half of the ladder (truncation ceiling, native vs Lua
`dur_ms`), because the native push never reached Lua at all this session
(§5.2 -- an environmental/deployment problem, not this WO's code). The
expected failure order (reply truncation before read-loop cost) is
therefore still unconfirmed for the NATIVE path specifically; what ran was
the Lua fallback path's own ceiling, which is a different, real result
(§5.1) -- not what §2 originally set out to measure, but not nothing.

---

## 4. Phase 4 -- verification

### 4.1 Synthetic (observed, this session's own run)

`tools/Test-WO102Synthetic.ps1`: **194/194** (was 169 -- WO-102.5's own
count -- +25: 18 new in scenario `dd`, 4 changed/added in `bb` for the
radius-clamp removal, 3 in `z` for the new push format). Covers: native
position substitution proven by the EMITTED value (not a flag) while the
live entity is provably untouched; staleness fallback; the toggle-off path;
the known-answer check's match AND fail-closed verdicts; re-enable re-arms
the check; the Phase 0 periodic lines actually fire.

Every OTHER Lua synthetic suite in this repo re-run this session, unchanged
and green: 48, 35, 33, 72, 47, 70, 101, 32, 160, 50 (`Test-NpcSmoothSynthetic`,
`Test-GhostInterpSynthetic`, `Test-WO1005Synthetic`, `Test-WO84Synthetic`,
`Test-WO86Synthetic`, `Test-WO90Synthetic`, `Test-WO94Synthetic`,
`Test-WO95Synthetic`, `Test-WO96Synthetic`, `Test-WO98Synthetic`), plus
`Test-WO99Synthetic`'s pre-existing "always exits 2" durable quirk
(39/39 passed internally, exit code not indicative -- durable context,
not touched). No regressions from this WO's changes to shared `kdcmp.lua`.

`dotnet\KcdMp.Client.Tests`: **157/157** (was 156 -- WO-102.5's own count --
+1: `Dropped_count_survives_the_round_trip`), including 7/7 in
`NpcScanCodecTests` (5 existing + `Dropped_count_survives_the_round_trip` +
the header-size update to all existing cases). Native (`native/KCDMP`) and
the full `dotnet` solution both build clean, Release, zero errors.

### 4.2 Relay round-trip (observed)

`KcdMp.Relay.Tests`: **13/13**, unchanged (the WO-101 standing gate,
`Build-Installer.ps1` runs it before publish). Correctly out of scope by
construction: nothing this WO built crosses the relay (§1.2, §2.6).

### 4.3 Field runbook

`docs/WO-103-field-runbook.md`: written; §2 (the radius ladder) run live
the same day (§5). §1 (the Phase 0 A/B baseline) also run live (§5.1).

---

## 5. Live field session (2026-09-18, observed) -- first time ANY of this
WO's own code ran against a live game

Driven the same way WO-102.5 §6 was: the maintainer had the game loaded,
saved, and connected via the Launcher on 0.26.0; this session drove it from
the coding shell via the debug console API (`127.0.0.1:1403/api/System/
Console/ExecuteString`) and `kcd.log`/`kcdmp-native.mirror.log` directly.
**Every command needs the `#` prefix to evaluate as Lua** (`#<code>`) --
without it the console tries to resolve the whole string as a single
registered command name and refuses it as unknown; this cost several failed
probes before landing on the right syntax, consistent with WO-94's own
"console drops arguments" caution but a NEW wrinkle: the `#` requirement
applies even through the HTTP `ExecuteString` endpoint, not just the
in-game console UI.

### 5.1 Phase 0's real baseline, and the Phase 3 radius ladder -- both live, for the first time

`MP-NPCTRACK`/`MP-NPCREAD` fired on their own, unprompted, exactly as
designed. At the shipped 300m default: **tracked=78-80, culled=52-62,
`MP-NPCREAD path=lua mean_ms=1.5 p50_ms=1 p95_ms=2 max_ms=3-4`**. Radius
walked up via `#KCD2MP_SetAuthorityRadius("<m>")` and forced rescans
(`KCD2MP._npcScanAt = 0`): 600m -> tracked=161 culled=142; 1000m ->
tracked=324 culled=305, `mean_ms=3.5-5.4 p95_ms=7-11 max_ms=13-16`; 2000m ->
tracked=447 culled=427, `mean_ms=6.2-6.7 p95_ms=12-14`; 5000m -> tracked
plateaus at 457 culled=434-436, `mean_ms=7.0 p95_ms=15 max_ms=18`.

**Read-loop cost scales with tracked count, confirmed live** (the design
claim §0.1/§2.4 could only predict): roughly linear, ~1.5ms at 78 tracked to
~7ms at 450 tracked. **Zero crashes at any radius up to 5000m** (16x the
shipped default). **The tracked-count ceiling is the ENGINE's own NPC-
streaming distance, not this mod's radius** -- growth from 1000m to 5000m
(5x the radius, 25x the area) only moved tracked count from 324 to 457
(1.4x), because past a certain distance there simply are no more NPCs
loaded into memory to find, native scan or not. This narrows the runbook's
own prediction: the reply-truncation ceiling this project worried about may
never be reachable in a normal single-settlement session, because the
engine's own streaming radius caps the count first -- untested for the
NATIVE path specifically (§5.2), but the Lua-fallback numbers above make it
a live possibility, not a certainty.

**One real, mild degradation signal**: mod-tick `max` rose from ~40ms
(300-1000m) to ~62-63ms (2000-5000m) while `avg` stayed ~25ms throughout --
an occasional hitch, not a crash, and not visible in the tracked/culled or
read-duration numbers alone. Likely the Lua fallback's own
`System.GetEntitiesInSphere`-per-anchor walk (WO-102.5 §2.1: this walks the
FULL entity list every call) scaling with anchor radius, since it -- unlike
the native walk -- has never been shown to be radius-independent.

Not run: the native-specific half (native vs Lua `dur_ms` comparison, the
reply-truncation ceiling) -- blocked by §5.2. Not run: village vs. dense-
town comparison (one town, the same one WO-102.5 tested in, per matching
NPC names in the log).

### 5.2 The native scan never reached Lua this session -- a real bug, but not in this WO's code

**Root cause, confirmed**: the running agent (`KcdMpClient.exe`,
`C:\...\AppData\Local\KCDMP\KcdMpClient.exe`) hashed to a build dated 8/15 --
sha256 `37e91de7...`, nothing this session or WO-103 ever produced (this
session's own fresh-clone build hashes to `a8a27739...`). **The mod pak WAS
confirmed fresh**: `KCD2MP._nativeScan`/`KCD2MP_ApplyNativeScan`/
`KCD2MP_NpcReadCompare` all exist and behave exactly as WO-103 shipped them
-- proven by manually invoking `KCD2MP_ApplyNativeScan("name:x:y:z:yaw:h")`
via the console and watching `KCD2MP_NpcSyncTick`'s very next emit carry
the injected coordinates instead of the entity's real (unmoved) position,
then correctly fall back once the injected sample aged past
`mp_native_scan_stale_after_s()`. **This is the read substitution's first
live proof, and it is unambiguous**: the fallback-is-free design (§2.3)
behaves exactly as designed against a real, running game.

**What the stale agent produced instead**: `kcd.log` showed a Lua syntax
error, `[Lua Error] ... unfinished string near '<eof>'`, firing every ~2
real seconds from shortly after connect onward -- the EXACT cadence of
`NpcScanInterval`. An "unfinished string" error means a quoted Lua string
argument was cut off before its closing quote, i.e. **the console received
a truncated request**, not a malformed-but-complete one (a bare-name CSV
with no colons, which an old pre-WO-103 agent would send, is syntactically
complete Lua and would not produce this error). The most consistent
explanation: the debug console's own HTTP request-line handling has a
length limit well under what a ~40-200-name push can reach, and has had
this problem since WO-102.5's own native scan shipped -- this session's own
`KCD2MP._nativeScan.at` staying `nil` for the ENTIRE session (never once
set by anything other than a manual injection) is consistent with every
automatic push failing this same way, not merely being absent. **This is
NOT proven** -- the agent's own console/stdout was unreachable (`agent.log`
existed but stayed 0 bytes all session, the same AppData-sandbox-
redirection constraint WO-102.5 hit) -- but it is the best-supported
explanation available from `kcd.log` alone, and it predates anything this
session did (the error's first occurrence in the log is well before this
session's own console probes began).

**Practical consequence, stated for the maintainer**: reinstalling with a
genuinely matched set (confirmed by hash, not by trusting the installer
finished) is necessary but may not be SUFFICIENT -- if the debug-console
truncation theory is right, a fresh, correctly-matched agent could still
fail to push native scan data past a certain payload size. This needs a
follow-up live test with a confirmed-fresh agent hash before it can be
called fixed either way.

### 5.3 The known-answer check bug, live-found and fixed same day

See the commit `b6634f4` and `docs/releases/RELEASE-NOTES-0.26.1.md`. The
manually-injected stale entry from §5.2's own substitution proof (~500s
old by the time the periodic `KCD2MP_NpcReadCompare` re-ran) reported
`verdict=match` with `delta_mean_m` in the 50-130m range every single
compare cycle -- the tolerance formula's `age`-scaled term had no ceiling,
so an arbitrarily old, arbitrarily wrong push could never fail the check.
Fixed by gating the whole comparison on the same freshness window the read
substitution already trusts. This was NOT caught by the synthetic suite
before this session, because every synthetic scenario's ages were small
(seconds, not minutes) -- a real gap in test design the live session
exposed, now closed with a dedicated stale-age regression check.

---

## State bits explicitly left in Lua -- handed to WO-103.5, not attempted here

Health, dead, KO, drawn, engaged. These live on `e.actor`/`e.human`
(soul/actor, not `CEntity`), the offsets are unmapped, and WO-99's
`sample_health` in `rttr_abi.cpp` is the stated starting point (per the
session prompt). Not attempted, not partially attempted, not scoped-and-
abandoned -- simply out of this WO's boundary. The reply format has room:
Phase 1's header growth (14->18 bytes) and Phase 2's per-entry format both
leave the entry structure exactly as WO-102.5 shipped it
(`NpcEntry{name,x,y,z,yaw,isHorse}`) -- WO-103.5 will need to grow the
entry itself (more fields per NPC), which is a bigger wire change than
either of this WO's two header-only/no-op-on-the-wire growths, and should
budget for that explicitly rather than assume it is "just one more field."

## Durable context added this session

An eighth costume for the standing trap ("a plausible result is not a
result"): `npc_scan.cpp`'s pre-WO-103 truncation `break` made
`total_walked`/`vptrOk`/`nameRejects` silently under-report themselves the
moment a scan truncated -- a normal-looking number that was quietly wrong,
found only because fixing the NAMED gap (the dropped-count itself) required
reading the surrounding loop closely enough to notice the early exit. Filed
alongside WO-96/97/99.5/100/100.5/101/102.5's own instances in
`docs/WO-103-progress.md`'s closing note.

A ninth, live-found the same day (§5.3): `KCD2MP_NpcReadCompare` reporting
`verdict=match` was itself a plausible-looking result that was quietly
wrong -- an unbounded age-scaled tolerance meant "match" proved nothing
once the compared entry was old enough, and nothing in the log line itself
signalled that the check had become meaningless rather than genuinely
passing.
