# WO-75 — project audit (Part 1)

Read-and-think session, 2026-09-06. No code changed. No `VERSION` change. No
action on PR #3. Companion: `docs/WO-75-jitter-design.md` (Part 2) and
`docs/WO-75-progress.md`.

Evidence tiers, applied to this session's own claims as strictly as to anything
it reviews, never rounded up:
**(observed)** seen this session — a command run here, or a value read out of a
log that is committed in this repo ·
**(code-verified)** read in the source tree at `8e836c5` ·
**(read-but-unrendered)** stated by a prior doc, not re-checked here ·
**(inconclusive)** the evidence does not settle it.

Privacy: no real IP, hostname, personal name or user-specific path appears in
this document. The working directory is written `<repo>`. Field-log values are
reported as counts and intervals only.

---

## 0. Ground truth this audit rests on

- (observed) Local `main` was **3 commits behind `origin/main`** at session
  start. PR #1 (max-players enforcement + write-path refactor + native
  `run_sync` hardening) was merged remotely on 2026-08-30. The session
  fast-forwarded (`git pull --ff-only`) before reading any code, so every
  code-verified claim below is against `8e836c5`, not `018d2d4`.
- (observed, GitHub API) PR state: **#1 merged**, **#2 closed unmerged**
  (32-bit ghost ids), **#3 open** ("split kdcmp lua", opened 2026-08-30).
  PR #3 was not read and is not acted on here. No doc in the repo mentions
  PR #2 or PR #3.
- (observed) `kdcmp/Data/Scripts/Startup/kdcmp.lua` is **7,867 lines**, not
  the "~2,400" that `PROJECT-STATE.md`, and this work order's own text, carry.
- (observed) `Protocol.Version = 6`; next free type byte **0x36**
  (`Protocol.cs:591`); all 55 type constants unique.
- (observed) Committed field logs (`docs/WO-38-test-logs`, `WO-40-test-logs`,
  `WO-58-test-logs`) were mined for numbers no prior doc had extracted:

  | measurement | value | source |
  |---|---|---|
  | In-process `ExecuteString` round trip (the interp pump runs back-to-back unbatched calls and prints its rate) | **p50 56 Hz ≈ 18 ms**, range 28–90 Hz, n=56 menu windows across 4 agent logs | WO-40 + WO-58 agent logs |
  | Lua state emitter output rate (`[KCD2-MP-DATA]` lines per second of the line's own `os.clock` field) | **41–45 lines/s** (a single 20 ms chain, frame-quantised) | WO-58 host + PlayerA kcd.logs |
  | Ghost interp heartbeat cadence (`TICK_ALIVE` every 250 ticks, timestamped by the nearest DATA line's clock) | **5.3–6.6 s** per 250 ticks ⇒ 21–26 ms/tick, one chain, no acceleration over ~5 min | same |
  | Agent position push cadence (`[pos]` lines, moving only) | p50 60 ms, n≈35k — confounded by the 5 cm change gate at walking speed; not a channel figure | 4 agent logs |
  | Emit-side duplication on the `npc_state` path (consecutive EVT lines, same NPC, byte-identical xyz) | **0 of 2,231 lines**; EVT `seq` monotonic, 0 duplicates | WO-58 kcd.logs (0.17.5, pre-WO-60) |
  | Puppet activity in those bundles | 0 `puppet tick started`, 0 `puppet start`, 0 `NPC-SYNC anim` — no machine in the WO-58 bundles ever received a puppet stream | same |
  | Menu markers in those bundles | 0 `[menu] local menu open` lines | same |

  The first row matters most: WO-30 measured the `ExecuteString` channel at
  60–130 ms warm through a PowerShell client, and WO-38 and WO-63 both built
  delivery-latency arguments on that figure. The agent's own in-process
  measurement, printed 56 times in the field, is ~18 ms. See §6.

---

## 1. Relay — verdict: **needs attention (specific)**

Healthy:
- (code-verified) Claim/engaged-hold semantics match WO-60/66 as documented:
  expiry needs both 5 s silence and 15 s since last engaged; rejects mutate
  nothing; first claim seeds the speed baseline unchecked; disconnect clears.
  `ClientHandler.RouteNpcState` + `ClearNpcClaimsFor` are the only writers.
  Wire-verified 23/23 + 35/35 per WO-66 (read-but-unrendered); no live session.
- (code-verified) Diagnostics surface exists: `GET api/information/npc-validation`
  counters, `[WO66-REJECT]` at Information level.
- (code-verified, PR #1) Client→relay writes now serialised behind one
  semaphore (`GameBridge.WritePacketAsync`); relay outbound is a bounded queue
  that coalesces `Ghost` packets per source. Both are sound.

Needs attention:
- **Byte-Id wrap — confirmed unfixed on `main`.** (code-verified)
  `ClientSession.cs:34`: `public byte Id { get; } = (byte)Interlocked.Increment(ref _idCounter);`
  Wraps after 256 connections in one relay lifetime; the 257th client gets
  Id 0. Consequences if two *live* sessions share an Id: `KCD2MP.ghosts` on
  every peer is keyed by that byte (one body for two players); the claim
  table's `OwnerId == sender.Id` test lets the impostor refresh or re-arm the
  other's claim; `PlayerHit` routes to the wrong target. WO-66 called it
  "theoretical"; a relay that stays up for weeks (WO-69 observed a survivor
  relay of that age) reaches 256 connections on reconnect churn alone. Fix is
  small (free-list of ready ids; PR #1's merge message already lists it).
- **PR #1 follow-ups are recorded only in a merge-commit message**, not in
  any doc: ServerFull reject packet (a full relay closes the socket with no
  packet — `ClientSession.cs:108-110`), `MaxPlayers` lower clamp (config
  `ServerInfo:MaxPlayers` = 0 refuses everyone, `ClientHandler.cs:33`),
  byte-Id pool, `run_sync` started-path timeout. They belong in a ledger.
- (code-verified) The bounded outbound queue (512) **disconnects** a client on
  overflow. Voice alone is 50 frames/s per speaker; a client stalled ~10 s
  during a multi-speaker session is now dropped where it was previously
  buffered. Reasonable, but new field behaviour with no live run.
- (code-verified) `Ghost` is the only coalesced type. `NpcStateDown` at
  4 Hz × 5 NPCs is not, which is correct today and would still be correct at
  the 10 Hz proposed in Part 2.
- Headless test coverage has holes at the core: no relay-only test asserts
  `0x01 Position → 0x02 Ghost`, `0x03 Name`, `0x04/0x05 Ping/Pong`,
  `0x06 Disconnect`, `0x07/0x08 Voice`, or `0x1A/0x1B Appearance` routing
  (code-verified by sweep of `tools/*.ps1`).

## 2. Native layer — verdict: **healthy where the pattern exists; the pattern was never retrofitted to the swing path**

- (code-verified) `script_context.cpp` carries the full integrity gate:
  manager vptr must equal the `C_ScriptContextManager::vftable` RVA; slots
  [2]/[7] must resolve to the expected RVAs; both prologues byte-compared;
  **one-way disarm on the first SEH fault** with a loud log block; refcount-
  aware set (read-before-write). This is the reference implementation.
- (code-verified) `combat_construct.cpp::ghost_swing` prologue-verifies its
  three RVAs once per process and fails closed on mismatch — but has **no
  vptr gate on the actor** (the probe path *reports* `isCPlayer`, the swing
  path does not check the class) and **no disarm on fault**: every faulted
  step returns `false` and the next swing packet retries the same call
  inside the game's update. WO-68's stated rationale for disarming ("a fault
  means our model of the engine is wrong; stop touching it") applies here
  verbatim and is not applied. This predates the pattern (WO-45/46), so it is
  a gap, not drift. Needs attention: a main-thread fault in a retried native
  call is the hang class WO-58 pinned.
- (code-verified) `dice_hook.cpp` sampler disables itself on the first SEH
  fault. Consistent with the pattern.
- (code-verified, PR #1) `main_thread::run_sync` now uses shared state, cancels
  a never-started task at timeout, and **waits unbounded once a task has
  started** (documented in the header as deliberate to avoid a use-after-free
  of the caller's captures). The trade is honest; the follow-up is recorded
  only in the merge message. `DLL_PROCESS_DETACH` cleanup removed and the pipe
  listener detached (loader-lock hygiene) — fine for a process-lifetime plugin.
- Not run this session: anything native (no game). `Test-Pipe` last observed
  PASS in WO-68.

## 3. Lua mod — verdict: **needs attention (specific)**

- (observed) 7,867 lines, ~250 functions, **~90 registered console commands**,
  of which roughly 40 are one-off probes and scratch spawners (`mp_probe_*`,
  `mp_test_*`, `mp_scan_*`, `mp_copy_npc`, `mp_read_adb`, `mp_spawn_knight`…)
  shipped in the release pak. Not harmful; it is the shape PR #3 proposes to
  split, which this session does not judge.
- (code-verified) Isolation/toggle machinery from WO-65/68/69 is coherent:
  `KCD2MP_ApplyGhostIsolation` states which side owns each half, verifies the
  dialog half by readback, emits an `isolate` event so the agent drives pipe
  0x07; `KCD2MP_ReassertGhostIgnorance` logs failure once per ghost and
  recovery once. Evidence discipline in comments is strong throughout: WO
  provenance, observed-vs-derived, and the "why not" of each rejected option.
- (code-verified) **Timer-chain liveness has a structural hole.** Every
  chain uses `tickAlive` (stale > 1.0 s ⇒ dead) and the agent re-arms
  `StartInterp`/`StartEmitter`/`StartNpcSync`/`StartItemSync` every **2.5 s**
  (PR #1 halved this from the previous ~5 s effective). A local menu
  *suspends* `Script.SetTimer` (WO-12/13 observed) but `ExecuteString` keeps
  running, so each re-arm during a menu longer than ~1 s finds a stale stamp
  and starts a **second chain**; on menu close both resume. The puppet chain
  has the same exposure through `KCD2MP_ApplyNpcState → StartNpcPuppet` on
  every inbound packet. WO-69 instrumented the puppet chain only. WO-54's
  live notes recorded "timer chains restarted on every menu close — not
  diagnosed" (read-but-unrendered). The two-chains-alive moment has never
  been directly observed; the committed WO-58 bundles cannot show it because
  they contain zero menu opens (observed). Full analysis and the fix shape
  are in Part 2 §3 (D3).
- (code-verified) Latent bug: `kdcmp.lua:3589` in `KCD2MP_UpdateGhost` reads
  `raw_vx`/`raw_vy`, which are **never defined** — every 40th ghost packet
  raises a nil-arithmetic error inside the agent's per-statement `pcall`.
  It is the function's last statement, so no state is harmed and the log line
  simply never prints; it is also why no `pkt#N` line appears in any field
  log.
- (code-verified) Ghost interp and puppet ticks both advance by a fixed
  per-tick factor, not by elapsed time; the menu pump therefore runs them at
  whatever rate the pump achieves (35–86 Hz, WO-13; the puppet pump is
  throttled to ~22 Hz). Not a defect on its own; it is what makes chain
  multiplication visible.

## 4. Installer — verdict: **healthy; two hygiene nits**

- (code-verified) WO-74's wiring is intact end to end: `ssInstall` stamps a
  FAIL-in-progress verdict; `ssPostInstall` sweeps managed-extension strays
  not in the manifest, verifies every APP and MOD entry by size + sha256, writes
  the verdict; `DeinitializeSetup` calls `ExitProcess(101)` when
  `VerifyFailed`. Manifest v2 is generated by one script after the pak rebuild
  and publish; the sweep-candidate extension set is identical across
  `KCDMP.iss`, `Apply-DirectInstall.ps1` and `Verify-Install.ps1`; manifest
  and sweep are both recursive, so the `MasterServer\` subfolder is covered.
- (observed) `installer/tests/SteamDetectProbe.exe` and `tools/probe-results.txt`
  are tracked in git despite matching `.gitignore` rules (added before the
  rules). Cosmetic.
- Unchanged and still open per WO-74: interactive Abort/Retry/Ignore path
  never watched; tier-3 clean-machine tests never executed.

## 5. Test suites — verdict: **needs attention (six mismatches, the Test-Dice family)**

Assertions that no longer match shipped code (all code-verified this session):

| # | Test | What it asserts | What the code does |
|---|---|---|---|
| 1 | `Test-NpcSyncE2E.ps1` Phase 2 (:444-456) | a non-authority `NpcStateUp` is **dropped** and moves nothing | since WO-39 an unclaimed name from a non-authority is a **claim** and is broadcast (`ClientHandler.cs:342-355`); Phase 2 fails against a correct stack |
| 2 | `Test-CombatOutbound.ps1:312` | handshake with literal protocol **3** | relay refuses anything but 6; the "derived, not copied" sweep (`ProtocolVersion.ps1`) missed this fourth script |
| 3 | `Test-ReloadBehaviour.ps1:363` | literal `$VERSION = 6` | passes only until the next bump |
| 4 | `Test-CombatVizE2E.ps1:24` | default `-RelayPort 5273` | 5273 is the relay's HTTP listener; TCP is 7778 (the WO-46 trap, left "documented" in WO-46 and never fixed) |
| 5 | `Test-Faces.ps1:332-337` | nested `Properties.guidSharedSoulId` spawn | the shipped spawn is flat `SharedSoulGuid` (WO-22); probes a mechanism the mod no longer uses |
| 6 | `Test-PlayerCombat.ps1` | "isolated relay on its own port, never touches 7778" | starts the relay without `ASPNETCORE_URLS`, so its Kestrel still binds 5273 and exits if any other relay is up |

Also: three self-starting suites hard-code the **Debug** exe path
(`Test-TimeSkipRelay`, `Test-ItemSyncRelay`, `Test-NpcClaimValidation`) and so
can never grade an installed relay — the exact blind spot that hid the
Test-Dice defect. `Test-Aggro*.ps1` expect a donor faction that exists only on
the dev playthrough's save. Coverage holes listed in §1.

## 6. Docs / ledger consistency — verdict: **needs attention; the headline docs mislead**

Committed docs that would send a fresh session the wrong way, in priority order.

**Docs claiming a state the code does not have:**
- `README.md:63,94` "Reactive ghost combat — working, always on, no toggle". Since
  WO-68 the default-on `mp_ghost_isolate` applies
  `switch_disabledHitBehavioralReaction`, and WO-68 **observed** "ghost
  fighting back — it does not". The README row is now false.
- `README.md:111-113` and `RELEASE-NOTES-0.19.0.md:70-72` say punching a ghost
  in front of a guard still files a crime and "needs a native fix". WO-68 fixed
  it natively and observed the guard not arresting (0.18.8). The same release
  note's own line 15 says the fix shipped.
- `RELEASE-NOTES-0.19.0.md:69` describes the gender fix backwards (the defect
  was male players rendering female); `:73` credits ghost yaw smoothing —
  `lerpAngle` landed on the **puppet** path in WO-69; ghosts already had it.
- `docs/MASTER-SERVER.md:173-174` says the launcher refuses a server on a
  different protocol version and shows release version on hover. `NetService`
  never maps either field into `ServerInfo`; no such gate or hover exists.
- `README.md:511` "the agent writes no log file" — it tees to
  `agent.log/.prev/.prev2` since WO-39 and the launcher bundles them.
- `README.md:75,317,427` "dice wagers not implemented" — wagers are on the
  wire (WO-33), parsed, and `mp_dice_wager` is registered.
- `PROJECT-STATE.md:181` NPC sync "off by default" — it is on
  (`kdcmp.lua:1852`); `:161-165` pipe opcodes omit 0x04/0x06/0x07; `:168`
  heading "Wire protocol v5" vs `Version = 6`; `:522` "~2,400-line";
  `:229-230` suite counts stale; `:3` "current as of 2026-07-28" over content
  through WO-48; `:459-470` "launcher never run against a real launch" vs the
  same-day `VERIFICATION-REPORT.md` observed-pass.

**Docs contradicting later evidence and never amended:**
- `docs/WO-69-progress.md:104-147` states as *(observed)* that the relay
  failed to cold-start because of a mismatched `Configuration.Abstractions`
  8.0.23 set. WO-74 showed no release ever shipped that assembly and that the
  directory read came through a sandbox shadow. WO-69-progress is unamended;
  the project memory note for this trap still leads with the retracted
  diagnosis and carries the WO-74 correction only as an appendix.
- `docs/WO-30-findings.md:58-62` measured `ExecuteString` at 57–167 ms
  (avg ~114) **through PowerShell**; `WO-38-findings.md:215` and
  `WO-63-findings.md` (cadence table, §2.3) restate it as the channel's
  warm cost and reason about delivery latency from it. WO-1 had already
  measured the same call in-process at ~13–42 ms (`WO-1-transport.md`), and
  the agent's own field figure is ~18 ms (observed, §0). The later docs
  picked the wrong one of two measurements the project already held. WO-63's "already up to ~400 ms
  behind" is therefore overstated by roughly 100 ms; the conclusion it drew
  (smoothing latency is cosmetic-dominant) survives, the premise does not.
- `docs/WO-57-findings.md:26-31` asserts WO-54 "never happened". Three WO-54
  docs and WO-58's bundle analysis say it did (2026-08-25).
- `docs/WO-32-findings.md:15,170` "off by default" vs `:279-285` "ON by
  default" in the same file; and `:72-74` "engine restores the NPC within 3 s
  of release" vs `WO-39-findings.md:289-292` "engine did NOT re-anchor him".
  WO-59 A1 still reasons from the WO-32 version. Release behaviour is
  schedule-dependent, not guaranteed — this matters for the release/resnap
  oscillator and is carried into Part 2.
- `docs/WO-69-findings.md:266-270` and `kdcmp.lua:1891-1897` say the send-side
  duplication is "same mechanism, same fix shape" as the puppet chain leak.
  Part 2 §3 shows the emitter's `moved` gate makes a Lua chain leak unable
  to produce byte-identical same-frame duplicates; that attribution is
  unsupported and the WO-58 bundles show zero duplicates on the pre-WO-60
  path (observed).
- WO-42 §3 (+0x54 field name), WO-40 (GetProcAddress-ability), WO-41
  (+0x278), WO-43/44 original verdicts, WO-65 (applier in RPGModule), WO-72
  (7× boot, 1920×1080, "no save-loading cvar"): each corrected by a later WO,
  none amended at source. A reader who lands on the earlier doc gets the wrong
  answer with no pointer forward.
- Memory/prompt attribution: the launcher duplicate-agent guard is WO-27 in
  the code comments (`Home.razor.cs:86-93,823-860`), not WO-58.

**Stale headline docs a new session might paste:**
- `docs/SESSION-PROMPT-next.md` is the WO-9-era prompt. Nearly every "must not
  re-derive" bullet is now false (aggro not achievable; faction manipulation
  off-limits; Python master never run; weapon sync not implemented). It should
  be retired or headed with a supersession banner.
- `docs/LAUNCHING.md` still carries the removed Flask master-server section
  and "launcher never run against a real launch".
- Release-notes gaps: 0.18.8 shipped as Setup + DirectInstall (WO-69) with no
  `RELEASE-NOTES-0.18.8.md`; 0.18.5/0.18.6 (the native crime fix) have none.

**Privacy / hygiene (observed, reported, not acted on — the maintainer's call):**
- `docs/WO-58-test-logs/**` and `docs/WO-40-test-logs/**` are committed field
  logs. They contain **3 distinct public IPv4 addresses** (28 occurrences) and
  tester identifiers. This session's own privacy rule would forbid committing
  them; they are already in history. Removing them from history is a
  force-push, an outward-facing action, and is not taken here.
- 15 docs (all `SESSION-PROMPT-*`, `HANDOFF-*`, `WO-22-nexus-mod.md` and
  others) carry the literal working-directory path including the maintainer's
  Windows username. Pre-existing; this session's docs use `<repo>`.

## 7. Backlog sweep — disposition for every recorded item

Sources: every `docs/WO-*.md`, `HANDOFF-*`, `ARCHITECTURE-*`,
`NATIVE-PLUGIN-findings.md`, `PROJECT-STATE.md`, README, release notes, and
the PR #1 merge message. Items grouped where several docs record the same
thing. Disposition: **OPEN** (still relevant) · **RESOLVED** (by later work,
cite) · **DROP** (moot or not worth carrying) · **MOOT-UNTIL** (blocked on a
named precondition).

### 7.1 NPC sync, authority, presentation

| Item | Recorded | Disposition |
|---|---|---|
| WO-60 proximity authority never live-verified; in-game `mp_npc_proximity off` flip unobserved; claim/hold × native paths never watched | WO-60 §3, WO-63, WO-69 | **OPEN** — the pending field session's primary purpose |
| WO-63 ordering gate: live-verify WO-60 raw before any puppet presentation change | WO-63:186-193 | **OPEN, refined** — Part 2 §6 proposes honouring its intent with a default-off toggle rather than a release-cycle serialisation; not bypassed |
| D1 gap-dashing (4 Hz emit vs 50 ms lerp) | WO-69 | **OPEN** — confirmed arithmetically; Part 2 is the design |
| D2 brain-fights-stream never tested; discriminator (`Test-NpcSyncE2E` Phase 3 + `AI.SetIgnorant`) never run | WO-69, WO-51 | **OPEN** — but `Test-NpcSyncE2E` Phase 2 is stale (§5 #1) and must be skipped or fixed first |
| D3 puppet chain leak suspected; instrument shipped, never fired | WO-69 | **OPEN, widened** — Part 2 §3: the same mechanism reaches every re-armed chain; a structural fix exists that needs no confirmation |
| Emit-side duplication "same mechanism" | WO-69:266-270 | **OPEN, re-graded** — attribution unsupported (Part 2 §3); capture raw EVT lines with `seq` in the field session before designing a fix |
| No footage of a walking puppet ever reviewed | WO-63, WO-69 | **OPEN** |
| Cadence raise 250→~100 ms held until interp watched live | WO-63:76-82,198 | **OPEN, re-costed** — Part 2 §4: at the 5-NPC cap the cost is negligible on every hop; ordering revised |
| Puppet Z floor raycast deliberately not ported | WO-63:89-94 | **DROP** unless a hover/sink symptom is reported |
| Whether 0x27 exposes sender identity for a velocity reset | WO-63:66-69 | **RESOLVED** — it does (`[sourceGhostId:1]`, `GameBridge.cs:2675`); Part 2's design does not need it |
| 15 s engaged-hold constant unmeasured | WO-60 §5 | **OPEN** — tune from field logs |
| Sharper engagement signals (LocalHit, 0x2C) not wired | WO-60 §5 | **OPEN** (WO-51 WO-B/C track) |
| 0x26 `hp` stored never written; no kill/loot arbitration | WO-49, WO-51, WO-60 | **OPEN** — design WO, two humans |
| Flow B (NPC→player hit) cross-machine never verified | WO-28, WO-51, WO-54 | **OPEN** — field session item |
| Radius gap / engagement asymmetry | WO-51 §1.4 | **RESOLVED by construction in WO-60** (non-authority claims + cue sampler on claimant), **unverified live** |
| Restart-cascade release/resnap oscillator | WO-59 A1 | **OPEN** — and the WO-32 "engine restores in 3 s" premise is contradicted by WO-39; release behaviour is schedule-dependent |
| Boundary flapping at 30 m | WO-59 A1 | **RESOLVED in code** (hysteresis 45 m, 8 m sticky bonus), unverified live |
| 50-NPC scale, receiver apply cost at 8–10 NPCs | WO-32, WO-39 | **DROP** for now — nothing asks for it; Part 2 keeps the 5-NPC cap |
| Dialogue during drive; combat NPC under external drive | WO-32, WO-38 O | **OPEN** — field observation only |
| Brain-suppression pilot `IEntity::Activate(false)` behind `mp_npc_suppress` | WO-64 WO-E, WO-67 hypotheses | **OPEN** — Part 2 §3 places it after the D1-vs-D2 discriminator, as WO-69 did |
| NPC sync default-ON pak not the build the 15/15 E2E ran against | WO-32-progress | **DROP** — many releases since |

### 7.2 Relay, protocol, capacity

| Item | Recorded | Disposition |
|---|---|---|
| Byte-Id wrap | WO-66:337-339, PR #1 msg | **OPEN** — confirmed unfixed (§1); small fix, should not wait |
| ServerFull reject packet | PR #1 msg only | **OPEN** — needs 0x36; also needs the launcher to show it |
| `MaxPlayers` clamp ≥1 | PR #1 msg only | **OPEN** — one line |
| `run_sync` started-path timeout | PR #1 msg only | **OPEN** — deliberate trade; record in a doc |
| Relay persistence | none propose it | **DROP** — WO-64 rejected it with reasons; relay stays stateless by design |
| Relay session tied to host's client (host hiccup cascades to joiners) | WO-54:336-340 | **OPEN, architectural** — no cheap fix; record |
| Master server: no WS rate limiting; unverified `Address` in announce; `MaxServers` not atomic; no VERSION stamping in csproj | WO-35, MASTER-SERVER.md, this session | **OPEN, low** — public-exposure hardening when a public master exists |
| Launcher auto-started master binds `0.0.0.0` | this session (code-verified) | **OPEN, low** — bind loopback unless hosting publicly |
| Locale-sensitive wire serialisation audit | WO-54:221-244 | **OPEN** — one grep-and-read pass; culture bugs already bit once |
| `TcpSocketService` fire-and-forget faults | WO-5 | **RESOLVED** — `ContinueWith` now logs faults (`TcpSocketService.cs:62-76`) |

### 7.3 Ghost identity, isolation, appearance

| Item | Recorded | Disposition |
|---|---|---|
| Soul collision: roster soul vs its own live world NPC (two bodies, one soul) | WO-69:87-92 | **OPEN** — not addressed; cheapest fix is excluding roster souls from `mp_npc_rescan` and puppeting; also a plausible mechanism for WO-40's "two guards phased into each other" |
| `SPAWN MISMATCH` fallback never executed | WO-69 | **OPEN, unexercisable** — no way to force it; accept |
| Save-load rebuild spawn path unobserved for the gender fix | WO-69 | **OPEN** — field session, cheap |
| Witness A/B (theft with only a ghost watching) | WO-68/69 | **OPEN** — needs a human at the keyboard |
| `crime_disableReport` value unevidenced; observer-side rows untried; store survival across save load; pathing walk-through | WO-68 §11 | **OPEN, low** |
| Nameplates via Soul display-name CryString (WO-B) | WO-64, WO-67 | **OPEN** — verify-first; offset contested even retail-side |
| Station-activity presentation (WO-C) | WO-64 | **DROP** until asked |
| Native equipment transaction | WO-64 | **DROP** — recorded recipe suffices |
| Soul-row hostility as aggro lever; fixed `SetParent` not wired into aggro path | WO-22/24/25, PROJECT-STATE | **DROP** — WO-26 showed reactive combat is already on by default; WO-68 now suppresses it by design; nothing wants this lever |
| Ghost de-escalation after a fight untested | WO-26 | **MOOT-UNTIL** isolation default changes — isolation suppresses the reactive combat that would need de-escalating |
| `Test-AppearanceE2E` 2 of 5 item classes never equip | WO-28, PROJECT-STATE | **OPEN** — reproducible, never chased |
| Unequip verification asymmetry; reappearing weapon | WO-10, README | **OPEN, low** |
| Female gear gap | WO-20/23 | **RESOLVED by removal** — roster is male-only since WO-69 |
| Hood/helmet exclusivity; write-latency variance | WO-9 | **DROP** — self-healing heartbeat; no field report |

### 7.4 Weather, time, misc sync

| Item | Recorded | Disposition |
|---|---|---|
| Weather reassert on receivers (drift between heartbeats; no weather read) | WO-64 WO-F, WO-51 | **OPEN, low** — a receiver-side re-apply every N s is ~10 lines |
| Weather arbiter E2E, reload convergence E2E, 0x30 damage E2E never run since install | WO-40, WO-51 | **OPEN** — field session |
| Multi-day forward clock write unverified | WO-59 | **DROP** — no report |
| Sleep pose for a sleeping player not wired | WO-40 brief | **DROP** until asked |
| Map markers | WO-38 B | **DROP** — closed as no route; UIAction map panel unstarted; no demand recorded |
| Forge damage bug | WO-38 D | **OPEN, unconfirmed** — one tester report, no repro |

### 7.5 Combat fidelity (native)

| Item | Recorded | Disposition |
|---|---|---|
| Swing zone mirroring; ranged swings; bow leaks fake melee events | WO-46/47/49/57 | **OPEN, low** — ranged is unwired by decision; the bow-leak guard clause is cheap and worth doing |
| Oversized sheathe path, shield/torch rows | WO-47 | **DROP** until a report |
| Blocks stay a Lua cue; paired sync-attack; `SetAction` on a ghost | WO-42/44/45 | **DROP** — research rungs beyond current need |
| Swing-path disarm-on-fault (§2) | this session | **OPEN** — small native change |
| `CombatPipe` stale reply after a 5 s timeout (late reply releases the semaphore; next command returns the previous result) | this session, `CombatPipe.cs:228-262` | **OPEN, low** — drain or sequence replies |
| `CombatPipe.ReadLoopAsync` awaits `OnLocalHit` inline; receive-loop decoupling; DLL pipe backpressure; publish-layout separation | WO-58 scoped-not-attempted | **OPEN** — the first two are the WO-58 hang coupling |

### 7.6 Dice, interactions, UI

| Item | Recorded | Disposition |
|---|---|---|
| Dice WIN payout port (`inventory:CreateItem`) lost to the WO-49 label collision; `ItemUtils.AddMoneyToInventory` still called | WO-49:12-19, WO-48 | **OPEN** — re-do; it is a real payout defect |
| `KCD2MP_SpawnArmoredNPC` calls unregistered `ItemManager.CreateItem` | WO-48 | **DROP** — debug spawner |
| Dice keybinds guessed for invite/accept/decline; `OverrideNextThrow` shape | WO-6/25 | **DROP** — console path works; no demand |
| `InteractionKind.Duel` wire value with zero handling; Emotes/Duelling unstarted | WO-7, brief | **OPEN, product** — the maintainer's roadmap call |
| Console `%LINE` "Too many arguments" parsing bug | WO-43/44 | **OPEN, low** |
| Ghost respawn corruption under a reused id | WO-43 | **OPEN, low** — never reproduced since |
| Overlay images / own `.gfx` / ImGui routes | WO-6 | **DROP** |

### 7.7 Launcher, agent, installer, tooling

| Item | Recorded | Disposition |
|---|---|---|
| Launcher UI flow with a hostname never driven | WO-55 | **OPEN** — field session, cheap |
| `ResetFilters` sets `hideUnreachable = true` (hides ICMP-dropping DDNS hosts) | this session | **OPEN, low** — one line |
| `WaitForInjectableAsync` proceeds on timeout; its failure message unreachable | this session | **OPEN, low** |
| Version-IPC compares only the first peer; launcher IPC ports never passed to the agent | this session | **OPEN, low** |
| Discord `Assets.Merge` NRE still fires in the field | WO-50/54 | **OPEN, low** |
| Voice mixer inputs never removed on `RemovePlayer` | this session | **OPEN, low** — leak across reconnects |
| Installer Ignore path; tier-3 clean machine; unsigned exe | WO-8/74 | **OPEN** — human in front of the wizard |
| Stale test assertions (§5) | this session | **OPEN** |
| Headless (WO-71/72/73): CPU-only host 15× too slow; decomposition untested; `-dedicated` blocker 4 | WO-73 | **OPEN, parked** — decision-session item, not engineering |
| `.vs/` blobs in history (~43 MB clone) | WO-0 | **DROP** unless a history rewrite is ever done for §6's privacy item too |
| `kdcmp/mod.manifest` `<version>0.3</version>` never tracks VERSION | WO-69 | **DROP** — the game's own field |
| `kdcmp.pak` tracked in git and not byte-deterministic | WO-74 | **OPEN, low** — every rebuild dirties the tree |
| Two `%LocalAppData%\KCDMP` trees (sandbox redirection) | HANDOFF-wo32, WO-74 | **OPEN, standing trap** — in memory already |

### 7.8 Closed-as-not-achievable items re-examined

- **Aggro "no reachable surface"** (HANDOFF-WO4, PROJECT-STATE §4 lead
  sentence): wrong since WO-16/26; the lead sentence should be rewritten, not
  amended below.
- **"Be Henry"**: closed twice (WO-26 crash, WO-56 mechanism). Stands.
- **Retail as a target**: PROJECT-STATE says no REST API; WO-18 showed
  RemoteConsole works on retail. The *native* half still needs Modding Tools.
  Stands with that nuance.
- **Behaviour trees / `IdleSeq`**: stands (WO-21).
- **`Draw2DLine`**: stands (WO-6).
- **CryNetwork replication**: stands (WO-52).
- **libKCD2 adoption**: stands (WO-67).

---

## 8. What this audit did not do

- Did not run a game, relay, injector or build. Every relay/native/Lua verdict
  is code-verified or drawn from committed logs, never observed running.
- Did not read PR #3's diff. Its existence and open state come from the
  GitHub API.
- Did not edit any doc other than the three WO-75 files, including the ones §6
  finds wrong. Amending them is a docs-only follow-up the maintainer can
  scope; this session's job was to find them.
