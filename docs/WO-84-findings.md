# WO-84 — the faction-less ghost, the animation storm, and the odd chain leak

Build under investigation: **0.20.6**, one live two-player session,
2026-09-11. Three log bundles were read: the joiner's `kcd.log`
(150,458 lines), the host's `kcd.log` (147,055 lines) and an earlier
same-day host session kept in `logbackups` (253,509 lines), plus both
agent logs, both native-plugin logs and the relay log.

Evidence discipline: **observed** (read in a log), **code-verified** (read in
the source), **read-but-unrendered**, **inconclusive**. Nothing is rounded up.

---

## 0. Verdict in one paragraph

The three symptoms are **not one cause — they are two causes and one
coincidence**. The animation storm and the chain leak are both consequences of
the same underlying habit in this file (a per-tick call that assumes the game
is advancing between ticks, and a chain that reschedules before it decides to
stop), amplified by the same third-party event (a local menu, which suspends
`Script.SetTimer` while the agent's pump and its inbound `ExecuteString`
traffic keep running). The faction errors are unrelated to either, and
unrelated to the live ghost: they belong to a ghost body that a previous
session serialised into the savegame. The camera-teleport warning is a common
cause with the leak, not a link between them.

---

## 1. The faction errors — root cause

### 1.1 They are not the live ghost. (observed)

| Log | `does not have a faction` | Entity named | That machine's live ghost |
|---|---|---|---|
| joiner | 266 | `kcd2mp_0` ×266 | `kcd2mp_0` |
| host | 265 | `kcd2mp_0` ×265 | **`kcd2mp_1`** |
| earlier host session | 387 | `kcd2mp_0` ×371, `kcd2mp_horse_1` ×16 | `kcd2mp_1` |

**The joiner row is ambiguous and the host row is not.** On the joiner, the
live ghost happens to be named `kcd2mp_0` too — it is mentioned 10,283 times in
that log, registered with the situation controller, animated, drawing weapons —
so on that machine alone the name cannot tell the two apart. On the host it
can: that machine spawned exactly one ghost, named `kcd2mp_1`, and every one of
its 265 errors names `kcd2mp_0`, a name it never created in that session.
Across all three logs, `kcd2mp_1 does not have a faction` occurs **zero**
times. What settles the joiner is not the name but §1.2's burst structure —
its first burst is 4,023 lines before it spawned anything.

### 1.2 They fire during entity reconciliation, not during play. (observed)

The joiner's 266 errors are not spread through the session. They are eleven
bursts:

| Lines | Count |
|---|---|
| 10062–10113, 25645–25696, 43387–43438, 55250–55301, 113809–113860 | 52 each |
| 12913, 28485, 46228, 58091, 116649 | 1 each |
| 93925 | 1 |

Each 52-line burst sits inside the entity module's savegame reconciliation
pass; each trailing single lands immediately after
`Sending concept notification 'EntityModuleOnPostLoadGame'`. Five savegame
loads, five pairs. The eleventh, at line 93925, follows
`CutscenePlayer::ReleaseScene ... 'crime_punishmentTimeAdvance'` and is
likewise followed by a run of `... deleted 0 reconciled changes` lines — a
reconcile pass triggered by a time advance rather than a load. So the trigger
is **an entity reconcile pass**, of which a save load is the common kind.

### 1.3 The record comes out of the save blob. (observed)

`Module EntityModule processed savegame data 2705 B of 2705 B` appears ten
times across the two current logs, byte-identical every time and identical
between the two machines (a second record, `166 B of 166 B`, likewise ×10). A
payload that does not vary across loads or across machines is a fixed blob on
disk, not live world state. The name `kcd2mp_0` exists nowhere in the shipped
mod data — it is only ever built at runtime at `kdcmp.lua:3186` — so the only
way it can appear in a save is by having been serialised there.

**Root cause, stated plainly: a ghost body created by a previous session was
written into the player's savegame, and every subsequent load restores it
soul-less and therefore faction-less.** This is universal, not soul-specific:
nothing in the path branches on soul, class or `className`.

### 1.4 WO-58 already knew this. The gap was that nothing ran the fix.

`KCD2MP_SweepStrayGhosts` (`kdcmp.lua:5942` before this WO) was written in
WO-58 and its comment describes this exact scenario, correctly, down to the
per-connection id reuse that makes `KCD2MP_SpawnGhost`'s same-name check miss
it. It was only reachable from `KCD2MP_RemoveAllGhosts` — that is, from
`mp_remove_all` or `KCD2MP_Stop`. **Neither ran in any of the three sessions**
(observed: zero `SweepStrayGhosts` lines in any log). The sweeper was correct
and unreachable during play.

### 1.5 Correction to a reading that looked obvious and is wrong

`kcd2mp_0 deleted 0 reconciled changes` does **not** say the entity was
deleted. It says *N* reconciled change records were discarded for that entity;
`ttkc_man_21` appears in the same block three times and goes on being synced
afterwards. So whether the restored body then stands in the world for the rest
of the session is **inconclusive** from these logs: there is no removal line
for it and no further faction errors after each burst, which fits both "the
engine dropped it" and "it stands there silently". The sweep now shipped
reports what it finds, so the next session answers this either way.

### 1.6 Does the mod's own faction assignment work? Measured, not assumed.

The spawn path ran both halves inside **one unlogged `pcall`**, so no field log
in this project's history says whether either did anything:

```lua
pcall(function()
    entity.Properties.esFaction = "Civilians"
    AI.ChangeParameter(entity.id, AIPARAM_FACTION, "Civilians")
end)
```

What the logs do reveal is a decisive control case nobody had looked at. The
**horse** spawn path runs the same `AI.ChangeParameter` with the same string,
in its own `pcall`. In the earlier host session, at line 214983:

```
[KCD2-MP] Riding START id=1
[Error] NPC kcd2mp_horse_1 does not have a faction.      x16
[Warning] Validator: AI: Unknown faction 'Civilians' being set...   x2
[KCD2-MP] HorseSpawn OK id=1
```

21,738 lines from the nearest post-load notification. Two things follow, both
**observed**:

1. **The same error text is emitted for a brand-new, live, mod-spawned
   entity.** The message means "an NPC with no faction was queried", nothing
   more. It is not a savegame signature, and §1.1–1.3 rest on the burst
   structure and the name mismatch, not on the message's wording.
2. **Where the call lands, the engine rejects the value.** `"Civilians"` is not
   a faction id in this build's FactionTree. This is the first direct
   measurement of that call in the project's history.

`Unknown faction 'Civilians'` appears **twice in the whole corpus**, both from
the horse path, and **zero times** across eight ghost spawns. Two readings fit
and the logs cannot separate them: either the `Properties` write throws and the
shared `pcall` aborted before `AI.ChangeParameter` ever ran, or the ghost has no
AI object for the call to act on (`KCD2MP_SpawnGhost` deliberately passes no
`SchedulerProxyName`; the horse path's own comment records that registering one
fights our per-tick `SetWorldPos`). **Inconclusive** — and now instrumented, so
the next session decides it (§4.4).

Not attempted here, deliberately: guessing a replacement faction name. WO-34
live-observed that the soul's own `FactionNode` wins regardless, and WO-68
shipped civic isolation through `C_ScriptContextManager` script contexts
instead, which removed the reason this override existed. A real faction attach
is native — `C_FactionBase::SetParent`, exported from `RPGModule` and exercised
in `NATIVE-PLUGIN-findings.md` — and is scoped in §5, not shipped in this WO.

---

## 2. The animation storm — root cause

### 2.1 It is one entity, and it is our own clips. (observed)

| Log | Total overflows | On the mod's ghost | Share |
|---|---|---|---|
| joiner | 9,192 | 9,037 | 98.3% |
| host | 5,756 | 5,711 | 99.2% |
| earlier host session | 2,380 | 1,998 | 83.9% |

Every other entity in the world combined accounts for 155 on the joiner. The
clips are the ones this mod pushes: on the joiner, 7,240 of 9,037 are
`combat_rg_sz1_idle_lngsw_player`; on the host, 4,634 are `relaxed_idle_both`;
the remainder on both are the three `*_turn_strafe` locomotion blendspaces.

### 2.2 The mechanism. (code-verified)

`KCD2MP_UpdateAnimation` called `StartAnimation` **unconditionally on every
interp tick** — the line carried the comment "Call StartAnimation every tick to
override Mannequin's idle". The interp chain runs on a 20 ms timer, so that is
**50 calls/second per on-foot ghost**, and roughly 100/s for a mounted one
(rider clip plus horse gait, both per-tick too). The NPC puppet path does the
identical job at **1 call/second** in steady state: WO-40 Phase 5 gated it
behind `p.animTag ~= tag or now - p.animRefreshAt > 1.0`, with the comment
"Restarting a loop 20x/sec is pure animation-system churn". A 50:1 asymmetry
between two renderers doing the same work.

This was not a considered design. `git log -S` on that comment returns one
commit: **57f13f5, 2026-02-26, "Animation fix ??"**. It deleted the ghost
path's original guard —

```
-    if istate.animTag == wantTag then return end
-    pcall(function() alreadyPlaying = ghost.entity:IsAnimationRunning(0, animName) end)
-        pcall(function() ghost.entity:StartAnimation(0, animName, 0, 0.4, 1.0, true) end)
+    -- Call StartAnimation every tick to override Mannequin's idle.
+    pcall(function() ghost.entity:StartAnimation(0, animName, 0, 0.15, 1.0, true) end)
```

— i.e. the ghost path once used exactly the puppet path's rule and lost it
seven months ago.

### 2.3 Why the queue overflows only sometimes. (observed, mechanism inconclusive)

50 enqueues/second is the necessary condition but not the whole story: a queue
that drains normally collapses them. The measured amplifier is a **local
menu**:

| Log | Overflows per 1,000 lines inside menu windows | Outside |
|---|---|---|
| joiner | 413 | 21 |
| host | 350 | 28 |
| earlier host session | 0 | 8 |

On the joiner, 6,148 of 9,037 overflows fall inside menu windows covering
14,884 lines — 10% of the session carrying 68% of the storm.

The reason is in the agent, and both agent logs measure it directly. A local
menu suspends `Script.SetTimer`, so WO-13 has the agent pump
`KCD2MP_InterpPump()` over `ExecuteString` for the duration. Its own summary
lines report, for the joiner, **5,395 pumped frames in 62.8 s (86.0 Hz)**, and
four shorter windows at 62.9–79.7 Hz; for the host, up to **100.2 Hz**. Every
one of those frames reached `KCD2MP_UpdateAnimation` and enqueued a clip, into
an animation system that was not advancing to drain it.

**Honest limit:** menus are neither necessary nor sufficient. The earlier host
session produced 1,998 overflows with **zero** inside any menu window, its
storm began at no marker at all, and it **stopped** mid-session at line 97,799
with no save load, no menu and no respawn, and did not return for 101,037
lines. Whatever stops the character instance draining its queue in the
non-menu case is engine-side and was not identified from these logs. What is
established is that the mod supplies 50–100 enqueues/second where 1/second
does the same job, and that this is the entire supply side of the problem.

### 2.4 Verdict on the faction link: **ruled out.**

The prompt's hypothesis was that a missing faction makes a combat state check
fail open and re-issue the animation. It does not survive the evidence. The
storm appears on **both** machines' live ghosts, built from **different** souls
(the joiner's from `ttac_man_9`, the host's from `ttro_man_59`), on
**different** clips, while **neither live ghost ever throws a faction error at
all** (§1.1). The enqueue rate is fully explained by a code-verified
unconditional per-tick call, and the per-clip counts match the tag→clip table
exactly. There is no residual for a faction effect to explain.

### 2.5 Verdict on soul-specificity: **ruled out.**

Nothing in the animation or spawn path branches on soul, class or `className`.
The joiner's ghost dominating the clip histogram with a longsword combat idle
reflects only that its owner spent that session with a weapon drawn — the tag
is still `idle`, and the clip is swapped by `KCD2MP.ghostWeaponDrawn`, which is
per-ghost state, not soul state.

---

## 3. The chain leak — root cause

### 3.1 What happened, to the line. (observed)

Joiner, in five consecutive mod log lines ending at 139690:

```
NPC-SYNC release ttkc_man_4 (stream silent)      (and four more)
NPC-SYNC puppet tick stopped (no puppets)
TICK_ALIVE #37500
tickstat avg=57.9ms max=19187.0ms n=581 interval=20ms DEGRADED (~17 fps floor)
NPC-SYNC puppet start ttkc_scribe
NPC-SYNC puppet tick started (50ms) gen=17
```

and then at 140915:

```
NPC-SYNC CHAIN LEAK CONFIRMED: puppet chain gen=16 is still running while
gen=17 is current -- two chains were writing the same puppets (stale chain
exiting now)
```

Generation 16 started at 138972. Its **last act was to stop itself**, and
generation 17 started on the very next inbound packet.

### 3.2 The mechanism. (code-verified)

`KCD2MP_NpcPuppetTick` reschedules its 50 ms successor at the **top** of the
tick, and may decide at the **bottom** that there is nothing left to drive
(`npcPuppetRunning = false`, "no puppets"). That leaves exactly one scheduled
timer belonging to a generation that is no longer running.

`chainMayStart` then grants a stopped chain an **immediate, unprobed restart**:
`tickAlive(false, stamp)` is false, and the next line short-circuits on the
falsy flag and returns `true` before any probe is armed. This is deliberate —
the doctrine comment names "the puppet chain's 'no puppets' exit" as a case
that "still starts at once". So a packet arriving inside that window starts
generation N+1, sets the flag back to true, and the orphaned generation-N timer
then wakes into a live chain and is reported as a leak it did not cause.

This is the **only** self-stop in the file. Every other `*Running = false` is
module init or an externally called stop.

### 3.3 Why WO-78's model does not cover it. (code-verified)

WO-78's leaks came from a **false restart of a chain that was suspended rather
than dead**, and its probe gate stops those. Here the chain really did stop,
the restart is legitimate, and the gate is bypassed by design. Different
mechanism, and the existing gate could never have caught it.

### 3.4 The menu widened the window from 50 ms to a whole menu. (observed)

The prompt states that "the emitter's sequence numbers were incrementing
normally through this entire window — no timer suspension occurred". **That is
refuted by the log.** The emit line's third field is `os.clock()` seconds
(format documented at `kdcmp.lua:176`). Sequence numbers do increment by one,
but the clock field jumps:

| Sequence | Clock | Gap |
|---|---|---|
| 30704 | 1161.384 | 19.19 s |
| 30705 | 1168.026 | 6.64 s |

and the mod's own `tickstat` line in the same window reports
`max=19187.0ms` against a 20 ms interval — the same 19.2 s, independently
measured. The map screen was open from line 135762 to 140894. Timers were
suspended for the duration while the agent's pump and its `ExecuteString`
traffic kept running, so **both** the orphan and generation 17's first timer
were released together when the screen closed. The leak line fires 21 lines
after `ApseClose`.

### 3.5 Severity: it was a false positive, with one real cost. (code-verified)

With `mp_npc_chainfix` defaulting on since WO-78, the orphan returns before its
reschedule and before the write loop, so it fires once and never writes a
puppet — the two chains never actually overlapped as writers. The real damage
is that `_chainLeakSeen.puppet` is a latch that is **never reset**, so one
benign firing permanently suppressed the report of any genuine puppet-chain
leak for the rest of the session, and raised a user-visible toast for a
non-event. Under the `mp_npc_chainfix off` rollback it would instead have
become a genuine permanent double chain.

### 3.6 The camera teleport: **common cause, not a link.** (observed)

`Teleport outside PrecacheMode detected! Camera Observer 1 moved 8420.50m in a
single frame` sits 1–3 lines after `World observer is changing mode from 1 to
0` and `PlayAudio: ApseClose` in **every** instance across both logs (joiner:
16207, 121015, 133196, 140897, 147190; host: five more). It is the map camera
returning to the player. It is not a position written to any entity by this
mod, and it does not cause the leak. Both are consequences of the same event —
the map screen closing — which is why they are 18 lines apart.

---

## 4. What shipped

All four changes are in `kdcmp/Data/Scripts/Startup/kdcmp.lua`.

### 4.1 Ghost animation throttle — `mp_anim_loop`

A looped clip restarts on a **change**, plus a keep-alive refresh, instead of
on every tick. Applied to all four looped ghost-side call sites: locomotion /
idle / combat idle, both riding-rider variants, and the horse gait.

Two things the puppet path's rule does not need, and this one does:

* **The guard compares the clip name, not just the tag.** Tag `idle` maps to
  two clips — `relaxed_idle_both`, and the combat guard idle when the owner's
  weapon is drawn — so a tag-only guard could never switch between them. This
  is the specific way a naive port of WO-40's rule would have broken.
* **A pumped frame gets the change-driven restart but never the keep-alive.**
  Refreshing a loop into a frozen animation system is exactly the queue filling
  described in §2.3, and the pump exists to keep ghost *bodies* moving through
  a menu, not to re-blend their animations.

A one-shot (a swing) clears the loop guard when its window expires, because it
replaced the clip on layer 0 — without that a ghost would hold its swing pose
until the next keep-alive. Under the old per-tick restart this could not arise.
The **vz-driven jump branch** needed the same clear explicitly: it is the one
one-shot site in the file that sets no `oneShotUntil`, so the expiry path never
runs for it, and a ghost running both before and after a jump would have
matched on clip name and skipped the restart. Found by writing the test for it,
not by reading the code.

Rollback: `mp_ghost_anim_refresh <seconds>`; `0` restores the pre-WO-84
per-tick restart exactly, so the fix can be A/B'd on one build.

Measured in the synthetic harness: 2 s of 20 ms ticks on a stationary ghost
goes from **101 StartAnimation calls to 3**, and 2 s of 80 Hz pumping from 160
to **1**.

### 4.2 Puppet-chain generation retirement

When the chain stops itself, the generation that owns the in-flight timer is
**retired by name**. When that orphan fires it exits silently, writes nothing,
reschedules nothing, and is counted rather than reported. A generation that did
*not* stop itself is untouched, so WO-69's detector still reports a real leak,
with its toast.

The same retirement is applied to the ghost interp chain at `KCD2MP_Stop`,
which has the identical shape. **This one is preventative: it has never been
observed in a field log**, and is recorded that way rather than claimed as a
fixed bug.

`_chainLeakSeen` keeps its once-per-session latch for the loud line and the
toast, but leak firings are now **counted** separately and surfaced in the
existing 5 s cadence line alongside the absorbed-orphan count — so a second
leak is no longer invisible behind the first.

### 4.3 The stray sweep now runs during play

WO-58's `KCD2MP_SweepStrayGhosts` is called from `KCD2MP_ReconcileGhosts`,
which the agent already invokes every 5 s. Its reasoning is unchanged. Four
extensions:

* `immediate` — true from the shutdown caller, which wants the body gone now.
  False (the new periodic caller) requires a name to be seen untracked on
  **two consecutive sweeps** before removal. Single-threaded Lua already means
  a sweep cannot interleave with `KCD2MP_SpawnGhost`'s brief untracked window;
  the second look makes that argument unnecessary rather than merely correct.
* A 30 s throttle, so the 5 s reconcile call is a safe host.
* Ids 0..63 rather than 0..31 — the relay's cap is 64 players, so 31 could miss
  a real stray on a full server. 128 name lookups every 30 s.
* The horse branch removes through `mp_remove_entity_verified` like the ghost
  branch, instead of a bare unverified `System.RemoveEntity`.

### 4.4 The faction attempt is now measurable

The single `pcall` is split, and one line per spawn records: whether the
`Properties` write succeeded and its error if not, **whether the entity has an
AI object**, the value of `AIPARAM_FACTION`, and whether `AI.ChangeParameter`
ran and what it returned. That is exactly the evidence needed to decide between
the two readings left open in §1.6. No behaviour changed.

---

## 5. What is still open, and what would settle it

1. **Does the restored ghost body stand in the world for the whole session?**
   *Inconclusive* (§1.5). Settled by the next session's log: a
   `SweepStrayGhosts: untracked kcd2mp_<n> ... removing` line means it does; its
   absence across a session that loaded a save means it does not.
2. **Which of the two readings explains the ghost's silent
   `AI.ChangeParameter`?** *Inconclusive* (§1.6). Settled by one line: the new
   `faction attempt ghost` log entry's `entity.AI=` and `err=` fields.
3. **What stops a character instance draining its animation queue outside a
   menu?** *Not identified* (§2.3). This is engine behaviour this project
   cannot inspect from Lua. A live probe would need to correlate overflow
   onset against the ghost's distance from the local camera and its LOD /
   visibility state — neither of which the mod reads today. Until then, the
   supply-side fix stands on its own merits: 1/s does the job 50/s was doing.
4. **Does the throttle resolve the reported "animation not smooth" complaint?**
   *Unverified.* The harness proves the call counts, not how a ghost looks to a
   person. The two are related but not the same claim: jitter also has the
   WO-69 D1 emit-period component and the WO-75 interpolation work behind it.
   A live A/B via `mp_ghost_anim_refresh 0` / `1` is the test.
5. **A real faction attach for a live ghost** is native
   (`C_FactionBase::SetParent`). The native plugin already contains two
   routes — a research hook gated behind a `kcdmp-faction.txt` that nothing
   ships, and the wired `SetFactionHostile` pipe opcode behind
   `mp_enable_aggro`. Prior docs disagree about whether the by-value
   `shared_ptr` ownership defect in that path was ever fixed. **Resolve that
   contradiction before touching it**; it is not a WO-84 change.

---

## 6. Claims this work order refutes

* "One ghost entity with no faction assignment for the entire session."
  **Refuted.** The live ghost never throws a faction error; the errors belong to
  a save-restored body and fire only during reconcile passes (§1.1–1.2).
* "The emitter's sequence numbers were incrementing normally … no timer
  suspension occurred." **Refuted.** Sequence increments, the clock field jumps
  19.19 s then 6.64 s, and `tickstat` independently reports `max=19187.0ms`
  (§3.4).
* "The animation storm is specific to this soul's sensitivity." **Refuted.**
  Both machines, different souls, different clips, no soul branch in the code
  (§2.4–2.5).
* "These may be three symptoms of one cause." **Refuted.** Two causes and one
  coincidence (§0).
* "`<name> deleted 0 reconciled changes` means the entity was deleted."
  **Refuted.** It discards change records; the entity's fate is not stated
  (§1.5).
