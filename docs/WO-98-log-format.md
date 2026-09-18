# WO-98 — log format reference

Structured channels added or converted in WO-98. One event per line, stable
`key=value` fields in a fixed order, no free prose inside a field. A value
that can contain spaces is double-quoted (`who="..."`, `text="..."`); a
double quote inside a quoted value is folded to `'`. Counts are integers,
distances metres, times milliseconds unless the key says otherwise.

The human-readable lines these sit beside (`NPC-FIGHT ...`, `[combat] sent
hit ...`, `QUEST-DIVERGENCE #n: ...`) are unchanged in shape and remain the
thing to read; the `MP-*` lines are the thing to parse.

## Where each file's lines are stamped

| File | Written by | Per-line stamp (WO-98) |
|---|---|---|
| `kcd.log` | engine + mod (`System.LogAlways`) | mod lines written through `mp_log` end with ` t=<s>.<ms>` = `os.clock()` on that machine (monotonic since process start). A handful of init-time lines (`=== MOD INIT ===`, hook confirmations) bypass `mp_log` and carry no stamp. Engine lines carry none. |
| `agent.log` | agent (`TeeTextWriter`) | `HH:mm:ss.fff m=<ms since agent start> off=<relay clock minus this clock, ms, or ?> <text>` |
| `relay<date>.log` | relay (Serilog) | `yyyy-MM-dd HH:mm:ss.fff zzz [LVL] <text>` (unchanged). The relay's clock is the host's. |
| `kcdmp-native.log` | KCDMP.dll | `[HH:mm:ss.fff]` (unchanged) |

**Cross-machine correlation.** `off` on a joiner's agent lines is the
host-vs-joiner wall-clock skew (the relay runs on the host). host_time =
joiner_time + off_joiner − off_host (off_host ≈ 0 over loopback). Until the
first sample lands `off=?`; the first `MP-CLOCK` line gives the moment it
became known.

## Channels

### MP-CLOCK — clock offset (agent.log)
`MP-CLOCK offset_ms=<F1> rtt_ms=<F1> n=<int> sample_offset_ms=<F1> sample_rtt_ms=<F1>`

`offset_ms` and `rtt_ms` are running medians of the last 15 samples;
`sample_*` is the sample that triggered the line; `n` is samples so far.
Written on the 1st and 5th sample and every 30 s after. Positive offset =
relay (host) clock is ahead of this machine's. Measurement only; nothing
consumes it (Phase 1).

### MP-CUTSCENE — cutscene edges (agent.log and kcd.log)
agent, own machine:
`MP-CUTSCENE side=local state=start|end type=Rendered|Ingame|Fader|Text|SkipTime name=<engine name> peers=<id:0|1,...>|- acted=0|1`

`acted=1` only for Rendered/Ingame (peer beat sent, prompt held). WO-99
Phase 4 added the other three as log-only edges, because a loading fade or
a sleep is what sits inside an unexplained emitter gap (2026-09-16: all 18
cutscene lines were Fader, so the channel was correctly silent and the
gaps had no marker).

agent, a peer's machine (StoryBeat kind 6):
`MP-CUTSCENE side=peer ghost=<id> who="<display name>" state=start|end type=<type> name=<name> local=0|1`

mod (kcd.log), own machine, state AFTER the edge was applied:
`MP-CUTSCENE side=local state=start|end name=<name> peers=<id:0|1,...>|- prompt=0|1 pending=0|1`

Only `Rendered` and `Ingame` edges act (WO-80's reasoning: the others are
not what a player experiences as a cutscene); all five types are logged
locally. Source is the engine's own `CutscenePlayer::PlayCutscene` /
`OnCutsceneEnd` lines.

### MP-KEY — prompt keys (kcd.log)
`MP-KEY action=kcd2mp_dice_bank|kcd2mp_dice_yield prompt=0|1 pending=0|1 waiting=0|1 cutscene=0|1 dice=0|1`

One line per F11/F12 press that actually reached the mod's `OnAction` hook,
with the state it landed in. A reported press with no `MP-KEY` line means
the engine never delivered the action to Lua.

### MP-TOAST — on-screen toasts (kcd.log)
`MP-TOAST kind=native|msg|dice text="<final string>"`

`native` = the HUD info-text toast (`ShowInfoText`), `msg` = the DrawText
interaction message row, `dice` = the dice overlay's `say()`. This is the
first record of what a player actually saw.

### MP-SCREEN — persistent DrawText rows (kcd.log)
`MP-SCREEN row=<key> text="<string>"`

Logged when a row's text CHANGES, and once with `text=""` when the row
stops being drawn. Never per frame. Rows whose visible text carries a
per-second countdown (`invite`, `quest_window`) log the text without the
countdown. Keys: `invite`, `invite_keys`, `msg`, `dice_turn`,
`quest_prompt`, `quest_prompt_keys`, `quest_window`, `quest_waiting`,
`quest_gap`. The ping row is not logged.

### MP-NPCFIGHT — puppet vs local AI (kcd.log)
`MP-NPCFIGHT npc=<name> n=<int> mean_m=<F2> max_m=<F2> window_s=<F0> total=<int> authority=peer`

Per puppeted NPC, flushed when a displacement event arrives ≥10 s after the
window opened: `n` displacements >5 cm between our write and the readback
one tick later, their mean and max, and the lifetime `total` for that
puppet. A window is flushed only by a later event, so the last partial
window of an episode is not reported (the totals are, in `MP-SUMMARY-MOD`).
`authority=peer` is structural: a puppet is by definition driven by a
peer's stream. The prose `NPC-FIGHT ... displaced ...` line stays, throttled
to one per 30 s per NPC (was 5 s).

### MP-NPCYIELD — sub-8 m yield arbitration (kcd.log, WO-99 Phase 2)
`MP-NPCYIELD npc=<name> state=yield disp_m=<F2> streak=<int> fight_n=<int> total_yields=<int> total_repins=<int>`
`MP-NPCYIELD npc=<name> state=repin target_moved_m=<F2> body_off_m=<F2> yielded_s=<F1> total_yields=<int> total_repins=<int>`

`yield`: the readback displacement stayed above `dispM` (default 0.30 m)
for `ticks` (default 10) consecutive 50 ms ticks; the puppet gets no more
position/angle/anim writes. `repin`: an inbound packet moved the stream
target more than `repinM` (default 1.0 m) from where it was at yield time;
`body_off_m` is how far the body had wandered from the new target, and the
render position is re-seeded from the body. Toggle `mp_npc_yield_on|off`
(default on); thresholds `#KCD2MP_SetNpcYield("dispM ticks repinM")`.
`MP-NPCFIGHT` stops counting a yielded puppet (nothing is written to
measure against), so a live A/B reads as: fewer NPCFIGHT events, NPCYIELD
lines appearing.

### MP-POSCADENCE — position sample cadence (agent.log, WO-102 Phase 1)
`MP-POSCADENCE path=log|native n=<int> mean_ms=<F1> p50_ms=<int|>=2000> p95_ms=<int|>=2000> max_ms=<F0> window_s=<F0>`
`MP-POSCADENCE path=log|native n= mean_ms= p50_ms= p95_ms= max_ms= scope=session`

Sample-to-sample intervals of fresh local position samples, per source.
`path=log` = a new `[KCD2-MP-DATA]` seq seen by the agent; `path=native` = a
new DLL frame read over pipe `0x0A`. Both are measured whenever they have
samples (the log path always; the native path only while
`mp_pos_native_on` and not refused), so one session with the native path on
yields both distributions. 1 ms buckets, exact percentiles; intervals
across a suspension (menu, load, toggle flip) are not counted. The
`scope=session` lines ride in `MP-SUMMARY`.

### MP-POSNATIVE — native position path verdicts (agent.log, WO-102 Phase 1)
`MP-POSNATIVE verdict=gave-up after=20 refused= module_missing= no_player= hop_unmapped= faulted= nonfinite= vtable= no_answer=`
`MP-POSNATIVE verdict=refused reason=oracle-mismatch run= last_delta_m= native=(x,y,z) log=(x,y,z)`
`MP-POSNATIVE oracle n= delta_mean_m= delta_max_m= bad_run= active=0|1`

`gave-up`: 20 consecutive DLL refusals/no-answers -- the reason histogram
says why (an older DLL shows as `no_answer`). `refused`: the known-answer
check failed -- 20 consecutive native samples more than 3 m from the log
line's position. `oracle`: every 30 s, the native-vs-log position delta
(the log sample can lag by a few frames, so a delta well under 1 m is the
healthy reading). `[pos]` lines carry `path=log|native`.

### MP-AUTHORITY — NPC ownership transitions (kcd.log, WO-102 Phase 2)
`MP-AUTHORITY npc=<name> event=acquire|release|owner-change owner=<self|ghostId|?> via=<how> held_s=<F1> model=claim|host [from=<ghostId>]`

One line per change of who drives a world NPC on THIS machine. `owner=self`
is this client (it streams the body); a number is the peer ghost id whose
inbound stream drives it as a puppet; `?` means the agent predates WO-102
and sent no source id. `via` on `acquire`: `authority-default` (this client
is the damage authority and began streaming it), `claim` (a non-authority
began a WO-60 proximity claim stream), `drag` (the WO-39 drag sensor),
`stream` (an inbound stream made it a puppet), `repin` (a yielded puppet
re-pinned). `via` on `release`: `untrack`, `drag-idle`, `silence` (WO-32
3 s release), `diverge` (WO-90), `yield` (WO-99). `owner-change` is an
existing puppet whose packets now arrive from another sender -- a claim
moved at the relay; `from=` is the previous owner. `held_s` is how long the
previous owner held it. `model` is the WO-102 toggle state at the time.
Counted into `MP-SUMMARY-MOD` as `auth_acquire= auth_release=
auth_owner_changes= auth_model=`.

Under host authority (`model=host`) a non-authority must only ever log
`acquire ... via=stream` from the one authority and never `owner-change`;
any `via=claim`, `via=drag` or `owner-change` under `model=host` is a
violation, not traffic.

### MP-AUTHORITY-VIOLATION — a second writer under host authority (kcd.log, WO-102 Phase 4)
`MP-AUTHORITY-VIOLATION npc=<name> kind=diverge|contention dist_m=<F2> owner=<ghostId|?> paused=0|1 n=<int>`

Only under `mp_authority_host_on`. `diverge` = the WO-90 rule fired (≥ 8 m
in one tick) and was refused instead of releasing; `contention` = the WO-99
yield rule fired (> 0.30 m for 10 ticks) and was refused instead of
yielding. `paused=1` = the pause lever had issued `wh_ai_PauseNPC` for this
body, so the writer is not the brain the lever addresses. One line per NPC
per 10 s; `n` is the exact per-NPC count; `auth_violations=` in
`MP-SUMMARY-MOD` is the session total. `event=pause|resume` on
`MP-AUTHORITY` records the lever (`via=wh_ai_PauseNPC` / the release
reason). `WO102-AUTHORITY scan anchors= cap=` records the authority's
anchor count when it changes.

### MP-REQUEST — the request channel (agent.log, WO-102 Phase 5)
requester: `MP-REQUEST dir=out kind=attack target=<name> <attack payload> gen=<gen> resolve=damage-path`
requester: `MP-REQUEST dir=out target=<name> result=resolved via=damage-sent dt_ms=<F0>` | `result=unresolved after_ms=1500 (no blow landed here)`
owner:     `MP-REQUEST dir=in from=<ghostId> kind=attack <attack payload> target=<name> seq= gen= dispatch=logged-awaiting-damage resolve=damage-path`
owner:     `MP-REQUEST dir=in from=<ghostId> target=<name> result=resolved via=damage-path dt_ms=<F0>` | `result=unresolved after_ms=1500`
owner:     `MP-REQUEST dir=in from=<ghostId> kind=attack … result=refused reason=host-authority-off|not-owner|target-not-owned|malformed-name`
summary:   `MP-REQUEST section=summary out= out_resolved= out_unresolved= in= in_resolved= in_unresolved= in_refused=`

Only under `mp_authority_host_on`. A request is a non-owner's committed
attack at the owned NPC it is facing (`npc_target`, nearest live puppet
within 4 m); it resolves through the existing name-addressed damage path
(`0x30`), and `dt_ms` is the request-to-damage gap on each side.

### relay `[CLAIM]` lines (relay log, WO-81 + WO-102 Phase 2)
`[CLAIM] granted npc= owner= pos=(x,y,z)` -- a non-authority's first accepted packet for an unclaimed name (WO-81).
`[CLAIM] muted npc= owner= authority= claimAgeSec=` -- **WO-102**: the damage authority's own stream for a claimed name was dropped for the first time under this claim. This is the authority's implicit request being denied, which WO-98 §2 could not see. Once per claim; every muted packet is counted (`AuthorityMutedPackets` at `GET api/information/npc-claims`).
`[CLAIM] released npc= owner= reason=expiry heldForSec= packets= silentSec= noticedBy=` -- **WO-102** adds `packets=` (the owner's accepted refreshes), `silentSec=` (how long the owner had been silent when a packet for the name finally arrived and noticed the expiry) and `noticedBy=` (whose packet noticed it).
`[CLAIM] released ... reason=disconnect ... packets=`.
`[CLAIM] reassigned` / `[CLAIM-CONTESTED]` unchanged (WO-81). Denials stay on `[WO66-REJECT] stale-owner|speed|reserved-name`.

### MP-NPCDIVERGE — divergence release (kcd.log)
`MP-NPCDIVERGE npc=<name> dist_m=<F1> hits=<int> window_s=<F0> standoff_s=<F0> total=<int>`

One per WO-90 release (the puppet is handed back to the local world for
`standoff_s`). `total` = releases this session.

### MP-SWING — swing path hops (agent.log)
sender: `MP-SWING hop=sent sid=<int>`
receiver: `MP-SWING hop=recv rsid=<int> sid=<int> ghost=<id> entity=0x<hex> spec="<fragment spec>"`
receiver: `MP-SWING hop=queued rsid=<int> sid=<int> ghost=<id> ok=0|1`

`sid` counts swings this machine sent and, since WO-99 Phase 4, travels
on the wire (CombatEventUp/Down v2, `[sid:2]`), so the receiver's `sid` is
the SENDER's counter: `hop=sent sid=N` on one machine matches `hop=recv
sid=N` on the other. `sid=0` on a receiver = a v1 sender. `rsid` still
counts swings this machine received and ties `recv` to its `queued`
outcome. The native side's `SWING:
entity=... queued fragment ...` line in `kcdmp-native.log` is the
"fragment queued" hop; whether the animation then PLAYED is still
unrecorded (nothing on the native side reports fragment start/end).

### MP-DMG — shared combat damage (agent.log)
`MP-DMG dir=out npc=<name> hp=<F1> st=<F1> fatal=0|1 authority=0|1`
`MP-DMG dir=in ghost=<id> npc=<name> hp=<F1> st=<F1> fatal=0|1 result=applied|nosoul|nodelta|failed authority=0|1`
`MP-DMG dir=drop npc=<name|?> hp=<F1> st=<F1> fatal=0|1 reason=local_player|local_player_name|echo|echo_fatal authority=0|1` (WO-99 Phase 0)
`MP-DMG dir=in ghost=<id> npc=<name> hp=<F1> st=<F1> fatal=0|1 result=refused reason=local_player|local_player_name authority=0|1` (WO-99 Phase 0)

`drop` = the DLL reported a local hit that this client refused to send:
`local_player` = the soul is the local player (by PlayerSoul guid),
`local_player_name` = same by soul name only (guid not yet re-read after a
save load), `echo` = the value matches an inbound hit applied within 300 s,
`echo_fatal` = a FATAL for a name whose death was applied from a peer within
300 s. `refused` = an inbound 0x31 whose name resolved to this machine's
own player soul. `[dmgguard] local player soul guid=... name=...` is logged
on connect and whenever the identity changes.

`authority` = whether THIS agent is the relay's damage authority at that
moment (the lowest-id ready client). The NPC's claim holder at the moment
of the hit is only known at the relay (`[CLAIM]` lines).

### MP-GHOSTPKT — ghost motion (agent.log)
`MP-GHOSTPKT ghost=<id> n=<int> ia_mean_ms=<F1> ia_max_ms=<F1> d_mean_m=<F2> d_max_m=<F2> snaps=<int> stale=<int>`

Per ghost per ≥10 s window (flushed by the next packet): inbound Ghost
packets, inter-arrival mean/max, position delta mean/max, and `snaps` =
deltas over 5 m. With `KCDMP_LOG_LEVEL=verbose` in the agent's environment,
every packet also writes
`MP-GHOSTPKT-RAW ghost=<id> ia_ms=<F1> d_m=<F3> snap=0|1 stale=0|1` — the snapshot-
buffer tuning data; ~4 lines/s per ghost, off by default.

`stale` (WO-99 Phase 1) counts packets carrying the Position/Ghost flag bit
0x02: the sender's mod emitter was halted (menu, loading, cutscene,
dialogue) and its agent re-sent the last known position at the 2 s
heartbeat. A gap that is all stale packets is "the peer is paused", not
"the peer is gone"; the sender logs `[pos] mod emitter silent -- sending
stale heartbeats until it resumes` / `[pos] mod emitter resumed after N
stale heartbeat(s)` at the edges.

### Authority transitions (relay log, pre-existing, unchanged)
`[CLAIM] granted npc=<name> owner=<id> pos=(x,y,z)`
`[CLAIM] released npc=<name> owner=<id> reason=expiry|disconnect heldForSec=<F1>`
`[CLAIM] reassigned npc=<name> prevOwner=<id> newOwner=<id> gapSec=<F1>`
`[WO66-REJECT] stale-owner '<name>' (id=<id>) npc '<npc>': claimed by another client.`
`[WO66-REJECT] speed '<name>' (id=<id>) npc '<npc>': implausible movement.`

There is no claim *request*: a non-authority claims by sending
`NpcStateUp`, so "requested" = the first accepted packet = `granted`, and
"denied" = `stale-owner`. The damage authority's own packets never create
claims (docs/WO-98-findings.md s2).

### MP-SUMMARY — per-connection summary (agent.log, on disconnect and every 300 s)
```
MP-SUMMARY section=session reason=<str> duration_s=<F0> agent_lines=<int> agent_lines_per_s=<F2> clock_offset_ms=<F1|?> clock_rtt_ms=<F1|?> clock_samples=<int>
MP-SUMMARY section=ping pongs=<int> rtt_min_ms=<F0> rtt_avg_ms=<F1> rtt_max_ms=<F0>
MP-SUMMARY section=swings sent=<int> recv=<int> queued=<int> failed=<int> no_entity=<int>
MP-SUMMARY section=position stale_out=<int> ghost_stale_in=<int>
MP-SUMMARY section=damage out=<int> out_fatal=<int> out_dropped=<int> in=<int> in_applied=<int> in_failed=<int> in_refused=<int> authority=0|1
MP-SUMMARY section=npc state_out=<int> claim_out=<int> drag_out=<int>
MP-SUMMARY section=story divergences_pushed=<int> cutscene_local_edges=<int> cutscene_peer_edges=<int> ghost_packets=<int>
MP-SUMMARY section=ghost ghost=<id> packets=<int> ia_mean_ms=<F1> ia_max_ms=<F1> d_mean_m=<F2> d_max_m=<F2> snaps=<int> stale=<int>
```
WO-99 Phase 4: the block is also printed every 300 s with `reason=periodic`
(counters are cumulative, so the last snapshot is the session summary) --
2026-09-16 ended with both agents killed under the launcher and no
disconnect block was ever written.
`no_entity` is reserved (a swing received for a ghost whose entity id is
not cached is currently dropped without a line; counting it needs the
dispatch restructured — WO-99 candidate).

### MP-SUMMARY-MOD — the mod's counters (kcd.log, on disconnect and `mp_summary`)
`MP-SUMMARY-MOD reason=<str> mod_clock_s=<F0> toasts=<int> screen_rows=<int> keys=<int> cutscene_edges=<int> ghosts=<int> ghost_packets=<int> puppets=<int> npcfight_events=<int> diverge_releases=<int> quest_divergences=<int> quest_prompts=<int> quest_fires=<int> clock_offset_ms=<F1|?> clock_rtt_ms=<F1|?> npc_yields=<int> npc_repins=<int>`

Also written every 300 s (the agent's periodic summary asks for it).

## Volume

Net new steady-state lines per second, estimated from the 2026-09-15 logs:
`MP-NPCFIGHT` ≈ +0.1 (offset by the prose line's 5 s→30 s throttle, ≈ −0.3),
`MP-GHOSTPKT` +0.1 per ghost, `MP-SWING`/`MP-DMG` only during combat
(≈ +0.7 at the brawl's peak), `MP-CLOCK` +0.03, `MP-SCREEN`/`MP-TOAST`/
`MP-KEY`/`MP-CUTSCENE` event-driven and rare. The Phase 7 re-push change
removes ≈ −0.4 (`QUEST-DIVERGENCE`) during a divergence. The `t=` suffix
adds ~10 bytes to ~3,000 mod lines per session and no lines. Not measured
live.
