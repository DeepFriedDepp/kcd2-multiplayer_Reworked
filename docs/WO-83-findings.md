# WO-83 — authority-class souls in the ghost roster

Build under investigation: **0.20.6**, the same live two-player session
(2026-09-11) WO-84 read. Sources: the host's `kcd.log` (147,055 lines), the
joiner's `kcd.log` (150,434 lines as extracted here), and the shipped
`Data/Tables.pak` of the installed game (identical bytes in both the retail
and the Modding Tools install: 7,211,991 bytes, 2026-07-27).

Evidence discipline: **observed** (read in a log or a running build),
**code-verified** (read in source or in the game's own data tables),
**inferred**, **not done**. Nothing is rounded up.

---

## 0. Verdict

The field report is real and its Guard hypothesis is **confirmed against the
game's own data** — but Guard is one instance of a wider class. Seven of the
nineteen roster souls belong to social classes whose crime role is
`soldier` (id 2, the game's own "authority figure" role). Those souls
enforce the `drawnWeapon` crime on a nearby player. `ttac_man_9` is one of
them; so was the deterministic fallback soul `ttkc_man_3`. All seven are
replaced in place by commoners already in the list, so the twelve untouched
slots keep their faces exactly.

| | |
|---|---|
| Souls with crime role 2 in the 0.20.6 roster | **7 / 19** (+ the fallback) |
| Guard (101) | `ttac_man_9`, `ttkc_man_3`, `tzel_man_7` |
| GuardLeader (107) | none |
| soldier_crimeAuthority (108) | `tneb_man_11`, `tneb_man_18`, `ttro_man_30` |
| huntsman_crimeAuthority (110) | `tvid_man_7` |
| Roster slots changed / unchanged | 7 / 12 |
| Distinct faces before / after | 19 / 12 |

---

## 1. Phase 0 — the claim, checked against the tables

### 1.1 `ttac_man_9`'s own row (code-verified)

`Libs/Tables/rpg/soul__ttac.xml`, the only row named `ttac_man_9`:

```
brain_id="4b914d1c-724a-a92d-3e6b-d183d35b8b98"          (brain.xml: npc_basic)
factionName="trosecko_settlements_tachov_soldiers_militia"
skald_character_name="char_GENERIC_MAN_GUARD_18"
social_class_id="101"
soul_archetype_id="0"                                     (soul_archetype.xml: NPC, male)
soul_id="69dfede7-a999-43dd-9dfa-5bf0c5aefe01"            (= the roster GUID)
soul_vip_class_id="0"
voice_group_name="Guards"
```

`social_class.xml` row 101: `social_class_name="guard"`,
`soul_crime_role_id="2"`. `soul_crime_role.xml` row 2: `soldier`, with the
authors' own comment *"Only socialClasses that are authority figures are
supposed to have this; affects wanted icon."*

**The Guard hypothesis is confirmed.** The brain is `npc_basic`, the same
brain every commoner in the roster uses (checked for nine roster souls) — the
soul's behaviour differs by class, not by brain.

### 1.2 The `extraCombatMod` warnings are not evidence (observed)

The host log carries 120 lines of
`[Warning] STORM: Rule name 'rpg_socialClass_<class>_extraCombatMod' has no
operations` at lines 1,551–1,670 — one per social class, alphabetical
(`apothecary`, `bailiff`, `baker`, `bandit`, `banditLeader`, …). They are the
STORM rule table loading at boot and name every class in the game, so they say
nothing about which soul any ghost used. `rpg_param.xml` in `Tables.pak` has
zero `extraCombatMod` rows; the rules live on the STORM side. Not cited as
proof anywhere in this document.

### 1.3 The mechanism (code-verified + observed)

`Libs/Tables/rpg/crime.xml`:

```
<crime expiration="1" fine="250" importance="20" isCrime="true"
       isSpreadable="true" label="drawnWeapon" metaroleLabel="VYTAZENA_ZBRAN"
       ui_name="ui_crime_drawnWeapon" />
```

Its `metaroleLabel` is the Czech "drawn weapon", and the game's crime-reaction
bark family for it is `crime_reaction_barks.vytazena_zbran.*`, whose guard
lines are prefixed `straz_` ("guard").

**Joiner's machine** — the host's ghost `kcd2mp_0`, spawn-verified five times
as `requested class=NPC soul=ttac_man_9 guid=69dfede7-…` (joiner lines
14,087 / 28,695 / 47,153 / 58,957 / 116,860). Barks *spoken by that ghost*
(`Params: souls = 'Ex: kcd2mp_0`), whole log:

| bark | count |
|---|---|
| `vytazena_zbran.straz_vidi_hrace_s_vytazenou_zbrani__melee` — guard sees player with drawn melee weapon | 8 |
| `vytazena_zbran.straz_vidi_hrace_s_vytazenou_zbrani__ranged_1_1` — same, ranged | 5 |
| `vytazena_zbran.hrac_zandal_vytazenou_zbran_a_straz_na_to_reaguje_1` — guard reacts to player sheathing | 2 |
| `assault.assault__hit_npc_reakce__melee__straz` — the *guard* variant of the hit reaction | 1 |
| `straze_obecne_reakce.*` — general guard reactions | 2 |
| `combat.skirmish_barks.*__soldier` (idle in combat, weapon swap, targeted, good hit) | 9 |
| `combat.pronasledovani.*` — pursuit | 2 |

First incident: joiner line 17,213 `[KCD2-MP-EVT] v1 213 combat block` (the
joiner's own player in combat stance), line 17,304 the ghost's first
`straz_vidi_hrace_s_vytazenou_zbrani__melee`, line 18,093 the ghost's first
`idle_barky_v_combatu__soldier`. That is the reported sequence — the other
player draws, the ghost warns as a guard, then fights — in the ghost's own
voice lines.

**Host's machine** — the joiner's ghost `kcd2mp_1`, spawn-verified five times
as `soul=ttro_man_59`. It speaks **zero** `vytazena_zbran` barks. Its ten crime
barks are all `assault__hit_npc_reakce__melee__muz`, the generic (non-guard)
hit reaction. The `vytazena_zbran` barks in the host log all come from real
Troskovice NPCs: `ttkc_man_2`, `ttkc_man_20`, `ttkc_bailiffSon`.

### 1.4 Class, not faction, is the lever (code-verified)

| soul | factionName | class | crime role | reacts to a drawn weapon |
|---|---|---|---|---|
| `ttac_man_9` (ghost) | `tachov_soldiers_militia` | 101 guard | 2 | yes, 13× |
| `ttro_man_59` (ghost) | `trosky_soldiers_guards` | 33 soldier | **1** | **no**, 0× |
| `ttkc_bailiffSon` (real NPC) | `troskovice_commonFolk_peasants_parcel01` | 101 guard | 2 | yes |

A soul with a *guards* faction and a civilian crime role does not react; a
soul with a *commonFolk* faction and a guard class does. This is why the audit
below keys on `soul_crime_role_id`, not on the faction string.

---

## 2. Phase 1 — the roster audit (code-verified)

Every 0.20.6 roster row resolved by `soul_name` in `soul__*.xml`, then
`social_class_id` → `social_class.xml` → `soul_crime_role_id`. All 19 GUIDs in
the Lua table equal the tables' `soul_id` (19/19).

| slot | soul | class | crime role | faction | voice group |
|---|---|---|---|---|---|
| 1 | `tneb_man_11` | 108 soldier_crimeAuthority | **2** | tvrzNebakov_soldiers | Guards |
| 2 | `tneb_man_18` | 108 soldier_crimeAuthority | **2** | tvrzNebakov_soldiers | Guards |
| 3 | `tpod_man_1` | 53 lumberjack | 1 | woodcutters_campPodseminsko | — |
| 4 | `tpod_man_5` | 53 lumberjack | 1 | woodcutters_campPodseminsko | — |
| 5 | `tsem_man_21` | 83 varlet | 1 | semin_commonFolk | — |
| 6 | `tsem_man_22` | 82 farmer | 1 | semin_commonFolk | — |
| 7 | `tsla_man_2` | 83 varlet | 1 | slatejov_commonFolk | — |
| 8 | `ttac_man_8` | 83 varlet | 1 | tachov_commonFolk | — |
| 9 | `ttac_man_9` | 101 guard | **2** | tachov_soldiers_militia | Guards |
| 10 | `ttkc_man_26` | 83 varlet | 1 | troskovice_commonFolk | — |
| 11 | `ttkc_man_3` | 101 guard | **2** | troskovice_soldiers_guards | Guards |
| 12 | `ttro_man_30` | 108 soldier_crimeAuthority | **2** | trosky_soldiers_militia | Guards |
| 13 | `ttro_man_59` | 33 soldier | 1 | trosky_soldiers_guards | — |
| 14 | `tvez_man_20` | 87 gypsy | 1 | romaniCamp_commonFolk | — |
| 15 | `tvez_man_21` | 87 gypsy | 1 | romaniCamp_commonFolk | — |
| 16 | `tvid_man_3` | 52 collier | 1 | charcoalburners_campVidlak | — |
| 17 | `tvid_man_7` | 110 huntsman_crimeAuthority | **2** | gamekeepers_vidlak | Guards |
| 18 | `tzel_man_10` | 83 varlet | 1 | zelejov_commonFolk | — |
| 19 | `tzel_man_7` | 101 guard | **2** | zelejov_soldiers_militia | Guards |
| fallback | `ttkc_man_3` | 101 guard | **2** | troskovice_soldiers_guards | Guards |

GuardLeader (107) does not occur. Every crime-role-2 soul also carries
`voice_group_name="Guards"`; every crime-role-1 soul carries none.

WO-34 §1.5 had recorded *"the roster contains four `_soldiers_guards` /
`_soldiers_militia` souls, so some players are walking around as authority
figures in the crime system. Consequence unmeasured; flagged, not claimed."*
The consequence is now measured (§1.3), and the count by crime role is seven,
not four — faction-string matching undercounts it (§1.4).

`ttro_man_59` (slot 13) is left in. Its class is `soldier` with crime role 1,
it carries no voice group, and it is the one soul in this data set observed
*not* reacting.

---

## 3. Phase 2 — what changed, and why in place

`kdcmp/Data/Scripts/Startup/kdcmp.lua` only.

### 3.1 Why not delete the seven rows

`KCD2MP_PickFaceForPlayer` is `idx = floor(h/2) % #list + 1`. Deleting rows
shrinks `#list` from 19 to 12 and re-rolls the face of **every** player — the
price WO-34 knowingly paid. WO-69's "everyone keeps their face" property held
only because the male list itself was untouched (`#list` was already 19).
The brief asked for both "remove" and "preserve everyone else's mapping"; with
this picker the second is only reachable by keeping 19 slots.

### 3.2 The in-place replacements

| slot | was | now | now's class |
|---|---|---|---|
| 1 | `tneb_man_11` | `tpod_man_1` | lumberjack, crime role 1 |
| 2 | `tneb_man_18` | `tsem_man_21` | varlet |
| 9 | `ttac_man_9` | `ttkc_man_26` | varlet |
| 11 | `ttkc_man_3` | `tzel_man_10` | varlet |
| 12 | `ttro_man_30` | `tvid_man_3` | collier |
| 17 | `tvid_man_7` | `tvez_man_20` | gypsy |
| 19 | `tzel_man_7` | `tsla_man_2` | varlet |
| fallback | `ttkc_man_3` | `ttkc_man_26` | varlet |

Every replacement is a soul **already in the list**. Deliberate: WO-69 read all
19 roster `SharedSoulGuid`s back live over REST
(`/api/rpg/SoulList/SoulsByName/<name>/SharedSoulGuid`, 19/19), and WO-33
established that a soul the engine cannot bind produces a silent default body
with no error. A fresh soul would be unverified against that failure, and the
verify-after-spawn net cannot catch it (§4.3). The fallback moves to
`ttkc_man_26`, WO-34's live control ("Hired hand", `soul_ui_name_varlet`).

Cost: 19 distinct faces become 12. Candidate commoners for widening the list
again once a live REST read is available (male, crime role 1, no voice group,
generic `char_GENERIC_*` voice actor, `soul_vip_class_id=0`, non-enemy faction,
not already used): `ttac_man_5`, `ttac_man_3`, `ttac_man_7`, `ttkc_man_14`,
`ttkc_man_24`, `ttkc_man_15`, `ttro_man_3`, `ttro_man_9`, `ttro_man_15`,
`tzel_man_1`, `tzel_man_2`, `tzel_man_5`, `tvid_man_2`, `tvid_man_4`,
`tsem_man_1`, `tsem_man_3`, `tsla_man_1`, `tsla_man_3`, `tneb_man_1`,
`tneb_man_28`. GUIDs are in `soul__*.xml`; none is checked in here because
none has been resolved live.

### 3.3 Comments updated

The roster header, the `faceFallback` comment (which said "roster slot 11" —
the slot that is now replaced) and the picker's stability note each carry a
WO-83 paragraph. The verify-after-spawn and `SetGhostName` re-pick code is
untouched — it already keys off the table.

---

## 4. Phase 3 — verification

### 4.1 The hash reproduction is the engine's (observed, WO-69)

The offline `KCD2MP_HashString` used here (`h = (h*33 + byte) % 65521`,
`h0 = 5381`) produces `Henry=7308`, `Player1=51656`, `Player91=1415` — the
same values WO-69 read back from the game's own interpreter key for key.

### 4.2 Old → new resolution (code-verified, exhaustive per slot)

| key | hash | slot | 0.20.6 soul | now | |
|---|---|---|---|---|---|
| `Host` | 48999 | 9 | `ttac_man_9` | `ttkc_man_26` | reassigned |
| `Player3` | 51658 | 9 | `ttac_man_9` | `ttkc_man_26` | reassigned |
| `Player4` | 51659 | 9 | `ttac_man_9` | `ttkc_man_26` | reassigned |
| `Player7` | 51662 | 11 | `ttkc_man_3` | `tzel_man_10` | reassigned |
| `Player8` | 51663 | 11 | `ttkc_man_3` | `tzel_man_10` | reassigned |
| `Player9` | 51664 | 12 | `ttro_man_30` | `tvid_man_3` | reassigned |
| `Player0` | 51655 | 7 | `tsla_man_2` | `tsla_man_2` | unchanged |
| `Player1` | 51656 | 8 | `ttac_man_8` | `ttac_man_8` | unchanged |
| `Player2` | 51657 | 8 | `ttac_man_8` | `ttac_man_8` | unchanged |
| `Player5` | 51660 | 10 | `ttkc_man_26` | `ttkc_man_26` | unchanged |
| `Player6` | 51661 | 10 | `ttkc_man_26` | `ttkc_man_26` | unchanged |
| `Player10` | 1150 | 6 | `tsem_man_22` | `tsem_man_22` | unchanged |
| `Player11` | 1151 | 6 | `tsem_man_22` | `tsem_man_22` | unchanged |
| `Player91` | 1415 | 5 | `tsem_man_21` | `tsem_man_21` | unchanged |
| `Henry` | 7308 | 7 | `tsla_man_2` | `tsla_man_2` | unchanged |

`Host` is the WO-69 key that resolved to `ttac_man_9`; in the field the host's
real nickname also landed on slot 9 (joiner spawn-verify lines, §1.3).
Slot-by-slot diff of the two tables: slots 1, 2, 9, 11, 12, 17, 19 changed,
the other twelve byte-identical. Every key not on those seven slots therefore
resolves as before — this is the mapping, not an argument from pattern.

### 4.3 Final-state audit (code-verified)

All 19 rows and the fallback: crime role 1, no voice group (19/19 + 1). All 19
GUIDs equal `soul_id` (19/19). Roster block braces balance (21/21); 19 rows
of the same shape as before. No Lua interpreter exists on this machine
(WO-69), so no syntax run — the edit is data rows plus `--` comments.

### 4.4 Not done

- **Live spawn on a reassigned key** — the game was not running (REST :1403
  and RemoteConsole :4600 both closed). Nothing here has been seen in a
  running build.
- **Pak rebuild** — `kdcmp.pak` is rebuilt at version time by the maintainer
  (`ef05b6e`); the Lua edit does nothing live until then. No `VERSION` change.
- The verify-after-spawn net **cannot** confirm a soul bound: it logs
  `resolved soul=nil` at spawn+0 on every healthy ghost (all ten spawn-verify
  lines in both field logs read `soul=nil`) and only acts on a *class*
  mismatch. Substitute resolvability rests on WO-69's REST read, not on the
  net.

---

## 5. What this does not fix

The seven authority souls are gone; the remaining twelve are still real souls
with real settlement factions. WO-34 §1.1/§1.2 stands unchanged: a ghost is a
full crime victim and its mistreatment costs real reputation with a real
settlement. WO-68's `crime_ignoredNPCHitVolume` fix covers the victim side;
this WO closes the *enforcer* side — no roster ghost is an authority figure
any more.
