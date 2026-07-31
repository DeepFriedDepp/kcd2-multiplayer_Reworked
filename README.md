# KCD2 Multiplayer

An unofficial multiplayer mod for Kingdom Come: Deliverance II. It lets two
or more people play the same open world together at once: you see each
other as ghost NPCs (position, animation, nameplates), hear each other over
proximity voice chat, can land shared damage on each other and on the
world's NPCs, and can play a full relay-authoritative game of Farkle dice
against each other from inside the game itself.

**Not affiliated with, endorsed by, or supported by Warhorse Studios.**
Kingdom Come: Deliverance is a trademark of Warhorse Studios; this is a
non-commercial fan project.

## Status

Honest, code-verified as of this write-up — not "should work," what's
actually been observed working. "Unverified" below means exactly that,
never "probably fine."

| Feature | Status |
|---|---|
| Relay (`KcdMpServer.exe`) | **Working** — automated suites green |
| Agent (`KcdMpClient.exe`) | **Working** |
| Native plugin + injection | **Built but unverified** on the fully-automatic path — the DLL's own liveness check can silently no-op if injected before a save is loaded; manual/gated injection into an already-running game is proven |
| Ghost presence (position/animation/nameplates) | **Working** |
| Shared combat | **Working** against synthetic peers and in real single-machine play; **unverified** with a second real human. NPC aggro (making an NPC fight back) is a **known limit**, not a bug — see below |
| Voice chat | **Working**, proximity-based |
| Session framework (invites/accept/decline) | **Working** |
| Dice engine (Farkle) | **Working** — 59/59 unit tests |
| Dice ↔ relay integration | **Working** headlessly; **unverified** with two real humans |
| In-game dice UI | **Working** — played to completion against a scripted opponent; **unverified** with two real humans |
| Emotes | **Not implemented** |
| Duelling | **Not implemented** — the wire protocol reserves a slot for it, nothing behind it |
| Master server (server browser backend) | **Built but unverified** — the .NET side is tested against a stub of its contract; the Python service itself has never been run on a machine that touched this project |
| Launcher (host/join, dependency handling) | **Built but unverified end-to-end** — see below |
| Installer (`KCDMP-Setup-<version>.exe`) | **Working** — silent install/upgrade/uninstall and Steam detection both covered by automated suites (39/39, 21/21) on one machine; the interactive wizard and any clean machine are **unverified**, see `docs/INSTALLER-TESTING.md` |

**Known not achievable, closed with evidence:**
- **NPC aggro / stimulus injection** — replicated damage lands and can kill
  NPCs, but there is no reachable way to make an NPC's AI *react* to it; the
  AI/stimulus surface is not exposed. NPCs never fight back.
- **Faction manipulation** — writing to a faction's ownership through the
  reflection layer corrupts a reference-counted pointer the game owns and
  crashes it; no safe path was found.
- **Reading the native dice minigame's live state** — the minigame's own
  in-progress state isn't reachable from outside it. This is why dice is a
  separate relay-authoritative engine rather than mirroring the vanilla
  minigame.

## How to play with a friend

1. Both of you install the mod (below) and the launcher.
2. One of you clicks **HOST GAME** in the launcher — it starts a relay and
   shows you the address to share.
3. The other clicks **ADD SERVER**, enters that address, and clicks **JOIN**.
4. Both of you click through to load into the game world; the launcher
   handles injecting the plugin and starting your agent once you confirm
   you're actually in-game.

Same Wi-Fi/LAN: that's it. Different houses: see
**[docs/NETWORKING.md](docs/NETWORKING.md)** for the two ways to connect
over the internet (a VPN overlay like Tailscale — recommended — or port
forwarding), including exactly what address and port to share.

You need Kingdom Come: Deliverance II on Steam, plus that Modding Tools
entry (free, a separate item in your Steam library). Nothing else: the
launcher, agent and relay carry their own .NET runtime, and the installer
fetches Microsoft's WebView2 runtime if your Windows doesn't already have it.

Installing by hand still works and is documented in
[docs/LAUNCHING.md](docs/LAUNCHING.md) — use it if the installer misbehaves
or your Steam setup is unusual.

**Building the installer yourself:**

```
powershell -ExecutionPolicy Bypass -File tools\Build-Installer.ps1
```

That publishes everything self-contained and compiles
`release\KCDMP-Setup-<version>.exe`. It needs
[Inno Setup 6](https://jrsoftware.org/isinfo.php)
(`winget install --id JRSoftware.InnoSetup`). The version comes from the
`VERSION` file at the repo root.

## How to play dice

Farkle, played against another real player. This is **not** the vanilla dice
minigame — it is a separate relay-authoritative engine with its own board
drawn over the game, so the rules are settled by the relay and neither player
can desync the other. The vanilla NPC minigame is untouched and still works
normally; nothing here interferes with it.

**Before you start:** both of you must be connected (green in the launcher)
and standing near each other in the same part of the world. Dice needs your
two characters close enough for "nearest player" to mean each other.

### 1. Open the game console

Every step that has no keybind yet is a console command. Open the developer
console with **`~`** (the key left of `1`; the Modding Tools build has the
console enabled — retail does not, which is one more reason the mod requires
that build). Type the command, press Enter, press `~` again to close.

### 2. Challenge someone

Walk up to a dice table, sit down if you like, and run:

```
mp_dice
```

That invites the nearest player. If you get *"Sit at a table first"*, the
table gate is on and there is no dice table in range — either move to a real
table, or turn the gate off with `mp_dice_gate off` (it ships **off** by
default, so you should not normally see this).

`mp_dice_table` reports the nearest table it can see, and `mp_dice_seat`
reports the seat under you — both are for working out why a table is not
being recognised.

### 3. Accept the challenge

The other player sees the invite prompt and runs:

```
mp_accept
```

or `mp_decline` to refuse. The board appears for both of you once accepted.

### 4. Play

Once the board is up, dice is played on **real keys** — no console needed:

| Key | Does |
|---|---|
| `F2` `F4` `F5` `F6` `F7` `F8` | Mark die 1–6 (the numbers under the dice on the board) |
| `F9` | Cast — rolls, or sets aside the dice you marked, depending on the phase |
| `U` | Clear every mark without rolling |
| `F11` *(hold)* | Bank your points and end your turn |
| `F12` *(hold)* | Yield the match |

Bank and yield are **hold-to-confirm**, deliberately — they are irreversible
and a stray tap should not end your turn or the match.

A turn goes: press `F9` to roll → mark the scoring dice you want to keep →
`F9` again to set them aside → roll the rest, or `F11` to bank what you have.
Roll nothing scoring and you **bust**: the board shows what you rolled and
says so, and your turn ends with nothing banked. First to the target score
wins.

Every key above has a console equivalent if a key ever fails you:
`mp_dice_mark 1`…`6`, `mp_dice_cast`, `mp_dice_unmark_all`, `mp_dice_bank`,
`mp_dice_yield`.

### If the board misbehaves

| Command | Use when |
|---|---|
| `mp_dice_redraw` | The board is stale — forces it to re-push |
| `mp_dice_flush` | The board is stuck or flickering — clears every queued panel |
| `mp_dice_close` | You want it gone |

### Known rough edges

- **Inviting and accepting have no keybind.** `mp_dice`, `mp_accept` and
  `mp_decline` are the reliable path. Key bindings for these exist in the code
  but are built on **guessed** action names (`dialog_answer3/4`,
  `dialog_answer1/2`) that have never been confirmed to fire — treat them as
  not working.
- **Nothing is wagered.** The match is a pure score contest; no groschen
  changes hands. Moving real currency needs a native write and has not been
  built.
- **A full two-human match has never been played.** Everything above was
  verified against a scripted opponent (`tools\Bot-DiceOpponent.ps1`) on one
  machine. See below.

## Architecture

```
PC1: [KCD2 + Mod] ←localhost→ [KcdMpClient.exe] ──TCP──┐
                                                          ├── [KcdMpServer]
PC2: [KCD2 + Mod] ←localhost→ [KcdMpClient.exe] ──TCP──┘
```

- **`KcdMpServer`** — the relay. Whoever hosts runs this; everyone else
  connects to its address. Binds all interfaces by default, so LAN and
  VPN-overlay play need no extra config — see `docs/NETWORKING.md`.
- **`KcdMpClient.exe`** — the per-player agent. Reads your local game state
  and pushes it to the relay; receives everyone else's state and drives your
  local ghosts/voice/combat.
- **`KCDMP.dll`** — the native plugin, injected into the game process. Talks
  to the agent over a local named pipe; reads and writes game state through
  the engine's own RTTR reflection layer (exported by `CrySystem.dll`), not
  offsets or signature scans.
- **`KCDMP_launcher`** — the desktop app you actually run: server
  browser/host/join UI, launches the game, drives injection, starts the
  agent.

Each agent only ever talks to its own machine's game — there is no
cross-machine game-API traffic, only the relay TCP connection.

## Repository layout

| Path | What it is |
|---|---|
| `kdcmp/` | The game mod — Lua and the built `kdcmp.pak` |
| `dotnet/KcdMp.Client/` | `KcdMpClient.exe`, the per-PC agent |
| `dotnet/KcdMp.Server/` | `KcdMpServer.exe`, the relay |
| `dotnet/KcdMp.Protocol/` | Shared wire protocol |
| `dotnet/KcdMp.Farkle/` | The dice engine (pure state machine, no external deps) |
| `native/KCDMP/` | The injected plugin (C++) |
| `native/KCDMP_LauncherInjector/` | The injector executable |
| `KCDMP_launcher/` | The desktop launcher (Photino/Blazor) |
| `kcd2_master_server/` | Flask + SQLAlchemy server-discovery service |
| `docs/` | Design notes and session handoffs — start with `docs/PROJECT-STATE.md` |

## Building from source

Requires the [.NET 8 SDK](https://dotnet.microsoft.com/download) and, for
the native plugin, VS Build Tools with the C++ workload (CMake + Ninja,
located automatically via `vswhere`).

```powershell
dotnet build KCD2-MP.sln
powershell -File native\Build-Native.ps1
```

To assemble a self-contained release folder (no .NET runtime required on
the target machine — the native plugin already links its C++ runtime
statically, so there's nothing extra to bundle there):

```powershell
powershell -File tools\Publish-Release.ps1
```

Run things directly during development:

```powershell
dotnet run --project dotnet\KcdMp.Server
dotnet run --project dotnet\KcdMp.Client -- --host localhost --name PC1
dotnet run --project KCDMP_launcher
```

The master server is a separate Python service (`kcd2_master_server/`);
never run on the machine this fork was developed on, so treat it as
reviewed, not proven — see the status table above.

## Testing

```powershell
dotnet run --project dotnet\KcdMp.Server -- --port 7778   # in one window
powershell -File tools\Test-Combat.ps1
powershell -File tools\Test-Sessions.ps1 -IncludeTimeout
powershell -File tools\Test-Dice.ps1
dotnet test dotnet\KcdMp.Farkle.Tests
```

`tools\Test-Pipe.ps1` additionally needs the real game running with the
plugin injected — see the script header.

## What's left undone, what still needs a human, and reporting bugs

### Not done

Things that are genuinely missing or impossible, as opposed to untested:

- **Emotes** — not implemented.
- **Duelling** — not implemented. The wire protocol reserves an
  `InteractionKind.Duel` value and nothing at all sits behind it; it reads
  like a shipped feature to anyone skimming `Protocol.cs` and it is not one.
- **Dice wagers** — a match is a pure score contest. No groschen moves.
  Transferring real currency needs a native (RTTR) write, not a Lua one.
- **Dice invite / accept / decline keybinds** — the console commands
  (`mp_dice`, `mp_accept`, `mp_decline`) are the working path. The key
  bindings in the code are built on guessed engine action names that have
  never been confirmed to fire.
- **NPC aggro** — *closed with evidence, not a to-do.* Replicated damage
  lands and can kill NPCs, but nothing reachable makes an NPC's AI react to
  it. They never fight back.
- **Faction manipulation** — *closed with evidence.* Writing faction
  ownership through the reflection layer corrupts a pointer the game owns and
  crashes it.
- **Reading the vanilla dice minigame's live state** — *closed with
  evidence.* That is why our dice is a separate engine rather than a mirror.
- **The master server (server browser backend)** — the Python service has
  never been run on any machine that touched this project. The .NET side is
  tested against a stub of its contract. The launcher's Join-by-address path
  does not need it; the browsable server list does.
- **Auto-detecting "you are actually in the world"** — the launcher asks you
  to confirm you have loaded your save before it injects, because injecting
  too early attaches a plugin that hooks nothing and only a fresh game launch
  recovers. It tells you either way; it cannot yet decide for you.
- **Installer code signing** — Setup.exe is unsigned, so a first download
  shows SmartScreen's "Windows protected your PC". Click *More info* →
  *Run anyway*.
- **A moved game is only half-handled** — re-running Setup finds the new path
  and re-deploys the mod, but will not overwrite a `GamePath` already set in
  your `settings.json`. The launcher notices the stale path at startup and
  opens Settings; it does not fix it for you.
- **`settings.json` follows the working directory, not the launcher** — the
  shortcuts the installer creates set it correctly. Launch
  `KCDMP_launcher.exe` from some other directory and it will read and write
  its settings there instead.

### Still needs a human, and has not had one

Nothing in this list has been executed. It is not a list of things believed
to work — it is the list of things nobody has watched happen.

**Two machines, two people — the real test.** Everything below is single-
machine or synthetic:

- [ ] Host on one PC, join from another, both load saves and connect.
- [ ] Each sees the other's ghost, hears proximity voice, and lands shared
      combat damage both ways.
- [ ] A full dice match played to completion on both screens.
- [ ] The same, with one player on a different network over a VPN overlay
      (see [docs/NETWORKING.md](docs/NETWORKING.md)).

**One machine, one person:**

- [ ] Launcher → HOST → START GAME → load a save → CONNECT, confirming
      `kcdmp-native.log` shows a nonzero `frames in ~1s` line for that run's
      pid and that `KcdMpClient.exe` starts.
- [ ] The deliberate failure case: click CONNECT *before* loading a save, and
      confirm you get the explicit "launch again" message within ~8s rather
      than a silent half-connected state.
- [ ] Whether `~` is actually the console key on your keyboard layout — the
      dice instructions above assume it.
- [ ] The installer's interactive wizard, including the Modding-Tools gate.
      Checklist: [docs/INSTALLER-TESTING.md](docs/INSTALLER-TESTING.md) tier 2.

**A machine that is not a development machine** — out of reach for this
project, which has exactly one PC:

- [ ] Fresh Windows with no WebView2 runtime: the installer's download and
      install of it has never been observed running.
- [ ] A PC with no Steam, and a PC with Steam but no Kingdom Come.
- [ ] A non-ASCII Windows username.

Full checklist and what each tier does and does not cover:
[docs/INSTALLER-TESTING.md](docs/INSTALLER-TESTING.md).

### Reporting a bug

Say which side you were on (host or join), what you were doing, and what you
expected instead. Then attach whatever of these exists — the paths are exact,
and `%LocalAppData%` / `%AppData%` / `%Temp%` can be pasted straight into
Explorer's address bar:

| What | Where | Attach it when |
|---|---|---|
| Launcher log | `%AppData%\KCDMP_Launcher\app<YYYYMMDD>.log` | Always. This is the first one to grab |
| Launcher settings | `%LocalAppData%\KCDMP\settings.json` | Always — it is three lines and it says which game it found |
| Native plugin log | `%LocalAppData%\KCDMP\kcdmp-native.log` | Injection, ghosts, combat, or dice not appearing in game |
| Game log | `<ModdingTools>\kcd.log`, e.g. `...\steamapps\common\KCD2Mod\kcd.log` | Anything in-game. Look for `[KCD2-MP]` lines |
| Agent output | The `KcdMpClient.exe` console window — **it writes no log file**, so copy the text out before closing it | Connected but nothing syncs |
| Relay output | The `KcdMpServer.exe` console window on the **host's** PC | Nobody can join, or people get dropped |
| Installer log | `%Temp%\Setup Log <date> #NNN.txt` — newest one | Anything that went wrong during install |

Also useful: your version (Add/Remove Programs → *KCD2 Multiplayer*), whether
both players are on the same network, and — for anything that looks like the
game ignoring the mod — confirmation that `<ModdingTools>\Mods\kdcmp\` exists
and that you launched through the launcher rather than through Steam.

Please redact your public IP from logs if you were playing over the internet.

## License and provenance

Licensed under the [GNU General Public License v3.0](LICENSE).

This is a fork of [`marczukmichal/kcd2-multiplayer`](https://github.com/marczukmichal/kcd2-multiplayer),
**continued here with the original developer's permission**, including
permission to upstream changes back if the two projects converge. All
credit for the original concept and implementation goes to marczukmichal —
this fork exists to keep building on that work, not to replace it. The
upstream repository carries no license of its own; that's a fact about the
upstream project, not a claim that it was itself GPL-licensed. This fork's
own code, from the point of forking onward, is licensed under GPLv3 as
stated above.
