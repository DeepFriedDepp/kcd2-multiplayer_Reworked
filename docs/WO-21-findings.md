# WO-21 — is a too-bare behaviour tree the shared root cause of A1 and A2?

Investigated 2026-08-04 against KCD2 (Modding Tools build, PID 19188) with a
real save loaded in the Troskovice area, the `kdcmp` mod loaded, a freshly
built `KCDMP.dll` injected with the human's explicit go-ahead, and the human
present at the machine throughout.

**Bottom line up front: the hypothesis is refuted, at the level it was posed.**
`esModularBehaviorTree` does nothing in this game — `"IdleSeq"` names a
behaviour tree that does not exist. A1 and A2 cannot share "the ghost's tree is
too bare" as a root cause, because the ghost's tree setting was never a live
variable in the first place. The structural explanation underneath it (the
ghost has no Warhorse *brain*) survives and is well supported, but it is not
reachable from Lua, so no fix could be tested this session.

A1 was then reproduced live at the human's direction. **It reproduces — and
WO-17's published root cause for it is wrong in a specific, correctable way.**

---

## Phase 0 — what actually differentiates a real NPC from a ghost

### The `IdleSeq` puzzle, solved from shipped game data

WO-16 read `esModularBehaviorTree` off deer, a hare, a horse, a dog and a real
placed NPC and got `"IdleSeq"` every time, and reasonably read that as "a real,
in-use, generic top-level tree". It is simpler than that:

```
Scripts/Entities/AI/Shared/BasicAITable.lua:25
    esModularBehaviorTree = "IdleSeq",
```

That is the **class default**, inherited by every AI entity class in the game.
Everything reports `IdleSeq` because everything inherits `IdleSeq`.

Stronger still: I decompressed `Scripts.pak`, `Tables.pak` and
`IPL_GameData.pak` and content-grepped every `.xml`, `.lua`, `.txt` and `.csv`
inside them for the string `IdleSeq`. **It occurs exactly once in the entire
shipped game data — the line above.** There is no behaviour tree by that name
anywhere. The value names nothing.

Two consequences follow immediately:

- Reading `esModularBehaviorTree` off any entity can never distinguish
  anything. It is a constant.
- `KCD2MP_SpawnGhost`'s `""` (aggro off) versus `"IdleSeq"` (aggro on) is a
  distinction without a difference. Confirmed live: `rawget` on a ghost's own
  `Properties` shows the spawn-time value is not even stored — reads fall
  through to the class default regardless of what was passed at spawn.

### What the real mechanism is

KCD2 does not drive NPC behaviour through CryEngine modular behaviour trees at
all. It uses Warhorse's own **brain / subbrain** system, in `Libs/Tables/ai/`:

| brain | id | subbrains |
|---|---|---|
| `npc_basic` | `4b914d1c-724a-a92d-3e6b-d183d35b8b98` | `npc_basic_scheduler` (type 9) + `npc_basic_switch` (type 6 → `AI/npc/basic/switch/switch.xml`) |
| `npc_default` | `00000000-0000-0000-0000-000000000002...045002` | `npc_test_base_main` → `AI/default.xml` |

`AI/default.xml`, in its entirety, is one node: `Wait duration="-1"`. A tree
that does nothing, forever.

`npc_basic_switch`'s tree is ~100 KB and contains precisely the branches A1 and
A2 need, by filename: `handleHitReaction.xml`, `handleOnSoulRevived.xml`,
`reviveCleanup.xml`, `interrupt_wakeUp.xml`, `interrupt_attack.xml`,
`handleStimulusEnemy.xml`, `handleAwareness_combat.xml`.

So the *shape* of the WO's hypothesis was right — a real NPC has recovery and
combat branches a ghost does not. It is just one layer below where the WO (and
WO-16/17) looked, and the name `esModularBehaviorTree` has nothing to do with
it.

### Is the brain reachable? No — verified five ways

| Surface | Result |
|---|---|
| `Actor.SetAIBrainId(brainId)` — documented in Warhorse's own shipped scriptbind reference, "ID (guid) of brain must be from table brain" | **Not registered in this build.** `type(e.actor.SetAIBrainId)` = `nil` on a real guard and on a ghost |
| Any brain member on `AI`, `e.actor`, `e.soul` | 0 hits scanning every key for `brain` |
| `XGenAIModule.GetBrainVariable` / `SetBrainVariable` | registered, but take a WUID; returned `nil` for guard and ghost alike across four real variable names from `switch.xml` — no signal either way |
| REST reflection `/api/behavior?info` (`XBehaviorModule`) | **zero properties, zero methods** |
| `Soul` reflection | exposes `Archetype` — stats only (`base_stamina`, `normal_body_weight`, gender, race), no brain |

### Everything else at the Lua level reads identically

Guard `ttkc_man_5` (faction `trosecko_settlements_troskovice_soldiers_guards`,
UI name `soul_ui_name_guard` — a real combat-capable NPC) versus a
mod-spawned ghost:

```
esBehaviorSelectionTree        ""    both
sWH_AI_EntityCategory          ""    both
aicharacter_character          ""    both
bWH_PerceptibleObject          true  both
bWH_PerceptorObject            true  both
bWH_CreateSituationSubsystem   true  both
bWH_RequiresHome               true  both
```

Also tested and negative:

- **`AI.StartModularBehaviorTree`** — fault-free `nil` for `"IdleSeq"`,
  `"npc_basic_switch"`, and for the deliberate control
  `"zzz_definitely_not_a_tree_9781"`. Indistinguishable across a real name and
  a garbage name: inert, or at minimum unverifiable.
- **`soulPool` as a spawn property** (`"civilians"`, from
  `Libs/LuaXML/soulPool.xml`, the pool list the game's own bandit/soldier
  spawns draw from) — produced a fresh generic soul with
  `SharedSoulGuid=0`, identical to a plain ghost. No effect.

### Gate 0, answered plainly

**There is no Lua-level or reflection-level differentiator.** The real
differentiator is the Warhorse brain, and this session could neither read it
nor write it from any surface available to the mod. Per the WO's own
escalation clause, this needs native investigation: how a brain is bound to an
entity in `WHGame.dll` / `CryAISystem.dll`, and whether that binding can be
written the way WO-15's `SetParent` faction attach is. **Not attempted this
session — flagged, not started.**

---

## A correction WO-16 and WO-17 both need

WO-16's perception asymmetry **does not reproduce**. Its finding was that an
empty-tree ghost runs no perception and is never perceived, and that
`"IdleSeq"` was what turned perception on — the observation the whole
"brained ghost" idea rests on.

Live this session, `Playerwo21p0`, spawned through the mod's real unmodified
`KCD2MP_SpawnGhost` with `KCD2MP.aggroEnabled=false` — i.e. `mbt=""`, the
supposedly brainless configuration — in one capture of
`XGenAIModule.PerceptionHistory.GetRecords()`:

```
PerceptorName="Playerwo21p0"    5 records
PerceptibleName="Playerwo21p0"  18 records
```

It both perceives and is perceived, with the empty tree. Given that `IdleSeq`
names nothing, this is the expected result and WO-16's reading was an artifact
of the rolling perception buffer (a caveat WO-16 itself raised about that
query, and WO-17's Phase D hit the same instability — "one earlier '6' reading
did not reproduce").

**What this means for WO-17's shipped feature:** `mp_enable_aggro`'s
`esModularBehaviorTree` switch is a no-op. The aggro feature still works, but
it works entirely because of the native faction attach — not because of
anything the toggle does to the ghost's tree.

---

## The A1 reproduction — run live, at the human's direction

The human directed the remaining session time here, and explicitly accepted
save consequences ("This save is solely for testing purposes").

### Setup

Donor: WO-16's `prepadeni_bandit_1` is **not loaded in this save** — the
playthrough-specific rough edge WO-17 documented, hit for real. Five of its ten
faction-mates *are* loaded; used `prepadeni_bandit_2`
(`4d094502-004a-4a09-8d9d-be44d124c04b`). Pairing re-verified live:
`GetRelation(trosecko_settlements, trosecko_enemies_bandits_prepadeniAmbushers_group1)`
→ `type="enemy" reputation="-1"`, and the guards' faction inherits it.

Attach via the file-gated `probe_faction()` path (`kcdmp-faction.txt` beside a
freshly staged DLL copy, one injection per ghost) — WO-16's exact route,
chosen over the shipped `set_ghost_faction_hostile` pipe command because that
one hardcodes the unloaded `prepadeni_bandit_1` as donor. **No shipped code was
modified.** Every attach verified over HTTP, not just from the native log.

Four ghosts, all attached to the same hostile faction, all within 3 m of each
other and of `ttkc_man_7`:

| ghost | class | tree | armor/weapon preset | weapon drawn |
|---|---|---|---|---|
| A `wo21A` | NPC_Female | `""` | none (spawner skips presets for female, WO-20) | attempted, failed |
| B `wo21B` | NPC (male) | `"IdleSeq"` | yes | yes (aggro path) |
| D `wo21D` | NPC (male) | `""` | yes | no |
| F `wo21F` | NPC (male) | `""` | **none** (runtime-only bare spawn) | no |

*(One false start worth recording: the first pair spawned ~2.6 m in the air,
because the human was in flight mode and the spawner uses the player's Z. NPCs
ignored them entirely. Moved to ground level through the mod's own
`KCD2MP_UpdateGhost` — which preserved the faction attach — and the fight
started within seconds.)*

### Result 1 — every male ghost was beaten unconscious within ~60 s

Ghost B, from grounding:

```
15:20:18  hp=100 → 35.7   injured_torso, injured_left_leg, low_health, interrupt_deafness
15:20:25  hp=2.8          IsUnconscious=true, unconscious + buff_infinite_blindness
```

D: 100 → 0.4, unconscious, ~75 s after attach, **weapon never drawn**.
F: 100 → 20.0, unconscious, ~60 s after attach, **no preset, no weapon at all**.

Tree setting, armor preset and drawn weapon were all varied independently and
**none of them mattered**. Faction membership alone is sufficient, which is a
cleaner confirmation of WO-15/16/17's mechanism than any prior session got.

### Result 2 — A1 reproduces, but WO-17's root cause for it is wrong

WO-17 root-caused the floored ghost as the RPG layer *never registering* the
knockdown: "`IsDead=false, IsUnconscious=false` ... The RPG/combat layer never
registered anything happened — it still considers the ghost a live, standing,
viable target."

That is not what happens. Observed here:

```
IsUnconscious = true
buffs: unconscious, low_health, injured_torso, injured_left_leg,
       buff_infinite_blindness
health: frozen exactly (B 2.8, D 0.4) -- no regen, no bleed-out
AttackersCount: 8 -> 0 (the attackers correctly disengage and walk away)
```

The RPG layer registered it **perfectly**. This is an ordinary unconscious NPC,
not a state desync. The attackers do not keep swinging at a target their AI
thinks is upright — they stop, because the game correctly knows it is down.

**What is actually missing is the wake-up.** B held `IsUnconscious=true` for
**16 minutes**, D for **9 minutes**, health frozen to the decimal, until both
were removed. A real NPC recovers from unconsciousness; these never do — and
the wake-up branches (`handleOnSoulRevived`, `interrupt_wakeUp`,
`reviveCleanup`) live in `npc_basic_switch`, the subbrain the ghost does not
have. Phase 0's structural finding explains A1 exactly. It is still not
fixable from Lua.

WO-17's supporting evidence for its version should also be retired: it cited
the ghost's `Roles` list carrying `RANENY_NA_ZEMI_MUZ` ("wounded on the
ground") as a live animation-state role disconnected from the RPG layer.
`Roles` is a **static catalogue** of every dialogue/animation role the soul's
archetype can ever play — a freshly spawned ghost that has never been touched
already lists `RANENY_NA_ZEMI_ZENA`. It carries no state at all.

### Result 3 — new, unexplained: the female ghost was never attacked

Ghost A held **100 hp, untouched, for the entire session** (~16 minutes) with
the identical hostile-faction attach, standing *between* two ghosts that were
beaten unconscious. Position is ruled out by that geometry.

Confounds ruled out by D and F: it is not the armor preset (F had none and was
attacked), not the drawn weapon (D's was sheathed), not the tree (all three
males varied). The remaining difference is that A is `NPC_Female`.

**Stated honestly: n=1 female against n=3 males, one location, one session.**
This is a strong signal, not an established fact. If it holds, it is
product-relevant — roughly half of all players get a female ghost by name hash
(`KCD2MP_PickFaceForPlayer`, `h % 2`), and for them `mp_enable_aggro` may do
nothing observable. Worth a dedicated confirmation with 2–3 female ghosts in a
different location before anyone acts on it.

### A2 — not advanced

No ghost attempted to attack anything at any point. `HasMeleeWeapon` was
`true` on B (see below) and it still never swung. A2 remains exactly where
WO-17 left it: **not solved**, and this session found no new lever.

One correction: WO-17 concluded `human:DrawWeapon()` "also left
`HasMeleeWeapon=false`" and that the flag only flips once real combat starts.
Observed here, B read `HasMeleeWeapon=true` from the first sample onward — with
its weapon drawn by the aggro path, before any NPC had touched it. On A the
same call returned fault-free and left the flag `false`, because A is female
and therefore has no weapon item to draw. So the flag tracks *a real equipped
weapon actually being drawn*, and `DrawWeapon` does flip it when there is one.
It still confers no ability to fight back.

---

## Phase 2 — the two regression risks

**Both are moot, and not because they passed.** Both were premised on applying
"a richer tree" to a ghost. No richer configuration exists to apply at this
level, so there is nothing new to regress:

- **2a, `ForceMount`:** untested this session. WO-16's result stands unchanged
  and, given `esModularBehaviorTree` is inert, its "brained vs control ghost"
  comparison was always comparing two identical configurations.
- **2b, fighting the mod's position sync:** untested as posed. The nearest
  real evidence gathered was moving two faction-attached ghosts through the
  mod's real `KCD2MP_UpdateGhost` path — they moved cleanly to the target
  position and stayed there, with no independent movement of their own at any
  point (positions byte-stable across 16 minutes of sampling, including while
  under attack). Consistent with a ghost that makes no movement decisions,
  which is exactly what a brainless entity should do.

If native brain assignment is ever achieved, **both regression risks come back
live and must be tested then** — that is the point at which a ghost could
start making its own pathing decisions while `KCD2MP_InterpTick` forces it
somewhere else.

---

## Gates, answered

- **Gate 0 — the real differentiator?** Not present at the Lua/Properties
  level, with six independent lines of evidence. `esModularBehaviorTree` is
  inert and `IdleSeq` names nothing. The genuine differentiator is the
  Warhorse brain (`npc_basic` vs nothing), unreachable from every surface the
  mod can touch. **Escalated to native, not guessed at.**
- **Gate 1 — A1 (floored recovery)?** The WO's hypothesis could not be
  tested as written. A1 itself was reproduced and **re-root-caused**: it is
  an ordinary, correctly-registered unconsciousness that never ends, because
  no wake-up behaviour runs. Not fixed. Not fixable from Lua.
- **Gate 1 — A2 (fight back)?** **No change.** No ghost attempted to act
  against anything. Not solved, not partially solved.
- **Gate 2 — regressions?** Neither materialized, and neither was genuinely
  exercised, because there was no richer configuration to apply. Said plainly
  rather than claimed as a pass.

## What this WO changes, and what it does not

**Does not change:** `KCD2MP_SpawnGhost`'s defaults, the aggro toggle's
shipped behaviour, `VERSION`, or the release pipeline. The only committed code
is new test tooling under `tools/`. Every test spawn was runtime-only and
removed at the end of the session; `KCD2MP.aggroEnabled` was returned to
`false`.

**Should change, as a follow-up decision that is not this WO's to make:**

1. `KCD2MP_SpawnGhost`'s `mbt` switch is dead code. It can go, or stay as a
   harmless no-op, but the comments around it (and `WO-16-release-candidate.md`'s
   Phase C description) currently claim it does something it does not.
2. `PROJECT-STATE.md` and the README's aggro limitations should carry A1's
   corrected root cause — "an aggro'd ghost knocked unconscious never wakes
   up", not "the RPG layer never registers the knockdown".
3. The female-ghost result needs a dedicated confirmation run before it is
   written down as fact anywhere user-facing.

## Files touched

- `tools/Probe-WO21-Brain.ps1` (new) — Phase 0 property/brain dump and diff
- `tools/wo21-lua.ps1` (new) — small ExecuteString driver + `[WO21]` log reader
- `tools/Wo21-Watch.ps1` (new) — paired-ghost combat telemetry watcher
- `docs/WO-21-findings.md`, `docs/WO-21-progress.md` (new)

No changes to `kdcmp.lua`, `native/`, `dotnet/`, `VERSION`, or the installer.
