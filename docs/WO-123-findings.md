# WO-123: send the world, pause the host

Session 2026-09-25. Solo, one machine, Modding Tools build 1.5.5, a local
relay, the game's agent as the **host** and a synthetic joiner
(`tools/wo118/synthpeer --join`). Progress, method and side effects:
`docs/WO-123-progress.md`. Settled decisions: `docs/DECISIONS-coop-design.md`.

Evidence marks: (observed) / (code-verified) / (synthetic) / (inconclusive).
Paths are written as `<saves>`, `<install>`, `<data>` (the agent's own data
folder). **Dormant:** everything here sits behind `mp_shared_world` (default
off). No installer, no VERSION bump. Protocol v8 → **v9**.

---

## 0. Phase 0: the C# splicer — **GO**

* WO-115's pair (copies of playline1 `quicksave027` = host world, playline2
  `save021` = joiner Henry), spliced with `KcdMpClient --save-tool splice`,
  `check: PASS`. (observed)
* The file that was loaded live (`playline1/mpworld123.whs`, placed before
  launch) is **byte-identical** to a fresh C# splice of the same inputs
  (re-spliced this session and compared). (observed)
* Loaded in-process after the joiner's own `save021` and the host's
  `quicksave027` in the same session: each reached `Gameplay started`; the
  engine's LoadGame phase took 0.42 / 0.57 / 0.58 s. (observed)

| category | joiner's save021 live | spliced live | verdict |
|---|---|---|---|
| inventory | 35 entries (class × amount) | identical multiset | exact |
| money | 15.1 | 15.1 | exact |
| skills (30) | level / progress | identical | exact |
| stats (4) | progress | identical; the printed level is drunkenness-modified (as WO-115 §3.4) | exact (progress) |
| vitals | hp 31.02, stamina 89.683, exhaust 89.935 | identical; hunger/alcoholism differ by the seconds between snapshots | exact |
| position | the joiner's own spot | the **host** Henry's spot | host (correct) |
| world clock | joiner's world, 4.7 days ahead | 579425 vs the host save's 579446 | host (correct) |
| NPCs ≤ 40 m | — | 34 of the host's 35 names (one on the edge) | host (correct) |

* `kcd.log`: normalised errors/warnings in the spliced load window minus the
  union of both original windows = one `zranenyLovci … invalid port` error
  (written while the **previous** world tears down; WO-115 §3.3 traced the
  same line to teardown) and three AI behaviour-tree scope warnings. Nothing
  about souls, items, perks, buffs, Dude or inventory. (observed)
* **Verdict: GO for the C# splicer.** The zlib bytes differ from Python's
  (WO-122 §5.2); the game does not care. The next WO may splice in the agent.

---

## 1. Answer first

| item | result | evidence |
|---|---|---|
| clock | `SetWorldTimeRatio(0)`, previous ratio read first (15) and restored on every resume | observed ×14 joins |
| NPCs | bulk `wh_ai_PauseNPC` on the list the join made; only that list resumed; 3–18 bodies in 7–10 ms; late arrivals added by a 2 s rescan | observed |
| animals | **not frozen by the first build** (7/7 hares moved up to 39 m in 60 s); now paused (any body with a soul) → 0 m over 55 s | observed |
| input hold | `no_input` action map (the fader's own: priority 15, exclusive, no actions) → the engine lists **only** `no_input` + `game_interrupt_start` active; released → the list is back exactly | observed (engine state; no key was pressed) |
| host message | "<partner> is joining… [bar] N%", then "… is loading the world…", hint `mp_join_cancel` | observed (window capture) |
| deferral | busy while loading (observed); combat / dialogue / cutscene / dead / cannot-save (code-verified + synthetic) | mixed |
| every resume path | ready, joiner gone, joiner abort, hash mismatch, ack timeout, safety timeout, `mp_join_cancel`, `mp_shared_world off`, host reload | observed (table §3) |
| transfer | real early save 1.43 MB: 0.06–0.07 s on loopback incl. acks; request → offer 1.5–1.7 s (the save); synthetic 13.6 MB: 0.10 s through the relay | observed (loopback) |
| verify | SHA-256 vs offer, then `WhsSave.Verify` and the save's md5 vs the offer's; a flipped byte and random bytes both rejected, nothing staged | observed + synthetic |
| 60 s pause | clock unchanged, every tracked body 0.00 m | observed |
| LAN | not run (no second machine set up in this session) | — |

Two real bugs were found live and fixed (§4). Gates: 20 Lua synthetic suites
(WO-123: 127 checks), both static Lua checks, 245 client tests, 42 relay tests,
59 Farkle tests: green.

---

## 2. Phase 1: the pause

### 2.1 Clock and bodies (observed)

* Every `MP-JOIN pause` line: `ratio_was=15 ratio_now=0`; every `MP-JOIN
  resume`: `ratio_back=15 (was 15)` and the clock equal at both ends
  (e.g. `clock=754476->754476` after 61.8 s).
* Pause cost: 7–10 ms of Lua for 3–18 bodies (the WO-108 bulk result holds).
* The resume wakes exactly the list; a name the WO-102 lever took over
  mid-join is left to the lever (synthetic; no lever conflict arose live).
* Drift over a paused minute (drift123: every actor within 80 m, two samples
  55 s apart):

| run | clock | NPCs | animals |
|---|---|---|---|
| unpaused baseline, 20 s | +352 | 1 moved 0.25 m | 3 of 6 hares, up to 15.6 m |
| first build (NPC/NPC_Female/Horse only), 55 s paused | +0 | 1 of 2 moved **0.21 m** | **7 of 7 hares, up to 38.8 m** |
| hares paused by hand, 20 s unpaused clock | — | — | 0 of 7 moved |
| final (any body with a soul), 55 s paused | +0 | 0.00 m | 0 of 5, 0.00 m |

* Paused by the final scan on this spot: cattle and hares alongside the NPCs
  (`SpawnedAnimal_CattleBull_…`, `SpawnedAnimal_Hare_…`). Horses were in the
  classes from the start; none was within 120 m. (observed)
* The 0.21 m NPC step: one NPC finishing a step as the pause landed.
  (inconclusive)
* Foliage and sky: two captures 55 s apart differ as much on the ground as in
  the sky (camera sway, wind, TAA). Render-only movement cannot be told from
  state change this way. (inconclusive)
* Random events, weather changes, quest timers: none triggered in the test
  windows. (inconclusive)

### 2.2 Holding the host's input

`ActionMapManager.EnableActionFilter` (the `no_move`/`no_attack` filters) is
**not registered** in either build (the retail and Modding Tools DLL strings
carry only `EnableActionMap`/`IsFilterEnabled`). Probed with the engine's own
`i_listActionMaps 1` overlay and a capture of the game window only (no key
input, no focus change):

| method | engine's active maps while held | verdict |
|---|---|---|
| `noinput`: `EnableActionMap("no_input", true)` | `no_input` (15, E) and `game_interrupt_start` only — player, movement, camera, combat, menu, debug all inactive | **shipped default** (observed) |
| `actionmap`: `player` + `movement` off | `player` gone, **`combat` still active** (attack, block, knock-out) | rejected (observed) |
| `noninteractive` | not probed | — |
| release (`no_input` false) | the list is identical to the baseline | observed |

* `mp_join_hold <noinput|actionmap|noninteractive|none>`; the release always
  undoes the method the hold used, even if the setting changed mid-pause.
* The pause menu's map is also inactive under `no_input`, so the host cannot
  open the menu to save, load or quit during a join. (observed as engine
  state; not tried with a key)
* Whether the console key (~) still opens: not tried (no input sent).
  CryEngine's console sits before the action maps. (inconclusive, runbook)

### 2.3 Deferral

* A join is asked of the mod (`KCD2MP_JoinTry`) every 2 s until it pauses.
  The mod refuses with the reason: `loading`, `dead`, `cutscene`, `dialogue`,
  `combat` (`soul:IsInCombatDanger`). The agent refuses on its own for a load
  in progress, the 10 s after `Gameplay started`, and an outstanding clock
  convergence (`clock-sync`, §4.1). The joiner hears JoinStatus `deferred
  <reason>` ("Your host is busy, you'll join in a moment."). (code-verified)
* Live: a join asked 3 s into a load was deferred `loading` twice and paused
  16 s later, after the world was up; the full transfer and Ready followed.
  (observed)
* The live reads behind the combat and dialogue checks return real booleans
  (`IsInCombatDanger=false`, `IsInDialog=false`), not nil. (observed)
* Mid-combat, live: **not run**. A fight needs UI input or native skirmish
  code (WO-119/121); neither was used with the machine possibly in use.
  The branch is synthetic-tested. (inconclusive, runbook)
* A host busy for 600 s gives the join up (the joiner is told). (code-verified)

---

## 3. Every way out of the pause (observed unless marked)

| trigger | reason logged | paused for | joiner told |
|---|---|---|---|
| joiner sends Ready | `ready` | 61.7 s, 61.8 s (60 s load) | resumed/ready |
| joiner disconnects mid-transfer | `joiner-gone` | 1.6 s | — (gone) |
| joiner dropped by the relay's 30 s idle timeout | `joiner-gone` | 31.7 s | — |
| joiner aborts: corrupted chunk → hash mismatch | `failed` | 1.7 s | resumed/failed |
| joiner cancels | `cancel` | 1.6 s | resumed/cancel |
| joiner stops reading (acks stop) | `timeout` (ack timeout 20 s) | 21.6 s | abort timeout |
| no Ready (safety timeout, set to 45 s) | `timeout` | 45.1 s | abort timeout |
| host types `mp_join_cancel` | `cancel` (mod resumes at once, then the agent) | 13.0 s | abort host-cancel |
| host sets `mp_shared_world off` | `shared-world-off` | 11.1 s | abort host-cancel |
| host starts a save load | `host-reload` (at the load's first line) | 15.5 s | abort host-reload |
| relay connection lost | `relay-lost` | — | (code-verified) |
| agent dead: mod's own timer (timeout + 15 s) / draw-loop backstop after a load | `mod-safety-timeout` | — | (synthetic) |
| a pause orphaned by a load | `host-reload` via `KCD2MP_JoinResumeStale` 3 s and 12 s after `Gameplay started` | — | (synthetic; the function was run live) |

* Every resume is idempotent: the second call logs `not paused for this join
  (already resumed)`. (observed)
* The default safety timeout is 180 s (`mp_join_timeout 30..1800`). The 60 s
  joiner load ran under it. (observed)
* The shipped fallback when nothing else fires: the agent's deadline, the
  mod's `Script.SetTimer`, and — because a load kills every timer chain —
  the draw loop's own timeout check.

---

## 4. Found live, fixed

### 4.1 The clock moved under a paused host (observed, fixed)

* A load, then a join: the host paused at the loaded clock (752222) and its
  save was sent at that time. The agent's WO-40/88 reload convergence then
  saw the clock "go backward" and moved it forward to the session clock
  (766055, **3.8 game hours**) while the world was held. After Ready the host
  would have run 3.8 h ahead of the save the joiner loads.
* Fix: a join defers while a convergence is outstanding (`clock-sync`) and
  for 10 s after `Gameplay started`; the reload handler does not converge
  while a join exists (the join's save is the world). Re-run: `a join holds
  the world -- not converging`, clock `752337->752337`. (observed)

### 4.2 A pause taken during a load (observed, fixed)

* Between `EntityModuleOnPostLoadGame` and `Gameplay started` the mod's Lua
  runs, the player exists and `Game.IsLoadingEngineSaveGame()` is false, so
  the mod accepted a pause there. The engine refused the join's save for the
  whole pause (10 enqueues, no file); the 45 s safety timeout resumed.
* **`Gameplay started` was printed 0.2 s after that resume** — the pause
  appears to hold the end of a load. Which part (the `no_input` map, ratio 0,
  paused bodies) was not isolated. (inconclusive)
* Fix: the agent tails the engine's `[CryAction] LoadGame: '…'` line. Joins
  defer from it to `Gameplay started` (+10 s); a load that starts under a
  pause ends the join at once (`host-reload`), not at `Gameplay started`.
  Re-run: resumed at the load's first line; `Gameplay started` followed.
  (observed)

### 4.3 Test tools (fixed)

* The synthetic joiner sent nothing while waiting for its "load"; the relay's
  30 s idle timeout dropped it (the host resumed correctly, `joiner-gone`).
  It now sends the agent's 2 s stale-position heartbeat, like a real joiner
  at the menu.
* An earlier attempt in this WO started a second agent under the same name:
  the relay gave them ids 0 and 1 and they fought over the WO-102 toggles
  every 2.5 s. `join123.py up` now refuses while an agent runs.

---

## 5. Phase 2: the transfer

### 5.1 Wire (protocol v9, `ProtocolWo123.cs`)

| up/down | message | body after `[target][joinId:4]` | sent by |
|---|---|---|---|
| 0x48/0x49 | JoinRequest | `[flags]` | joiner |
| 0x4A/0x4B | WorldOffer | size, chunk size, chunk count, SHA-256, WorldSaved seq, md5 | host |
| 0x4C/0x4D | WorldChunk | `[index:4][≤32 KB]` | host |
| 0x4E/0x4F | WorldAck | `[next:4]` cumulative | joiner |
| 0x50/0x51 | WorldDone | SHA-256 prefix (hash + Verify passed) | joiner |
| 0x52/0x53 | JoinAbort | `[reason]` | either |
| 0x54/0x55 | JoinerReady | `[WorldSaved seq]` | joiner |
| 0x56/0x57 | JoinStatus | `[state][reason][arg:2]` | host |

* Pairing is by `joinId` and the WorldSaved `seq`/md5, never by time (WO-122
  carry-forward 6). (code-verified)
* The relay routes each message to one peer; joiner messages go only to the
  damage authority, host messages are accepted only from it; exact lengths
  come from the one table `Protocol.JoinWire`. Wrong side or length: dropped
  and counted. (synthetic: relay tests; observed: `[join]` relay lines)
* Chunks are 32 KB (a frame's length is a u16, so 64 KB is out of reach);
  at most 256 KB unacknowledged; the joiner acks every 4 chunks and on the
  last. A stalled joiner held the host at 262,144 B acked, and the relay test
  shows a full window into a non-reading joiner does not overflow its 512 KB
  queue. (observed + synthetic)
* v9 carries WO-122's WorldSaved (0x46/0x47); v8 and v9 refuse each other at
  Handshake. Next free type byte: **0x58**.

### 5.2 Checks

* Host, before the offer: `WhsSave.Verify` on the file just written, and its
  md5 must equal the one WorldSaved announced. (observed ×13; the 14th join never got its save, §4.2)
* Joiner: SHA-256 against the offer, then `WhsSave.Verify`, then the save's
  own md5 against the offer's. Any failure deletes the staging file and sends
  JoinAbort. Live: a flipped byte in chunk 20 → `hash-mismatch`, 0 files
  left; 1.4 MB and 13.6 MB of random bytes → SHA-256 matched, `Verify: no
  0XBP footer` → `verify-failed`, 0 files left. (observed)
* Staging: `<data>/join-staging` (`%LOCALAPPDATA%\KCDMP`, `KCDMP_DATA_DIR`
  overrides), never the saves folder; swept at agent start, at a new request
  and at a new offer. (synthetic)

### 5.3 Speed (loopback)

| file | through | time | rate |
|---|---|---|---|
| real early save, 1.43 MB, 44 chunks | agent host → relay → synthetic joiner | 0.06–0.07 s (host: offer to Done) | 20–23 MB/s |
| random 1.44 MB | synthetic host → relay → synthetic joiner | 0.03 s | 44 MB/s |
| random 13.6 MB, 416 chunks | same | 0.10 s | 129 MB/s |

* Request → offer: 1.50–1.66 s, almost all of it the engine's save (WorldSaved
  verified 1.50–1.56 s after the request). (observed)
* Off loopback the window bounds the rate at 256 KB per round trip: 13.6 MB is
  ~5 s at 100 ms RTT, ~0.5 s at 10 ms. (code-derived; LAN/WAN not measured)

### 5.4 Progress

* Host: the bar on screen (percent acked), `MP-JOIN host:` lines with bytes,
  time and MB/s. (observed)
* Joiner agent: `MP-JOIN joiner: receiving N/M B (P%) eta_s=…` every 10%, and
  GET `/join-status` (same listener as `/version-status`) for the launcher's
  "Receiving the world… 62%". The endpoint answers live (`idle` on the host);
  the joiner-side agent path is synthetic only (the second machine role was
  the synthetic peer). (observed endpoint; synthetic states)

---

## 6. Phase 3: Ready

* JoinerReady carries the WorldSaved seq the joiner loaded; the host logs a
  mismatch but resumes either way. Ready before the transfer finished is
  ignored. (code-verified)
* Live with the synthetic joiner sending Ready 5 s and 60 s after the file
  verified: the host resumed within the same second (`reason=ready`), clock
  unchanged. (observed)
* The next WO sends it from the mod: `KCD2MP_EmitEvent("join_ready")` →
  agent → 0x54. (code-verified)

---

## 7. Carry-forwards

1. **LAN transfer not measured.** Loopback only; the window math (§5.3) is
   the expectation.
2. **Mid-combat deferral not run live** (§2.3); **console key under
   `no_input` not tried** (§2.2). Runbook, progress §5.
3. **A load under a pause delays `Gameplay started`** until the pause ends
   (§4.2). Joins can no longer be paused during a load, and a load ends a
   pause at once, but the cause is not isolated.
4. **The joiner agent's side** (offer → staging → Done, `/join-status`
   states, launcher banner) ran only as the synthetic joiner and unit tests.
   The next WO's joiner is the first live one.
5. **Each join writes a new `autosaveNNN`** in the host's playline (15 files this
   session, joins and WO-122's schedule together). They rotate with the host's own autosaves (100 slots).
6. **Reload convergence is skipped while any join exists, deferred ones
   included.** Under `mp_shared_world` the host is the clock, so a host reload
   is the world's time; a later design may drop convergence for the host
   entirely.
7. **Busy reason for an unanswered mod is `no-mod`** (seen once during a load
   before the load-start tail existed). With the load tail it no longer
   appears for loads.
