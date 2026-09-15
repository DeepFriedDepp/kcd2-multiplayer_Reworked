# WO-97 — fix-table audit, live read confirmation, `C_PortRef::Trigger`

Evidence marks: **(observed)** ran and seen · **(code-verified)** read out of
the shipped binary/XML · **(synthetic)** offline harness · **(inconclusive)**.

---

## 0. Answer first

* **Phase 0 done.** 19 unaudited entries walked. **5 of 22 withdrawn** — each
  one's `On<State>` pulse chain reaches a `CutsceneHandler.EnqueueCutscene`
  **(code-verified)**. Table is now **17**. 160/160 synthetic.
* **Two of WO-96's own hazard examples are wrong.** Its named cutscene case
  (`zachranaPtacka.07_startMalesovMeetupCutscene`) starts no cutscene, and its
  named item case (`setkaniVRatbori1.06_getDocument`) *does* grant the item.
  Both corrections are §1.4.
* Phases 1–3: see §2 onward.

---

## 1. Phase 0 — per-entry hazard audit of the 22 shipped fixes

### 1.1 What "clean" missed, and the graph model used to find it

WO-96's `clean` = the trigger's `OnTrigger` drives only the objective's `State`
node. That bounds the **direct** effect. It says nothing about the transition
itself, which pulses the State's `On<State>` consumers — and those cross module
files. WO-96 said so (§4.2 point 1) but never walked the chain per entry.

Graph model, from the Modding Tools `Scripts.pak` **(code-verified)**:

* a node's XML **tag is its class**; `<Edge From="Src.Port" To="InPort"/>` lives
  on the **destination** node. Consumers of `X.OnDone` = every element in the
  file carrying `Edge From="X.OnDone"`.
* a node whose tag matches a sibling file `<file-minus-.xml>/<tag>.xml` is a
  **module instance**; a pulse into its in-port continues in that child file as
  `Edge From="<inport>"`.
* an `<Output>` node forwards to the **parent** module file as
  `Edge From="<basename>.<To>"`.

`tools/Audit-ObjectiveFixHazards.py` walks this breadth-first to depth 6 in the
fired direction only, distinguishing **pulse** (`OnDone`/`OnActive` — fires
something) from **bool** (`Done`/`Active` — enables a gate someone else fires).
The distinction is carried through so nothing is rounded up.

### 1.2 Verdict table — all 22

Withdrawn rows are **bold**. "Chain" is the fired direction only.

| # | quest | objective | dir | trigger | chain finding | verdict |
|---|---|---|---|---|---|---|
| 1 | zachrana | goToSleep_visual | active | `goToSleep_activate` | 8 edges, none hazard-class | **keep** |
| 2 | mucirna | jed…na_semin | active | `_activateRideToSeminObjective` | 10 edges: `changeweather12.Exec`, `samotny_tour.start`; no cutscene | keep (note A) |
| 3 | nebakovObrana | odraz_utok_na_branu | done | `bitva_7_branaOdrazeno` | `chat_and_barks.done` (barks only) | keep |
| 4 | **vezniNaTroskach** | **doprovod…na_konec_chodby** | **done** | **`startApolenaGameplay`** | **`OnDone → cin_m1280t_vezninatroskach__zikmund_letter.enqueue_cs → CutsceneHandler.EnqueueCutscene`; also `quest_items.AddQuestItem` at d5** | **REMOVE (cutscene)** |
| 5 | **sedmStatecnych** | **pomoz_kubenkovi_v_bitce** | **done** | **`sedmStatecnych_kubenkaZachranen`** | **`OnDone → Output.bitka_vyhrana → trialog_s_zizkou_a_kubenkou.start_trialog → CutsceneHandler.EnqueueCutscene`** | **REMOVE (cutscene)** |
| 6 | sedmStatecnych | zachran_sucheho_certa | done | `certZachranen` | `SaveGame.EnqueueSave`, post-battle barks; no cutscene | keep (note B) |
| 7 | hledaniLichtenstejna | searchForKozina | done | `05___complete_…_baths` | `AddReward codexZide` (**grants**, not lacks), `SaveGame` | keep |
| 8 | hledaniLichtenstejna | talkToKaterina | done | `03___complete_talkToKaterina` | urge-dialog disable, 2×`SaveGame` | keep |
| 9 | kralovskeStribro | jdi_do_ruthardky | done | `complete_findRuthard` | **zero** consumers on `Done`/`OnDone` | keep (note C) |
| 10 | zachranaPtacka | dostan_se…na_malesov | done | `07_startMalesovMeetupCutscene` | 11 edges, **no cutscene** — bool latch only (§1.4) | keep (note D) |
| 11 | setkaniVRatbori1 | getDocument | done | `06_getDocument` | no hazard; `Done` **places the certificate on the player** (§1.4) | keep |
| 12 | **setkaniVRatbori2** | **sezen_dzbanek_vina** | **done** | **`pickWineSkip`** | **`OnDone → Output.bezprovino_ondone → Output.spustit_cutscenu_utoku → cin_m3780k_setkaniratbordva__ratbor_attack → CutsceneHandler.EnqueueCutscene`** | **REMOVE (cutscene)** |
| 13 | pogrom | probij_se_domem | done | `03b_completeMothersPart` | 3 edges, none hazard-class | keep |
| 14 | **pogrom** | **vydrz_napor_pred_synagogou** | **done** | **`04a_cutscene_blockadeFire`** | **`OnDone → cin_m4220k_pogrom__blockade_fire.cutscena_utek_podzemim → CutsceneHandler.EnqueueCutscene`** | **REMOVE (cutscene)** |
| 15 | zikmunduvTabor | bring_deserters_report | active | `deserters_getItem` | **zero** consumers on `Active`/`OnActive` | keep (note E) |
| 16 | **prepadeniVlasskehoDvora** | **jdi_do_vlasskeho_dvora** | **done** | **`init_end2`** | **`OnDone → Output.legatova_druzina_je_vpustena_do_vd → bohuta__vlassky_dvur → fader_a_priprava_npc → CutsceneHandler.EnqueueCutscene`** | **REMOVE (cutscene)** |
| 17 | prepadeniVlasskehoDvora | prones_zaverecnou_rec | active | `courtHall_finalVerdict` | bool only: enables a dialogue option | keep |
| 18 | oblehaniSuchdole | odraz_nepratelsky_utok | done | `012_konecBitvy` | 4 edges, none hazard-class | keep |
| 19 | hladAZmar | dones_ptackovi_neco_k_jidlu | done | `hideBeforeBattleMainObjective` | **zero** consumers on `Done`/`OnDone` | keep (note C) |
| 20 | finale | dojdi_nabrousit_hanusovi_mec | active | `_sharpenSwordObjectiveActive` | `Active` feeds `or_itemAtHenry → AddQuestItem addquestitem4 (StartingLocation=player)` — **grants the sword** | keep |
| 21 | finale | dojdi_nabrousit_hanusovi_mec | done | `_returnSwordToHanus` | `Done → and13 → or_itemAtHenry → AddQuestItem`; item management stays coherent | keep |
| 22 | finale | setkej_se_s_rackem | active | `talkToRacekObjective` | bool only: 2×`ClothingPresetOverride`, dialogue switches | keep (note F) |

### 1.3 Notes attached to kept entries

* **A — `mucirna`.** `OnActive` runs `changeweather12.Exec`. Weather is synced
  (`0x2E`/`0x2F`, WO-40) but *write-only* — there is no read, so the fixer's
  weather change does not propagate. Cosmetic, one-sided. Not a cutscene.
* **B — `certZachranen`.** `SaveGame.EnqueueSave` on `OnDone`. A save *write* is
  harmless here; it is a save *load* that kills every Lua timer chain (WO-13,
  WO-78). Four entries enqueue a save; none loads one.
* **C — `IsHidden=true`.** `kralovskeStribro.complete_findRuthard` and
  `hladAZmar.hideBeforeBattleMainObjective` carry `<Constant Name="IsHidden"
  Value="true"/>`. `ConsoleHTMLHelp/CRYAUTOGEN/WHCONCEPTHASTETRIGGER` says only
  "Fires a Haste trigger using its debug name" and never mentions the flag
  **(code-verified)**. Whether `IsHidden` hides the trigger from the on-screen
  Haste list only, or also from `wh_concept_HasteTrigger` by name, is
  **(inconclusive)** — these two may be inert rather than harmful. Cheap to
  settle in a live session: fire one and read the journal.
* **D — `zachranaPtacka`.** Kept, but it sets `hrac_se_dostal_na_malesov` true
  while the player is not at Malesov; downstream that bool is one input of
  `malesov.and4`. A state lie, not an action. See §1.4.
* **E — `zikmunduvTabor`.** No `AddQuestItem` anywhere in the
  `musa_a_dezerteri` subtree **(code-verified)** — the report is a world/chest
  item, not state-managed. Firing this sets the journal line "bring the
  deserters' report" for a player who has not looted it. A premature prompt,
  not a false completion; the objective remains reachable by ordinary play.
* **F — `finale.setkej_se_s_rackem`.** `Active` drives two
  `ClothingPresetOverride` nodes. WO-59 named clothing asymmetry as a live
  bug class; this makes one machine's Henry change clothes and not the other's.
  Cosmetic, one-sided, recoverable. Kept because the alternative — no fix for
  the last quest's first objective — is worse.

### 1.4 Two corrections to WO-96 §4.2

WO-96 named one example per hazard. Both are wrong at the edge level.

1. **"`zachranaPtacka.07_startMalesovMeetupCutscene` grants `getToMalesov` Done
   and, downstream, the cutscene that Done triggers."** It does not.
   `cesta_chodbou.xml` contains **no `cin_*` node at all**; `getToMalesov` has
   **no `OnDone` consumer**; the only `Done` edge is
   `Output.hrac_se_dostal_na_malesov`, a **`Type="bool"`** port that lands on
   `malesov.and4`'s A input **(code-verified)**. The trigger's name is
   aspirational — the Malesov meetup cutscene is a later beat gated on that
   bool, not fired by it. The entry is kept.
2. **"`06_getDocument` sets Done; the `AddQuestItem` beside it is driven by the
   real pickup… A player granted the objective has the journal line, not the
   document."** The opposite. In `glejt.xml`,
   `<AddQuestItem Name="addquestitem469_1" … StartingLocation Alias="player">`
   takes `Edge From="or473.bool" To="IsActive"`, and `or473` has
   `getDocument.Done → D` **(code-verified)**. `AddQuestItem` is a *relocator*:
   the sibling `addquestitem469` holds the same GUID at `franta` while the
   phase is `Started`. Setting `Done` therefore **puts the certificate on the
   player**. This is one of the safest entries in the table, not the worst.

Neither correction was reachable from the CSV; both needed the XML.

### 1.5 Limits of this audit — stated so nobody rounds it up

* Depth 6. Deeper chains are unwalked.
* **Bool** propagation is followed and reported, but a bool going true can
  enable an `If`/`IfFunction` whose `Exec` arrives later from an unrelated
  source. No such second-order path was traced. A kept entry marked "bool only"
  means *this fix fires nothing*, not *nothing can ever follow*.
* Hazard classes are name-and-tag heuristics (`cin_*`, `CutsceneHandler`,
  `AddQuestItem`, `ClothingPresetOverride`, …). A cutscene started by a node
  named nothing like a cutscene would be missed.
* Nothing here was fired. Every row is **(code-verified)**, none **(observed)**.

### 1.6 What shipped

* `KCD2MP_OBJECTIVE_FIXES` 22 → **17**.
* `KCD2MP_OBJECTIVE_FIX_HAZARDS` — new named blocklist of the five, outside the
  generated block. `KCD2MP_QuestIsRegistryBeat` refuses a listed path **before**
  any other check and logs why, so an older peer, an older pak, or a typed
  console line cannot reach one.
* `tools/Find-ObjectiveTriggers.ps1` carries the same five in `$hazardCutscene`
  and skips them at generation, so regenerating the table cannot silently
  re-add them.
* `tools/Audit-ObjectiveFixHazards.py` — the audit itself, re-runnable. Exits
  non-zero if any shipped entry has a cutscene on a pulse path. Currently 0.
* `tools/Test-WO96Synthetic.lua` — new `(w97)` block, 18 checks. Suite
  **160/160** **(synthetic)**.
