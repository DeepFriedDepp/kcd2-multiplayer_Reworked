# KCD2 Multiplayer

An unofficial multiplayer mod for Kingdom Come: Deliverance II. It lets two
or more people play the same open world together at once: you see each
other as ghost NPCs (position, animation, nameplates, and each other's
actual equipped armor *and* weapons — not one fixed costume), hear each other over
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
| Native plugin + injection | **Working** — the liveness race that used to make early injection silently no-op is fixed and verified by a real cold-start injection (the DLL now polls for the game's tick instead of sampling once, and picked the tick up 42s after hooking where it previously aborted at 1s). One **residual gap** remains in the step immediately after it — see below |
| Ghost presence (position/animation/nameplates) | **Working**, including while *you* are in a menu — ghosts keep moving instead of freezing and snapping, measured at 6–7 m of real ghost travel during a menu that previously froze them dead. A peer who is *themselves* in a menu is tagged **`[in menu]`** on their nameplate, confirmed on screen. Your own nameplates stay hidden during your own menu, as before — see below |
| Ghost faces | **Working** — each connected player is deterministically assigned one of 48 real, hand-placed NPC faces from the game's own roster (the same name always gets the same face, including across reconnects), instead of every ghost sharing one generic look |
| Reconnecting | **Fixed** — rejoining under a new connection used to orphan your old ghost instead of replacing it, leaving stray duplicate ghosts stacked on top of you; identity, not connection id, now decides which ghost is yours. A related launcher bug is fixed alongside it: closing only the game (not the launcher) and reconnecting could start a second agent process on top of a stale one, with the two fighting over the same ghost forever — visible in-game as an NPC seemingly attached to the player. The launcher now stops any existing agent before starting a new one |
| Appearance sync (ghosts mirror your real equipped armor and weapons) | **Working** against synthetic peers and in real single-machine play — per-item, not a fixed costume; **unverified** with a second real human. Weapons go through the same mechanism as armor and were human-confirmed on screen across swords, an axe, a mace, shield+sword and a crossbow. Individual equip/unequip calls occasionally take several seconds to a couple of minutes to actually land under load — a **known rough edge**, not silently broken, see below |
| Shared combat | **Working** against synthetic peers and in real single-machine play; **unverified** with a second real human |
| Shared player health and death | **Working** — every player's own health and stamina now reach everyone else, so a peer's ghost shows their real `HP`/`ST` on its nameplate instead of looking permanently healthy while its owner is being killed. A player who dies is announced explicitly by their own game (never guessed from health hitting zero) and their ghost is tagged **`[dead - reloading]`**, clearing by itself once they are back in the world. Live-verified end to end on one machine, 17/17. **What death does is ordinary single-player behaviour: you reload your own most recent save.** Nobody else's world reverts — every player has always had a completely separate save, and this mod has never had, and is not getting, a way to sync one player's save into another's |
| NPC hits on a player crossing between players | **Built, guards verified, cross-machine step UNVERIFIED.** An NPC attacking your ghost in someone else's world reports the damage back to you, so NPC combat can hurt a remote player rather than only their stand-in. Exactly one client holds this authority at a time (the relay assigns it) — without that, every player's own NPCs would independently damage everyone and multiply the damage by the player count. All three guards around it are individually verified live, plus a positive control. The actual hit crossing two machines was **not** tested: there is one machine here and no second player. **This does not synchronise NPCs themselves** — each player still sees their own local version of any fight; what's shared is only who got hurt and who died, never the NPC's position, animation or AI state |
| Recovering from a mid-session save reload | **Fixed this release, live-verified.** Loading a save used to permanently stop that player transmitting at all — they simply vanished for everyone else for the rest of the session — and destroyed every other player's ghost body in their world while leaving the floating nameplate walking around with nothing under it. Both were measured (dead for 197s and 187s respectively, still going when the test ended) and both now recover on their own in about 14 seconds |
| Reactive ghost combat (self-defense, joining nearby fights) | **Working, always on, no toggle** — a ghost has a real soul and brain, so it defends itself when attacked (treats it as a crime, arms itself, lands real damage) and will join a fight already happening near it, independent of `mp_enable_aggro` below. Verified taking a real player from 100 to 57 HP in one exchange, and separately pursuing and killing another ghost 340 m from where both spawned. A knocked-out ghost also gets back up on its own, usually within a minute. Its position is still pinned to its owner's real movement during a networked session, so it cannot step, close, or retreat — a real, unresolved gap. **A ghost's own attacks are not replicated to its owner** — a remote player's character can kill NPCs in your world that its owner never actually attacked, invisibly to them |
| NPC aggro on ghosts (`mp_enable_aggro`) | **Working, opt-in, off by default** — this does NOT turn the reactive combat above on or off; that already happens regardless. What the toggle actually gates is *proactive, faction-wide* hostility: when on, a ghost that lands or receives a hit gets attached to one real hostile faction for ~20s, so *any* nearby NPC of an opposing faction — not just whoever it's already fighting — can recognize and attack it unprompted. When off, that native attach never fires. Verified end-to-end (synthetic peer → relay → agent → native plugin → game) via a live on/off comparison and repeated live fights; **unverified** with a second real human. **Known limits, not bugs** — see below |
| NPC sync (`mp_npc_sync`) | **Working, ON by default** (WO-32) — up to 5 hand-placed NPCs within 30 m of the session's world-authority player mirror that player's world on everyone else's machine: position, walking/running animation, health, death. Verified end to end (15/15): the emitted stream matches engine-resolved positions, the relay refuses NPC state from any client that isn't the authority, and a real NPC was driven over the real wire, then released cleanly back to its own schedule (observed restoring to its exact anchor, still talkable, no crime/faction side effects). Costs less bandwidth than one player's position stream. **Turn it off with `mp_npc_sync off`** in the console — only meaningful on the authority's machine (the same client that holds combat authority; in practice, the host), since only that client transmits; everyone else just renders what arrives. **Unverified** with a second real human; dialogue with an NPC *while* it is actively being driven is untested (before/after works) |
| Voice chat | **Working**, proximity-based |
| Session framework (invites/accept/decline) | **Working** |
| Dice engine (Farkle) | **Working** — 59/59 unit tests |
| Dice ↔ relay integration | **Working** headlessly; **unverified** with two real humans |
| In-game dice UI | **Working** — played to completion against a scripted opponent; **unverified** with two real humans |
| Emotes | **Not implemented** |
| Duelling | **Not implemented** — the wire protocol reserves a slot for it, nothing behind it |
| Master server (server browser backend) | **Working, live-tested** (WO-35) — a community-contributed C# service (`dotnet/KcdMp.MasterServer/`) replaced the never-run Flask service. Relay↔master↔launcher exercised end-to-end with the real code on all three sides: announce, live update, and delisting within ~1s of a relay disconnecting |
| Launcher (host/join, dependency handling) | **Built but unverified end-to-end** — see below. Shares the in-game dice overlay's art direction (aged parchment, oak, gold) across every screen rather than looking like a generic dark app; has a **REPORT BUG** button in the status bar that opens this project's GitHub Issues or Discord; and warns you before you connect if you and your peer are on different mod versions, naming which side needs to update |
| Installer (`KCDMP-Setup-<version>.exe`) | **Working** — silent install/upgrade/uninstall and Steam detection both covered by automated suites (41/41, 21/21) on one machine; the interactive wizard and any clean machine are **unverified**, see `docs/INSTALLER-TESTING.md`. **Hardened against half-applied updates** (WO-32 follow-up, after a real one): Setup refuses to install while the launcher/agent/relay/game is running, verifies every installed file against a size manifest afterwards (verdict in `install-verify.txt`), and the launcher itself warns at startup if the install directory holds a mix of two builds |

**NPC aggro (`mp_enable_aggro`) — known limits, v1 scope, not bugs:**
- **Hitting another player's ghost in a town is a crime.** A ghost is a real
  `Civilians`-faction NPC, so attacking one inside a settlement can draw guard
  aggro onto *you*.
- **One hostile faction for all of v1** — a real bandit faction hostile to
  ordinary townsfolk, not a nuanced per-NPC-type system.
- **The hostile-faction attach depends on a playthrough-specific donor soul**
  (a leftover NPC from a specific earlier ambush sequence). On a save that
  hasn't reached that ambush, the attach fails quietly — logged, not crashed,
  but `mp_enable_aggro` does nothing observable on such a save.
- **Not synchronized between clients** — whether an NPC treats a ghost as
  hostile is decided entirely by that NPC's own player's local toggle and
  local combat events, not agreed between both players.
- **Not tested with a second real human** — verified end-to-end via a
  synthetic peer through the real relay and agent, not a real second player.

## How to play with a friend

1. Both of you install the mod (below) and the launcher.
2. One of you clicks **HOST GAME** in the launcher — it starts a relay and
   shows you the address to share.
3. The other clicks **ADD SERVER**, enters that address, and clicks **JOIN**.
4. Both of you click through to load into the game world; the launcher
   handles injecting the plugin and starting your agent once you confirm
   you're actually in-game.
5. Once both loaded, ALT+TAB into the launcher and choose the "Connect" option

Same Wi-Fi/LAN: that's it. Different houses: see
**[docs/NETWORKING.md](docs/NETWORKING.md)** for the two ways to connect
over the internet (a VPN overlay like Tailscale — recommended — or port
forwarding), including exactly what address and port to share.

### Install

1. Download **`KCDMP-Setup-<version>.exe`** from the releases page.
2. Run it.
3. That's it — use Host or Join as above.

> **One-time step done by Steam/Warhorse's own tools, not ours — do this
> before your first launch, regardless of the order you install things in.**
> The KCD2 Modding Tools app does not ship with its own copy of the game's
> data (animations, characters, tables, scripts, cinematics, and more) — only
> a `Developer.pak`. The first time you install it, launch it **once through
> Steam itself** (its own Play button, or the shortcut Steam creates for it)
> and let **Workspace Setup**
> (`Tools\ModdingWorkspaceSetup\WorkspaceSetup.exe`) run — it copies the
> missing data from your base **Kingdom Come: Deliverance II** install into
> the Modding Tools folder. You need to own and have the base game installed
> too, since that's where the copy comes from.
>
> Skip this and the game will start, then immediately crash:
> *"Database system error — 114 tables are not loaded. See log for details.
> Ensure you have latest tables."* This is **not** this mod and **not** our
> installer — reproduced with the mod entirely removed, same crash. Our
> `Setup.exe` currently has no way to detect it; see "Not done," below.

The installer finds your game through Steam, deploys the mod into it,
installs the launcher, writes the game path into the launcher's settings so
there is nothing to configure, and puts a shortcut on your desktop. If the
free **KCD2 Modding Tools** are not installed it will say so, offer a button
that starts that download in Steam, and refuse to continue until they are
there — the retail game genuinely cannot run this mod, it lacks the debug
API and the module layout the plugin needs.

You need Kingdom Come: Deliverance II on Steam, plus that Modding Tools
entry (free, a separate item in your Steam library). Nothing else: the
launcher, agent and relay carry their own .NET runtime, and the installer
fetches Microsoft's WebView2 runtime if your Windows doesn't already have it.

Installing by hand still works and is documented in
[docs/LAUNCHING.md](docs/LAUNCHING.md) — use it if the installer misbehaves
or your Steam setup is unusual.

### Already installed? Update in 2 steps — no reinstall needed

Everyone you play with needs the same version, not just the host — an old and
a new build won't connect to each other.

Download **`KCDMP-DirectInstall-0.11.5.zip`** from the release and unzip it. It
contains two folders, `App` and `Mod`:

1. Copy the **`App`** folder's contents into your existing install folder
   (`%LocalAppData%\KCDMP` — paste that into Explorer's address bar),
   overwriting when asked. Your `settings.json` is not in the zip, so the game
   path you already have is left alone.
2. Copy the **`Mod`** folder's contents into your game's mod folder
   (`<your KCD2 Modding Tools folder>\Mods\kdcmp`), overwriting when asked —
   that's `mod.manifest` and `Data\kdcmp.pak`, the same two files Setup.exe
   deploys there and the only two that belong there.

Close the launcher first. That's it — no need to run Setup.exe again, and
nothing else on your PC is touched. Prefer a full reinstall? Running
`KCDMP-Setup-0.11.5.exe` over the top does that and keeps your settings too.

**Building the installer yourself:**

```
powershell -ExecutionPolicy Bypass -File tools\Build-Installer.ps1
powershell -ExecutionPolicy Bypass -File tools\Build-DirectInstall.ps1 -SkipPublish
```

The first publishes everything self-contained and compiles
`release\KCDMP-Setup-<version>.exe`; the second zips that same published
output into `release\KCDMP-DirectInstall-<version>.zip` (`App\` + `Mod\`, as
above), reusing the publish the first one just did. Building the installer
needs [Inno Setup 6](https://jrsoftware.org/isinfo.php)
(`winget install --id JRSoftware.InnoSetup`); the zip needs nothing extra.

Both read the version from the `VERSION` file at the repo root and from
nowhere else, so they cannot disagree about it. That number is chosen by hand,
never bumped automatically — see [docs/VERSIONING.md](docs/VERSIONING.md).

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
| `dotnet/KcdMp.MasterServer/` | `KcdMpMasterServer.exe`, the server-discovery backend (WO-35) — see `docs/MASTER-SERVER.md` |
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
dotnet run --project dotnet\KcdMp.MasterServer
```

The master server (`dotnet/KcdMp.MasterServer/`) is optional — a relay and
launcher with each other's address connect directly and never touch it. See
`docs/MASTER-SERVER.md` for how to point a relay and the launcher at one.

## Testing

```powershell
dotnet run --project dotnet\KcdMp.Server -- --port 7778   # in one window
powershell -File tools\Test-Combat.ps1
powershell -File tools\Test-Sessions.ps1 -IncludeTimeout
powershell -File tools\Test-Dice.ps1
powershell -File tools\Test-PlayerCombat.ps1
dotnet test dotnet\KcdMp.Farkle.Tests
```

`tools\Test-Pipe.ps1` additionally needs the real game running with the
plugin injected — see the script header. `tools\Test-AppearanceE2E.ps1` and
`tools\Test-PlayerVitalsE2E.ps1` need the real game and a running agent, but
**not** the native plugin — appearance sync and player vitals never touch the
DLL or the pipe, only the reflection debug API. `tools\Test-ReloadBehaviour.ps1`
needs all of that plus a human to reload a save mid-test. Every synthetic-peer
script derives its wire-protocol version from `tools\ProtocolVersion.ps1`
rather than hardcoding it — never add a new literal version byte to a script.

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
- **Appearance sync's write latency is genuinely variable** — equipping or
  unequipping one item on a ghost usually lands within a second, but under
  heavier load it has taken up to a couple of minutes, and it self-heals via
  a 30-second resend rather than promising a fixed time. `mp_sync_appearance`
  forces an immediate resync if you don't want to wait. Hairstyle, face and
  beard do not sync — no reflected engine surface exposes them at all.
  Weapons *do* sync, through the same mechanism as armor.
- **Unequips are not verified the way equips are** — the agent retries what
  should now be *on* a ghost, but never confirms that what should now be
  *gone* actually went. A weapon unequipped several steps earlier was once
  observed back in a ghost's equipped map, reproducibly, minutes later. Not
  root-caused: it may be the game refilling an empty weapon slot from the
  ghost's own inventory rather than a failed write.
- **The soul walk right after injection still gives up after one 5s try** —
  the tick-liveness check above it now polls and retries; the step after it
  does not. Inject in the narrow window where the game has started ticking
  but a save has not finished loading and that injected instance declines to
  start the pipe, with no second attempt.
- **Reading the vanilla dice minigame's live state isn't possible** — its
  in-progress state isn't reachable from outside it. That's why dice is a
  separate relay-authoritative engine instead of mirroring the vanilla
  minigame.
- **The master server (server browser backend)** — the Python service has
  never been run on any machine that touched this project. The .NET side is
  tested against a stub of its contract. The launcher's Join-by-address path
  does not need it; the browsable server list does.
- **Auto-detecting "you are actually in the world"** — the launcher still asks
  you to confirm you have loaded your save before it injects. Injecting too
  early is no longer fatal (the plugin waits for the game's tick instead of
  giving up on it), but the launcher cannot yet decide for you when you are
  really in the world, so it asks.
- **Nameplates are hidden while *your own* menu is open** — ghost bodies keep
  moving during your menu, but the `System.DrawLabel`/`DrawText` calls that
  draw names are immediate-mode, one frame per call, and the update pump is
  not frame-locked to the renderer. Pumping them would strobe rather than
  render, so they stay off. This is unchanged from before the menu fix, not a
  regression from it.
- **The installer does not detect an incomplete Modding Tools data
  install** — it verifies `Framework.dll`/`CrySystem.dll` exist beside
  `KingdomCome.exe`, which proves the *engine binaries* are the right build.
  It does not check for the actual game data (`Data\Tables.pak` and the
  other mandatory paks), so a Modding Tools install that has never had its
  one-time **Workspace Setup** step run (see Install, above) passes the gate
  and then crashes the game with "114 tables are not loaded" — a real,
  reproduced failure, not a hypothetical one.
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

### Reporting a bug

The launcher's status bar has a **REPORT BUG** button — it opens either the
GitHub Issues page or this project's Discord directly, whichever you'd
rather use.

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
