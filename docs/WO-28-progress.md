# WO-28 progress — shared combat: health, hits, death

Session of 2026-08-07. Human at the machine for every live step. Full evidence
in `docs/WO-28-findings.md`; this file is the running account of what was done,
in order, and what was decided along the way.

---

## Read first, and one correction it produced

`docs/WO-26-shared-combat-design.md`, `docs/WO-26-findings.md`,
`docs/PROJECT-STATE.md`, `docs/WO-27-findings.md`.

**WO-27's ghost-duplication fix is confirmed landed** before any Flow B work
started, as the WO required: commits `911a515` (the launcher duplicate-agent
fix), `af06d53` (its live verification) and the Phase 2 Lua dedupe are all on
`main`, and `docs/WO-27-findings.md` records both the 4× synthetic reconnect
test holding at exactly one ghost per identity and the live-verified launcher
fix. Flow B keys on `ghostId`, so this was a real gate, not a formality.

**One stale fact found and corrected:** `docs/PROJECT-STATE.md` §3 said "Next
free type byte: `0x1C`". That predates `0x1C`–`0x1E` (pause, release version).
`Protocol.cs` itself said `0x1F`, which is correct and matches the design doc's
assumption. Checked in code rather than trusted from either document.

---

## Phase 0 — the reload investigation (done first, as required)

Built `tools/Test-ReloadBehaviour.ps1` and ran it live with the human reloading
a save by hand at t≈63 of a 260 s window.

It answered all four questions and found two previously-unknown bugs that have
been live since WO-13. Summarised here; the timeline and reasoning are in the
findings doc.

- **Connection: survives untouched.** No Disconnect for the reloading agent in
  259 s.
- **Lua globals: survive.** `KCD2MP.ghosts` held at 1 throughout; no re-init.
- **Timer chains: all three die**, `*Running` flags still true — WO-13's bug
  reproduced. Interp and label self-heal in ~17 s. **The emitter never does.**
- **Consequence 1:** the reloading player transmits nothing for the rest of the
  session and vanishes for every peer.
- **Consequence 2:** every ghost body is destroyed and never respawned, while
  the mod still thinks it has them — the human, live: *"the ghost is invisible
  for me but I can see its nametag continuing in the same path."*

**Gate 0: passed.** The answer is firmly the WO's second branch — "send a death
packet, then also do X" — because without the fixes a death notice would be
followed by that player never returning.

### Fixes written as part of this WO

1. The agent's periodic re-arm now sends `KCD2MP_StartEmitter()` as well as
   `KCD2MP_StartInterp()`. WO-13 gave the emitter its liveness check but left
   it with no caller; ghosts visibly recovering made it look fixed.
2. `KCD2MP_ReconcileGhosts()` (new), driven on a 500-tick cadence, drops the
   bookkeeping for any ghost whose entity is gone from the world so the next
   position packet respawns it.
3. Per-ghost WO-28 state is cleared on removal and on reconcile, so a reused
   relay id cannot inherit a sampler baseline and fire a fake hit.

---

## Protocol

`0x1F`–`0x25` added; next free byte **`0x26`**. `Protocol.Version` deliberately
left at 6 — the layer is additive and ignorable, so a mixed session degrades
instead of being hard-refused at handshake, and every existing test's version
pin stays valid.

`0x25 CombatRole` is not in the design document. It fills a real gap: the doc
names Rule 2's host authority but never says how a client learns it holds it,
and the agent has no notion of a host. The relay designates the lowest-id ready
client and announces the current answer to everyone on each membership change.
Reasoning, and the rejected loopback-address alternative, in the findings doc.

---

## Phases 1–3 — what was built

- **Flow A.** Emit line `v1` → `v2` with health and stamina, plus dead and
  unconscious flag bits. `LogTailGameTransport` parses both versions; `v1`
  degrades to "health unknown", never to a rendered zero. Receivers render the
  owner's authoritative health on the nameplate.
- **Flow C.** `0x23` sent by the dying client, latched to one packet per life,
  cleared when the emitter reports them alive again — which is exactly what the
  end of a save reload looks like from the agent's side.
- **Flow B.** Ghost health sampled in `KCD2MP_InterpTick`, reported on the
  existing event channel, gated by three guards enforced in the mod, the agent
  and the relay independently.

### Two deliberate departures from the design document

**1. The Flow A receiver does not write the ghost's health.** The doc says
"receivers set the ghost's health from this." Lua health writes are inert
(`PROJECT-STATE` §2) and no native ghost-health write has ever been proven, so
what ships is the rendered number — which is what players actually read — and
not a write that would have looked implemented and done nothing. Guard 2's skip
flag is still implemented on that path, so it holds if such a write is added
later.

**2. The bindings were measured before being used, and the obvious ones are
wrong.** `player.actor:GetStamina`, `player.soul:IsDead` and
`player.soul:IsUnconscious` do not exist on this build. What works is
`player.actor:GetHealth()`, `player.soul:GetState("stamina")`,
`player.actor:IsDead()` and `player.actor:IsUnconscious()`. Worth recording
separately: `GetState("dead")` returns **nil rather than erroring**, so a
`pcall` around it succeeds and yields a falsey "not dead" that was never
measured — death detection built on it would have silently reported nothing
forever.

## Phase 4

Option (i) confirmed still correct and unchanged by Phases 1–3: Flow B is a
pure sensor on ghost health and never touches what the ghost's AI attacks, so
nothing built here creates a new reason to suppress ghost-initiated attacks or
would be simplified by doing so. Option (ii) remains blocked on the same
missing lever and was not attempted.

---

## Verification

| Suite | Result |
|---|---|
| `Test-PlayerCombat.ps1` (new, relay-level) | 21 / 0 |
| `Test-PlayerVitalsE2E.ps1` (new, real game) | 17 / 0 |
| `Test-Combat.ps1` | 14 / 0 |
| `Test-Sessions.ps1` | 22 / 0 |
| `Test-Dice.ps1` | 10 / 0 |
| `Test-Pause.ps1` | 10 / 0 |
| Farkle xUnit | 59 / 0 |

The E2E suite includes a **positive control** — with the sensor on, no skip
pending and a genuine negative delta, a hit *is* reported — specifically so the
three guard tests cannot pass by nothing ever firing.

Live, unprompted, before any test ran: the newest emit line read
`[KCD2-MP-DATA] v2 802 … 0 100.00 126.67` and `KCD2MP.hitSensorOn` read `true`,
so the whole `0x25` round trip (relay designates → agent receives → mod is
told) was already working end to end on an ordinary connect.

`Test-Pipe.ps1` was not run: it deals real damage to a live NPC and needs
`KCDMP.dll` injected. `native/` is untouched by this WO.

One trap re-encountered, already documented in `PROJECT-STATE` §5 and cost time
anyway: PowerShell variables are case-insensitive, so `$ack` shadowed `$ACK`
and every handshake "failed" against itself. Noted in the test script at the
site.

---

## Not done, deliberately

- **No save-sync mechanism of any kind.** Settled by the human's design: the
  player who dies reloads their own save, nobody else's world reverts.
- **No `VERSION` change and no installer build**, per `docs/VERSIONING.md`.
- **Design doc §5 option (ii)** — suppressing ghost-initiated attacks. Out of
  scope, still its own research task.
- **The genuinely cross-machine step of Flow B** — an NPC hit in one player's
  world reaching the other player's health in theirs. No second machine was
  available. Marked unverified in the findings doc rather than skipped
  silently; every guard around it is verified individually.
