# KCD2-MP 0.26.5 — every WO-109 fix, on by default

The label for everything on `main` as of WO-110 (2026-09-22), packaged as
`KCDMP-Setup-0.26.5.exe`. Setup exe only. **To go back:** the tag
`rollback/0.26.4` and `KCDMP-Setup-0.26.4.exe` — or, without reinstalling,
type `mp_preset_legacy` in the console (below).

**Both machines must run 0.26.5. The relay now refuses anything else.** A
0.26.4 agent connecting to a 0.26.5 relay (or the reverse) is turned away
at the handshake with a message on both sides and a toast in the game; it
never joins. The wire protocol is v7 (was v6), so an old build is refused
twice over.

**This build exists to be tested with a peer.** Nothing in it has run
two-player; every fix was verified solo against the shipped pak
(`docs/WO-110-findings.md`). Read `docs/WO-110-peer-test-runbook.md` (one
page) before the session.

---

## Every console argument works again

Since 0.26.3 every `mp_*` command that takes an argument was a Lua syntax
error (`mp_puppet_rate 200`, `mp_authority_radius 90`, `mp_npc_yield …`,
the quest and dice commands — 38 of them); only bare commands worked.
Confirmed live, then fixed: all 41 argument commands were typed bare and
with an argument against the shipped pak, 0 errors. The WO-108
`mp_puppet_rate` sinking A/B never actually ran; it can now.

## What changed in the NPC stream

| | 0.26.4 | 0.26.5 | why |
|---|---|---|---|
| position source on the host | native scan snapshot when "fresh" (≤ 6 s) | live Lua read, always | the snapshot refreshed every 2 s; a walker would update at 0.5 Hz (WO-109 R1). It most likely never landed live anyway (below) |
| NPCs the host tracks | first 40 in engine walk order | nearest first, up to **200** (`mp_npc_track_max`) | half the NPCs inside the streaming radius were never streamed or paused (R3) |
| streaming radius | 30 m (no console door) | **60 m** (`mp_cull_radius <m>`, 10..150) | 30 m was too small for play; the relay is not the wall (WO-109 §4.3) |
| puppet Z | newer sample | interpolated with XY | a small rate-independent downhill sink / uphill float (R14) |
| receiver timing | arrival time | **sender time** (`mp_npc_senderclock`) | agent-loop quantisation, batch flushes and Nagle no longer land in the interpolation; dropped/reordered samples are visible (R6) |
| who owns the NPCs | lowest relay id, ids recycled FIFO | relay-local client, else lowest id; a reconnecting client gets its old id back | a host-agent reconnect handed the joiner every NPC for the rest of the session (R4) |

`mp_preset_legacy` puts all five 0.26.4 values back in one command;
`mp_preset_clean` returns to 0.26.5. Both log every value. The pause lever
stays ON in both (it was 0.26.4's change, and it holds).

## New log lines to grep

* `MP-AUTHORITY-OWNER` — who owns NPCs and why, on both machines and in
  the relay's `relay.log`, on every connect/disconnect.
* `MP-NPCID npc= wuid= eid= body=` — the host's identity per NPC, to diff
  against the joiner's `MP-PAUSE` lines. Rule: a different `wuid` means a
  wrong body **only for `eid` < 0x70000**; event spawns get new ids every
  load.
* `MP-NPCZ` / `MP-NPCZ-SUMMARY` — written vs read-back Z per puppet: the
  first line that can see sinking.
* `MP-RELOAD-RESET`, `MP-PAUSE … event=forget` — a save load was detected
  and stale bookkeeping cleared (no more false deaths or false `diverge`
  after a load).
* `MP-RELAY-DROPS side=relay|client` — frames dropped on a framing check,
  once a minute while nonzero. Silent before.
* `MP-BATCH-DROP`, `MP-DIALOG-GUARD` — two more things that used to fail
  silently.
* The cadence line adds `sender-spacing … seq_gaps= seq_behind= seq_dup=`.

## Fixed underneath

* **The console has a command-length ceiling (~2,100 encoded characters).**
  The agent's batch budget was 4,000 raw characters and was never safe: a
  full batch was truncated whole with only an engine-side Lua error. Every
  command is now measured in encoded characters against the ceiling; an
  oversize one is dropped loudly. By the same arithmetic the 0.26.0–0.26.4
  native position push (~2,900 encoded) most likely never reached the mod.
* **The shipped agent could not write JSON.** The merged release folder
  carried `System.Text.Json` 10 (from the relay) while the agent's own
  dependency list said 8 and lacked `System.IO.Pipelines`; every JSON write
  failed with an assembly-load error. Found by the new payload smoke gate
  on its first run; fixed by pinning the package in agent and launcher.
* Pipe hardening: a reply that arrives after the agent's timeout can no
  longer be taken as the next command's answer; the DLL gives up before the
  agent does; a faulted native task replies a fault code instead of a
  default OK (an empty NPC scan can no longer untrack everything); unknown
  commands get an answer.
* Disconnect cleanup (`RemoveAllGhosts`, `Wo102ResumeAll`) is sent
  immediately instead of queued into a batch nobody flushes.
* Peer names are sanitised at the relay; the log tail accepts an event tag
  only at the start of a line; Lua string escaping covers control
  characters; the inbound name exclusion is case-insensitive like the
  engine's lookup.
* The relay's per-client queue is sized in bytes (512 KB); a slow joiner has
  stale NPC samples thinned before it is disconnected.
* The joiner's agent no longer runs the native NPC scan (it never consumed
  it).
* `mp_debug_hud` no longer errors on a read-back call that does not exist
  on this build.
* Metrics that lied are renamed or fixed (`pause_issued_npcs`,
  `auth_pause_issued_now`, the real puppet tick in the cadence line,
  `interp tick=20ms`, `NpcStateOut` counts sent packets).
* Dwell resumes fire even with `mp_npc_sync off`; the NO_SAVE flag's result
  is checked at every spawn; console toggles typed while disconnected are
  no longer overwritten by the reconnect.
* `kdcmp.lua` had 180 top-level locals against Lua 5.1's hard cap of 200
  (MoonSharp, which every synthetic suite uses, does not enforce it); folded
  to 124, with a static check that fails the build above 170.

## The release gate

`Build-Installer.ps1` now runs every `Test-*Synthetic.ps1` (14, was 4),
both static checks, and a smoke run of the **published** agent and relay
from the payload folder (handshake + round trip, and no assembly-load line
in either process). `Publish-Release.ps1` rebuilds `KCDMP.dll` every time.

## Not in this build

* An engine-side read of the NPC suspend state (WO-109 R8): the entity →
  intelligent-object path is not in any RE note. `pause_issued=` and friends
  are the mod's bookkeeping, labelled as such.
* Locomotion/activity animation on the wire; the crime/perception
  divergence; `SchedulerProxy`.

## Evidence marks (docs/WO-110-findings.md)

* **(observed)** every Phase 8 smoke item except the engine `paused=`
  read; the console ceiling; the payload defect; the post-reload write
  fight (§3.4); owner cadence 105–113 ms; 78 tracked, nearest first.
* **(synthetic)** reorder/duplicate/gap handling, the queue pressure path.
* **(inconclusive)** everything two-player.

## ⚠ Matched set, both machines

Both machines must run 0.26.5. The relay refuses a mismatch; if one side
sees `Relay runs KCD2-MP 0.26.4, this machine runs 0.26.5` (or the
reverse) in the agent console or as a toast, that machine has the wrong
Setup. Verify with the `WO110-BUILD` line near `MOD INIT` in each `kcd.log`.
