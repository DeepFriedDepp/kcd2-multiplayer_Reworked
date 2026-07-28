# WO-5 handoff — dice (Farkle)

State as of 2026-07-28. Branch: `main`.

**Read `PROJECT-STATE.md` first** for the naming-collision note (the brief
calls this WO-3; every commit says `WO-5:`). This document is the operational
handover for dice specifically: what was built, how to run and test it, what
is proven, and what still needs a human.

---

## One-line status

Dice is playable relay-authoritatively end to end, proven headless (relay +
engine) and proven with two real agent processes (the IPC bridge to the
launcher). The Blazor UI itself and a real in-game keybind are both built but
**not observed running** — no way to drive Photino's webview headlessly, no
running game to test the keybind against.

---

## Architecture as built

```
KCDMP_launcher                agent (KcdMpClient)              relay
┌─────────────────────┐       ┌───────────────────────┐        ┌────────┐
│ DiceWindow.razor     │       │ InteractionClient      │        │        │
│  invite prompt       │◄─HTTP►│  (WO-2, unchanged)     │◄─TCP──►│ SessionManager │
│  6-dice board        │ poll │ DiceClient              │        │  FarkleGame    │
│ DiceIpcClient         │      │ DiceIpcState/Server     │        │  (relay-owned) │
└─────────────────────┘       └───────────────────────┘        └────────┘
```

- **`dotnet/KcdMp.Farkle`** — pure state machine (`FarkleGame`, `Scoring`,
  `IDiceRng`). No sockets, no relay, no game. 59 xUnit tests.
- **Relay (`KcdMp.Server`)** — dice is a session *kind* on the existing WO-2
  framework (`SessionManager`). Unlike `RelayEvent`, which forwards opaque
  bytes between the two clients untouched, `HandleDiceIntent` terminates the
  packet and interprets it: the relay owns the one live `FarkleGame` per
  session, so the RNG, turn order, and scoring can never be influenced by
  either client.
- **Agent (`KcdMp.Client`)** — `DiceClient` mirrors `InteractionClient`'s
  discipline for the dice packets: it sends an intent and renders whatever
  comes back, never computing a roll or score itself. `DiceIpcState` +
  `DiceIpcServer` are the only channel to the launcher (see below).
- **Launcher (`KCDMP_launcher`)** — `DiceIpcClient` polls the agent's local
  HTTP endpoint; `DiceWindow.razor` is the actual UI, a self-contained
  component with no external parameters.
- **In-game (`kdcmp.lua`)** — one new keybind guess calling the
  already-existing `KCD2MP_InviteNearest("dice")`, plus an optional one-line
  `DrawText` turn hint. Presentation itself stays in the launcher.

## Protocol (v4, bytes `0x16`–`0x19`)

See `dotnet/KcdMp.Protocol/Protocol.cs` for the authoritative layout — the
doc comment there is kept in sync with the code by construction (that's the
point of the Phase 0 extraction). Summary:

```
C→S  0x16  DiceIntent: [sessionId:2][intentType:1][data:N]
             0=Roll (no data), 1=Keep ([mask:1]), 2=Bank (no data), 3=Forfeit (no data)
S→C  0x17  DiceState:  full snapshot, never a delta, sent to both participants identically
S→C  0x18  DiceError:  sent to the rejected sender only; game state unchanged
S→C  0x19  DiceEnd:    outcome + final scores, immediately followed by a normal SessionEnd(Completed)
```

`Invite` (`0x0A`) gained an optional trailing `[configLen:1][config:N]` —
backward compatible, a bare 2-byte Invite is still valid. Dice's config is
`[targetScore:2 LE][debugSeedOverride:4 LE]`; the seed override only exists
in a `#if DEBUG` code path, so a Release relay never reads those bytes
regardless of what a client sends.

Next free type byte: **`0x1A`**.

## The agent↔launcher channel

Nothing connected these two processes before this WO — the launcher starts
the agent as a bare subprocess and never reads or writes anything to it
afterward, and per spec they're also meant to work started **independently**
("a manually started launcher beside a manually started agent"), which rules
out anything riding the parent/child relationship (piped stdio).

**Picked:** a local HTTP listener in the agent (`DiceIpcServer`,
`System.Net.HttpListener`, no new dependency), polled by the launcher the
same way it already polls the relay's own `/api/information`
(`NetService.GetDedicatedServerInfoAsync`). `GET /dice` returns the full
current snapshot (invite pending, or active session, or neither); `POST
/dice/respond` and `POST /dice/intent` send commands back. Port is
`ClientConfig.DiceIpcPort` / `AppSettings.DiceIpcPort`, default `5901` on
both sides, `--dice-ipc-port` to override on the agent.

---

## How to run everything

```powershell
$env:DOTNET_ROOT = "$env:USERPROFILE\.dotnet-sdk8"; $env:PATH = "$env:DOTNET_ROOT;$env:PATH"
dotnet build KCD2-MP.sln

dotnet run --project dotnet\KcdMp.Server -- --port 7778
dotnet run --project dotnet\KcdMp.Client -- --host localhost --no-voice

# the launcher, started independently -- no game required for the dice window
# to reach a locally-running agent
dotnet run --project KCDMP_launcher
```

### Test scripts

| Script | Proves | Needs |
|---|---|---|
| `dotnet test dotnet\KcdMp.Farkle.Tests` | scoring table, bust, hot dice, invalid keeps, out-of-turn, seeded replay — 59/59 | nothing running |
| `tools\Test-Dice.ps1` | relay-side dice: seeded reproducibility, out-of-turn, bad keep mask, forfeit, disconnect — 10/10 | relay only |
| `tools\Test-Sessions.ps1` | WO-2 sessions still green after the dice extension — 22/22 (23/23 with `-IncludeTimeout`) | relay only |
| `tools\Test-Combat.ps1` | WO-4 combat still green — 14/14 | relay only |

`Test-Dice.ps1`'s seed override only works against a **Debug** relay build —
that's deliberate (see the config section above).

---

## What was verified, and how

**Headless (relay + engine), by the test scripts above.** This is the
strongest evidence: every scoring row, hot dice spanning multiple keeps in
one turn, every invalid-keep shape, out-of-turn intents for all three real
actions, bank/win, forfeit, and a seeded full match reproducing identical
final scores when replayed.

**The real agent-side IPC code (`DiceClient`, `DiceIpcState`,
`DiceIpcServer`), with two real `KcdMpClient.exe` processes and a synthetic
third wire peer, no game, no launcher UI.** This is not something
`Test-Dice.ps1` can cover — that script only ever talks to the relay.
Observed directly:

- A real wire Invite correctly surfaces through a real agent's `GET /dice`
  (invite sender's name resolved correctly).
- Accepting through that same IPC endpoint sends a real `InviteResponse` on
  the wire; the resulting `SessionStart`/`DiceState` populate the IPC
  snapshot correctly (role, peer name, phase, target score).
- An intent POSTed to `/dice/intent` produces a real `DiceIntent` on the
  wire that the relay processes, reflected back through both the wire
  (`DiceState`) and the IPC snapshot.
- A clean `Forfeit` through IPC ends the match with the correct winner
  (`DiceEnd` + `SessionEnd(Completed)`).
- A peer disconnecting mid-match correctly clears the IPC-visible session
  (the existing WO-2 disconnect-propagation path, untouched, doing exactly
  what "disconnect = forfeit" asks for).

**Not verified, and cannot be from here:**

- **The actual Blazor rendering.** `DiceWindow.razor` builds, but there is no
  way to drive Photino's webview headlessly in this environment. The board
  layout, click-to-toggle keep selection, and button enable/disable logic
  have been read carefully but never seen on screen.
- **The in-game keybind.** `DICE_INVITE_ACTIONS` (`dialog_answer3/4`) are
  guesses, exactly like WO-2's `ACCEPT_ACTIONS`/`DECLINE_ACTIONS` before
  them. They may simply never fire. `mp_invite dice` (the pre-existing
  console command) is the verified fallback; `KCD2MP.logActions = true`
  finds the real action name by pressing the key and reading `ACT` lines
  from `kcd.log`.
- **A real two-human match at real latency.** Everything above ran on one
  machine, loopback only. UI feel under real relay latency — how long a
  `DiceState` takes to reach the other player's screen after a Roll/Keep/Bank
  — was never observed.
- **The launcher's own process-spawn path with dice.** The IPC smoke test
  used two agents started directly (`dotnet run`), not through
  `KCDMP_launcher.LaunchGame`. That sequencing was already unverified before
  this WO (`PROJECT-STATE.md` §7) and is unrelated to dice specifically.

---

## Scope cuts (v1), and where each would slot in later

- **Special dice / badges / the Devil's Head.** `DieKind` already exists as
  an enum on `Die` with only `Standard` defined, specifically so a future
  badge type slots in without changing the wire format again — `Scoring`
  would need a per-kind rule table instead of the current flat one, and
  `DiceState`'s free/kept face arrays would need a kind byte alongside each
  face.
- **A final-round rebuttal.** The spec is explicit: the first bank reaching
  target wins immediately. Adding a rebuttal round would mean `FarkleGame`
  gaining a state past `Outcome != InProgress` (bank-a-response phase) before
  actually ending, and `DiceEnd` would need to move later in the sequence.
- **Reconnect-resume.** Disconnect is forfeit, full stop — the session (and
  the `FarkleGame` it owns) is discarded with it. Resuming would require the
  relay to keep the engine alive past a disconnect for some grace window and
  the reconnecting client to re-fetch a snapshot instead of relying on
  `SessionStart` + the first `DiceState`; a reasonable amount of new state to
  add to `SessionManager`, not attempted here.

---

## Manual two-PC test steps — NOT EXECUTED

No second machine and no second copy of the game exist in this environment.
These steps are written out for whoever has both, and nothing below has been
run.

1. On each PC: launch KCD2 via the **KCD2 Modding Tools** Steam entry, load a
   save, confirm `[KCD2-MP] === MOD INIT ===` in `kcd.log`.
2. On one PC: `dotnet run --project dotnet\KcdMp.Server -- --port 7778`.
3. On each PC: inject (`KCDMP_LauncherInjector.exe --pid <pid> --dll
   <path>\KCDMP.dll`), then start the agent (`dotnet run --project
   dotnet\KcdMp.Client -- --host <relay ip> --port 7778`).
4. On each PC: start `KCDMP_launcher` independently of the agent (per the
   spec's "manually started launcher beside a manually started agent" — do
   not use `LaunchGame`, which is unverified for unrelated reasons, see
   `PROJECT-STATE.md` §7).
5. Walk one player next to the other's ghost. Press the dice keybind (or, if
   it does not fire — likely, see below — run `mp_invite dice` in the
   console instead).
6. Confirm: the invited player's **launcher** shows an accept/decline
   prompt (not an in-game Scaleform/DrawText prompt — that would indicate
   the Kind == Dice gate in `GameBridge.WireInteractionFeedback` regressed).
7. Accept. Confirm both launchers show the six-dice board, turn banner
   correctly identifying whose turn it is, and matching totals.
8. Play a full match: roll, click dice to select a keep, submit Keep, bank
   or roll again, through to one player reaching the target score. Confirm
   the win/lose screen matches on both launchers and the scores agree.
9. Separately: mid-match, close one player's agent process (or alt-F4 the
   game). Confirm the survivor's launcher shows the match ending (session
   torn down) rather than hanging.
10. Note, for whoever runs this: whether the keybind fired at all, and if
    not, set `KCD2MP.logActions = true` in-game, press the intended key, and
    read the `ACT` line it logs to find the real action name to substitute
    for `dialog_answer3`/`dialog_answer4` in `kdcmp.lua`.

## Traps that cost time in this WO

- **PowerShell variable names are case-insensitive.** A local `$p` holding
  the current packet inside `Test-Dice.ps1` silently aliased the script's own
  `$P` protocol-constants table the moment it was assigned — `$P.DiceState`
  then resolved against the packet object instead of the constant, and the
  failure looked like the relay silently allowing an out-of-turn Roll. It
  wasn't; the relay was correct the whole time. Renamed to `$pkt`. (WO-4's
  handoff already flagged the general shape of this trap with `$ack`/`$ACK`;
  this is the same mistake in new code.)
- **`DiceState` broadcasts to both participants identically.** An early
  version of the out-of-turn-roll test only drained the initiator's copy of
  the initial snapshot from its socket; reading the *other* participant's
  stream afterward picked up its own still-queued snapshot instead of the
  `DiceError` actually being tested for. Both copies need draining before
  reading further from either side.
- **A namespace cannot share a name with a type inside it.** Naming the new
  shared project's namespace `KcdMp.Protocol` (matching the project/folder
  name) collided with the `Protocol` class living in it: unqualified
  `Protocol.X` resolved to the sibling namespace `KcdMp.Client.KcdMp.Protocol`
  rather than the type, `CS0234`. Renamed the *namespace* to `KcdMp.Wire`;
  the project/assembly name is unaffected.
- **A lambda parameter named `_` shadows the discard.** `dice.MatchEnded +=
  _ => { _ = ExecLuaAsync(...); }` doesn't discard — it assigns a `Task` to
  the lambda's own parameter (typed `DiceResult`), `CS0029`. Only shows up
  when the discard and the parameter share the literal name `_` in the same
  scope; renaming the parameter fixes it.

---

## Also flagged, not fixed (out of scope here)

`TcpSocketService`'s fire-and-forget `ContinueWith` and
`ClientSession.WriteLoopAsync`'s bare `catch` both swallow exceptions with no
logging — the same "silent catch on a background task" trap
`HANDOFF-WO4-combat.md` already documents, still live elsewhere in the relay.
It cost real time during this WO narrowing down the `$p`/`$P` bug above
before a from-scratch debug script proved the relay itself was fine. Flagged
as a background task (`task_d7b61562` at time of writing) rather than fixed
inline, since it touches exception-handling behavior in code this WO wasn't
asked to modify.
