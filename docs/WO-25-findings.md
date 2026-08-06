# WO-25 — dice shape recovery, AI-bind isolation, aggro safety gate

Investigated 2026-08-06, live against KCD2 (Modding Tools build), a real
dice match and a real isolated meadow spot with hand-placed NPCs, human
present throughout. No save backup was taken before Phase 2/3 — the human
explicitly declared the active save (`playline2`) disposable for testing
("I dont care if every NPC in the game dies on this save"); the
`playline2_wo24backup` from this morning's session remains as a rollback
point regardless. One real NPC (`ttac_man_11`) was killed during Phase 3's
guardrail verification and could not be revived (death is idempotent/
one-way, confirmed live) — acceptable per the human's explicit blanket
authorization. All spawned test entities removed and cleanup confirmed by
count at the end of each phase.

---

## Phase 1 — `Dice.OverrideNextThrow`'s real table shape

**Not recovered. A genuinely exhausted, documented negative.**

Extracted the shipped scriptbind docs (`Tools/modding/docs/script_bind/
script_bind.zip`, previously unopened by this project) to check what
`OverrideNextThrow` actually documents. Its own page
(`C_ScriptBind_Dice__OverrideNextThrow@...html`) has **zero** Parameters or
Description sections — genuinely, completely undocumented, unlike every
other `Dice` method on the same page set (`RollDie`, `HoldDie`, `SetScore`,
`SetAdvantage` all have full parameter tables). This confirms WO-24's
finding was not an oversight: Warhorse shipped no information about `tbl`'s
shape at all.

Cross-referenced `RollDie(userId, dieEntityId, dieNumber)` — `dieNumber`
documented as "number of the die (0 - 5)", a plain 0-based int, no entity
handle despite the parameter's name. This shaped several hypotheses below.

Seven distinct real shapes tried this session (plus WO-24's original),
each verified against an actual cast, not just a fault-free return:

| # | Shape (`dieValues`) | `player` arg | Result |
|---|---|---|---|
| WO-24 | `{1,1,1,1,1,1}` (flat, 1-based) | `0` | no effect (prior session) |
| A | `{[0]=6,[1]=6,...,[5]=6}` (explicit 0-based keys) | `0` | no effect — busted (likely full 6-die roll, unconfirmed) |
| B | `{faces={6,6,6,6,6,6}}` (nested field) | `0` | no effect — busted (likely full, unconfirmed) |
| C | `{["0"]=6,...,["5"]=6}` (string-keyed 0-based) | `0` | no effect — busted (likely full, unconfirmed) |
| D | `{6,6,6,6,6,6}` (flat) | `1` | no effect — rolled 1,4 (**confounded**: only 2 of 6 dice were active this turn, 4 already held) |
| E | `{[0]={face=6},...,[5]={face=6}}` (per-die subtable) | `0` | no effect — rolled 5 ones + 1 two (**clean, full 6-die read**) |
| F | `{6,6,6,6,6,6}` (flat) | player entity id (userdata) | no effect — rolled 3 fives, 1 one, 1 six, 1 four (**clean, full 6-die read**); also triggered a validator type error (below) |

**A real, new finding, not a guess:** shape F's entity-id `player` argument
triggered a logged engine-side rejection that no other call did:

```
[Warning] Validator: [Script Error] Wrong parameter type. Function
Dice.OverrideNextThrow(playerIndex, dieValues) expect parameter 1 of type
Number (Provided type Pointer)
```

This recovers the **real parameter names** — `playerIndex` and
`dieValues`, not just the generic `player`/`tbl` from the C++ signature —
confirms `playerIndex` must be a plain `Number` (ruling out an entity-id
hypothesis cleanly, rather than by inference), and — critically — shows
that **none of shapes A–E's `dieValues` tables triggered this same
validator path**. The engine accepts all of them as structurally valid
`SmartScriptTable` input; it simply produces no visible dice-face effect.
That is a stronger negative than "one guess, no effect" — six structurally
distinct, engine-accepted shapes, zero observed override.

**What remains unresolved and untried:** whether the non-effect is a shape
problem at all, versus a **lifecycle/timing** problem — this build's dice
auto-rolls a fresh hand at the start of a turn with no player-controllable
"about to cast" moment to inject before, so every override call in this
session landed some indeterminate number of engine ticks before the actual
roll it was meant to affect. It is equally plausible that `OverrideNextThrow`
only takes effect if called in the same frame/immediately before the
specific native roll event fires (e.g. consumed by the very next internal
`RollDie` call rather than persisting until the next player action), and
every shape here was simply overwritten or expired before use. This was not
testable this session — it would need either a way to hook the exact
pre-roll moment, or the native disassembly of `OverrideNextThrow` itself.

**Gate 1: shapes tried and none worked, stated precisely** — 7 real shapes
across two sessions, all fault-free, all silently accepted, none observed
to affect an actual roll. Recovering the shape (if it is even the blocker)
needs either the timing question resolved or disassembly, neither attempted
here.

**Architecture implication (stated, not built, per the WO):** this remains
a real, better foundation for real two-player dice than the current
Lua-overlay board — `SetScore` alone (WO-24) already lets the mod push a
verified score into the real native UI. But `OverrideNextThrow` staying
unrecovered means the mod still cannot force *individual die faces* through
the native minigame, which is what a true synced two-player match needs;
the overlay-replacement question stays open pending either the timing fix
or a disassembly session.

---

## Phase 2 — isolating whether the AI binds add anything

**Isolated cleanly for the first time. No effect without hostile faction
underneath.**

WO-24's Phase 3 was confounded: it applied `AddPersonallyHostile`/
`SetAttentiontarget` to an already-hostile bandit soul, so the binds'
contribution could not be separated from the soul's own faction hostility.
This session ran the controlled version the WO specified.

**Setup:** `ttac_man_11`, a real, hand-placed herdsman
(`FactionNode.UIName = soul_ui_name_herdsman`, `SharedSoulGuid =
f21b01fb-3a28-45ec-b25c-97858519a5bd`) in an isolated meadow (cattle, no
settlement, no crowd), used as both the donor soul (for the spawned ghost)
and the real target NPC.

**Condition 1 — commoner soul alone, no binds.** `wo25A` spawned with
`ttac_man_11`'s own `SharedSoulGuid`, no `SchedulerProxyName`. Verified:
`SharedSoulGuid` read-back match, `FactionNode.UIName = soul_ui_name_herdsman`
(real, non-hostile commoner faction). 4 samples over ~24s: position
byte-identical, health unchanged (100/100 both), `AI.IsPersonallyHostile`
false. **Clean baseline, matches expectation.**

**Condition 2 — same soul, `AddPersonallyHostile` + `SetAttentiontarget`
applied.** Both calls fault-free; both independently verified via getters,
not just a fault-free return:

```
AI.IsPersonallyHostile(ttac_man_11, wo25A) = true
AI.GetAttentionTargetEntity(ttac_man_11):GetName() = "wo25A"
```

Observed over **~65s total** (two windows, 6 + 4 samples): `wo25A` never
moved (position byte-identical throughout — consistent with soul-only,
no-proxy stationarity even post-bind), health never changed on either
side, and — the key readings — `AI.GetAttentionTargetType(ttac_man_11)`
and `AI.GetPeakThreatLevel(ttac_man_11)` **stayed exactly 0 for every
sample**. `ttac_man_11` continued its own unrelated routine (walking a
short distance, then stopping) with no observable relation to the ghost.

**Gate 2: no effect without hostile faction underneath, confirmed
precisely.** This is the first clean isolation of the two binds' own
contribution from soul-row hostility. The result reproduces WO-20's exact
non-effect signature (`AttentionTargetType`/`PeakThreatLevel` stuck at 0
despite `AttentionTargetEntity` correctly resolving) — now on a
genuinely non-hostile soul, ruling out the confound WO-24 could not rule
out. **`AI.AddPersonallyHostile`/`AI.SetAttentiontarget` write real,
verified state but do not themselves cause engagement — the native
soul-row `factionName` remains the only proven lever for real aggro.**

Cleanup: `wo25A` removed (took two attempts — the first
`System.RemoveEntity` call returned `ok=true` but the entity was still
alive and healthy on the next lookup, a real observed unreliability worth
knowing about; the second call worked). Final sweep across all WO-25 test
entity names confirmed 0 remain.

---

## Phase 3 — aggro safety guardrail: findings, decision, and live verification

### 1. Does native essential-NPC protection exist?

**Yes — real, confirmed from shipped data, and confirmed live to actually
block death.**

`Libs/Tables/rpg/soul_vip_class.xml` defines a real enum (`soul_vip_class_id`
on every soul row) with tiers including `attack_protection`, `immortality`,
`unconsciousness_protection`, `untouchable`, and combinations. Across
~8,198 souls in the extracted table data:

| `soul_vip_class_id` | count | meaning |
|---|---|---|
| 0 | 7,796 (95.1%) | none |
| 31 | 154 | untouchable |
| 12 | 90 | immortality + unconsciousness protection |
| 4 | 55 | immortality |
| 3 | 39 | attack + steal protection |
| 16 | 23 | loot protection |
| 15 | 21 | steal/attack/immortality/unconsciousness |
| 8 | 7 | unconsciousness protection |
| 1 | 7 | pickpocket protection |
| 23 | 3 | immortality/attack/pickpocket/loot |
| 2 | 2 | attack protection |
| 13 | 1 | steal/unconsciousness/immortality |

**Live-verified, not just read from static data.** Spawned a ghost bound to
`soul_id 237705d9-a6e6-4e38-97f8-5aa80684bda1` — **Petr Mailer**, a real,
named Kuttenberg quest NPC, `soul_vip_class_id="4"` (immortality). Applied
identical lethal damage (`CombatSoul.TakeDamage?Health=200`, the real
combat entry point per `NATIVE-PLUGIN-findings.md`) to this ghost and, as a
control, to the same real unprotected NPC used in Phase 2:

| target | protection | damage | result |
|---|---|---|---|
| Petr Mailer soul (ghost) | `vip_class_id=4` (immortality) | 200 lethal | health floored at **1**, `IsDead=false` — **survived** |
| `ttac_man_11` (real NPC) | `vip_class_id=0` (none) | 200 lethal (identical call) | health **0**, `IsDead=true` — **died** |

This is a clean, controlled, live A/B result: the native immortality flag
genuinely intercepts the real damage pathway an aggro'd ghost's attacks
would use, not just a data-table label. (A prior attempt using
`SetState?State=health&Value=0` was inconclusive and discarded — that
write silently no-op'd on **both** the protected and unprotected subject,
an unrelated behavior of that specific endpoint at exactly zero, not a
protection signal. `TakeDamage` is the real test.)

I could not confirm the identity of WO-24's three victims (Villager,
"Hired Hand Zdenyek the Mouth", "Innkeeper Prochek") against this table —
their display names are not present in the locally mirrored soul data
(display strings are evidently stored in a separate localization table not
extracted here). Given 95% of the roster carries no protection, it is
plausible but **not directly proven** that they fell in the unprotected
majority.

`ttac_man_11` itself was killed by this test and could not be revived
(`SetState` health writes do not reverse `IsDead=true` — death is a
one-way transition, matching `NATIVE-PLUGIN-findings.md`'s note that death
is idempotent and not inferred from health alone). Acceptable per the
human's explicit blanket authorization for this disposable save.

### 2. Is this a new risk category?

**Not new in kind; different in trigger, legibility, and blast radius.**
A player can already kill an ordinary NPC directly in vanilla single-player
play — the 95%-unprotected roster shows this is the base game's own design,
not an oversight. What genuinely differs with aggro'd ghosts: the kill
decision comes from NPC AI, not deliberate player action; it can happen to
bystanders the player never selected (WO-24's ghost moved into a town and
killed people incidental to its own fight, not people the player was
aiming at); and there is no "are you sure" moment — the player learns about
it after the fact, if at all.

### 3. Guardrail options presented and decision

Presented three options (rely on native VIP protection + warning;
health-triggered auto-detach reusing the existing 20s hold pattern;
severity tier on the toggle) plus "don't ship Phase 4 this session."

**Human's recorded decision, verbatim:** *"So long as Quest NPCs cannot be
killed, that is all that matters to me. There will surely be players who
decide they want to do a kill-all-NPCs run, and I want them to have that
freedom, just like you do when you are playing KCD2 solo."*

This selects reliance on the native `soul_vip_class_id` protection — now
live-verified above to actually work against real lethal damage — over any
blanket kill-prevention mechanism, explicitly preserving ordinary-NPC
killability. No custom protection code is needed; the guardrail is "do not
interfere with the native flag," which nothing in this project's aggro path
currently does.

**Gate 3: native protection confirmed present *and* live-verified against
real damage; novelty assessment stated plainly; options presented; explicit
human decision recorded before Phase 4.**

---

## Phase 4 — not shipped this session, deferred

Before implementing, a real design conflict surfaced: the soul-row
hostility mechanism (WO-22/24) only works by binding a ghost's
`SharedSoulGuid` to a soul whose own `factionName` is hostile — and
`SharedSoulGuid` is the *same* property that determines the ghost's
face/outfit under WO-20's deterministic face roster (making a ghost look
like the actual connected player). There is no proven way to get real
hostile faction independent of soul identity — `AI.SetFactionOf` is
confirmed inert (WO-20, re-confirmed not-retested-negatively this session).
So shipping the soul-row approach as specified would mean an aggro'd ghost
stops resembling the connected player for as long as it's hostile.

Raised this to the human before implementing. The human's response
reframed the goal beyond this WO's scope: the long-term intent is for
connected players to be **fully Henry** — cosmetically and functionally,
never a "ghost" — with aggro/combat engagement working automatically and
reactively (matching how the real player Henry can engage, flee, and
return without being permanently flagged), not as a manual
`mp_enable_aggro on/off` toggle. Achieving that is a materially different
and larger technical problem than "replace one attach mechanism with
another" — it needs a lever that sets real faction hostility independent
of appearance, which nothing found across WO-20/22/24/this session
provides. Per the human's explicit instruction — *"If that needs to be a
separate WO, then stop there for the aggro piece"** — Phase 4's shipped-code
work stops here.

**Nothing in `KCD2MP_SpawnGhost`, the aggro toggle, `dotnet/`, or `native/`
was changed this session.** The current shipped mechanism (native
`SetParent` faction attach, reactive, 20s hold, donor-soul-loaded
fragility and all) remains exactly as WO-15/16/17 left it.

**Gate 4: not reached.** Recorded as an explicit, human-directed stop, not
an oversight or a self-selected default.

---

## Cleanup

All WO-25 test entities (`wo25A`, `wo25V`, plus a swept check for
`wo25B/C/D/W/X`) confirmed removed by count: **0 remain.** `ttac_man_11`
(a real, hand-placed NPC, not a mod-spawned test entity) was killed during
Phase 3's guardrail verification and stays dead — irreversible, and
explicitly acceptable to the human for this disposable save.

## What this session does not resolve

- `Dice.OverrideNextThrow`'s table shape — 7 shapes tried, all inert; the
  open question is now specifically whether this is a shape problem or a
  call-timing/lifecycle problem, given this build's dice auto-rolls with no
  controllable "about to cast" moment to inject before.
- Whether soul-row hostility can ever be reconciled with keeping a ghost's
  WO-20 face-roster appearance — no lever found this session (or any prior
  one) that sets faction hostility independent of soul/appearance identity.
- The broader "players are fully Henry, not ghosts" goal — out of scope for
  this WO by the human's own instruction; needs its own WO.

## Files touched

- `tools/wo25-lua.ps1` (new) — ExecuteString driver + `[WO25]` log reader,
  same shape as `tools/wo24-lua.ps1`
- `docs/WO-25-findings.md` (this file)
- `docs/WO-25-progress.md`
- `docs/PROJECT-STATE.md` §4 — amended with the VIP-protection finding

No changes to `kdcmp.lua`, `native/`, `dotnet/`, `VERSION`, or the
installer.
