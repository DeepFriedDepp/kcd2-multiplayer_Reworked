# WO-10 Part A — Weapon sync

Extends WO-9's per-item appearance sync to weapons. Read
`docs/WO-9-appearance-sync.md` first — this document only covers what is
different for weapons; the poll/diff/verify mechanism itself is identical
and is not re-explained here.

---

## Phase 0 — shape confirmation (live, not assumed)

The brief asked to confirm the shape before force-fitting the WO-9
mechanism onto it. Confirmed live against the real running game
(2026-07-31):

- `GET .../PlayerSoul/EquipmentManager/EquippedWeaponsByClassId?depth=1`
  returns the exact same `<DictionaryOfItem><Pair Key="guid"><Value
  ItemClass="guid" .../></Pair></DictionaryOfItem>` shape as
  `EquippedArmorsByClassId`. Same reflection root
  (`SoulList/{soul}/EquipmentManager`), same `ItemClass` GUID keying. Read
  against the real player: two weapons simultaneously equipped
  (`torch_weapon`, `alias_zachrana_huntingSword`) — confirms the map holds
  more than one slot at once, same as armor.
- **`EquipItem`/`UnequipItem`/`CreateItems` are item-class-agnostic** —
  confirmed live, not assumed from the WO-9 writeup. On a spawned test
  ghost (`kcd2mp_wo10_test`): unequipped its spawn-preset sword
  (`UnequipItem`), read-back showed the weapon map empty; created and
  equipped the real player's own hunting sword (`CreateItems` + `EquipItem`
  on a class the ghost never had), read-back showed it equipped
  immediately, no retry needed. **The same calls that equip armor equip a
  weapon** — there is no separate weapon-specific reflection surface.

**Conclusion: the shape matches cleanly, no adaptation needed.** This is
mechanism reuse, not new design.

## Design decision — extend, don't add a sibling message

The brief allowed either approach. Chose to **extend the existing
`AppearanceUp`/`AppearanceDown` (0x1A/0x1B) message** rather than add a new
one, and **did not bump `Protocol.Version`**. Reasoning:

- The wire payload is already "a list of ItemClass GUIDs." Nothing about
  it encodes armor-ness. A weapon's ItemClass GUID is structurally
  identical to an armor one on the wire.
- The receiver's diff/apply logic (`GameBridge.ApplyAppearanceAsync`,
  `VerifyAndRetryAsync`) already operates on `Guid[]` with no category
  branch anywhere in it — it was already correct for weapons with zero
  code changes, once the outbound read included them.
- A sibling message would have meant a second poll, a second diff-tracking
  set per ghost, and a second wire type for no actual behavioral gain,
  since both kinds go through the same `EquipItem`/`UnequipItem` call
  either way.

**Consequence: no protocol version bump, no `tools\*.ps1` hardcoded
`$PROTOCOL_VERSION` to update.** This sidesteps the exact trap WO-9 hit
(forgetting a test script's hardcoded version) by not needing the bump at
all. Confirmed nothing references a weapon-specific byte anywhere in
`tools\`.

### What actually changed

- `IGameTransport.ReadEquippedItemClassesAsync` /
  `ReadGhostEquippedItemClassesAsync`: doc comments updated to state they
  now cover weapons too — no signature change.
- `HttpGameTransport`: both methods now read **two** REST endpoints
  (`EquippedArmorsByClassId` and `EquippedWeaponsByClassId`) and merge the
  results into one `Guid[]`, via a shared `ReadItemClassMapAsync` helper.
  Two round trips instead of one for the outbound poll (every 3s) and for
  each verify-retry read — same order of magnitude the appearance loop
  already tolerates, not a new performance concern.
- `EquipItemOnGhostAsync`/`UnequipItemOnGhostAsync`: **unchanged.** They
  already took a bare `itemClass` GUID with no category parameter, so they
  needed no modification to work for weapons — this is the direct
  consequence of the calls being item-class-agnostic.
- `GameBridge.ApplyAppearanceAsync`/`VerifyAndRetryAsync`: **unchanged.**
  Same reason.

## Spawn-preset seeding — the WO-9 trap, checked proactively this time

WO-9's diff-seeding bug (diff starting empty, so a ghost's spawn-time
preset items were never proposed for removal) has an exact weapon
equivalent: `KCD2MP_SpawnGhost` in `kdcmp.lua` calls
`entity.actor:EquipWeaponPreset(p.weapons)` right alongside
`EquipClothingPreset`, using `KCD2MP.armorPresets.white_red.weapons =
"af2dd849-92a4-4081-9955-0afcb861fcd5"` (the `kkut_menhart` weapon preset).

**Checked before shipping, not found by screenshot after the fact** (per
the brief's explicit instruction): spawned a fresh test ghost and read its
`EquippedWeaponsByClassId` immediately — it carries
`sermiry_longSwordMenhart` (ItemClass
`204c1852-dd30-42ae-9317-bc3123a3e301`) from the moment it exists, exactly
the same shape of trap as the armor preset.

**Fixed**: added that GUID to `GameBridge.GhostSpawnPresetItems`
(now 10 entries: the original 9 armor pieces plus the one spawn weapon).
Verified live end-to-end (see below): first apply to a fresh ghost logged
`+5 -10` — 5 real items added (4 armor + 1 weapon), all 10 preset items
(9 armor + 1 weapon) proposed for removal.

## Visual-hiding edge case

The brief flagged that a sheathed/two-handed weapon or an off-hand item
could hide a change the same way plate armor hid an under-layer in WO-9.

**Not fully checked visually this session** — no human was watching the
screen during this pass (unlike WO-9's live demo, which had the user
confirming on-screen changes). What *was* checked:

- The REST read-back after each swap unambiguously shows the correct
  weapon class in `EquippedWeaponsByClassId` and the old one gone — this
  is "read-but-unrendered" tier evidence, not "observed" tier, per this
  project's own evidence discipline.
- The real player was observed to have **two weapons equipped at once**
  (a melee weapon and a torch), which means the off-hand/main-hand
  distinction is a real thing this sync will encounter in practice — a
  torch swap and a sword swap are two independent map entries, synced
  independently, exactly like two independent armor slots.

**Left as an open item, stated plainly**: whether a sheathed weapon,
a two-handed weapon's off-hand exclusivity, or a torch in the off-hand
slot ever fails to render the way the Hood-vs-Helmet exclusivity did for
armor is **not ruled out** — it needs a human watching the screen during a
live weapon swap to confirm, the same way WO-9's own preset bug was only
caught by a screenshot. Flagged for the next session with the game
actually being watched.

## Verification run this session

`tools\Test-AppearanceE2E.ps1`, extended to push 4 armor classes + 1
weapon class (`alias_zachrana_huntingSword`,
`b867dd0e-1bfe-40e9-b114-4b126a3ff1b0`, read live off the real player's own
`EquippedWeaponsByClassId`), and to verify against **both**
`EquippedArmorsByClassId` and `EquippedWeaponsByClassId` on the synthetic
peer's ghost (a weapon class will never show up in the armor map).

**Run against a real relay + real running agent + real game** (2026-07-31):

```
peer connected to relay as ghost id 2
sent Position -> agent should spawn ghost 'kcd2mp_2'
sent Appearance: 5 item class(es)
waiting 16s for the agent to apply it...

PASS - all 5 pushed item classes are equipped on the ghost
```

Agent log: `[appearance] ghost 2: +5 -10` — confirms the spawn-preset seed
fix (10 preset items proposed for removal, not the pre-fix "only ever
add" bug). No retry needed — the fast path landed on the first read,
matching WO-9's own "quiet game state" fast-path runs. No regressions:
the same agent process also correctly synced the **real local player's**
own 7-item equipped set (5 armor + 2 weapons, matching the live REST read
taken during Phase 0) to any ghost that would represent them, via the same
unmodified outbound loop.

Cleaned up: removed the synthetic peer's ghost and the Phase-0 probe
ghost after each test.

## What does not sync (unchanged from WO-9, restated for completeness)

- Hairstyle, face, beard — still out of reach, no reflected property.
- The Hood-vs-Helmet armor exclusivity — unchanged, not a weapon concern.
- **New for this WO**: whether an off-hand/sheathed weapon has an
  analogous exclusivity rule is unconfirmed (see "Visual-hiding edge
  case" above) — not found broken, just not checked with eyes on the
  screen.

## Wire protocol — unchanged

No new type byte, no version bump. `Protocol.Version` stays **5**. Free
type byte for a future feature is still **0x1C**. The Appearance layer's
doc comment in `Protocol.cs` is updated to state it now carries weapons
too, but the byte layout on the wire is byte-for-byte identical to what
WO-9 shipped.
