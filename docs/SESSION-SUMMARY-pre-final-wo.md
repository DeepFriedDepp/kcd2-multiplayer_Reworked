# Summary for the final WO — verification, not new features

Written 2026-07-28 as raw material for a session prompt, not a session prompt
itself. Everything below is either proven (with how) or explicitly flagged as
unverified (with why and what would prove it).

---

## One-line status

Every planned work order (WO-0 through WO-5 in commit numbering; the brief's
WO-0/1/2/3) is **built and headlessly tested**. Nothing is unimplemented. What
remains is a backlog of manual verification that has been deferred across two
sessions for the same reason: no second machine, no second player, no Python,
and no way to drive a Blazor webview headlessly. If any of those constraints
have lifted, **the final WO is a verification pass, not new development.**

---

## What's proven, and how

- **Shared combat** (damage/death replication) — `Test-Combat.ps1` 14/14,
  plus real pipe/DLL/agent chain tests (`Test-Pipe.ps1`,
  `Test-CombatE2E.ps1`, `Test-CombatOutbound.ps1`).
- **WO-2 session framework** (invite/accept/decline/leave/disconnect/timeout)
  — `Test-Sessions.ps1` 23/23.
- **Dice (Farkle) engine** — `dotnet\KcdMp.Farkle.Tests`, 59 xUnit tests,
  headless, no relay needed.
- **Dice relay integration** — `Test-Dice.ps1` 10/10: seeded reproducibility,
  out-of-turn rejection, invalid keep, forfeit, disconnect.
- **Dice agent↔launcher IPC** — verified with **two real `KcdMpClient.exe`
  processes** and a synthetic wire peer (no game, no launcher UI): a real
  invite surfaced through the real agent's IPC endpoint, a real accept
  produced a real wire response, a real intent posted through IPC produced a
  real wire packet the relay processed and reflected back, a clean forfeit
  ended the match correctly.
- **`KcdMp.Protocol` extraction** — the wire format is no longer
  hand-duplicated between client and server; real drift that had already
  accumulated was found and reconciled.

Full detail: `docs/HANDOFF-WO4-combat.md` (combat), `docs/WO-5-dice.md`
(dice), `docs/PROJECT-STATE.md` (corrections to the original brief — read
this before the brief itself, several of its factual claims are stale).

---

## What's NOT proven — the actual backlog

### Carried from before WO-5 (still open, WO-5 didn't touch any of these)

1. **A real launcher-driven launch.** `KCDMP_launcher.LaunchGame` (start the
   Modding Tools build → wait for `WHGame.dll` → inject → start the agent)
   has never been run. Its pieces are individually proven; the sequencing —
   in particular the `WHGame.dll` load-wait timeout — is a reasoned choice,
   not a measured one. See `docs/LAUNCHING.md`.
2. **The real Python master server.** No Python on this machine, ever.
   `servers.py`/`models.py` were validated against a stub of the Flask
   contract, not the real thing. Needs: run it for real, confirm
   registration/heartbeat/upsert/`last_seen` expiry actually work, and if the
   database already has rows from before the schema change, run the
   migration (`migrate.sh`) rather than relying on `create_all()`.
3. **A real second client / second machine, generally.** Every "verified
   end to end" claim anywhere in this project used synthetic TCP peers or,
   at best, two agent processes on one machine talking over loopback. No
   claim anywhere has been checked against real network latency or two
   actual human players.

### New from WO-5

4. **The dice launcher UI, on an actual screen.** `DiceWindow.razor` builds
   and the data feeding it is proven correct via the IPC smoke test above,
   but nobody has seen it render: the six-dice grid, click-to-toggle keep
   selection, button enable/disable by turn and phase, the accept/decline
   prompt, the win/lose screen. Any purely visual bug — layout, a
   misattached click handler, CSS scoping — is still possible.
5. **The in-game dice keybind.** `kdcmp.lua`'s `DICE_INVITE_ACTIONS`
   (`dialog_answer3`/`dialog_answer4`) are guesses, same as WO-2's
   accept/decline actions before them. They may simply never fire. The
   verified fallback is the console command `mp_invite dice`. Finding the
   real action name: set `KCD2MP.logActions = true` in-game, press the
   intended key, read the `ACT` line from `kcd.log`.
6. **A real two-human dice match**, specifically: turn-passing latency feel
   (how long a `DiceState` takes to reach the other player's screen after a
   Roll/Keep/Bank), and whether the launcher window is usable/discoverable
   mid-game without feeling disruptive.

`docs/WO-5-dice.md` has a fully written-out, numbered manual test procedure
for items 4–6 (and touches on 1) — copy it into the next session's task list
rather than re-deriving it.

---

## Traps to carry forward (all already cost time once)

- `$env:DOTNET_ROOT = "$env:USERPROFILE\.dotnet-sdk8"; $env:PATH = "$env:DOTNET_ROOT;$env:PATH"`
  before any `dotnet` command — the SDK is user-scope, not on PATH.
- Launch the game via the **KCD2 Modding Tools** Steam entry, never the base
  game — the debug REST API and module DLLs the agent depends on exist only
  there.
- A stale injected DLL keeps the pipe alive and its sampler keeps running —
  always test a rebuilt DLL against a **restarted** game.
- PowerShell variable names are case-insensitive (`$ack`/`$ACK`, `$p`/`$P`) —
  bit this project twice already, in two different test scripts.
- A silent `catch` on a background task turns a crash into "looks like a
  normal disconnect" — this was just fixed in `TcpSocketService` and
  `ClientSession.WriteLoopAsync`, but the same shape of bug could exist
  elsewhere; don't assume an absent error means an absent problem.
- The dice seed override (for a reproducible scripted match) only works
  against a **Debug** relay build.

---

## Naming note for whoever writes the actual prompt

The original brief numbers work orders 0–5 (Emotes is brief-WO-4, Duelling is
brief-WO-5). Every commit in this repo instead numbers them by when they were
actually built: shared combat is `WO-4:` in commits despite being unplanned,
and dice is `WO-5:` in commits despite being brief-WO-3. `PROJECT-STATE.md`
documents both collisions explicitly. If the next session is verification-only
(no new feature), it doesn't need a new WO number at all — call it something
like "WO-5 verification pass" or "post-WO-5 hardening" rather than inventing
a numbered WO for work that adds no new feature.
