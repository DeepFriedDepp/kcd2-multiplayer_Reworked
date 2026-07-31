# WO-10 Part B — Injection liveness-check fix

Read `docs/VERIFICATION-REPORT.md`'s injection section first — this is the
fix for the bug documented and evidenced there, not a re-derivation of it.

---

## The bug, restated

`native/KCDMP/dllmain.cpp`'s `plugin_main`, after installing the IAT hook on
`C_ModulesManager::Update`, used to do exactly this:

```cpp
Sleep(1000);
const auto frames = kcdmp::main_thread::frame_count();
if (frames == 0) {
    kcdmp::logf("MAIN: tick is not firing -- aborting before any game-state access");
    return 0;   // permanent -- no retry
}
```

`WHGame.dll` is a static import, so it is present in the process almost
instantly. The game's actual per-frame tick does not start until well past
the splash/menu screens, into an actually-loaded save. A DLL injected the
moment the module is merely loadable hooks the import correctly but samples
for ticks far too soon, and this code gave up **permanently** on that one
sample — no second chance, ever, for that injected instance.

## Which fix, and why

Chose **(i)**: make the native check itself poll instead of sampling once.
Not (ii) (launcher waits for a real gameplay signal before injecting),
per the brief's own reasoning: it is the smaller, local change, and it
protects every injection path, not just one launcher UI flow. That turned
out to matter in practice, not just in theory — see "A complication found
mid-fix" below: the launcher (`KCDMP_launcher`) already added its own
gameplay-signal gate in WO-7 (the player must click CONNECT after they can
see and move their character before injection happens at all), which is
functionally close to option (ii) already, and it long predates this WO.
That gate reduces how often the race fires through the launcher, but does
**not** eliminate it — a player can still click CONNECT slightly too early,
and it protects nothing for direct/manual injection (`KCDMP_LauncherInjector.exe`
run by hand, the dev/test workflow every `Test-Pipe.ps1`-style script and
this very session's own verification uses). Fixing the native check is the
only one of the two that closes the race for every path at once.

## The fix

`plugin_main` now polls `frame_count()` on a 1s interval, up to a 5-minute
ceiling, instead of sampling once:

```cpp
constexpr DWORD kFrameCheckIntervalMs = 1000;
constexpr DWORD kFrameCheckCeilingMs  = 300'000; // 5 minutes
constexpr DWORD kFrameCheckLogEveryMs = 30'000;

unsigned long long frames = 0;
DWORD waited = 0;
while (waited < kFrameCheckCeilingMs) {
    Sleep(kFrameCheckIntervalMs);
    waited += kFrameCheckIntervalMs;
    frames = kcdmp::main_thread::frame_count();
    if (frames > 0) {
        kcdmp::logf("MAIN: %llu frames after ~%u ms -- tick is live", frames, waited);
        break;
    }
    if (waited % kFrameCheckLogEveryMs == 0) {
        kcdmp::logf("MAIN: still waiting for the tick to start (%u ms elapsed, 0 frames so far)", waited);
    }
}
if (frames == 0) {
    kcdmp::logf("MAIN: tick never fired after %u ms -- aborting before any game-state access", waited);
    return 0;
}
```

**The 5-minute ceiling is generous, not measured** — a player may sit at
the main menu for a while before loading a save, and there is no cost to
waiting longer: `plugin_main` runs on its own background thread (created in
`DllMain`, which returns immediately after `CreateThread`), so this never
blocks the game or the loader. A genuine failure (the tick truly never
starts — wrong build, hook actually broken) still gives up eventually and
logs plainly, rather than either aborting in 1s or hanging forever silently.

### A complication found mid-fix

`KCDMP_launcher/Pages/Home.razor.cs`'s `VerifyInjectionAsync` (added in
WO-7) regex-parses this exact log line to decide whether to start the
agent: it was matching `MAIN: (\d+) frames in ~1s` and checking for the
literal string `"tick is not firing"`. Both wordings changed with this fix.
**Updated in the same commit** — the regex now matches `MAIN: (\d+) frames
after ~\d+ ms -- tick is live`, and the failure check looks for `"tick
never fired"`. Caught before it could ship as a silent break: the launcher
would have timed out waiting for a log line that no longer gets written in
that shape, always reporting failure regardless of what the native DLL
actually did. `docs/PROJECT-STATE.md`'s traps list already has one
protocol-version-forgot-a-script entry; this is the same shape of mistake
in a different layer (a log format contract instead of a wire format one),
caught by reading the consumer before assuming there wasn't one.

The launcher's own 8-second wait for that line is unchanged: WO-7's CONNECT
gate means the tick should already be live by the time the player clicks
it, so the native side's first 1s sample should log success well inside 8s
in the normal launcher flow. The native poll's 5-minute ceiling exists for
paths without that human gate.

## Verification — real cold-start injection, not into an already-loaded session

Matched `VERIFICATION-REPORT.md`'s own method exactly: closed the running
game, started a **fresh** `KingdomCome.exe` process, and injected
`KCDMP.dll` via `KCDMP_LauncherInjector.exe` the moment the process
existed — the same "inject the instant it's possible" behavior the old
automatic path had, well before any save was loaded. This is the literal
scenario `VERIFICATION-REPORT.md` reproduced and found broken.

**Injection 1 — the race, reproduced and now survived** (native log, this
session, `native/build/KCDMP/kcdmp-native.log`):

```
[15:39:29.389] MAIN: hooked WHGame.dll!IAT[C_ModulesManager::Update] original=...
[15:39:59.409] MAIN: still waiting for the tick to start (30000 ms elapsed, 0 frames so far)
[15:40:11.415] MAIN: 1 frames after ~42000 ms -- tick is live
[15:40:16.416] MAIN: walk timed out waiting for a frame; not starting the pipe
```

Under the **old** code this would have logged `"0 frames in ~1s"` /
`"tick is not firing -- aborting"` at the 1-second mark and returned
permanently, exactly as `VERIFICATION-REPORT.md` documented. Under the
**new** code it kept polling, logged a progress line at 30s so a long wait
does not look hung in the log, and correctly picked up the tick becoming
live 42 seconds after the hook was installed — the fix's core claim,
directly observed, not inferred.

(The soul walk immediately after timed out and the DLL declined to start
the pipe for *this* injected instance — the game was still at/near the
main menu, not yet in a loaded save, so `SoulList` was not really populated
even though one sparse frame had ticked. This is a **separate, pre-existing
mechanism** — `run_sync`'s own 5-second wait for the walk step, unrelated
to the `frame_count()` check this WO fixes — and not something the brief
asked to change. Noted here plainly rather than folded into "the fix
didn't work": the fix's job was "don't permanently abort on the liveness
sample," and it did exactly that. See "Known residual gap" below.)

**Injection 2 — full success, pipe listening, same running process** (a
save had since loaded in that same game instance; injected a second,
freshly-built copy of the DLL from a different directory, since Windows
will not re-run `DllMain` for an already-loaded module path — same
technique `VERIFICATION-REPORT.md`'s own "second copy, separate directory"
retry used):

```
[15:41:53.771] MAIN: hooked WHGame.dll!IAT[C_ModulesManager::Update] original=...
[15:41:54.772] MAIN: 25 frames after ~1000 ms -- tick is live
[15:41:54.777] WALK: SUCCESS with layout {type,type,data}/24 -- compare SoulCount against the HTTP API
[15:41:54.831] PIPE: listening on \\.\pipe\kcdmp
[15:41:54.872] SAMPLE: tracking 31 souls within 60 m
[15:41:57.917] SAMPLE: tracking 31 souls within 60 m
```

**Both required pieces of evidence, confirmed**: a nonzero frame count
(`25 frames after ~1000 ms`) and **the pipe listening**
(`PIPE: listening on \\.\pipe\kcdmp`), with the sampler actively tracking
souls afterward. This also confirms **no regression** on the already-working
fast path: with a save already loaded, the new polling code gets its first
successful sample on the very first 1-second check, identical timing to
the old code's single sample (`"25 frames in ~1s"` was the exact figure
`VERIFICATION-REPORT.md` measured for manual injection into an
already-running game).

## Known residual gap, honestly flagged for a future session

The `frame_count()` liveness check now retries correctly. The **soul walk
that runs immediately after it does not** — `run_sync`'s 5-second wait is
unchanged, unretried, and (Injection 1 above) can still fail if injection
lands in the narrow window where the tick has started but a save has not
actually finished loading (sparse/menu-only ticking). This is a different,
smaller-radius version of the same underlying shape of bug, discovered by
this session's own test, not by the original brief. Not fixed here —
scope was "pick one of the two named fixes, don't half-do both," and
retrying the walk is neither of them. Flagged for whoever picks this up
next; the fix, if wanted, is the same shape (poll/retry `run_sync` instead
of giving up after one 5s attempt).

## What this does not change

- No change to `main_thread.cpp`'s `run_sync`, hook mechanism, or the pipe
  protocol itself.
- No change to `KCDMP_launcher`'s CONNECT-gated flow beyond the regex fix
  above — the two-stage Launch/Connect UI, the "no retry across a failed
  verification" limitation it documents, and the 8-second verification
  window are all unchanged.
- `WaitForInjectableAsync` (waits for `WHGame.dll` to be loadable before
  offering CONNECT) is unchanged — this WO did not touch when injection is
  *offered*, only what the DLL itself does once injected.
