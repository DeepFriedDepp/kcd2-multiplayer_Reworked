# WO-47 — real swings for every weapon, not just longsword. Live-verified.

Worked 2026-08-24 (Fable 5), live, human at the machine. Extends WO-45/46's
native ghost-swing mechanism from one hardcoded longsword row to **every
melee weapon class the game ships attack data for**, driven by the game's own
tables — plus a ranged-combat probe that scopes the future ranged WO with
recorded facts.

---

## 1. Phase 1 — the two "class id" spaces ARE linked, exactly

The question this WO existed to answer: does the appearance sync's
`EquippedWeaponsByClassId` speak the same language as the combat tables'
`r_weapon_class_id`? **Yes, with one shipped indirection.** The chain, every
link of it data in `Data\Tables.pak`:

```
EquippedWeaponsByClassId          ItemClass GUID          (what WO-9/10 sync)
  -> Libs/Tables/item/item*.xml   MeleeWeapon Class="N"   (GUID -> int; ItemAlias
                                                           rows redirect via SourceItemId)
  -> Libs/Tables/item/weapon_class.xml                    N's meaning (id space)
  -> combat_action_attack.xml     r_weapon_class_id       SAME id space
```

The id space (`weapon_class.xml`): 0 dagger, 1 sword, 2 sabre, 3 axe,
4 longsword, 5 mace, 6 flail, 7 halberd, 8 shield, 9 bow, 10/14/15 crossbows,
11 torch, 12 unarmed, 13 rifle, 16 hunting_sword, 17 shield_broken.

**Live cross-check (Gate 1), 5/5 exact MATCH.** Equipped each weapon on the
real player via REST, read `EquippedWeaponsByClassId` back — and its `Value`
element carries `Type="N"`, **the game's own live statement of the weapon
class**, corroborating the item.xml mapping without any table lookup:

| equipped item | ItemClass GUID reported | live `Type` | item.xml `Class` |
|---|---|---|---|
| sermiry_longSwordMenhart | `204c1852-…e301` | **4** | 4 (longsword) |
| maceClub | `cff7ae16-…70f94` | **5** | 5 (mace) |
| axeWork01 | `1fc42528-…e41c8` | **3** | 3 (axe) |
| shortswordCleaver | `652db434-…ba1e2` | **1** | 1 (sword) |
| huntingSwordBasic | `c164f346-…74cd5e` | **16** | 16 (hunting_sword) |

Corroborating anchors: the WO-45/46 proven longsword row carries
`r_weapon_class_id="4"` and its spec verbatim; WO-42 §9.2's sample row had
`r_weapon_class_id="7"` with `l_halberd+r_halberd` tags — 7 = halberd. The
dictionary Key equals the ItemClass GUID (same value both places).

**Trap for future readers:** ammo pollutes the live map — `arrow_normal`
appears in `EquippedWeaponsByClassId` with `Type="1"` (sword's id). Never
resolve weapon class from the live `Type` field alone; the catalog resolves
through item.xml `MeleeWeapon` rows, where ammo cannot appear.

## 2. The table structure that shapes the design

`combat_action_attack.xml` FreeAttack rows (the one fragment proven to render
standalone on a ghost, WO-45/46), on-foot human rows only:

- **Dedicated rows** exist for exactly three classes: longsword (4),
  halberd (7), unarmed (12) — 2 rows each on foot (slash/stab; punch/kick),
  own `l_*`/`r_*` tags.
- **Every one-handed weapon rides `r_weapon_class_id="-1"` rows** tagged by
  weapon GROUP: `r_shortSwords`, `r_swords`, `r_bluntWeapon` — with off-hand
  variants (`l_shield`, `l_torch`, plain). The group→class mapping is itself
  shipped: `combat_weapon_group.xml` (group → `mn_tag`) +
  `combat_weapon_group_to_class.xml` (group → class ids). Sword/sabre/hunting
  sword → shortSwords (swords with a shield); axe/mace/flail → blunt.
  This is the game's own design — a mace and an axe share attack rows,
  distinguished visually by the item in hand.
- **No FreeAttack rows exist** for dagger (0, matching its lack of a combat
  stance), or any missile class (9/10/13/14/15) — there is no such thing as a
  melee-swing fragment for a bow in the shipped data.

## 3. What shipped

No wire change, no DLL change, no protocol bump. The DLL's `ghost_swing`
already took an arbitrary fragment spec; only the agent (and one Lua
function) changed.

| layer | change |
|---|---|
| agent | `WeaponSwingCatalog` — parses the installed game's own `Tables.pak` once at startup (found via the same Steam-library walk as kcd.log): item GUID→class (aliases followed, 675 melee items this build), class→real FreeAttack rows (dedicated first, group rows otherwise), off-hand aware (shield/torch `l_` tag selection), fail-closed to null. `GameBridge.ResolveSwingSpec` picks the spec per swing from the ghost's synced appearance set (`_ghostAppearance`, preset-seeded so a pre-appearance ghost = longsword as before); **per-ghost swing index rotates through the rows (slash/stab)** so consecutive swings differ. WO-46's hardcoded spec is now the fallback (catalog missing / no melee item / unknown class). |
| agent | `--dump-swing-catalog` diagnostic mode (prints every class's resolved rows + resolves GUIDs given as args). |
| agent | draw-event routing: a ghost whose synced main-hand weapon is **Oversized** (halberd/polearm) gets `KCD2MP_GhostDrawItem` instead of the plain draw (see §4). |
| Lua | `KCD2MP_GhostDrawItem(id, classGuid)` — `inventory:FindItem(guid)` + `human:DrawFromInventory(item, 0, true)`, with fallback to the old draw when the item is not in inventory yet. |
| tools | `Test-SwingCatalog.ps1` (offline suite vs the real pak), `Test-WeaponClassMapping.ps1` (Phase 1 live), `Test-WeaponSwingE2E.ps1` (appearance-carrying synthetic peer). |

## 4. The polearm discovery — equip ≠ render, and the one call that works

Live-observed sequence, each step human-watched:

1. REST `EquipItem` of a polearm on a ghost **reports success** —
   `EquippedWeaponsByClassId` returns it with `Type=7`, the WO-10 verify loop
   passes — **but no model ever attaches.** Read-but-unrendered, precisely
   the WO-10 evidence-tier gap made flesh.
2. `human:DrawWeapon()` ignores the Oversized slot entirely: on a ghost with
   an equipped poleaxe (via shipped weapon preset `polearm_5_01`) it drew the
   preset's **sidearm sword** instead.
3. Bare class-7 swings on such a ghost render as real polearm attack
   animations **with empty hands** (human-observed, screenshot in session).
4. **`human:DrawFromInventory(itemHandle, 0, true)`** — scriptbind-doc-mined,
   `itemHandle` from `inventory:FindItem("<classGuid>")` — is the one call
   that puts the polearm in a ghost's hands. Human-confirmed.
5. **Ordering trap (live-observed twice):** `DrawFromInventory` issued AFTER
   the ghost's combat draw event suppressed native swing rendering entirely
   (swings queued `status=1`, rendered nothing). Issued INSTEAD of /
   BEFORE the draw, swings render fully. The shipped routing therefore
   replaces the draw call for Oversized ghosts rather than adding to it.

## 5. Live verification (Gate 2) — four weapon families, human-watched

Full production stack (relay 7778, agent with catalog, game with new pak).
`Test-WeaponSwingE2E.ps1` per weapon: ghost spawns beside the player, its
appearance swaps to the test weapon over the real wire (0x1A), then draw +
three swings + sheathe as real combat events (0x2C). Every run: agent logged
`swing as <class>` with the resolved spec, DLL logged three
`SWING … status=1 ref(controller)=1`, human watched the render.

| weapon (class) | rows used | human verdict |
|---|---|---|
| maceClub (5) | blunt-group, slash→stab→slash | **"I saw all 3 swings and it worked with the mace"** |
| axeWork01 (3) | blunt-group, slash→stab→slash | **"All swings worked with the axe"** |
| sermiry_longSwordMenhart (4) — regression | dedicated rows; slash row is byte-identical to WO-46's constant | **"All swings worked"** |
| polearmBardiche (7) | dedicated halberd rows; draw routed through `DrawFromInventory` — **pure production path, no manual help** | **"Everything worked"** — bardiche visibly in hand, three real polearm swings |

Row rotation observed in every run (slash/stab alternation) — "every swing
looks identical" is fixed in the same pass.

Suites green throughout: Farkle 59/59, Test-SwingCatalog PASS.

## 6. Ranged probe — recorded facts for the future ranged WO

Human performed full draw→aim→shoot→sheathe cycles per family, with the
mod's action logger capturing raw `OnAction` names:

- **Drawn-state sync already works for all three families**: `combat draw` /
  `combat sheathe` events fired for bow, crossbow, and gun every time
  (`Human.IsWeaponDrawn` covers them).
- **Shot/aim inputs all reach the Lua OnAction hook, unmapped today**:
  bow `bow_primary` / `bow_primary_release`; crossbow `crossbow_prepare` /
  `crossbow_execute` / `crossbow_abort`; gun `gun_prepare` / `gun_execute` /
  `gun_abort`. Nothing goes to the wire for any of them.
- **Bow can leak FAKE melee events**: the first bow cycle emitted
  3× `combat swing` + 2× `combat block` (input-context noise — stray
  melee-named actions during handling); a later clean cycle emitted none. So
  a bow-wielding peer can put swing events on the wire today; the receiving
  ghost resolves no melee item → longsword fallback → no-op with a bow in
  hand. Wrong but silent.
- Scope statement: aim stances, cocking/loading animations, shots, and
  projectiles are **not synced and not attempted here** — that WO needs new
  wire events (prepare/execute per family) and a render route; the hook
  surface above is where it starts.

## 7. Where solid ground ends

- **Observed-live:** everything in §1 (5/5 MATCH), §4 (all five steps),
  §5 (all four weapons + rotation), §6 (all logged actions/events).
- **Known limits, stated:** sword/sabre/hunting-sword share one visual row
  set (shortSwords group), axe/mace/flail another (blunt) — the game's own
  data offers nothing finer for one-handers. Dagger and missile classes have
  no swing rows (correctly none). Sheathe on an Oversized ghost is untested
  (`HolsterWeapon` on a polearm — unknown; polearms have no holster slot).
  A shield/torch off-hand's row selection is implemented from the tables but
  was not separately watched live. The `oneShotUntil` hold and block/draw
  cue paths are unchanged from WO-46.
- **Trap recorded (deploy):** `KcdMpServer.deps.json` requires
  System.Text.Json **10.0.0** (Serilog 10.x chain) while the client publish
  carries the framework 8.0 copy. A flat merge must copy **client first,
  server last** so Json 10 wins (Publish-Release.ps1's order; both apps load
  10.x fine). This session's first deploy merged server-first → the relay
  died at startup with the exact WO-46 signature.
- **Trap recorded (tooling):** PowerShell XML: `.Value` on a `Pair` element
  is the XmlNode property (null), not the `<Value>` child — use
  `SelectSingleNode`. And `-like` treats `[plain]` as a character class —
  use `.Contains` for literal needles.

## 8. Handoff

- Ranged visibility WO: start from §6's action vocabulary; drawn-state is
  already synced, so the delta is prepare/execute wire events + a render
  route (the polearm lesson says: check what actually attaches/renders on a
  ghost before trusting any equip/pose call).
- Oversized sheathe behavior (§7) is a 5-minute live check next session.
- Swing DIRECTION/zone mirroring (attacker's real sZ/aZ) remains open —
  the tables carry zone-tagged rows if the emitter ever reports zones.
