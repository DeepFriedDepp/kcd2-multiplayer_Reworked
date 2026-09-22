# WO-110 — findings: 0.26.5, every WO-109 fix on

Session 2026-09-22, solo, against the running Modding Tools build (0.26.4
pak at the start; rebuilt WO-110 paks from Phase 1 on). Progress, gaps and
side effects: `docs/WO-110-progress.md`. Field page:
`docs/WO-110-peer-test-runbook.md`. Release notes:
`docs/releases/RELEASE-NOTES-0.26.5.md`. Read first: `docs/WO-109-audit.md`
(R-numbers below are its §2), `docs/WO-109-progress.md`,
`docs/WO-108-findings.md`, `docs/WO-108-toggle-inventory.md`.

Evidence marks: (observed) / (code-verified) / (synthetic) / (inconclusive).
**Nothing here ran two-player.** 0.26.5 ships on solo evidence as a stated
risk. **Nothing was deleted.** One commit per fix; every behaviour change has
a toggle, a default and a row in both presets. Paths: `<repo>`, `<install>`
(the Modding Tools install), `<saves>`.

---

## 0. Answer first

* **14 of the 15 WO-109 R-items shipped, every one on by default.** R8 (an
  engine read of the suspend state) did **not** ship: no RE note or DLL
  source records an entity → `C_IntelligentObject` hop, and the WO bounded
  that effort. §5. Nothing was reverted.
* **R2 confirmed live before it was touched, then fixed and re-tested
  live**: `mp_entity_id Dude` → `')' expected near 'Dude'` on the 0.26.4 pak;
  after the fix, all 41 argument commands typed bare and with an argument
  (82 forms) produced 0 Lua errors against the shipped pak. §4 item 2.
  The WO-108 `mp_puppet_rate 50→1000` sinking A/B was therefore void: it
  failed the same way (observed).
* **The console has a hard command-length ceiling of ~2,100 URL-encoded
  characters** (2,067 executes, 2,167 does not; observed). Three
  consequences, §3.1: the agent's 4,000-raw-character batch budget was never
  safe; the WO-103 native position push (~2,900 encoded) most likely never
  landed in the field, so R1's "2 s snapshot" was probably never in effect
  live (inconclusive on 0.26.4's exact bytes; the arithmetic is not); and
  this WO's own R3 chunked push hit it until the batching was rewritten by
  encoded size.
* **The new payload smoke gate found a shipped defect on its first run**
  (§3.2): the relay's publish overwrote the agent's `System.Text.Json` 8 with
  10, whose `System.IO.Pipelines` dependency was not in the agent's
  `deps.json`; every JSON write in the shipped agent failed with
  `Could not load file or assembly 'System.IO.Pipelines'` (observed against
  the 0.26.4-era tree). Fixed by pinning the package in agent and launcher.
* **A save load changes the engine's response to puppet writes** (§3.4,
  observed, one NPC, one load): before an in-process quick-load, 250 writes
  a quarter metre into the ground read back to the millimetre (0 MP-NPCZ,
  0 contentions); after it, the same stream produced `kind=contention` at
  0.31–0.49 m per tick toward the anchor and `MP-NPCZ delta=+0.28…+0.31`
  (the body lifted out of the ground) for 30 s. This is WO-109 failure mode
  3, reproduced solo, by a reload. Mechanism (inconclusive).
* **Sticky authority demonstrated solo** (§4 item 7): the agent was killed
  while a synthetic peer watched; the peer saw the relay's `Disconnect`
  2 ms later, the relay re-elected, and the reconnecting agent **got id 0
  back** and authority with it. Under the 0.26.4 FIFO pool it would have
  come back as id 2 and the peer would have owned every NPC.
* **Henry died during the smoke test** (§3.3): GAME OVER, "bled to death",
  most likely the two factionless armed test NPCs that `mp_spawn_armor`
  (part of the R2 checklist) put 3 m from him. A death screen halts every
  Lua timer while the console API keeps answering; an hour of "the emitter
  produces no frames, all chains dead" was that. Methodology finding, not a
  mod defect.

---

## 1. Predictions — committed 2026-09-22, before the 0.26.5 two-player session

Same rules as WO-109 §1: both players on 0.26.5 through the launcher, in a
town crowd, runbook followed. "Joiner" = the machine whose kcd.log says
`MP-AUTHORITY-OWNER … authority=peer`. WO-109's predictions were for 0.26.4
and no longer apply.

| # | prediction | P |
|---|---|---|
| P1 | The runbook verdict comes back "jitter substantially reduced within the streamed radius" on the joiner, 0.26.5 defaults | **0.45** |
| P1a | …the high-frequency vibration component is substantially reduced | 0.70 |
| P1b | …walking streamed NPCs visibly *step* (stand ~2 s, dash) — the R1 shape. Low because the native push probably never landed on 0.26.4 either (§3.1) | 0.10 |
| P1c | The joiner's cadence line reads `moving … mean=100–200ms` and `sender-spacing … mean ≈ arrival mean`, `seq_gaps` < 1 % of packets | 0.85 |
| P1d | Clean pass ("jitter gone, no sinking") | 0.08 |
| P2 | Sinking substantially reduced | **0.20** |
| P2a | `MP-NPCZ` lines appear on the joiner with a consistent sign for a given NPC (the instrument sees *something*) | 0.75 |
| P2b | …and they cluster after a save load or a first packet, not uniformly (§3.4) | 0.55 |
| P3 | `kind=contention` violations on the joiner are near zero **except** inside ~60 s after a save load or a puppet's creation, where they burst at ~0.3–0.5 m per tick toward the anchor (the §3.4 shape) | 0.60 |
| P4 | Every joiner `MP-PAUSE … event=pause` carries `exec=ok` | 0.95 |
| P5 | For eid < 0x70000 the joiner's `MP-PAUSE eid=/wuid=` equal the host's `MP-NPCID eid=/wuid=` for the same name, every name | 0.95 |
| P6 | The owner's `MP-NPCTRACK tracked=` exceeds 40 in town (typical 60–90) and `MP-NPCSCAN dir=consume verdict=native pushed=` equals it | 0.90 |
| P7 | An NPC standing next to both players has a `NPC-SYNC puppet start` on the joiner (coverage gap closed) | 0.85 |
| P8 | Authority sits on the relay host's machine for the whole session, including across a host-agent reconnect (`MP-AUTHORITY-OWNER … reason=relay-local` on the relay) | 0.90 |
| P9 | `MP-RELAY-DROPS` is nonzero at least once (any framing drop, either side) | 0.30 |
| P10 | A mixed-version attempt (one machine still on 0.26.4) is refused with both messages, if anyone tries it | 0.98 |

**Top failure modes, ranked, with the line that identifies each:**

1. **Post-reload/post-creation write fight (§3.4).** Joiner:
   `MP-AUTHORITY-VIOLATION npc=<n> kind=contention dist_m=0.3–0.5 … cos≥0.85 anchor_m≈1–3`
   in the minute after `MP-RELOAD-RESET` or `NPC-SYNC puppet start`, plus
   `MP-NPCZ … delta=+0.2…+0.4`. If it also appears with no reload nearby,
   the trigger is puppet creation, not the load.
2. **Joiner Lua ingress at 60 m.** Joiner agent console: `MP-BATCH-DROP`
   lines (a batch failed) or relay `MP-RELAY-DROPS … 0x27:pressure-coalesced`.
   Joiner cadence line `seq_gaps` climbing. Fix in the field:
   `mp_cull_radius 30` on the **host**.
3. **Authority flip.** Relay `MP-AUTHORITY-OWNER … changed=1` more than
   once with the same two names; both kcd.logs show `authority=self` at
   different times. Should not happen (R4); if it does, `reason=` says why.
4. **Identity mismatch.** A joiner `MP-PAUSE … eid=<E>` with E < 0x70000
   that differs from the host's `MP-NPCID eid=` for that name.
5. **Statue.** Joiner `MP-PAUSE … event=pause` for a name and no
   `event=resume|release|forget` for it within 30 s after the stream stops.
   `MP-PAUSE-GAP` should catch it; if it does not, `mp_resume_all`.
6. **Sinking without an instrument line.** Visible sinking and **no**
   `MP-NPCZ` for that NPC: the body is exactly where the joiner writes it and
   the stream's Z is low — look at the host's `MP-NPCID` line and its own
   NPC. That would move the sinking question to the owner's read.
7. **The truncation returning.** Any `[Lua Error] … unfinished string near
   '<eof>'` in either kcd.log: a statement outgrew the console ceiling
   (§3.1). The agent console shows `MP-BATCH-DROP reason=oversize` if the
   guard caught it first.

**What would show the two-controllers diagnosis wrong (WO-109 P3/P3a):**
unchanged from WO-109 §1, with one addition: if contention bursts are
confined to the post-reload/post-creation minute (P3 here), the second
writer is transient engine settling, not a live brain.

---

## 2. The R-items — what shipped

| # | fix (commit) | default / toggle | preset rows (clean = 0.26.5 / legacy = 0.26.4) | evidence |
|---|---|---|---|---|
| R1 | position/yaw always from the live Lua read; native scan for enumeration only | `readNative=false`; `mp_npc_read_native_on/off` | off / on | owner cadence 105–113 ms mean on walking NPCs (observed, §3.6) |
| R2 | 38 → 41 templates `f(%line)`; handlers accept nil; static test forbids a quoted placeholder | — (bug) | — | 82 forms, 0 errors (observed) |
| R3 | nearest-first sort, chunked push, `mp_npc_track_max` | 200 (10..400) | 200 / 40 | `cap=40 → pushed=40 farthest_pushed_m=48.5`; `cap=200 → pushed=78 farthest 205.7`; `tracked=78` (observed) |
| R4 | relay-local client else lowest id; SortedSet id pool; Ack before ready; `MP-AUTHORITY-OWNER` | — (bug) | — | reconnect got id 0 back; peer saw `Disconnect` in 2 ms (observed); relay tests 17/17 |
| R5 | `MP-NPCID npc= wuid= eid= body= via=acquire\|first-emit` on the owner | — (log) | — | 78 acquire + 56 first-emit lines (observed) |
| R6 | 0x26/0x27 `[seq:u16][senderMs:u32]`, protocol v7; sender-time stamping; seq accounting; `TCP_NODELAY` | on; `mp_npc_senderclock on/off` | on / off | sender-spacing == arrival spacing solo (observed); reorder/dup/gap paths (synthetic) |
| R7 | `KCD2MP_OnChainDeadRestart`: death marks, dwells, lastWrote reset; `MP-RELOAD-RESET` | — (bug) | — | quick-load with a live puppet: reset line, reassert, no false death, no false diverge (observed) |
| R8 | **not shipped** | — | — | §5 |
| R9 | drop counters both sides, `MP-RELAY-DROPS`; 0x3D release refusal; v7 | — (bug) | — | `0x3D payload=0.26.4` for a 0.26.5 peer; drops line after 60 s (observed) |
| R10 | every `Test-*Synthetic.ps1` + 2 static checks gate; WO-90 mock; payload smoke; DLL always rebuilt | — (build) | — | smoke found §3.2 (observed) |
| R11 | disconnect cleanup via `ExecuteNowAsync` | — (bug) | — | code-verified; kill path is the relay's (observed) |
| R12 | seq advance on timeout; DLL 3.5 s < agent 5 s; by-value captures; unknown-command reply; fault codes 17/18; empty-walk refusal | — (bug) | — | code-verified, DLL rebuilt (402,432 B); pipe used live for the whole stack run without a refusal |
| R13 | agent scans only when it can consume | — (bug) | — | code-verified (solo is always the authority) |
| R14 | Z interpolated on the segment; `MP-NPCZ`, `MP-NPCZ-SUMMARY`; 3-D detectors | — (bug + instrument) | — | silent before the reload, fires after it (observed, §3.4); suite f/g |
| R15 | relay name sanitiser; event tag anchored; `EscapeLua` control chars; case-folded exclusion | — (bug) | — | relay test 17/17; WO-90 assertion inverted (§7) |
| 2.4 | `mp_cull_radius`, default 60, floor 10, ceiling 150 loud | 60 | 60 / 30 | `set=90/60/30/60` lines (observed) |
| 4.4 | relay queue in bytes (512 KB), stale-NPC coalescing under 64 KB pressure | — | — | code-verified; relay tests |
| 6 | silent-failure batch (§2.3–2.5, 2.8 of WO-109) | — | — | suites green; `MP-BATCH-DROP`, `MP-DIALOG-GUARD` new lines |
| + | console ceiling: encoded-size batching (1,900), encoded chunking, oversize drop, atomic check-and-add | — (bug) | — | 0 truncation errors, `verdict=native pushed=78 resolved=78` (observed) |
| + | `mp_debug_hud` `GetCVarValue` nil (WO-50) | — (bug) | — | checklist (observed) |
| + | Phase 0.2: 180 → 124 top-level locals; `Test-WO110LuaLocals.ps1` fails > 170 | — | — | live `loadfile` compile ok (observed) |

`WO110-BUILD npc_read_native=off npc_track_max=200 cull_radius_m=60 npc_senderclock=on -- 0.26.5 defaults (mp_preset_legacy = 0.26.4)`
is logged two lines after `MOD INIT` (observed). Both presets set 19 values
and log each (observed, §4 item 12).

---

## 3. New findings

### 3.1 The console command ceiling (observed)

`#System.LogAlways("…" .. string.len("aaaa…"))` through
`ExecuteString?command=`:

| payload | decoded chars | URL-encoded chars | result |
|---|---|---|---|
| 2,000 × `a` | 2,062 | 2,067 | executes |
| 2,100 × `a` | 2,162 | 2,167 | `unfinished string near '<eof>'` |
| 500 × `:` | 1,067 | 1,566 | executes |
| 1,000 × `:` | 1,567 | 3,067 | fails |
| 400 × `:` in a pcall wrapper | 867 | 1,685 | executes |
| 500 × `:` in a pcall wrapper | 1,067 | 2,085 | fails |
| two-line batch, 1,900 × `a` in line 2 | 2,021 | 2,051 | executes |

The limit is on the **encoded** command (≈2,050–2,160), not on the decoded
text, and not per line. The engine logs a Lua error; the HTTP call returns
200 — nothing agent-side ever saw it.

* `HttpGameTransport.MaxBatchChars` was 4,000 **raw** characters (+32 per
  statement). A full batch was truncated whole and every statement in it
  lost. Batches are usually 1–5 statements, so this bit only under load —
  exactly a dense-town `ApplyNpcState` burst on the joiner. Fixed:
  `LuaCommandBudget.MaxEncodedCommandChars = 1900`, measured per statement,
  the size check and the add under one lock (the first version raced:
  four fire-and-forget chunk statements each saw an empty queue and landed
  in one 6 KB batch, observed). An oversize statement is dropped loudly
  (`MP-BATCH-DROP reason=oversize`).
* The WO-103 push: 40 entries × ~55 raw characters with five `:` and one
  `,` per entry (three encoded characters each) ≈ 2,900 encoded. It would
  have failed exactly like today's first R3 push did. WO-103 §5.1's only
  recorded tracked counts were `path=lua`, and WO-109 R3 already noted the
  cap had no live record. **So the R1 mechanism — the 2 s snapshot as the
  streamed position — was most likely never in effect in the field**; the
  receiver saw the live read. (inconclusive: 0.26.4's push bytes were not
  captured; every other number is measured.) R1's fix stands regardless: it
  removes a path that could only ever be stale or absent.
* Today, after the fix: `MP-NPCSCAN dir=consume verdict=native pushed=78
  resolved=78 age_s=1.3` every 2 s, 0 `unfinished string` errors over the
  rest of the session (observed).

### 3.2 The shipped agent could not write JSON (observed)

First run of `tools/Test-PayloadSmoke.ps1` against the 0.26.4-era tree:
the published agent printed
`[config] Could not write …kcdmp-client.json: Could not load file or assembly 'System.IO.Pipelines, Version=10.0.0.0'`.
`Publish-Release.ps1` flat-merges four publishes; the relay's and master
server's `System.Text.Json` 10 (via `Serilog.Extensions.Hosting` 10)
overwrote the agent's 8.0 copy, and its `System.IO.Pipelines` 10 was present
in the folder but not in `KcdMpClient.deps.json`, so the agent's loader could
not resolve it. Deserialisation paths may not touch the missing type; the
config **write** did. Fixed by referencing `System.Text.Json` 10.0.0 in
`KcdMp.Client.csproj` and `KCDMP_launcher.csproj`; the smoke now passes and
also fails on any assembly-load line in either process's output. The static
deps.json coherence pass is informational (14 benign differences remain:
higher shared DLLs the host accepts, the launcher's long-shipped lower
facades).

### 3.3 Game Over halts every Lua timer (observed)

At t≈460 s into the third launch, `Gameplay ended` appeared in kcd.log and
the screen showed "GAME OVER — You have bled to death". From then on every
`Script.SetTimer` chain froze (emitter, interp, label, npcsync, puppet), no
new timer fired (`Script.SetTimer(20, …)` from the console never ran), the
process idled at 0 CPU, the world produced no lines — while the console API
answered and `ExecuteString` executed. The agent, started after the death,
correctly reported `emitter produced no frames` and fell back to HTTP. The
probable cause is the R2 checklist's `mp_spawn_armor`, which spawns
factionless armed NPCs 3 m from Henry (both earlier launches ran it too and
"exited on their own" ~40 minutes later; `Gameplay ended` was not searched
for in those logs). **Lesson for every future live session:** if
`[KCD2-MP-DATA]` stops and the console still answers, look at the screen;
and keep `mp_spawn_armor` out of a checklist that runs unattended.

### 3.4 A save load changes the engine's response to puppet writes (observed, n = 1)

Solo driver (WO-108 pattern): `ttkc_barbora` streamed at 100 ms in a 1.5 m
circle with the stream's Z **0.25 m below** the ground, this machine as the
joiner, puppet paused (`exec=ok`).

| phase | writes | `MP-NPCZ` | `MP-AUTHORITY-VIOLATION` | `MP-NPCFIGHT` |
|---|---|---|---|---|
| before the load (~4 min) | ~2,400 | none: read-back Z == written Z to the mm, 250 samples checked | none | none |
| after `wh_sys_TestLoadGame`, driver restarted, pause re-asserted | ~1,200 | `delta=+0.28…+0.31`, `float_n=95 sink_n=0` per 5 s window: the body is lifted 28–31 cm out of the ground within 50 ms of every write | `kind=contention dist_m=0.31–0.49 cos=0.86–0.99 anchor_m=1.50`, n=13 in 30 s | `n=79 mean_m=0.36 max_m=0.68` |

Ratio 0.2–0.33 of the anchor distance per tick is WO-107 §4's relax decay
(≈0.32) — above the relax tag's `RATIO_MAX` 0.12, so it is logged as
contention, not relax. Before the load the same geometry produced nothing.
Interpretation (inconclusive): a loaded body carries a physics/ground state
the pre-load body did not (a ground snap + a settle), or the re-asserted
suspension does not cover something the load re-created. Either way this is
WO-109 failure mode 3 in the log, produced by a reload, with the lever
`exec=ok`. It is also the shape of the WO-104 148-contention session. The
relax tag's band was left as is (a heuristic change needs a live A/B).

### 3.5 The Z instrument is correctly silent when nothing moves the body

§3.4's first row is itself a result: 250 writes a quarter metre into the
ground and the body stayed exactly there. On this build, before a reload,
`SetWorldPos` Z is not corrected by the engine for a suspended NPC. Any
sinking seen on a freshly loaded joiner is therefore either the stream's Z
(owner side) or the post-load state of §3.4.

### 3.6 Owner cadence with the live read (observed)

Synthetic joiner reading the `senderMs` stamp of every 0x27 for 45 s, town,
78 tracked, 55 distinct NPCs, 7,004 packets:

| NPC (walking) | n | mean ms | min | max | seq gaps |
|---|---|---|---|---|---|
| ttkc_man_6 | 426 | 105 | 46 | 172 | 0 |
| ttkc_scribe | 425 | 106 | 46 | 172 | 0 |
| ttkc_man_24 | 312 | 106 | 46 | 172 | 0 |
| ttkc_woodworker | 296 | 133 | 46 | 1,593 | 0 |
| ttkc_woman_14 (mostly idle) | 66 | 642 | 375 | 1,172 | 0 |

100–200 ms for walkers (the R1 target), the long means are NPCs alternating
walk and stand (heartbeat spacing counted when the position had drifted).
`min=46` is two emits inside one 100 ms window (the emit gate is per tick,
the tick is frame-bound).

### 3.7 Owner tracking numbers (observed)

`MP-NPCSCAN dir=native anchors=1 radius_m=300 total_walked=36,979 matched=78
pushed=78 cap=200 farthest_pushed_m=205–230 chunks=4 dur_ms=13–22`;
`MP-NPCTRACK tracked=78 culled=31–32` at 60 m. Under the legacy cap:
`pushed=40 farthest_pushed_m=48.5` — the 40 nearest.

---

## 4. Phase 8 — solo smoke against the shipped pak

Rebuilt pak 870,483 bytes installed by `Build-And-Install-Mod.ps1`, cold
relaunch, `quicksave023` (the WO-108 throwaway save). Stack for items 3/4/7:
the rebuilt relay (`--port 7778`), `KCDMP_LauncherInjector` into the running
game, the rebuilt agent — the launcher's pieces by hand.

| # | item | result |
|---|---|---|
| 1 | fresh load, nothing typed | `WO110-BUILD npc_read_native=off npc_track_max=200 cull_radius_m=60 npc_senderclock=on` two lines after `MOD INIT` (observed) |
| 2 | every argument command bare + with an argument | 41 commands, 82 forms, 0 Lua errors; e.g. `mp_entity_id Dude` → `Dude id=userdata: 0000000000007777`, `mp_npc_yield 0.3 10 1.0`, `mp_together_params 60 90 10`, `mp_npc_track_max 150`, `mp_cull_radius 90`, `mp_npc_senderclock on` all logged their set lines; bare numeric setters report (observed). Full capture in the session scratchpad |
| 3 | owner cadence on a walking NPC | 105–113 ms mean, 46–172 ms range, 0 seq gaps, from sender stamps (observed, §3.6) |
| 4 | town: `tracked=` > 40, nearest first | `tracked=78`; `cap=40 → pushed=40 farthest 48.5 m`, `cap=200 → 78 / 205.7 m` (observed) |
| 5 | `mp_cull_radius 90`, then `60` | `WO1025-CULL-RADIUS set=90.0 was=60.0`, `set=60.0 was=90.0` (observed) |
| 6 | `MP-NPCZ` on a puppet | fires only after a reload (§3.4); silent with delta = 0 before it (observed); the line and rollup shapes (synthetic + observed) |
| 7 | `MP-AUTHORITY-OWNER` on connect | agent console + kcd.log `self_id=0 authority=self reason=relay-combatrole`; relay `id=0 … reason=relay-local trigger=combat-role` on every connect/disconnect (observed) |
| 8 | save-load with a live puppet | `MP-RELOAD-RESET chain=npcsync death_seen_cleared=1 dwells_forgotten=0 puppets_reset=1`, chain restart, `MP-PAUSE-GAP` resume (the driver chain died with the load), driver restarted → `event=reassert why=chain-dead-restart exec=ok`; **no** `NPC-DEATH … announcing`, **no** `kind=diverge` (observed) — and §3.4 |
| 9 | relay refuses a mismatched release | peer declaring 0.26.5 against the (then 0.26.4) relay → `0x3D payload=0.26.4`; relay `Rejecting 'mixedbuild' … release 0.26.5 does not match this relay's 0.26.4`; same release → Ack (observed) |
| 10 | `MP-RELAY-DROPS` on malformed frames | 36 s after a 5-byte 0x01 and a nameLen-mismatched 0x26: `MP-RELAY-DROPS side=relay interval_s=60 dropped=3 total=3 by=0x00:release-mismatch=1,0x01:wrong-length=1,0x26:namelen-mismatch=1` (observed) |
| 11 | engine `paused=` | n/a — R8 not shipped (§5) |
| 12 | presets round-trip | `mp_preset_legacy`: 19 `MP-PRESET name=legacy set=` rows (read native on, cap 40, radius 30, sender clock off, lever on); `mp_preset_clean`: 19 rows back to 0.26.5; `authority_model=untouched` both (observed) |
| R11 | kill the agent mid-session | synthetic peer received `DISCONNECT id=0` 2 ms after `Stop-Process`; relay re-elected; the restarted agent got id 0 back (observed) |

Synthetic: `Test-WO110Synthetic.ps1` 85/85 (scenarios a–m, header of the
`.lua`); every other suite green at every commit (WO-108 94/94, WO-102
196/196, WO-90 70/70 — was 69/70); relay tests 17/17 (+4); agent unit tests
174/174 (+4); both static checks green.

---

## 5. R8 — not shipped, and why

The prompt allowed a bounded effort. Tried: grep of every RE note
(`WO-107-ai-suppression.md`, `WO-107-progress.md`, `NATIVE-PLUGIN-findings.md`,
`WO-21/22`) and of every DLL source for `IntelligentObject`, a brain
pointer, or an entity → AI-object hop. WO-107 §3.2 records the object's own
layout (`+0x128` state, `+0x129` mask, RVA of `Suspend`/`Resume`) and
nothing about how to reach the object from an entity or a name; the DLL
walks entities (`npc_scan.cpp`) and actors (`local_state.cpp`) and never an
AI object. Finding the container `wh_ai_PauseNPC` resolves a name through
is a Ghidra session against `WHGame.dll`, flagged for an Opus/Ghidra WO.
Until then the engine's `Node status inconsistency. Can't update suspended
node!` line is the only engine-side signal, and every `pause_*` field is
labelled bookkeeping (Phase 6).

---

## 6. Not done, inconclusive, stated plainly

* **Two-player: everything.** Every prediction in §1 is a prediction.
* **R6's before/after measurement** ("the joiner's cadence min/max spread")
  was not run as an A/B: the only joiner available solo is a synthetic peer
  with no Lua renderer. What was measured is the owner's sender spacing
  (§3.6); the runbook asks the joiner to compare `sender-spacing` against
  arrival cadence on the same line.
* **4.4's pressure path** (coalescing at 64 KB) never engaged solo
  (`MP-RELAY-DROPS` shows no `0x27:pressure-coalesced`). Code-verified and
  relay-tested only.
* **R11's kill case** relies on the relay's Disconnect (observed) and Lua's
  silence path; the killed agent's own game keeps its ghost bodies until an
  agent re-arms — unchanged from 0.26.4.
* **§3.4's mechanism.** One NPC, one load. Whether the post-load fight ends
  on its own, whether it is the load or the puppet re-creation, and whether
  a wider relax band would tag it: not established.
* **The 0.26.4 native push bytes** were not captured; §3.1's "never landed"
  is arithmetic on the codec plus WO-103/WO-109's absence of any `path=native`
  live record.
* **R13** could not be observed as a skip solo (solo is always the
  authority).
* **The launcher** is not exercised by the payload smoke (GUI); its
  `System.Text.Json` pin is code-verified only.

---

## 7. Corrections this WO makes to the record

* WO-109 R1: the mechanism is real in the code but was most likely never
  live (§3.1). P1b there ("stepping") was probably unobservable on 0.26.4.
* WO-103 §5.1 / WO-102.5 §6.2: the *names-only* push (~800 encoded) landed;
  the WO-103 position push very likely did not. The "read-native known-answer
  check" compared a push that was not there.
* WO-106 §3.6's post-deploy checklist: run for the first time here; it
  caught `mp_debug_hud`'s `GetCVarValue` error on top of R2.
* WO-108 §7 item 5's `mp_puppet_rate` A/B advice: the command did not work
  until now (R2).
* `Test-WO90Synthetic.lua` (e) asserted a case-**sensitive** name exclusion
  "matching the engine"; `System.GetEntityByName` is case-insensitive
  (WO-105 entry 10), so the assertion is inverted (R15).
* `docs/WO-108-peer-test-runbook.md`'s "different wuid = wrong body" rule
  holds only for eid < 0x70000 (WO-109 §1.4); the 0.26.5 runbook says so.
* Every `paused_npcs=`/`auth_paused_now=` field is renamed to say
  `pause_issued` (Phase 6): it was always the Lua table.

## 8. Open, carried forward

* Two-player: everything. This build's purpose.
* R8 (engine suspend read) — Ghidra session.
* §3.4: the post-load write fight; the relax tag's band.
* The joiner's Lua ingress ceiling at 60 m under a real crowd (failure mode 2).
* Locomotion/activity animation on the wire (next WO after the peer test).
* `SchedulerProxy` (WO-107 §9); the crime/perception divergence.
