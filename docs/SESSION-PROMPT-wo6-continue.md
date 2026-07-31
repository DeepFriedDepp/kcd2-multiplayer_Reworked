# Session prompt — WO-6 continued: payout, native invite/accept, launcher

Paste everything below the rule into a fresh session. Working directory
`C:\Users\Jonasty\Documents\KCD2_MP`. Prefix commits `WO-6:`.

---

You are a senior engineer continuing an unofficial multiplayer mod for
*Kingdom Come: Deliverance II*. Repo `DeepFriedDepp/kcd2-multiplayer_Reworked`,
branch `main`. Read `docs/WO-6-progress.md` end to end before touching
anything — it is long; the **Session 3** entry at the end is the one that
matters, and it explains in detail why several things that look like
reasonable ideas (a native keyboard hook, reusing an "unclaimed" key without
testing it live) turned out to be wrong.

## The goal, and what's actually new this session

Two players walk up to a table and gamble against each other with
relay-authoritative Farkle. The engine, wire protocol, and — as of last
session — the presentation and input are **done and proven in real play**:
a real parchment-panel board, real F-key/U/F11/F12 bindings, a live opponent
bot for testing. This session is four specific, human-requested extensions,
not a rebuild of anything above. Do not touch the engine or wire protocol
outside item 1 below without stating why first, same rule as always.

## The repo, and how to get current

```
git clone https://github.com/DeepFriedDepp/kcd2-multiplayer_Reworked.git
git checkout main && git pull
```

Everything described here is pushed to `origin/main`. Two commits landed
last session, in order:

| Commit | What |
|---|---|
| `9cf7b9d` | real physical dice keybinds, live-board panel rework, bust visibility |
| `a144b93` | progress log for that session (read this narrative first) |

## State: all of last session's verify list is DONE and confirmed in real play

Not "committed, unverified" this time — the human played multiple full
matches against `tools/Bot-DiceOpponent.ps1` with the actual shipped build
and confirmed each of these directly:

- **Keybinds work, seated and standing, exactly as documented.** F2/F4/F5/
  F6/F7/F8 mark dice 1-6, F9 casts/sets aside, hold F11 banks, hold F12
  yields, U clears a pending selection without rerolling. These are real
  game action-map entries (`Libs/Config/keybindSuperactions.xml` +
  `Libs/Config/defaultProfile.xml`, both shipped in this mod's own pak), not
  a Lua-side guess — see Session 3 in the progress log for exactly how that
  works and why **both** files are required (an action declared in only one
  never fires).
- **The live board is the parchment panel again** (`hud.ShowTutorial`),
  debounced so marking rapidly does not flicker. Dice render as
  same-width pip grids separated by a thin divider; the human called the
  result "legitimately perfect."
- **Bust visibility works.** `FarkleGame.LastBustedDice` + a new trailing
  field on `DiceState` (0x17) mean the board now says "Bust! Rolled 2, 4, 6
  — nothing scored" instead of just "nothing scored" — this was a real
  engine + wire change, stated up front and confirmed in scope before it was
  made, same rule you should follow for item 1 below.

**F11 and F12 were deliberately chosen for bank/yield with room to spare —
U, Y, F1-F12 minus the debug-bound ones were all live-tested this session.**
The point that matters for items 2 and 3 below: **F11/F12 are already
taken** (bank/yield), so invite-accept/decline need their own keys, found
the same way — see "How to find a safe key" below.

## Reading order

1. `docs/WO-6-progress.md`, **Session 3** — the whole narrative: the native
   keyboard hook attempt and exactly why it cannot work on this game
   (DirectInput exclusive capture while focused), the keybind mechanism that
   does work, every key trap found (`Numpad /` **crashes the game** — do not
   retest it), the panel rework, the bust-visibility change.
2. `docs/NATIVE-PLUGIN-findings.md` — read fully before starting item 1. This
   is the evidence that native writes to game state work at all (NPC health,
   damage, death — all verified by observed effect, not a call returning
   success) while the same thing through Lua is inert. Money/currency has
   **never been probed** — item 1 starts from zero here, not from a proven
   surface the way combat did.
3. `docs/WO-5-dice.md` — engine, protocol, IPC, still the baseline reference
   for the Farkle engine and wire format.
4. `docs/kcd2_lua_api.md` — the Lua surface, including why `UIAction`/native
   HUD calls are push-only and what that does and doesn't let you draw.

## The four things requested for this session, in the human's own priority order

### 1. On a Farkle loss, transfer the wager to the winner

**This needs a design decision before it needs code — get it from the human
first, do not assume.** Right now a Farkle match tracks pure abstract
score; no real in-game currency (groschen) is staked or moves at any point.
Questions to resolve before writing anything:

- Is there an actual up-front stake (both players' money escrowed at
  invite/accept time, paid out to the winner at the end), or does the
  *loser's* money move to the winner post-hoc, and if so — how much? A
  fixed amount? Tied to `TargetScore`? Player-chosen at invite time (the
  `Invite` packet already carries a `[targetScore:2][debugSeedOverride:4]`
  config trailer — extending it is precedented)?
- What happens if the loser doesn't have enough money?
- Does this need a NEW wire message (e.g. confirming both sides agreed to a
  stake before the match starts), or can it hang entirely off the existing
  `DiceEnd` (0x19) transition, applied natively by each client for its own
  local player only (mirroring how combat damage is applied locally, never
  trusted from the peer)?

**Technically:** per `docs/NATIVE-PLUGIN-findings.md`, Lua cannot write game
state that sticks — this has to go through the native plugin (`KCDMP.dll`),
the same RTTR-by-name mechanism that already proves out for NPC health/
damage/death. Money has never been located via RTTR in this project before;
expect an R0/R1-shaped research pass (find the player's currency property —
likely on the player's `RPGModule`/inventory soul — via the same
`get_by_name`/`get_property` walk `rttr_abi.cpp` already does for combat) before any write is attempted. Read `native/KCDMP/rttr_abi.cpp` and
`rttr_probe.cpp` for the established pattern; do not start from scratch.

### 2 & 3. Native invite-send and invite-accept/decline, no console command

Currently `mp_invite dice` / `mp_accept` / `mp_decline` are the only
verified-working paths — the actual keybinds
(`DICE_INVITE_ACTIONS = dialog_answer3/4`, `ACCEPT_ACTIONS`/`DECLINE_ACTIONS`)
are unverified guesses inherited from WO-5, most likely dead. **The fix is
the exact technique proven this session for cast/mark/bank/yield** — do not
reach for a different approach:

1. Pick candidate keys **not already claimed** — grep every `input="..."`
   value across both `Libs/Config/keybindSuperactions.xml` and
   `Libs/Config/defaultProfile.xml` (the base game's copies, extracted from
   `Data/IPL_GameData.pak` the same way Session 3 did — see that entry for
   the exact `unzip` commands) first, but **do not trust XML absence as
   proof of safety by itself** — F1/F3/F10, the Numpad operator keys, `H`,
   and `Numpad /` were ALL "clean" by that check and were respectively photo
   mode, flight mode, AI debug draw, a debug menu, and a full game crash.
   Every candidate must be pressed live, one at a time, with
   `KCD2MP.logActions = true`, and watched for *any* visible effect before
   being trusted — this cost real time to learn twice already.
2. Add a new `<superaction>` to `keybindSuperactions.xml` with a new action
   name (e.g. `kcd2mp_dice_invite`, `kcd2mp_dice_accept`,
   `kcd2mp_dice_decline`) on the chosen key, `map="interaction"` (proven
   still active seated or standing) unless a reason emerges to pick a
   different map.
3. **Also add the matching `<action>` entry to `defaultProfile.xml`'s
   `interaction` actionmap** with `keyboard="_keybinds_ref_"`. Skipping this
   is the single mistake that cost the most time last session — an action
   declared only in `keybindSuperactions.xml` registers nowhere and never
   fires, silently, with no error anywhere.
4. Wire the new action name into `handleAction` in `kdcmp.lua`
   (`KCD2MP_InviteDiceAtTable`/`KCD2MP_AcceptInvite`/`KCD2MP_DeclineInvite`
   already exist and do the real work — this is just giving them a real key
   instead of only a console command).
5. Update `Build-And-Install-Mod.ps1`'s `$Files` list if any new file paths
   are introduced (unlikely — both XML files already exist and just need
   more entries).

F11 and F12 are free. Beyond those, treat every other key as unproven until
tested live per step 1.

### 4. Improve `KCDMP_launcher` to fetch its own dependencies

Lowest priority of the four, per the human. Currently starting a match
means manually running `dotnet run --project dotnet\KcdMp.Server` and
`dotnet run --project dotnet\KcdMp.Client` by hand in separate terminals.
**Build on the existing launcher** (`KCDMP_launcher/`, Blazor/Photino) —
do not start a new one. Scope (dependency detection/fetching, whether it
should also start the relay/agent as child processes, etc.) is not decided;
get the human's actual intent before designing this one, it was stated in
one line and needs unpacking.

## How to find a safe key (do this before binding anything)

```
# in-game console, or via the debug API (tools/KcdApi.ps1 has helpers):
#KCD2MP.logActions = true
```

Press the candidate once, then check `kcd.log`:

```powershell
Select-String "ACT '" (Get-ChildItem "D:\SteamLibrary\steamapps\common\KCD2Mod\kcd.log").FullName | Select-Object -Last 10
```

An empty result is *not* proof of safety by itself if the effect is purely
visual/native (the debug-menu and crash traps produced no `ACT` line at
all) — also just watch the screen. If you have the game's debug REST API
running (`http://localhost:1403`), you can drive this check yourself via
`tools/KcdApi.ps1`'s `Invoke-KcdApi` without needing the human to type
anything, the way Session 3 did for the `[DIAG]` markers — but you still
need the human physically at the keyboard to press the candidate key and
tell you what appeared on screen; you cannot press keys for them.

**Never suggest `Numpad /` again. It crashes the game.**

## Traps carried forward (all from Session 3, full detail there)

- A native `WH_KEYBOARD_LL` hook **cannot see any key at all** while KCD2
  has focus — the game reads input via exclusive DirectInput, which never
  generates the Win32 message-level events that hook taps into. Don't
  re-attempt this; if physical input is ever needed and the
  `keybindSuperactions.xml`/`defaultProfile.xml` route genuinely can't cover
  something, that's a much bigger native undertaking (hooking DirectInput's
  own device-state calls) and needs its own scoped investigation.
- A UTF-8 BOM silently kills the whole Lua file — always write with
  `New-Object System.Text.UTF8Encoding($false)`.
- `ShowTutorial` is a notification queue; `HideAllTutorials` before every
  push, `KCD2MP_DiceRender()` for state that's already paced by relay
  timing, `scheduleRender()` for anything locally rapid-fire.
- XML comments cannot contain `--` anywhere inside them, not just at the
  end — hit repeatedly this session in both `Libs/Config/*.xml` files
  because this project's own prose convention uses `--` as an em-dash.
  Use `:` or a plain sentence break instead when writing XML comments.
- The debug console silently drops oversized/complex chunks — build long
  strings in ~150-character pieces.
- A DLL already loaded into a running game cannot be swapped; the game must
  be closed and reopened for a native rebuild to take effect, every time.

## Environment

Game via the **KCD2 Modding Tools** Steam entry
(`D:\SteamLibrary\steamapps\common\KCD2Mod`), not the base game. GPLv3 fork.
`$env:DOTNET_ROOT = "$env:USERPROFILE\.dotnet-sdk8"; $env:PATH = "$env:DOTNET_ROOT;$env:PATH"`
before any `dotnet` command. Suites all green as of `9cf7b9d`: Farkle 59/59,
`Test-Dice` 10/10, `Test-Sessions` 22/22, `Test-Combat` 14/14.

To test any input change against a real session with no second human:
```powershell
dotnet run --project dotnet\KcdMp.Server -- --port 7778        # separate window
dotnet run --project dotnet\KcdMp.Client -- --host localhost --port 7778 --no-voice   # separate window, bridges the real game
powershell -ExecutionPolicy Bypass -File tools\Bot-DiceOpponent.ps1                    # third window, scripted opponent
```
Then `mp_dice` in-game to challenge the bot.
