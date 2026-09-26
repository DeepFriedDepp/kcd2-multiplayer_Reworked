# tools/wo118 — the WO-118 live gate (solo, local relay)

The harness behind `docs/WO-118-findings.md`. It drives a **synthetic authority
peer** through a **real local relay** into the **joiner's** running game, and reads
back what the renderer drew through `mp_npc_trace` (one CSV row per frame: position
at the DLL frame hook before the write, what the native writer wrote, position at
`CSystem::Render`, `bFlying`). Nothing here ships; nothing here is two-player
evidence.

## Setup

1. Build: `dotnet build tools/wo118/synthpeer -c Release`, plus the relay and agent
   from `dotnet/` (or use an installed build's `KcdMpServer.dll` / `KcdMpClient.dll`).
2. `set KCD2MP_INSTALL=<the Modding Tools install folder>` (the one holding `kcd.log`).
   `DOTNET_ROOT` is honoured if `dotnet` is not on PATH.
3. Start the Modding Tools build (Steam running), load a **throwaway** save by the
   Troskowitz village (the plans in `plans/` name its NPCs and positions), inject
   `KCDMP.dll` (the launcher does it; by hand:
   `KCDMP_LauncherInjector --pid <pid> --dll <absolute path>`), and check the native
   log for `WO118-NATIVE native_write=armed`.
4. `python start_joiner.py <KcdMpClient.dll> [<KcdMpServer.dll>]` — the agent must be
   the **joiner** (relay rule 2: the lowest ready id is the authority, so a
   placeholder peer takes id 0 first; every test peer takes it back).
5. `python live.py luaf lua/wo118.lua` — the plan/probe helpers.

## The gate

```
python phase5_gate.py
```

Four traced runs, ~3 minutes: walker native (0 frozen frames), seated native +
detach (≤ 1 mm, no moving frames), walker legacy (the stair-step returns, ≥ 40 %
frozen), seated legacy (the sawtooth returns, ≥ 20 mm, most frames moving). Ends
with `GATE GREEN` or `GATE RED` and restores both toggles on.

## The other runs

| script | what |
|---|---|
| `noise_batch.py` | one walker with delay/jitter/spikes injected after the sender stamp; sender clock on/off; old tick stamps |
| `ghost_batch.py` | the peer's ghost (`kcd2mp_0`) at the pos-native cadence, clean and jittered, sender-stamped like a current agent; `g2off` is the jittered run without the stamp (`--ghost-sender-ms off`) |
| `scale_run.py <tag> <N> [r]` | N walking puppets, frame time native on/off/on + `MP-NPCWRITE-COST`; `MINIMIZE=1` for the background-limited case; `EMIT_MS` sets the peer's emit period (100) |
| `peer_trace.py` + `slope118.py` / `fight118.py` | sinking on a slope (`plans/plan.slope*.txt`) and in a fight (`plans/plan.fight.txt`); `fight118.py` also reports each swing hold's resume step and the largest render step in the second after it |
| `peer_trace.py` + `start118.py` | a puppet start (pause, detach, bind) frame by frame: plan `start 1.5` + `hold <npc> …` at or near its spot, trace armed before the stream starts; every rendered movement is a start-up artifact |
| `jitter118.py <csv> line x0 y0 ux uy len` / `hold x y` | per-trace analysis |

## Traps (each cost a run)

* **Focus.** KCD2 drops to ~26 fps whenever its window is not in front (its
  background limiter). Every script calls `live.focus()`; `MINIMIZE=1` measures the
  limited case on purpose.
* **REST under load.** With dozens of puppets the agent's Lua batches keep the
  game's REST server busy: outside commands get 503 (retried) or are lost.
  Schedules are armed in Lua (`Script.SetTimer`) before the load starts.
* **Spacing.** Leave ≥ 6 s between peer runs: the DLL resets a source's clock after
  5 s of silence and a stream's sequence after 2 s.
* **Plans are save-specific.** Regenerate with `WO118_Plan`, `WO118_PlanHold`,
  `WO118_PlanMany`, `WO118_SlopeFind`, `WO118_Flat` (see the header of `lua/wo118.lua`).

## WO-123 / WO-124: the join

| script | what |
|---|---|
| `join123.py` | WO-123: the running game's agent as the HOST, `synthpeer --join` as the joiner |
| `join124.py` | WO-124: the running game's agent as the JOINER (at the main menu), `synthpeer --join-host <copy of a host save>` as the host: `relay`, `host <tag> ...`, `agent <tag> <KcdMpClient.dll> [ENV=VAL]`, `stop host|agent|all`, `lines` |

* `synthpeer --join-host` announces its session mode (`--shared on|off`), streams its
  avatar at `--host-pos x,y,z` (the host save's Henry spot), and serves `--serve N` joins;
  `--corrupt-chunk N` flips a byte on the way out; `--leave-after-ready S` disconnects.
* A plan's `ride <t0> <t1>` line makes the peer's ghost ride between t0 and t1 (6a).
* Run the agent and the peers from COPIES of their build folders: a running agent locks
  `bin/Release`, and the next build fails.
* `KCDMP_DATA_DIR` (default `data124/`, git-ignored) is the agent's staging folder;
  `KCDMP_JOIN_SAVES_DIR=<empty dir>` makes the joiner a player with no save of their own.
* The host save the synthetic host serves is a COPY in the session scratchpad: never in
  the repo, never logged by path.
