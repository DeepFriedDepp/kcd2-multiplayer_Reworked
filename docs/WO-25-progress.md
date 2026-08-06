# WO-25 progress — dice shape, AI-bind isolation, aggro safety gate

Session run 2026-08-06. Game running throughout (`KingdomCome.exe`,
`KcdMpServer.exe`, `KcdMpClient.exe`, `KCDMP_launcher.exe`), human present
and playing/testing throughout. No fresh save backup taken — the human
explicitly declared the active save (`playline2`) disposable for this
session; this morning's `playline2_wo24backup` remains as a rollback point.

## Coverage

Phases 1–3 run as specified. Phase 4 stopped before any shipped-code
change, per an explicit human instruction issued mid-session after a real
design conflict surfaced.

| phase | result |
|---|---|
| 1. `Dice.OverrideNextThrow` shape recovery | **Not recovered — exhausted negative.** 7 distinct real shapes tried (6 this session + WO-24's original), all fault-free, all silently accepted by the engine, none observed to affect an actual roll. New finding: recovered the real parameter names (`playerIndex`, `dieValues`) via a validator log triggered by one shape's type mismatch. Open question shifted from "wrong shape" to possibly "wrong timing" — this build's dice auto-roll gives no controllable pre-cast injection point. |
| 2. Isolating the AI binds | **Isolated cleanly for the first time: no effect without hostile faction underneath.** Commoner-soul baseline (no binds) showed zero hostility over 24s. Same soul + `AddPersonallyHostile`/`SetAttentiontarget` showed zero observable engagement over 65s (`AttentionTargetType`/`PeakThreatLevel` stuck at 0 throughout, despite both binds independently verified as real writes). Resolves WO-24's confound (its Phase 3 used an already-hostile soul). |
| 3. Aggro safety guardrail | **Native protection confirmed real and live-verified against actual lethal damage.** `soul_vip_class_id` exists on every soul row (95% of ~8,198 souls carry none; the rest carry graduated protection). Live A/B test: a ghost bound to a real quest NPC's soul (Petr Mailer, immortality flag) survived 200 lethal damage at 1 HP; an identical hit killed an unprotected control NPC outright. Novelty assessed as "not new in kind, different in trigger/legibility/blast-radius." Human's recorded decision: rely on native VIP protection, no blanket kill-prevention — ordinary NPCs stay fully killable by design. |
| 4. Ship soul-row hostility | **Deferred, not built.** A real design conflict surfaced before implementation: soul-row hostility requires swapping a ghost's `SharedSoulGuid` to a hostile-faction soul, which also destroys its WO-20 face-roster appearance (no proven way to set faction independent of soul identity). Raised to the human; their answer revealed the real long-term goal is bigger than this WO's scope — connected players staying fully "Henry" (cosmetic and functional) with automatic reactive combat engagement, not a manual toggle wrapping a soul-swap. Per their explicit instruction, stopped here rather than ship a mechanism that conflicts with that direction. |

## What's fixed

Nothing shipped changed. `KCD2MP_SpawnGhost`, the aggro toggle
(`mp_enable_aggro`), `dotnet/`, `native/` are all untouched — same as
WO-24, this was verification/design work, with one explicit stop mid-Phase-4
before any implementation began.

## What's a promising, flagged, untested lead for the next session

1. **`Dice.OverrideNextThrow` timing hypothesis** — the real parameter
   names (`playerIndex`, `dieValues`) are now known from a validator log,
   and six structurally distinct table shapes are all confirmed
   engine-accepted with zero effect. The next lever to pull is timing, not
   shape: does the override need to be called in the exact frame before a
   specific native roll event, and is that event reachable at all given
   this build's auto-rolling dice?
2. **A native faction-hostility lever independent of soul/appearance
   identity** — this is now the actual blocker on the "players stay as
   Henry" goal, not merely a nice-to-have. `AI.SetFactionOf` (Lua) is
   confirmed inert (WO-20). Nothing tried across WO-20/22/24/this session
   sets real faction hostility without also changing which soul (and thus
   which face) an entity carries. This likely needs either further native
   disassembly of the faction-attach code path, or accepting the
   soul-identity coupling as permanent and redesigning the product around
   it.
3. **A future WO scoped explicitly around "automatic, reactive, in/out of
   combat aggro with no permanent ghost identity"** — the human's actual
   long-term ask, not the same shape as this WO's Phase 4.

## Real-world session cost

One real, hand-placed NPC (`ttac_man_11`) was killed during Phase 3's
guardrail verification test and could not be revived (death is a one-way
transition on this engine, confirmed live). The human explicitly
authorized this in advance for the disposable test save in use.

## Files touched

- `tools/wo25-lua.ps1` (new)
- `docs/WO-25-findings.md` (new)
- `docs/WO-25-progress.md` (this file, new)
- `docs/PROJECT-STATE.md` §4 (amended)

No changes to `kdcmp.lua`, `native/`, `dotnet/`, `VERSION`, or the
installer.
