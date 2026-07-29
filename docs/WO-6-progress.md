# WO-6 progress log

Append-only. Newest entry at the bottom. If you are starting a new session,
read this file plus `docs/SESSION-PROMPT-wo6-native-dice.md` (what this WO
was asked to do) and, if picking up the in-game overlay work specifically,
`docs/SESSION-PROMPT-wo6-overlay-ui.md` (what to do next — a design pivot
happened at the end of this session, see below).

---

## Session 1 — 2026-07-28 — Phase 0.5, R0, R1, R2, and a design pivot

Started cold from `docs/SESSION-PROMPT-wo6-native-dice.md`. Did not reach
Phase 1/2 builds — R2 turned out to need far more investigation than
budgeted, and the session ended on a design pivot instead. Nothing here is
half-finished code; everything committed is either a completed research step
or a clean negative result with evidence.

### Housekeeping first

Found uncommitted changes from a prior session's verification pass already
in the working tree: a real bug fix (`Home.razor.cs`'s ping loop skipping
manually-added servers) and TEMP diagnostic logging left mid-investigation
in `DiceIpcClient.cs`. Committed the fix on its own, reverted the diagnostic
back to its original silent form. Also committed the prior session's raw
working documents (`VERIFICATION-REPORT.md`, `SESSION-SUMMARY-pre-final-wo.md`)
alongside the WO-6 session prompt itself.

### Phase 0.5 — licensing

Added `LICENSE` (GPLv3, fetched verbatim from gnu.org) and a "License and
Provenance" section to `README.md`. One clarification surfaced and resolved
with the human: GPL permits commercial resale of derivatives (copyleft means
derivatives must stay open, not that they can't be sold) — the human's actual
goal was closer to a non-commercial license, but chose GPLv3 anyway after
understanding the tradeoff, prioritizing dependency-compatibility and
staying aligned with "the fork will carry a GPL license" from the WO brief.

### R0 — framework/dependency scout

Searched Nexus/GitHub for existing native tooling. Found and evaluated:
`kcd2_rttr_dumper` (unlicensed, used as an unvendored local research
reference only — see below), `kcdx`/`KCSE-for-kcd2`/`KCD2ModLoader` (general
script-extender frameworks, declined — this project's own native plugin
already works and these would replace it rather than extend it),
`kcd2-modding-docs` (doesn't cover the dice/GUI surface, declined). Nothing
adopted as a dependency.

### R1 — mapping the reflected surface

**Static lead, before touching the game:** `kcd2_rttr_dumper`'s committed
57k-line static RTTR type dump led directly to `wh::guimodule::C_UIDice` —
a real reflected class with five methods (`ShowDiceScore` taking 14
parameters, `HideDiceScore`, `ShowDiceProperties`, `HideDiceProperties`,
`SetCurrentPlayer`) and zero properties.

**Live confirmation:** walked the debug REST API (`localhost:1403`) the same
way `NATIVE-PLUGIN-findings.md` did for `rpg`/`xgen`/`ent`. Confirmed
`C_UIDice` sits in `GUIModule.UIElements` (index 22) alongside the game's
other minigames (Pickpocketing, Shop, ShootingContest — same
one-singleton-per-minigame pattern) and is **genuinely empty even at
depth=4**, live, not just in the static dump.

**Environment correction, mid-session:** the human had launched via
`KCDMP_launcher` rather than the Modding Tools Steam entry directly. Debug
REST API unaffected (built into the game, independent of this mod's DLL).
`KCDMP.dll`'s *automatic* injection did hit the known 0-frames race
(`VERIFICATION-REPORT.md` Track 1) — manually re-injected a fresh copy into
the same already-running process, worked immediately (same fix already
verified last session). Automatic-injection race remains open, out of scope
here.

**Real game, real negative result:** played two real games against "Dicer
Filip." With known ground-truth scores mid-match (600/350 banked), searched
`C_UIDice`, `PlayerModule`, `PlayerSoul` (`CombatSoul` included),
`ent`/`concept`/`db`/`dialog`/`behavior`/`xgen` — neither value appears
anywhere. **Confirmed: pull-based reflection cannot see the dice minigame's
live state**, same shape as combat's already-solved outbound problem.
Evidence committed as `tools/dice-probe-*.xml`.

Side finding: `PlayerSoul`'s own internal `Name` is `"Dude"` in this build —
resolves the old "Dude decoy" note from `NATIVE-PLUGIN-findings.md` (not a
lookalike soul, the player's own soul).

### R2 — find the logical dice

**Found `wh::playermodule::C_Dice`** by cross-referencing `PlayerModule.dll`'s
export table (`dumpbin /exports`) against the static RTTR dump — a real
game-logic controller class the dump itself missed, confirmed via one
exported method: `SetPauseWorldTime(bool)`.

**Attempted an inline hook on `SetPauseWorldTime`**, with the human's
explicit go-ahead, to capture a live `C_Dice*` instance (no exported
accessor reaches one; nothing imports it via any checked module's IAT, so
the already-proven IAT-hook technique had no attachment point). Verified the
hook site was safe via `dumpbin /disasm` (13 bytes, four complete
instructions, no internal jumps/RIP-relative operands) before installing.
**Installed cleanly against the human's live game — no crash — but never
fired across two real transitions** (finishing an in-progress game, starting
a fresh one). Clean negative: `SetPauseWorldTime` is almost certainly not
part of ordinary NPC gambling.

**Brought in Ghidra** (12.1.2, official release) + Temurin JDK 21 (Ghidra
needs 17+, machine only had Java 8) to properly recover `rttr::array_range<T>`'s
ABI by decompilation — the same discipline already used for
`variant`/`argument`/`instance`, just with a real disassembler instead of
`dumpbin`. Ran headless auto-analysis against `CrySystem.dll`, wrote
`native/ghidra_scripts/DumpArrayRangeFuncs.java` to decompile
`get_methods`/`get_properties`. **Recovered the real layout**: hidden sret
buffer's first two 8-byte slots are a plain `{begin, end}` pointer pair into
a contiguous array of 8-byte elements, directly usable as `Method::data`/
`Property::data`. Built this into `rttr_abi.h`/`.cpp` and a new
`probe_dice_class()` that asks rttr directly, by name, for every
method/property `C_Dice` has — no guessing.

**Final result: `C_Dice` is not RTTR-registered at all.**
`get_by_name` resolves without faulting; `is_valid` is false. Clean,
trustworthy negative (same shape as this project's own negative-control
discipline). **This closes the entire reflection-based path for `C_Dice`
definitively** — the class is real but was never hooked up to the
introspection system this project has been using all night, so no amount
of further tooling can read it. Likely reading: `C_Dice` belongs to a
scripted/quest dice context, not the "walk up to any NPC and gamble"
interaction this project needs (the `dice_gameLevel`/`dice_betType`/
`SpokeWithDicePlayers`-shaped enums found earlier read like flowgraph glue
for exactly that different context).

**R-gate reached, early, for Tier III+ specifically**, per the WO's own
instruction to stop before building past Tier II. Full tier verdict is in
`docs/WO-6-native-dice-findings.md` §"R-gate: Tier verdict": R2 exhausted
this session without success; Tier I/II are fully unblocked and unaffected;
Tier III+ is not proven unreachable but nothing tried tonight reached it —
the next concrete lead (not pursued tonight) is decompiling the real caller
of `C_UIDice::ShowDiceScore` with the now-working Ghidra pipeline.

### The design pivot

Presented the tier verdict to the human plainly (no jargon, per their
request). Their response reframed the actual goal in a way that sidesteps
the whole native-reflection problem:

- **Restrict to PvP only, at real dice tables.** NPC games stay exactly as
  they are today, untouched, full native experience. Only two real players
  gambling together triggers this mod's own dice UI.
- **The UI must be in-game/on-screen, never the launcher window.** Their
  explicit complaint about WO-5's existing `DiceWindow.razor`: "clunky,
  boring, and appears in the LAUNCHER, and not in the game." The launcher
  should be a launcher, full stop.
- **Wants better visuals/animation than the existing plan's plain
  `DrawText` overlay**, but understands (after the tradeoff was explained)
  that real sprite/texture-based dice needs its own small research spike
  (has the GUI module's image-drawing surface ever been checked? — no,
  never examined, per `PROJECT-STATE.md` §5.1), separate from and much
  lower-risk than tonight's `C_Dice` investigation, since it's about
  drawing this mod's *own* data, not reading the game's hidden state.

This is, functionally, **Tier II** (the WO's own guaranteed floor) with two
refinements: gated to real tables + PvP only (rather than "invite
anywhere"), and explicitly positioned as the actual deliverable rather than
a fallback — no further native reflection work needed to build it.

**Nothing was implemented for this yet** — the human asked for a
documentation handoff instead, to pass to a fresh session. See
`docs/SESSION-PROMPT-wo6-overlay-ui.md`.

### State at end of session

- `KCDMP.dll` is injected and alive in the currently-running game (multiple
  research copies actually — `native/build/KCDMP_dice3/`,
  `native/build/KCDMP_diceclass/`, plus earlier `KCDMP_retry`/`KCDMP_retry2/`
  — all harmless duplicates from iterative re-injection during this session,
  gitignored, not part of the repo). None of this matters for a fresh
  session: the game will need re-launching and re-injecting from scratch
  next time regardless.
- Ghidra 12.1.2 and Temurin JDK 21 are installed locally (not part of this
  repo — official-source installs, large binaries). See
  `native/ghidra_scripts/README.md` for how to reuse the pipeline.
- All suites untouched this session (no relay/protocol/engine changes) —
  still exactly as green as WO-5 left them.
- Full technical evidence trail: `docs/WO-6-native-dice-findings.md`.
