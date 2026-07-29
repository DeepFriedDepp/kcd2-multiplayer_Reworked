# Session prompt — WO-6 continued: in-game PvP dice overlay

Paste everything below the rule into a fresh session, working directory
`C:\Users\Jonasty\Documents\KCD2_MP`. Prefix commits `WO-6:`.

This supersedes the *build* portion of
`docs/SESSION-PROMPT-wo6-native-dice.md` (Phase 1/2/3 and the tier ladder)
based on a design decision made at the end of the research session that
produced `docs/WO-6-native-dice-findings.md` and `docs/WO-6-progress.md`.
Read both of those before writing any code — they are the evidence trail
behind every "do not relitigate" item below.

---

You are a senior engineer continuing an unofficial multiplayer mod for
*Kingdom Come: Deliverance II*. Repo `DeepFriedDepp/kcd2-multiplayer_Reworked`,
branch `main`. Dice (Farkle) works end to end today — relay engine (59
tests), sessions (`Test-Dice.ps1` 10/10), agent↔launcher IPC proven — but the
UX lives in a Blazor window in the launcher (`KCDMP_launcher/DiceWindow.razor`).
This session replaces that with an in-game overlay.

## What was already tried, and why it's closed — do not relitigate

A prior session spent significant effort (including bringing in Ghidra to
properly reverse-engineer the RTTR ABI) trying to make this mod render the
game's own native dice-table UI for a remote player's turn — reading the
real minigame's live state (dice values, scores) via reflection so it could
be mirrored. **This is closed, with strong evidence, not abandoned from
fatigue:**

- Pull-based reflection cannot see the dice minigame's live state anywhere —
  confirmed against a real game with known ground-truth scores (600/350
  banked), searched across every reachable reflection root.
- The one real lead found (`wh::playermodule::C_Dice`, a genuine
  game-logic controller class) is **not RTTR-registered at all** — a clean,
  trustworthy negative, confirmed by asking rttr directly via a properly
  Ghidra-recovered `array_range<T>` ABI, not a guess.
- An inline hook on `C_Dice::SetPauseWorldTime` (the only method found on
  it) installed cleanly against a live game but never fired during ordinary
  NPC gambling across two real transitions.

Full evidence: `docs/WO-6-native-dice-findings.md`. **Do not re-attempt
reading the native minigame's state.** If a future session wants to revisit
Tier III+ (native-looking dice, real physics), the one recorded, untried
lead is decompiling the real caller of `wh::guimodule::C_UIDice::ShowDiceScore`
with the now-working Ghidra pipeline (`native/ghidra_scripts/README.md`) —
that is real, open-ended reverse-engineering work and is explicitly **out of
scope for this session**.

## The actual target for this session

Presented with the tier verdict above, the human reframed the goal in a way
that needs none of the closed-off native-reflection work:

1. **PvP-only, at real dice tables only.** NPC dice games are untouched —
   full native experience, exactly as today. This mod's dice UI only
   triggers when two real players are gambling with *each other* at a real
   in-world dice table.
2. **In-game / on-screen for the client. Never the launcher window.** The
   human's explicit complaint about the existing `DiceWindow.razor`:
   "clunky, boring, and appears in the LAUNCHER, and not in the game...
   The launcher should be only that; a launcher, to launch the MP Mod."
   Retire the launcher window as the primary dice UX. It may stay as a
   debug mirror if that's cheap, but is not the deliverable.
3. **Better visuals than a bare `DrawText` dump, with some animation.**
   Not required to match the native game's polish — just needs to feel
   designed, not like a debug printout.

This is, functionally, **Tier II** from the original WO (the guaranteed
floor: "full match on a DrawText/DrawLabel overlay driven by in-game keys...
must work even if every higher tier dead-ends") with two refinements:
gated to real tables + PvP only, and treated as the actual deliverable
rather than a fallback. Nothing about it needs further native reflection
work — it renders data this mod's own relay-authoritative Farkle engine
already fully owns and controls.

## What already exists to build on

- **The engine and wire protocol are done and proven.** `dotnet/KcdMp.Farkle`
  (59 xUnit tests), the relay's `DiceIntent`/`DiceState`/`DiceError`/`DiceEnd`
  packets (`0x16`-`0x19`, see `dotnet/KcdMp.Protocol/Protocol.cs`), all
  verified against a real relay (`tools/Test-Dice.ps1`, 10/10) and with two
  real agent processes over real IPC. **None of this needs to change** —
  this session is presentation-layer only. Read `docs/WO-5-dice.md` for the
  full architecture before touching anything.
- **The agent↔launcher IPC** (`DiceIpcClient`/`DiceIpcServer`,
  `DiceIpcState`) is what currently feeds `DiceWindow.razor`. Decide during
  this session whether it's worth keeping as a debug mirror or should be
  removed along with the window — either is defensible, but say which and
  why rather than leaving it half-connected.
- **In-game drawing primitives already proven in `kdcmp.lua`:**
  `System.DrawText(x, y, text, size)` (screen-space — used for the invite
  toast, dice turn hint stub, ping display) and `System.DrawLabel({x,y,z},
  size, text, r,g,b,a)` (world-space). Both are real, working, low-risk.
- **The existing turn-hint stub.** `PROJECT-STATE.md` §5.1 already notes "a
  one-line `DrawText` turn hint... exists, but only as a glance-without-
  alt-tabbing convenience alongside the launcher window, not as the dice UI
  itself" — this session turns that into the actual UI.

## What needs deciding/building this session

1. **Identify real dice tables**, not "invite anywhere." Probe how tables
   are represented in the game's entity/reflection data (REST `?depth=0/1`
   through `tools\KcdApi.ps1`, or probed Lua entity queries) — never invent
   a query, run it and read the result, same discipline as everything else
   in this project. If tables genuinely aren't reliably identifiable, fall
   back to a proximity heuristic and say so honestly, but try the real
   query first.
2. **Gate the mod's dice UI to PvP at those tables.** Reuse the existing
   session/invite framework (WO-2) exactly as today's `mp_invite dice` does
   — the gating logic is "only offer/accept this at a real table," not a
   new invite mechanism.
3. **Design and build the in-game overlay itself.** Minimum bar: dice
   faces, kept vs. free state, turn banner, running/final scores, bust/win,
   all legible and not a raw debug dump. `DrawText`/`DrawLabel` are the
   proven baseline — use them well (layout, color via the RGBA params
   `DrawLabel` already takes, redraw-driven simple animation like a "roll"
   flicker or fade transitions on state change).
4. **Optional, timeboxed research spike: can Lua draw an image/texture/sprite
   at all**, not just text? This has never been checked (`PROJECT-STATE.md`
   §5.1: "the GUI module's reflected surface was never examined" — that
   statement is about the *native* reflected surface, which is closed per
   above; this is a different, much lower-risk question about what the
   *Lua* API itself exposes for drawing, which is a presentation capability
   check, not a state-reading one). If a real image-drawing primitive
   exists, it would let dice look like dice instead of styled characters.
   **This must not block shipping the `DrawText`-based version** — timebox
   it, and ship the proven version regardless of the outcome.
5. **Push `DiceState` into the overlay.** The agent already has the full,
   correct state from the relay; get it into Lua over the existing WO-1
   transport (log-tail out, `ExecuteString` in) the same way ghost
   positions and the invite toast already flow. State the per-update cost
   honestly; at 2-4 players it should be trivially within budget, per the
   original WO's own note.
6. **In-game intent keys** (roll / toggle-keep / bank / forfeit), discovered
   via the documented keybind procedure (`KCD2MP.logActions = true` → press
   key → read `ACT` from `kcd.log`), never invented. `mp_invite dice`-style
   console fallback if a clean key can't be found, stated honestly.

## Can this be built without the game open?

**Mostly, yes** — this was asked explicitly and matters for scheduling. The
Lua overlay rendering logic, the C# agent-side `DiceState`→Lua push
plumbing, and the table-identification *query construction* can all be
written and code-reviewed without a running game. What genuinely needs the
game running: discovering the real dice-table entity shape (step 1),
finding the real in-game keybind (step 6), the texture-drawing spike (step
4, if attempted), and obviously any visual/manual verification. Structure
the session so the no-game-needed work happens first and the
game-needed work is batched into clearly-marked steps, so a human can pick
up the game-dependent parts separately if needed.

## Read first

1. `docs/WO-6-progress.md` — full narrative of the research session that
   led here, including the exact conversation that produced this pivot.
2. `docs/WO-6-native-dice-findings.md` — the evidence closing off native
   reflection for dice; read this before considering any native work.
3. `docs/WO-5-dice.md` — the engine/protocol/IPC this session builds a new
   presentation layer on top of. Do not modify the engine or wire protocol
   without a clear reason, stated up front.
4. `docs/PROJECT-STATE.md` — corrections to the original brief, current
   state ledger.
5. `docs/kcd2_lua_api.md` — what's documented about the Lua API surface,
   including `UIAction`/element listeners if the texture-drawing spike goes
   there.

## Durable context (carried forward)

**Traps:** stale injected DLL keeps the pipe — test rebuilt DLLs against a
restarted game; PowerShell case-insensitivity and `Object[]` range indexing;
REST always with `?depth=` via `tools\KcdApi.ps1`; running relay/agent locks
build output; `$env:DOTNET_ROOT = "$env:USERPROFILE\.dotnet-sdk8"; $env:PATH
= "$env:DOTNET_ROOT;$env:PATH"` before any `dotnet` command.

**Environment:** game via the KCD2 Modding Tools Steam entry
(`D:\SteamLibrary\steamapps\common\KCD2Mod`); one machine, one game copy, no
second human today — PvP-specific behavior (two real players at one table)
is designed now, verified when a second machine/human exists, marked
unverified until then, same as everything else in this project.

## Definition of done

- Table-identification approach documented with evidence (real query result
  or honest fallback), not invented.
- In-game overlay renders a full match: dice, keep state, turn banner,
  scores, bust/win — reviewed for legibility and basic visual polish, not
  just functional correctness.
- Launcher window's role decided explicitly (removed, or kept as a
  documented debug mirror) — not left ambiguously half-wired.
- PvP/table gating verified against the existing session framework; NPC
  dice games confirmed untouched.
- All existing suites still green (`Test-Combat`, `Test-Sessions`,
  `Test-Dice`, `Test-Pipe`).
- `docs/WO-6-progress.md` appended before session end.
