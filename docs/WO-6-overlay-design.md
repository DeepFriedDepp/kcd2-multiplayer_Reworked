> ## SUPERSEDED IN PART — read this first
>
> This document specified a panel **drawn by us** with `System.DrawText` and
> `System.Draw2DLine`. Against the real game, **`Draw2DLine` renders nothing**
> (registered, callable, silent, and not CVar-gated — see the CORRECTION section
> of `docs/WO-6-visual-capability.md`). Everything here that depends on drawing
> lines is therefore dead: the oak frame, the bevels, the nailheads, the laid
> ground, the leader rules, the vector dice, and most of the motion table in §4
> (shake, flash, expanding frame, per-die travel).
>
> **What shipped instead:** HTML pushed into the game's own tutorial panel via
> `hud.ShowTutorial` — a gilded gothic frame around illuminated parchment,
> rendered by the game. See `WO-6-visual-capability.md` for the capability table.
>
> **What survives here and is still authoritative:** §1's diegetic language
> ("The Wager", "on the board", "set aside", groschen framing), §2's palette
> (re-expressed as HTML `<font color>` hex, which works), §5's state model in
> full, §6's fall-back-by-default rule for native panels, and §7's input feel.
>
> **What changed in §3 (type):** the panel uses Scaleform's embedded font
> library, not the CryFont `subtitles`/AlexanderQuill. `Manuscript` is a real
> blackletter face and is available via `<font face>`. The tofu warning about
> Unicode die faces was correct and now applies to far more characters — the
> verified glyph inventory is in the capability doc.
>
> **What changed in §4 (motion):** motion is now a small number of deliberate
> re-pushes (the cast tumbles over ~450 ms) plus `hud.ShowInfoText` for the
> moments that want to punch. Coarser than an 8 ms redraw, and honest about it.

# WO-6 — in-game dice overlay: art direction and state model

The design the overlay is built to. Settled before writing it, per the WO's
"design first, then build." Capability evidence is in
`docs/WO-6-visual-capability.md`; this document is the *look*.

Target: a stranger glancing at the screen mid-match should read **a game's dice
UI**, not a mod's HUD overlay. Order of priority: **legibility, then character,
then motion** — all three required.

---

## 1. The object

The interface is a **thing on the table**, not text floating in space: a
wager-board of oak and iron, with a parchment score slip pinned to it and a
felt tray for the dice. It sits low and centre, where a real board would be if
you were sitting at the table — not in a HUD corner.

```
        ┌───────────────────────────────────────────────┐   <- oak frame, double rule
        │  ╤═══════════════ THE WAGER ═══════════════╤  │   <- iron nailhead corners
        │                                               │
        │   Dicer Filip .................  350          │   <- opponent, leader dots
        │ > Jonas ........................  600         │   <- '>' = whose turn, gold
        │                              of 2 500         │
        │  ─────────────────────────────────────────    │   <- hairline rule
        │   ON THE BOARD                 SET ASIDE      │
        │   ┌──┐ ┌──┐ ┌──┐ ┌──┐          ┌──┐ ┌──┐      │   <- dice: vector, pipped
        │   │ ●│ │● │ │●●│ │●●│          │ ●│ │ ●│      │
        │   └──┘ └──┘ └──┘ └──┘          └──┘ └──┘      │
        │                                               │
        │   this hand  250                              │
        │  ─────────────────────────────────────────    │
        │   [E] cast   [1-6] set aside   [B] hold: bank │   <- action strip, iron
        └───────────────────────────────────────────────┘
```

Everything above is drawn with `System.Draw2DLine` (frame, rules, dice, pips,
nailheads) and `System.DrawText` (all glyphs). No images — there is no image
primitive (`docs/WO-6-visual-capability.md`, Route 2 negatives).

**Diegetic language, not generic fantasy.** "The Wager" not "Dice Game". "On the
board" / "set aside" not "free" / "kept". "Cast" not "roll". Scores framed
against the target as *"of 2 500"*, groschen-style with a thin space. The
opponent is titled, not labelled — their name stands alone as a gambler's name
would on a tally board.

## 2. Palette

Pulled to KCD2's own HUD register: aged parchment, oak, iron, candle-warm gold,
tavern shadow. Values are linear 0..1 RGB as the draw calls take them.

| Name | RGB | Used for |
|---|---|---|
| `shadow` | `0.06 0.05 0.04` | panel ground, drop lines under every rule |
| `oak` | `0.34 0.24 0.14` | outer frame |
| `oakLit` | `0.52 0.38 0.22` | frame top/left bevel (light from above-left) |
| `iron` | `0.42 0.41 0.39` | nailheads, action strip, die borders |
| `parchment` | `0.86 0.79 0.63` | body text, die faces |
| `ink` | `0.13 0.10 0.07` | pips, text on parchment |
| `gold` | `0.85 0.68 0.30` | active player, headings, rules |
| `goldBright` | `1.00 0.86 0.45` | winner flourish, kept-die lock flash |
| `blood` | `0.62 0.13 0.11` | bust |
| `dim` | `0.38 0.34 0.28` | inactive player, spent hints |

Light comes from **above-left**, consistently: every bevel is `oakLit` on its
top and left edges and `shadow` on its bottom and right. That single rule is
what makes flat lines read as a carved object.

## 3. Type

`System.DrawText`, font `"subtitles"` — the CryFont bound to the game's own
`AlexanderQuill.ttf`, which already carries a 1 px black shadow pass.

| Role | Size | Colour |
|---|---|---|
| Panel title | 2.6 | `gold` |
| Player names | 2.0 | `gold` active / `parchment` idle |
| Scores | 2.4 | `parchment`, `goldBright` while ticking |
| Section captions | 1.4 | `dim`, letterspaced by manual gaps |
| Action strip | 1.6 | `parchment`, key glyphs in `gold` |
| Banner | 3.0 | `gold` |

**Trap, recorded before it can be made:** do **not** use the Unicode die faces
`⚀`–`⚅`. `AlexanderQuill.ttf` will not have those glyphs and they render as
tofu. Dice are drawn as vector squares with vector pips, always.

Two degradation paths, both harmless:

- If this build's `DrawText` turns out to keep the legacy 4-argument form, the
  font and per-string colour are lost — **layout, framing and every dice face
  are unaffected**, because all of that is `Draw2DLine`, which takes RGBA
  unconditionally. Controlled by `KCD2MP.dice.richText`.
- If `Draw2DLine`'s coordinate space is not what the probe expects, one constant
  changes. All layout is authored in a normalised 0..1 design space and mapped
  through `sx()`/`sy()`, so the whole panel moves together.

## 4. Motion — a moment for every transition

Motion is a requirement, not polish. The rule: **no state ever changes
instantly.** Everything is redraw-driven off `os.clock()` deltas inside the
existing label tick, so there is no new timer and no new failure mode.

| Transition | Moment | Duration |
|---|---|---|
| **Cast** | each die flickers through random faces, then settles — staggered so they land left to right, with a small vertical hop that damps out | 250 ms + 70 ms per die |
| **Set aside** | die travels from board row to the set-aside row on an ease-out, with a `goldBright` flash on its border that decays | 220 ms |
| **Un-set-aside** | the same journey backwards, no flash — reversibility must *look* reversible | 220 ms |
| **Score change** | the displayed number lerps toward the real one and is drawn rounded, so it counts up; colour rides `goldBright` → `parchment` as it settles | 500 ms |
| **Turn hand-off** | a banner slides in from the left, holds, fades. The active row's `>` marker and gold move across | 1 800 ms |
| **Bust** | the whole panel shakes (decaying ±6 px), a `blood` wash flashes over the ground, "FARKLE" strikes across the board row | 700 ms |
| **Win** | a second frame expands outward from the panel edge in `goldBright`, the winning score pulses, the loser's dims | 1 400 ms |
| **Open / close** | the panel rises from below and its alpha ramps; closing reverses | 300 ms |

Everything is driven by one `anim` table of `{startedAt, kind, payload}` plus
per-die `{fromX, fromY, startedAt}` — no tweening library, no coroutines.

Easing is one function, `easeOut(t) = 1 - (1-t)^3`. Used for every move. Shake
and flash use `(1-t)` linear decay.

## 5. State model

The overlay renders **only** what the relay sent. It never computes a score, a
roll, or whose turn it is — same rule `DiceClient` follows on the C# side.

```
KCD2MP.dice = {
  open       = bool,      -- panel visible at all
  role       = 0|1,       -- OUR role: 0 initiator, 1 acceptor
  turnRole   = 0|1,       -- whose turn, from the snapshot
  scores     = {[0]=n, [1]=n},
  shown      = {[0]=n, [1]=n},   -- animated, lags scores
  turnTotal  = n, shownTurn = n,
  target     = n,
  phase      = n,         -- DicePhase from the wire
  free       = { faces… },   -- on the board
  kept       = { faces… },   -- set aside
  sel        = { bool… },     -- OUR pending keep selection, local only
  peer       = "name",
  anim       = { … },
  outcome    = nil | "win" | "lose" | "forfeit",
}
```

`sel` is the one piece of state the overlay owns rather than mirrors: which dice
the player has *marked* before submitting a Keep. It is local, it resets on
every new snapshot, and it is never authoritative — the relay validates the mask
and can reject it, which arrives as a `DiceError` and shakes the board row.

**Turn gating.** When it is not our turn, the action strip greys to `dim` and
selection is refused with a short shake. The panel stays fully legible — a
spectator's view of the opponent's turn is half the drama and must not be
hidden.

## 6. Native panels layered on top

Per `docs/WO-6-visual-capability.md`, each of these is an *optional upgrade over
a working drawn equivalent*, enabled only if its probe passed. The drawn version
is never removed.

| Moment | Native upgrade | Falls back to |
|---|---|---|
| Invite | `ApseModalDialog.OpenQuestionDialog` — real yes/no, real callbacks | the drawn toast + `mp_accept`/`mp_decline` |
| Turn hand-off | `hud.ShowInfoText` | the drawn banner |
| Bust / win sting | `hud.ShowSkillCheckResult` | the drawn flash and flourish |
| Score board | `hud.ShowDiceScore` | the drawn score slip |

Flags live in `KCD2MP.dice.native = { modal=false, infotext=false, sting=false,
score=false }`, **all default false** until the probe says otherwise. Nothing
ships enabled on a guess.

## 7. Input

| Action | Key | Why |
|---|---|---|
| Cast | one press | the common action, must be frictionless |
| Set aside die *n* | `1`–`6` | obviously reversible — press again to un-set |
| Bank | **hold** ~600 ms, with a filling arc | deliberate; ends the turn and cannot be undone |
| Forfeit | hold ~1200 ms | hard to hit by accident; concedes the match |

Real action names are discovered with the documented procedure
(`KCD2MP.logActions = true` → press → read `ACT` from `kcd.log`), never invented.
Until then every action also has a console command in the `mp_invite` style,
and those are the supported path.
