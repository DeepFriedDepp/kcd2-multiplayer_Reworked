# WO-120 progress: connect through Steam

Findings and the Phase 0 ranking: `docs/WO-120-findings.md`.
Runbook for the gate: `tools/wo120/README.md`.

## 2026-09-24: Phase 0 prepared, gate waiting on a second network

- **Read:** `GameBridge.ConnectAndRunAsync` / `WritePacketAsync` (whole frames
  under one lock), `ClientSession` (authority via `IsLoopback`),
  `ClientHandler` (relay-local wins), `TcpSocketService`, WO-110 R4/R9.
- **The game's Steam DLL** (code-verified): `Bin\Win64Shared\steam_api64.dll`,
  identical in retail and Modding Tools; 1070 exports; `SteamAPI_InitFlat`,
  SteamUser v023, SteamNetworkingSockets v012, SteamNetworkingMessages v002,
  SteamNetworkingUtils v004, SteamFriends v017, SteamNetworking v006.
- **The game's app id** (code-verified): 2429020 (Modding Tools
  `steam_appid.txt`), not 1771300.
- **Built `dotnet/KcdMp.Steam`** (no product code references it yet):
  - `SteamNative`: the flat API calls used, bound to the game's DLL
  - `SteamLibraryLocator`: finds that DLL (env, exe dir, launcher GamePath, Steam libraries)
  - `SteamSession`: `InitFlat` under a chosen app id, manual-dispatch pump
    thread (1 ms), relay/auth readiness, P2P listen/connect, rich presence,
    friends in the same app
  - `SteamP2PConnection` + `SteamConnectionStream`: reliable ordered messages
    as a `Stream`, backpressure by retry, never drop
  - `FriendCode`: the host's code, 7 chars + check
  - `SteamLogScrub`: strips SteamIDs and addresses from Steam's text
- **Built `tools/wo120/SteamProbe`**: double-click host/join/check, one child
  process per app id (2429020, 480, 1771300), all three APIs, game-shaped
  traffic, privacy-clean report file.
- **Observed locally:**
  - `--selftest`: codes 100,000/100,000 round-trip, 90.3% single-typo
    rejection, scrubber 0 leaks
  - `check`: `SteamNotRunning` under all three app ids. Steam's
    `ActiveProcess` was `pid=0 ActiveUser=0` although `steam.exe` ran as this
    Windows user, so Steam wasn't logged in. No Steam networking exercised yet.
  - Published probe (self-contained single file, 35 MB) has no user-profile
    paths in its binaries.
- **Blocked on the maintainer:** the two-network run (runbook). Phase 1 is not
  started, per the gate.
