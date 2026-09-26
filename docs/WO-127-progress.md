# WO-127 progress: the 0.29.9 test build

Session 2026-09-25/26, solo, mostly unattended. Findings:
`docs/WO-127-findings.md`. Tester page: `docs/TEST-0.29.9.md`. Runbook:
`docs/WO-124-first-shared-world-runbook.md` (updated).

## 1. Phases

| phase | state | where |
|---|---|---|
| 0 the Steam reading | answered: `IsSteamRunning` reads a registry pid the Steam client leaves at 0; InitFlat now decides; probe OK under 2429020 / 480 / 1771300 | findings §1 |
| 1 Steam as a connection path | built; relay listens beside TCP, agent dials a code, launcher Host/Join/Settings, host-claim authority rule, 20 s fallback | findings §2 |
| 2 plain errors + Test connection | built; `/connection-status`, `--test-connection`, mixed-build message on both sides | findings §3 |
| 3 leash recorder | built; host + joiner CSVs, native sample, cost measured | findings §4 |
| 4 gates, installer, tester page | green; `release\KCDMP-Setup-0.29.9.exe` built here; tester page + runbook | §3 below |

## 2. Code

* `dotnet/KcdMp.Steam`: `SteamApps`, `SteamJoinCode` (the code + app letter),
  `FriendsWithPresence`, `OwnRichPresence`; `TryStart` no longer gated on
  `IsSteamRunning`; steam_api's stderr silenced while it initialises.
* `dotnet/KcdMp.Protocol/ProtocolWo127.cs`: Position flag 0x40 HOST CLAIM,
  `ConnectionTestRelease`, `ConnectionTestReply`, `ConnectionTrouble` +
  `PlainConnectionError` (sentences, next steps, Steam fallback wording,
  exception classification).
* Relay: `RelayConnection`, `ClientSessionRunner` (the old TcpSocketService
  lifecycle, unchanged), `ClientSession` over a `Stream`, the connection-test
  answer, refused-release memory, host-claim handling;
  `ClientHandler.PickAuthority` rule 0; `Features/Steam`:
  `SteamRelayService`, `SteamRelayStatus`, loopback-only `LocalController`
  (`GET api/local/status`); CLI `--steam/--steam-app/--steam-game`.
* Agent: `RelayConnector`, `ConnectionTools` (`AgentConnectionStatus`,
  `ConnectionTest`, `SteamFriendsList`), `GameBridge.Wo127` (host claim),
  `GameBridge.Wo127Leash` + `LeashRecorder` (codec, CSV, rows), `CombatPipe.
  LeashSampleAsync`; IPC server lives as long as the agent; `--steam`,
  `--steam-app`, `--steam-game`, `--test-connection`, `--steam-friends`.
* Native: `leash.cpp/.h` (pipe 0x1F → 0x8F, paged), `npc_scan::
  for_each_in_radius`, `npcdrive::physics_status` / `stream_info`,
  `actions::brain_state`.
* Lua: `mp_leash_trace on|off`, `KCD2MP_LeashCtx`; pak rebuilt.
* Launcher: Host window Steam section, `JoinSteamModal`, `MessageModal`,
  TEST CONNECTION on the server list, Steam app in Settings, `AgentHelper`,
  `Home.Wo127.cs` (host status poll, Steam join, fallback, plain messages),
  log bundle carries the leash CSVs, the Steam code never written to
  settings.json.
* Tools: `Test-WO127Synthetic` (17), relay tests (+6), client tests (+34),
  synthetic WO-125 host claims the host, `Verify-Install` / `Test-PayloadSmoke`
  know `KcdMp.Steam.dll` and the WO-127 markers, `SteamProbe` report marker
  `wo120-probe-2` (so a report says which Steam check it used).

## 3. Gates and the installer

* `tools\Build-Installer.ps1` ran here end to end (exit 0): relay round-trip
  gate 48/48, client 325/325, 24 Lua suites (WO-127 17/17), both static Lua
  checks, native build, payload coherence + smoke (`RELAY-SMOKE ok ...
  release=0.29.9`), install manifest (1,026 entries), Inno Setup.
* **`release\KCDMP-Setup-0.29.9.exe`** (96.3 MB, local only; not on GitHub, no
  Release). The tester probe: **`release\wo120-probe\KcdMpSteamProbe.exe`**
  (rebuilt with the Phase 0 fix; `--selftest` green; no user name in either
  binary).
* Farkle 59/59, solution build, launcher build, synthpeer and avatarpeer
  builds: green.

## 4. Live method and side effects

* Modding Tools 1.5.5, Steam up. `kcd.log`, its backup and the native mirror
  log copied to the session scratchpad before each launch. Two launches;
  both quit with `System.Quit()`; no crash.
* Pak rebuilt and installed with the game closed (`Build-And-Install-Mod.ps1`).
  `KCDMP.dll` injected at the main menu by `KCDMP_LauncherInjector` under a new
  name per launch (`KCDMP-wo127a/b.dll`, from the scratchpad); the loaded
  module checked by name and `ModuleMemorySize`.
* Relay, agent and peers ran from scratchpad copies of their Release builds;
  `KCDMP_DATA_DIR` in the scratchpad.
* Run 1: the real game as the **joiner** at the main menu, WO-125's synthetic
  host serving a scratchpad copy of `playline1/quicksave038` through a local
  relay → Bring my character (from `playline2/quicksave022`) → Ready in 58 s;
  joiner recorder for ~2 min; one NPC paused and resumed by console to verify
  the brain read; the player moved next to two NPCs (`SetWorldPos`) to read
  their physics. Then the real game as the **host** (agent `--hosting`) with
  a scripted avatar peer (WO-121's `avatarpeer`) that connected first and
  walked ~150 m away and back; relay with Steam on (2429020); host recorder;
  Test connection (direct, own Steam code), Steam friends lookup; a second
  agent dialled a code nobody hosts (a synthetic account id past any
  allocated one) to watch the fallback.
* Run 2 (rebuilt DLL): `wh_sys_LoadGame 1 quicksave038`, the same host run
  for the living "simulated" column and a third cost window.
* In-game time 16:51–16:56 (daytime). No fights; no NPC attacked or touched
  beyond the one pause/resume; `mp_spawn_armor` never used.
* Saves: none created, changed or deleted (checked after each run). The
  join's transient `playline2/mpworld1d0ef4fa.whs` was written and deleted by
  the join itself, as designed.
* One earlier connect-timeout check (before the synthetic id was chosen)
  dialled a code built from an arbitrary account id; nothing listened there
  and nothing was sent but Steam's own connect attempt.

## 5. Decisions (made unattended, with why)

* **The game window was not brought to the front.** The session prompt asks
  for it (WO-119's rule); the maintainer's standing feedback (2026-09-25) is
  never to steal focus during unattended WOs because they use the same
  desktop. I kept to the feedback: console and agent only. Consequence: fps
  ~26 (the background limiter), so the per-frame cost is an upper bound.
* **Authority by claim, carried in the Position flags byte** (no new message
  type, no version bump): the only upstream message every agent sends from
  the first second, including at the menu. A handshake field could not follow
  `mp_shared_world` flipping later.
* **The app id rides in the join code** (one letter for non-default ids), so a
  mismatch is caught before Steam is even started; Steam itself cannot tell
  "wrong app" from "not hosting".
* **The launcher never loads Steam**: a Steam session in the launcher would
  show the player in game as long as it is open; the agent runs as a one-shot
  helper instead.
* **Test connection = a refused handshake**, so it works against every relay
  since WO-110 R9 and can never become a session or spawn a ghost.
* **`phys_awake` kept only for non-living bodies**, `phys_sim` added: the
  engine never answers "awake" for a character (observed, and the base
  implementation says so).
* The recorder writes beside `agent.log` (the "mod's log folder" testers
  already collect, and the one the REPORT BUG zip reads).

## 6. What is left

1. The two-network Steam test and the first real two-player session (WO-128;
   tester page).
2. The launcher's new windows looked at on screen.
3. Final default Steam app id (the maintainer).
4. The recorder's 4 ms per-sample hitch, if it is ever kept on.
