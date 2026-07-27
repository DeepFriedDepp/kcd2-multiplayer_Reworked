# WO-1 — Transport replacement

Replacing per-call HTTP and the `sv_servername` CVar hack with a duplex,
low-latency channel between the Lua mod and `KcdMpClient.exe`.

**Investigation is complete.** Probes and the baseline benchmark were run
against KCD2 v1.5.2 on 2026-07-27. Two of the four candidate options are dead,
and the answer is a combination of the other two.

---

## Probe results

Run: `powershell -ExecutionPolicy Bypass -File tools\Probe-Transport.ps1`
(raw output in `tools/probe-results.txt`, regenerated per run).

### The sandbox is a stripped Lua 5.1, not LuaJIT

| | |
|---|---|
| `_VERSION` | `Lua 5.1` |
| `jit`, `ffi`, `bit` | **nil** — this is not LuaJIT |
| `io` | **nil**, in *both* the console and tick contexts |
| `socket` | nil; `require("socket")` fails with "module not found" |
| `os` | table, but stripped to **`clock` and `time` only** — no `getenv`, `date`, `remove`, `rename`, `tmpname`, `execute` |
| present | `package`, `require`, `load`, `loadstring`, `dofile`, `loadfile`, `setfenv`, `debug`, `coroutine`, `string`, `table`, `math` |

### `System.LogAlways` is cheap and lossless

50 tagged lines took **0.98 ms** of Lua time. All 50 reached `kcd.log`, in
order, none dropped.

---

## Verdict on the four options

| | Option | Verdict | Why |
|---|---|---|---|
| a | Lua-side socket | **DEAD** | No `socket` module, and no `ffi` to reach `ws2_32` — the runtime is plain Lua 5.1, not LuaJIT |
| b | File mailbox on disk | **DEAD** | `io` is nil in both contexts. There is no file API to write with, and `os.getenv`/`os.remove` are gone too |
| c | Structured `kcd.log` tail | **VIABLE — chosen for outbound** | LogAlways costs ~20 µs/line, lossless and ordered |
| d | Batched `ExecuteString` | **VIABLE — chosen for inbound** | Batching is measurably free (below) |

Options (a) and (b) are not "hard", they are **impossible** on this runtime. No
amount of engineering opens them; only a different Lua build would.

---

## Baseline benchmark

Run: `dotnet run --project dotnet\KcdMp.Client -- --benchmark`

```
operation                            min     p50     p95     p99     max    mean
--------------------------------------------------------------------------------
noop ExecuteString                  39.4    42.2    44.9    45.6    47.6    42.4
position read (1 RT)                40.0    43.4    45.7    47.0    47.4    43.5
rot+ride CVar cycle (2 RT)          81.6    84.6    87.6    89.3    89.9    84.8
full player state (3 RT)           123.0   127.4   132.9   134.3   134.3   127.8
batched ExecuteString x5            39.9    42.2    43.5    45.7    45.7    42.3
batched ExecuteString x20           39.7    42.0    45.0    48.3    48.3    42.3

full state reads : 7.8/s
implied ceiling  : 23 HTTP round trips/s
```

Two things fall straight out of this:

**Cost is per round trip, flat, at ~42 ms.** One round trip is 43 ms, two are
85 ms, three are 128 ms — dead linear. Latency does not vary with payload.

**Batching is free.** Twenty Lua statements in one call cost the same 42 ms as
one statement. Nothing is charged for the content of a call, only for making
it. This is the single most useful measurement in the set, and it means the
cheap fallback option (d) is worth far more than "lowest risk" suggested.

The consequence is stark: the sync loop ticks at 10 ms but the channel supports
**7.8 full state reads per second**. The loop is entirely transport-bound.

Also measured: the **first** request after connect takes ~2.2 s versus ~40 ms
warm. Anything with a short timeout must retry rather than conclude the game is
absent — the benchmark itself had that bug and now retries five times.

---

## The design

**Outbound (game → agent): tail `kcd.log`.** The Lua tick already runs every
20 ms. It emits one structured `[KCD2-MP-DATA]` line per tick with position,
yaw and mount state; the agent tails the file. This removes the CVar hack and
the polling read entirely.

- 3 round trips per sample → **0**
- 7.8 samples/s → **~50/s**, set by the Lua tick rate rather than by HTTP
- Yaw no longer requires *writing* to the game to read it
- `sv_servername` is handed back to the game

**Inbound (agent → game): one batched `ExecuteString` per tick.** Ghost
updates are coalesced into a single call instead of one call per ghost. With
N players, cost goes from N x 42 ms to a flat 42 ms.

Both halves use only APIs already proven in the existing mod. Nothing here
depends on an unverified capability.

### Known risks, to settle during implementation

1. **Log-to-disk visibility latency: measured, design holds.**
   A tailer holding the file open and reading from the end sees a line
   **~45 ms** after the write is triggered (min 39.1, p50 46.0, p95 53.7,
   max 53.7, n=15). The engine does not sit on log writes for long, so an
   external tailer is viable.

   **Caveat: this is an upper bound, not the true write-to-visible latency.**
   The trigger was an HTTP `ExecuteString` and the clock started when that
   response returned, so the figure still contains however much command
   dispatch and main-thread scheduling sat between the response and Lua
   actually running. The real emitter is an autonomous Lua tick with no HTTP
   involved, so its latency is *at most* this and probably lower. Re-measure
   from inside the mod's own tick once the emitter exists.

   Worth being clear about what this does and does not buy. Against a
   *position-only* HTTP read (43 ms) the latency is a wash. The win is that it
   collapses the **3-round-trip full-state read (128 ms)** to a single ~45 ms
   push, and lifts throughput from 7.8/s to the tick rate. This is a
   throughput and round-trip win, not a raw single-sample latency win.
2. **`kcd.log` is noisy and grows.** During testing it was 3.5 MB and being
   flooded by siege AI ("First shot replanning for ..."). The tailer must seek
   to the end and filter by prefix, never re-read the file.
3. **Log rotation on game restart** must be handled by the tailer.

---

## What is in place

- `IGameTransport` — the seam. Intent-based: `ReadPlayerStateAsync` asks for a
  whole sample rather than exposing position and CVar reads separately, so HTTP
  can spend three round trips answering it while a log-tail transport answers
  from its latest frame with none. `RoundTripsPerStateRead` is on the interface
  so a comparison shows *why* one is faster.
- `HttpGameTransport` — today's channel behind that interface, the baseline above.
- `TransportBenchmark` — `--benchmark`, reporting percentiles rather than means
  because smoothness is set by the slow ticks, not the average.
- `tools/probe_transport.lua` + `tools/Probe-Transport.ps1` — re-runnable
  capability check. Worth re-running after any game patch, since the whole
  design rests on `io` and `ffi` being absent.

`GameBridge` is deliberately **not** rewired onto the interface yet; that lands
with the log-tail transport, against a real second implementation.

---

## Measured result: log tail vs HTTP

Steps 1 and 2 are built and were run end-to-end against the live game. The
emitter was injected through the console rather than loaded from the pak (the
game was running and the pak is locked while it is), which exercises exactly
the same code path.

```
                           http-debug-api       kcd-log-tail
------------------------------------------------------------
round trips / read                      3                  0
state read p50 (ms)                  55.0             0.0001
samples / second                     18.1               30.4
throughput gain                                          1.7x
frames dropped                          -                  0
```

**Note the HTTP baseline moved.** It measured 128 ms / 7.8 per second during the
first run and 55 ms / 18.1 per second here. The difference is game load: the
first run happened during a siege with the AI flooding the log. Absolute
numbers are not comparable between runs, only ratios within a run. Anything
quoting a fixed "128 ms" is quoting one loaded-game sample.

### The projection that did not hold

The design predicted ~50 samples/s from a 20 ms emitter tick. **It delivers
~30/s.** Sequence numbers were contiguous and zero frames were dropped, so
nothing is being lost in the log or the tailer — the emitter genuinely only
fires ~30 times a second. `Script.SetTimer` is evidently frame-bound rather
than a true 20 ms timer, so the ceiling is the frame rate, not the interval.
Asking for 20 ms does not produce 50 Hz.

### What this actually buys, stated plainly

The throughput gain is **1.7x, not the 6.4x** the earlier projection implied.
The real wins are structural rather than raw rate:

1. **Reads cost nothing.** 3 round trips become 0, and a read is a cache hit at
   0.0001 ms instead of a 55 ms blocking call. The whole HTTP channel is freed
   for outbound ghost updates, which is what it should have been doing all
   along.
2. **The CVar hack is gone.** `sv_servername` goes back to the game, and yaw no
   longer requires *writing* to the game in order to read it.
3. **Zero drops** across the measured window.

One honest cost: **freshness is worse, not better.** A tailed frame is up to
one frame period old plus ~45 ms of log-flush latency, so roughly 45-80 ms
stale. A direct HTTP position read returns data ~18 ms old. The log tail trades
sample freshness for eliminating round trips. For a presence layer showing
other players' avatars that is the right trade, but it is a trade, and if ghost
smoothness ever regresses this is the first thing to suspect.

---

## Next steps

1. ~~Measure log-to-disk visibility latency~~ — done, ~45 ms.
2. ~~Implement `LogTailGameTransport` and the Lua emitter~~ — done, measured above.
3. **Rebuild the pak** so `KCD2MP_StartEmitter` loads normally instead of needing
   console injection. Requires closing the game; script in `docs/kcd2_lua_api.md`.
4. Add batched `ExecuteAsync`/`FlushAsync` buffering to the HTTP path for inbound.
   Batching is free, so this is the cheapest remaining win.
5. Rewire `GameBridge` onto `IGameTransport`, selecting by config.
6. Consider whether ~30 Hz frame-bound emission is enough. If not, the emitter
   could pack several samples per line, though the frame rate still bounds how
   often state is *sampled*.

## Tooling notes

- **Keep probe blocks small.** Long or deeply nested chunks are dropped by the
  console endpoint silently — no output, no Lua error. Length is not the cause
  (an 8000-character single-line chunk runs fine, as does a 60-line one), so the
  trigger is chunk complexity. Not worth pinning down; several short blocks are
  reliable, one long one is not.
- **`kcd.log` lives with the Modding Tools install** (`steamapps\common\KCD2Mod`),
  not the base game folder. `Probe-Transport.ps1` scans every Steam library and
  takes the most recently written match. The agent's own `GetSteamNameFromKcdLog`
  still hardcodes the base-game path and so silently falls through to its
  `loginusers.vdf` fallback under Modding Tools — harmless today, worth fixing.
