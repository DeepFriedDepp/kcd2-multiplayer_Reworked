# WO-66 — relay claim-update hardening (progress)

Evidence tiers as in WO-54/58/59/60: **observed** (a run this session, cited)
/ **code-verified** (read or written directly in current source) /
**wire-verified** (exercised against a real relay process on this machine, no
game involved) / **inconclusive**. Nothing below is rounded up.

Mandate: port the update-validation semantics WO-64 Phase 3 read in
KCD2Online's `npc_registry.cpp` (reference pinned @ `5777c15`, read-only) into
our relay's NPC-claim path, as hardening of WO-60's shipped claim/engaged-hold
system — not a redesign. Relay + wire tests only; no game session anywhere in
this WO.

---

## 1. The four gates, as built (all wire-verified this session)

All gates run in the relay's 0x26 `NpcStateUp` path
(`ClientSession.RunAsync` framing layer + `ClientHandler.RouteNpcState`),
**before** any relay state mutates and before any fan-out. Rejection is: one
`[WO66-REJECT] speed|rotation|reserved-name|stale-owner` log line
(Information level — Debug is below the shipped Serilog floor and would be
invisible in field logs), one per-reason counter bump, packet dropped. A
rejection never releases a claim, never disconnects the peer, never mutates
NPC state — invariant stated in `RouteNpcState`'s doc comment and enforced by
gate placement (all gates precede all writes).

### Gate 1 — plausibility speed gate

Reject a claimed-NPC update whose position implies movement
`> MaxSpeedMps * elapsed + SlackMeters` since the claim holder's **last
accepted** update. Semantics from their `npc_registry.cpp:240–248`.

- **Constants: 40 m/s cap, 2 m slack — theirs kept, re-examined against our
  world.** The fastest legitimate mover on this channel is a world horse (the
  `mp_npc_rescan` loop tracks `Horse`-class entities); a KCD2 horse gallop is
  ~12–14 m/s (community figure, read-not-measured), so 40 m/s is ~3× headroom
  while teleport-class garbage sits orders of magnitude past it. At the
  ordinary 250 ms emit cadence the allowance is ~12 m per packet vs. ~3.5 m
  of real horse-sprint movement. No reason found to diverge from their
  field-proven constant.
- Constants are config-backed (`NpcClaimValidation:MaxSpeedMps` /
  `:SlackMeters` in appsettings.json, the `Tcp:Port`/`Echo` pattern) with the
  shipped defaults inline in `ClientHandler`'s constructor.
- **Baseline lifecycle**: the last-accepted position lives INSIDE the claim
  table entry (`_npcClaims` gained `X, Y, Z`), so claim expiry, disconnect
  clear (`ClearNpcClaimsFor`), and reclaim all destroy it with the entry — no
  leak, no stale carryover: a new claimant's first packet is never checked
  against a previous owner's data. The first accepted packet of any claim (or
  reclaim) seeds the baseline and is deliberately not speed-checked.
- **Rejected packets update nothing** — not the baseline, not `LastUtc`, not
  `EngagedUtc`. A rejected packet is bad data, not evidence the owner is
  gone (claim retained), and also not evidence the owner is alive (claim not
  refreshed). Consequence, deliberate and now wire-verified (V5b): a claim
  fed only garbage expires on the ordinary 5 s silence path and the next
  packet re-seeds — which is also how a genuine legitimate teleport (e.g.
  claimant reload) self-heals within one expiry window instead of wedging.

### Gate 2 — rotation validation

Our wire rotation is a **scalar yaw float (`rotZ`), not a quaternion** — so
their "rotation normalizes" check degrades honestly: NaN/Inf `rotZ` is
rejected; any finite angle is accepted and broadcast verbatim (an unwrapped
angle is receiver-wrappable drift, not garbage; the relay never rewrites a
payload). "Near-zero norm" has no scalar equivalent and maps to nothing.
Additionally NaN/Inf **positions** are rejected in the same framing-layer
check (counted under the `speed` reason — position-plausibility class),
because a NaN position would otherwise sail through the speed compare
(`NaN > cap` is false). Finite checks run for every sender including the
authority: a non-finite value never legitimately leaves the game, and
garbage fanned out poisons receivers whoever sent it.

### Gate 3 — reserved-name rejection

The relay refuses an NPC **claim** (the non-authority path) whose entity name
starts with `kcd2mp_` — read from kdcmp.lua, not guessed: every entity the
mod spawns is under that prefix (`kcd2mp_<id>` ghosts, `kcd2mp_horse_<id>`,
`kcd2mp_npc_<n>`, `kcd2mp_ianchor_*`). Drift protection: the prefix is
`Protocol.NpcReservedNamePrefix` with a loud comment, and kdcmp.lua's ghost
spawn site carries the mirror comment pointing back (comment-only Lua change,
inert until the next pak build, per the WO's exception).

**Honest scope statement**: ghosts are *renamed to player nicks* after spawn
(WO-26 `KCD2MP_ApplyGhostName`) — which is exactly why the Lua-side guard
(`mp_is_mod_entity`) is registry-reference-based rather than name-based. The
relay name gate therefore covers the spawn-name window and the never-renamed
families; renamed ghosts remain the Lua guard's territory (the relay has no
entity registry to check references against). This is defense in depth behind
that guard, as scoped — not a replacement for it.

Deliberately NOT applied to the authority's default stream: `kcd2mp_npc_*`
test spawns are real NPCs a host's rescan may legitimately track and stream;
only the claim path is the recursive-puppet-discovery risk this gate exists
for.

### Gate 4 — stale-owner rejection: NO protocol field needed

Phase 0 determination, from reading the claim table and framing end to end:

- Sender identity is the **TCP session itself** (`ClientSession`, byte `Id`
  minted at connect). Upstream 0x26 carries no sender identity to spoof; the
  relay knows the sender from the socket.
- Claims move only via silence-expiry-then-new-claim or disconnect-clear
  (`ClearNpcClaimsFor`). There is **no reassignment path** that can leave the
  table pointing at a stale identity: a former owner's late packet after
  release→reclaim arrives as a non-owner and hits the existing
  `claim.OwnerId != sender.Id` rejection — including inside the new holder's
  15 s engaged-hold window (wire-verified V4b). A reconnecting client is a
  new session with a new Id and its old claims were cleared at disconnect.
- Therefore strict enforcement already existed structurally (WO-39's drop);
  this WO makes it a first-class gate: tagged `stale-owner`, counted. **No
  monotonic claim-generation was added — no protocol change, no version
  bump.**
- The WO-39 echo-loop mute (the *authority's* re-sample of a claimed body,
  dropped by design at high frequency) is deliberately NOT tagged or counted
  — it is normal operation, not garbage; tagging it would drown the counters.
- Residue noted for the record: `ClientSession.Id` is a byte counter that
  wraps after 256 connections in one relay lifetime, so two *live* sessions
  could theoretically share an Id. Pre-existing session-identity property,
  not claim-specific, not worth a protocol field; recorded, not fixed.

## 2. Splice-back audit (scoped to ours)

Question: can any accepted client update mutate relay-owned authority state —
claim ownership, the engaged-hold bit's effect (`EngagedUtc`), hold/expiry
timers? Code-verified answer, now also wire-verified (V5a/V5b):

- `_npcClaims` is written in exactly two places: `RouteNpcState` and
  `ClearNpcClaimsFor` (disconnect). No packet type releases, transfers, or
  extends a claim; 0x30 `NpcDamageUp` never touches the table.
- The ENGAGED flag is the only payload-derived bit that reaches authority
  state, and it lands only on a first-claim or current-owner-refresh packet
  that passed every gate — a rival's or the authority's flag is inert
  (rival: rejected before any write; authority: its branch never writes the
  table). Post-WO-66 a rejected *owner* packet can't re-arm the hold either
  (speed gate precedes the write).
- Hammering cannot extend or erode anything: dropped packets update nothing
  (WO-60's property, preserved and now also true of garbage from the owner
  itself).

Closed paths needing closing: none found — the shape WO-60 shipped was
already single-writer per entry; this WO added the garbage filters in front
of the one legitimate writer.

Explicitly out of scope, unchanged: server-side aggro, combat-target
ownership, nearest-player lease assignment, interest radii (all rejected with
reasons in WO-64 Phase 3).

## 3. Protocol decision

**No field added, no version change.** Phase 0 found the claim table +
framing already carry enough identity for strict stale-owner enforcement
(gate 4 above), including across release→reclaim races around the engaged
hold — the race a claim-generation would exist to close cannot occur in this
topology (no reassignment, disconnect clears, reconnect = new identity).
Wire format of 0x26/0x27 is byte-identical to WO-60.

## 4. Test results (all observed this session)

| Suite | Result | Notes |
|---|---|---|
| **Test-NpcClaimValidation (new)** | **23/23** | V0 counters zero; V1 speed (legit accepted / teleport dropped / claim retained / sane resumes); V2 rotation (NaN rotZ dropped, Inf position dropped, finite rotZ=100 accepted verbatim); V3 reserved name (kcd2mp_7 refused, normal claim unaffected); V4a stale owner simple; V4b stale owner inside the new holder's engaged-hold window; V5a crafted ENGAGED+teleport rival packet moves neither ownership nor hold; V5b garbage never refreshes a claim (expiry-then-reseed self-heal); V6 endpoint tallies exact (speed=6, rotation=1, reserved-name=1, stale-owner=4) |
| Test-TimeSkipRelay | 35/35 unchanged | T17–T20 (WO-60 engaged hold) regression green — the hold behaviour is untouched |
| Test-ItemSyncRelay | 11/11 | claim-echo item arbitration untouched |
| Test-Sessions | 22/22 | against the freshly built relay |
| Test-Combat | 14/14 | against the freshly built relay |
| Test-Dice | 14/14 | against the freshly built relay |
| Farkle unit tests | 59/59 | |
| dotnet solution + launcher | build clean | 0 errors, pre-existing warnings only |
| Test-Pipe | **not run** | requires DLL injection into a live game; no game this session, and this WO touches no pipe path (relay + Protocol const + one Lua comment only) |

Harness notes: the new suite is the Test-TimeSkipRelay shape verbatim (starts
its own relay of THIS build on ports 7793/5301, synthetic peers, drains with
the assign-then-filter idiom from the T17 lesson). V5b uses 900 ms garbage
intervals, not 1 s, so all four rejected refreshes land inside the 5 s expiry
window with margin — the point is that rejects do NOT refresh; a slow machine
must not turn the 4th packet into a legitimate post-expiry reseed.

## 5. Diagnostics surface

- `GET api/information/npc-validation` on the relay's existing HTTP listener
  (the `InformationController` pattern, same controller): running per-reason
  totals `{speed, rotation, reservedName, staleOwner}`. All zero on a healthy
  wire.
- `[WO66-REJECT] <reason>` log lines at Information, one per dropped packet,
  greppable in the standard log bundle.

## 6. Files touched

- `dotnet/KcdMp.Server/Features/ClientHandling/ClientHandler.cs` — gates,
  claim-tuple X/Y/Z, counters, config-backed constants, `NpcRoute` enum
- `dotnet/KcdMp.Server/Features/ClientHandling/ClientSession.cs` — finite
  checks, position parse, routed switch + tagged logging
- `dotnet/KcdMp.Server/Features/ClientHandling/NpcValidationCounters.cs` — new
- `dotnet/KcdMp.Server/Features/ServerInformation/Controllers/InformationController.cs`
  — `npc-validation` endpoint
- `dotnet/KcdMp.Server/appsettings.json` — `NpcClaimValidation` section
- `dotnet/KcdMp.Protocol/Protocol.cs` — `NpcReservedNamePrefix` const
  (comment-only wire impact: none; no version change)
- `kdcmp/Data/Scripts/Startup/kdcmp.lua` — the mirror comment at the ghost
  spawn-name site (comment only, inert until next pak build)
- `tools/Test-NpcClaimValidation.ps1` — new suite

No engine, session-framework, or (non-comment) Lua changes. No `VERSION`
change (user owns versions, docs/VERSIONING.md).
