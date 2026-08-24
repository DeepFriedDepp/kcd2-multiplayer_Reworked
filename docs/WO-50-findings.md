# WO-50 — research for main-release polish: Discord presence, HUD cleanup, launcher icon

Worked 2026-08-24 (Sonnet 5). Research only, per the session brief — nothing
in this WO is implemented. Three ready-to-build specs follow.

`docs/branding/kcd2-mp-logo.png` committed — copied from the human-provided
`docs/branding/npp_kcd_mp_color.png` (2048×2048, 8-bit RGBA, real alpha,
confirmed via `file`).

---

## Phase 1 — Discord Rich Presence

### 1. Discord Application: does not exist yet — human action required

Searched the repo for any registered Client ID, asset key, or Discord
Developer Portal reference. Found none. The only existing Discord footprint
is a community server invite (`discord.gg/m4U95xUZ5`, `docs/WO-19-progress.md`,
`README.md`) wired to the launcher's REPORT BUG button
(`KCDMP_launcher/Components/Shared/UrlLauncher.cs`) — unrelated to a Rich
Presence application. **Confirmed absent, not assumed.**

**What the human needs to do, before a build WO can start:**
1. Go to the Discord Developer Portal, create a new Application (any name,
   e.g. "KCD2 Multiplayer"), and copy its **Application ID** (this is the
   Rich Presence "Client ID").
2. Inside that application, open **Rich Presence → Art Assets**, click
   **Add Asset**, upload `docs/branding/kcd2-mp-logo.png`, and give it a
   **Key** (e.g. `logo`). Images should be ≥512×512 (1024×1024 recommended);
   the 2048×2048 source clears that easily. Assets are usually available
   within minutes, occasionally up to a few hours.
3. Hand over: **Client ID** + **asset key** (e.g. `logo`). Nothing else is
   needed — basic Rich Presence (status text + one large image) does not
   require Discord app review/verification, unlike features such as
   Ask-to-Join or Spectate.

### 2. Library: `DiscordRichPresence` (Lachee/discord-rpc-csharp) — confirmed current

Searched NuGet directly rather than trusting memory. Latest version
**1.6.1.70, published 2025-08-04** (~1 year before this session, reasonable
for a small, stable API surface). 6.6M total downloads, MIT licensed,
targets **.NET 9.0**, .NET Standard 2.0, and .NET Framework 4.5+. This is the
de facto standard unofficial C# implementation of Discord's classic
IPC-based Rich Presence protocol — not the newer "Discord Social SDK" (a
larger, separate API for deeper social features like invites/friends that
this task does not need).

[DiscordRichPresence on NuGet](https://www.nuget.org/packages/DiscordRichPresence) ·
[Lachee/discord-rpc-csharp on GitHub](https://github.com/Lachee/discord-rpc-csharp)

### 3. Owning process: the agent (`KcdMp.Client`), not the launcher — confirmed from code, not assumed

Read `KCDMP_launcher/Pages/Home.razor.cs`'s `ConnectToGame()`: once the agent
starts, the UI literally displays **"Connected. You can close this once
you're playing."** (line 656). And `ConfirmExit()` (the launcher's own quit
handler, line 1209) calls `StopHostedRelay()` and `StopHostedMasterServer()`
but **never** stops `agentProcess`. So the launcher is explicitly designed
to be closable mid-session, while the agent (`KcdMp.Client.exe`,
`dotnet/KcdMp.Client/Program.cs`) is the process that persists for the
actual play session — it owns the relay connection (`GameBridge.RunAsync`)
and lives until the player quits the game or the agent itself. Presence
belongs on the agent.

**Consequence:** the launcher and agent are separate .NET executables
(`KCDMP_launcher.csproj` vs `KcdMp.Client.csproj`), so the Discord IPC
connection, the `PackageReference`, and the update loop all belong in
`dotnet/KcdMp.Client/`, most naturally as a new class alongside
`GameBridge.cs`.

### 4. Implementation spec

**State to show:**
- `Details`: `"Hosting"` or `"Playing"` (joined) — see the caveat below.
- `State`: mod version, from the already-existing `ReleaseVersionInfo.Current`
  (`dotnet/KcdMp.Client/ReleaseVersionInfo.cs`) — free, no new plumbing.
  Optionally append peer count once connected (see below).
- `LargeImageKey`: the asset key handed over in step 1.2 above.
- `StartTimestamp`: set once, at agent startup, so Discord shows elapsed
  session time ("00:14 elapsed").

**Hosting vs. joined — flagged, not solved:** `ClientConfig`
(`dotnet/KcdMp.Client/ClientConfig.cs`) has no `IsHosting` concept; the agent
always just connects to `ServerHost:ServerPort` like any client, whether or
not that relay happens to be one the launcher spawned locally
(`hostedRelayProcess` in `Home.razor.cs`). The launcher *does* know which
case it is. Cleanest fix: launcher passes a new flag (e.g. `--hosting`) on
the existing agent command line (`ConnectToGame`'s `agentArgs`, line 641)
when it also started `hostedRelayProcess`; the agent just threads it through
to the presence text. Don't infer it from `ServerHost == "localhost"` — a
host on a LAN address would misclassify.

**Peer count:** available cheaply from `_ghostReleaseVersions` (or the
equivalent live ghost-id set) in `GameBridge.cs` — it already grows/shrinks
as peers connect/disconnect (`ReleaseVersion` packet, `0x1E`).

**Update triggers:**
- On agent startup (after config load, before `RunAsync`): initialize Discord
  RPC, set initial presence (`Details = "Connecting..."`).
- On relay connect (`ConnectAndRunAsync`, after the TCP connect succeeds):
  update to `Hosting`/`Playing` + version.
- On a peer's `ReleaseVersion` packet arriving/leaving: update peer count.
- On disconnect/shutdown (the existing `ProcessExit`/`CancelKeyPress`
  handlers in `Program.cs`): call `Dispose()` on the RPC client so the
  presence clears instead of sticking on a stale state after the agent
  exits.

**What the human must hand over before this can be built:** Client ID +
asset key (step 1 above). Nothing else blocks implementation once those two
values exist.

---

## Phase 2 — hide the debug HUD overlay for release builds

### 1. CVar identified and live-verified: `r_DisplayInfo`

Live-tested against the running Modding Tools build over the project's
standard debug REST API (`localhost:1403/api/System/Console/...`, the same
one every prior WO's probes use — see `tools/KcdApi.ps1`, `docs/kcd2_lua_api.md`):

```
GET /api/System/Console/GetCvarValue?name=r_DisplayInfo   → "3"   (default, on)
GET /api/System/Console/ExecuteString?command=r_DisplayInfo%200   → set to 0
GET /api/System/Console/GetCvarValue?name=r_DisplayInfo   → "0"   (confirmed)
```

**Human visually confirmed** (session live, game running, connected): with
`r_DisplayInfo=0` the build/memory/FPS corner block disappeared; the
ping/network indicator stayed visible. Restored to `3` afterward — readback
confirmed. This is the standard CryEngine debug-info overlay CVar (0=off,
1–3=increasing detail); nothing here is guessed from general engine
knowledge without the live round-trip above.

### 2. Confirmed separate from the ping/network indicator — different systems entirely

Not just "a different setting" — a **different rendering mechanism**. The
ping indicator is the **mod's own Lua code**, not an engine overlay:

```lua
-- kdcmp/Data/Scripts/Startup/kdcmp.lua:3490-3493
if KCD2MP.pingText then
    System.DrawText(10, 10, KCD2MP.pingText, 2)
end
```

(`KCD2MP_ShowPing`, line 124, sets `KCD2MP.pingText` from the agent's
measured latency.) `r_DisplayInfo` cannot affect it because it isn't an
engine-drawn element at all — it's the mod calling `System.DrawText` every
frame, same mechanism documented in memory ([[kcd2-lua-drawing-limits]]) as
the only screen-draw call that actually renders. Live test confirmed this
plainly: toggling `r_DisplayInfo` never touched the ping line.

### 3. Mechanism for off-by-default-but-toggleable: mod-side `System.SetCVar`, not an engine config file

This project already has the right tool for exactly this, live in
`kdcmp.lua`, and already used for an equivalent problem
(`KCD2MP.dice.requireTable`, flipped by `mp_dice_gate on|off`,
line ~1624). The Lua API doc (`docs/kcd2_lua_api.md:14-15`) confirms
`System.SetCVar(name, value)` / `System.GetCVarValue(name)` are real,
callable bindings — not the external REST-only surface, callable directly
from the mod's own script.

**The concrete mechanism:** add near `MOD INIT`
(`kdcmp/Data/Scripts/Startup/kdcmp.lua:1-2`), gated by a flag so a future
debug session can flip it without editing code:

```lua
KCD2MP.debugHud = false   -- release default: OFF
if not KCD2MP.debugHud then
    System.SetCVar("r_DisplayInfo", "0")
end
```

Plus a console command mirroring the existing `mp_dice_gate`/
`mp_enable_aggro` pattern (`System.AddCCommand`, registered alongside the
other `mp_*` commands around line 6642):

```lua
System.AddCCommand("mp_debug_hud", "KCD2MP_DebugHud('%LINE')", "on|off: toggle the CryEngine debug HUD (r_DisplayInfo) without a rebuild")
```

This is a **mod-side** override, reasserted every time `kdcmp.lua` loads —
it does not touch the base game's own `system.cfg`/`autoexec.cfg` (found no
existing mechanism there; the mod doesn't currently write engine config
files at all, and shouldn't start here). It survives a player's own engine
config regardless of what CryEngine or Modding Tools shipped as the
built-in default, and it is trivially reversible for debugging by running
`mp_debug_hud on` from the console — no rebuild, matching the existing
`mp_dice_gate` convention exactly.

No human action needed for this phase — everything is mod-code, ships in
the pak like every other WO's Lua change.

---

## Phase 3 — new launcher icon

### 1. Where the icon is set today — confirmed empty

- `KCDMP_launcher/KCDMP_launcher.csproj` has **no `<ApplicationIcon>`
  property at all** — the launcher currently ships with the .NET SDK's
  generic default exe icon.
- `installer/KCDMP.iss`'s `[Icons]` section (Start Menu shortcut, desktop
  shortcut) sets `Filename: "{app}\{#AppExeName}"` with **no
  `IconFilename` override** — both shortcuts read whatever icon is embedded
  in `KCDMP_launcher.exe` itself. **One change point, not two**: fix the
  exe's own icon and both shortcuts inherit it automatically. No installer
  script edit needed.

### 2. Conversion path: real multi-resolution `.ico`, two viable options — confirmed, neither installed here

Checked this machine: no ImageMagick (`magick`/`convert` — the only
`convert.exe` found is Windows' own unrelated file-system conversion
utility), no Python. `KCDMP_launcher.csproj` already sets
`<UseWindowsForms>true</UseWindowsForms>`, which pulls in
`System.Drawing.Common` for free — no new package needed for option B.

**Option A — ImageMagick** (industry-standard, most reliable, one command):
```
magick docs/branding/kcd2-mp-logo.png -define icon:auto-resize=256,128,64,48,32,16 KCDMP_launcher/app.ico
```
Requires installing ImageMagick first (`winget install ImageMagick.ImageMagick`)
— a one-time tool install, not attempted this session since this WO builds
nothing.

**Option B — small in-repo conversion helper, zero new dependencies:** a
short C# console snippet using `System.Drawing.Bitmap` to resize the source
to each target size (256/128/64/48/32/16 px) and encode each as PNG, then
hand-write the standard Vista+ `.ico` container (`ICONDIR` header +
`ICONDIRENTRY` array + PNG-compressed image data per entry — a well
documented ~50-line binary format, not a guess). Avoids installing anything
new; slightly more code to write and verify once.

Either produces a real multi-resolution `.ico` — a single upscaled 256px
image renamed `.ico` (the failure mode explicitly flagged in the brief) is
not proposed by either option.

### 3. Concrete spec

**Files to change:**
- Add `KCDMP_launcher/app.ico` (or similar), built from
  `docs/branding/kcd2-mp-logo.png` via Option A or B above.
- `KCDMP_launcher/KCDMP_launcher.csproj`: add
  `<ApplicationIcon>app.ico</ApplicationIcon>` inside the existing top
  `<PropertyGroup>`. Covers the exe's file icon — Explorer, Start Menu
  shortcut, desktop shortcut, taskbar icon **when the app is not running**.
- `KCDMP_launcher/Program.cs`: add a `MainWindow.SetIconFile("app.ico")`
  call in the existing `MainWindow` chain (next to `SetTitle`/`SetSize`,
  line ~56-62). Photino's window icon is a **separate** setting from the
  exe's embedded resource — needed for the title bar and the taskbar icon
  **while the app is running**.

**Known residual risk, flagged rather than papered over:** an
open/unresolved Photino.NET issue
([tryphotino/photino.NET#106](https://github.com/tryphotino/photino.NET/issues/106))
reports that on Windows 11, even with both `ApplicationIcon` and
`IconFile`/`SetIconFile` set correctly, the **running window's taskbar
icon** can still fall back to a generic icon (the title bar icon works).
No confirmed workaround exists upstream as of this search. Do both settings
anyway — they're the only levers that exist and they fix the file-icon
cases unconditionally — but the build WO should visually check the taskbar
specifically after a real install, not assume it's fixed by the code
change alone.

**Nothing else needs a separate change:** confirmed no `IconFilename`
override in `KCDMP.iss`, no icon handling in `tools/Publish-Release.ps1`,
and no other launcher-facing executable (agent, relay, injector) ships a
visible icon anywhere a user would see it.
