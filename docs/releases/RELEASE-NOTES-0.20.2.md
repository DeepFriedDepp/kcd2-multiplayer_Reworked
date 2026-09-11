# KCD2-MP 0.20.2 — pre-release test build

The label for everything on `main` as of WO-77 (2026-09-11), and a packaged
build: `KCDMP-Setup-0.20.2.exe` plus the update-only
`KCDMP-DirectInstall-0.20.2.zip`. Built for **pre-release testers**; it is
not on the releases page unless the maintainer put it there.

**What we need from you:** play a session with a friend near hand-placed NPCs
— a fight, a chase, a walk through a village — and tell us whether synced
NPCs still stutter. That is the one thing this build changes that nobody has
watched yet. Send `kcd.log` from **both** machines and the relay's console
log; see *If something looks wrong* below.

## The headline: synced NPCs should stop dashing and pausing

Since NPC sync arrived (0.11.8), an NPC being mirrored from another player's
machine moved in a visible rhythm — a quick dash, a pause, another dash, four
times a second, with its walk/run animation flickering to match. WO-69 traced
the dominant cause to the receiver: it was chasing each new position with a
per-tick "close half the gap" step, so it sprinted the instant a packet
arrived and coasted to a stop before the next one. Two things change:

- **The receiver now plays the stream back a fixed 120 ms behind real time,
  moving at a constant speed between the last two known positions.** No
  guessing ahead, no catch-up bursts. If packets stop, the NPC stops where
  the last one put it. A teleport (more than 5 m in one step) still snaps.
- **The sender reports moving NPCs at 10 Hz instead of 4 Hz.** Idle NPCs
  still cost only a 2 s heartbeat. Bandwidth stays well under one player's
  own position stream.

A side effect worth knowing: the NPC's walk/run animation is now chosen from
the speed of the whole segment through the same hysteresis bands ghosts use,
so it no longer cycles run→walk→idle inside a single packet gap.

**Verified synthetically only.** The renderer's arithmetic is proven by a new
automated test (39 checks: constant-speed interpolation, no overshoot past
the newest sample, a doubled or leaked update chain rendering exactly the
same positions as a single one, the delay tracking the send rate). **No human
has yet watched it in a two-machine session.** That is what this build is
for.

`mp_npc_smooth off` in the game console brings the old renderer back on the
spot, so you can compare live; `mp_npc_smooth on` restores the new one. The
default is **on** — deliberately, because two weeks of 0.19.0 produced no
tester sessions at all, and a fix nobody turns on is not being tested.

This does **not** change who owns an NPC (the 0.18.2 proximity claim system
is untouched). If two machines were ever fighting over one NPC, that fight is
now harder to see by eye — but it is still fully visible in the logs, which is
why we ask for them.

## Relay and native hygiene (WO-76)

None of this changes gameplay; all of it makes failures louder or rarer.

- **A full relay now says so.** A client refused because the relay is at its
  player limit gets an explicit `ServerFull` packet (type `0x36`, carrying
  the limit) and stops retrying, instead of a silent disconnect and a retry
  every 3 s forever. An older agent does not know this packet; it will still
  see the disconnect it always saw.
- **`ServerInfo:MaxPlayers` is clamped to at least 1** and the effective
  limit is logged at startup — `0` used to brick the relay silently.
- **Relay session ids are pooled and recycled.** The wire's single-byte id
  used to count up forever and never be reused; a long-running relay could
  exhaust it. Ids are now taken from a free list only when a handshake
  completes and returned on disconnect.
- **The native plugin's pipe server can no longer hang forever** on a
  request while the game's frame loop is wedged. It now bounds its own wait
  at 5 s, logs the condition, answers failure, and keeps serving. Compiled
  clean on this project's toolchain; **not yet exercised against a live
  injected game.**
- A nil-arithmetic error that silently ate roughly every 40th ghost
  diagnostic line is fixed, so ghost `pkt#` lines will finally appear in
  field logs.
- Six test scripts that had drifted from current relay behaviour were
  repaired; a seventh gained HTTP-port isolation.

Protocol version is unchanged (`6`); a 0.19.0 agent can still connect to a
0.20.2 relay and vice versa.

## Also on `main` since 0.19.0

- PR #1 (merged): main-thread timing and write-queue refactor in the native
  plugin, wall-clock re-arm of the agent's timer chains, ready-client
  tracking for the player limit.
- WO-75: a full project audit and the jitter design this build implements.
  Design docs, no shipping code.

## If something looks wrong

Send, from **each** machine:

- `kcd.log` — the game's log, from the folder you launch the game from.
- The relay's console output (whoever hosted).
- `install-verify.txt` from the install folder if the install itself
  misbehaved.

Things we will grep for, so you don't have to: `[WO66-REJECT]` and
`api/information/npc-validation` counts on the relay (two senders fighting
over one NPC), `NPC-SYNC tracking` / `untracking` churn, `NPC-FIGHT` lines
(something other than the stream moving a synced NPC), and `CHAIN LEAK
CONFIRMED`. You can flip `mp_npc_smooth off` mid-session and tell us which
looked better; that comparison is more useful than either alone.

Installing over 0.19.0 or any earlier version works the same way as before:
run the Setup, or unpack the DirectInstall zip and run its `Apply.ps1`. Setup
repairs a mixed or broken install and verifies every file (0.19.0's
guarantees are unchanged).

Full evidence trail: `docs/WO-77-findings.md`, `docs/WO-76-findings.md`,
`docs/WO-75-jitter-design.md`.
