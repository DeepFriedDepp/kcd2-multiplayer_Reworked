# WO-81 — relay claim-lifecycle logging + contested-claim detector (findings)

Evidence tiers as in WO-54/58/59/60/66: **observed** (a run this session,
cited) / **code-verified** (read or written directly in current source) /
**wire-verified** (exercised against a real relay process on this machine, no
game involved) / **inconclusive**. Nothing below is rounded up.

Mandate: a 2026-09-11 field session reported NPC jitter that seemed to get
worse specifically when the two players stood close together, "as if it
fought over authority." The relay's claim table (`ClientHandler._npcClaims`,
WO-39/60/66) had never logged a grant, a release, or a reassignment — only
WO-66's rejections. This WO gives the claim system a voice, mirroring WO-66's
`[TAG] detail` + counter shape, so the next field session can actually see
what the claim table decided instead of inferring it from puppet behavior.
Not a fix: the claim system's decisions are unchanged everywhere in this WO.

---

## 1. Phase 0 — ground truth

### 1.1 Does the relay parse/cache player positions already?

**Code-verified, partial.** `ClientSession.RunAsync`'s Position (0x01) branch
(lines ~491–499, pre-WO-81) parses `x`/`y`/`z`/`rotZ`/`flags` out of every
packet to build the outgoing Ghost packet, then calls
`_broadcastService.Broadcast(...)` and discards them — `TcpBroadcastService.
Broadcast` only enqueues Ghost packets to other clients, it never stores
anything. So the relay sees every position it needs but **retained none of
them** before this WO. Adding the distance-correlation cache was therefore
the "small addition" case Phase 0 was asked to determine, not new parsing: a
one-line call (`_clientHandler.RecordPlayerPosition(this, x, y, z)`) right
after the existing parse, into a new `Dictionary<byte, (float X, float Y,
float Z)>` on `ClientHandler`, cleared on disconnect the same way
`ClearNpcClaimsFor` already is (`TcpSocketService.cs`'s disconnect
continuation).

The cache is read-only from the claim system's point of view — grep-verified:
`_playerPositions` appears in exactly three places in `ClientHandler.cs`
(`RecordPlayerPosition`'s write, `ClearPlayerPositionFor`'s removal, and
`DistanceBetweenLocked`'s read) and none of `RouteNpcState`'s accept/reject
branches touch it. It cannot become a gameplay-logic dependency by accident
because nothing in the accept/reject path calls the one method that reads it.

### 1.2 Does the relay write a persistent log file, and does Collect Logs bundle it?

**Code-verified: no, and no.** `dotnet/KcdMp.Server/appsettings.json`'s
Serilog section, before this WO:

```json
"Using": [ "Serilog.Sinks.Console" ],
"WriteTo": [ { "Name": "Console" } ]
```

Console-only. WO-66's own progress doc claimed its `[WO66-REJECT]` lines
would be "greppable in the standard log bundle" — that was never true, and
tonight's real two-player field session confirmed it the hard way: **neither
host nor joiner's Collect Logs zip contained any relay output**, because
there was no relay log file to collect. `KCDMP_launcher/Components/Shared/
LogBundle.cs`'s `Collect` method (the tester diagnostics bundle behind the
"COLLECT LOGS" button) bundles `kcd.log`, the native mirror log, log backups,
the agent's three log files, and the launcher's own `app*.log` — no relay
path existed in the method at all, `code-verified` by reading it end to end.

The fix turned out to be cheaper than "the bigger case" the session prompt
anticipated: `KcdMp.Server.csproj` **already references `Serilog.Sinks.File`
7.0.0** — not for its own logging, but so a merged self-contained publish
folder (relay + launcher + agent flattened together) doesn't crash at
startup when `Serilog.Settings.Configuration` probes every `Serilog.*.dll`
next to the executable and finds the launcher's own File-sink DLL not listed
in the relay's `.deps.json` (see the csproj's own comment, dated to whichever
WO first hit that crash). The package was present and unused; only
`appsettings.json`'s `Using`/`WriteTo` needed the File entry.

### 1.3 A second, unplanned Phase 0 finding: the OTHER relay test scripts never load appsettings.json

**Code-verified, then wire-verified the hard way while building this WO's own
test.** None of the existing `Test-*Relay.ps1` scripts (`Test-
NpcClaimValidation.ps1`, `Test-TimeSkipRelay.ps1`, `Test-ItemSyncRelay.ps1`)
pass `-WorkingDirectory` to `Start-Process` when launching the relay exe.
`WebApplication.CreateBuilder`'s default content root is the process's
current directory, and `appsettings.json` loads relative to that — so these
scripts' relay processes inherit whatever directory the PowerShell session
itself was started from, which has no `appsettings.json`, and **every config
value silently falls back to its hardcoded C# default** (`GetValue(key,
fallback)`). Nobody ever noticed because the fallbacks (40.0 m/s, 2.0 m
slack, port 5273 vs. their own `$env:ASPNETCORE_URLS` override, etc.)
numerically match `appsettings.json`'s own shipped values.

This is out of scope to fix (those scripts still pass; their assertions never
depended on a file that was, unbeknownst to them, absent) but it directly
shaped this WO's own new test: `Test-NpcClaimLifecycle.ps1` deliberately DOES
set `-WorkingDirectory` to the relay's own bin folder (so `appsettings.json`
— and therefore the new Serilog File sink and `NpcClaimValidation` defaults —
actually load), and therefore also has to override `--Urls` on the command
line (added last in `Program.cs`'s configuration chain, so it wins) to avoid
fighting `appsettings.json`'s fixed `http://0.0.0.0:5273` for the port a
real, already-running relay from tonight's field session held throughout
this work (confirmed via `Get-NetTCPConnection -LocalPort 5273`; never
touched).

---

## 2. Phase 1 — claim lifecycle logging

Shipped in `ClientHandler.RouteNpcState` and `ClientHandler.ClearNpcClaimsFor`
— the same two methods WO-66 instrumented, no new call sites needed for
grant/release/reassignment. New tag family `[CLAIM]`, mirroring `[WO66-
REJECT]`'s `Information`-level, one-line-per-event shape:

- `[CLAIM] granted npc=<name> owner=<id> pos=(x,y,z)` — a name with no prior
  release on record (see reassignment logic below).
- `[CLAIM] released npc=<name> owner=<id> reason=expiry|disconnect
  heldForSec=<n>` — `heldForSec` is `now - GrantedUtc`, a new field added to
  the `_npcClaims` tuple (previously only `LastUtc`, the last-*refreshed*
  time) specifically so a release can report how long the claim actually
  lasted, not just how stale its last packet was.
- `[CLAIM] reassigned npc=<name> prevOwner=<id> newOwner=<id> gapSec=<n>` —
  see §3 for what `gapSec` measures and the bug that definition caught.

Refreshes (an already-owned claim's routine heartbeat) are deliberately not
logged, per the brief — that runs at the ~250 ms emit cadence and would drown
the signal exactly as WO-66's own doc warned about tagging the WO-39
echo-mute.

**Counters live on a new sibling endpoint, `GET api/information/npc-claims`**
(`NpcClaimCounters`: `Grants`, `Releases`, `Reassignments`, `Contested`,
`ContestedByNpc`), not folded into WO-66's `npc-validation`. Different
concern: `npc-validation` is a tally of *rejected* packets; this is lifecycle
events on claims the relay *accepted*. Per-NPC breakdown is kept only for
`Contested` — grants/releases/reassignments happen for any ordinary claim use
and a per-NPC table for those three would just be a bigger version of the
same totals; `Contested` is the rare, actually diagnostic signal this WO
exists to surface, so it alone gets the breakdown.

---

## 3. Phase 2 — the contested-claim detector

### 3.1 Two paths, one log tag

`[CLAIM-CONTESTED] npc=<name> prevOwner=<id> newOwner=<id> gapSec=<n>
distanceBetweenPlayers=<meters|unknown>`, fired from two places:

1. **Reassignment path** — a grant on a name that has a recent-enough prior
   release on record (see `_recentReleases`, §2), where the elapsed gap is
   under `NpcClaimValidation:ContestedGapSeconds` (config-backed, default
   `10.0`).
2. **Stale-owner-rejection path** — WO-66's existing gate
   (`claim.OwnerId != sender.Id`), where the current claim's own `LastUtc` is
   under the same threshold — i.e. someone tried to take a claim that is
   still actively live, not one quietly decaying toward expiry.

### 3.2 A property of the constants, not a coincidence

**Code-verified, worth stating explicitly so nobody misreads the counter
later**: `Protocol.NpcClaimTimeoutSeconds` is `5`; the shipped
`ContestedGapSeconds` default is `10.0`. A stale-owner rejection can only
fire while `claimed` is still `true`, which by construction requires
`now - claim.LastUtc <= NpcClaimTimeoutSeconds` (5s) — always under the 10s
default threshold. **Under shipped defaults, every single stale-owner
rejection is therefore also a contested event.** This is not double-counting
or a bug: a rival being rejected specifically *because* the claim is live is
exactly the "fought over authority" shape the field report described, just
observed via the rejection path instead of the reassignment path. The
reassignment path is where the detector actually discriminates — a quick
handoff (§3.3, T4) vs. a slow one (T5) genuinely differ under the same
constants.

### 3.3 A real bug the test caught before it shipped

The first implementation computed a reassignment's `gapSec` as `now -
<the moment the stale claim was removed>`. That moment is **always the same
instant as the reassignment itself** for the expiry-driven path: removal is
lazy (only checked when some later packet arrives) and, when that packet
is the reassignment, the removal and the grant happen inside the same
`RouteNpcState` call with the same `now`. `Test-NpcClaimLifecycle.ps1`'s T5
case (an intentionally slow, 17s-gapped reassignment expected to read as
*not* contested) instead logged `gapSec=0.0` and fired `[CLAIM-CONTESTED]`
regardless of how long the wait actually was — the detector was structurally
incapable of ever reporting "slow."

Fixed by storing the released claim's own `LastUtc` (its last accepted
packet, captured *before* removal) in `_recentReleases` instead of the
removal instant, so `gapSec = now - <previous owner's last real activity>` —
the genuine silence duration a rival interrupted, immune to when the lazy
removal happened to run. Re-verified: T4 (a deliberate ~6s reassignment)
reads `gapSec≈6.8` and fires contested; T5 (~17s) reads `gapSec≈17.8` and
does not. This is exactly the kind of defect the WO's own thesis is about —
an unlogged/unverified decision looking fine until someone actually checks
what it says.

### 3.4 Distance correlation

Read from the WO-81 position cache (§1.1). If either session has never sent
a Position packet, logs `distanceBetweenPlayers=unknown` rather than a
fabricated or stale number — wire-verified (`Test-NpcClaimLifecycle.ps1` T6,
a peer that never sends Position contesting a claim). Otherwise a plain
Euclidean distance, formatted `F1`; wire-verified against a real 3-4-5
triangle (peers at `(0,0,0)` and `(3,4,0)` → logged `5.0`, T3/T4).

### 3.5 Default-on reasoning

`NpcClaimValidation:ClaimLifecycleLogging` defaults to `true` (config-backed,
overridable). A claim transition happens orders of magnitude less often than
a per-tick position/NPC-state update — WO-39's own claim shape refreshes at
the ~250 ms emit cadence, but grants/releases/reassignments are rare events
against that — so there is no real cost argument for shipping this off, and
the project is actively in a bug-hunting phase where an operator having to
discover and flip a flag before the *next* incident is strictly worse than
paying a handful of extra log lines per session. Wire-verified that the gate
actually gates both the `[CLAIM]`/`[CLAIM-CONTESTED]` lines and the
`npc-claims` counters (`Test-NpcClaimLifecycle.ps1` T7: a real grant against
a relay started with `--NpcClaimValidation:ClaimLifecycleLogging false`
produces neither).

---

## 4. Phase 3 — wiring the relay log into Collect Logs

1. **Serilog File sink** added to both `appsettings.json` and `appsettings.
   Development.json` (`Using: [Console, File]`, `WriteTo: [Console, {File,
   path: "relay.log", rollingInterval: Day, retainedFileCountLimit: 10}]`),
   the exact rolling shape the launcher's own `app.log` already uses
   (`KCDMP_launcher/Program.cs`). Relative path resolves against the
   process's working directory — which is the exe's own folder both when the
   launcher starts it (`Home.razor.cs`'s `OpenHostModal` already sets
   `WorkingDirectory = Path.GetDirectoryName(relayPath)`) and when this WO's
   own test starts it, so `relay<yyyyMMdd>.log` lands next to `KcdMpServer.
   exe` in both the real and the test case. Observed: a real relay run
   produced `relay20260911.log` with correctly formatted `[INF]` lines
   including a genuine unhandled startup exception (the port-5273 collision
   from §1.3), proving the sink also captures `Error`-level output, not just
   the new `[CLAIM]` lines.

2. **`LogBundle.Collect`** gained a third parameter, `relayDirectory`
   (default `""`), and a `relay*.log` collection block identical in shape to
   the existing `app*.log` block — same `DirectoryInfo(...).GetFiles(...).
   OrderByDescending(LastWriteTimeUtc).Take(2)` idiom, same `try/catch`, same
   "take the two newest" reasoning (a session straddling midnight).

3. **Host-only, gracefully** — confirmed the existing pattern rather than
   inventing a new one: `LogBundleAgentDirectory` in `Home.razor.cs` already
   resolves unconditionally from `settings.AgentPath` regardless of whether
   the agent is currently running, and `AddIfPresent`'s `File.Exists` check
   is what actually makes a joiner's missing file a silent no-op rather than
   an error. `LogBundleRelayDirectory` mirrors that exactly: resolves
   `Path.GetDirectoryName(ResolveAgainstLauncher(settings.RelayPath))`
   unconditionally, never checking whether `hostedRelayProcess` is currently
   set. A joiner (no relay ever run from this install) or a host who hasn't
   hosted yet both produce a `relayDirectory` with no `relay*.log` in it,
   which `AddIfPresent` already skips — no new branching needed, no
   misleading empty entry, code-verified by reading `AddIfPresent`'s
   `File.Exists` guard.

4. **Retention** — `rollingInterval: Day` means a single day's file is never
   truncated or overwritten mid-session (a play session is hours, not days);
   `retainedFileCountLimit: 10` only prunes *older days'* files. No
   `fileSizeLimitBytes` cap was added — Serilog's File sink has none by
   default, and a session's claim-event volume (rare events, not a per-tick
   stream) cannot plausibly approach a size worth capping. No truncation risk
   found for a typical session.

5. **End-to-end verified, not assumed.** Built a throwaway console harness
   (`ProjectReference` to `KCDMP_launcher.csproj`, not committed — same
   "real code, not a mock, but not a permanent fixture" practice as WO-80's
   own harness) that calls `LogBundle.Collect` directly. Ran a real relay,
   generated a real grant + a real contested rejection via synthetic peers,
   then ran the harness against that relay's own bin folder. The produced
   zip (`KCDMP-logs-20260911-155250.zip`, deleted after inspection — this
   session's own test artifact, not the maintainer's data) contained
   `relay20260911.log` at 1,438 bytes with the exact `[CLAIM]`/`[CLAIM-
   CONTESTED]` lines generated moments before, alongside the pre-existing
   `kcd.log`/`app*.log`/`logbackups` entries, confirming this WO's addition
   composes with the bundle rather than replacing anything.

6. **The field-session checklist**: no committed checklist file in this repo
   mentions a manual "grab the relay log" step (`docs/WO-38-tester-
   checklist.md`, the one checklist-shaped doc found, says nothing about
   relay logs at all) — it is an informal, ad-hoc practice on the maintainer's
   side, not something to edit here. Noted for the maintainer: that manual
   step is now redundant now that Collect Logs bundles it automatically.

---

## 5. Test results (all observed this session)

| Suite | Result | Notes |
|---|---|---|
| **Test-NpcClaimLifecycle (new)** | **28/28** | T0 baseline; T1 grant; T2 release/disconnect; T3 contested via stale-owner rejection + 5.0 m distance; T4 reassignment quick → contested (gap≈6.8s); T5 reassignment slow → not contested (gap≈17.8s); T6 unknown-distance contested; T7 `ClaimLifecycleLogging=false` produces zero `[CLAIM]` lines and all-zero counters |
| **Test-NpcClaimValidation (WO-66 regression)** | **29/29 unchanged** | All four original rejection gates, counters, and capacity/disconnect behavior untouched |
| Test-Sessions | 22/22 | |
| Test-Combat | 14/14 | |
| Test-TimeSkipRelay | 35/35 | |
| Test-ItemSyncRelay | 11/11 | |
| Farkle unit tests | 59/59 | |
| dotnet build (full solution, 7 projects) | clean | 0 errors, 0 warnings introduced (1 pre-existing `ServerList.razor` nullability warning, unrelated) |
| Test-Dice.ps1 | **1 pre-existing failure, confirmed NOT a WO-81 regression** | `same seed -> same final scores` fails intermittently (also failed `same seed -> same outcome` on one run) across 4 consecutive runs. Reproduced identically on the untouched `main` baseline via `git stash` (2 runs, both failed the same assertion with different score values each time) before restoring this WO's changes. Pre-existing flakiness in Farkle/dice test timing, unrelated to the relay's NPC-claim path; out of scope for this WO, not fixed |
| Test-Pipe | not run | requires a live game + DLL injection; this WO touches no pipe path (relay, one test script, and launcher log-bundling only) |

---

## 6. Files touched

- `dotnet/KcdMp.Server/Features/ClientHandling/ClientHandler.cs` — `_logger`
  field, WO-81 config fields, `_npcClaims` tuple gains `GrantedUtc`,
  `_recentReleases`/`_playerPositions` caches, grant/release/reassignment/
  contested logging + counters, `RecordPlayerPosition`/`ClearPlayerPositionFor`
- `dotnet/KcdMp.Server/Features/ClientHandling/NpcClaimCounters.cs` — new
- `dotnet/KcdMp.Server/Features/ClientHandling/ClientSession.cs` —
  `RecordPlayerPosition` call in the Position (0x01) receive path
- `dotnet/KcdMp.Server/Features/Tcp/TcpSocketService.cs` —
  `ClearPlayerPositionFor` on disconnect
- `dotnet/KcdMp.Server/Features/ServerInformation/Controllers/
  InformationController.cs` — `npc-claims` endpoint
- `dotnet/KcdMp.Server/appsettings.json`,
  `dotnet/KcdMp.Server/appsettings.Development.json` — Serilog File sink,
  `NpcClaimValidation:ClaimLifecycleLogging`/`:ContestedGapSeconds`
- `KCDMP_launcher/Components/Shared/LogBundle.cs` — `relayDirectory` param +
  `relay*.log` collection
- `KCDMP_launcher/Components/Modals/ReportBugModal.razor` — `RelayDirectory`
  parameter, threaded into `LogBundle.Collect`
- `KCDMP_launcher/Pages/Home.razor.cs`, `Home.razor` —
  `LogBundleRelayDirectory`, wired to `ReportBugModal`
- `tools/Test-NpcClaimLifecycle.ps1` — new suite

No engine, session-framework, or Lua changes. No protocol/wire change — this
WO adds zero packet types and zero fields to any existing one; everything is
relay-internal bookkeeping and an HTTP/log surface. No `VERSION` change (user
owns versions, `docs/VERSIONING.md`).
