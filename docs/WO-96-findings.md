# WO-96 — divergence-triggered prompting, `WAITING_FOR_PEER`, sub-objective mismatch, and the narrow-trigger fix

Companion: `docs/WO-96-progress.md`. Session 2026-09-14. **No live game was
reachable** (`localhost:1403` refused for the whole session), and the native
DLL cannot be deployed from this shell (WO-45). Everything below is therefore
**synthetic**, **code-verified**, or **observed from files** (the quest XML
corpus in `Scripts.pak` sha `bf3eca10…`, the 2026-09-13 host's own saves,
Ghidra on MT `ConceptModule.dll`). Nothing here has been watched on a screen.

Evidence marks as in every prior WO: **(observed)** = read off a file or log
the engine wrote; **(code-verified)** = read off shipped source/binary;
**(synthetic)** = the MoonSharp / xunit harness; **(inconclusive)** = not
settled here.

---

## 0. Answer first

* **Phase 1 shipped.** The readiness prompt fires on the `[story] divergence`
  signal; proximity is a beat *hint* only. Nothing-to-offer is an explicit
  `WAITING_FOR_PEER` status row with stated exits. 60 s per-peer debounce,
  spent beats, decline memory. 142/142 synthetic. **(synthetic)**
* **Phase 2 detects the sub-objective gap — from the save file, not from the
  native read.** The autosave the engine writes at every marker carries the
  concept graph's node state as plain XML; each journal objective is a
  `_objectiveVisualNN/Logs/<State>` node under its module chain. A generated
  registry (626 objectives, 601 with a display node) indexes them; both agents
  exchange a per-quest 2-bit-per-objective fingerprint (StoryBeat kind 5) and
  name the gap. **Known-answer check passed on the real 2026-09-13 host save**:
  the marker's objective reads *active*, the sacks read *none* — the journal at
  16:21 **(observed)**. The ConceptModule native route was **not called**; it
  was sharpened statically and handed off (§3.1).
* **Phase 3 attempted, with the honest census.** Of 626 main-quest objectives,
  **39 have a direct narrow Haste trigger, 24 a clean one, 22 grant-type ones
  ship in a generated fix table**; the mod offers one through the existing F11
  channel when the local player is in that quest and the peer's fingerprint
  shows the objective in exactly that state. **The sacks objective of M03 is
  not among them: no narrow trigger exists for it anywhere in `socky`
  (observed, §4.3).** The bag gap could have been *named the moment it
  opened*, but not closed by this mechanism.
* **Three commits on `main`, one per phase.** `VERSION` untouched (0.22.0).

---

## 1. Phase 0 — ground truth

* `main` was at WO-95's head (`b38b653`) **(observed)**.
* WO-95 §5: the prompt fired 3 times across 5 divergence windows because it
  was gated on proximity to M03's single beat; the divergence line was correct
  every time and unused **(observed, WO-95)**.
* WO-92 §5.2: `FindNode → GetPort → Read()` exists and was never called
  **(code-verified, WO-92)**. §8: STOP rules.
* WO-94 §3: 32 M-coded quests, 53 fireable beats, registry generated between
  markers **(code-verified)**.

---

## 2. Phase 1 — the prompt fires on divergence

### 2.1 Trigger and the role of proximity

**Decision: divergence is the trigger; proximity is no longer a condition.**
`GameBridge.ReportStoryDivergence` — the code that prints `[story]
divergence:` — now also calls `SendQuestDivergence`, once per new pair
(behind the existing latch), and again on the 2.5 s re-arm so a restarted
game's fresh Lua gets it back **(code-verified)**. A peer's `quest_approach`
is recorded as a hint and re-runs the same decision with that beat preferred;
it never raises anything by itself **(code-verified; synthetic (a))**.

Reasoning: the catch-up relocates the player anyway (WO-95 Group D, all
three fires landed on Warhorse's point), so "the peer is standing near the
beat" adds nothing to the offer's usefulness and, per WO-95 §5, was the
reason the offer was mostly absent.

### 2.2 Who is behind

Markers carry no order. The agent remembers the **last marker the pair
agreed on** (`_lastSharedObjective`); when they then differ, whoever still
sits on it is *behind*, the other *ahead*. When both have moved (or the pair
never agreed), the mod orders by production code (M05 > M03); same quest with
no shared history is "cannot tell" **(code-verified; synthetic (i), (k))**.
This is the ordering the 2026-09-13 session needed: the host stayed on
`rekni ptackovi` while the joiner moved on — host behind.

### 2.3 The decision table (`KCD2MP_QuestDivergence`)

| We are… | Peer's quest | Result |
|---|---|---|
| behind | differs, has an unspent, undeclined fireable beat | **prompt** (F11/F12) for that beat: the approach hint if it names one, else the usable beat nearest the peer's ghost, else the first |
| behind | same quest | `WAITING_FOR_PEER` — "reach their objective through ordinary play" |
| behind | no fireable beat / all spent or declined / outside the registry | `WAITING_FOR_PEER`, reason stated |
| ahead | any | `WAITING_FOR_PEER` — "they are behind you" |
| unknown | any | `STORY DIVERGED` row, no offer |

**Same-quest divergence never offers a beat.** A quest-start entry fired
mid-quest advances nothing — the 2026-09-13 host fired `socky._initAndStart`
twice and landed on the identical point twice **(observed, WO-95)** — and
M34's few mid-quest beats are not worth the general risk. **(synthetic (b))**

**Spent beats.** A beat fired *here* this session is never offered again
(`Q.fired`), on both the divergence path and the direct `ShowPrompt` path
**(synthetic (h))**.

### 2.4 `WAITING_FOR_PEER` — a state, not a lock

One `DrawText` row at y=232 (plus an objectives row at y=256 when Phase 2 has
a gap), one native toast on entry and again only when *who is ahead* flips.
Exits: **convergence** (`KCD2MP_QuestConverged`, sent by the agent when the
pair's markers agree on either side's next marker), **peer disconnect**
(`KCD2MP_QuestPromptMoot("peer left")`), **F12 / `mp_quest_hide`** (hidden
until the divergence pair changes). No exit depends on comparing wall clocks
across machines — every exit is an event **(code-verified; synthetic (c), (d),
(l))**. It blocks nothing: synthetic (o) asserts that across every scenario
the only console command ever issued is `wh_concept_HasteTrigger`, after F11,
and that the game's own `OnAction` ran for every press.

**Scope limit, stated as required.** `WAITING_FOR_PEER` is right for *beat*
divergence, where the behind player reaches the same point by playing. It is
the wrong answer for a sub-objective the ahead player earned organically
(items 3–5 of the prompt): waiting cannot make the ahead player re-earn it,
and it cannot grant it to the behind one. That is Phases 2 and 3's problem
and the state does not pretend otherwise — it names the gap (Phase 2) and
offers a fix only where one exists (Phase 3).

### 2.5 Debounce and suppression

* **60 s per peer** between prompts (`Q.promptGapS`, `#KCD2MP_QuestSetGap(n)`).
  A divergence inside the gap is *deferred*: it sits in the waiting row
  ("prompt cooling down, Ns") and the 1 Hz tick raises it once the gap has
  elapsed **(synthetic (e): 50 s no, 61 s yes, exactly two prompts)**.
* **Decline** suppresses that beat for the session (WO-94's rule, kept); a
  later divergence to that quest becomes `WAITING_FOR_PEER` with "declined" in
  the reason **(synthetic (g))**.
* **Update in place.** The row is keyed on (peer objective, our objective,
  rel); a changed objective updates the text silently, a changed rel toasts
  again **(synthetic (f))**. Repeated agent calls while a prompt is up add
  nothing **(synthetic (e))**.

Why these numbers: the fire rate is now the objective-change rate — the
2026-09-13 host saw 6 markers in 90 min, the joiner more — and a decline
that comes back in a minute is exactly the nagging WO-95 §5 warned about.
Whether 60 s and one toast per rel-change *feel* right is the first live
question (§5.4).

### 2.6 Prologue

`prepadeni` and `zachrana` have zero fireable beats (WO-94 §3.4). Under
divergence gating, M01-vs-M02 divergence goes to `WAITING_FOR_PEER` with the
reason "has no fireable beat" — one toast, one row, no command **(synthetic
(i))**. Decision: **left as `WAITING_FOR_PEER`, not suppressed.** WO-95 showed
the `zachrana` stretch reconverging on its own within minutes three times; a
status row that says who is ahead and vanishes on its own is accurate there,
and suppressing the whole prologue would hide the one place Phase 3 *does*
have a fix (`zachrana.goToSleep_activate`, §4.2).

### 2.7 What did not change

The registry gate (`KCD2MP_QuestIsRegistryBeat`) still fronts every path to
`ExecuteCommand` and to the screen; WO-90's `DialogTwin_` exclusion and
WO-94's registry bounds are untouched — this WO changes *when* the prompt
fires, not what it may fire at **(code-verified; WO-94 suite 101/101 after
updating its reset and the row wording)**.

### 2.8 Keys

F11/F12 remain `kcd2mp_dice_bank`/`_yield`. Phase 3 needed no second action:
the narrow fix *is* the F11 prompt in the same-quest case, where no broad
catch-up can exist (§4.4). For the record, the shipped map leaves **no free
F-key** (F2, F4–F8 dice marks, F9 cast/invite, F11/F12, F1/F3/F10 engine
debug); a future distinct action would have to reuse F9 under a prompt gate,
with the dice-table invite as the collision to reason about, or `U`
(`kcd2mp_dice_cancel`).

---

## 3. Phase 2 — sub-objective mismatch is detected, from the save

### 3.1 The native route: sharpened, not exercised, handed off

WO-92's read path was **not called**. Two blockers, neither a judgment call:
no game process existed to attach to, and `KCDMP.dll` is maintainer-deploy
only (WO-45). Rather than guess, the path was decompiled with Ghidra 12.1.3
on MT `ConceptModule.dll` (`native/ghidra_scripts/DumpWo96Decompile.java`),
which settles what a live attempt must get right **(code-verified)**:

| Function | RVA | Real shape |
|---|---|---|
| `C_ConceptManager::FindNode` | `0x16530` | `this` in RCX, **hidden `_smart_ptr<C_Node>*` return in RDX**, `const CryStringT<char>&` in R8. Builds a `C_ConceptPath` (a deque of `CryStringT` segments, `FUN_c6d70`/`FUN_c7110`), matches the **first segment against the root module list** at `this+0x48..0x50` by name, then `C_ModuleBase::GetNode(module, path)`. Returns a null smart_ptr when no root matches. |
| `C_Node::GetPort` | `0x2B62E0` | Same convention (RCX/RDX/R8); linear scan of ports `this+0x30..0x38`, name via vtable slot `+0x48`, compared as C strings. |
| `I_Port::Read` | `0x2B1CF0` | **The exported symbol is the base-class virtual and returns an EMPTY `rttr::variant`** (`in_RDX` constructed, nothing else). A real read must go through the concrete port's vtable, not the export. |
| `C_ConceptModule::GetConceptManager` | `0x1C950` | plain `this` getter |

Still unread: the segment separator inside `FUN_1800c7110` (the tokenizer),
and the `C_ModuleBase::GetNode` descent. With the save tree's root being
`_Barbora/_trosecko/_socky/…`, the first segment is very likely the database
name, but that is **(inconclusive)** until a live call returns a non-null
node. **Handoff:** a live known-answer call — `FindNode("Barbora.…")` against
the same objective the journal shows — needs a deployed DLL and a maintainer
at the keyboard; the register layout above is what it must follow, and the
`Read` caveat is the trap that would otherwise return "empty" and look like
"works, objective none".

### 3.2 The route that works today: the save file

The ConceptState the native read would return is **already on disk**: the
engine writes an autosave at every `questNameOverride` marker (the marker
line *is* `InitiateSaveGame()`), and WO-92 §7 item 3 had decoded the
container. Confirmed byte-for-byte here on the host's saves **(observed)**:

```
[u32 FFFFFFFF][i32 descLen][UTF-8 XML C_SaveGameDescription]
{ [i32 compressedLen][i32 rawLen=32768][zlib 78 5E …] }*   -- plus, in autosave008
{ [i32 -1][i32 rawLen][raw bytes] }                       -- one STORED block at 1,030,211
[64-byte footer]
```

Inside the inflated stream, `<Roots>…</Roots>` is well-formed XML
(`System.Xml` loads it) with the shape

```
Roots/_Barbora/Nodes/_<level>/Nodes/_<quest>/Nodes/_<module>/…/_objectiveVisualNN/Logs/<State UpdateTime="…"/>
```

and State-node leaves beside it (`_sockyState value="Hospoda"`,
`_rekniPtackoviOPraci value="Active"`). Only non-default state is persisted:
a quest never started has no subtree; an objective never shown has no node
**(observed, autosaves 003–009)**.

`SaveGameReader` (inflate + locate + parse), `QuestObjectiveRegistry`
(embedded JSON), `StoryFingerprint` (read/encode/decode/compare) —
**(code-verified; 89/89 xunit incl. a framed synthetic `.whs` with a stored
block)**.

### 3.3 Known-answer checks — run on the real saves, by eye against the journal

`KcdMpClient --fingerprint <save> [questKey]` is the offline probe. On the
**2026-09-13 host's `autosave009.whs`** (16:21, the last objective change of
its session, WO-95 §1.3) **(observed)**:

| Objective (socky) | Save reads | Journal at 16:21 (WO-95) |
|---|---|---|
| `rekni_ptackovi_o_praci` — the marker's own objective | **active** | the tracked objective |
| `zjisti_vic_o_seminove_svatbe` (optional) | **active** | the optional entry |
| `nos_pytle_05` — the sacks | **none** | never shown to the host (item 9) |
| `bran_ptacka` | **none** | never shown to the host |
| the three earlier objectives | none | see below |

The wire text for this state is `b6b917b72323:socky:4001`.

On `autosave005` (M01, `nasleduj ptacka`): 11 *done*, 5 *active* — the
tutorial-duel chain in order, `crouch` done, "follow Hans along the bank"
active. On `autosave007 → 008` (M02): `herbTracker` goes active → done and the
whole alchemy sequence appears done — a progression a player would recognise
**(observed)**. So *done* persists too; the socky "none" for the first three
objectives is the save's truth for that host (its `socky` entry came from the
F11 replay, not from playing the tavern arrival), not a read failure.

`autosave008` first read as "framing mismatch" — the STORED block above.
Fixed and pinned by a unit test.

### 3.4 Registry, fingerprint, wire, refusal

* `tools/Build-MainQuestObjectives.ps1` → `dotnet/KcdMp.Client/mainquest-objectives.json`
  (embedded) + `docs/WO-96-mainquest-objectives.csv`. **626 objectives in the
  32 quests, 601 with exactly one display node, 626 English-titled** from
  `text_ui_quest.xml` **(observed)**. Type resolution is **per file**: the
  quest `socky.xml` and the sub-module `socky/socky.xml` are both named
  `socky`, and ten more socky types are defined twice; a global type map made
  the quest instantiate itself (`socky.socky.socky…`, 113 paths for 8
  objectives) — caught by the first run, fixed. `objectiveVisual5` is reused
  three times in `svatba`; the module chain disambiguates.
* **Fingerprint**: 2 bits per objective (none / active / done / failed), quest
  order; the largest quest (52) is 13 bytes = 26 hex chars; wire text
  `<registryId>:<questKey>:<hex>` ≤ 128. `Active` covers every non-Done/Failed
  log name, including the sack-carrying tracker's own (`ZvedniPytelZeZdroje…`).
* **Wire**: StoryBeat **kind 5** on the existing 0x37/0x38 packet; the relay
  copies the body verbatim (WO-94); a WO-94-era receiver ignores the kind.
  Sent after each own marker, once the save carrying that marker has landed
  (polled ≤ 20 s), superseded by a newer marker.
* **Comparison** is against *our newest save* for *the peer's quest* — the
  tree holds every started quest — so a peer in another quest is still
  compared for that quest's objectives.
* **Registry drift**: `id` = sha-256 prefix over (code, name, key, level,
  objective names, paths). Mismatch → one log line + one toast per peer,
  comparison refused, marker-only behaviour kept **(code-verified; unit-tested
  at the codec level)**. This is deliberately independent of the relay's
  protocol version and of the version-IPC WO-58 found broken in the field.

### 3.5 What the player sees

`[quest] OBJECTIVE GAP with <peer> in M03 "Laboratores": they have [Carry the
sacks to the pantry.] we lack; …` in the agent log; in the mod a `QUEST-GAP`
line, **one toast per change** ("<peer> has an objective you do not: Carry the
sacks to the pantry."), and an *Objectives:* row under the waiting row.
Cleared on convergence and peer-left **(synthetic (q))**. That is the
sentence that would have explained the bag block at 16:23:11 on the
2026-09-13 host, instead of an hour later in a log review.

---

## 4. Phase 3 — closing the gap: what exists, what does not

### 4.1 Method

`tools/Find-ObjectiveTriggers.ps1` reuses WO-94's extraction (same roots,
same subtree walk, same `MakeArray/JoinArrays` resolution). For each
objective it finds the State node its display node reads (`Edge From="X.State"
To="Progress"`) and every `HasteTrigger` in the same file whose `OnTrigger`
edge lands on `X.Set*`. Each such pair is classified **(observed)**:

* *positional* — any `goto` / `playerGoto` / `teleport` in `ConsoleCommands`
* *prereqs* — a `Prerequisites` array (cumulative replay)
* *nested* — a `ConsoleCommands` entry firing another Haste trigger
* *other targets* — `OnTrigger` edges to anything but `X`

**clean** = none of the four. Indirect grants (trigger → module in-port → …
→ X) are *not* followed: those are the cumulative replay WO-94 already
fires, with WO-92 §6.3/§6.4's cost.

### 4.2 The census

| | Count |
|---|---|
| Main-quest objectives | 626 |
| …with ≥ 1 direct narrow trigger | **39** (42 pairs) |
| …with a **clean** one | **24** (25 pairs) |
| …minus reset ports (`SetNone`) and a `test_` name | **22 grant triggers** → `KCD2MP_OBJECTIVE_FIXES` |
| Quests with any fix | 16 of 32 |
| Quests with none | 16 — **M03 socky**, M01, M05, M06, M07, M09, M10, M30, M31, M38, M44b, M45, M47, M48b, M49, M50 |

Every pair is in `docs/WO-96-objective-triggers.csv` with its ports, other
targets, prerequisites and commands. Spot-checked three "clean" entries in the
XML **(observed)**: each is a bare `<HasteTrigger Name="…"/>` whose only
consumer is the State set-port (`finale.talkToRacekObjective →
setkejSeSRackem.SetActive`; `zachrana.goToSleep_activate → goToSleep.SetActive`;
`setkaniVRatbori1.06_getDocument → getDocument.SetDone`).

**Two things "clean" does not mean, stated so nobody rounds it up:**

1. *Clean* means no *extra direct* effect. The state transition itself pulses
   its `On<State>` consumers — that is the point (WO-92 §6.2) and also the
   cost: `zachranaPtacka.07_startMalesovMeetupCutscene` grants `getToMalesov`
   Done and, downstream, the cutscene that Done triggers. Journal-consistent
   is not world-consistent.
2. *Clean* does not grant items. `06_getDocument` sets `getDocument` Done;
   the `AddQuestItem` beside it is driven by the real pickup, not by the
   trigger (WO-92 §6.3 item 2's class). A player granted the objective has
   the journal line, not the document.

### 4.3 The bag case, end to end

**Would Phase 1 have caught it earlier?** Yes, at the first step. Replayed in
synthetic (p): at 16:23:11 (joiner → `nos pytle 05`, host still on `rekni
ptackovi`) the host enters `WAITING_FOR_PEER` naming the joiner as ahead on
the sacks; 16:27 (`bran ptacka`) updates the row in place, no second toast;
16:33 (joiner leaves M03 for M05) the offer for `svatba`'s beat appears.
Under WO-94 the host saw nothing until the joiner happened to pass the single
socky beat.

**Would Phase 2 have named it?** Yes. The host's own save at 16:21 reads the
sacks as *none* **(observed, §3.3)**; the joiner's save at 16:23 would have
read them as *active* (the tracker's `ZvedniPytelZeZdrojeStart` log is what
`Started` writes, `pytle_a_hadka.xml:162`). The gap message is "Joiner has an
objective you do not: Carry the sacks to the pantry." — and, from the joiner's
seat, nothing (the host had nothing the joiner lacked).

**Would Phase 3 have closed it? No.** `socky` has 9 Haste triggers
(`docs/WO-94-mainquest-registry.csv`). `nos_pytle_05` is displayed by
`pytle_a_hadka/objectiveVisual43`, whose progress comes from the
`sackcarrying` minigame module, which starts on
`druhy_dialog_s_ptackem.nos_pytle` — the **second Hans dialogue's out-port**,
which simultaneously sets `rekniPtackoviOPraci.SetDone`
(`v_hospode.xml:344,360`). No `HasteTrigger` anywhere in `socky` drives
`pytle_a_hadka.start`, `rekniPtackoviOPraci.SetDone`, or any sacks state; the
only trigger in that module tree, `start_skirmish_animCheck`, enqueues a
dialogue in the *third* phase **(observed)**. The gate on the bag interaction
was the dialogue the host never got (WO-95 item 5), and the only lever that
reaches it is a native pulse of a module in-port (`C_PortRef::Trigger`,
WO-92 §5.2) — a write, outside this WO and still unexercised.

So the honest end-to-end answer: **caught at 16:23:11, explained in one
sentence, not closed.** The prompt's premise that this specific gap is a
structural ceiling stands; the census shows how narrow the exception is —
22 objectives in 626.

### 4.4 How a fix fires, where one exists

Folded into F11, not a new key. In the same-quest case there is no broad
catch-up (§2.3), so the fix *is* the prompt: "<peer> has '<objective>'
(active) in '<quest>' and you do not — F11 grant it (narrow trigger …, no
teleport) / F12 stay". A standing catch-up offer is never replaced by a fix
**(synthetic (r))**. Gates, all in the mod **(code-verified; synthetic (r))**:

* local player **is in that quest** (`Q.current == questKey`) — a fix for a
  quest we have not started is reported only;
* the peer's state **matches the trigger's direction** (`active` vs `done`);
  a `done` gap with only an `active` fix is not offered;
* the fix path passes `KCD2MP_QuestIsRegistryBeat` (the fix table is a
  second bounded generated registry), so it goes through `KCD2MP_QuestFire`:
  logged before and after, `pcall` true means only "Lua did not throw"
  (WO-43), hazard window opened, `quest_catchup begin` to peers, **spent**
  afterwards, **declined** remembered;
* no positional component by construction (the census refuses any).

**Direction.** Each side computes its own gap from its own save, so whichever
player lacks the objective is the one offered the fix — host-behind (the bag
case's direction) and joiner-behind alike **(code-verified)**. The F11 channel
itself is not directional; it always fires on the machine that pressed it.

---

## 5. Phase 4 — verification

### 5.1 Synthetic — `tools/Test-WO96Synthetic.ps1`, 142 checks, all passing

(a) divergence with a catch-up available, F11 fires exactly the offered beat,
beat spent; hint / nearest-to-ghost / first selection. (b) same quest →
`WAITING_FOR_PEER`, one toast, no command. (c) exit on convergence. (d) exit
on peer disconnect, other peers untouched. (e) debounce: 50 s no re-prompt,
61 s the tick raises the deferred offer, repeated calls under a prompt add
none. (f) update in place; rel flip toasts. (g) decline remembered. (h) spent
beat refused on both paths. (i) prologue → waiting only; production-code
order. (j) ahead. (k) cannot tell. (l) F12 / `mp_quest_hide` hide, new pair
re-shows, F11 alone inert. (m) side-quest peer. (n) `mp_quest_off`. (o)
nothing pauses, only `wh_concept_HasteTrigger`, the game's `OnAction` ran for
every press. (p) the 2026-09-13 host replayed. (q) objective gap: logged,
toast per change, row, close, peer-left; the sacks named as having no trigger.
(r) fix: table bounded (22), gates (quest, direction, spent, declined,
standing offer), F11 fires the exact trigger, hazard window, withdrawn on
close.

Regression: WO-94 101/101 (its reset and row wording updated), WO-90 70,
WO-95 32, WO-86 47, WO-84 72 unchanged. Unit tests 89/89.

### 5.2 What the synthetic layer does NOT prove about Phase 2

The native read: nothing — it was not run. The save read is proven by **the
known-answer probe on `autosave009` (§3.3)**, cross-checked on 005/007/008,
and by the synthetic `.whs` round trip. Not proven: that the engine's
autosave has *finished writing* when the agent's 20 s poll finds it on a slow
disk (the reader retries a failed parse six times); that two real machines
exchange kind 5 (the relay path is WO-94's, unchanged, wire-verified there);
that the objective the joiner's save would show for the sacks is `active`
(inferred from the XML log names, not observed on a joiner save).

### 5.3 Phase 3 live-fire discipline

No fix was fired — no game. When one is, the WO-94 procedure applies
unchanged: `QUEST-CATCHUP FIRE` and `ExecuteCommand returned` lines bracket
the call, the engine's `<HasteTrigger> … is being triggered from haste` line
is the only proof it ran, and every `CATCHUP-HAZARD` line in the 120 s window
is a candidate consequence. For a fix specifically, watch for the downstream
`On<State>` consequences named in §4.2 (a cutscene on `07_start…Cutscene`).

### 5.4 What only a real two-player session settles

1. **Does divergence-gated prompting feel right at its real fire rate?**
   60 s debounce, one toast per rel change — chosen, not measured.
2. **Does `WAITING_FOR_PEER` read as help or as nagging**, especially through
   the prologue where it can never offer anything?
3. **Does the autosave land within the 20 s poll on both machines**, and does
   kind 5 arrive?
4. **Does a narrow fix leave the world consistent**, or only the journal
   (§4.2's two caveats)?
5. **Is the joiner's sacks state `active`** as inferred?

---

## 6. STOP-rule compliance

No game was launched, attached to, or commanded; `:1403` was probed once and
refused. No native function was called. No Lua was injected into a game. No
save was modified — the nine saves inspected were **copied** to the session
scratch directory and read there. Ghidra ran on a copy-free import of the MT
`ConceptModule.dll` and wrote only to the scratch directory. The pak was
rebuilt with `-NoInstall`; nothing was installed.

---

## 7. Corrections to standing belief

* **WO-92 §5.2's "read surface" needs one amendment:** the exported
  `I_Port::Read` is the *base* implementation and returns an empty variant;
  the real read is the concrete port's vtable slot. A live call to the export
  would "succeed" and read nothing.
* **WO-92 §7 item 3's container description gains a case:** saves can carry
  STORED blocks (`compressedLen = 0xFFFFFFFF`, raw bytes follow).
* **WO-95 §5's "extend coverage into the prologue is the second step"** —
  with the census in hand, the prologue's fixable set is one objective
  (`zachrana.goToSleep`); the rest of M01/M02 has neither a fireable beat nor
  a narrow trigger. Coverage there is a data ceiling, not a backlog item.

---

## 8. Named, not attempted

1. **The live native known-answer call** (§3.1) — needs a deployed DLL, a
   game, and a maintainer; register layout and the `Read` trap are written
   down for it.
2. **Pulsing a module in-port** (`C_PortRef::Trigger`) to run the second Hans
   dialogue's `nos_pytle` edge — the only lever that reaches the bag case;
   a native write, explicitly outside this WO.
3. **The joiner's saves** from 2026-09-13 — reading them would turn §4.3's
   inferred `active` into an observation.
4. **A registry-id check in the relay handshake** — the agent-side refusal is
   enough to prevent misreads; a handshake check would only make the mismatch
   louder.
