# 0.26.5 peer test — the one page for two people mid-session

**Both machines must run 0.26.5.** The relay now refuses anything else: a
0.26.4 agent connecting to a 0.26.5 relay (or the reverse) gets a clear
message on both sides and never joins. A refused agent prints
`Relay runs KCD2-MP <x>, this machine runs <y>` and the game shows a toast
saying the same. If you see that, one machine has the old Setup; nothing
below applies until both run the same build.

No console command is needed. Load the game through the launcher, connect,
play. The build is configured for this test out of the box.

**Before either machine relaunches the game: copy both `kcd.log` files.**
Every launch rotates `kcd.log` into `logbackups\`, which keeps exactly one
file. The WO-108 smoke log was lost this way.

---

## What you should see on load (nothing typed)

Within the first seconds after `[KCD2-MP] === MOD INIT ===` there are two
marker lines:

```
[KCD2-MP] WO108-BUILD pause_lever=on npc_replica=off npc_yield=off resume_dwell_s=10.0 -- 0.26.4 defaults (mp_preset_legacy = 0.26.3)
[KCD2-MP] WO110-BUILD npc_read_native=off npc_track_max=200 cull_radius_m=60 npc_senderclock=on -- 0.26.5 defaults (mp_preset_legacy = 0.26.4)
```

If the `WO110-BUILD` line is missing, the old pak is still installed. Stop;
nothing you observe is about 0.26.5. (The WO108 line's own tail still says
"mp_preset_legacy = 0.26.3"; the WO110 line is the current one.)

## Who is the authority — check it on load

On **both** machines, after connecting:

```
[KCD2-MP] MP-AUTHORITY-OWNER self_id=<n> authority=self|peer reason=relay-combatrole hit_sensor_was=on|off
```

Exactly one machine says `authority=self`. That machine owns every NPC
(streams them, is never paused); the other renders puppets and pauses their
brains. The relay's own `relay.log` has the same decision as
`MP-AUTHORITY-OWNER id= name= reason=relay-local|lowest-id trigger=…`.
`reason=relay-local` means the host's own agent (connected over loopback)
won — that is the expected case when the host runs the relay through the
launcher. The line is written on every connect/disconnect; **if it ever flips
mid-session, note the time**: that is failure mode 5 below.

## The one-line pass/fail

**Walk into a crowd together. Do the NPCs jitter? Do they sink into the
ground?**

* Jitter gone, no sinking → pass. Say so, capture the logs anyway.
* Jitter unchanged → first read the joiner's cadence line (below), then the
  identity lines. Then the lever.
* NPCs frozen where they should move, a statue that never wakes →
  `mp_resume_all`, note the time and the NPC.

## Console commands — all of them take arguments now

In 0.26.3 and 0.26.4 every `mp_*` command with an argument was a Lua syntax
error (WO-109 R2); only bare commands worked. In 0.26.5 all 41 argument
commands were typed live, bare and with an argument, against the shipped pak
(docs/WO-110-findings.md §1.1). Type them plainly, no `#`, no quotes:

| command | when |
|---|---|
| `mp_preset_legacy` | "It is worse than before." Puts every **0.26.4** value back in one command (native NPC read on, track cap 40, streaming radius 30 m, arrival-time stamps; pause lever stays ON). `mp_preset_clean` returns to 0.26.5. Both log every value as `MP-PRESET`. |
| `mp_resume_all` | Panic. Resumes every NPC this session ever suspended and switches the pause lever off. `mp_preset_clean` re-enables it. |
| `mp_cull_radius 90` / `mp_cull_radius 30` | The streaming radius around each player (default 60; floor 10; ceiling 150, clamped loudly). Bare = report. |
| `mp_npc_track_max 40` | How many NPCs (nearest first) the owner tracks (default 200). Bare = report. |
| `mp_npc_senderclock off` | Render puppets on arrival time again (0.26.4). `on` = sender time (default). |
| `mp_puppet_rate 200` | The write-rate A/B, now actually runnable: `mp_puppet_rate 200`, then `500`, while an NPC is sinking; watch `MP-NPCZ` change. Default 50. |
| `mp_wo102_status`, `mp_summary` | one-line state / the session counters |

## If the agent console says "emitter produced no frames"

Look at the screen before anything else. A death screen, a loading screen
or the main menu halts every mod timer while the console API keeps
answering; the agent then falls back to HTTP polling and NPC sync is off
until the game is back in a world and the agent reconnects. WO-110 lost an
hour to Henry bleeding to death behind an unattended console (findings
§3.3). Do not type `mp_spawn_armor` during a session: it spawns factionless
armed NPCs next to you.

## What to capture

* **Both** `kcd.log` files, whole, **copied before either machine relaunches**.
* The relay's `relay.log` (next to `KcdMpServer.exe`).
* The **timestamp** (any clock, wall or the `t=` field) of anything odd,
  with one sentence: which NPC, what it did. The two machines' clocks
  differ; the `MP-CLOCK` line on each agent console gives the offset.
* If you used a command, which one and when.

## Reading the two logs after the session

### Identity — did both machines suspend the same body?

The **host** (authority) now logs, per NPC name, when it starts tracking it
and again on the first packet it sends:

```
[KCD2-MP] MP-NPCID npc=<name> wuid=<hex16> eid=<hex> body=<class> via=acquire|first-emit
```

The **joiner** logs the same tuple on every pause:

```
[KCD2-MP] MP-PAUSE npc=<name> event=pause wuid=<hex16> eid=<hex> body=<class> exec=ok why=puppet-start owner=<id> …
```

Diff them per name: `grep "MP-NPCID npc=ttkc_barbora" host.log` against
`grep "MP-PAUSE npc=ttkc_barbora event=pause" joiner.log`.

**The rule, corrected (WO-109 §1.4):** a different `wuid` for the same name
means a wrong body **only when `eid` < 0x70000**. Authored NPCs have the same
name, entity id and WUID on both machines across loads and even across
different playthroughs. Runtime event spawns — caravans, brawlers,
`SpawnedAnimal_*` — have `eid` ≥ 0x70000 and get a new id and WUID on every
load on every machine; a mismatch there is expected and harmless (the name
still resolves, or resolves to nothing, which is the safe case).

### Sinking — the first log line that can see it

```
[KCD2-MP] MP-NPCZ npc=<name> wrote=<z> read=<z> delta=<m> xy_delta=<m> rate_ms=<n> pause_issued=0|1 anim=<tag>
[KCD2-MP] MP-NPCZ-SUMMARY n=<count> mean_abs=<m> max_abs=<m> sink_n=<n> float_n=<n> rate_ms=<n>
```

Joiner only. `delta` is the puppet's read-back Z minus the Z the mod wrote
one tick earlier; negative = the body sits lower than written (sinking),
positive = higher. Logged once per 2 s per puppet, only while |delta| > 5 cm.
No `MP-NPCZ` lines while an NPC visibly sinks means the body is exactly
where the mod writes it and the *stream's* Z is low — the host's read, not
the joiner's write. Lines with a steady negative delta mean something on the
joiner moves the body down after every write. Run `mp_puppet_rate 200` /
`500` and compare `MP-NPCZ-SUMMARY` before and after.

### Jitter — the cadence line

Joiner, every 5 s:

```
[KCD2-MP] NPC-SYNC packet cadence: moving n=… mean=…ms min=…ms max=…ms; idle-heartbeat n=… (receiver assumes emitter 100ms, heartbeat 2000ms; apply tick is 50ms; …) sender-spacing n=… mean=…ms min=…ms max=…ms seq_gaps=… seq_behind=… seq_dup=… senderclock=on
```

* `moving … mean` ≈ 100–200 ms is a healthy stream. **≈ 2000 ms is the
  0.26.4 snapshot bug (R1) and should not appear on 0.26.5** unless someone
  typed `mp_npc_read_native_on`.
* `sender-spacing` is the same stream measured on the *owner's* clock. If
  arrival `min/max` is wide and sender-spacing is tight, the network/agent
  path is the jitter and the sender clock (on by default) is what hides it.
* `seq_gaps` > 0 = packets lost between owner and joiner; `seq_behind` = a
  packet overtaken by a later one; both used to be invisible.

### Other greppable lines

| line | meaning |
|---|---|
| `MP-AUTHORITY-OWNER` | who owns NPCs, and why (both machines + relay) |
| `MP-NPCID` | host identity per name (see above) |
| `MP-PAUSE … event=pause/resume/release/cancel/forget` | the lever's every action, with identity; `forget` = a save load dropped the engine's suspension |
| `MP-RELOAD-RESET` | a save load was detected; death marks, dwells and last-written positions were reset |
| `MP-NPCZ`, `MP-NPCZ-SUMMARY` | sinking telemetry (joiner) |
| `MP-NPCTRACK tracked=… culled=…` | owner: how many NPCs it owns / how many are inside the streaming radius (was capped at 40 in 0.26.4; now up to 200, nearest first) |
| `MP-NPCSCAN dir=native … pushed= cap= farthest_pushed_m= chunks=` | owner's agent console: the scan push |
| `MP-RELAY-DROPS side=relay|client` | relay.log / agent console: frames dropped on a length check, every 60 s while nonzero |
| `MP-BATCH-DROP` | agent console: a whole Lua batch failed to execute (was silent) |
| `MP-DIALOG-GUARD` | a dialogue check threw and defaulted (was silent) |
| `MP-AUTHORITY-VIOLATION … kind=contention/relax/diverge` | joiner: something else moved a driven body; `dist_m` is 3-D now |
| `MP-PAUSE-GAP` | a paused NPC nobody was writing — the safety net |
| `MP-PRESET` | a preset was applied; one line per value |

## Known in 0.26.5 — do not report these as new bugs

Unchanged from 0.26.4 (docs/WO-108-peer-test-runbook.md, "Known in
0.26.4"): a driven NPC on the joiner has generic legs, no head-look, no
barks, no prop interaction, no combat decisions, no reactions to the joiner;
attacking one may raise no crime response; ~25 s of standing after the
stream leaves an NPC is the dwell plus the brain's re-plan, not a statue.

New in 0.26.5, by design:

* **Only the host's agent scans NPCs.** The joiner's agent console says
  `MP-NPCSCAN dir=native verdict=skipped reason=not-authority` once. Correct.
* **A mixed-version session cannot connect.** Both Setup.exe installs must
  be 0.26.5.
* **Engine suspend state is still not read.** `pause_issued=` /
  `pause_exec=` / `pause_issued_npcs=` are the mod's bookkeeping; the engine
  read (WO-109 R8) did not ship — the entity → intelligent-object path is
  not in any RE note. The engine's own `Can't update suspended node!` line
  remains the only engine-side signal.

Nothing in this build has run two-player. Every fix was verified solo
against the shipped pak (docs/WO-110-findings.md) and ships on that evidence
as a stated risk; this session is what it was built to collect.
