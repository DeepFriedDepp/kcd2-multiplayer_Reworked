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

---

## 2. Phase 1 — the live read

### 2.1 Verdict: **node resolution CONFIRMED LIVE; port-value read not yet attempted**

Stated plainly, per the WO's instruction not to manufacture a partial success.

The maintainer launched the game, loaded the save, and completed the launcher's
Connect flow. Verified from this shell **(observed)**:

* `KingdomCome.exe` pid 13840, Modding Tools build, RemoteConsole on `:4600`
  equivalent `localhost:1403` open, `kdcmp.pak` mounted, `[KCD2-MP] MOD INIT`
  in `kcd.log`;
* `KCDMP.dll` injected — 189 modules, `ModuleMemorySize=364544`, loaded from
  `%LOCALAPPDATA%\KCDMP\KCDMP.dll`;
* `kcdmp-native.mirror.log` written at 19:44:58 (it had been stale since
  2026-09-13), i.e. the native side initialised;
* `ConceptModule.dll` present in the process at its own base.

The environment was therefore exactly what WO-96 §3.1's handoff asked for, and
the read still could not be attempted:

**`KCDMP.dll` contains no ConceptModule code.** Its pipe dispatch accepts seven
commands — `kPing`, `kApplyDamage`, `kApplyDeath`, `kSetFactionHostile`,
`kGhostSwing`, `kGhostIsolate`, `kResolveLuaClosure`
(`native/KCDMP/pipe_server.cpp:239-349`) — and a case-insensitive grep for
`FindNode|ConceptModule|ConceptManager|GetPort|concept` across all of
`native/KCDMP/` returns **zero hits** **(code-verified)**.

WO-96 *decompiled* the read path. It never *implemented* it. Its handoff
sentence — "a live known-answer call … needs a deployed DLL and a maintainer at
the keyboard" — reads as though the code existed and only the environment was
missing. It did not. **Correction to standing belief:** the blocker on the
native read was never deployment or maintainer availability; it is that the
function has never been written.

The known-answer check against the 2026-09-13 host save's sacks objective is
therefore still **(inconclusive)**, unchanged from WO-96 §3.3.

### 2.1a How it got there, and the honest scope of "confirmed"

The first half of this section, written before the maintainer approved a
deviation, stands as the record of why Phase 1 could not run as written: the
environment was perfect and `KCDMP.dll` had no ConceptModule code. With
approval that code was written (`native/KCDMP/concept_read.cpp`, pipe command
`0x08`, read-only), built, deployed by the maintainer, and fired.

**Confirmed (observed), 2026-09-15:**

| path | result |
|---|---|
| `Barbora.zzz_not_a_level` | NULL -- the negative control holds, so null is meaningful |
| `Barbora.trosecko` | node, vtable `ConceptModule.dll+0x41E868` |
| `Barbora.trosecko.svatba` | node, vtable `QuestModule.dll+0x93FA8` |
| `Barbora.trosecko.socky` | node, vtable `QuestModule.dll+0x93FA8` |
| `Barbora.trosecko.socky.hibernable` | node, `QuestModule.dll+0x93DE0` |
| `...v_hospode` | node, `QuestModule.dll+0x93DE0` |
| `...v_hospode.pytle_a_hadka` | node, `QuestModule.dll+0x93DE0` |
| `...v_hospode.druhy_dialog_s_ptackem` | node, `DialogModule.dll+0x23C288` |

So: **the separator is `.` live**, **the first segment is the database name and
the manager has exactly two roots, `Barbora` and `Haste`**, the descent resolves
at every depth, and the node this whole WO is aimed at -- the second Hans
dialogue -- is addressable. WO-96 s3.1's handoff is closed.

**A free type oracle.** A node's vtable names the module that implements it, so
a quest (`QuestModule+0x93FA8`), a plain module (`+0x93DE0`), a level container
(`ConceptModule+0x41E868`) and a dialogue (`DialogModule+0x23C288`) are
distinguishable *before* anything is done to them. Phase 3 uses this to check it
is holding a dialogue module and not something that merely shares a name.

**What is NOT confirmed.** Only node *resolution*. No port has been read: that
needs `C_Node::GetPort` (`0x2B62E0`) and the concrete `C_PortRef::Read`
(`0x34E500`), neither implemented yet. The WO's known-answer target was the
sacks objective reading `none`; the node exists, but its **state has not been
read**, so that specific check stays **(inconclusive)**. Nothing here separates
"objective is None" from "objective is Done" -- it proves the address resolves,
no more.

**The two roots.** `Haste` sitting beside `Barbora` as a top-level root is worth
recording: `C_ModuleBase::IsHasteNamespace` exists in the symbol table and
`wh_concept_HasteTrigger` addresses triggers by "debug name". How the `Haste`
root relates to the `quest.trigger` paths WO-94 fires is unmapped, and is a
**WO-98 candidate**, not chased here.

### 2.1b The bug that made the first attempt read nothing

Recorded because it failed silently and looked like a negative result. The first
build set the path string's `refCount` to **-1**, reasoning that a negative
refCount marks a CryString immortal, so the engine could neither free our buffer
nor retain a pointer into it. The immortality half is true. The consequence was
backwards. `C_ConceptPath`'s constructor (`0xC6D70`) reads:

```
if (refCount < 0) { str = <the shared empty string>; }   // and NO _Assign
else              { str = ours; ++refCount; }
```

There is no deep copy on the negative branch -- the engine substitutes `""` and
tokenizes that. The root scan then compared `""` against `Barbora`/`Haste`,
matched nothing, and **FindNode returned null for every path**, first hops
included. That uniformity is what exposed it: a real "no such node" would not
have swallowed `Barbora.trosecko` as well.

Fixed with `refCount = 0x40000000` -- positive, so the engine reads our bytes;
large, so `Release` (which frees only on the 1 -> 0 transition) can never get
there. The probe now also reads its own header back after the call and logs
`refCount/len/cap/text`, so a null can never again be ambiguous between "bad
string" and "no such node". The confirming run read back `refCount=0x40000000
len=54` with the text intact.

**General lesson:** a guard that makes an engine call *safe* is not the same as
one that makes it *correct*, and this one silently degraded the call to a no-op.
The read-back check is the pattern to copy for any future hand-built engine
struct.

### 2.2 What *was* settled: both of WO-96 §3.1's open items

Ghidra 12.1.3, headless, on MT `ConceptModule.dll` (6.28 MB). The DLL carries
**full MSVC mangled symbols** — 114 functions matched the WO-97 needle sweep by
name alone, so nothing here rests on pattern-matching an unnamed `FUN_`.

**Item 1 — the tokenizer's segment separator is `.` (0x2E)** **(code-verified)**.

Chain, all three steps read out of the binary:

1. `FUN_1800c6d70(path, &CryString)` is the `C_ConceptPath` constructor: it
   stores `C_ConceptPath::vftable`, initialises the deque at `+8`, and calls
   the tokenizer.
2. `FUN_1800c7110(path, str)` calls
   `wh::framework::SimpleTokenize(str, DAT_18058cdf8, out_vector)` and pushes
   each token onto the path's deque. `DAT_18058cdf8` is the separator.
3. `DAT_18058cdf8` is a global `CryStringT<char>` built at static init by
   `FUN_180002fd0`: allocates `0xe` bytes, sets refcount 1, **length 1,
   capacity 1**, terminates at index 1, and copies **one** character from
   `DAT_1803ed4e4`. That address is `.rdata` RVA `0x3ED4E4`, file offset
   `0x3EC6E4`, byte **`2E`** — `'.'`.

The `.data` word itself is null in the file image (the global is
runtime-constructed), which is why this needed the initializer and not a
memory dump. Dotted paths — `finale.talkToRacekObjective`,
`druhy_dialog_s_ptackem.nos_pytle` — are the right spelling, now for a reason
rather than by analogy with the Haste console command.

**Item 2 — the `C_ModuleBase::GetNode` descent** **(code-verified)**.

`FindNode` (`0x16530`) default-constructs a `C_ConceptPath` from the R8 string,
**pops the front segment** (`FUN_1800c6eb0`, which both returns the front and
decrements the count at `path+0x28`), and linear-scans the root module list at
`this+0x48 .. this+0x50`, comparing each module's name at `*(char**)(module+0x10)`
by inline `strcmp`. No root matches → it writes a **null smart_ptr** into the
hidden return slot and returns. So the **first segment is the database name**,
which WO-96 guessed as `Barbora` — the guess is now supported by the code, but
remains **(inconclusive)** until a call returns non-null, because nothing here
proves what the root list actually contains at runtime.

Otherwise it calls the second overload:

| Function | RVA | Shape |
|---|---|---|
| `C_ModuleBase::GetNode(C_ConceptPath&&)` | `0x241300` | **virtual**; `this` RCX, hidden `_smart_ptr<C_Node>*` RDX, `C_ConceptPath&&` R8 |
| `C_ModuleBase::GetNode(CryStringT<char> const&)` | `0x241280` | virtual; a different, visitor-shaped entry through vtable slot `+0xD0` with a `std::function` — **not** the one `FindNode` uses |

The descent at `0x241300` is a loop, not a single lookup:

```
node = (*this->vtbl[0x48])(this, &ret, path.pop_front())   // child by name
while (path.remaining /* path+0x28 */ != 0 && node != null)
    node = (*node->vtbl[0x48])(node, &ret, path.pop_front())
    release the previous smart_ptr
return ret
```

So **vtable slot `+0x48` is "resolve one child by name"**, uniform across
`C_ModuleBase` and `C_Node`, and `C_ConceptPath` is a `std::deque<CryStringT>`
with `+0x10` bucket array, `+0x18` bucket count, `+0x20` front index,
`+0x28` remaining count.

### 2.3 Amendments to WO-96 §3.1's table

* `C_ConceptManager::FindNode` — the mangled name
  `?FindNode@C_ConceptManager@conceptmodule@wh@@QEBA?AV?$_smart_ptr@VC_Node@…@@AEBV?$CryStringT@D@@@Z`
  **confirms** WO-96's register layout: one explicit `const CryStringT<char>&`
  argument, non-trivial return ⇒ `this` RCX, hidden return RDX, string R8.
* `C_Node::GetPort` (`0x2B62E0`) — confirmed verbatim: hidden return nulled
  first, R8 string, linear scan of `this+0x30..this+0x38`, port name via the
  port's **vtable slot `+0x48`**, C-string compare.
* **The `Read` trap has a named way out.** WO-96 warned that the exported
  `I_Port::Read` (`0x2B1CF0`) is the empty base virtual. The symbol sweep found
  a **concrete `C_PortRef::Read` at `0x34E500`** (`__thiscall`, one argument —
  just `this`). That, not the export, is the read to call. Recorded here
  because it belongs to the read path; its use is Phase 2/3's business.

### 2.4 Tooling added

* `native/ghidra_scripts/DumpWo97Concept.java` — needle sweep over function
  names, `__FUNCTION__`-style strings and their referrers, then decompiles
  every hit with its callers.
* `native/ghidra_scripts/DumpWo97Refs.java` — every reference to a data address
  plus the decompiled referrers; this is what recovered a runtime-constructed
  global that is null in the file image.
