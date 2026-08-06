# WO-24 — three live checks WO-23 could only flag

Investigated 2026-08-06, live against KCD2 (Modding Tools build), the `kdcmp`
mod loaded, and the human present and playing throughout. Save backed up
before Phase 2/3 (`playline2` → `playline2_wo24backup`, verified byte-identical
via `diff -rq`). All three phases run in the order the WO specified. Every
test ghost removed and cleanup confirmed by count (0/3 remain) at the end.

---

## Phase 1 — is the `Dice` Lua scriptbind actually live?

**Liveness, checked precisely, not assumed from the docs:**

```
type(Dice)                    = table
type(Dice.GetDice)            = nil        <- documented, NOT present
type(Dice.SetScore)           = function
type(Dice.OverrideNextThrow)  = function
type(Dice.RollDie)            = function
type(Dice.HoldDie)            = function
type(Dice.ToggleHoldDie)      = function
type(Dice.SetAdvantage)       = function
type(Dice.SetAIDifficulty)    = function
type(Dice.SetAIRiskTaking)    = function
```

8 of 9 documented methods are real, callable functions in this build.
`Dice.GetDice` — the one method that would return a `C_Dice&` handle — is
`nil`. Same pattern this project has hit repeatedly (`TryEndCombat` documented
but absent, `C_Dice` documented but not RTTR-registered): documented does not
mean present, checked per-symbol.

**Tested mid-match, against a real dice game (Henry vs. a real NPC opponent,
goal 1500):**

| Call | Fault-free? | Real observed effect? |
|---|---|---|
| `Dice.SetScore(77, 33)` | yes | **yes, real and precise.** Henry 300→377 (+77), Opponent 0→33 (+33). **`SetScore` is additive to the existing banked total, not a literal overwrite** — the method name is misleading. Confirmed from a known pre-call value (300), supplied by the human, not assumed. |
| `Dice.HoldDie(pid, pid, 0, 1)` (`pid`=player entity id, used for both `userId` and `dieEntityId` — a guess, since the method page documents no field/parameter meaning beyond the C++ signature) | yes | **yes, real.** A die on the table visibly became selected/held; the "Selected" counter changed. |
| `Dice.RollDie(pid, pid, 1)` | yes | **yes, real.** One of the human's own **held** dice silently changed face value (1 → 4) with no roll animation and no button press. A genuine, individual per-die state write, not a full re-roll. |
| `Dice.OverrideNextThrow(0, {1,1,1,1,1,1})` (guessed `tbl` shape — the method page for this call documents literally nothing beyond `SmartScriptTable tbl`, no field names anywhere in the shipped docs) | yes | **no observed effect.** The human's next real throw came up as 4 twos, not the forced all-1s. This is **inconclusive on the table shape**, not a clean negative — the true shape of `tbl` is genuinely undocumented and this session tried exactly one guess. |

**Gate 1: `Dice` is live and three of four tested write calls produce real,
verified changes to the native minigame's actual displayed/held/rolled state**
— `SetScore`, `HoldDie`, `RollDie` all confirmed. `OverrideNextThrow` remains
open: fault-free, but the one shape tried did not force the result, and
nothing in the shipped docs describes what shape would.

**Architecture implication, stated as the WO asked, not built:** this is a
real, better foundation for real two-player dice than the current Lua-overlay
board (`docs/WO-6-overlay-design.md`). `SetScore` alone would let the mod push
a real, verified score into the actual native minigame UI instead of drawing
a parallel screen. The concrete next step, if this is picked up: recover
`OverrideNextThrow`'s `tbl` shape (candidates: per-die face array in a
different order/base, or a table keyed by die index rather than a flat
array — both untried), since forcing individual die results, not just the
score line, is what a real synced two-player match needs. Not attempted
further this session per the WO's explicit "don't build this now."

---

## Phase 2 — hostile soul, no `SchedulerProxyName`

Donor soul: `prepadeni_banditWithTorch_1`, `SharedSoulGuid =
75ec27f8-509b-4285-a295-350130519927` — a bandit from the same `prepadeni_*`
ambush event WO-22/WO-23 referenced by its truncated GUID
(`29f8bb4d-…`, never fully recorded in this project before; this is a
different soul from that same event, since the earlier GUID could not be
recovered from any surviving log or commit).

**Spawn 1 (`wo24A`), isolated location, no real NPC nearby:**

- `XGenAIModule.SpawnEntity{Name="wo24A", SharedSoulGuid=<bandit guid>, Pos=…}`,
  no `SchedulerProxyName` — the exact shape the shipped `KCD2MP_SpawnGhost`
  would use if WO-22's follow-up #1 is ever applied.
- Read back: `SharedSoulGuid` matches exactly, `FactionNode.UIName =
  soul_ui_name_bandit` — real hostile faction, sourced from the soul row, no
  native `SetParent`, no proxy, no donor NPC needing to be loaded.
- **Position stability: byte-identical across 6 samples over 60 s**
  (`2389.3384,2307.0315,140.09329`, unchanged to 4 decimal places every 10 s).
  Matches WO-22's `wo22U`/`wo22D`/`wo22S` pattern exactly.

**Spawn 2 (`wo24B`), near a real NPC (a farmer), after the human moved:**

- Same soul, same shape, respawned near the human and a real farmer NPC.
  Soul binding re-verified (`SharedSoulGuid` match, `FactionNode.UIName =
  soul_ui_name_bandit`).
- **The ghost engaged real NPCs and won.** By the human's own account:
  the ghost moved into the nearby town and killed **3 real, named NPCs** — a
  Villager, "Hired Hand Zdenyek the Mouth", and "Innkeeper Prochek" — before
  combat ended on its own. This is a materially stronger result than WO-22's
  own aggro tests, where every hostile ghost tested (n=3, all bandit souls)
  **fled** rather than fought, because those were outnumbered 4:1 by armed
  guards. Against ordinary civilians, the identical mechanism (soul-row
  faction alone) wins fights, not just starts them.
- **Correction to WO-22's stationarity claim, found live this session:**
  position was byte-stable (confirmed, `wo24A`) *before* any NPC noticed the
  ghost. Once real combat started, `wo24B` moved roughly 106 m under its own
  power (`2094.37,2559.14` → `1989.95,2535.13`), then went stationary again
  (4 samples, byte-identical, 32 s) once the fight ended. **"No
  `SchedulerProxyName` ⇒ never moves" holds only pre-engagement.** A
  soul-only ghost that gets into real combat moves on its own regardless of
  the proxy setting — this is new information WO-22 did not have, because its
  own soul-only ghosts were never engaged in a real fight while unproxied.
  Anyone shipping this configuration needs to account for that: the position
  sync (`KCD2MP_InterpTick`) will fight a hostile soul-backed ghost exactly as
  hard as it fights a proxied one, but only once, and only during combat.

**Gate 2: WORKED, clearly.** A hostile `SharedSoulGuid` alone, no proxy, no
native attach, no DLL-injection-dependent mechanism, produced real NPC
aggression that killed three real NPCs. **This is a real candidate to replace
the current native faction-attach mechanism's donor-soul-must-be-loaded
fragility.** Not wired into `KCD2MP_SpawnGhost` this session, per the WO's own
instruction — that is a follow-up decision, not made here.

---

## Phase 3 — `AI.AddPersonallyHostile`/`AI.SetAttentiontarget` on a soul-backed ghost

Fresh ghost (`wo24C`), same bandit `SharedSoulGuid`, no proxy, spawned next to
the human and a real Peasant NPC (`ttac_man_2`) in an open field.

Applied immediately after spawn, before natural perception could plausibly
have already triggered engagement on its own:

```
AI.AddPersonallyHostile(npcId, ghostId)   -> ok=true
AI.SetAttentiontarget(npcId, ghostId)     -> ok=true
AI.IsPersonallyHostile(npcId, ghostId)    -> true   (verified, not fault-free-and-assumed)
AI.GetAttentionTargetEntity(npcId):GetName() -> "wo24C"   (verified)
```

Both binds fault-free and independently verified as real, exactly reproducing
WO-20's original result — now on a soul-backed, brained ghost for the first
time, closing WO-22's own flagged-not-answered follow-up.

**Observed outcome: the ghost killed both nearby real NPCs.** By the human's
account, same shape of result as Phase 2 — rapid engagement, ghost wins.

**Gate 3: no distinguishable additional effect from the binds.** The outcome
here is qualitatively identical to Phase 2's result, which used the same
bandit soul with **no** `AI.*` binds at all. Since Phase 2 already
demonstrated that soul-row hostility alone reliably produces full engagement
and real kills against ordinary NPCs, this session cannot isolate any
contribution from `AddPersonallyHostile`/`SetAttentiontarget` — the binds are
confirmed to write real, verified state (again), but nothing observed here
shows they changed the outcome, speed, or behavior versus soul-hostility
alone. No precise timing baseline exists from Phase 2 to compare against, so
"same speed" is an honest impression, not a measurement — recorded as such.
This is one of the three valid results the WO named in advance (real
additional effect / no distinguishable difference / no action at all) — the
second one is what happened.

---

## Cleanup

All three test ghosts (`wo24A`, `wo24B`, `wo24C`) removed via
`System.RemoveEntity`. Confirmed by count: all three return 404
("not found in container") from the reflection API after removal. **0 of 3
test ghosts remain.**

## What this session does not resolve

- `Dice.OverrideNextThrow`'s real `tbl` shape — one guess tried, no effect,
  shape remains undocumented.
- Whether `AI.AddPersonallyHostile`/`SetAttentiontarget` ever add anything
  beyond soul-row hostility alone — Phase 3's test was confounded by using an
  already-inherently-hostile soul. Isolating the binds' own contribution would
  need a **non-hostile-faction** soul (e.g. a commoner) plus the binds, compared
  against that same commoner soul with no binds at all — not attempted this
  session, since the WO specified reusing/matching Phase 2's exact shape.
- Real-world consequence: Phase 2/3 killed 5 real, named NPCs total across a
  town and a field. The test save (`playline2`) now reflects that; a clean
  backup exists at `playline2_wo24backup` if the human wants to roll back.

## What this session does NOT change

Per the WO's explicit instructions: no changes to `KCD2MP_SpawnGhost`'s
shipped defaults, no changes to the aggro toggle's mechanism, no changes to
the current dice UI architecture, no `VERSION`/release action. Both Phase 1
and Phase 2 produced real, positive leads with a stated next step each, but
neither was built.

## Files touched

- `tools/wo24-lua.ps1` (new) — ExecuteString driver + `[WO24]` log reader,
  same shape as `tools/wo22-lua.ps1`
- `docs/WO-24-findings.md` (this file)
- `docs/WO-24-progress.md`

Save backup: `C:\Users\Jonasty\Saved Games\kingdomcome2\saves\playline2_wo24backup`
(copy of `playline2`, taken before Phase 2, verified identical via `diff -rq`).

No changes to `kdcmp.lua`, `native/`, `dotnet/`, `VERSION`, or the installer.
