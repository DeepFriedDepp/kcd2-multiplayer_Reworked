# WO-1 — Transport replacement: status

Replacing per-call HTTP and the `sv_servername` CVar hack with a duplex,
low-latency channel between the Lua mod and `KcdMpClient.exe`.

**This phase is blocked on a decision that only the game can answer.** Options
(a) and (b) both hinge on whether the Lua sandbox exposes `io`, `socket` or
LuaJIT's `ffi`, and the brief's first rule is not to invent an API. So the
deliverable here is the probe that settles it, plus everything that does not
depend on the answer.

## What the current channel costs

One player-state sample is **three HTTP round trips**:

| # | Call | Purpose |
|---|---|---|
| 1 | `GET /api/rpg/SoulList/PlayerSoul` | scrape `Position="x,y,z"` |
| 2 | `GET /api/System/Console/ExecuteString` | Lua packs yaw + mount state into `sv_servername` |
| 3 | `GET /api/System/Console/GetCvarValue` | read that CVar back |

Steps 2–3 are the CVar hack. There is no push channel out of the game, so an
unrelated real CVar is hijacked as a one-slot mailbox — meaning yaw cannot be
*read* without first *writing* to the game. The live agent hides some of this
by running steps 2–3 on an 80 ms background loop while position ticks at 10 ms,
but the ceiling is still set by HTTP round trips.

## The four options, and what each needs

| | Option | Needs | Verdict |
|---|---|---|---|
| a | Lua-side socket | `socket` table, or `ffi` to reach `ws2_32` | **probe** |
| b | File mailbox / ring buffer on disk | working `io.open` + a writable path, *in the tick context* | **probe** |
| c | Structured `kcd.log` tail + batched inbound | known-good `System.LogAlways`; needs measured flush latency and no drops | **probe** (partly) |
| d | Batch N Lua statements per `ExecuteString` | nothing — always available | **fallback, measured** |

`ffi` is the headline. If LuaJIT's FFI is exposed, option (a) is reachable
without LuaSocket by calling Win32 sockets directly, and it beats everything
else. If `io` works but `ffi` does not, option (b) is the pick. If neither, it
is (c) for outbound plus (d) for inbound.

**One trap the probe is built around:** `Terrain.GetElevation` is already known
to exist inside a `Script.SetTimer` tick but *not* in the console
`ExecuteString` context. The two environments demonstrably differ, so the probe
re-runs every check inside a tick and reports `exec.*` and `tick.*` separately.
A capability that only exists in the console context is useless for options (b)
and (c), which have to run from the tick.

## Run the probe

Needs KCD2 running through the **Modding Tools** entry with a save loaded. No
pak rebuild and no restart — the probes define nothing and persist nothing.

```powershell
powershell -ExecutionPolicy Bypass -File tools\Probe-Transport.ps1
```

It sends each block of `tools/probe_transport.lua` through the debug console,
then reads the answers back out of `kcd.log` and writes
`tools/probe-results.txt`. Paste that file back to decide the transport.

## Run the baseline benchmark

Same requirement — game up, save loaded:

```powershell
dotnet run --project dotnet\KcdMp.Client -- --benchmark
```

Reports latency percentiles for a no-op `ExecuteString`, a position read, the
CVar cycle, a full state read, and batched `ExecuteString` at x5 and x20 — that
last pair is option (d) measured directly, so its value is known before
anything gets built. Finishes with sustained full-state reads per second.

Percentiles, not averages, because smoothness is set by the bad ticks: an
occasional 200 ms stall is what a player sees, so p95/p99 are the real numbers.

## What is already in place

- `IGameTransport` — the seam, so the rest of the agent does not care which
  channel is in use. Deliberately intent-based: `ReadPlayerStateAsync` asks for
  a whole sample rather than exposing "read position" and "read a CVar"
  separately. HTTP needs three round trips to answer it; a push transport
  answers from its latest frame with none. Callers see one method either way.
  `RoundTripsPerStateRead` is on the interface so a comparison shows *why* one
  transport is faster.
- `HttpGameTransport` — today's channel behind that interface, kept faithful so
  the baseline is honest.
- `TransportBenchmark` — the measurement, run via `--benchmark`.

`GameBridge` has **not** been rewired onto the interface yet. That is
deliberate: the seam is worth confirming against one real replacement before
committing the whole sync loop to it.

## Next, once probe results land

1. Pick the transport from the table above.
2. Implement it as a second `IGameTransport`.
3. Re-run `--benchmark` against it and put the two side by side — that is the
   work order's actual deliverable.
4. Rewire `GameBridge` onto the interface and select the transport by config.
