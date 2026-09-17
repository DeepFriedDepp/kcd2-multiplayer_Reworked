# WO-99 — fixes for the 2026-09-16 session (0.22.5 → 0.22.7)

Source: host + joiner bundles, 2026-09-16 19:10–19:46, build 0.22.5, quest
`hledanipsa`. Host id=0 (damage authority), joiner id=1. Joiner clock is
2.12–2.15 s behind the host's (`off=+2123..2148`, MP-CLOCK); joiner times
below are shifted onto the host clock where stated. Every figure re-derived
from the files this session.

Evidence marks: (observed) from the logs · (code-verified) read in source ·
(synthetic) proven only under xunit / MoonSharp · (inconclusive).

Hands-off session: no native calls, no live game, no DLL deploy. `KCDMP.dll`
is source-unchanged. Everything below is synthetic-verified at best.

---

## Phase 0 — the `Dude` collision (fixed, structurally)

**Verified from the logs** (observed): 9 `MP-DMG … npc=Dude` lines per side,
values 88.9 → 7.7 → 16.2 → 16.9 → 28.2, every inbound `result=applied`,
zero `Dude` tokens in `relay20260916.log`. Prompt figures hold.

**Mechanism, corrected in two places:**

* The prompt read `hp=` as a health value being copied. It is a health
  DROP (`ApplyDamage(hp)`), which is worse: the host genuinely lost 88.9 hp
  at 19:17:23 (`[vitals] health=11.1`), the DLL sampler reported its own
  player soul as an NPC named `Dude`, the joiner applied an 88.9 blow to
  ITS player (`[vitals] 100.0 → 11.1` at 19:17:24.1), re-emitted the same
  drop 12 s later, and the host applied it back and **died** (`11.1 → 0.0`
  at 19:17:38.06, then `[death] … reloading`). Both reported symptoms — the
  joiner "holding the host's health" and "being hit with no NPCs around" —
  are this one packet, and the host's death in Phase 3 is its echo.
* Why the DLL reported the player at all (code-verified, `rttr_abi.cpp`):
  `sample_health` does skip `soul != g_player`, but `g_player` is captured
  once at the RTTR walk and is never refreshed; a save load rebuilds the
  player soul at a new address and the check silently stops matching. Both
  machines had reloaded before their first `Dude` line.
* Why it echoed with a 12 s–3 min delay instead of instantly (code-verified
  + observed): the DLL's `credit` (damage applied for a peer, cancelled
  against the next observed drop) lives in a tracked set that is rebuilt
  every 3 s with `credit = 0`. The player soul's `GetState(health)` lagged
  the actor health by ~12 s on the joiner, so the credit was gone before
  the drop was seen. Half the nine lines are echoes, half are genuine
  player wounds mis-sent; both classes cross-applied.

**Fix (agent-side, `NpcDamageGuard`, code-verified + synthetic):**

1. Structural key: the local player's per-save `Soul.Guid` read from
   `SoulList/PlayerSoul` (new `IGameTransport.ReadPlayerSoulIdentityAsync`),
   refreshed on a 60 s TTL and forced after a save load / `MOD INIT`.
   Outbound: a DLL hit on that guid is dropped (`MP-DMG dir=drop
   reason=local_player`). Inbound: a 0x31 whose name resolves to that guid is
   refused (`result=refused reason=local_player`).
2. Name fallback (`local_player_name`), for the window between a reload and
   the next identity read; a name match with a guid miss forces the re-read
   first so the guid gets to be the reason. Logged distinctly.
3. Echo guard, independent of the exclusion: an outbound (name, hp±0.06,
   st±0.06) matching an inbound hit this client applied within 300 s is
   dropped (`reason=echo`); a FATAL for a name whose death was applied from
   a peer within 300 s is dropped (`reason=echo_fatal` — `ApplyDeath` books
   no DLL credit, and the joiner's `out hp=2.0 fatal=1` at 19:16:36.107 was
   exactly that echo). 300 s because the observed echo delays were 12 s,
   12 s, 20 s, 34 s, 41 s and one of 3 min.
4. WO-90's `IsNeverSyncedNpcName` mechanism extended, not paralleled: the
   Lua exclusion now also refuses the live `player:GetName()` on the NPC
   stream (inbound refusal, tracked-set exclusion).

**Audit of the other name-keyed paths** (code-verified): NPC state/claim —
the emitter is class-filtered (`NPC`/`NPC_Female`), the inbound apply
refuses excluded names (WO-90), now including the player's; horse identity
(0x2B) — the adopt path already refuses the local player's own mount ("crash
guard"); items — drop ids + `PickableItem` class; appearance — ghost id +
item-class guids; faction — ghost only; NPC death — observer reads
class-NPC bodies only. **Only the DLL-fed damage path collided.** The DLL's
stale `g_player` and credit-zeroing rescan are native defects → WO-99.5.

**Synthetic** (`NpcDamageGuardTests`, 12/12): the session's nine lines per
side replayed through two guards with the real guids from the logs — zero
sends, zero applications; name fallback; post-reload re-read; echo and
fatal-echo drops; expiry; a real NPC untouched.

## Phase 1 — ghost packet starvation: 100 % sender-side, 0 transport

**Prompt table verified** (observed): >10 s 27 (host 18 + joiner 9), 2–10 s
172 (63+109), 0.5–2 s 105 (60+45), <0.5 s 42 (25+17); worst 21.7 s.

**Transport premise refuted** (observed): the joiner connected from the
same private LAN address as on 2026-09-15 (`relay20260915.log`), and its
`[ping]` RTT was already p50 100 ms / p90 183 ms that night (`agent.prev.log`)
vs p50 93 / p90 159 tonight. WO-98's "25–66 ms one-way" was the agent-poll
figure, not RTT. Nothing changed; nothing is an order of magnitude slower.

**Classification**, per inbound `[ghost N]` line gap >2 s, cross-matched to
the sender's own `[pos]` cadence (observed):

| receiver | gaps >2 s | 2.0–2.3 s (standing-still heartbeat, unpaused) | >2.3 s inside sender `[pause]` | >2.3 s outside |
|---|---|---|---|---|
| host | 168 | 129 | 36 | 1 (13.4 s: joiner "player is at a bed" = sleep fade) |
| joiner | 322 | 291 | 21 (19 full + 2 partial) | 8 (2.8–13.3 s: host save reload, fast-travel "Teleport outside PrecacheMode … 8297 m", dialogue) |

167/168 and 322/322 receiver gaps coincide with a sender-side send silence;
the one unmatched gap is 2.0 s (the heartbeat quantum). The 20 s cadence
inside a long silence: the mod's own emitter shows the same 20.1 s gaps with
`tickstat … n=1 DEGRADED`, i.e. the engine halts every `Script.SetTimer`
chain (WO-78 "suspended ≠ dead") and the emitter runs once each time the
agent's 2.5 s re-arm lands. The interp tick kept running (`TICK_ALIVE`
+1250 per 20 s) because the agent pumps it; the emitter had no pump.

**Verdict, stated plainly:** the residue is **sender**, not transport. A
20 s hole is "the peer is in a menu / loading / sleeping". Not a Steam-P2P
argument.

**Fix** (agent, code-verified, not live-verified): when the state read
returns null (emitter halted >500 ms) the agent re-sends its last sample at
the 2 s heartbeat with a new flag bit `0x02 STALE` (relay forwards the byte
verbatim — code-verified `ClientSession` copies `flags`; an old receiver
masks bit 0 only). Receivers count them (`MP-GHOSTPKT … stale=`, `MP-SUMMARY
section=position`), and log one line per suspension edge. The receiver can
now tell "paused" from "gone"; the ghost interp sees a repeated position,
which is what standing still already produces.

**Smoothing (WO-75, parked) is unblocked by this phase:** there is no
packet hole to survive, only a suspended peer; a snapshot buffer would idle
through it.

## Phase 2 — sub-8 m yield arbitration (landed, default on, toggle)

Verified (observed): host `MP-NPCFIGHT npc=ttkc_drozd n=177 mean_m=0.07
max_m=0.08 window_s=10`; joiner totals `tzel_rowdy_2` 3826, `tzel_rowdy_1`
3448, `tzel_bretislav` 3429, `tzel_groom` 2711. `authority=peer` is
structural on every NPCFIGHT line (the channel only exists for puppets).

Landed exactly WO-98 §3a: readback displacement > `dispM` (0.30 m) for
`ticks` (10) consecutive 50 ms ticks → **yield** (no position/angle/anim
writes); re-pin only when an inbound packet moves the STREAM TARGET
> `repinM` (1.0 m) from the yield anchor — the body's own drift never
re-pins, so a stationary stream cannot oscillate. On re-pin the render
position and WO-77 ring are re-seeded from the body (slide, not snap). A
yielded puppet is off the write path, so WO-90's release cannot see it
until re-pinned (stated limit). `MP-NPCYIELD` on every edge; `mp_npc_yield_on`
/ `_off` (argless — the console drops arguments), `#KCD2MP_SetNpcYield("0.3
10 1.0")` for thresholds; `npc_yields`/`npc_repins` in `MP-SUMMARY-MOD`.

**What to watch in the A/B:** `MP-NPCFIGHT` event counts should fall for
yielded names and `MP-NPCYIELD state=yield` lines appear in their place;
the cabin scene's 7 cm contention is BELOW `dispM` and will not yield —
that is deliberate (7 cm at 50 ms is not the brain walking; lowering
`dispM` toward 0.10 is the first knob to turn if the stutter is still
visible). **Named risk (WO-51):** an NPC the peer is fighting may walk off
on this machine. That is divergence made visible instead of jitter; a
field report of "NPC wandered away" is this rule, not a new bug.

Synthetic (`Test-WO99Synthetic`, 39/39): yield on exactly the 10th tick,
zero writes while yielded, 0.5 m target move ignored, 1.5 m re-pins and
re-seeds from the body, 7 cm never yields, streak resets on a quiet tick,
off/on semantics, threshold parsing, summary counters.

## Phase 3 — death and reload divergence (explained; one class documented)

* **Death asymmetry: fully explained by Phase 0** (observed). The host died
  of the echoed 88.9 blow at 19:17:38; player death travels on its own
  channel (0x14 / PlayerState 0x1F–0x25) and is applied to the GHOST, never
  to the peer's player — so the joiner correctly did not die, while its own
  health had been cut to 11.1 by the same packet. Nothing to build.
* **Reload divergence** (observed): host reloaded at 19:17:52 (`[timeskip]
  reload: converging forward`); `hledaniPsa_corpseRobber` was alive in that
  save and dead on the joiner. The mod already detects and accepts this:
  host kcd.log `NPC-DEATH hledaniPsa_corpseRobber reads ALIVE again (by
  puppet) -- was dead; reload? clearing its death marks` (t=578.2). The
  reconciliation pass (`ReloadReconcile`, WO-88) covers the ghost body,
  appearance and the clock; **it does not cover NPC life state, and this
  WO does not extend it**: the reloaded save is that player's truth, and
  re-killing an NPC the save says is alive would be a quest-state write by
  another name (WO-92's hazard class). Documented as a named, accepted
  limit; the joiner's stream marks it `dead on its first packet here …
  freeze only`.
* **Re-kill of an already-dead entity is harmless** — proven (code-verified
  + observed): native `apply_death` reads `IsDead` first and returns true
  ("already dead is success"); the agent's `ApplyRemoteNpcDeathAsync`
  dedupes per name for 60 s; the Lua observer announces alive→dead
  transitions only. The 19:20:37 re-kill on the joiner logged `peer says
  dead … IsDead=true hp=0, puppet=no` and no engine error line followed.
  The only side effect — the joiner's `out hp=2.0 fatal=1` echo after the
  FIRST kill, which made the host apply a blow to a corpse — is the
  `echo_fatal` case Phase 0 now drops.

## Phase 4 — instrumentation gaps

* **`MP-CUTSCENE` absent because no qualifying cutscene occurred**
  (observed): 18/18 `CutscenePlayer` lines across both kcd.logs are type
  `Fader` (`korenarkaZachrana_startQuestStreamProfiles` etc.), which WO-98
  excludes by design; the edge detection and wiring are intact (WO-98's
  synthetic 50/50 still passes). Not "misses Ingame" — none played. Change:
  Fader/Text/SkipTime edges are now logged locally with `acted=0` so a
  loading fade or sleep is visible beside the emitter gap it causes; only
  Rendered/Ingame act (`acted=1`). Cutscene-sync work is not blocked by the
  channel; it needs a session with an Ingame cutscene.
* **`MP-SUMMARY` / `MP-SUMMARY-MOD` absent because the session did not end
  cleanly** (observed): both agent.logs end in `[ping]` lines, the relay log
  ends in claim traffic, no disconnect ever ran. Both blocks now also print
  every 300 s (`reason=periodic`; counters are cumulative).
* **Swing correlation id landed** (code-verified): CombatEventUp/Down v2
  append `[sid:2]` (the sender's swing counter); relay accepts v1 and v2
  lengths and forwards verbatim; receivers log the wire `sid` beside their
  `rsid` on `hop=recv/queued`. Host 127 / joiner 191 `MP-SWING` lines from
  this session remain unmatchable; the next session's will match. "Did the
  fragment PLAY" still has no native reporter (WO-99.5).

## Confirmed working — do not "fix"

WO-86's death path (first kill: 6 hits applied, FATAL applied, dedupe
rejected the 0x27 duplicate 0 s later); WO-98's channels (all eight that
had something to report fired); the pause detector (55/64 long gaps inside
its intervals); the divergence release; the clock offset (2.12–2.15 s
measured, stable to ±30 ms all session).

## Deviations

* **Taken:** Phase 0 hp semantics corrected (drop, not value) — same fix,
  stronger reading of the symptom.
* **Taken:** Phase 1 conclusion is "no transport gaps" and "no code cause
  beyond a missing heartbeat"; the prompt's transport regression premise
  is refuted with the 2026-09-15 RTT figures.
* **Taken:** Phase 3 reload gap documented as accepted, not extended
  (conservative path; the alternative is a cross-machine NPC re-kill on
  reload, a quest-state write in disguise).
* **Taken:** Fader/Text/SkipTime cutscene edges logged (log-only, beyond
  the prompt's list; they are the missing marker for Phase 1's unpaused
  gaps).
* **Taken:** swing id as a v2 payload length rather than a protocol-version
  bump (additive; relay accepts both; a v1 receiver drops v2 packets, so
  the deploy is a matched set as every release since WO-46).
* **Dropped:** re-using the DLL's credit mechanism by widening it — native.
* **Dropped:** skipping `ApplyDamage` for a name this client believes dead
  — would refuse legitimate damage to a respawned copy after a peer's reload.

## WO-99.5 addenda (need a live game or a DLL deploy)

1. **Native:** refresh `g_player` on every rescan (`SoulList.PlayerSoul`)
   and carry `credit` across rescans by guid instead of zeroing it. Phase 0's
   agent guard makes this non-urgent; the DLL still samples the player.
2. **Live A/B:** `mp_npc_yield_on|off` in a puppet-dense scene; watch
   `MP-NPCFIGHT` vs `MP-NPCYIELD`; first knob is `dispM` 0.30 → 0.10.
3. **Live:** confirm `[pos] mod emitter silent/resumed` brackets a menu open
   and that the peer's `MP-GHOSTPKT … stale=` counts it.
4. **Live:** one session with an Ingame cutscene, to see `MP-CUTSCENE
   acted=1` fire at all (unchanged from WO-98's own gap).
5. Carried from WO-98: situation-context native change; `C_PortRef::Trigger`
   live fire; `Movie.PauseSequences` probe; `FindNode` port read.

## WO-100 candidates

1. Snapshot-buffer smoothing (WO-75) — **unblocked** by Phase 1 (the holes
   were suspensions, and stale heartbeats now mark them).
2. Emitter pump: pump `KCD2MP_EmitTick` from the agent during menus the
   way the interp tick is pumped, so the position stream never needs the
   stale fallback (the agent already holds the menu edge).
3. `ttkc_man_3`-class guard `PickUpRight` loop (WO-98 §4) — untouched.
4. `hp=` on `MP-DMG` is a delta; consider adding the resulting health so a
   field reader stops misreading it (this WO did).
