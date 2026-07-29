# WO-6 native dice — research findings

Investigation started 2026-07-28 against KCD2 v1.5.2 (or whatever's current at
session start), Modding Tools build, game running with a save loaded.
Following the methodology of `NATIVE-PLUGIN-findings.md`: proven / unverified
/ guessed, evidence per claim, negatives recorded.

---

## R0 — framework/dependency scout (timeboxed)

Searched Nexus Mods and GitHub for existing community native
frameworks/plugin-loaders/hooks that might expose the minigame or UI layer,
per the WO's "dependencies are encouraged" instruction.

| Candidate | What it is | License | Verdict |
|---|---|---|---|
| [`googleben/kcd2_rttr_dumper`](https://github.com/googleben/kcd2_rttr_dumper) | Offline tool that dumps RTTR type info from a live process or a full minidump into a pseudo-C++ listing (`out.cpp`, committed to the repo, ~57k lines) | **none set** (GitHub reports `license: null`) | **Not vendored** — no license to vendor under. Used read-only as a research reference (downloaded to local scratch space, not committed to this repo) to shortcut R1's surface-mapping. Author's own README admits it's "quick and dirty" and may miss or misreport properties (RTTR's `constexpr std::array` members defeat static offset recovery) — treat every claim sourced from it as **unverified** until confirmed live. |
| [`violetanvil/kcdx`](https://github.com/violetanvil/kcdx) | SKSE-style script extender: declarative function hooking, Address Library (name→address resolution), Lua+C++ parity, pub/sub messaging | GitHub license API returns `"other"/NOASSERTION` despite repo claiming MIT informally | **Declined.** General-purpose hooking/memory framework, still early (58/60 internal tests passing, some features unimplemented). This project already has a working, proven native plugin (`KCDMP.dll`: IAT hook, hand-modelled RTTR ABI, agent pipe) — adopting a third-party script-extender wholesale would mean a large rewrite for no capability this project doesn't already have. Its Address Library approach is worth remembering as a fallback idea *if* R3/R4 hit the "outbound problem" (an unexported function that needs hooking without a hand-recovered offset), but not adopted now. |
| [`JerryYOJ/KCSE-for-kcd2`](https://github.com/JerryYOJ/KCSE-for-kcd2), [`xiaoxiao921/KCD2ModLoader`](https://github.com/xiaoxiao921/KCD2ModLoader) | Similar script-extender / Lua-mod-loader frameworks | Unchecked | **Declined**, same reasoning as kcdx — general loaders, no minigame-specific capability, would replace a working mechanism rather than extend it. |
| [`souky-byte/kcd2-modding-docs`](https://github.com/souky-byte/kcd2-modding-docs) | Community modding documentation, 15+ mods analyzed | Per-repo, not unified | **Declined** — doesn't cover the dice minigame, GUI/Scaleform module, or minigame-adjacent RTTR types. Checked directly, not just by title. |

**Outcome: no dependency adopted.** Nothing found exposes the minigame or UI
layer more directly than probing it ourselves. The RTTR dumper's static
output is useful as an offline map to decide *where* to point live probes
(see below) but is not a substitute for them and is not part of this repo.

---

## R1 — mapping the reflected surface (read-only, in progress)

### Static lead: `wh::guimodule::C_UIDice`

From the (unlicensed, unvendored) RTTR dumper's static output, a real
reflected UI class exists:

```
class wh::guimodule::C_UIDice : class wh::guimodule::C_UIBase {
    ShowDiceScore( int, string const &, int, int, int, string const &, int, int, int, int, int, string const &, int, int );
    HideDiceScore( );
    ShowDiceProperties( string const &, int );
    HideDiceProperties( );
    SetCurrentPlayer( bool );
};
```

No properties recovered statically — only methods. `ShowDiceScore`'s 14
parameters are the strongest available clue about data shape before any live
game is observed: they look plausibly like (total, playerName, ..., some
per-die or per-player breakdown, ..., opponentName, ...) but this is a
**guess**, not yet confirmed against an actual screen.

Also present statically, evidence these are real registered rttr types (not
dumper noise): enums `DiceGameState` (`Inactive/Queued/Starting/InProgress`),
`DiceMinigameResult` (`None/PlayerWon/PlayerLost/PlayerLeft/GameInterrupted`),
`DiceResult`, `dice_minigameResult`, `dice_gameLevel`, `dice_betType`,
`dice_initDialogResultType`, `dice_badgeEffects`. These read like
flowgraph/UIAction node parameter enums (quest scripting glue), not
necessarily live queryable state — **unverified which, if either**.

A `wh::playermodule::I_Minigame` / `C_Minigame` base pair exists, with
**one** concrete subclass found statically: `C_Pickpocketing`. No
`C_Dice`/`C_DiceGame`/similar subclass was found anywhere in the static dump.
Either dice doesn't use this base (state machine is elsewhere, maybe pure
Lua/flowgraph), or the dumper missed it. Unresolved.

### Live confirmation via the debug REST API (`localhost:1403`)

Following `NATIVE-PLUGIN-findings.md`'s method exactly — walk the reflection
browser, always with `?depth=`.

- `GET /api?depth=1` — module roots include `GUIModule`/`gui`,
  `PlayerModule`/`player`, alongside the already-known `RPGModule`/`rpg`,
  `XGenAIModule`/`xgen`, `EntityModule`/`ent`.
- `GET /api/gui?depth=1` — `GUIModule.UIElements` is a live 31-element vector
  of singletons, index 22 is `C_UIDice` (confirmed by name match against
  `UIElementsByName`). Sibling elements include `C_UIPickpocketing`,
  `C_UIShop`, `C_UIShootingContest` — the game's other minigames follow the
  same one-singleton-per-minigame-type pattern.
- `GET /api/gui/UIElements/22?depth=2` — **`<C_UIDice />`, empty at depth 2.**
  Confirms the static finding live: **`C_UIDice` genuinely has zero
  reflected properties**, not a dumper gap. Same test against
  `C_UIPickpocketing` (index 26) — also empty at depth 2. This is a real
  pattern across this whole minigame-UI family, not specific to dice.
- `GET /api/player?depth=1` — `PlayerModule` exposes only
  `RandomEventManager` and `TutorialManager` as static singletons. No
  minigame instance reachable from this root while no game is in progress.

**Working conclusion (unverified until a live game is diffed against
this baseline): the dice minigame's C++/reflected surface is presentation-only
and one-directional (something pushes 14 values *into* `C_UIDice` via
`ShowDiceScore`; `C_UIDice` does not hold or expose game state for reflection
to pull back out).** If true, this is the same shape as the "outbound
problem" already solved for combat (`TakeDamage` not exported, solved by
sampling) — reflection alone may not find the logical dice values; whoever
*calls* `ShowDiceScore` holds them, and that caller is not yet located.

This is exactly why R1 needs the human playing: nothing reachable from a
static root shows what exists only while a game is active. **Next: snapshot
`gui/UIElements/22`, `player`, and the player's own soul record before
sitting, at the table, mid-roll, on the keep screen, on bank, and on win,
diffing each against this baseline**, per the WO's protocol.

---

## R-gate: Tier verdict

Not reached. Gates all builds above Tier II per the WO.
