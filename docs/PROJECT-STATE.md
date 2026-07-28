# Project state — supersedes the original engineering brief

Current as of 2026-07-28, branch `main`, pushed to
`DeepFriedDepp/kcd2-multiplayer_Reworked`.

**Read this before the original brief.** The brief remains the best statement of
*intent*, but several of its factual sections are now wrong — it predates the
native plugin, and a fresh session that trusts §3/§4/§5.2 will design around
limits that no longer exist, or re-derive dead ends at length.

---

## 1. Work order ledger

The brief numbered six work orders. Actual state:

| Brief WO | Scope | State | Where |
|---|---|---|---|
| WO-0 | Merge four branches onto `main`, version byte | **done** | `WO-0-merge-notes.md` |
| WO-1 | Transport replacement | **done** | `WO-1-transport.md` |
| WO-2 | Interaction framework (opt-in paired sessions) | **done**, 23/23 tests | protocol `0x0A`–`0x11` |
| WO-3 | Dice (Farkle) | **done** — committed as `WO-5:` (see the naming collision note below) | `WO-5-dice.md`, protocol `0x16`–`0x19` |
| WO-4 | Emotes | **not started** | — |
| WO-5 | Duelling | **not started** | — |

**Plus one unplanned work order, not in the brief:**

| — | **Shared combat** — damage and death replicate between clients | **done** | `HANDOFF-WO4-combat.md` |

### Naming collision — fix this

Shared combat was labelled "WO-4" throughout its commits and documents. The
brief's WO-4 is **Emotes**. They are unrelated. Suggested renumbering:

- shared combat → **WO-6** (or "WO-C"), retroactively
- Dice, Emotes, Duelling keep their brief numbers

Whatever is chosen, say it explicitly in the next session's prompt, because
`git log` is full of "WO-4:" prefixes that mean shared combat.

The same collision now applies to dice: the brief calls it WO-3, but the
session prompt that commissioned it (superseding all earlier dice planning
docs) renumbered it **WO-5**, and every commit that built it says `WO-5:`.
"WO-5" in `git log` means dice, not duelling — the brief's WO-5.

---

## 2. Corrections to the brief

### §3 "Verified negative results" — still true, but Lua-only

Every item in that list holds **for the Lua sandbox**. None of it constrains
native code. The brief's framing invites the wrong conclusion, so state it
plainly: *Lua writes are inert; the engine is not.*

### §4 "The product design" — materially changed

The brief says: *"NOT a shared-world co-op mod… NPCs never know a second player
exists… no combat participation… a ghost is a prop… no server-side world state."*

That is no longer the design. Per `ARCHITECTURE-shared-world.md` and the native
work, the boundary now falls between **generic and unique NPCs**, not between
world and progression:

- **Shared:** damage and death on hand-placed generic NPCs.
- **Private:** quests, dialogue, journal, reputation, progression — unchanged.
- **Relay is still stateless.** Authority is per-hit, held by the client whose
  player landed the blow. That part of the brief survives intact.

Quest-state sync, save merging and entity streaming remain out of scope and
remain the right call.

### §5.2 "Duelling" — its central premise is now false

The brief says ghosts *"cannot deal or receive damage"* and that a real synced
fight *"is not achievable on the current transport."*

- **Damage is achievable.** Replicated damage lands on real NPCs, verified both
  directions end to end.
- **The transport objection is weaker** — the DLL pipe is a real push channel,
  not a polled one.
- **But the duel bubble is still the right design**, for a different reason:
  directional combat state, perfect blocks and clinches are per-frame and would
  need a per-frame sync the pipe can carry but the *relay* round trip cannot at
  fighting latency. Keep the bubble; drop the "cannot deal damage" rationale.

### §2.2 "Highest-priority engineering problem" — solved

The no-push-channel problem is solved twice: log-tail out (WO-1) and the DLL
named pipe (shared combat). Any new feature should assume a push channel exists.

### §5.1 "Dice" presentation options — decided and built

Recommendation (b), the launcher window, is what got built (`WO-5-dice.md`).
The native plugin still does **not** make Scaleform (c) any more tractable —
the GUI module's reflected surface was never examined. A one-line `DrawText`
turn hint (a) also exists, but only as a glance-without-alt-tabbing
convenience alongside the launcher window, not as the dice UI itself.

---

## 3. What now exists that the brief does not describe

### The native plugin (`native/`)

- **`KCDMP.dll`** — injected into the game. `KCDMP_LauncherInjector.exe` —
  `--pid <pid> --dll <path>`, the exact contract `KCDMP_launcher` already
  expected. Both build via `native\Build-Native.ps1` (MSVC, installed, not on
  PATH).
- **RTTR reflection ABI** — `CrySystem.dll` exports the whole rttr runtime, so
  the game's object model is drivable **by name**: no offsets, no signature
  scans. Hand-modelled ABI in `rttr_abi.h`, every layout claim carrying the
  disassembly evidence that produced it.
- **Main-thread marshalling** — IAT hook on `C_ModulesManager::Update` in
  `WHGame.dll`. Chosen over an inline detour: one aligned pointer store, no
  instruction relocation, reverses cleanly. Runs at 26–79 Hz.
- **Object walk** — `C_GameInterface::GetWritableInstance()` (exported from
  `Shared.dll`) → `RPGModule` → `SoulList` → `Soul` → `CombatSoul`.
- **Soul lookup by `SharedSoulGuid`**, the cross-client key.
- **Outbound detection by sampling**, not hooking — see §5.

### The agent↔DLL pipe

`\\.\pipe\kcdmp`, DLL hosts, agent connects. Framing matches the relay protocol.
`0x01 ApplyDamage`, `0x02 ApplyDeath`, `0x03 Ping` down; `0x81 Result`,
`0x83 Pong`, `0x90 LocalHit` up. **Overlapped I/O on both handles is mandatory**
— see §5.

### Wire protocol v4

Added `0x12`–`0x15` (Damage/Death, both directions) in v3, then `0x16`–`0x19`
(DiceIntent/DiceState/DiceError/DiceEnd) in v4. `Protocol.cs` is **no longer
duplicated** — it moved to a shared `KcdMp.Protocol` project (net8.0 classlib,
namespace `KcdMp.Wire` to avoid a name collision with the `Protocol` class
itself) that both `KcdMp.Client` and `KcdMp.Server` reference. One copy, kept
in sync with itself by construction. Next free type byte: **`0x1A`**.

### Test scripts (`tools\`)

| Script | Proves | Needs |
|---|---|---|
| `Test-Combat.ps1` | relay forwarding, 14/14 | relay only |
| `Test-Pipe.ps1` | pipe → DLL → NPC | game + DLL |
| `Test-CombatE2E.ps1` | inbound, full chain | everything |
| `Test-CombatOutbound.ps1` | outbound, full chain | everything |
| `Test-Sessions.ps1` | WO-2 sessions, 23/23 | relay only |
| `Test-Dice.ps1` | WO-5 dice, 10/10 | relay only |
| `Probe-Reflection.ps1` | capability re-check after a game patch | game |
| `KcdApi.ps1` | bounded REST client — dot-source it | game |

`dotnet\KcdMp.Farkle.Tests` (xUnit, 59/59) covers the dice scoring/turn state
machine itself, headless, no relay needed — see `WO-5-dice.md`.

---

## 4. Closed as not achievable — do not re-derive

- **Aggro / stimulus injection.** No reachable surface. `xgen` reflected =
  two read-only properties; `XBehaviorModule` = empty; XGenAIModule's 1,784
  exports are behaviour-tree enum glue; `SkirmishManager::DebugTriggerEvent`
  does nothing observable outside a running skirmish. **Consequence: replicated
  damage hurts NPCs but does not make them fight back.**
- **Attacker attribution.** `TakeDamage`'s `Attacker` parameter creates no
  combat history — `HasCombatHistoryWithSoul(player, 30s)` returned false after
  a hit landed.
- **Faction manipulation.** `C_FactionBase::SetParent` corrupted the faction
  tree and crashed the game. Disabled in code with reasoning inline.
- **Retail build as a target.** Monolithic `WHGame.dll`, exports nothing, no
  reflection REST API. Modding Tools only — both players need that Steam entry.

---

## 5. Traps — every one of these cost real time here

**Native / reflection**

- A fault-free rttr `invoke` is **not** a successful one. It returns an *invalid
  variant* on argument mismatch, with no exception. Check `variant::is_valid`.
  This is `pcall` returning true, one layer down.
- `TakeDamage`'s third parameter is `Attacker` (`I_Soul*`), **not**
  `SuppressHitReaction`. Passing a bool there silently did nothing.
- **Never pass a borrowed reference to a by-value parameter that owns a
  resource** (`shared_ptr`, `CryStringT`, containers) — the callee destroys it.
  This released a faction object and crashed the game. Value types (floats,
  enums, raw pointers) are fine.
- **Immediate read-back is not verification** for state the game re-derives. The
  faction write read back correctly and was reverted minutes later.
- Pointer comparison cannot distinguish souls: the map stores `C_Soul*` while
  `PlayerSoul` returns an `I_Soul*` base subobject. Compare by GUID.
- Even GUID comparison is not enough for "is this the player" — a second soul
  named "Dude", with its own GUID, sits at the player's exact position.

**Pipe / IPC**

- A duplex pipe used from two threads **requires `FILE_FLAG_OVERLAPPED` on both
  handles**. Without it Windows serialises I/O per handle and a write queues
  behind a parked read forever. A user-mode lock cannot fix this.
- Check the result of every write. A discarded `WriteFile` return made a blocked
  write look delivered.
- A narrow `catch` filter on a background task is a diagnostic dead end — the
  reader died silently and looked identical to "the DLL never wrote".

**Process / tooling**

- **A stale injected DLL keeps the pipe** (`ERROR_PIPE_BUSY`) and its sampler
  keeps running. Test a rebuilt DLL against a **restarted game**, or you are
  testing the old one. This produced two false negatives.
- A REST container read without `?depth=` serialised **658 MB** once. Always
  `?depth=0` or `?depth=1`.
- `Soul.Revive()` undoes a death; `SetState(health, …)` does not.
- `System.Guid` needs no byte reordering — its layout matches the game's CryGUID
  in memory. Only the *text* form needs field reversal.
- **PowerShell variables are case-insensitive**: `$ack` shadows `$ACK`, `$pong`
  shadows `$PONG`. Cost two false failures.
- `[Guid]::new($arr[1..16])` throws — a range index yields `Object[]` and selects
  the string overload. Cast to `[byte[]]`.

---

## 6. Environment

- **Launch via the KCD2 Modding Tools Steam entry**
  (`D:\SteamLibrary\steamapps\common\KCD2Mod`). The reflection REST API on
  `localhost:1403` and the exported module DLLs exist only there.
- **.NET SDK is user-scope, not on PATH:**
  `$env:DOTNET_ROOT = "$env:USERPROFILE\.dotnet-sdk8"; $env:PATH = "$env:DOTNET_ROOT;$env:PATH"`. Stay on net8.0.
- **MSVC Build Tools installed**, not on PATH; `native\Build-Native.ps1` finds them.
- **No Python** — the Flask master server cannot be run or tested here.
- **One machine, one copy of the game, no second player.** Synthetic TCP peers
  and the pipe test cover everything except a real second client. This is why
  every feature needs a headless test path.

---

## 7. Still open

- **Launcher end-to-end run.** The wiring itself is **done** — commit `54af330`
  rewrote `LaunchGame` to start the Modding Tools build, wait for `WHGame.dll`,
  run the injector, check its exit code, and then start `KcdMpClient.exe`. The
  master-server chain is closed too (`MasterRegistrationService`, corrected URL
  and DTO field names, upsert plus `last_seen` on the Python side).

  What remains is **verification**: the launcher has never been run against a
  real game launch. Its pieces are exercised individually by
  `tools\Test-CombatOutbound.ps1`, but its own sequencing has only been
  reviewed. The `WHGame.dll` wait is a reasoned choice, not a measured one. The
  Python master server has never been executed at all — there is no Python on
  this machine, so `servers.py` and `models.py` were validated against a stub
  mimicking the Flask contract. See `LAUNCHING.md`.

  *(This bullet previously claimed the launcher still booted the base game and
  never started the agent. That was already false when written — `54af330`
  precedes the commit that added this document.)*
- **Dice (WO-5) real-game verification.** The relay/protocol/engine layers are
  proven headless (`Test-Dice.ps1`, the Farkle xUnit suite), and the agent-side
  IPC bridge to the launcher was verified with two real `KcdMpClient.exe`
  processes and a synthetic wire peer. Not verified: the actual Blazor
  rendering (no way to drive Photino's webview headlessly), the in-game
  keybind (action names are unverified guesses — same caveat WO-2's
  accept/decline already carried), and a real two-human match at real
  latency. See `WO-5-dice.md`.
- **Ghost behaviour-tree trade-off.** `KCD2MP_SpawnGhost` passes
  `esModularBehaviorTree=""` deliberately so the scheduler does not fight
  `ForceMount` during riding. A ghost *with* a tree genuinely perceives (it
  appears in `PerceptionHistory`). Real trade-off, undecided.
- **`kdcmp.lua` is a ~2,400-line monolith.** Much of the ghost plumbing is
  redundant if the DLL ever renders players directly. The animation tables and
  speed thresholds are empirical data — port them, never regenerate them.

---

## 8. Reading order for a new session

1. **this document** — current state and corrections
2. `HANDOFF-WO4-combat.md` — shared combat: architecture, how to run and test
3. `WO-5-dice.md` — dice (Farkle): architecture, how to run and test, what is
   and is not verified
4. `NATIVE-PLUGIN-findings.md` — capability evidence, the RTTR ABI
5. `ARCHITECTURE-shared-world.md` — where the shared/private boundary falls
6. `LAUNCHING.md` — launch path and the remaining launcher gaps
7. the original brief — intent and the unstarted work orders, read *last* and
   with §2–§5 corrected by this document

`git log` records reasoning and **retractions**, not just changes. Several
commits explicitly retract earlier claims; read those before trusting an older
statement.
