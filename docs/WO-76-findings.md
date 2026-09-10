# WO-76 — relay/native hygiene, test suite repair, discriminator data, doc corrections

Implementation session, 2026-09-10. Every fix here had its root cause and
remedy already specified by WO-A1 (unmerged, no committed doc — cited from
this session's own prompt) and `docs/WO-75-audit-findings.md`; nothing here
was re-diagnosed. Companion: `docs/WO-76-progress.md`.

Evidence tiers, same discipline as WO-75:
**(observed)** seen this session — a command run here, a test suite executed
here, a build that succeeded or failed here ·
**(code-verified)** read directly in the source tree ·
**(read-but-unrendered)** stated by a prior doc, not re-checked here ·
**(inconclusive)** the evidence does not settle it.

Privacy: no real IP, hostname, personal name or user-specific path appears in
this document.

---

## 0. Ground truth (Phase 0)

- (observed, GitHub API) **PR #3 is open, unmerged** — "Kcd2mp/split kdcmp
  lua" (`F02K/kcd2-multiplayer_Reworked-help:kcd2mp/split-kdcmp-lua` →
  `main`), 2 commits, mergeable. Its file list includes the ghost/session-id
  width change (`dotnet/KcdMp.Protocol/Protocol.cs`, `ClientSession.cs`,
  `ClientHandler.cs`, `GameBridge.cs` and others converting `byte` ids to
  `uint`, alongside an unrelated Lua-file-split). Not merged, so the byte
  width is still live on `main`.
- (code-verified) `ClientSession.cs:34` (pre-fix): `public byte Id { get; } =
  (byte)Interlocked.Increment(ref _idCounter);` — confirms the byte width
  directly from source, not from any prior doc's number. **Decision: the
  Id-wrap pool item is in scope, not moot** (Phase 1 item 4).
- (code-verified) `Protocol.Version = 6` (`Protocol.cs:618`); next free type
  byte was `0x36` before this session, now `0x37` after claiming `0x36` for
  ServerFull (Phase 1 item 1).
- `docs/WO-A1` findings are not committed to this repo; this session worked
  from the WO-76 prompt's own citations of them (F1 ServerFull, F3 run_sync
  started-path timeout, F5 MaxPlayers clamp, F7 capacity test) and cross-
  checked each against `docs/WO-75-audit-findings.md` §1/§2, which
  independently records the same four items (as "PR #1 merge message only")
  plus their exact code locations.

---

## 1. Phase 1 — small, independent fixes

1. **ServerFull (0x36) reject packet.** Root cause (WO-75-audit s1): a full
   relay closed the socket with no packet; the client's generic "expected
   Ack" failure path could not distinguish "full" from any other refusal and
   retried every 3 s forever, burning one pooled id per attempt (this only
   became a *bounded* problem once item 4 landed — before that, every
   accepted TCP connection burned a never-recycled counter value regardless).
   Added `Protocol.ServerFull = 0x36` with a 1-byte `[maxPlayers]` payload
   (the next free type byte, confirmed from `Protocol.cs` directly, not
   assumed); `ClientSession` sends it before closing on a full-relay
   rejection; the client throws `ServerFullException` and `RunLoopAsync`
   treats it as fatal, the same way it already treats
   `ProtocolVersionMismatchException`. `Test-NpcClaimValidation.ps1`'s V7
   capacity check now asserts the packet (type + echoed maxPlayers), not
   silence. (observed) 29/29 on this suite after the change.

2. **MaxPlayers clamp.** Root cause (WO-75-audit s1, s7.2): `ServerInfo:
   MaxPlayers` was read unclamped; `0` bricks the relay silently
   (`TryMarkReady`'s count-vs-limit check can never pass). Clamped to
   `Math.Max(1, configured)` in `ClientHandler`'s constructor; logs a warning
   when clamping occurred and the effective limit unconditionally at
   startup (`ILogger` now injected into `ClientHandler`, the same DI pattern
   `TcpSocketService` already uses).

3. **`run_sync` started-path timeout.** Root cause (WO-75-audit s2; WO-A1
   F3): `main_thread::run_sync` deliberately waits **unbounded** once a
   queued task has started — returning early there would invalidate
   references the caller's stack-captured lambda holds, the exact
   use-after-free PR #1 already fixed for `run_sync`'s own internal state.
   That guarantee is correct and was left untouched. The actual defect is
   one level up: `pipe_server.cpp`'s six `run_sync` call sites captured their
   output (`ok`, `info`) by reference from the pipe thread's own stack, so a
   hung main thread (a wedged frame) froze the entire `serve()` loop
   forever — no timeout, no log line, the next pipe request never read.

   Fix: each call site's captured state now lives in a `shared_ptr`-owned
   heap struct (`PipeSyncState<T>`), mirroring PR #1's own pattern one layer
   up; the actual `run_sync` call moves onto a detached helper thread, and
   `serve()` waits on its *own* bounded timeout (`run_sync_bounded`,
   5000 ms) against that shared state instead of `run_sync`'s unbounded one.
   If the bound elapses, `serve()` logs it explicitly ("is still waiting on
   the main thread past 5000ms -- the frame loop may be hung"), replies
   failure, and goes back to reading the pipe; the helper thread and
   `run_sync`'s own wait are left running to finish (or not) on their own —
   safe now because nothing on the pipe thread still references their
   captured state.

   (observed) Compiled clean with the project's mandated MSVC 19.44 / CMake
   toolchain (found at
   `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools`, not on
   PATH — matches the durable-context note), zero warnings, both a targeted
   rebuild of the two touched files and a full link. **Not exercised against
   a live injected game** — none available this session (confirmed: no
   `KingdomCome.exe`/`WHGame.dll` process, port 1403 not listening). `Test-
   Pipe.ps1` was therefore **not run** — see §5.

4. **Id-wrap free-list pool.** In scope per §0. `ClientSession.Id` changed
   from an ever-incrementing `static int` counter (assigned at construction,
   before handshake or capacity checks — so every accepted TCP connection
   burned one, including probes and rejected-for-full attempts) to a
   `Queue<byte>` free-list of 0–255, reserved only in `ClientHandler.
   TryMarkReady` (a handshake that actually completes) and released in
   `RemoveClient` on disconnect. `ClientSession.Id`'s setter is now `internal`
   and the value is meaningless before `IsReady` (documented on the
   property; the two `TcpSocketService` disconnect-log fallbacks that used
   to print a stale `id=0` for a never-ready session now say `"(not ready)"`
   instead).

   (observed) `Test-NpcClaimValidation.ps1` 29/29, `Test-Sessions.ps1` 22/22,
   `Test-Combat.ps1` 14/14, `Test-Dice.ps1` 15/15 (fresh relay), `Test-
   TimeSkipRelay.ps1` 35/35, `Test-ItemSyncRelay.ps1` 11/11 — all run against
   the same long-lived relay process in sequence at one point, confirming ids
   are handed out and recycled correctly across repeated connect/disconnect
   churn from independent suites, not just within one script's own peers.

5. **`kdcmp.lua:3589` nil reference.** Root cause (WO-75-audit s3):
   `KCD2MP_UpdateGhost`'s diagnostic line read `raw_vx`/`raw_vy`, never
   defined anywhere in the file — a nil-arithmetic error on the function's
   last statement, swallowed by the agent's per-statement `pcall` on
   roughly every 40th ghost packet, which is why no `pkt#N` line has ever
   printed in any field log. Fixed by substituting `istate.vx`/`istate.vy`
   (the lerped velocity estimate the function already computes and stores a
   few lines above, at what was line 3536-3537), with an `or 0` guard for
   the first packet of a ghost's lifetime, before either has been assigned
   (dt is 0 on that call, so neither velocity branch runs). No Lua
   interpreter was available in this environment to execute-check the
   change; it is a two-line, syntactically simple local-variable
   substitution, reviewed by hand.

---

## 2. Phase 2 — test suite repair (docs/WO-75-audit-findings.md §5)

All six items fixed; a sweep of `tools/*.ps1` for other hardcoded
protocol/port/version literals found nothing else. One correction to the
WO-76 prompt's own line numbers: every citation in it (`:312`, `:363`,
`:24`, `:332-337`) was stale relative to the current file contents — the
described defects were all real and located, just not at those exact lines
(the same drift pattern this whole session exists to fix elsewhere).

1. `Test-NpcSyncE2E.ps1` Phase 2 — flipped from asserting the pre-WO-39 drop
   to asserting the post-WO-39 claim-and-broadcast, and reworded from
   "authority guard" to "claim guard". **Not run** (needs a live game +
   agent; none available — see §0).
2. `Test-CombatOutbound.ps1` — hardcoded handshake byte `3` (found at its
   actual current line 42, not `:312`) now derives `$PROTOCOL_VERSION` from
   `ProtocolVersion.ps1`, the pattern the other 15 synthetic-peer scripts
   already use. **Not run** (needs a live game + agent + DLL).
3. `Test-ReloadBehaviour.ps1` — same fix, at its actual line 60 (not `:363`).
   **Not run** (needs a live game + agent + a human to reload).
4. `Test-CombatVizE2E.ps1` — default `-RelayPort` corrected from 5273 (the
   HTTP listener) to 7778 (TCP), at its actual line 24 (this one number did
   match the prompt). **Not run** (needs a live game + agent).
5. `Test-Faces.ps1` — probe's spawn table corrected from nested `Properties.
   guidSharedSoulId` to flat `SharedSoulGuid`, matching `kdcmp.lua`'s
   `KCD2MP_SpawnGhost` shape since WO-22, at its actual line 46 (not
   `:332-337` — the whole file is 67 lines). **Not run** (needs a live game;
   it is also explicitly a throwaway scratch probe, not a committed test).
6. `Test-PlayerCombat.ps1` — added `-HttpPort` (default 7782) and set
   `ASPNETCORE_URLS` before starting its relay, so the HTTP listener is
   isolated the same way `Tcp:Port` already was (`appsettings.json`
   hardcodes `"Urls": "http://0.0.0.0:5273"`, so `-Port` alone never
   isolated the HTTP side). (observed) Ran clean, 21/21, **while a separate
   relay occupied the default 7778/5273 unmolested** — a real regression
   test of the isolation, not just a standalone run.

---

## 3. Phase 3 — discriminator: not run

`Test-NpcSyncE2E.ps1` Phase 3 needs a live game with two hand-placed NPCs
loaded, a connected agent, `AI.SetIgnorant` available via the in-game
console, and a synthetic peer streaming 4 Hz packets at both. **None of
that is available in this environment** (confirmed: no `KingdomCome.exe` or
`WHGame.dll` process running, `localhost:1403` not listening). No data was
gathered, none was fabricated. This matches the environment's own stated
expectation ("no live two-player session available or expected") and WO-77
(a separate, later session) is the one that needs this data before its own
work — that session's scope, not this one's, to schedule the field run.

---

## 4. Phase 4 — doc corrections

Applied directly to README.md, `docs/releases/RELEASE-NOTES-0.19.0.md`,
`docs/PROJECT-STATE.md`, `docs/MASTER-SERVER.md` — see the WO-76 commit for
the itemised list; each correction cites the source it was checked against
(`kdcmp.lua`, `Protocol.cs`, `NetService.cs`/`AppModels.cs`,
`docs/WO-68-findings.md`, `docs/VERIFICATION-REPORT.md`, or a suite run this
session) rather than trusting the prompt's own framing of the claim.

One correction to the prompt itself: the "punching a ghost still files a
crime, needs a native fix" quote is not present anywhere in the current
README.md (verified by direct search) — it lives in
`RELEASE-NOTES-0.19.0.md:70-72` instead, which is where the fix was applied.
`docs/WO-75-audit-findings.md` §6 attributes the same quote to both files;
only one of the two currently carries it.

`docs/WO-69-progress.md` got a pointer to WO-74's retraction, not a rewrite,
per instruction.

Discord badge: used the WO-76 prompt's own explicit default pattern (static
"Join" badge, the invite code it supplied), matching the row's existing
`?style=flat-square` shields.io convention. The live-member-count
alternative needs the numeric Discord guild id and the server's widget
enabled — neither was available to confirm, and the prompt itself said to
ask rather than guess for that variant; the default was explicitly
pre-authorized, so no question was needed for it.

Deferred, named but not attempted, per instruction: supersession banners on
old superseded WO-findings docs; retiring `docs/SESSION-PROMPT-next.md`; the
stale Flask section in `docs/LAUNCHING.md`.

---

## 5. Suite results this session

| Suite | Result | Notes |
|---|---|---|
| `Test-NpcClaimValidation.ps1` | **29/29** (observed) | Run twice — after Phase 1's ServerFull+MaxPlayers commit and again after the Id-pool reconstruction; both green |
| `Test-Sessions.ps1` | **22/22** (observed) | Not 23/23 as `PROJECT-STATE.md` claimed — corrected |
| `Test-Combat.ps1` | **14/14** (observed) | |
| `Test-Dice.ps1` | **15/15** (observed), fresh relay | Not 10/10 as `PROJECT-STATE.md` claimed — corrected |
| `Test-TimeSkipRelay.ps1` | **35/35** (observed) | Self-starting suite |
| `Test-ItemSyncRelay.ps1` | **11/11** (observed) | Self-starting suite |
| `Test-PlayerCombat.ps1` | **21/21** (observed) | Run twice: standalone, and again while a separate relay occupied 7778/5273 — confirms the Phase 2 isolation fix |
| `Test-Pipe.ps1` | **not run** | needs a live injected game; none available |
| `Test-NpcSyncE2E.ps1`, `Test-CombatOutbound.ps1`, `Test-ReloadBehaviour.ps1`, `Test-CombatVizE2E.ps1`, `Test-Faces.ps1` | **not run** (syntax-checked only, via `[System.Management.Automation.Language.Parser]::ParseFile`) | each needs a live game, several need a running agent or a human |

`dotnet build` succeeded with 0 errors for `KcdMp.Server`, `KcdMp.Client` at
every intermediate commit state (verified before each Phase 1 commit, not
just at the end). The native `KCDMP` target built clean (0 warnings) via a
scratch CMake+Ninja+MSVC configuration, cleaned up afterward.

---

## 6. What this session did not do

- Did not touch NPC puppet rendering, jitter, or interpolation — that is
  WO-77's explicit scope; nothing here came close to needing it.
- Did not run a live game, relay-under-game-load, or injector. Every
  relay/test-suite claim above not marked "not run" was executed against
  synthetic peers and a source-built relay only.
- Did not attempt Phase 3's data gathering by any means other than the
  live game the WO specifies — no synthetic approximation was built or
  substituted for it.
- Did not read PR #3's actual diff beyond the file list the GitHub API
  already returned (its content is out of scope; only its existence/state
  and the ghost-id-width fact mattered here).
