# WO-46 — native ghost swings over the wire. Live-verified end to end.

Worked 2026-08-23 (Fable 5), same day as WO-45, live, human at the machine.
WO-45 proved the rung-2 construction renders a real, complete combat swing on
a ghost; this WO wired it into the WO-39 combat-visibility stream as the
production render path for a peer's swing. **Live-verified over the real wire:
a synthetic peer's three swing events rendered as three real longsword swings
on its ghost, watched by the human** — where WO-39 could only manage a
guard-transition cue at 1.6× ("this is a cue, not a true swing" was its own
honest ceiling).

---

## 0. What shipped

One new pipe command and a routing change; **no wire-protocol change** (rides
the existing 0x2C/0x2D combat events; the protocol version stays 6).

| layer | change |
|---|---|
| native | `ghost_swing(entityId, fragSpec)` (`combat_swing.h`, implemented in `combat_construct.cpp`) — the lean production twin of the WO-45 rung-2 research mode: resolve the actor by entity id, `GetOrCreateCombatActor`, engine-parse the fragment spec against the actor's own animDB, module-alloc + `C_CombatAnimAction` ctor, `QueueAction` with −1.0f in XMM2. One log line per swing. All three RVAs prologue-verified once per process, fail closed. |
| native pipe | `0x06 GhostSwing [entityId:4 LE][fragSpec:N]` → `main_thread::run_sync(ghost_swing)` → `Result`. |
| Lua | `KCD2MP_SpawnGhost` emits `ghostid <id> <hex>` (the entity id, parsed from the userdata `tostring` — the only integer-faithful form in this float32 sandbox); new `KCD2MP_GhostNativeSwingHold` sets only the one-shot window so the locomotion tick does not fight the playing native action. |
| agent | caches `ghostid` events (ghostId → entityId); on an incoming swing event with a cached id, sends `GhostSwing` down the pipe + the hold call to Lua. On failure (DLL absent, stale id) it falls back to the old Lua cue, late but visible. Draw/sheathe/block are untouched. |

The fragment row is WO-43/WO-45's real longsword `FreeAttack` row, hardcoded
agent-side (`NativeSwingFragmentSpec`): the armed ghost loadout **is** the
longsword preset (`kkut_menhart` → `sermiry_longSwordMenhart`, male ghosts
only), and a ghost with no drawn weapon renders a native no-op
(WO-45-live-verified), which matches its synced drawn-state anyway.

**Lifecycle (differs from the research path, deliberately):** two AddRefs in —
one consumed by `QueueAction`, one held across the call and the post-queue
state read — then our reference is released through the action's own
`vtbl[0x10]`. The controller's own reference (live-measured both in WO-45 and
here: `ref(controller)=1` after our release) owns the action until it
completes. **No leak per swing**, unlike the research path's deliberate
0x1A8-per-invocation retention. The held-across-the-call ref also means the
post-queue read can never touch a destroyed object even on `QueueAction`'s
internal no-controller path.

## 1. The live verification

Full stack: launcher-hosted relay + agent + game with the new DLL
(`ModuleMemorySize` 0x51000 checked), `tools/Test-CombatVizE2E.ps1` as the
synthetic peer (its hardcoded peer name `wo39-combat-peer` hashes **male**, so
its ghost carries the real longsword — checked before running).

Observed, in order, all three layers agreeing:

1. Ghost `2` spawned by the peer's position stream; Lua emitted
   `[KCD2-MP-EVT] v1 16 ghostid 2 000000000008053E`.
2. Agent cached it; the peer's three swing events each produced a native
   pipe command; the DLL logged three
   `SWING: entity=525630 queued fragment 195 status=1 ref(controller)=1`
   lines at exactly the harness's scheduled times (34/38/46 s).
3. **Human: "I did see it do 3 swings."** Three real longsword swings on the
   ghost, over the wire. Draw and block (the untouched paths) also rendered.

The one thing the human did not see — the sheathe — was chased down and is
**not a regression**: the harness peer disconnects at sequence end and the
ghost despawns seconds after the sheathe event. A targeted manual retest
(fresh male ghost `wo46a`: draw → native swing → `HolsterWeapon`) confirmed
the weapon **does** return to the sheath after a native swing — instantly,
with no sheathing animation, which is how the Lua holster state-call has
always behaved. Human-confirmed.

Suites green (59/59) after every change.

## 2. Traps found on the way (each cost a round-trip; recorded so they stop costing)

- **A flat single-project publish over the shared install breaks the other
  executables.** Copying the client's publish output over
  `%LocalAppData%\KCDMP` replaced the shared `KcdMp.Protocol.dll` with a build
  referencing System.Text.Json **10.0.0.0**; the installed 8/15 relay could
  not resolve it and crashed at startup (event log:
  `FileNotFoundException: System.Text.Json, Version=10.0.0.0`), silently —
  the launcher's 500 ms exited-immediately check missed it. Fix: publish and
  copy the server too. Rule: **deploy binaries as a matched set** (this is
  what `tools/Publish-Release.ps1` exists for); partial copies of one project
  are only safe if nothing shared moved.
- **The relay's TCP port is NOT 5273 in a launcher-hosted session.** 5273 is
  the relay's Kestrel **HTTP** endpoint (hardcoded); the actual relay socket
  comes from `--port {HostPort}` = **7778** by default. A raw TCP client on
  5273 connects (OS backlog) and then hangs — it is talking to an HTTP
  server. `Test-CombatVizE2E.ps1`'s default `-RelayPort 5273` is therefore
  stale for launcher-hosted relays; pass `-RelayPort 7778`. (Left as a
  documented trap rather than changed, since the default may be right for a
  standalone `--port 5273` relay.)
- **The agent's single startup pipe connect can race injection.** The
  original routing gated on `_combat.IsConnected`, which would have parked
  every swing on the fallback path forever if that one connect missed. The
  shipped gate drops the pre-check: `GhostSwingAsync` connects on demand, and
  the Lua cue is the on-failure fallback (agent commit note "pipe-gate fix").
- The stat-requirement spawn lines (`insufficient strength/agility for
  sermiry_longSwordMenhart`) appeared again on clean spawns whose ghosts then
  swung fine — reconfirming WO-45: those lines alone are not the corruption
  signature.

## 3. Where solid ground ends

- **Observed-live:** everything in §1; the no-leak lifecycle's
  `ref(controller)=1`; the relay crash and its event-log cause; the
  5273-vs-7778 port split; holster-after-native-swing.
- **Known limits, stated:** one hardcoded longsword fragment row for all
  swings (right for today's armed-ghost loadout; per-weapon-class rows are
  the obvious next step if ghost loadouts diversify). Swing direction/zone is
  not mirrored — every peer swing renders as the same canonical attack.
  Sheathe/draw remain instant state-calls with no animation (pre-existing).
  The `ghostid` cache is never invalidated, only overwritten by the next
  spawn report; a stale id fails clean in the DLL (entity ids are not reused
  within a session).
- **Not done:** no VERSION change; blocks stay on the Lua cue; no paired
  (sync-attack) work — that is still Phase 3 territory (WO-45 §3).

## 4. Handoff

- Real multiplayer swing fidelity now exists. Candidate refinements, in
  value order: per-weapon-class fragment rows (needs the attacker's weapon
  class on the wire or inferred from the appearance sync); swing-zone
  variety (multiple real rows, picked per swing); a sheathe/draw animation
  route if one exists natively.
- The launcher should surface a relay that dies after its 500 ms check
  (found silently dead twice this session) — small UX fix, outside this WO.
