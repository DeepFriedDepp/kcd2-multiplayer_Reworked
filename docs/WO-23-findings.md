# WO-23 — auditing every open limitation against `kcd2-mod-docs`

Investigated 2026-08-06, desk audit only. **The KCD2 Modding Tools game was not
running this session** (`localhost:1403` unreachable throughout) — offered the
choice between a desk-only audit and pausing for the human to launch the game,
and the human chose desk-only. **Nothing in this document is a live
observation.** Every claim below is either a citation from the extracted
`muyuanjin/kcd2-mod-docs` repo (Warhorse's shipped scriptbind docs, extracted
`Scripts.pak`/`Tables.pak`, the Skald function-schema `d_definitions.xml`) or a
citation from this project's own git history/source, cross-referenced against
those. Anything that needs the game running is flagged as an untested lead,
not rounded up to a result.

Source repo used: the clone from WO-22, recovered at
`%LOCALAPPDATA%\Temp\claude\C--Users-Jonasty-Documents-KCD2-MP\5f6ff8af-f32a-4cf5-a01f-f528d92d2ece\scratchpad\kcd2-mod-docs`
(same commit WO-22 used, `9cb0675`, "docs: clarify bundled pak script path").
That scratchpad directory belongs to a different, expired session, so it will
not persist — a future session needs to re-clone `muyuanjin/kcd2-mod-docs` if
it wants this data again.

---

## Item 1 — Weapon sync: `HasMeleeWeapon`, re-audited

**The limitation as stated in the session prompt is stale.** It was already
corrected once, in `docs/WO-21-findings.md:261-272`, before this session
started:

> Observed here, B read `HasMeleeWeapon=true` from the first sample onward —
> with its weapon drawn by the aggro path, before any NPC had touched it. On A
> the same call returned fault-free and left the flag `false`, because A is
> female and therefore has no weapon item to draw. So the flag tracks *a real
> equipped weapon actually being drawn*, and `DrawWeapon` does flip it when
> there is one.

So `HasMeleeWeapon` does become `true` — on a **male** ghost, with a real
weapon item equipped, once `human:DrawWeapon()` is called. WO-17's original
"never becomes true" was measured on a case (or a female ghost) where no
weapon item existed to draw, not a broken call.

**Shape-mismatch check on `DrawWeapon` and `HasMeleeWeapon`, done properly this
session:**

- `Human.DrawWeapon()` — `script_bind_2025_01_14/C_ScriptBind_Human__DrawWeapon@IFunctionHandler__.html`:
  `virtual int DrawWeapon(IFunctionHandler* pH)`, no parameters, "Draw active
  weapon set." This is exactly what `kdcmp.lua:1415` calls
  (`g.entity.human:DrawWeapon()`). **No mismatch** — signature matches.
- `HasMeleeWeapon` is **not a method at all** — it is a read-only output port
  on the `I_CombatSoulProperties` reflection node
  (`wh::rpgmodule::I_CombatSoul`), confirmed against the Skald schema
  (`Scripts/Quests/Testing/tv/d_definitions.xml:8855-8868`):
  `AttackersCount, SkirmishStatistics, Target, IsUnarmed, HasMeleeWeapon,
  HasMissileWeapon` are all `Direction="Out"`. There is no setter surface for
  it anywhere in the schema. Confirms this project's own approach (drive the
  AI's real weapon-drawn state, then read the derived flag) is the only
  correct one — there is no "call X to set `HasMeleeWeapon`" to have missed.
- `EquipmentManager.EquipItem`/`EquipmentManager.EquippedWeaponsByClassId` (the
  calls WO-9/WO-10 use for gear sync) have **no entry anywhere** in either the
  Skald schema or the scriptbind HTML docs — they are pure RTTR reflection
  methods, undocumented by Warhorse, discovered empirically via the Modding
  Tools' own `?info` browser. There is nothing to compare them against; WO-9/
  WO-10 already round-tripped them live and confirmed they work.

**A real bug found: the shipped code comment is stale, not just the WO
description.** `kdcmp/Data/Scripts/Startup/kdcmp.lua:1404-1410` still reads:

```lua
-- WO-17: human:DrawWeapon() is a real, visually-confirmed native mutation
-- (unlike EquipWeaponPreset, which is cosmetic-only, WO-9) -- it does NOT
-- flip CombatSoul.HasMeleeWeapon on an NPC (confirmed live: that flag
-- tracks the AI's own combat-engagement state, not the item-in-hand
-- visual), so this does not grant real retaliation capability.
```

This is the exact claim WO-21 disproved five commits before WO-22 even
started. The comment was never updated. **Not fixed this session** (comment
fixes are cosmetic and this WO's scope is investigation), but flagged: the
`DrawWeapon` call in that block is unconditional and only runs when
`KCD2MP.aggroEnabled` — since WO-22, that same call now runs against
soul-backed, brained ghosts and *does* confer real `HasMeleeWeapon=true` on
males with a preset weapon. The comment should say so.

**Retested against WO-22's premise change (soul required):** already done, in
WO-22 itself, not redone here. `docs/WO-22-brain-lead.md`'s Gate A2 section
found: with a real soul + real brain, `HasMeleeWeapon=true` throughout,
`AttackersCount` up to 7, and the ghost is "a participant in combat rather
than a prop in it" — but every hostile ghost tested chose to **flee** rather
than land a blow (n=3, all bandit souls, all outnumbered 4:1 by armed guards).
"Fights back" remains undemonstrated, not because the flag is wrong, but
because no ghost so far has been in a fight it could plausibly win.

**Checked for a documented "force this NPC to attack" lever, found none.**
Searched the Skald schema for any `Attack`-named function beyond passive
triggers/enums (`d_definitions.xml`, `grep -n 'Name="[A-Za-z]*Attack'`) —
every hit is either an enum value, a hidden animation-graph trigger port, or
an autotest port. No callable "attack now" function exists in the schema.
This is consistent with combat participation being an emergent AI-brain
decision (morale, odds, context), not a settable flag — matching WO-22's own
framing of "a real behavioural decision."

**Result: checked, no shape mismatch found in the calls themselves.** The
open gap is real but is not a wrong parameter — it's that no soul-backed
ghost has yet been tested in a fight it has reason to win. WO-22's own
flagged follow-up (`AI.AddPersonallyHostile`/`AI.SetAttentiontarget` on a now-
brained ghost — "the obvious next experiment... flagged not answered") is
still the correct next lever, and it needs the game running.

---

## Item 2 — Appearance sync: female gear, re-audited

**The limitation, precisely** (`docs/WO-20-faces.md:165-208`): a male item
class (e.g. `BootsKnee03_m01_C`) equips fault-free (`ok=true`) on a
female-classed ghost or a bare `NPC_Female` control, but never renders —
`EquippedArmorsByClassId` reads back her own default outfit, the male item
never appears. WO-20's own conclusion: a real fix "would need a per-slot
gender-equivalent item mapping... which is new scope."

**Checked directly against `Libs/Tables/item/item.xml`** (5,143 lines, 1,916
`<Armor>` entries) for exactly that mapping:

- The `_m0X` suffix WO-20 read as a gender marker is **not** a gender marker —
  it is a model/variant index shared by both sexes. Female-body items exist
  and also carry `_m01`, `_m02`, etc. (e.g. `F_SimpleDress01_m01_D`,
  `F_SimpleDress02_m01_C`). **This is a correction to WO-20's stated root
  cause**, though not one that changes its practical conclusion (see below).
- The real gender marker is a distinct `F_` name prefix. Enumerating every
  `F_`-prefixed base item class in `item.xml` gives exactly 39 distinct
  families (315 total variants): `F_Bonnet`, `F_Cap`, `F_Cotehardie`,
  `F_HairDecor`, `F_Hood`, `F_Shoes` (×2), `F_SimpleDress` (×7 + 2 named),
  `F_Surcote`, `F_Veil` (×6 + 1 named), `F_Wreath`. All civilian headwear,
  dresses, and plain shoes.
- **There is no `BootsKnee03` female counterpart, no female combat armor of
  any kind, and no female weapon classes.** `item.xsd` has no gender or
  cross-reference attribute anywhere in its schema (checked every
  `xs:attribute name=` line in both the `Armor` and item-header complex
  types) — Warhorse ships no lookup table pairing a male item class to a
  female equivalent, hand-authored or otherwise.

**Result: checked, no viable fix exists in the shipped data, confirmed
structurally rather than assumed.** WO-20's practical conclusion stands and is
now on firmer ground: the real player's equipped items are always combat/
civilian-male item classes, and Warhorse's female item catalogue has zero
overlap with that set (no combat armor was ever authored for female meshes).
A per-slot mapping table is not something this project failed to find — **it
does not exist to find.** Building one by hand would require inventing
plausible female equivalents for gear Warhorse never modeled on a female body
(plate, gambesons, weapons), which is a content-creation task, not a data
lookup, and out of this WO's scope. The disclosed limitation in
`docs/WO-20-faces.md` and `PROJECT-STATE.md` should stay as-is, but can now
cite "no such table exists in the shipped item schema" instead of "not
attempted."

---

## Item 3 — Aggro's own flagged follow-up: soul-row hostility (WO-22 §5 lead C)

**The limitation, precisely** (`docs/WO-22-brain-lead.md:404-412`, item 4 of
its follow-up list): does a hostile soul's own `factionName`, applied via
`SharedSoulGuid` alone, produce the same aggro the native `SetParent` faction
attach does, without a loaded donor NPC?

**This is partially answered by WO-22's own existing evidence, not new data
found this session** (the game was not running to extend it):

- `wo22H`/`wo22F`/`wo22G` (`docs/WO-22-brain-lead.md:185-195`): a ghost spawned
  with bandit soul `29f8bb4d-…`'s `SharedSoulGuid` **plus**
  `SchedulerProxyName` was confronted by a real guard within seconds, fled
  ~150 m under attack, and died — with "no native `SetParent` attach, no DLL
  injection, and no dependence on a donor NPC being loaded in the save." This
  already demonstrates the core mechanism works: **a hostile `factionName` on
  the soul row alone is sufficient to make real NPCs treat a ghost as an
  enemy**, sourced from table data, not save data.
- **What is specifically untested**: the shipped-preferred configuration is
  `SharedSoulGuid` **without** `SchedulerProxyName` (WO-22's own decision,
  "ship `SharedSoulGuid`, omit the proxy" — `docs/WO-22-brain-lead.md:404-406`).
  The soul-only recovery test (`wo22U`) used a **commoner** soul, not a
  hostile one — WO-22 never combined "hostile `factionName`" with "no
  scheduler proxy." Whether a stationary, non-patrolling, hostile-faction
  ghost still draws real aggro (rather than needing the proxy's activity
  search to register the confrontation) is the one genuinely open cell in
  this matrix.

**Result: promising lead, partially validated by existing evidence, the exact
shippable combination untested.** Flagged clearly for a dedicated live test:
spawn a ghost with a bandit/hostile soul's `SharedSoulGuid`, no
`SchedulerProxyName`, verify position stays byte-stable (as `wo22U`/`wo22D`/
`wo22S` did for non-hostile souls), and confirm a real guard or bandit-faction
NPC still initiates a fight against it. If yes, this replaces the fragile
native `SetParent`-attach mechanism (donor-soul-must-be-loaded fragility) with
a lever that needs zero native code and zero DLL injection.

---

## Item 4 — Combat: attacker attribution / `HasCombatHistoryWithSoul`

**This item's premise in the session prompt is stale — the escalation it asks
for was already done, before WO-15, not "never attempted."**

`native/KCDMP/rttr_abi.cpp:1844-2122` (`probe_attribution()`) already calls
`HasCombatHistoryWithSoul` **in-process**, via `invoke2` on a resolved RTTR
method handle, not over HTTP. Commit `00360a2` ("Settle attribution:
TakeDamage's Attacker does not create combat history", 2026-07-27) predates
even WO-15 (2026-08-02). The test used a **real, hand-placed NPC**
(`ttkc_man_32`) as the target and the real player's own soul as `attacker` —
not a ghost, so WO-22's soul-backing change cannot affect this result either
way:

```
ATTR: TakeDamage(0, 3, attacker=player) on soul <ptr>
ATTR: HasCombatHistoryWithSoul(player, 30s) = false   <-- attribution did NOT register from a bare TakeDamage
```

**Shape-mismatch check, done anyway, for completeness:** the Skald schema
(`d_definitions.xml:8749-8760`) documents `HasCombatHistoryWithSoul` as:

```
MemberFunction, DeclaringType="wh::rpgmodule::I_CombatSoul"
  Target   [I_CombatSoul*]
  Soul     [I_Soul*]
  MaxTime  [float, default 30]
  -> bool
```

The native call's arguments (`attacker` as `I_Soul*`, `max_time=30.0f` against
a `CombatSoul` instance) match this exactly — two positional args plus the
default `MaxTime`, same order. **No mismatch.** The negative result is a real,
confirmed answer, not a transport artifact.

**Checked for a documented alternative/setter, found none.** The only other
schema hit for "combat history" is `CombatHistoryTrigger`
(`d_definitions.xml:4223-4231`), a quest-side polling trigger
(`Soul1, Soul2, MaxTime -> OnCombatHistoryBegins`) — a *reader*, structurally
identical in shape to `HasCombatHistoryWithSoul` itself, not a setter. There
is no documented function anywhere in the schema that writes combat-history
state. This is consistent with `NATIVE-PLUGIN-findings.md`'s own conclusion
that attribution requires the AI's perception/stimulus system (already found
inert: `AI.CreateStimulusEvent`, `AI.SetFactionOf`), not a flag `TakeDamage`
or any sibling call sets directly.

**Result: closed, confirmed negative, correctly escalated already.** No
native offset work remains to try here — the in-process call this item asked
for exists, ran, and answered the question. `PROJECT-STATE.md`'s existing
wording ("creates no combat history") is accurate; it doesn't need a
correction, but its history is worth recording: this was settled by native
code that predates WO-15's own (unaware) re-statement of it as blocked.

---

## Item 5 — Dice: the native minigame UI question

**This is the one item where the "five-minute check" turned up something
real.** WO-6's closure (`docs/WO-6-native-dice-findings.md`, cited in
`PROJECT-STATE.md:349-353`) is specifically about **RTTR reflection**: `C_Dice`
is not RTTR-registered, so the live minigame's state cannot be read or written
through the `localhost:1403` reflection API. That is a narrower claim than
"the native dice minigame cannot be controlled from Lua" — and the two get
conflated in this project's own framing.

**Found in `script_bind_2025_01_14/`, a complete, separate Lua scriptbind
surface this project has never checked:** `C_ScriptBind_Dice`, file
`ScriptBindDice.h`, exposed as the global Lua table `Dice` — the same
mechanism as `Human`, `Actor`, `System`, `UIAction` (all of which this project
already uses successfully, per WO-6's own visual-capability findings). Full
method list (`!!MEMBERTYPE_Methods_C_ScriptBind_Dice.html`), with documented
C++ signatures from the individual method pages:

| Lua call | signature |
|---|---|
| `Dice.GetDice()` | returns `C_Dice&` |
| `Dice.RollDie(dieNumber)` | `RollDie(fh, ScriptHandle userId, ScriptHandle dieEntityId, int dieNumber)` — "Rolls a single die," `dieNumber` 0–5 |
| `Dice.HoldDie(...)` | `HoldDie(fh, ScriptHandle userId, ScriptHandle dieEntityId, int dieNumber, int hold)` |
| `Dice.ToggleHoldDie(...)` | `ToggleHoldDie(fh, ScriptHandle userId, ScriptHandle dieEntityId, int dieNumber)` |
| `Dice.OverrideNextThrow(player, tbl)` | `OverrideNextThrow(fh, int player, SmartScriptTable tbl)` |
| `Dice.SetScore(p1, p2)` | `SetScore(fh, int player1Total, int player2Total)` |
| `Dice.SetAdvantage(player, advantage)` | `SetAdvantage(fh, int player, float advantage)` |
| `Dice.SetAIDifficulty(difficulty)` | `SetAIDifficulty(fh, float difficulty)` |
| `Dice.SetAIRiskTaking(riskTaking)` | `SetAIRiskTaking(fh, float riskTaking)` |

This is a Lua-scriptbind surface, not an RTTR-reflected one — `C_Dice` being
absent from RTTR (WO-6's finding) says nothing about whether the `Dice`
global table itself is registered in this build's Lua state. Every prior WO
that found a scriptbind class either present or absent did so by checking
`type(ClassName)` / `type(ClassName.Method)` live (exactly the check WO-22
ran for `XGenAIModule.SpawnEntity`/`AddLink`/`FindLinks`, and WO-6 ran for
`UIAction.*`). **That check has never been run for `Dice`.**

If `Dice` is live in this build, `SetScore` and `OverrideNextThrow` in
particular would let the mod push a real score and a real predetermined
throw directly into the native minigame instead of drawing a parallel Lua
overlay (the `hud.ShowTutorial`-based board WO-6 built) — a materially
different, likely much better, architecture for real two-player dice.

**Result: promising lead, well-documented, completely untested.** Flagged
clearly for a dedicated follow-up with the game running: check
`type(Dice)` and `type(Dice.SetScore)`/`type(Dice.OverrideNextThrow)` first
(same discipline as every prior "registered but is it live" check in this
project — WO-22 found `TryEndCombat` documented but absent from this build,
so existence must be checked per call, not assumed from the docs). Do this
**before** any further investment in the current overlay-based dice UI.

---

## Item 6 — Sweep: voice chat, launcher, world-persistence/menu-freeze, sessions

Quick scan only, as scoped ("don't force a finding").

- **Voice chat**: not a shipped or attempted feature — `voice` appears only in
  passing brief/handoff mentions, no dedicated WO or open limitation exists
  for it in `PROJECT-STATE.md`. Nothing to check against `kcd2-mod-docs`; not
  investigated further.
- **Launcher**: `PROJECT-STATE.md §7`'s open item is pure end-to-end
  *verification* (has the wiring been run against a real game launch), not a
  capability question — out of scope for a docs-repo mismatch check.
- **Menu-input lock / Lua timer liveness** (WO-12/WO-13: `Script.SetTimer`
  halts during menus): checked the scriptbind docs for a differently-scoped
  timer that might survive a menu pause. `CScriptBindEntity::SetTimer`
  (`CScriptBindEntity__SetTimer@IFunctionHandler__.html`) is a distinct,
  entity-bound timer from the global `Script.SetTimer` this project uses.
  **Not confirmed to behave differently under a menu pause** — this is a
  shallow, unverified possibility surfaced by a name search, not a documented
  fix, and it needs a live check to mean anything. Flagged only as a cheap
  thing to try, not a lead to trust.
- **Session framework (WO-2)**: no specific lever named in the brief for this
  item, and none turned up in a name-search of the schema/scriptbind docs for
  session-related primitives beyond what this project already uses. Not
  investigated further, per the WO's own "don't force it" instruction.

---

## What this session does not resolve

Every "promising lead" above (items 1's `AI.AddPersonallyHostile` re-test,
item 3's soul-only-hostile combination, item 5's `Dice` global) needs the game
running to move past "documented and untested." None were tested live this
session — the human chose the desk-only path when asked, given the game
wasn't running. No shipped file was changed. No `VERSION`/release action
taken.

## Files touched

- `docs/WO-23-findings.md` (this file)
- `docs/WO-23-progress.md`
