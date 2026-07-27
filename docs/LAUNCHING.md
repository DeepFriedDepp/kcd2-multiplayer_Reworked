# How to launch, and why not through the launcher

## The working flow

Keep doing what you have been doing. **Launch KCD2 through the KCD2 Modding
Tools Steam entry.** That is not a preference — the debug REST API on
`localhost:1403` exists only in that build, and it is the entire channel between
the game and `KcdMpClient.exe`. Launch the base game and the agent has no way to
reach it at all.

Full sequence:

1. **Relay** — on one machine (either player's PC or a dedicated box):
   `KcdMpServer.exe` (defaults to port 7778)
2. **Each player** — launch KCD2 via **Modding Tools**, load a save. Confirm
   `[KCD2-MP] === MOD INIT ===` appears in `kcd.log`.
3. **Each player** — `KcdMpClient.exe --host <relay ip>`

The agent finds the game, picks its transport, connects to the relay, and starts
syncing. Settings live in `kcdmp-client.json` next to the executable.

## Do NOT launch through KCDMP_launcher

The launcher cannot start the system that actually exists. Its `LaunchGame` was
written for a **native DLL-injection** design that was never built:

```csharp
FileName  = settings.GamePath                       // KingdomCome.exe, the BASE game
Arguments = "+map <MapName> --kcdmp-ip <ip> --kcdmp-port <port>"
// then:
KCDMP_LauncherInjector.exe --pid <gamePid> --dll KCDMP.dll
```

Five separate problems, any one of which is fatal:

1. **It launches the base game**, not Modding Tools — so no debug API, so no
   mod channel. The settings file picker even filters for `KingdomCome.exe`.
2. **`KCDMP_LauncherInjector.exe` does not exist** anywhere in the repo.
3. **`KCDMP.dll` does not exist** either. The launcher refuses to proceed
   without both, so it fails closed rather than doing something strange.
4. **It never starts `KcdMpClient.exe`.** The launcher contains no reference to
   the agent, the pak, Modding Tools, or port 1403 — it does not know the real
   system exists.
5. **`+map <MapName>`** presumes booting straight into a level, which is a
   dedicated-server notion rather than how a KCD2 save loads.

## The master server chain is also not wired up

Two breaks, so the server browser would show an empty list even with a master
server running:

- The launcher defaults to `http://localhost:5000/api/servers`, but Flask
  registers the blueprint at `url_prefix="/servers"` with a `/servers_list`
  route — the real URL is `http://localhost:5000/servers/servers_list`.
- **Nothing ever registers a relay.** The master server has a `POST
  /servers/register` endpoint and the relay serves `/api/information` for
  polling, but no code pushes a registration. `InformationController`'s comment
  says "Called by the master server", and that call is the missing half.

## Why this matters for the native-plugin work

The launcher is not junk — it is **scaffolding for the DLL-injection
architecture**, built ahead of the thing it was meant to launch. Whoever wrote
it was already planning to hook the game directly rather than go through Lua,
which is exactly where the shared-combat investigation ended up pointing (see
`ARCHITECTURE-shared-world.md`: the Lua surface is read-mostly, so mutation has
to come from native code).

So if a native plugin gets built, the launcher becomes the right front end for
it almost unchanged, and `--kcdmp-ip` / `--kcdmp-port` are already the arguments
it expects to pass. The work needed is the injector, the DLL, and closing the
two master-server gaps above.

Until then: **Modding Tools, then the agent.**
