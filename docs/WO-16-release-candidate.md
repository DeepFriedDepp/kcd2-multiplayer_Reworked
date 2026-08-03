# WO-16/17 release candidate — NPC aggro on ghosts

Investigated and built 2026-08-02, same session as `WO-16-findings.md`
(a pure test) and directly building on it: this session closed WO-16's two
open technical gaps, got the feature's shape confirmed by the human, wrote
the real permanent code (replacing WO-16's console-only test clone), and
tested it — live, against the real KCD2 (Modding Tools) process, with the
human watching for the parts that need eyes.

Read `WO-16-findings.md` first for the underlying three-ingredient theory
(real soul / hostile faction / working behaviour tree) and the original
faction-attach evidence. This document is the gate: what got fixed, what got
scoped as a known limit, what got built, and what got tested.

---

## How to enable/disable it

`mp_enable_aggro on` / `mp_enable_aggro off`, typed in the in-game console.
Decided locally, per player — no session invite, no agreement from the other
player needed, because it only changes how *your own* local world treats an
incoming ghost. Persists for the session (a plain Lua global; resets on mod
reload/game restart, same as every other `mp_*` toggle in this project).

**Only affects ghosts spawned after the toggle flips.** A ghost already on
screen keeps whatever behaviour tree it spawned with — to change a live
ghost's state, the peer has to reconnect (or you can `mp_remove_all` and let
it respawn). Confirmed live: this command's `%LINE` argument parsing is
occasionally flaky on the very first invocation after a game (re)launch (a
pre-existing quirk shared with `mp_dice_gate`, not new to this feature) — if
the toggle doesn't seem to take, check with `#System.LogAlways(tostring(KCD2MP.aggroEnabled))`
and retry.

## Known limitations, rough edges, side effects — the true list

**Limitations (by design/investigation, not bugs):**

- **One-sided.** An aggro'd ghost can be hurt; it cannot hurt back. See A2
  below — no lever for real retaliation was found.
- **A sustained fight can leave the ghost stuck floored**, alive per the
  game's own bookkeeping, unresponsive on screen. See A1 below — root-caused,
  not fixed.
- **Not synchronized between clients.** Whether an NPC in *your* world treats
  a ghost as hostile is computed entirely from your own toggle and your own
  locally-observed combat events — nothing about this is agreed or shared
  with the other player's client.
- **One hardcoded faction for all of v1** — a real bandit faction confirmed
  hostile to ordinary townsfolk (WO-16), not a nuanced per-NPC-type system.

**Rough edges (real, but narrow):**

- **The donor soul is playthrough-specific.** The native attach path copies
  its hostile-faction membership from a real, loaded donor soul
  (`prepadeni_bandit_1`, a leftover NPC from *this playthrough's* earlier
  ambush sequence — see `WO-16-findings.md`). If a save has never reached
  that ambush, this specific soul will not exist in `SoulList` yet, and the
  attach will fail quietly: the native log records `"donor soul not loaded
  here"`, the pipe replies with a failure result, `TriggerReactiveAggroAsync`
  logs it and moves on — no crash, but on such a save `mp_enable_aggro`
  currently does nothing observable. Not hit in this session because the
  test playthrough had already reached that ambush. **Not verified against a
  save that hasn't.**
- **`mp_enable_aggro`'s console dispatch is occasionally flaky** on the first
  call after launch (see above) — pre-existing, shared with `mp_dice_gate`,
  not introduced by this feature.
- **`XGenAIModule.PerceptionHistory` is a live rolling buffer**, not a stable
  log — a single sample can occasionally show a stale or noisy count. Not a
  functional bug; only matters if you're debugging with the same query this
  session used.

**Side effects:**

- **`human:DrawWeapon()` fires automatically** ~1s after spawn when aggro is
  on — purely cosmetic (see A2: confirmed not to grant any combat
  capability), makes the ghost visually look combat-ready instead of
  sheathed.
- **No effect at all when the toggle is off** — the default path is
  unchanged from every prior release; see the regression test in Phase D.

---

## Phase A — the two gaps WO-16 left open

### A1 — the mid-fight disappearing-ghost bug: root-caused, not fixed

Reproduced deliberately: a brained (`esModularBehaviorTree="IdleSeq"`),
weapon-drawn ghost, attached to the hostile faction via the fixed `SetParent`
call, near a real NPC (`ttkc_dusko`, the same woodcutter WO-16 used, though
this time in a moderately populated spot, not WO-16's isolated clearing).

**What happened, with hard evidence, not a guess:**

- The NPC landed real hits through the game's own combat pipeline — not this
  project's inert Lua writes. Proof: the ghost's own `Buffs` list picked up
  `injured_left_leg`, `injured_head`, `injured_left_arm`, `injured_torso`,
  `low_health`, and its health genuinely dropped to 44.65%.
- The human reported the ghost's body visibly went to the ground ("the ghost
  died, and his body is on the ground") and the attacker kept trying to fight
  it.
- Telemetry through the entire episode: `IsDead=false`, `IsUnconscious=false`,
  position unchanged. The RPG/combat layer never registered anything
  happened — it still considers the ghost a live, standing, viable target.
  The `Roles` list even carries `RANENY_NA_ZEMI_MUZ` ("wounded on the
  ground"), a real animation/state role, disconnected from the RPG layer's
  own view of the world.

**Root cause:** a real stagger/knockdown hit reaction fires correctly, but
the ghost's behaviour tree — `esModularBehaviorTree="IdleSeq"`, a bare
top-level dispatcher — has none of a real NPC's archetype-specific recovery
branches to bring it back to standing. It gets stuck on the ground
indefinitely, while the attacker (correctly, from its own point of view)
keeps trying to fight a target its own AI still considers upright. This is
very likely the same underlying bug WO-16 saw as "the model disappeared" —
a floored, hard-to-see or partially-clipped body, not a true vanish — same
missing-recovery-behaviour cause, different visual presentation depending on
terrain and camera angle.

**Disposition, decided with the human:** scope as a known v1 limitation, not
a blocker. A real fix needs a richer behaviour tree with an actual recovery
branch — untested, more trial-and-error against real NPC archetype data than
this session's remaining budget allowed. Documented plainly in the README
and here, not buried as a footnote.

### A2 — can a ghost's weapon become functional: investigated, still no

Two native levers were tried, both real, working, native mutations — neither
grants actual combat capability:

- **`EquipmentManager.EquipItem`** (the WO-10 weapon-sync mechanism, a native
  RTTR call over the debug REST API): confirmed cosmetically real (the item
  genuinely re-equips, `Condition` resets to 1.0), but `CombatSoul.HasMeleeWeapon`
  stayed `false` before and after, on a fresh unequip/re-equip cycle.
- **`human:DrawWeapon()`** (a real scriptbind method, `Human.DrawWeapon()`,
  found in Warhorse's own shipped scriptbind docs): confirmed **visually**
  real — the human watching the screen directly confirmed the ghost's sword
  was genuinely drawn — but this *also* left `HasMeleeWeapon=false`.
  Comparison against the real player: `HasMeleeWeapon` reads `false` while a
  weapon is sheathed-but-equipped and `true` the instant the real player
  draws it manually (confirmed live) — so the flag tracks the *animation
  system's* live drawn-state, not inventory, and not this scriptbind call
  either. It genuinely did flip `true` once the ghost was engaged in real
  combat during the A1 fight above — but the human confirmed, watching
  directly, the ghost still never swung back. Whatever flips the flag once a
  fight starts, it is not the same thing as the AI deciding to attack.

**Conclusion:** no achievable lever found this session for real two-way
combat. This is exactly the fallback the WO's own brief anticipated —
**ship one-sided aggro as v1**: NPCs can hurt an aggro'd ghost, it cannot
hurt them back. `human:DrawWeapon()` is wired into the real spawn path
anyway (Phase C) purely for visual presentation — it's proven harmless and
makes an aggro'd ghost look combat-ready rather than sheathed, at zero cost.

---

## Phase B — the confirmed shape

The WO's own proposed default (opt-in, off by default, a persistent console
toggle, one hardcoded faction) was presented to the human and **explicitly
changed** before any code was written. The human's stated concern:

> I do not want Player B to ALWAYS be perceived as Hostile. I only want the
> second (non-Main Char) to be perceived as hostile when an attack is made
> by either player. Similar to how Henry... is made to be.

WO-16's tested mechanism (`SetParent` onto a hostile faction) is a
**permanent membership** the moment it's applied — the shape the human
rejected. The confirmed design instead makes the attach **reactive and
temporary**, agreed explicitly ("Yes, that's it") after being proposed:

- **Attach trigger:** the ghost deals damage to a real NPC (an existing,
  already-proven hook — the moment a peer's `DamageDown` packet is applied
  locally), **or** the local player deals damage nearby (the existing
  `OnLocalHit` hook) — either player starting a fight is the trigger, not
  just the ghost.
- **Detach trigger:** no further combat involving that ghost for 20 seconds
  (`AggroHoldDuration`) — reverts to the ghost's original orphan/Civilians
  state, invisible to NPCs again, exactly like today's default.
- **Master switch (`mp_enable_aggro on|off`)** still gates whether *any* of
  this runs at all — decided locally per player, no session invite/agreement
  needed (unlike dice), because it only changes how *your own* local world
  treats an incoming ghost.

---

## Phase C — what got built

Real, permanent code across all three layers, replacing WO-16's console-only
clone and the gitignored `kcdmp-faction.txt` research file:

- **`kdcmp.lua`** — `KCD2MP.aggroEnabled` (off by default), `mp_enable_aggro
  on|off` console command (emits an `aggro_toggle` event over the existing
  log-tail event channel), and `KCD2MP_SpawnGhost` now takes the toggle into
  account: `esModularBehaviorTree` is `"IdleSeq"` when aggro is on, `""`
  (today's exact default) when off. `human:DrawWeapon()` fires once, 1s after
  spawn, only when aggro is on.
- **`native/KCDMP/rttr_abi.cpp`** — `set_ghost_faction_hostile(guid, hostile)`,
  a real callable function (not a file probe) reusing WO-15's ownership-safe
  `SetParent` recipe. `hostile=true` attaches via the same WO-16 donor pairing
  (`prepadeni_bandit_1` → `trosecko_enemies_bandits_prepadeniAmbushers_group1`).
  `hostile=false` — **a genuinely new code path, never exercised before this
  session** — hands `SetParent` a zeroed 16-byte buffer (an empty
  `shared_ptr<C_Faction>`), reproducing the ghost's own pre-attach orphan
  state rather than guessing at a different one.
- **`native/KCDMP/pipe_server.{h,cpp}`** — new pipe message `0x04
  SetFactionHostile [guid:16][hostile:1]`, agent → DLL, replies `0x81 Result`
  like every other command.
- **`dotnet/KcdMp.Client`** — `CombatPipe.SetFactionHostileAsync`;
  `HttpGameTransport.ReadGhostSoulGuidAsync` (a ghost's own `Soul.Guid`, not
  `SharedSoulGuid` — a locally-spawned ghost proxy carries `SharedSoulGuid=0`,
  so `Guid` is the identity that actually resolves through the DLL's
  `SoulsByGuid` lookup for it); `GameBridge` wires the `aggro_toggle` event,
  hooks `TriggerReactiveAggroAsync` into the existing `DamageDown` handler
  and the existing `OnLocalHit` handler, and sweeps expired holds on the main
  tick loop's existing cadence (cheap: one dictionary scan, no I/O, unless
  something actually expired).

**The toggle-off path touches none of this at runtime** — `esModularBehaviorTree`
stays `""`, no faction file, no pipe message, no C# hook fires. This was the
single hardest regression requirement and it was designed in, not bolted on.

---

## Phase D — testing

### Regression (toggle off) — clean pass, the non-negotiable one

Fresh game process, fresh mod install, `mp_enable_aggro` never touched
(default state). Spawned a ghost, checked three independent signals:

| Check | Result |
|---|---|
| `PerceptionHistory` — does it run perception? | **0** matching records, confirmed 3x on resample (one earlier "6" reading did not reproduce and is attributed to the perception buffer's own live/rolling nature, not a regression — see the raw session log) |
| `CombatSoul` | `IsUnarmed=true HasMeleeWeapon=false AttackersCount=0` — identical to every ghost this project has ever spawned |
| `FactionNode/Parent` | orphan (empty), never attached |

Byte-for-byte identical to pre-WO-17 behaviour, confirmed against the live
game, not inferred from reading the diff.

### Toggle on — mechanics confirmed

Fresh ghost spawned with `mp_enable_aggro on`: **2** `PerceptorName` records
in `PerceptionHistory` (real perception, matching WO-16), weapon-draw call
fires without error.

### Native pipe — attach *and* detach, verified over a window

`tools\Test-Aggro.ps1` (new, committed): drives the DLL's pipe directly,
standing in for the agent. `SetFactionHostile(hostile=true)` → verified via
`FactionNode/Parent/Name` immediately **and again 5 seconds later** (not just
an immediate read-back — this project's own documented trap).
`SetFactionHostile(hostile=false)` — the detach path's first-ever live
exercise — verified `Parent` reads back to orphan. Game process and debug
API healthy throughout. **PASS.**

### Full end-to-end — real relay, real agent, real game

`tools\Test-AggroE2E.ps1` (new, committed): a synthetic peer joins the real
relay (`KcdMpServer.exe`), the real agent (`KcdMpClient.exe`, unmodified
production build) connects to the real running game, `mp_enable_aggro` is
turned on through the real console → the real `aggro_toggle` log-tail event
→ confirmed in the agent's own log (`[aggro] enabled`). The peer sends a real
`Position` packet (agent spawns `kcd2mp_<id>` for it) then a real `Damage`
packet naming a live NPC (`ttkc_man_32`):

- NPC health dropped (100 → 97) through the real pipe/native `apply_damage`
  path.
- The peer's ghost was attached to the hostile faction
  (`FactionNode/Parent/Name` = `trosecko_enemies_bandits_prepadeniAmbushers_group1`),
  confirmed via the agent's own log (`[aggro] ghost 2 attached to hostile
  faction: True`).
- Re-run with the connection held open past the 20s hold window: the sweep
  fired automatically at ~t+20s (`Parent` went null, agent logged `[aggro]
  ghost 3 detached from hostile faction: True`) — no manual trigger, the real
  tick-loop sweep did it.

**PASS, both runs.** This is the strongest verification available without a
second physical player — the same synthetic-peer-through-real-relay-and-agent
pattern this project used for `Test-CombatE2E.ps1` and
`Test-AppearanceE2E.ps1`.

### Repeated live fights, different targets

Across this session: `ttkc_dusko` (A1's reproduction, direct faction attach,
real fight, real injuries, the floored-body limitation observed and
root-caused) and `ttkc_man_32` (the E2E synthetic-peer damage target, x2).
Not the "different NPCs, different location" breadth the WO asked for
ideally — session time went to closing A1/A2 and building the full
three-layer reactive mechanism instead. A future session repeating the live
NPC-attacks-ghost scenario against 2–3 more targets/locations would
strengthen this further, but is not, on the evidence gathered, expected to
surface a new failure mode — the mechanism (WO-15's fixed `SetParent`) is the
same one exercised repeatedly and cleanly across WO-15, WO-16, and this
session.

### Real two-player test — not attempted, stated plainly

**One machine, one copy of the game, no second player** — the same
constraint every prior WO in this project has stated honestly. Not
attempted, not faked, not skipped silently. The synthetic-peer E2E test
above is the closest available substitute and exercises the identical wire
path a real second player's client would use.

### Functional-weapon danger check

Moot in the sense the WO anticipated ("if built") — no functional weapon was
achieved (A2). `human:DrawWeapon()` is purely cosmetic (confirmed:
`HasMeleeWeapon` stays governed by the AI's own combat-engagement state, not
this call) and the ghost was never observed attempting an attack of any kind
across every fight in this session, so there is no evidence of any new
danger to the player.

---

## Is this "shared aggro"? Claim by claim

Written after the human asked, directly, whether committing this code means
concluding shared aggro is possible. It does not, and conflating the two
oversells what got built. This section exists so no future reader has to
reconstruct that distinction from the evidence scattered above.

**TRUE — proven, with hard evidence:**

- An NPC can be made to perceive and attack a ghost (a proxy representing the
  other player). Real, verified with telemetry across WO-15, WO-16, and this
  session, now permanent toggle-gated code.
- The attach is reactive and temporary, not a standing "this player is a
  bandit" flag — verified live, both the attach and the first-ever exercise
  of the detach path, held over an extended window.
- The whole chain — toggle → damage event → native faction write — works
  through real production code: the real agent, the real native plugin, the
  real game process. Verified via a synthetic peer speaking the real wire
  protocol through the real relay, the same pattern this project already
  trusts for combat and appearance sync.

**FALSE, or not established — do not claim these:**

- **"NPCs and ghosts fight each other."** False. This is one-sided. The
  ghost can be hurt; it cannot hurt back. No lever for the ghost to actually
  attack was found (A2). "Shared combat between a party and shared enemies"
  is not what this is — it is "an NPC can now notice and attack your
  friend's ghost."
- **"It's shared/synchronized state."** False, or at least not shown. Each
  player's own game decides, entirely locally, whether an NPC near them
  treats a ghost as hostile — from that player's own toggle and that
  player's own locally-observed combat events. Nothing about *which NPCs
  are hostile to which ghost* is synchronized between clients. What's
  shared is the same thing that was already shared before this WO: the
  underlying damage numbers.
- **"It's reliable under a sustained fight."** False. A1's floored-ghost bug
  is real and not fixed — a long enough fight can leave the ghost stuck in a
  broken-looking state while the game's own combat bookkeeping still thinks
  it's a live, standing target.
- **"It's verified for real multiplayer."** Not established. Every test this
  session ran against a synthetic peer script on one machine, standing in
  for a second player. The wire protocol and every server-side/agent-side
  code path a real peer would exercise were exercised for real — but real
  network latency, two independent live game processes, and a second
  physical human were not.

If this gets committed, the accurate one-line description is: **"NPCs can be
made to notice and attack a ghost, one-sidedly, opt-in, locally decided per
player, with two disclosed limitations, verified via synthetic peer
simulation."** Not "shared aggro is solved."

---

## The gate, answered plainly

- **Phase A's two bugs:** both real, both root-caused with hard evidence,
  both explicitly scoped as known v1 limitations (not fixed, not hidden) —
  one-sided combat, and a sustained fight can leave the ghost stuck floored.
- **Phase B's shape:** confirmed with the human, changed from the WO's own
  proposed default in response to explicit feedback, before any code was
  written.
- **Regression (toggle off):** clean pass, verified against the live game,
  the one result this WO could not ship without.
- **Phase D:** toggle-on mechanics, native attach/detach (including the
  detach path's first-ever exercise), and the full relay→agent→native→game
  chain are all verified live. Repeated-target breadth is thinner than
  ideal. Real two-player test not attempted — no second player available,
  stated honestly, not glossed over.
- **Is this ready for the human to decide to ship?** Yes, as a v1 with known,
  disclosed limits — not a proof of concept, and not oversold as
  finished-and-perfect either. The two open limitations (one-sided combat,
  the floored-body bug) are real product tradeoffs for the human to weigh,
  not implementation gaps hiding behind "should work." No code change here
  touched `VERSION` or built a release artifact — that remains the human's
  call, separately, per `docs/VERSIONING.md`.
