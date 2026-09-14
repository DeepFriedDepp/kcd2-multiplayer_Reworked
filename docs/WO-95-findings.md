# WO-95 — the 2026-09-13 two-player session, in full

Forensic read of one live two-player session on 0.22.0: eleven reported
items, five hypothesis groupings, and an open sweep of both machines' logs
for everything nobody watching happened to catch. Companion:
`docs/WO-95-progress.md`.

Sources: host and joiner bundles (`kcd.log`, `agent.log`, `kcdmp-native.log`,
the launcher log, and the relay log from the host). No live game was
available to this session; everything below is from the logs and the code.
The two players are called **host** and **joiner** throughout.

Evidence marks used exactly as in every prior WO here: **(observed)** = read
off a log line; **(code-verified)** = read off the shipped source;
**(read-but-unrendered)** = the code path exists and was exercised but its
on-screen result is not in any log; **(inconclusive)** = the logs do not
settle it.

---

## 0. Answer first

* **Nine of the eleven reports are confirmed, two are refuted in their stated
  form** (item 9's "the joiner reverted" — it was the host, twice; item 3's
  "0.5 s" — the true figure is 0.80 s, and only after correcting a clock skew
  nobody knew was there).
* **Three of the five groupings hold; two do not.** Group A (dialogue) and
  Group B (scripted-fight deaths) both collapse: the items inside them have
  different mechanisms, and in both cases the *obvious* suspect is innocent.
* **The single largest finding is not on the list.** The host logged **30,495
  engine movement-validation errors**, 26,950 of them against one NPC, whose
  onset is in the same tenth of a second as that NPC's claim grant and puppet
  start. Peak 43 per second, still running when the log ends.
* **The wire is healthier than the session felt.** Cross-machine NPC damage
  landed within 30–50 ms and to the exact decigram; WO-86's death sync did
  its job; WO-90's `DialogTwin_` exclusion held at zero all session; WO-78's
  chain-leak detector caught a real leak and the fix stopped it.
* **What actually went wrong is quest-state divergence**, and every painful
  item in the list is downstream of it. See §5.

---

## 1. Phase 0 — the master timeline, before any theory

### 1.1 The build, confirmed from the logs, not assumed

| Fact | Evidence |
|---|---|
| Both clients on 0.22.0 | relay: `[+] '<host>' connected (id=0, protocol v6, release 0.22.0)` 15:32:18.0; `[+] '<joiner>' connected (id=1, protocol v6, release 0.22.0)` 15:33:17.9 **(observed)** |
| Agents agree | host `[version] ghost 1 is on release 0.22.0`; joiner `[version] ghost 0 is on release 0.22.0` **(observed)** |
| `main` is at WO-94's head | `git log` → `0c66261 WO-94: version 0.22.0, release cut`; `VERSION` = 0.22.0 **(observed)** |
| The pak in play is WO-94's | both `kcd.log`s carry `QUEST current main quest: socky (M03 Laboratores, 1 fireable beats)` — the WO-94 registry line, with WO-94's own fireable count for M03 **(observed)** |

Two earlier sessions on the same relay log (14:26 and 14:55) ran **0.21.5**
and are not this session. The 0.22.0 session runs 15:32:18 → 16:35:42.

### 1.2 Calibration — the two machines' clocks are 0.80 s apart

**This had to be found before anything cross-machine could be timed, and it
is the size of the effect item 3 reports.**

`kcd.log` carries no wall clock. It carries `[KCD2-MP-DATA] v2 <seq> <t>`
where `t` is `os.clock()` seconds since mod init, so each machine's log maps
onto its own wall clock by a single constant. Anchoring on events that appear
in both `kcd.log` (as `t`) and `agent.log`/the relay (as wall time):

| Machine | Anchors | Offset | Spread over 52 min |
|---|---|---|---|
| Host | 3 (a relayed FATAL, two catch-up fires) | `t` + 15:29:46.19 | 22 ms |
| Joiner | 2 (a peer catch-up, its own fire) | `t` + 15:31:03.55 | 39 ms |

`os.clock` does not drift on either machine **(observed)**.

The relay runs on the host, so relay time *is* host time. Three independent
relayed events were logged by the relay **before** the joiner's own agent
logged sending them:

| Event | Relay (host clock) | Joiner agent (joiner clock) | Apparent lead |
|---|---|---|---|
| FATAL relayed, one NPC | 15:40:55.021 | 15:40:55.833 | 0.812 s |
| joiner reported its own death | 15:44:02.294 | 15:44:03.076 | 0.782 s |
| FATAL relayed, same NPC | 15:45:02.452 | 15:45:03.243 | 0.791 s |

A packet cannot be received before it is sent, so **the joiner's wall clock
runs ≈0.80 s ahead of the host's** (LAN latency ≈1 ms, so the residual is
negligible) **(observed)**. Everything below is in **host clock**; joiner
`kcd.log` `t` maps to host clock as `t + 15:31:02.75`.

**Trap, for every future session:** comparing raw `agent.log` timestamps
across these two machines is wrong by 0.8 s. That is larger than the
reported cutscene offset, larger than the observed damage latency, and would
by itself manufacture or erase a finding.

### 1.3 The timeline — all eleven reports located on both machines

| # | Host clock | What the logs show | Item |
|---|---|---|---|
| | 15:32:18.0 | host connects; 15:33:17.9 joiner connects | |
| | 15:40:04–15:40:59 | the `zachrana` ambush: both players fight two NPCs | **1** |
| | 15:40:54.9 / 15:40:58.7 | host lands both killing blows, `0x31 FATAL` on the wire | 1 |
| | 15:42:50.6 | host player dies; host reloads 15:42:53.8 | |
| | 15:44:02.3 | joiner player dies; joiner reloads 15:44:06.3 (its **only** save load all session) | |
| | 15:43:31–15:45:03 | the fight again, roles reversed | **2** |
| | 15:46:46.6 / 15:46:57.0 | `zachrana_afterHerbs` — 10.4 s apart | 3 |
| | 15:54:16.3 / 15:54:17.1 | `zachrana_prespani` — **0.81 s apart** | **3** |
| | 15:56:07.1 | host advances alone; `[story] divergence` opens | |
| | 15:58:24.7 | joiner converges; divergence closes | |
| | 16:01:48.19 / 16:01:47.42 | `m03_trosky_journey` (Rendered) — **0.77 s apart**; 172.8 s freeze on both | **3, 4** |
| | 16:04:41.04 / 16:04:40.23 | `socky_2_gate` (Ingame) — **0.81 s apart** | 3 |
| | 16:09:26.6 / 16:09:29.1 | `socky_3_tavern` — 2.5 s apart (players skipped the previous one apart) | 3 |
| | 16:10:36.9 | Hans relocated 847 m by the quest; relay rejects 3 claim updates as implausible | |
| | 16:10:38.0 / 16:10:38.9 | both get the **first** Hans conversation | |
| | 16:12:25.4 | joiner advances to `socky promluv si s zenou`; divergence opens | |
| | 16:12:26.2 → 16:12:37.2 | host prompt → **F11 fired** → teleport 7.7 m | **8** |
| | 16:21:21.5 | host reaches `socky rekni ptackovi o pr` — **its last objective change of the session** | **6** |
| | 16:22:00.8 | joiner reaches the same objective; converged | |
| | 16:22:07.1 | **joiner** gets the **second** Hans conversation. The host never does. | **5, 6** |
| | 16:22:08.9 | the host's only talk request all session that produces no dialogue | **5** |
| | 16:23:11.8 | joiner advances to `socky nos pytle 05` — **the sacks** | **9** |
| | 16:24:01.2–16:24:07.7 | host: **11 talk requests in 6.5 s**, every one answered by the same coachman bark | **6, 7** |
| | 16:27:00 | **host** reloads `autosave009` | **9** |
| | 16:27:10.1 | host: `NPC-DIVERGE ttkc_woodworker ... 9.1 m ... 180 s` | **7** |
| | 16:27:30.9 | joiner advances to `socky bran ptacka` | 9 |
| | 16:28:46.1 | **host** reloads `autosave009` again | **9** |
| | 16:29:35.1 | host dialogue `jindra_nemuze_z_hospody` — "can't leave the tavern" | **10** |
| | 16:29:38.9 | joiner: two `NPC-DIVERGE` releases in the same tick | **11** |
| | 16:30:10.4 | host: woodworker stand-off lapses, puppet re-acquired — **a snap** | **11** |
| | 16:32:27.8 → 16:32:32.1 | host prompt #2 → F11 → teleport 15.0 m, same destination | 8 |
| | 16:33:37.5 | host: `jindra_nemuze_z_hospody` again, 4 min later | 10 |
| | 16:33:48.4 | joiner leaves M03 entirely (`svatba`, then `hledanipsa`) | 9 |
| | 16:34:36.7 | joiner fires its own F11 → teleport 20.8 m, same destination | 8 |
| | 16:35:41.9 | host disconnects | |

---

## 2. Phase 1 — the five groupings

### Group A — dialogue and conversation (items 5, 6, 10): **the grouping does NOT hold**

Three different mechanisms that look alike from the chair.

**The objective test.** Every player-initiated conversation leaves a
`Soul 'Dude' requested dialog. Assigned id is N` followed by
`Attempting to start new dialogue (runtime id 'N') with souls 'Ex: Dude; ...'`.
A request with no matching start is a refused conversation. Across both
machines for the whole `socky` stretch: **31 requests, 30 resolved, 1 did
not** **(observed)**.

* **Item 5 — one sample, not a mechanism.** The single unresolved request is
  the host's, at 16:22:08.9, **1.8 s after the joiner opened its own Hans
  conversation** and 0.9 s after the host's *previous* request had already
  succeeded. That is equally consistent with a double press during an opening
  dialogue. **No lockout mechanism is visible in either log.** Specifically:
  * `RestrictDialog(true)` is applied only to the **ghost's** soul, six times
    on the host and twice on the joiner, each `readback=true`
    **(observed)** — it gates being spoken to *on the ghost body*, and cannot
    touch a world NPC **(code-verified, WO-90 §3.2)**.
  * **WO-90's `DialogTwin_` bug has not recurred.** Zero `DialogTwin_` claims
    in the relay and zero in either machine's NPC sync, all session
    **(observed)**. The exclusion is holding.
  * **Verdict: inconclusive on one sample.** Real or not, it is not what made
    the evening hard.

* **Item 6 — not a lockout at all.** The host opened a dialogue with Hans
  **exactly once**, at 16:10:38, and never again **(observed)**. It was never
  refused; the conversation was never offered, because the host's quest never
  advanced to the beat that offers it. The host sat on
  `socky rekni ptackovi o pr` from 16:21:21 to the end of the session — 14
  minutes, zero objective changes — while the joiner moved through three more.
  The 11 talk requests in 6.5 s at 16:24 are the player working the talk key
  against NPCs that had nothing quest-relevant to say; all eleven were
  answered, all eleven by the same coachman bark **(observed)**.

* **Item 10 — the game working correctly.** `jindra_nemuze_z_hospody`
  ("Jindra can't leave the tavern") is Warhorse's own gate line for that beat,
  fired twice, 4 minutes apart **(observed)**. For the host's *actual* quest
  state it is the right line. It reads as a bug only because the host's quest
  state was wrong relative to the joiner's.

**Group A verdict: refuted as a shared mechanism.** Items 6 and 10 are not
dialogue defects at all — they are quest-state divergence presenting as
dialogue. Item 5 is a separate, single-sample, unexplained refusal. This is
**not** a recurrence of WO-90's `DialogTwin_` bug.

### Group B — scripted-fight deaths (items 1, 2): **holds as one event, but the suspected cause is refuted**

The reported signature — "dead body still walking" — is WO-86's original
symptom verbatim, so the obvious hypothesis is that WO-86's fix does not
engage inside a scripted fight. **The logs refute that.**

**The damage wire was exact and fast.** Reconstructing one NPC's health from
the host's own emitter against what the joiner applied:

| Host's copy (host clock) | Host hp | Joiner applied | Joiner's delta | Lag |
|---|---|---|---|---|
| 15:40:15.4 | 100 → 90.2 | 15:40:15.43 | −9.8 | 30 ms |
| 15:40:19.2 | 90.2 → 53.5 | 15:40:19.25 | −36.7 | 50 ms |
| 15:40:28.2 | 53.5 → 34.8 | 15:40:28.25 | −18.7 | 50 ms |
| 15:40:35.1 | 34.8 → 32.8 | 15:40:35.04 | −2.0 | ~0 |
| 15:40:36.1 | 32.8 → 22.4 | 15:40:36.06 | −10.4 | ~0 |

Every blow, in order, to the decigram, **30–50 ms** behind the host's own
engine **(observed)**. The killing blow then arrived as `0x31 FATAL` and the
joiner applied death in the same tick it was received — not early
**(observed)**. The other ambush NPC matches: the joiner's copy read
`hp=31.3759` at the instant a 31.4 blow arrived, i.e. **the two worlds' health
agreed to four decimal places** **(observed)**.

**So this is not a death-sync failure.** WO-86's protocol work is doing
exactly what it was built to do, now with two-machine evidence it never had.

**What the scripted fight actually does, that nobody had established:** both
ambush NPCs were `puppet=yes` on the receiving machine throughout
**(observed)**. **A quest-scripted fight runs through the ordinary NPC-sync
path with no special case** — the non-authority's copies are position-written
every 50 ms while their own local brains keep running. That was assumed
(WO-51 says claims never fire in combat); it is now observed to be how a
scripted fight behaves.

**Two unguarded paths, both code-verified:**

1. **The puppet hold covers dead and unconscious — and nothing else.** The
   gate is `if p.dead or p.ko or locallyDead or locallyKo or remoteDead`, and
   a body inside it is frozen (or corpse-dragged) with **no animation write**
   **(code-verified)**. A body that is *knocked down, staggering or in a hit
   reaction* is none of those five things. It keeps taking a 50 ms position
   write and a restarted locomotion loop over the top of the reaction —
   `e:StartAnimation(0, anim, …, true)` on tag change or every 1 s, with no
   death, KO or reaction gate anywhere in that branch **(code-verified)**.
   **A prone body being walked along is precisely the report.**
2. **WO-86's corpse-write safeguard never engaged, all session.** Every
   cadence line on both machines reads `corpse writes suppressed=0`
   **(observed)**. By construction it only fires when the local copy is down
   **and the inbound stream says alive**; when both agree the NPC is dead the
   code falls through to the drag/carry branch and keeps writing the corpse's
   position **(code-verified)**. That is intended (corpse dragging is a
   feature), but it means the safeguard covers one of the two ways a corpse
   can be seen moving.

**Group B verdict: items 1 and 2 are one event, and WO-86 is exonerated.**
The cause is presentational, in the puppet renderer, not on the wire. The
knockdown gap is the concrete, named gap. **Which of the two paths produced
what the joiner saw is (inconclusive)** — no log line records an NPC's
animation state at the moment it is hit, and adding one is the natural next
step.

### Group C — cutscene entry timing (item 3, with item 4): **holds, and the answer is a hard limit**

**The measurement, after removing the 0.80 s clock skew:**

| Cutscene | Host | Joiner (host clock) | Δ |
|---|---|---|---|
| `zachrana_prespani` | 15:54:16.29 | 15:54:17.10 | **0.81 s** (joiner later) |
| `m03_trosky_journey` | 16:01:48.19 | 16:01:47.42 | **0.77 s** (joiner first) |
| `socky_2_gate` | 16:04:41.04 | 16:04:40.23 | **0.81 s** (joiner first) |

For the three cutscenes the two players reached together, the entry offset is
**0.77–0.81 s, in both directions** **(observed)**. The maintainer's "roughly
0.5 s" is corroborated; the true figure is 0.8 s. (The two earlier cutscenes
at 6.3 s and 10.4 s apart, and the later one at 2.5 s, are not entry jitter —
the players arrived or skipped out at genuinely different moments.)

**Why nothing can fix this as things stand:**

* **Nothing in the mod schedules a cutscene.** Each engine starts its own when
  its own player crosses the trigger. The 0.8 s is the players' own arrival
  difference plus per-machine load.
* **There is no hold primitive on this build**, re-confirmed rather than
  re-derived: `wh_ui_StopCutscene` is scoped to `wh_ui_PlayCutscene` and does
  not touch a quest cutscene; `mov_NoCutscenes` is a skip, not a hold; there
  is **no quest scriptbind at all** on retail **(code-verified, WO-90 §3.2)**.
* **There is no usable pre-roll to hold *in*.** Tonight's own logs:
  `OnCutsceneInitialized` → `PlayCutscene` is **0.000 s** for four of six
  cutscenes and **0.16 s** for the other two **(observed)**. There is no
  window in which a gate could be armed.

**Verdict: true synchronized cutscene start is not achievable with what this
build exposes.** It is an engine-level limit, not a mod defect. The only
lever that moves the number is making the two players arrive together — which
is §5's recommendation on independent grounds.

**Item 4 (nametag visible during a cutscene) — explained, and not a bug.**
A **Rendered** cutscene freezes every Lua timer chain: across
`m03_trosky_journey` both machines logged every chain as `172.7s`/`172.8s`
stale and `os.clock` did not advance at all **(observed)**. An **Ingame**
cutscene does not: through the 285 s `socky_2_gate` the host kept logging
tick statistics throughout **(observed)**. The label loop is one of those
chains, so it keeps drawing names through Ingame cutscenes and stops during
Rendered ones. Exactly as reported, and now with a mechanism.

### Group D — the catch-up mechanism (items 8, 9): **holds; both are confirmed design behaviour, not defects**

**Item 8 — F11 fired. It was not silent.** The full chain is in the host log
for both fires **(observed)**:

```
QUEST-CATCHUP FIRE #1: wh_concept_HasteTrigger socky._initAndStart
[CONSOLE] Executing console command 'wh_concept_HasteTrigger socky._initAndStart'
QUEST-CATCHUP ExecuteCommand returned true
<HasteTrigger> name:'Barbora.trosecko.socky.haste.teleportBeforeEndPreviousQuest' is being triggered from haste
TeleportPlayer Player 'Dude' (alive, health=100.00/100.00) BEFORE pos=<2335.89 2071.29 110.51>
CATCHUP-HAZARD teleport-local ...: player jumped 7.7m in one 33ms tick
```

followed by twelve further `<HasteTrigger>` lines — the cumulative replay
WO-92 §6.1 identified as the lever. **The player *was* relocated.** All three
fires of the session landed on the identical point, `(2342.7, 2068.2, 112.2)`:

| Fire | Who | From | Jump |
|---|---|---|---|
| #1 | host, 16:12:37.5 | (2335.9, 2071.3, 110.5) | **7.7 m** |
| #2 | host, 16:32:32.4 | (2343.5, 2083.2, 111.2) | **15.0 m** |
| #1 | joiner, 16:34:37.9 | (2340.7, 2047.8, 109.2) | **20.8 m** |

This is **WO-94's named open uncertainty, confirmed live**: the catch-up jumps
to a point Warhorse authored for their own testing, not to the peer. Because
all three fires happened inside the same tavern courtyard the jump was a few
metres and read as "nothing happened". The mechanism worked; the destination
is the limitation. (WO-94 §9 also predicted the landing is ~1.6 m above the
ground here — unchanged.)

**Item 9 — a save revert cannot resync quest progress, and two of the three
premises in the report are wrong.**

* **It was the host that reverted, not the joiner** **(observed)**. The joiner
  loaded a save exactly once all session, at 15:44:06, after its own death.
  The host loaded four times: 15:42:53.8, 15:44:14.9, **16:27:00** and
  **16:28:46.1** — the last two inside the sacks stretch.
* **Both of those reloads were to `autosave009`, whose own quest marker is
  `@qname_socky_CpmD|@socky_rekni_ptackovi_o_pr_ebpz`** **(observed)** — the
  host's already-stuck objective. Reloading it could only restore the host to
  the same place it was stuck.
* **The conclusion in the report is right and survives the correction.** A
  save restores position and world state at the moment of the save. It has no
  channel to the peer's quest state, and the mod has none either: **no quest
  scriptbind exists on this build**, so nothing can read or write quest
  progress except by firing a Haste trigger **(code-verified, WO-90/WO-92)**.
  A revert on either machine was never going to close this gap.

### Group E — jitter (items 7, 11): **holds; the release engaged for item 11 and could not for item 7**

WO-90's divergence release fires when the local world drags a puppeted body
**more than 8 m** from our last write, **3 times within 30 s**. WO-94 raised
the stand-off to 180 s.

**The stand-off is exactly 180 s, measured** — 180.3 s, 181.9 s, 181.7 s,
180.9 s across four release/resume pairs **(observed)**. WO-94's change is
confirmed in the field.

**Item 7 (jitter through the sacks stretch, ~16:21–16:28): the release did
NOT engage, and by construction could not.** The host had exactly one release
in that window, on a different NPC. Through the whole stretch the host's
readings for Hans — the NPC the beat is about — were **0.07 m to 0.17 m**,
sampled thousands of times **(observed)**. That is **two orders of magnitude
below the 8 m threshold**. The bodies were not being yanked; they were being
*vibrated*, by our 50 ms write and the unsuppressed local brain disagreeing by
about 15 cm, continuously.

**This is a real, precisely nameable gap.** WO-90's release is built for the
large, rare divergence (its own validation set: 97% of readings under 2 m, the
rule firing twice in 90 minutes). It has no answer for a sustained
sub-metre tug-of-war, which is what a player actually sees as jitter. Nothing
in the mod currently detects or reports that case.

**Item 11 (hard jitter from ~16:29:35, self-corrected with a visible snap):
the release DID engage, and the snap is the mechanism working as designed.**
The joiner released two puppets in one tick at 16:29:38.9, and the host's
180 s stand-off on `ttkc_woodworker` lapsed at **16:30:10.4**, re-acquiring
the puppet in the same tick **(observed)**. A release hands the body back to
the local world at its own position; a re-acquire snaps it back to the
stream's. Both are single-tick position changes. **"Self-corrected eventually,
but visibly snapped rather than smoothed out" is a precise description of the
shipped behaviour** — already named as a known limitation in WO-90 §4.2
("the stand-off is time-based rather than convergence-based").

Two aggravating factors sit under both items, neither previously recorded:
the host's frame time doubled for the last 25 minutes (§3.2), and the host
was simultaneously emitting a 43-per-second engine error storm (§3.3).

---

## 3. Phase 2 — the open sweep

**This was run as a first-class pass over both full logs, not as a leftover.**
It found nine things that nobody reported, one of which is larger than
anything on the list.

### 3.1 The two machines' clocks are 0.80 s apart

Covered in §1.2 because Group C could not be answered without it. Listed here
too because it is a sweep finding in its own right: it silently corrupts every
cross-machine timing claim, and no tooling in this project currently measures
or reports it.

### 3.2 The host's frame time doubled for the last 25 minutes

The host's tick statistics run at **22–28 ms** until 16:11, then sit at
**41–43 ms for the remaining 25 minutes** — about 24 fps, against the joiner's
steady 28 ms (~36 fps) **(observed)**. The host is also the machine running
the relay and the master server. Nothing in the reports mentions frame rate;
at 24 fps every other symptom in the session is worse.

### 3.3 30,495 engine movement-validation errors on the host — the largest finding of the night

```
CLivingEntity:Action(action_move): (<npc> @ 2326.3,2038.8,108.8)
  Validation Error: dir is invalid or out of range
```

| | Host | Joiner |
|---|---|---|
| Total | **30,495** | 70 |
| One NPC (`ttkc_woodworker`) | **26,950** | — |
| Second NPC (`ttkc_man_16`) | 3,513 | — |
| Peak rate | **43 per second** | — |

**The onset is not ambiguous** — three events in the same tenth of a second
**(observed)**:

| Host clock | Event |
|---|---|
| 16:20:36.11 | relay: `[CLAIM] granted npc=ttkc_woodworker owner=1` |
| 16:20:36.2 (`t`=3050.0) | host: `NPC-SYNC puppet start ttkc_woodworker` |
| 16:20:36.2 (`t`=3050.0) | host: **first** `dir is invalid` for that NPC |

The NPC is pinned by our writes while its own unsuppressed brain keeps issuing
move actions the engine then rejects. Both affected NPCs are puppets; no
non-puppet NPC produced more than a handful. This is the same tug-of-war as
item 7, seen from the engine's side, and it is a plausible contributor to §3.2.

**One thing does not fit and is (inconclusive):** the storm persists through
puppet releases and through the entire 180 s divergence stand-off, and was
still running when the log ended at 16:35:40. Onset is firmly ours; what
sustains it is not established. **Named as a follow-up, not fixed blind.**

### 3.4 The packet-cadence instrument was reporting a meaningless number — **fixed this session**

Both machines printed, every five seconds:

```
NPC-SYNC packet cadence: n=11 mean=2057ms min=1923ms max=2206ms (emitter is 100ms; ...)
```

Session means of **1,738 ms** (host) and **1,887 ms** (joiner), with **not one
five-second window under 100 ms** and 415 of 503 host windows above a second
**(observed)**. Read literally: the stream is starved about 17×.

**It is not.** The emitter sends a *moving* NPC every `emitMs` (100 ms) and a
*still* one every `heartbeatS` (2.0 s), and the instrument averaged both
together **(code-verified)**. The tight clustering (`min=1923 max=2206`) is
the heartbeat, not congestion. Confirmed per-NPC: when the authority's Hans
was actually walking, 106 of its gaps were under 150 ms; the rest were
heartbeats **(observed)**.

So the number WO-70 is meant to tune a jitter fix against was really measuring
*how many tracked NPCs happened to be standing still*. **Fixed in §4.**

### 3.5 WO-78's chain-leak detector caught a real leak — first field confirmation

```
NPC-SYNC CHAIN LEAK CONFIRMED: puppet chain gen=9 is still running while
gen=10 is current -- two chains were writing the same puppets (stale chain exiting now)
```

Once, on the joiner, at 15:46:08 **(observed)**. WO-78 shipped this detector
and its fix synthetically-verified only. The detector fired, the fix stopped
the stale chain, and the host saw zero leaks all session. **WO-78 is
field-confirmed.**

### 3.6 WO-66's relay speed gate fired four times — all on legitimate scripted moves

| Host clock | NPC | Context |
|---|---|---|
| 16:04:41.27 | `tvez_bozena` | 0.2 s after a cutscene started and relocated her |
| 16:10:38.79 / 16:10:40.55 / 16:10:42.71 | `tkop_ptacek` | the quest relocating Hans **847 m** to the tavern |

All four are `[WO66-REJECT] speed ... implausible movement` **(observed)**.
Every one is a false positive: **a scripted teleport is indistinguishable
from a speed hack by displacement alone.** The rejects mutate nothing (WO-66's
design), so the cost is a stale claim position for those NPCs for a few
seconds — which is exactly when the peer most needs the update. A false-positive
class WO-66 did not anticipate.

Related and correct: WO-90's release did **not** fire on that 847 m
relocation, because it only reached 2 of its required 3 hits in 30 s
**(observed)** — the legitimate-teleport case WO-90 §4.3 designed for,
behaving as intended.

### 3.7 Ghost gait flapping, several times a second

Locomotion transitions logged for the *other player's* body: **3,224** on the
host and **4,409** on the joiner, of which **81%** and **84%** are less than
300 ms apart **(observed)**. The ghost's gait changes run→walk→run→sprint
several times a second for the whole session. Each is a `StartAnimation`.
This is WO-69's D1 signature on the ghost path rather than the puppet path,
and it is a visible stutter independent of anything in the reports.

Alongside it: **1,229 `Animation-queue overflow` errors on the joiner** versus
65 on the host, concentrated in the NPC-sync-heavy windows. The engine's own
text calls it "a serious performance problem" **(observed)**.

### 3.8 A sub-0.05 damage packet train

The joiner's hit sensor emitted **32 hits of ≤0.05 damage out of 72 total**,
including an unbroken run of 16 at about 8 Hz against one NPC between
15:44:59.98 and 15:45:01.68 **(observed)**. Each is a wire packet carrying a
hundredth of a hit point. Harmless to health, pure wire and log noise.

### 3.9 Smaller items, recorded so they are not rediscovered

* **`__completeActiveGateObjective` Haste errors**: 185 `already exists` +
  148 `Unable to find` on the host, in bursts of 37 or 74 **at every save
  load** **(observed)**. Present in WO-58's logs too, so it **predates WO-94
  and is not ours** — but it does mean Haste trigger registration is not clean
  across reloads, which is the same machinery the catch-up fires through.
* **A savegame collision on the joiner**: `Savegame type AutoSave, quest
  '@qname_hledanipsa…' is ignored, because there is another savegame pending`
  — two quests completing within one second during a catch-up **(observed)**.
* **`PerceptionTrigger … No NPC found for soul`**: 814 on the host, 569 on the
  joiner, all *after* the ambush NPCs died — the quest's own trigger still
  hunting for the dead **(observed)**. Vanilla behaviour, both machines.
* **The WO-50 DiscordRPC `Assets.Merge` NullReferenceException still fires**:
  three times on the host, four on the joiner, at startup **(observed)**.

---

## 4. Phase 3 — what was fixed, and what was deliberately not

### Fixed: the packet-cadence instrument (§3.4)

Small, self-contained, receiver-side only, no wire change, and verifiable
without a game.

* `KCD2MP_ApplyNpcState` now classifies each inbound packet as **motion**
  (position moved more than `npcSync.moveEps` since the previous packet) or
  **idle heartbeat**, deciding against the previous target before it is
  overwritten.
* Only **motion-to-motion** gaps enter the mean. Heartbeats are counted
  separately. WO-69's existing >5 s drop is untouched.
* A puppet's first packet has nothing to compare against, so it is classified
  `nil` and the gap after it is skipped rather than guessed.
* The log line now reads:
  `NPC-SYNC packet cadence: moving n=… mean=…ms min=…ms max=…ms; idle-heartbeat n=… (emitter is 100ms, heartbeat 2000ms; …)`

**Verification:** `tools/Test-WO95Synthetic.{ps1,lua}` — **32 checks, all
passing**, driving the real `kdcmp.lua` under MoonSharp with a fake clock.
Scenarios (a)–(g): a pure moving stream measures its true gap; a pure
heartbeat stream never enters the mean; **tonight's own mixture (four idlers
against one walker) now reports 100 ms where the old instrument would have
reported 277 ms**; `moveEps` decides, so sub-epsilon float noise stays a
heartbeat; the >5 s drop still holds; the transition packet out of stillness
is not averaged in; and the window resets cleanly.

**Regression:** 303 existing synthetic checks re-run green — WO-94 (101),
WO-86 (47), WO-84 (72), NPC-smooth (48), ghost-interp (35).

### Named, not attempted

| # | Finding | Why not now |
|---|---|---|
| 1 | The 30k movement-validation storm (§3.3) | Onset is ours; what sustains it past release is not established. Fixing the onset blind could mask the real cause. |
| 2 | The knockdown gap in the puppet hold (Group B) | Needs a live probe: does a read for "knocked down / in a hit reaction" exist on this build at all? `IsDead`/`IsUnconscious` do; nothing else is known. |
| 3 | Sub-metre sustained tug-of-war (item 7) | A genuine design question — a second, tighter threshold, or convergence-based rather than time-based release. Not a patch. |
| 4 | Item 5's single refused conversation | One sample. Needs either another session or an instrumented talk-refusal line. |
| 5 | WO-66's scripted-teleport false positives (§3.6) | The fix is to distinguish a scripted relocation from a speed hack, which needs a signal the relay does not currently receive. |
| 6 | Ghost gait flapping (§3.7) | WO-69 D1 on the ghost path; belongs with the jitter work, not bolted on here. |
| 7 | The 0.01-damage packet train (§3.8) | Trivial to threshold, but it is on the native side and this session cannot rebuild or deploy the DLL. |
| 8 | Cutscene start synchronisation (Group C) | Not buildable on this engine. Recorded as a limit, not a backlog item. |

No `VERSION` change. Nothing was deployed; the pak was not rebuilt.

---

## 5. Phase 4 — the highest-priority next step

**Recommendation: extend Shared Quests coverage into the prologue is the right
top priority, but it is the *second* step. The first is to make the readiness
prompt fire when the players are together and still diverge — because tonight
it mostly did not fire at all.**

The evidence, in order.

**1. Quest divergence is the root, and Group A proves it.** Items 5, 6, 9 and
10 all looked like different bugs and are all one thing: the host's quest
stopped advancing at 16:21:21 and never moved again, while the joiner took
three more objectives and then left the quest entirely. Items 7 and 11 are
made worse by it (the two players are in different world states in the same
tavern, so every shared NPC is contested). The new design principle is
therefore not just a preference — it is the actual root cause of most of this
session.

**2. But the prologue-coverage gap is not what bit tonight.** WO-94 §3.4
already established that `prepadeni` (M01) and `zachrana` (M02) have **zero**
fireable beats. That is confirmed live: `QUEST current main quest: zachrana
(M02 Fortuna, 0 fireable beats)` **(observed)**. And yet the `zachrana`
stretch went *fine* — the players diverged at 15:56:07 and reconverged on
their own at 15:58:24, twice more after that, with no lasting damage. **The
session broke in `socky` (M03), which has coverage.**

**3. The prompt fired far too rarely where it mattered.** Across the whole
`socky` stretch there were **five separate `[story] divergence` windows** and
only **three prompts** and **three fires** **(observed)**. The reason is in
the code: a prompt is raised only when a peer's **proximity detector** fires
an approach — and the detector only announces beats of the **current quest**,
within 35 m, and M03 has **exactly one** fireable beat **(code-verified,
WO-94 §3.4)**. So the prompt can only ever appear when one player happens to
walk within 35 m of that single point. From 16:21:21 to 16:35:42 the host was
stuck and the joiner advanced three times, and **the mechanism had nothing to
offer at any of them** — not because coverage is missing, but because
proximity to one authored point is the wrong trigger for "you two have
drifted apart".

**4. The divergence signal the mod already has is better than the one it
uses.** `[story] divergence: <peer> is on "X" -- you are on "Y"` is computed
on both machines, on every objective change, with no proximity condition, and
it was correct every single time tonight **(observed)**. It is reporting-only
by explicit design (`GameBridge.cs`: "nothing in this class gates on them,
deliberately").

**So the highest-priority next step is:** raise the readiness prompt from the
**story-divergence signal** rather than from beat proximity — the players are
demonstrably apart, tell them so and offer the catch-up — and only then extend
the fireable-beat registry into the prologue so that there is something to
offer when it fires. Coverage without a trigger that fires is what tonight
actually demonstrated.

Two things to carry into that work, both from tonight:

* **The catch-up destination is Warhorse's point, not the peer's** (Group D,
  now confirmed live). A prompt that fires more often will teleport players a
  few metres more often. Either say so on the prompt, or resolve the
  destination against the peer's position before firing.
* **"Decline / continue independently" should stop being a peer to "catch
  up".** WO-94 gives F12 equal standing and remembers the decline for the
  session. Under the new design principle it is an emergency exit, and the UI
  should say that.

---

## 6. Corrections to standing belief

* **WO-86 is field-confirmed, not suspect.** Its §5.1 listed the whole
  two-machine death path as unverified. Tonight verified it: exact damage,
  30–50 ms, death applied on the right tick, on both machines.
* **WO-78 is field-confirmed.** Its chain-leak detector fired once for real
  and the fix worked. WO-78 shipped synthetic-only.
* **WO-94's stand-off change is field-confirmed** at 180.3/181.9/181.7/180.9 s
  across four measured pairs.
* **WO-90's `DialogTwin_` exclusion is holding** — zero claims, zero syncs,
  all session.
* **WO-94's catch-up destination uncertainty is resolved**: it does land on
  Warhorse's fixed point. All three fires, both machines, the identical point.
* **"WO-90's divergence release is the jitter safety net" is too strong.** It
  covers the large rare divergence and is blind to the sustained sub-metre
  tug-of-war that a player actually perceives as jitter (item 7).
* **The NPC-sync packet cadence figures in any log before this session are not
  comparable to those after it** — they measured a different quantity (§3.4).
