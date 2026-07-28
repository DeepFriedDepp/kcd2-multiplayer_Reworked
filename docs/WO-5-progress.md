# WO-5 progress log

Append-only. Newest entry at the bottom. If you are starting a new session on
WO-5, read this file plus `docs/SESSION-PROMPT-wo5-dice.md` and
`docs/WO-5-dice.md` (the handoff) — this file is the narrative of *how* it got
built, those are the *what it is now*.

---

## Session 1 — 2026-07-28 — Phases 0–4 complete

Started cold from `docs/SESSION-PROMPT-wo5-dice.md`. Worked through all five
phases (0 through 4) in one session. Everything committed, nothing left
half-finished.

### Phase 0 — verify the ground

- Ran `Test-Sessions.ps1`: failed 100%, but the framework wasn't at fault —
  WO-4 bumped `Protocol.Version` to 3 and the relay strictly rejects a
  handshake mismatch; the test script still hardcoded 2 from when it was
  written for WO-2. One-line fix, then 23/23. Separate commit from everything
  else, since it's an unrelated pre-existing bug, not WO-5 work.
- `Protocol.cs` was still hand-duplicated between `KcdMp.Client` and
  `KcdMp.Server`, and had **already drifted**: client had
  `GhostPayloadLen`/`DamageDownPayloadLen`/`DeathDownPayloadLen` the server
  lacked; server had `InviteTimeoutSeconds` the client lacked. Neither project
  used the other's missing constants yet, so nothing was broken, but it's
  exactly the failure mode dice would have hit hard with new shared packet
  types. Extracted `dotnet/KcdMp.Protocol`. Hit a real snag: naming the
  namespace `KcdMp.Protocol` (matching the project name) collided with the
  `Protocol` class inside it — `Protocol.X` resolved to the sibling namespace
  instead of the type (`CS0234`). Renamed the **namespace** to `KcdMp.Wire`,
  left the project/assembly name alone.
- Confirmed next free wire byte was `0x16` as the session prompt claimed.

### Phase 1 — Farkle engine

- New `dotnet/KcdMp.Farkle` classlib, zero dependencies beyond the BCL.
  `FarkleGame` (state machine) + `Scoring` (pure scoring/validation) +
  `IDiceRng` (`CryptoDiceRng` for production, `SeededDiceRng` for the
  debug-only scripted-match override).
- Kept separate from `KcdMp.Protocol` deliberately: Protocol is the wire-format
  contract, Farkle is game rules Phase 2 maps onto that wire format. Mixing
  them would give the wire-format library a rules dependency neither Client
  nor the rest of Server needs.
- 59 xUnit tests: every scoring row in the spec table, hot dice (including
  spanning two `Keep` calls in one turn), every invalid-keep shape, all three
  real intents out-of-turn and in the wrong phase, bank/win, forfeit, and a
  seeded full-match replay (same seed → byte-identical outcome and scores
  across two independent runs).

### Phase 2 — relay integration + wire protocol

- Dice became a session *kind*. `SessionManager.Session` gained
  `OpenConfig` (opaque, like `SessionEvent` payloads already are) and a
  nullable `DiceGame`, populated on accept, riding the `Session`'s own
  lifecycle — no parallel dictionary, no extra disconnect cleanup
  (`HandleDisconnect` already tears the session down generically).
- New packets `0x16`–`0x19` (DiceIntent/DiceState/DiceError/DiceEnd).
  `Invite` gained an optional trailing `[configLen:1][config:N]` — additive,
  a bare 2-byte Invite still works. Dice's config carries `targetScore` +
  a debug-only seed override (`#if DEBUG`, so Release never reads it even if
  a client sends it).
- Bumped `Protocol.Version` 3→4. Confirmed this is sufficient for "pre-dice
  clients never get packets they can't parse" on its own: the relay already
  refuses any handshake version mismatch outright, so a connected peer
  already speaks dice by construction — no separate per-peer gate needed.
  Had to bump `Test-Sessions.ps1`'s and `Test-Combat.ps1`'s hardcoded version
  constants in lockstep, same class of staleness as the Phase 0 fix.
- Wrote `tools\Test-Dice.ps1`: seeded match reproducibility (played twice,
  identical final scores), out-of-turn Roll, out-of-range Keep mask, explicit
  Forfeit, mid-match disconnect. 10/10.
- Two real bugs found and fixed **in the test script**, not the relay:
  PowerShell's case-insensitive variable names meant a local `$p` (current
  packet) silently aliased the script's own `$P` (protocol constants) the
  moment it was assigned; and an early version of the out-of-turn test only
  drained one participant's copy of the initial `DiceState` broadcast,
  leaving the other's queued and misread later.

### Phase 3 — launcher window

- Confirmed via a dedicated Explore pass: **no** existing channel connects
  the launcher to the agent once started — no redirected stdio, no shared
  port, nothing. `ServerInfoPort` is relay-facing, unrelated.
- Since the spec also requires launcher and agent to work **independently**
  started (not parent/child), stdio piping was ruled out even though it
  would have been simpler. Picked a local HTTP listener in the agent
  (`DiceIpcServer`, plain `HttpListener`, no new dependency), polled by the
  launcher exactly the way it already polls the relay's `/api/information`.
- Agent: `DiceClient` (mirrors `InteractionClient`'s "relay arbitrates"
  discipline for dice packets), `DiceIpcState` (aggregates into one flat
  snapshot, full state never a delta — same rule as the wire itself),
  `DiceIpcServer` (GET /dice, POST /dice/respond, POST /dice/intent).
  `GameBridge` wired it in and gated the existing in-game
  `KCD2MP_ShowInvite` Lua call to skip `Kind == Dice` specifically.
- Launcher: `DiceIpcClient` (polls every 700ms, fires a change event only
  when the snapshot actually differs), `DiceWindow.razor` (self-contained,
  no external parameters, mounted once in `Home.razor` — deliberately
  independent of `Home.razor.cs`'s already-large state, per that file's own
  "split this into several components" comment).
- **Verified with two real `KcdMpClient.exe` processes** (not just
  `Test-Dice.ps1`'s synthetic peers) plus a synthetic third wire peer,
  against a real relay, no game, no launcher UI: real Invite → real IPC
  surfacing → real accept via IPC → real wire response → real DiceState →
  correct IPC snapshot → a real intent POSTed through IPC → real wire
  DiceIntent → relay → real DiceState back → IPC reflects it → clean
  Forfeit through IPC → correct winner. This is coverage `Test-Dice.ps1`
  structurally cannot provide (it never touches the agent's own code).
- Not verified and cannot be from here: the actual Blazor rendering (no
  headless way to drive Photino's webview).

### Phase 4 — in-game keybind

- Found almost everything already existed from earlier WO-2 work:
  `KCD2MP_InviteNearest("dice")` already found the nearest ghost and emitted
  `invite_send` in the exact shape `GameBridge.OnGameEvent` expects, already
  exposed as the working console command `mp_invite dice`. Only the keybind
  itself was missing.
- Added `DICE_INVITE_ACTIONS` (guessed `dialog_answer3`/`dialog_answer4`,
  same family as the existing accept/decline guesses) + a `handleAction`
  branch. Same unverified-guess caveat as those, explicitly documented
  in-line; `mp_invite dice` remains the reliable fallback.
- Added the optional `System.DrawText` turn hint (it was genuinely trivial —
  the label loop, DrawText, and transient-message pattern all already
  existed for the invite prompt). Wired from `DiceClient.StateChanged` /
  `MatchEnded` in `GameBridge`.
- No Lua interpreter available in this environment to syntax-check the
  file; re-read the edited regions carefully by eye instead. Cannot be
  verified without a running game.

### Documentation

- `docs/WO-5-dice.md` — the handoff note (architecture, protocol, how to
  run/test, what's verified vs not, manual two-PC steps not executed, scope
  cuts and where they'd slot in, traps).
- `docs/PROJECT-STATE.md` updated: WO-3/dice marked done (with the WO-5
  naming-collision note extended to cover it), the stale "Protocol.cs
  duplication is overdue" open item removed (it's fixed), wire protocol
  section bumped to v4/`0x1A`, test-script table gained `Test-Dice.ps1`, a
  new open item added for what dice itself still needs verified.

### For the next session

Everything in scope for WO-5 is built, tested (as far as headlessly
possible), and documented. What's actually left needs a human:

1. Run the manual two-PC steps in `docs/WO-5-dice.md` — a real match between
   two real players is the one thing nothing here could simulate.
2. Find the real keybind action name (`KCD2MP.logActions = true`, press the
   key, read the `ACT` line) and update `DICE_INVITE_ACTIONS` in
   `kdcmp.lua` — or decide the console command is good enough for now.
3. Look at the Blazor UI on an actual screen. It compiles; nobody has seen it.
4. The three items already flagged as unverified from WO-4 (real
   launcher-driven launch, the real Python master server, a real second
   client) are still exactly as unverified as before — WO-5 didn't touch any
   of them, and combining "real launch" verification with "real dice match"
   verification in one manual pass would be efficient if a second machine
   ever becomes available.
5. A background task (`task_d7b61562` at time of writing) is queued for the
   silent-exception-swallowing issue found in `TcpSocketService`/
   `ClientSession.WriteLoopAsync` during Phase 2 debugging — not fixed here
   since it's outside what this WO was asked to touch.
