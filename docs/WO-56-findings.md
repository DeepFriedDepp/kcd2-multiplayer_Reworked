# WO-56 — what would it actually take for every player to be Henry, not a ghost?

Worked 2026-08-25 (Fable 5). Design document only — no code, no prototypes, no
VERSION change. Every claim carries its evidence tier: **observed** (read
directly out of a binary/disassembly this session, or a cited live
observation from an earlier WO) / **read-but-unrendered** (a mechanism traced
in code, never executed) / **inferred** (a step beyond the bytes, labelled) /
**inconclusive**. Nothing is rounded up.

**Bottom line up front.** The WO-26 crash is no longer mysterious — it now
reads as a *malformed spawn*, not as proof two `C_Player` objects cannot
coexist (Phase 1). The class itself is even multi-instance-shaped in its
bones (`Init` vs `InitLocalPlayer` are separate vtable slots — CryEngine MP
heritage). But the investigation kills the idea anyway, for a sharper reason
than the crash ever was: **Henry's special status is granted by singular
slots — `GetPlayer`, `PlayerSoul`, the camera, the save's `PlayerId`, the
faction tree's player node — not by the `C_Player` vtable.** A second
`C_Player`-class entity would not be pointed to by any of those slots, so it
inherits none of the immunity this WO hoped to borrow (Phase 2). And the
sharpest hoped-for payoff — deleting Flow B's cross-machine damage layer —
breaks on topology, not on entity class: the remote player's authoritative
health lives on the remote machine, so the wire hop survives any local
representation (Phase 4). Meanwhile NPC hits *already* land natively on
today's `C_NPCActor` ghosts — that is the very signal Flow B samples.
Recommendation: **do not pursue** (Phase 6). WO-51's plan stands unchanged.

---

## Phase 1 — the original attempt, re-read and re-explained

### 1.1 What was actually tried (2026-08-06, `WO-26-findings.md` Phase 1)

- The spawn was **bare**: `XGenAIModule.SpawnEntity{Name="wo26P",
  ClassName="Player", Pos=…}` — no `SharedSoulGuid`, no `SoulArchetypeName`,
  no faction, 4 m from the real player (observed, WO-26:239). Note the date:
  this predates WO-22's discovery that soul binding is what makes any spawned
  entity whole — the project's own ghosts were still brainless then too.
- Log signature: `[Warning] no archetype found for 'wo26P' of class
  'Player', returning 0`, then `[Error] NPC wo26P does not have a faction.`
  ×52, then the log ends; BugSplat fired; process gone (observed, WO-26:243-249).
- WO-26's own honest limit: the crash is inferred from adjacency — **no dump
  was analysed, no faulting frame recovered** (WO-26:263-269). Its gate
  statement already anticipated this session: a future attempt "would need to
  supply an archetype and a faction … before the first AI frame runs" and
  called that "a native-plugin-scale problem, not a Lua one" (WO-26:279-285).

### 1.2 What the modern toolkit adds (new static evidence, this session)

All **observed** — decompiled this session from the installed binaries
(EntityModule via the surviving WO-42 Ghidra project; RPGModule imported
fresh; fingerprints per WO-42 §1).

**(a) The archetype warning is non-fatal, and its mechanism is now known.**
`wh::rpgmodule::C_SoulList::GetDefaultSoulArchetypeFromEntity` (RPGModule
`0x745400`, string-anchored, SoulList.cpp): reads the entity script's
`defaultSoulArchetype` property → falls back to a class-name lookup → if both
fail, logs exactly WO-26's warning and **returns archetype id 0**. So the
spawned Player-class entity got a soul-archetype of 0 — a soul-less,
identity-less RPG wrapper — and execution continued. The property side is
now observed too: `player.lua` (extracted from `Scripts.pak` this session)
declares `defaultSoulClass = "player"` and **no `defaultSoulArchetype` at
all** — the real player's soul (`player_henry`) is bound by game-start
machinery, not by this spawn-time path, so a *spawned* Player-class entity
starves by design.

**(b) The per-frame faction error is also non-fatal in itself.**
`wh::rpgmodule::C_NPCFactionNode::GetFactionPtr` (RPGModule `0x443FA0` /
`0x444060`, string-anchored): if the faction pointer is null it logs `NPC %s
does not have a faction.` and **returns the null pointer to its caller**.
Two collateral facts: the "NPC" in the message is just this class's wording —
the RPG layer wraps *every* spawned entity, `Player`-class included, in NPC
faction machinery; and every caller of `GetFactionPtr` received null every
frame for ~52 frames, so the process survived ≈1 s of that before dying.

**(c) The engine contains a deliberate "malformed player → kill the process"
guard.** `wh::entitymodule::C_Player::Init` (EntityModule `0xADB1A0`,
string-anchored, Player.cpp line 0x101): if the player entity has no
character (the render/animation character), it logs *"Player has no
character. This will crash anyway..."* and calls
`wh::shared::TerminateThisProcess(0xf7)`. Warhorse's own comment string tells
us they consider a partially-provisioned `C_Player` unsupported-by-design —
they chose to terminate rather than tolerate it.

### 1.3 The crash, re-explained — precisely where honesty allows

The chain **spawn → soul archetype 0 → no faction → nulls handed to every
faction consumer → death within ~52 frames** is now traced at every step but
the last. The final fault was never captured (no dump, WO-26's own caveat),
so two candidate finishes exist and cannot be separated without re-running:

- a null-dereference downstream of `GetFactionPtr`'s null returns (any of its
  per-frame callers), or
- `C_Player::Init`'s own `TerminateThisProcess` firing on the character check
  (timing fits only if that init step runs deferred; not established).

**Verdict on the history: the 2026-08-06 result was a symptom of a bare
spawn, not a wall.** Every missing ingredient it died of is one the project
has since learned to supply to ghosts (soul via `SharedSoulGuid`, WO-22;
faction at spawn, shipped `kdcmp.lua`). "A second `C_Player` crashes the
game" over-claimed — the observed fact is "a second `C_Player` *with no soul,
no archetype, no faction and possibly no character* dies within a second."
Those are different statements. What survives of WO-26's verdict is its
structural half — the single-slot inventory — which Phase 2 now extends and
which turns out to be the real wall.

---

## Phase 2 — is "exactly one player" a hard wall or a soft convention?

### 2.1 The class is multi-instance-shaped in its bones

**Observed (this session):** `C_Player::Init` and `C_Player::InitLocalPlayer`
are separate functions on separate vtable slots (`C_Player::vftable`
`0xE96F78`, slots `+0x38` and `+0x290` respectively; both string-anchored).
`InitLocalPlayer` does the local-only wiring: sets the global `player_who`
var to `player_henry`/`player_theresa`, broadcasts a module message (id
`0x28`) through `wh::framework::C_ModulesManager::ProcessMessage`, binds an
`environment_listener`. This split is CryEngine MP heritage — an engine
lineage where remote players got `Init` but only the local client's actor got
`InitLocalPlayer`. The API *shape* for a non-local player instance still
exists.

### 2.2 But this build's `Init` performs global, singular registrations

**Observed (this session), in `C_Player::Init` (`0xADB1A0`):**

- registers itself into the object at `GameIface+8` via `vtbl[+0x338](obj,
  this+0xBE0, "Player", 1)` — a name-keyed registration whose registry was
  not identified further (Framework-side, not imported);
- registers itself into the object behind `GameIface+0xE8` (`vtbl[0x58]()` →
  `vtbl[0x20](_, this)`);
- binds the global variables `player_in_crouch` and `player_stealth_skill`
  **to addresses inside this instance** (`this+0xE70`, `this+0xE74`).

A second `Init` would re-run all of these. Whether each registry overwrites
(second instance silently becomes "the player" for that consumer — hijack) or
collides (duplicate-key failure) was not determined. Either behaviour is
wrong for our purpose; hijack is the dangerous one.

### 2.3 The player-slot chain — where "the player" actually lives

**Observed (this session):** `C_EntityModule::GetPlayerActor` (`0x71B330`,
exported) is a thin virtual → `vtbl[+0x2D8]` → `GetPlayer` (`0x71B300`,
exported) = `GetGameIface()->[+8]->vtbl[+0x218]()`. The player is fetched
from **one Framework-side slot**, not stored per-module. The EntityModule
export table (parsed this session, PE walk) exports **no `SetPlayer*`** —
its player-related exports are exactly `GetPlayer`/`GetPlayerActor`/
`GetScriptBindPlayer`/`GetPlayerTouchedManager` (a differently-named setter
elsewhere is not ruled out).
Whether `Init`'s `"Player"` registration (§2.2) is the write side of this
exact slot was not established (same object, `GameIface+8`, different vtable
offsets — plausible, unproven).

### 2.4 The singularity audit — who keys off "the" player

| layer | the singular thing | evidence |
|---|---|---|
| Framework | `GameIface[+8]->vtbl[+0x218]()` — one player slot behind every `GetPlayer*` | observed, this session |
| RPG souls | `SoulList::PlayerSoul`, single read-only `Soul*` = `player_henry`; exactly 3 shipped souls of soul-class 5, alternates not concurrent | observed, WO-26:206-217 |
| Reputation | `C_FactionBase::GetPlayerReputation/GetPlayerRenown/IsPlayerNode` — the faction tree has one player node | observed (exports), this session |
| Save | `C_SaveGameDescription::GetPlayerId` (framework, used by GUIModule) | observed (export), this session |
| Script layer | `g_localActor` single Lua global; gamerules = `SinglePlayer.lua`, the only gamerules in the binary | observed, WO-26:219-223 / WO-52 |
| Player services | `PlayerModule.dll` = per-process singular services (fast travel, minigames, tutorial, keybinds, FOW) | observed (class-string survey), this session |
| Globals | `player_who`, `player_in_crouch`, `player_stealth_skill` bound to *the* instance | observed, this session |
| Identity traps | a second soul named "Dude", own GUID, already sits at the player's exact position — "is this the player" checks are subtle even today | observed, PROJECT-STATE traps |

### 2.5 The decisive point: the special status is the slot, not the class

The WO's motivating instinct — "Henry is the one thing not subject to the
proximity-gated AI/simulation limits" — attributes the immunity to the wrong
thing. The engine simulates at fidelity *near the local player's position*
(AI quiet at 340 m, WO-26, observed; the whole WO-51 option-4 rejection rests
on it). Every "near the player?" check resolves through the singular
accessors in §2.3/§2.4 — which would keep returning the original local
Henry. **A second `C_Player`-class entity would stand in the world with a
player's vtable and nobody asking about "the player" would ever mean it.** No
second simulation bubble, no save/quest identity, no camera, no input. The
immunity this WO wanted to borrow is relational, and the relation is
occupied. (**Inferred** — from the slot architecture read this session plus
WO-26/WO-51's observed proximity gating; not live-tested, and stated as the
load-bearing inference of this document.)

### 2.6 Verdict, in the WO's own two-part form

- **"A second `C_Player` object can exist without crashing"** —
  **inconclusive, leaning plausible** with full provisioning (soul +
  archetype + faction + character), which nobody has ever attempted. The two
  known fatal paths (§1.2) are both starvation faults, not "second instance
  detected" checks; no code read this session refuses a second instance *as
  such*.
- **"…and behave correctly as a player-grade combatant"** — **hard wall in
  practice.** Correct behaviour would require occupying or duplicating the
  singular slots (player soul, Framework player slot, reputation node, input
  path), i.e. rewriting the relation the whole game is built on — and §2.2's
  registration side-effects mean even *constructing* one risks hijacking
  those slots for the real player. This is the WO-26 conclusion, rebuilt on
  named mechanisms instead of one crash.

---

## Phase 3 — if it existed, what would drive it?

- **A `C_Player` has no brain.** The class's autonomy is the human at the
  keyboard; its `__FUNCTION__` inventory (9 strings, observed this session:
  `DoChat`, `DrawTorch`, `ExecuteTeleportImpl`, `Init`, `InitLocalPlayer`,
  `ProcessSliding`, `Use*Item`) is input-adjacent machinery. A remote Henry
  is a statue unless *everything* is streamed. Today's ghost brain provides,
  for free: knockout **recovery** (a brainless ghost stays down forever —
  A1, WO-22, observed), reactive self-defence (WO-26 Phase 0, observed), and
  engagement behaviour. All of that would be lost and would have to be
  re-transmitted or re-implemented.
- **Position writes would probably land** (they land on the real player even
  in menus, WO-12, observed) — but the position stream is the part that
  already works on ghosts. Locomotion *animation* under a pure position
  stream on a player-class body is unknown (inconclusive; never tested on
  any class).
- **Combat actions are already class-agnostic.** The working native swing
  primitive (`GetOrCreateCombatActor` → `C_CombatAnimAction` →
  `QueueAction`, WO-45, observed-live) was built precisely because it works
  on any `C_Actor` regardless of leaf class (WO-44 §2). The one thing
  `C_Player` class membership would fix — the `vtbl[0x80]` guard that blocks
  `PlayAnim` on ghosts (WO-43 correction, observed) — is a problem the
  project already routed around.

Net: the input side does not get easier — it gets strictly harder. Same wire
data as today (the WO's own Phase-3 framing is confirmed: the data still has
to be sent), applied to a body with *less* local autonomy than the current
puppet.

---

## Phase 4 — the payoff chased directly: does this fix Flow B?

**No. The reasoning breaks down at topology, one step before entity class
ever matters.**

Flow B's anatomy (WO-28 Phase 3, read): NPC in the authority's world hits
the remote player's ghost → the ghost's health drops **natively** → a Lua
sensor diffs it → `0x21` routed over the relay → applied to the remote
machine's real Henry through the DLL. The unverified step (WO-51 §1.4,
standing) is the cross-machine hop and apply.

- **The engine's own combat machinery already recognizes and damages the
  ghost.** That is not the gap. A `C_NPCActor` ghost is a real, native combat
  victim — hits land on it, and its own hits land, through real hit
  detection (WO-26 Phase 0, all observed: the player's hit dropped the ghost
  100→99.4 and registered as a crime with an injury buff; the ghost's
  counterattack dropped the *player* 100→57.5; a ghost fought another ghost
  to death 340 m away; Flow B's sensor exists *because* ghost health
  genuinely drops). Swapping the victim's class from `C_NPCActor` to
  `C_Player` upgrades nothing that is broken.
- **The wire hop is irreducible.** The remote player's authoritative health
  lives on the remote machine. Whatever entity locally absorbs the NPC's
  hit — ghost, remote Henry, anything — is a local copy whose damage must
  still be detected, transmitted, and applied remotely. That is Flow B,
  re-derived. A remote Henry would need the *same* sensor→wire→apply layer,
  and its cross-machine step would be exactly as unverified as today's.
- What class *would* change, honestly listed: NPC targeting/difficulty
  treatment of an `AIOBJECT_PLAYER`(=100) target vs an actor(=5) (WO-26,
  observed values; behavioural consequence untested); the `PlayAnim` guard
  (moot, §Phase 3); possibly player-grade sync-attack pairing. These are
  fidelity nuances inside the authority's world — none touches the
  never-verified step, and none needs a `C_Player` to pursue (the nuances
  worth having are cheaper to chase on the existing ghost).

**Conditional stated plainly, as the WO asks:** even if Phases 1–3 all broke
our way — a second Henry exists, behaves, is driven — player-vs-NPC combat
for the non-authority player would still require Flow B's cross-machine
damage layer, verified, exactly as WO-51's WO-B already demands. The
simplification this phase hoped for does not exist.

---

## Phase 5 — honest scope: what this would and wouldn't replace

**It replaces almost nothing.** Walking the shipped ghost stack: position
stream + interpolation (still needed — the body must be told where to be),
appearance/equipment sync (still needed — a `C_Player` body doesn't dress
itself), name-keyed identity and nameplates (still needed), combat-swing
cues and the native swing path (still needed — remote attacks must render),
drawn-state sync (still needed), item-drop sync (untouched), health/death
events and Flow A/B (still needed, Phase 4), NPC sync (completely
orthogonal). The only layer that changes is *what kind of entity receives
the stream* — and per Phases 3–4 the change is net-negative: lost brain
autonomy, no gained damage path.

**New costs nothing else on the table has**, confirming the WO's suspicion
rather than underselling it:

- a persistent `Player`-class entity entering the **save file** (ghosts
  already complicate reloads, WO-27/28; a second Player in the save is
  untested against load/quest machinery — save corruption is on the table);
- §2.2's registration side-effects on construction — the failure mode is not
  "the new entity is broken" but "**the real player's** global bindings now
  point at the imposter";
- the per-machine soul problem: only `player_bohuta`/`player_naked` exist as
  spare player-class souls (WO-26, observed) — two spares, N players, and
  `PlayerSoul` still points at `player_henry` regardless;
- every crash here is a BugSplat-grade process death (observed once
  already), on the machine hosting the shared fight.

This is, as predicted, the most expensive and riskiest option this project
has evaluated — and unlike WO-51's option 4 (which at least delivered one
true thing inside a 30 m bubble), its unique payoff evaporated under
analysis.

---

## Phase 6 — recommendation

**Do not pursue. Close "be Henry" again — this time on mechanism, not on a
crash.** The 2026-08-06 verdict was right for a wrong-ish reason; the right
reason is: the specialness this architecture wants to borrow is granted by
singular slots a second instance cannot occupy (§2.5), and the one concrete
prize (Phase 4) is blocked by topology that no local representation can
change. WO-51's recommendation stack (measure joint combat → verify Flow B →
receiver-side suppression → engagement claims) is unaffected and remains the
plan; nothing found this session competes with it.

**What evidence would change this:**

1. **The slot inference failing live** — e.g. a fully-provisioned second
   `C_Player` observably getting a simulation bubble, or engine code found
   doing "is a player" by class/AIObject-type rather than via the singular
   accessors, in a system that matters (AI LOD, streaming, combat). This is
   the disprovable core of §2.5; anything that breaks it reopens the file.
2. **A slot-swap primitive surfacing** — a writable path that re-points
   `GameIface[+8]`'s player slot / `PlayerSoul` at runtime (a setter, a
   possession/cutscene mechanism, a Theresa-switch path). That wouldn't
   revive *this* WO (N simultaneous Henrys) but would enable a different,
   narrower idea — temporary authority-by-possession — which would deserve
   its own analysis before anyone builds toward it.
3. Note what does **not** change it: Flow B failing verification does not
   revive this option — a remote Henry needs the same wire hop (Phase 4), so
   it inherits the failure rather than fixing it.

**If someone pursues it anyway**, the first bounded step is cheap and
half-done: finish the static read (the `defaultSoulArchetype` value in
`player.lua`; whether `Init`'s `"Player"` registration is the `GetPlayer`
slot's write side — one Framework.dll import); then a single fully-provisioned
spawn (`ClassName="Player"` + `SharedSoulGuid` of `player_bohuta` + faction
at spawn) on a disposable save, expecting only to answer §2.6's first
question. Budget one session; expect the answer to be "it exists and is
useless," because existence was never the wall.

---

## Where solid ground ends

**Observed (this session, static):** `GetDefaultSoulArchetypeFromEntity` and
its non-fatal fallback chain; `GetFactionPtr`'s non-fatal null return;
`C_Player::Init`'s registrations, global-var binds, and
`TerminateThisProcess` guard; the `Init`/`InitLocalPlayer` vtable-slot split;
`GetPlayerActor`→`GetPlayer`→`GameIface[+8]->vtbl[+0x218]` chain; the
no-player-setter export inventory; `C_SaveGameDescription::GetPlayerId` and
the `C_FactionBase` player-node exports; the 9-string `C_Player`
`__FUNCTION__` inventory.

**Observed (cited from earlier WOs):** the WO-26 spawn, log signature, and
crash adjacency; ghost vptr = `C_NPCActor` family and player = the only
`C_Player` (WO-45, live); the ghost-blocking `vtbl[0x80]` guard (WO-43,
live); rung-2 swings on ghosts (WO-45, live); NPC/player hits landing
natively on ghosts (WO-26, live); Flow B's built-but-unverified cross-machine
step (WO-28/WO-51).

**Inferred, labelled:** §2.5 (slot-not-class) — the document's load-bearing
inference; §1.3's two candidate crash finishes (explicitly not separated);
"no second simulation bubble" (follows from §2.5, untested live).

**Inconclusive / not determined:** whether the `"Player"` registration and
the `GetPlayer` slot are the same storage; overwrite-vs-collide semantics of
`Init`'s registrations; save-system behaviour with a second Player-class
entity; locomotion animation of any class under a pure position stream;
whether a fully-provisioned second `C_Player` can exist at all.

**Deliberately not done:** no game launched, no spawn attempted, no code or
`VERSION` changes, no Framework.dll import (bounded out; named as the next
static step if ever needed).
