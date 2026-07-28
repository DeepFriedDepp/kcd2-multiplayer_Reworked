# How to launch

## The manual flow

This is still the flow every test in `tools\` assumes, and the one to fall back
to when something misbehaves.

1. **Relay** — on one machine (either player's PC or a dedicated box):
   `KcdMpServer.exe` (defaults to port 7778)
2. **Each player** — launch KCD2 via **Modding Tools**, load a save. Confirm
   `[KCD2-MP] === MOD INIT ===` appears in `kcd.log`.
3. **Each player** — inject the plugin into the running game:
   `KCDMP_LauncherInjector.exe --pid <pid> --dll <path>\KCDMP.dll`
4. **Each player** — `KcdMpClient.exe --host <relay ip>`

The agent finds the game, picks its transport, connects to the relay, and starts
syncing. Settings live in `kcdmp-client.json` next to the executable.

**Launch through Modding Tools, not the base game.** That is not a preference.
The debug REST API on `localhost:1403` exists only in that build, and it is the
entire channel between the game and `KcdMpClient.exe`. Retail is also monolithic:
`Framework.dll` and `CrySystem.dll` are separate modules only in the Modding
Tools build, and the plugin needs both — the IAT hook rewrites `WHGame.dll`'s
import of `Framework.dll`'s `C_ModulesManager::Update`, and the rttr reflection
ABI is exported from `CrySystem.dll`. Retail ships 6 DLLs beside the executable
and none of them are these; Modding Tools ships 45.

## KCDMP_launcher

The launcher now drives the real system. It was written as scaffolding for a
DLL-injection design before that design existed, and every assumption in it has
since been settled by the native-plugin work.

`LaunchGame` starts the Modding Tools build, waits until `WHGame.dll` is loaded
in the game process, runs `KCDMP_LauncherInjector.exe`, and then starts
`KcdMpClient.exe --host <ip> --port <port>`.

What changed and why:

| Was | Now |
|---|---|
| Launched whatever `GamePath` pointed at | Refuses anything without `Framework.dll` + `CrySystem.dll` beside the exe |
| `+map <MapName>`, guarded by a level-directory check | Dropped — KCD2 loads a save; there is no level to boot into |
| Injected 3 s after `Process.Start` | Waits for `WHGame.dll` to load, up to `InjectDelaySeconds` (default 20) |
| Never started the agent | Starts `KcdMpClient.exe`, without which nothing reaches the relay |
| Ignored the injector's exit code | Reports a failed injection instead of continuing |

New settings: `AgentPath`, `InjectDelaySeconds`, `ServerInfoPort`.

**Still unverified:** the launcher has not been run against a real game launch.
Its pieces are verified individually — the injector, the DLL and the agent are
all exercised by `tools\Test-CombatOutbound.ps1` — but the launcher's own
sequencing of them has only been reviewed, not observed. The `WHGame.dll` wait
in particular is a reasoned choice, not a measured one.

## The master server chain

Both breaks are closed.

**The URL was wrong.** The launcher defaulted to
`http://localhost:5000/api/servers`. Flask registers the blueprint at
`url_prefix="/servers"` with a `/servers_list` route, so the real URL is
`http://localhost:5000/servers/servers_list`. That is now the default.

**A third break, not previously recorded:** even with the right URL the list
would have arrived blank. `MasterServerEntry` bound `"ip"`, but
`Server.to_dict()` emits `"ip_address"` and `"map_name"`. The DTO's comment
admitted it was a guess. It now matches the Python, verified by deserialising
`to_dict()`'s exact output.

**Nothing registered a relay.** `MasterRegistrationService` in the relay is that
missing half. It is **opt-in**: with no `MasterServer:Url` set it does nothing,
because publishing a relay's address to a third party is the operator's call.

```jsonc
"MasterServer": {
  "Url": "http://localhost:5000/servers/register",
  "Name": "",            // defaults to the machine name
  "Description": "",
  "AdvertisedIp": "",    // only when the master cannot see the real address
  "HeartbeatSeconds": 120
}
```

Registration doubles as the heartbeat, which forced two changes on the master:

- **`/register` is now an upsert** keyed on `(ip_address, port)`. It inserted
  unconditionally, so every relay restart added another row for the same server.
- **`last_seen` is recorded and `/servers_list` hides anything older than five
  minutes** (`?all=1` to see everything). A relay that crashes cannot deregister
  itself, so without this the browser only ever grows.

`ip_address` is now optional and falls back to `request.remote_addr` — a relay
behind NAT does not know the address peers reach it on, but the master can see
it. Set `AdvertisedIp` when the master is behind a reverse proxy.

Related fixes this turned up:

- `ServerInfo:Tags` shipped as `["PvP", "PvE", "RP", "Feeling quite hungry"]` —
  four tags where the master allows three, and one that is not in its fixed list
  (`PvP, PvE, RP, Hardcore, Friendly, Modded`). Either alone rejects the whole
  registration. Corrected in **both** `appsettings.json` and
  `appsettings.Development.json`; the latter overrides the former in the dev
  environment, so fixing only the base file changes nothing.
- `GetDedicatedServerInfoAsync` returned **random numbers** behind a
  `TODO: actual udp`, so the browser showed a plausible map and player count for
  servers that were not running. It now reads the relay's existing
  `/api/information` and returns null when there is no answer, so the row is
  marked offline instead of invented.
- `ValidateIpAddr` rejected every IPv6 address. Since the master falls back to
  `remote_addr`, a same-machine relay registers as `::1` and a remote one may
  register as real IPv6; those rows reached the browser and were then dropped as
  unreachable, unpinged. It now uses `IPAddress.TryParse`, and IPv6 literals are
  bracketed when building the info URL.

### What was verified, and what was not

Verified by running it:

- The relay registers on start and re-registers on the heartbeat, carrying its
  token; a restart **refreshes** the existing entry rather than duplicating it.
- The tag warning fires when the count is wrong, and registration is clean once
  it is corrected.
- `/api/information` returns `{"mapName","players","maxPlayers","tags"}`, which
  is what the launcher's DTO expects.
- `MasterServerEntry` binds `Server.to_dict()`'s exact payload.

**Not verified:** the Python master server was never executed — there is no
Python on the development machine. The registration flow above was exercised
against a stub that mimics the Flask contract, so `servers.py` and `models.py`
are reviewed, not run. Anyone with a Python environment should run the real
thing before trusting it.

**Also note:** `models.py` gains a `last_seen` column and a unique constraint on
`(ip_address, port)`. There is no `migrations/` directory, so a fresh database
gets these from `db.create_all()`. An **existing** database needs a migration
(`migrate.sh`) — `create_all` does not alter tables that already exist.
