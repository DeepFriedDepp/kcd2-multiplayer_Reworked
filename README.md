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

### Install

1. Own Kingdom Come: Deliverance II, and install the **KCD2 Modding Tools**
   entry from Steam (a separate library item — the base game alone cannot
   run this mod, it lacks the debug API and module layout the plugin needs).
2. Copy `kdcmp/` into the Modding Tools install's `Mods/` directory:
   `<ModdingTools>\Mods\kdcmp\`.
3. Download a launcher release and run it. Point it at your Modding Tools
   `KingdomCome.exe` in Settings if it doesn't find it automatically.
4. Use Host or Join as above. The launcher launches the correct game build,
   injects the plugin, and starts your agent — no manual DLL injection, no
   console commands, no hand-edited config for the common case.

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
