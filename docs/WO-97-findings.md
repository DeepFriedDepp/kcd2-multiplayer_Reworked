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

---

## 3. Phase 2 — `C_PortRef::Trigger`, mapped statically

Nothing in this section was called. Every line is **(code-verified)** from MT
`ConceptModule.dll` (sha256 `ab4032ac…`), Ghidra 12.1.3.

### 3.1 The function

```
public: virtual void __cdecl wh::conceptmodule::C_PortRef::Trigger(void) const
?Trigger@C_PortRef@conceptmodule@wh@@UEBAXXZ        RVA 0x34E610
```

| | |
|---|---|
| convention | `__thiscall`, **RCX = `this`, nothing else** |
| arguments | none |
| return | void |
| virtual | yes — **vtable slot [15], byte offset +0x78** |

No ambiguity to flag: this is the simplest possible signature. The register
layout needed no inference — the mangled name gives one `void(void) const` and
the vtable dump pins the slot.

Body, in full:

```
port = resolve(this+0x38, this)      // cached; FUN_180362700
if (!port) return                    // silent no-op
if (port->activationId16 /*+0x0C*/ == 0)
    port->id /*+0x08*/ = conceptManager->vtbl[0](mgr, port)   // register on first use
InterlockedIncrement16(&port->+0x0C)
port->vtbl[0x78](port)               // <-- THE ACTUAL FIRE
C_SharedResource::Release(port)
```

So `C_PortRef::Trigger` is a **forwarder**. It resolves a port and calls that
port's own slot-15. `C_PortRef` is itself an `I_Port` subclass — its vtable
overrides only `GetName` [9], `Trigger` [15] and `Read` [16] — i.e. a proxy.

### 3.2 The `I_Port` vtable (the map everything else hangs off)

| slot | offset | member |
|---|---|---|
| 8 | +0x40 | `GetDirection` |
| 9 | +0x48 | `GetName` |
| 10 | +0x50 | `IsEmpty` |
| 13 | +0x68 | `IsTrigger` |
| **15** | **+0x78** | **`Trigger`** |
| 16 | +0x80 | `Read` |
| 18 | +0x90 | `ConnectedPorts` |

This retires a guess: WO-96 §7 warned that the exported `I_Port::Read` is the
empty base virtual. **`I_Port::Trigger` (`0x2B1DB0`) is the same** — its whole
body is the debugger-check stub and `return`. The trap generalises; the export
is a decoy in both directions.

### 3.3 What a `C_PortRef` is, and the honest stall

Layout recovered from `C_PortRef::Trigger`, `::Read` and the resolver
`FUN_180362700`:

| offset | holds |
|---|---|
| +0x10 | a node reference (resolved by `FUN_18002f080`) |
| +0x20 | `I_PortDef*` — the port's **definition** (name, type, direction) |
| +0x28 | a refcounted owner handle |
| +0x38 | cache: `[0]` resolved flag, `[8]` the resolved `I_Port*` |

Resolution is: resolve the node from +0x10, ask the **def** for the port name
(`def->vtbl[8]`), then linear-scan the node's port list at `node+0x30..+0x38`
comparing names — the identical scan `C_Node::GetPort` performs.

**The stall, stated plainly as the WO asked.** There is **no public
`C_PortRef` constructor in the symbol table**, and building one by hand would
require fabricating an `I_PortDef` — engine-authored metadata that carries the
port's rttr type and direction. Manufacturing one is not something this project
should attempt.

**But it is not needed.** `C_PortRef::Trigger`'s entire payload is
`port->vtbl[0x78](port)`, and that `port` is obtainable directly:

```
FindNode(path)              ->  C_Node*        (Phase 1, confirmed live)
C_Node::GetPort(name)       ->  I_Port*        (0x2B62E0, same scan)
port->vtbl[15]()            ->  the fire
```

So the write path **bypasses `C_PortRef` entirely**. The WO named
`C_PortRef::Trigger` as the lever; the accurate statement is that it is the
*public face* of a lever whose working end is `I_Port` slot 15, and the working
end is the reachable one.

### 3.4 In-ports vs out-ports — they differ, and it is enforced

`PortDef::InTrigger` (`0x2B0C80`) sets `def+0x14 = 1`.
`PortDef::OutTrigger` (`0x2B0CD0`) sets `def+0x14 = 2`.

`I_Port::GetDirection` (slot 8) returns that value. `I_Port::CanTrigger`
(`0x2B1E30`, protected virtual) is:

```
if (!IsEmpty() && def != null && def->GetDirection() != 2 && FUN_180021f20(def))
    return true
return false
```

**Direction 2 (Out) is refused; direction 1 (In) is allowed.** So an
out-port — e.g. `druhy_dialog_s_ptackem.nos_pytle`, which is what the session
prompt's prose points at — is *not* the triggerable object. The triggerable
objects are the **in-ports it drives**: `pytle_a_hadka.start` and
`rekniPtackoviOPraci.SetDone`. Phase 3 targets those.

Caveat, because it cuts the other way: **`C_PortRef::Trigger` does not call
`CanTrigger`.** The direction guard is only as real as the concrete port's own
slot-15 implementation choosing to consult it.

### 3.5 Guards and preconditions — and a native WO-43 trap

Of the **17** genuine `I_Port` subclasses in `ConceptModule.dll` (filtered by
`GetDirection` occupying slot 8), only **two** have a real slot-15:

| port class | slot 15 |
|---|---|
| `C_ActiveTriggerPort` | `FUN_1800C78E0` — **the real propagation** |
| `C_DebuggerPort` | `FUN_1800CB230` |
| `C_TriggerPort` | `I_Port::Trigger` — **EMPTY** |
| `C_EdgePort`, `C_DataPort`, `I_Port` | **EMPTY** |
| `C_PortRef`, 10× `C_TypedPortRef<T>`/`C_TypedArrayPortRef<T>` | the forwarder |

**`FUN_1800C78E0` self-identifies** — it builds a trace scope from the literal
string `"C_ActiveTriggerPort::Trigger"`, so this is a name read out of the
binary, not a guess (WO-42's observation that MT builds keep `__FUNCTION__`).
What it does:

1. **Re-entrancy depth guard.** A global depth counter is compared against a
   configured maximum. Over the limit it calls
   `C_Node::TraceHint(node, 4, "Infinite loop detected at port:'%s', stopping
   execution!")` **and does not fire**. That string is an engine-side signal a
   live fire can be watched for.
2. Otherwise: registers the port if unregistered, collects its outgoing
   connections into a vector (stride `0x58`), sorts them, then for each one
   increments the depth counter and invokes the connection's handler through
   `handler->vtbl[0x10]` (a `std::function`-shaped call — `std::_Xbad_function_call`
   is the null path), decrementing afterwards.

So a trigger *propagates* by walking connections and invoking handlers. That is
the primitive the whole quest graph runs on.

`C_DebuggerPort::Trigger` inlines `CanTrigger`'s test verbatim (`!IsEmpty &&
def && direction != 2 && …`) and then builds an `S_NodeExecuteContext`. Its
existence next to the `Haste` root Phase 1 found is suggestive of the
`wh_concept_HasteTrigger` path, but that link is **(inconclusive)** and is a
WO-98 candidate, not chased.

**The trap, and it is WO-43's in native clothing.** Calling slot 15 on a
`C_TriggerPort`, `C_EdgePort` or `C_DataPort` runs the empty base and returns
cleanly, having done **nothing at all**. There is no error, no log line, no
return value. "The call succeeded" would prove exactly as much as "`pcall`
returned true" did in WO-43 — which is nothing.

**Consequence for Phase 3:** before believing any fire, the port's **vtable
pointer must be compared against `C_ActiveTriggerPort::vftable`**
(`ConceptModule.dll+0x3F3130`). A port that is not an active trigger port must
be reported as unfireable rather than fired and hoped over.

### 3.6 Phase 2 answers, against the questions asked

1. **Signature / convention** — `void __thiscall C_PortRef::Trigger(C_PortRef*)`,
   RCX only, virtual slot 15. Nothing unclear; no stop needed.
2. **What a `C_PortRef` is / how obtained** — a proxy over (node-ref, PortDef).
   **No public constructor; building one needs a fabricated `I_PortDef`, and
   that is where the `C_PortRef` route stalls.** The route around it —
   `FindNode` → `C_Node::GetPort` → slot 15 — needs no `C_PortRef`.
3. **In vs out** — direction 1 = In (triggerable), 2 = Out (refused by
   `CanTrigger`). The prompt's `nos_pytle` is an out-port; the in-ports it
   drives are the real targets.
4. **Guards** — port class (only `C_ActiveTriggerPort` propagates), a
   re-entrancy depth limit with a named log line, and a silent return on a null
   port.
5. **Anything needing disassembly beyond this session** — no. Nothing was
   guessed and nothing was left ambiguous.

---

## 4. Phase 3 — the target, the predicted effect, and the live-fire procedure

**Nothing in this section was fired.** No native write was performed this
session. Everything below is **(code-verified)** except where marked.

### 4.1 The target is two in-ports, not the out-port the prompt names

`v_hospode.xml` has exactly **two** consumers of `druhy_dialog_s_ptackem.nos_pytle`
**(code-verified)**:

```
<pytle_a_hadka Name="pytle_a_hadka">
    <Edge From="druhy_dialog_s_ptackem.nos_pytle" To="start"/>
<State Name="rekniPtackoviOPraci" TypeT="Progress">
    <Edge From="druhy_dialog_s_ptackem.nos_pytle" To="SetDone"/>
```

The prompt aims at `nos_pytle` itself. Phase 2 §3.4 rules that out: `nos_pytle`
is an **out**-port (direction 2) and `CanTrigger` refuses direction 2. The
triggerable objects are the two **in**-ports it drives. Firing both reproduces
the dialogue's effect exactly, and does so without depending on out-port
triggering at all — strictly better than the route the prompt assumed.

| # | node path (as `FindNode` needs it) | port | what it is |
|---|---|---|---|
| **T1** | `Barbora.trosecko.socky.hibernable.v_hospode.pytle_a_hadka` | `start` | the gameplay |
| **T2** | `Barbora.trosecko.socky.hibernable.v_hospode.rekniPtackoviOPraci` | `SetDone` | the journal |

T1's node was **resolved live in Phase 1** (`QuestModule.dll+0x93DE0`). T2's node
was not probed and must be resolved before firing.

### 4.2 Predicted effect — the paired effect, in full

**T1 — `pytle_a_hadka.start`** drives exactly three things **(code-verified)**:

1. `backuptimer.SetRunning` — a Timer.
2. `savegame17.EnqueueSave` — a save **write**.
3. `sackcarrying.start_minigame` — and this is the whole point.

`sackcarrying` is a shared library module (`Namespace="utils.minigames"`,
`Barbora/utils/minigames/sackcarrying.xml`) with `source_piles = pytle_start`
and `target_piles = pytle_end`. Its `start_minigame` in-port does one thing:

```
start_minigame -> sackCaryying.SetZvedniPytelZeZdrojeStart
```

**That is precisely the state WO-96 §4.3 read out of the joiner's save and not
the host's.** From there the state fans out:

```
sackCaryying.State -> switch7.Switch -> switch7.Value1 -> IsActive on
      ActorCarryItemTrigger (source_piles)
      CarryItemSource       (source_piles)
      CarryItemTarget       (target_piles)      <-- the sacks become grabbable
sackCaryying.State -> Output.states -> pytle_a_hadka's nos_pytle_05
                      objectiveVisual43.Progress <-- the journal line appears
sackCaryying.OnDone -> Output.target_is_filled -> vratSeZaPtackem.SetActive
```

**This refutes the prompt's stated worry.** The prompt warns that writing the
objective alone "would fix the journal and leave the sacks ungrabbable — worse
than the current state, because it looks fixed". True of writing the objective.
But the objective `nos_pytle_05` is not a `State` node at all — its `Progress`
is fed **from `sackcarrying.states`**, i.e. the journal line is a *readout of
the minigame's own state*, not an independent flag. Starting the module
therefore produces both halves from one pulse: sacks grabbable **and** journal
correct. There is no way to get the journal without the gameplay on this path.

**T2 — `rekniPtackoviOPraci.SetDone`.** Transitive walk of `Done` and `OnDone`:
**zero consumers, at any depth** **(code-verified)**. It is a pure journal line
("tell Hans about the work" → Done). This is the *paired* effect the prompt
asked to have named: it comes with T1 in the original dialogue, and firing T1
alone leaves this objective stuck Active.

### 4.3 Downstream hazard enumeration

Against the seven classes `tools/Audit-ObjectiveFixHazards.py` uses (Phase 0
§1.1), over the transitive reach of both targets:

| class | T1 `pytle_a_hadka.start` | T2 `rekniPtackoviOPraci.SetDone` |
|---|---|---|
| CUTSCENE | **none** | none (no consumers) |
| TELEPORT | **none** | none |
| ITEM | **none** — carry-piles are world props, not inventory | none |
| DIALOG | **none** | none |
| SAVE | **`savegame17.EnqueueSave`** | none |
| CLOTHING | **none** | none |
| MOVE | **none** | none |

So the only hazard on either target is **one enqueued save**. Per Phase 0 note
B: a save *write* is harmless here; it is a save *load* that kills every Lua
timer chain (WO-13, WO-78). Worth stating anyway because it fires an autosave
mid-session on one machine.

**Named limits of this enumeration, so nobody rounds it up:**

* The walker could not follow into `sackcarrying` automatically — a shared
  library module is not a child file — so that subtree was walked **by hand**
  and is reported above from a direct read, not from the tool.
* `treti_faze` in `pytle_a_hadka.xml` contains `forced_zacatek_bitky` ("forced
  start of the brawl"). The tavern brawl is a **later phase**, reached by
  *completing* the minigame, not by starting it. It is not in T1's fire chain,
  but it is where this quest is heading, and a brawl starting on one machine
  only is a real MP hazard for whoever takes the next step.
* Depth limit 7; bool-latch second-order effects are not traced (Phase 0 §1.5's
  limit applies unchanged).

### 4.4 Live-fire procedure for the next session

Not run this session. This is the written procedure the WO asked for.

**Preconditions**

1. Game running with `KCDMP.dll` injected; `KcdMpClient` stopped so the pipe is
   free (`nMaxInstances = 1`).
2. A save loaded where M03 `socky` is live and the player is past the first Hans
   dialogue but has not had the second — i.e. the WO-95 host's position.
3. `Probe-ConceptRead.ps1` with no `-Path` returns the two roots. If it does
   not, stop: the layout has moved.

**Step 0 — resolve and inspect, no fire.** A new read-only probe (`0x08`
extended, or a sibling command) must report, for each target:

* `FindNode(<path>)` non-null — T1 already confirmed live, T2 unproven;
* `C_Node::GetPort("<port>")` (`0x2B62E0`) non-null;
* the port's **vtable pointer**, compared against
  `C_ActiveTriggerPort::vftable` = `ConceptModule.dll+0x3F3130`;
* `GetDirection()` (slot 8, `0x2B1A30`) — must be **1**.

**Do not fire unless the vtable matches `C_ActiveTriggerPort`.** Phase 2 §3.5:
`C_TriggerPort`, `C_EdgePort` and `C_DataPort` inherit an **empty** slot 15, so
a call on one of those returns cleanly having done nothing whatsoever. This is
the whole reason step 0 exists.

**Step 1 — fire T1 first.** `port->vtbl[15](port)` on
`pytle_a_hadka` / `start`. T1 before T2, deliberately: T1 is the gameplay. If
only one of the two ever lands, the one worth having is the one that makes the
sacks grabbable. T2 alone is exactly the "looks fixed but isn't" state the
prompt warns about.

**Step 2 — fire T2.** `rekniPtackoviOPraci` / `SetDone`.

**What to watch, and what each line proves**

| signal | where | means |
|---|---|---|
| `CONCEPT: FindNode returned a NODE` | native log | the path resolved |
| port vtable == `+0x3F3130` | native log | it is an active trigger port — the call can do something |
| `Infinite loop detected at port:'%s', stopping execution!` | engine log | the depth guard refused the fire (Phase 2 §3.5) — **the fire did not happen** |
| `ZvedniPytelZeZdrojeStart` | quest/tracker log | the minigame state actually advanced |
| journal shows "Carry the sacks to the pantry" | screen | `sackcarrying.states` reached `objectiveVisual43` |
| **the sacks can be picked up** | screen | `CarryItemSource`/`Target` went active — the real test |

**"It worked" versus "it didn't throw" (WO-43, in native form).**

WO-43's lesson was that a `pcall` returning true proves only that Lua did not
throw. The native equivalent is sharper and worse: `C_PortRef::Trigger` and the
empty `I_Port::Trigger` both **return void**. There is no success value to read,
no exception, and no log line on the empty path. A call that did nothing is
byte-for-byte indistinguishable, from the caller's side, from a call that fired.

So the *only* admissible evidence that this worked is **the sacks becoming
grabbable in the game world**, with the journal line as corroboration. Not the
call returning. Not the probe reporting "ran". Not the absence of a crash. If
the sacks cannot be picked up, the fire did not work, whatever the logs say.

**Rollback.** None. There is no inverse pulse; the minigame state machine has no
"un-start". The rollback is the save made before firing — take one manually
first, and do not rely on `savegame17` to be that save, because it fires *as
part of* T1.

**MP scope.** This fires on one machine. It closes a gap where the local player
is behind; it does not and cannot push the state to a peer. Two players both
needing it means firing on both.

### 4.5 What this leaves for WO-98

* The fire itself, on a live game, with a manual save taken first.
* T2's node has never been resolved; only T1's has.
* The `Haste` root (Phase 1 §2.1a) and `C_DebuggerPort`'s inlined `CanTrigger`
  (Phase 2 §3.5) together suggest a second, parallel addressing scheme beside
  the one WO-94 fires blind. Unmapped, **(inconclusive)**, and the single most
  promising thread this WO turned up that it did not chase.
* Whether `IsHidden=true` hides a trigger from `wh_concept_HasteTrigger` by
  name (Phase 0 note C) — two shipped fix-table entries may be inert.
