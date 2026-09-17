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
`MP-CUTSCENE side=local state=start|end type=Rendered|Ingame name=<engine name> peers=<id:0|1,...>|-`

agent, a peer's machine (StoryBeat kind 6):
`MP-CUTSCENE side=peer ghost=<id> who="<display name>" state=start|end type=<type> name=<name> local=0|1`

mod (kcd.log), own machine, state AFTER the edge was applied:
`MP-CUTSCENE side=local state=start|end name=<name> peers=<id:0|1,...>|- prompt=0|1 pending=0|1`

Only `Rendered` and `Ingame` types are reported; `Fader`, `Text` and
`SkipTime` are not (WO-80's reasoning: not what a player experiences as a
cutscene). Source is the engine's own `CutscenePlayer::PlayCutscene` /
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

### MP-NPCDIVERGE — divergence release (kcd.log)
`MP-NPCDIVERGE npc=<name> dist_m=<F1> hits=<int> window_s=<F0> standoff_s=<F0> total=<int>`

One per WO-90 release (the puppet is handed back to the local world for
`standoff_s`). `total` = releases this session.

### MP-SWING — swing path hops (agent.log)
sender: `MP-SWING hop=sent sid=<int>`
receiver: `MP-SWING hop=recv rsid=<int> ghost=<id> entity=0x<hex> spec="<fragment spec>"`
receiver: `MP-SWING hop=queued rsid=<int> ghost=<id> ok=0|1`

`sid` counts swings this machine sent; `rsid` counts swings this machine
received, and ties `recv` to its `queued` outcome. The two ids are
per-machine; a cross-machine correlation id needs a field on
CombatEventUp (0x2C) and is not in this WO. The native side's `SWING:
entity=... queued fragment ...` line in `kcdmp-native.log` is the
"fragment queued" hop; whether the animation then PLAYED is still
unrecorded (nothing on the native side reports fragment start/end).

### MP-DMG — shared combat damage (agent.log)
`MP-DMG dir=out npc=<name> hp=<F1> st=<F1> fatal=0|1 authority=0|1`
`MP-DMG dir=in ghost=<id> npc=<name> hp=<F1> st=<F1> fatal=0|1 result=applied|nosoul|nodelta|failed authority=0|1`

`authority` = whether THIS agent is the relay's damage authority at that
moment (the lowest-id ready client). The NPC's claim holder at the moment
of the hit is only known at the relay (`[CLAIM]` lines).

### MP-GHOSTPKT — ghost motion (agent.log)
`MP-GHOSTPKT ghost=<id> n=<int> ia_mean_ms=<F1> ia_max_ms=<F1> d_mean_m=<F2> d_max_m=<F2> snaps=<int>`

Per ghost per ≥10 s window (flushed by the next packet): inbound Ghost
packets, inter-arrival mean/max, position delta mean/max, and `snaps` =
deltas over 5 m. With `KCDMP_LOG_LEVEL=verbose` in the agent's environment,
every packet also writes
`MP-GHOSTPKT-RAW ghost=<id> ia_ms=<F1> d_m=<F3> snap=0|1` — the snapshot-
buffer tuning data; ~4 lines/s per ghost, off by default.

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

### MP-SUMMARY — per-connection summary (agent.log, on disconnect)
```
MP-SUMMARY section=session reason=<str> duration_s=<F0> agent_lines=<int> agent_lines_per_s=<F2> clock_offset_ms=<F1|?> clock_rtt_ms=<F1|?> clock_samples=<int>
MP-SUMMARY section=ping pongs=<int> rtt_min_ms=<F0> rtt_avg_ms=<F1> rtt_max_ms=<F0>
MP-SUMMARY section=swings sent=<int> recv=<int> queued=<int> failed=<int> no_entity=<int>
MP-SUMMARY section=damage out=<int> out_fatal=<int> in=<int> in_applied=<int> in_failed=<int> authority=0|1
MP-SUMMARY section=npc state_out=<int> claim_out=<int> drag_out=<int>
MP-SUMMARY section=story divergences_pushed=<int> cutscene_local_edges=<int> cutscene_peer_edges=<int> ghost_packets=<int>
MP-SUMMARY section=ghost ghost=<id> packets=<int> ia_mean_ms=<F1> ia_max_ms=<F1> d_mean_m=<F2> d_max_m=<F2> snaps=<int>
```
`no_entity` is reserved (a swing received for a ghost whose entity id is
not cached is currently dropped without a line; counting it needs the
dispatch restructured — WO-99 candidate).

### MP-SUMMARY-MOD — the mod's counters (kcd.log, on disconnect and `mp_summary`)
`MP-SUMMARY-MOD reason=<str> mod_clock_s=<F0> toasts=<int> screen_rows=<int> keys=<int> cutscene_edges=<int> ghosts=<int> ghost_packets=<int> puppets=<int> npcfight_events=<int> diverge_releases=<int> quest_divergences=<int> quest_prompts=<int> quest_fires=<int> clock_offset_ms=<F1|?> clock_rtt_ms=<F1|?>`

## Volume

Net new steady-state lines per second, estimated from the 2026-09-15 logs:
`MP-NPCFIGHT` ≈ +0.1 (offset by the prose line's 5 s→30 s throttle, ≈ −0.3),
`MP-GHOSTPKT` +0.1 per ghost, `MP-SWING`/`MP-DMG` only during combat
(≈ +0.7 at the brawl's peak), `MP-CLOCK` +0.03, `MP-SCREEN`/`MP-TOAST`/
`MP-KEY`/`MP-CUTSCENE` event-driven and rare. The Phase 7 re-push change
removes ≈ −0.4 (`QUEST-DIVERGENCE`) during a divergence. The `t=` suffix
adds ~10 bytes to ~3,000 mod lines per session and no lines. Not measured
live.
