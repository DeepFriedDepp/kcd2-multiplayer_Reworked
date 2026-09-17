# WO-98 — field-session diagnosis (2026-09-15, 0.22.4, protocol v6)

Source: host and joiner log bundles (`agent.log`, `kcd.log`,
`kcdmp-native.log`, `app20260915.log`, host `relay20260915.log`). Host id=0,
joiner id=1, session 20:26:37–20:44:53 host clock. Every number below was
re-derived from those files this session; where the prompt's figure
differed, both are given.

Evidence marks: (observed) from the logs · (code-verified) read in source ·
(synthetic) proven only under the MoonSharp/relay test harness ·
(inconclusive).

`kcd.log` has no wall clock. Mod lines were placed on each machine's clock
via the `[KCD2-MP-DATA] t` field anchored to the agent line that produced
`QUEST-DIVERGENCE #1` (host 20:33:47.156, joiner 20:33:51.967); joiner times
were then shifted by −4.75 s onto the host clock where stated.

---

## 0. Shipped privacy leak — fixed

* 0.22.4's launcher printed the build machine's profile path in a tester's
  crash trace (observed, joiner `app20260915.log` 19:49:00). Cause: the
  WO-97 end gate built from a clone under the maintainer's temp folder;
  Roslyn embeds source paths in PDBs and the PDB path in the DLL's debug
  directory. **Every** managed DLL and PDB in the shipped output carried it
  (14 files, checked in the surviving gate-clone output); the native
  `KCDMP.dll` carried none.
* Fix: `Directory.Build.props` at the repo root — `PathMap` rewrites the
  repo root to `/_/`, `Deterministic` on, SourceLink OFF. SourceLink was a
  second copy of the path: the .NET 8 SDK's implicit SourceLink writes a
  `{"documents":{"C:\Users\...\*":"https://raw.githubusercontent.com/..."}}`
  map into every PDB that PathMap does not touch (found only because the
  first test build was grepped).
* Verified: a forced exception in a test build prints
  `at Program.Main(String[] args) in /_/KCDMP_launcher/Program.cs:line 32`
  (observed); a full `Publish-Release.ps1` output (435 files) grepped for
  the profile path in UTF-8 and UTF-16: **zero** hits in any first-party
  file. Six third-party NAudio DLLs carry their own author's `\Users\` path
  — not ours, not fixable here, noted.
* Other leak classes checked: `install-manifest.txt` (relative paths only),
  `settings.json` (holds the tester's own game path — theirs, local, not
  shipped), `appsettings.json` (no paths), relay/agent `.deps.json` (none).
* **`app.ico` crash** (observed, same tester, same minute): `WindowIconFile:
  app.ico cannot be found`, thrown from `PhotinoWindow.WaitForClose`. Not a
  missing file — `app.ico` is in both release outputs. Code-verified against
  Photino.NET's `IconFile` setter: it probes `AppContext.BaseDirectory` when
  the relative name is not found but STORES the relative string, and the
  later startup-parameter check runs `File.Exists` against the working
  directory. So the launcher hard-crashed whenever started from any
  directory other than its own (the installer's shortcuts set `WorkingDir`;
  anything else — a terminal, a third-party launcher — did not). Fixed:
  absolute path, and a missing icon is now a warning, not a crash.
* Gate-clone vs working-tree release diff: only the expected 0.22.0→0.22.4
  deltas (`KcdMpClient.dll` grew by the embedded objective registry, PDB
  sizes, master-server appsettings) plus the path strings. Nothing else.

## 1. Clock skew is ~4.75 s, was 0.80 s

**Derivation reproduced** (observed), five independent ways:

| Pair | Host clock | Joiner clock | Apparent |
|---|---|---|---|
| host `rekni ptackovi` → joiner ghost line | 20:33:47.156 | 20:33:51.967 | +4.811 |
| joiner `rekni ptackovi` → host ghost line | 20:34:10.406 | 20:34:15.168 | −4.762 |
| host `nos pytle 05` → joiner | 20:35:22.136 | 20:35:26.949 | +4.813 |
| joiner `nos pytle 05` → host | 20:35:40.356 | 20:35:45.050 | −4.694 |
| relay `MooseSplosion connected` → joiner `Connected! Assigned id=1` | 20:26:37.800 | 20:26:42.611 | +4.811 |
| relay item-claim echo → joiner `claimed by ghost 0` | 20:31:21.850 | 20:31:26.663 | +4.813 |
| joiner `sent sync t=719737` → relay `clock sync -> 719737` | 20:26:48.073 | 20:26:52.753 | −4.680 |

Symmetric pairs give skew = (4.811+4.762)/2 = **4.787 s**, (4.813+4.694)/2 =
4.754 s, (4.813+4.680)/2 = 4.747 s; one-way propagation 25–66 ms (agent
poll cadence, not network). **Joiner's clock ahead of host's by ≈4.75 s.**
The prompt's arithmetic holds.

**WO-95's 0.80 s was not wrong** — its method (relay stamp vs joiner stamp,
one direction, LAN latency ≈1 ms) is sound and would have read 4.8 s on this
data. The skew grew ~4 s in two days: an unsynchronised Windows clock,
different problem from measurement error. It will keep drifting.

**Every cross-machine timestamp comparison in the stack** (code-verified):
there are none. Enumerated —
* Wire fields carrying time: `Ping/Pong` (own stamp echoed → RTT only),
  `TimeSkip` (game world-time, not wall). Nothing else.
* Ghost interpolation (`istate.lastPacketTime`, smoothing ring `at`), NPC
  puppet ring, `_ghostLastPos.AtUtc`, `_peerLastSeenUtc`: local receive time.
* Quest layer (`windowS`, `promptGapS`, `since`, `untilT`, catch-up hazard
  window, `_peerCatchup.AtUtc`): local clock.
* Fingerprint "newest save": `File.GetLastWriteTimeUtc` of LOCAL saves, used
  as a cache key, never compared to a peer.
* Relay claim expiry/hold, time-skip timeout, invite timeout: relay clock only.
* `WAITING_FOR_PEER` exits, hazard windows: event-based (convergence).
So the set "already wrong by ~5 s" is **empty**; the set "deliberately
event-based / receive-timed" is everything. Nothing was broken by the skew;
nothing could see it either. The parked snapshot-buffer smoothing (WO-75)
would be the first consumer of a sender timestamp — hence this phase.

**Landed:** `ClockSyncUp/Down` 0x39/0x3A, NTP-shaped, one sample per ping,
client-side running median of 15; `MP-CLOCK` line; `KCD2MP_SetClockOffset`
(shown beside the ping); `off=` on every agent.log line. Not applied to
anything. Synthetic wire test over loopback: offset 0.03 ms, RTT 0.19 ms,
unknown opcode skipped, Ping/Pong intact (synthetic). Not run across two
machines.

## 2. Every NPC claim went to the joiner — by design

* **78 grants, all `owner=1`** (observed; the prompt's 69 undercounts — 78
  `granted` + 55 `released expiry` + 23 `released disconnect` lines, 156
  `owner=` tokens). Zero `stale-owner` rejections; 5 `speed` rejections, all
  the joiner's.
* Code-verified, `ClientHandler.RouteNpcState`: `if (IsDamageAuthority(sender))
  return claimed && owner != sender ? MutedEcho : Broadcast;` — **the damage
  authority's packets never create claims**; its right to stream is the
  default. `DamageAuthority` = the lowest-id ready client = the host. The mod
  mirrors it: the authority emits `npc_state`, a non-authority emits
  `npc_claim` (`KCD2MP_NpcSyncTick`, `isAuthority = KCD2MP.hitSensorOn`).
  The host **never requested a claim** because it cannot; the relay never
  biased anything. Design intent (WO-39 Phase 2 / WO-60), documented in the
  router's own comment.
* Consequence worth stating: every NPC the joiner streams becomes a puppet
  on the host (its own stream for that name is muted). In the brawl the
  joiner claimed 15 names and the host streamed 15 others; each machine
  puppeted ~13–14 of the ~30 NPCs in the tavern (observed).
* The corroborating SWING asymmetry was read backwards in the prompt: a
  `SWING:` line in `kcdmp-native.log` is a swing RECEIVED from the peer and
  queued on the local ghost. Joiner native 212 SWING = the **host** swung
  ~210 times; host native 21 = the **joiner** swung 21. `[combat] sent hit`:
  host 43, joiner 7. The joiner was the one barely swinging — see §5.

## 3. Puppet vs local AI tug-of-war — confirmed, arbitration options

* Confirmed against source (code-verified): `KCD2MP_NpcPuppetTick` writes
  `SetWorldPos`/`SetWorldAngles` every 50 ms tick for every live puppet; the
  only arbitration is the WO-90 divergence release (≥8 m, 3 hits in 30 s →
  180 s stand-off). Below 8 m there is none: the local brain moves the body,
  the next tick drags it back.
* Observed: 272 (host) / 246 (joiner) `NPC-FIGHT` lines; these are
  **throttled to one per 5 s per NPC**, so the true event counts are the `n=`
  values — max n=1248 host, **1826** joiner (the prompt's figure is the
  joiner's). Displacements: <0.10 m 101/95, 0.10–0.25 24/35, 0.25–0.5 12/10,
  0.5–1.0 57/24, 1–8 m 53/57, ≥8 m 25/25 (host/joiner). Top NPCs:
  `ttkc_inkeeper` 43/51 lines, `tsla_man_2` 37, `ttkc_man_18` 36/14,
  `ttkc_woman_1` 19/27. Sustained, every tick, exactly as the prompt reads it.
* Prior work on this class (corpus): WO-40 Phase 5 (the counter), WO-69
  (threshold 0.75 m→5 cm, "D2 would act at walking pace"), WO-77 (interp-
  behind rendering), WO-90 (the 8 m release). WO-95's crouch-toggle finding
  is the same shape — a per-tick write versus the engine's own state for the
  same body. Nothing in the corpus arbitrates sub-8 m contention.
* (a) **Should the mod stop writing on sustained sub-8 m opposition?** A
  proportional option exists that the corpus has not tried: when the readback
  displacement stays >0.3 m for N consecutive ticks, stop writing position
  for that puppet and only re-assert on packets that move the target >1 m
  ("yield to the brain while it is walking, re-pin when the stream says so").
  Risk: an NPC the peer is fighting walks off on this machine — the WO-51
  "unsuppressed puppet brain" gap, made visible instead of jittery. Not
  landed: it needs live A/B, and this WO is diagnosis.
* (b) **Suppress the local AI for a puppet?** Lua has no lever (WO-21
  behaviour trees inert; `Activate(false)` pilot never ran, WO-64). Native:
  `DisableSituationParticipation` exists as a script context (§4) but covers
  social situations, not locomotion; a brain-suppression context was not
  found in `ScriptContext.xml`. Out of scope, native, WO-99 candidate.
* Did the 180 s release help? Both states are in the logs: 8/7 releases
  (host/joiner), each ending the stutter for that NPC by handing it to the
  local world — and each producing a desynced NPC for 3 minutes (the
  released name is refused re-puppeting). The release also fired on
  `ttkc_man_3` on the host (20:33:20, 10 m) which then ran its own guard
  tree — see §4. It traded stutter for divergence, as designed; it did not
  reduce the sub-8 m contention at all (it cannot see it).

## 4. The post-brawl engine AI storm — one target confirmed, one reduced, one re-attributed

Line-rate windows reproduced (observed; joiner, own clock):

| Window | prompt | measured | dominant classes (per s) |
|---|---|---|---|
| 20:32:22–20:33:52 | 66.9 | 66.8 | MP-DATA 36.6, other 15.8, facial-anim validator 6.3, MP-EVT 4.0 |
| 20:33:52–20:35:27 | 58.1 | 58.1 | MP-DATA 34.7, other 12.2 |
| 20:35:27–20:38:48 | 60.2 | 60.2 | MP-DATA 37.0, other 9.8, MP-EVT 3.5 |
| **20:38:48–20:40:22** | 118.9 | **119.9** | MP-DATA 35.6, other 29.3, **MP-EVT 21.4**, PickUpRight 6.8, BT-move 5.2, AnimFramePose 5.1 |
| 20:40:22–20:44:53 | — | 90.7 | MP-DATA 31.4, **PickUpRight 22.0**, other 14.6, MP-EVT 10.1 |

The host shows the same jump (65 → 137.6/s in the same window).

**Correction to the prompt's premise "not mod traffic":** of the joiner's
+60 lines/s, **+18/s is the mod's own `npc_claim` EVT lines** — the joiner
claiming the brawl NPCs (§2). It is not the majority (+42/s is engine), but
it is the single largest class change and it is ours.

**Target A — `ttkc_man_3`: confirmed as the dominant NPC, re-attributed.**
4,408 error lines on the joiner, 2,982 on the host (the prompt's 6627/4503
count every mention). **Not greeting-sync**: only 11/20 lines are
`situation_greeting_synchronization`. The loop is
`[ActionExecutor]: Can't execute action PickUpRight. Starting of the action
failed!` from `(BT)guard_postBehavior/guardNonImportantContinual` — a guard
profession tree trying to pick something up, three error lines per attempt,
16–18 attempts/s. `ttkc_man_2` (654 host) runs the same tree. Onset **both
machines 20:39:5x** (host clock), right after the brawl, before the pillory
cutscene; never recovers (900/min on the host at 20:43).

Mod-induced or stock? Evidence (observed): on the **host** `ttkc_man_3` was
NOT puppeted during the storm (joiner's claim expired 20:36:18; the host
emitted `npc_state` for him, i.e. he was locally driven) — so the host's
half of the storm is the engine failing in its own world. On the **joiner**
he WAS a puppet through the storm (7 `puppet start` lines 20:40–20:42) and
failed identically. Item sync ruled out (the session's four synced drops
were 350 m away, nine minutes earlier). No solo log exists to compare; the
earlier same-day MP runs (`logbackups`) show 0 and 2 PickUpRight lines. One
mod-induced instance IS on record: at 20:32 the host puppeted him and he
threw 8 PickUpRight failures during exactly those 10 puppet-anim ticks.
**Verdict: a stock guard-tree failure triggered by the post-brawl state
(present on an unpuppeted NPC), which puppeting also provokes; the
post-brawl storm itself is not ours. Not worth chasing further here.**

**Target B — the ghost in the SituationController: confirmed, but tiny.**
`Registering NPC kcd2mp_1 for situations` 40× on the host, `kcd2mp_0` 42×
on the joiner (observed) — a soul-backed ghost (WO-22) is a real NPC to the
situation system, and the engine assigns it gossip/greeting/storyteller
roles. But the ghost's behaviour-tree error lines number **4 (host) / 9
(joiner) for the whole session** — the prompt's 244/408 `kcd2mp_` counts are
overwhelmingly the mod's own lines. It is real and it is not the storm.
WO-90 cross-check: WO-90's exclusion (`IsNeverSyncedNpcName`) is the
opposite direction — it stops the MOD adopting ENGINE entities (`DialogTwin_*`);
nothing stops the engine adopting ours. The existing native isolation
(WO-68, `KCDMP.dll` `kIsolationContexts`, all eleven applied-and-verified
in both native logs) covers crime/awareness contexts only. **The lever
exists**: `Tables.pak :: Libs/Tables/ai/ScriptContext.xml` has
`<ScriptContextDatabaseNode Name="DisableSituationParticipation"
Class="Entity" SideEffect="disableSituationParticipation"/>`. Adding that
row to the compiled list (or to `kcdmp-contexts.txt`, the file override the
DLL already reads) would take the ghost out of situations through the
shipped, live-verified SCTX path. It is a native-DLL change (maintainer-
deploy only) → **WO-99 candidate, not done here**.

Why does a cutscene amplify it? Not established. The registration lines
are spread through the session (registered/unregistered 479× each in the
post window for ttkc_* NPCs), and the storm's onset is post-BRAWL, not post-
cutscene: the pillory cutscene (socky_6, 20:39:51 host clock) starts ~10 s
after the failures begin. Hypothesis "cutscene exit re-registers everyone"
is (inconclusive); the data fits "the brawl's end leaves guards trying to
pick up" better.

Frame-budget cost — **measured, and it is not there**: the mod's emit tick
spacing (a frame-time proxy; `[KCD2-MP-DATA] t` deltas) on the joiner was
26–29 ms mean / 33–35 ms p95 through the brawl and the storm's first
minute, identical to the 20:32 baseline (28.3 ms); the host 25–31 ms. The
only gaps are cutscene/menu suspensions (2.5–16 s, at cutscene edges). So
the post-cutscene "jitter far worse than before" did not come from a
saturated frame loop on either machine (observed). It is most plausibly the
§3 tug-of-war over ~14 puppets per machine at brawl density, plus the
NPC-DIVERGE releases (8/7) making some NPCs diverge outright.

**Target C — peer name in toasts: re-attributed.** No `kcd2_tctk`-like
string exists in any log (observed). All toast text was built at eight call
sites and logged at none. Of the toasts that fired this session (WAITING
entered 5/4, QUEST-GAP 4/6, NPC-DIVERGE 8/7 releases → ≤8 toasts at the
60 s throttle), exactly one led with an NPC entity name:
`"KCD2-MP: ttkc_inkeeper is at a different point in your friend's story --
following your own quest instead"` (the NPC-DIVERGE toast, `KCD2MP_ShowNativeToast`
at the release site). "KCD2-MP: ttkc_…" read at a glance is the reported
string. **Not downstream of Target B** — the ghost's soul name never reaches
a toast; the agent's display names (`_ghostNames`) are correct everywhere
they are used. Fixed: the toast names the peer, puts the NPC last, is
suppressed while the quest layer's own row/prompt already explains the
divergence, and fires at most once per 5 min; every toast now logs
`MP-TOAST text="…"`.

## 5. Cutscene state — was unsynced and uninstrumented; joiner lockout inconclusive

* **Instrumentation existed and never fired.** WO-94 wired
  `CutsceneStateChanged` → `OnLocalCutscene`, but (a) the tail tracks only
  `Rendered` cutscenes and every quest cutscene this session was `Ingame`
  (`socky_2_gate` … `socky_7_bergov`, 7 pairs per side, plus one 0-length
  Rendered `m03_trosky_journey`), and (b) the log line was gated on an open
  catch-up window. Result: zero cutscene lines in either agent.log
  (observed). Landed: every Rendered/Ingame edge logged locally, sent to
  peers (StoryBeat kind 6), logged with the peer's state, pushed to the mod.
  No Lua read for "is a cutscene playing" exists in the vendor scriptbind
  docs (`Movie` has Play/Stop/Pause only), so log-tail detection stays the
  mechanism.
* Cutscene timeline (host clock; joiner shifted −4.75 s):

  | Cutscene | Host | Joiner |
  |---|---|---|
  | socky_5_departure | 20:33:10–20:33:14 | 20:33:17–20:33:23 |
  | brawl (first/last SWING received on the other side) | host swings 20:38:47–20:39:5x | joiner swings 20:39:19–20:39:5x |
  | socky_6_pillary | 20:39:57–20:39:59 | 20:39:51–20:39:57 |
  | socky_7_bergov | 20:40:10–20:40:14 | 20:41:10–20:41:13 |

  "The host's cutscene ended first" holds for socky_5 (10 s) and socky_7
  (60 s — the host had already been through the pillory scene and dialogue
  a minute earlier). For socky_6 the joiner was 6 s ahead.
* **Joiner lockout — (inconclusive), with two candidates ruled out.**
  Saturation: ruled out by the tick-spacing measurement above. "Cutscene
  input lock not released": the joiner's Dude issued attacks
  (`Skirmish event: Attack on Dude` 11×, hits received 24) between 20:39:19
  and 20:39:5x, after socky_5 and before socky_6, so input was live; it
  simply produced 21 swings/7 hits against the host's ~210/43. What the
  joiner log does show: `Player: Combat player controller requested end of
  combat due unlocking` **33×** (host 19×) and `Dude: Requested combat
  termination: No main action` 10× — the combat lock kept dropping. The
  joiner's targets (`tsla_man_2`, `ttac_man_6`) were its OWN claims, not
  puppets, so puppet writes breaking the lock does not explain it either.
  Cause not determinable from these logs; the new `MP-KEY`, `MP-SWING` and
  `MP-DMG` channels plus the cutscene lines are what the next session needs.
* **Co-op cutscene gating (maintainer's Halo proposal) — assessed.** What is
  needed: (1) both machines know a cutscene started — landed (kind 6);
  (2) a way to HOLD a cutscene until the peer confirms — none found in the
  vendor scriptbind docs (`Movie.PauseSequences/ResumeSequences` exist and
  are unprobed; whether an `Ingame` quest cutscene is a Movie sequence is
  unknown); (3) a way to gate skip on both confirming — the skip input is
  engine-side, no Lua surface seen. Feasibility: (1) is done, (2) is a live
  probe of `Movie.PauseSequences` at a cutscene edge (cheap, but a live test
  → next session), (3) is probably native. Hard constraint restated: with
  4.75 s of skew, nothing can be aligned on timestamps until §1's offset is
  consumed; the kind-6 edge messages are event-based and do not need it.
* **F11 in the cutscene.** The prompt was shown 20:40:21 (joiner clock) and
  withdrawn on convergence 20:41:21; zero `CATCHUP`/`QuestFire`/`MP-KEY`-
  equivalent lines in between (observed). The F11 path is
  `Player.Client.OnAction` → `handleAction` → `KCD2MP_QuestAnswer`; the
  action is `kcd2mp_dice_bank` in the `interaction` action map. Loss point:
  (inconclusive) — most likely the engine not delivering `interaction`-map
  actions during a cutscene (socky_7 ran 20:41:14–20:41:17 inside the
  window), but no line proves where the press died. Decision: **queue**.
  A prompt arriving during a cutscene is parked and re-offered when it
  ends; a prompt that is up when a cutscene starts is hidden and returns;
  `mp_quest_yes` is refused mid-cutscene (a Haste trigger during a cutscene
  is WO-97's hazard class); every F11/F12 that reaches the hook is logged
  with the state it landed in. Synthetic-verified (50/50).

## 6. Instrumentation — landed

See `docs/WO-98-log-format.md`. Structured, `key=value`, one event per line:
`MP-CLOCK`, `MP-CUTSCENE`, `MP-KEY`, `MP-TOAST`, `MP-SCREEN`, `MP-NPCFIGHT`,
`MP-NPCDIVERGE`, `MP-SWING`, `MP-DMG`, `MP-GHOSTPKT` (+`-RAW` under
`KCDMP_LOG_LEVEL=verbose`), `MP-SUMMARY`, `MP-SUMMARY-MOD`; the mod clock on
every `mp_log` line; monotonic ms and relay offset on every agent line.
Authority transitions were already structured at the relay (`[CLAIM]`,
`[WO66-REJECT]`) and are documented rather than duplicated. Net steady-state
volume ≈ neutral (estimate in the format doc; not measured live). Gaps
stated there: no cross-machine swing correlation id (needs a wire field), no
"fragment actually played" signal from the native side.

## 7. Notification cadence

* Re-arm confirmed as the source (code-verified): `RepushQuestDivergences()`
  ran inside the 2.5 s re-arm block for as long as any peer's marker
  differed; the mod logged `QUEST-DIVERGENCE #n` on every receipt (48/51
  lines per side, ten in 21 s at t=1084.6…1106.3 — observed).
* What the mod did on each receipt: for an unchanged pair, **nothing
  visible** — `Q.waiting[id].key == key` returns "waiting" with no toast and
  no row change (code-verified). So the 50 lines were log noise only; the
  on-screen volume was WAITING toasts (5/4, on `rel` change), QUEST-GAP
  toasts (4/6) and NPC-DIVERGE toasts (≤8/7). The maintainer's "noisy" is
  most plausibly the NPC-DIVERGE toast (per-NPC, 60 s throttle, led with an
  NPC name) — the objective-level noise. Beat-level (WAITING/QUEST-GAP)
  toasts fired once per pair change, which is what he found useful.
* Decision: re-push on `MOD INIT` (tail event) + a 60 s heartbeat instead of
  every 2.5 s; the mod logs an unchanged re-push as one counter line per
  minute. NPC-DIVERGE toast: peer-named, suppressed while the quest layer's
  row/prompt is showing, 5 min throttle. Beat-level toasts unchanged.

## 8. Confirmed working — do not "fix"

Save-derived fingerprints (parsed 14–48 ms, 8 objectives, correct every
time, both sides); objective naming in live gaps (`Carry the sacks to the
pantry.`, `Defend Capon!`); honest no-fix reporting (`QUEST-GAP no narrow
trigger exists … reported only`); Phase 3 fix gating (`fix not considered:
we are not in svatba`); `WAITING_FOR_PEER` enter/exit on convergence (23 s,
19 s, 2 s). Also, from this analysis: the mod's emit tick held 26–29 ms
through the brawl on both machines; WO-86's damage path applied 43/43 hits
on the joiner and 9/9 on the host.

## Deviations

* **Dropped:** adding `DisableSituationParticipation` to the native
  isolation list — the lever is real and one line, but it is a native-DLL
  change under this WO's no-native rule. Recorded as WO-99 candidate 1.
* **Dropped:** the sub-8 m yield arbitration (§3a) — small to write, but not
  "clearly right" without a live A/B; the field could lose fighting NPCs to
  their own brains.
* **Taken:** a synthetic wire test against the built relay for Phase 1
  (loopback only) — the only way to prove the exchange without two machines.
* **Taken:** `Test-WO98Synthetic` added to the MoonSharp suite family.
* **Corrected premises** (stated in place): the SWING asymmetry direction;
  "not mod traffic"; `ttkc_man_3` as greeting-sync; `kcd2mp_` reference
  counts as Target B evidence; "no cutscene instrumentation exists"
  (existed, never fired); 69 grants (78).

## WO-99 candidates

1. Native: add `DisableSituationParticipation` to `kIsolationContexts` and
   read back; then re-measure the ghost's situation lines (expect 0).
2. Live: probe `Movie.PauseSequences/ResumeSequences` at an `Ingame` cutscene
   edge — the only found lever for co-op cutscene holding.
3. Wire: a swing correlation id on CombatEventUp/Down + a native "fragment
   started/ended" report, to close the swing-path trace.
4. Puppet yield arbitration for sustained sub-8 m contention (§3a), live A/B
   behind a toggle.
5. Count-and-log the dropped swing-without-entity case (`no_entity`).
6. Consume the clock offset: snapshot-buffer smoothing (WO-75) on sender
   time; cutscene edge alignment.
