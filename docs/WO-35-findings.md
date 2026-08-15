# WO-35 findings: a community-written C# master server

## The reported problem

The launcher shows a plain "Master Server not found" error. It confuses
non-technical users even though the master server is not required to play —
a launcher with the host's address can join directly. The Python master
server (`kcd2_master_server/`) has never actually been run on any machine
this project has touched; its wiring on the launcher/relay side was validated
only against a stub of the Flask contract (see `PROJECT-STATE.md` line 461,
`LAUNCHING.md`). The error is not a bug in a specific line of code — it's the
predictable result of pointing the launcher at a service that has never been
proven to run.

## Provenance

- Delivered as `kcd2-mp.tar.gz`, a full snapshot of the project tree including
  a new `dotnet/KcdMp.MasterServer/` project, a rewritten
  `dotnet/KcdMp.Protocol/MasterApi.cs`, and a rewritten
  `dotnet/KcdMp.Server/Features/ServerInformation/MasterAnnounceService.cs`
  (named differently from, and replacing, this repo's existing
  `MasterRegistrationService.cs`).
- Human confirmed: the contributor wrote it and gave it to the human to
  finish and test, with full permission for it to go into this GPLv3 repo.
  **Contributor name/handle for credit in `docs/` and code comments is still
  needed from the human** — not yet added anywhere.

## Contract comparison — does NOT match as-is

The current repo already has a working (never-run) contract between the
launcher, the relay, and the Python master server, added in commit `54af330`
("Wire the launcher to the real injector and close the master server
chain"):

| | Current (Python contract) | Contributed (`KcdMp.MasterServer`) |
|---|---|---|
| Transport | HTTP: relay POSTs `/register` every `HeartbeatSeconds`; launcher GETs `/servers_list` | WebSocket: relay holds one socket open (`/api/v1/servers/connect`), announce/update/heartbeat frames; launcher GETs `/api/v1/servers` |
| Listing shape | Bare JSON array | `{ "apiVersion": 1, "servers": [...] }` |
| Field casing | snake_case (`ip_address`, `map_name`) | camelCase (`address`, `mapName`) |
| Expiry | `last_seen` timestamp, 5-minute stale window (`STALE_AFTER` in `servers.py`) | Immediate: listing dies when the WebSocket closes |
| Extra fields | none | `id`, `infoPort`, `releaseVersion`, `protocolVersion`, `onlineSince` |

Verified by reading both sides directly: the launcher's
`GetServersFromMasterAsync` (`KCDMP_launcher/Models/NetService.cs`) does
`GetFromJsonAsync<List<MasterServerEntry>>`, and `MasterServerEntry`
(`KCDMP_launcher/Models/AppModels.cs:27-42`) is `[JsonPropertyName("ip_address")]`
etc. — bare array, snake_case. The relay's existing
`MasterRegistrationService.cs` POSTs the same snake_case shape and expects a
bare `{ "token": ... }` back. Neither matches what `KcdMp.MasterServer`
serves or expects.

**This is not a drop-in replacement.** Adopting it requires:
1. Deleting `MasterRegistrationService.cs` and replacing it with the
   contributed `MasterAnnounceService.cs` in `KcdMp.Server`.
2. Replacing `KcdMp.Protocol`'s DTOs with the contributed `MasterApi.cs`.
3. Rewriting `NetService.GetServersFromMasterAsync` and
   `AppModels.MasterServerEntry` in the launcher to parse the wrapped,
   camelCase shape.
4. `kcd2_master_server/` (Python) becomes dead code to remove, not something
   with a schema-migration story to reconcile — the new registry is
   in-memory only, nothing to migrate.

The contributor's own `docs/MASTER-SERVER.md` (included in the delivered
tree) states this plainly: "It replaces the Flask service." It was written
as a full three-sided replacement, not an add-on.

### Does it fix the specific reported bug?

Yes, if adopted with the launcher/relay changes above — and for a better
reason than "it's finally runnable." The old contract's `STALE_AFTER`
5-minute window meant a crashed relay stayed listed for up to 5 minutes;
here delisting happens within about a second of the connection dying,
confirmed live (see Testing). But adoption alone doesn't fix the *reported*
error either — until the launcher and relay code are actually changed to
speak this contract, pointing the launcher at this master server would fail
exactly the same way, just against a different service.

## Safety review

Reviewed `Program.cs`, `ServerConnectionEndpoint.cs`, `AnnounceValidator.cs`,
`ServerRegistry.cs`, `ServersController.cs`, `StatusController.cs`.

- **Binding**: `0.0.0.0:5100` by default (documented, intentional — "a master
  server nobody outside the machine can reach is not one"). No TLS
  out of the box; the doc correctly says to put a reverse proxy in front
  before pointing real players at it. Same posture as the Python service
  would have had.
- **Unauthenticated write surface**: none over HTTP — `ServersController` and
  `StatusController` are GET-only, and nothing in them can mutate the
  registry (verified by reading both controllers). The *only* way to list a
  server is to hold a WebSocket open and send a well-formed `announce`. No
  token/ownership model is needed because there's nothing to "claim" later —
  the connection itself is the proof of liveness (contrast with the Python
  contract's token-based upsert, which existed because reads and writes were
  decoupled in time).
- **Input validation**: `AnnounceValidator.Build` bounds every field before
  it reaches the registry — name/map/description/version length caps,
  tag allow-list (`AllowedTags`, dropping anything else with a warning
  instead of refusing the whole registration), port range 1–65535, player
  counts clamped to 0–255 (`MaxPlayerLimit`, matching the relay's one-byte
  ghost addressing), and a spoofed `address` field is rejected unless it's a
  plain hostname/IPv4 (no path/whitespace/colon injection into the listing).
  Confirmed live: a 4th tag ("NotATag") was silently dropped with a warning
  rather than rejecting the whole announce.
- **Injection**: no database at all — `ServerRegistry` is an in-memory
  `ConcurrentDictionary`. No SQL, no ORM, nothing to inject into. This also
  removes the Python side's entire attack surface class.
- **Resource exhaustion**: `Registry:MaxServers` (default 500) caps
  *listed* servers, and `MaxMessageBytes` (8 KB) caps a single frame — both
  verified in the source. There is **no rate limiting on WebSocket connection
  attempts themselves** — nothing stops a remote host from opening and
  dropping thousands of connections per second before completing an announce.
  This is a real gap worth noting for a public deployment, though it's the
  same posture the Flask service would have had (no rate limiting there
  either) and is generally mitigated at the reverse-proxy layer the docs
  already call for. Not a regression, but not solved either — flag for the
  human if this goes into production without a proxy in front.

No other unauthenticated write endpoints found. No secrets, connection
strings, or credentials in any of the contributed files.

## Testing — actually run, for the first time

Built and ran `dotnet/KcdMp.MasterServer` standalone (isolated copy, not the
working repo) with `dotnet build` / `dotnet run --no-build`,
`ASPNETCORE_ENVIRONMENT=Development` (binds `localhost:5100`). Exercised it
with a small throwaway WebSocket client (`relaysim`) built against the real
`KcdMp.Protocol` types, plus `curl` against the HTTP side. All observed
directly, not inferred from reading the code:

| Check | Result |
|---|---|
| `GET /api/v1/status` before any relay | `{"apiVersion":1,"servers":0,"players":0}` |
| `GET /api/v1/servers` before any relay | `{"apiVersion":1,"servers":[]}` |
| Non-WebSocket request to `/api/v1/servers/connect` | 400 with the documented explanatory message |
| `GET /api/v1/servers/{unknown-id}` | 404 |
| Relay announces (name, port, map, tags incl. one invalid tag) | `accepted` reply with the invalid tag dropped and a warning; server appeared in `GET /api/v1/servers` with correct field values |
| Relay sends `update` (player count 1→5) | Listing reflected the new count on the next GET, live |
| Relay sends `heartbeat` | No error; connection stayed open |
| Relay closes the socket | Master's log: `Delisted "WO-35 Test Relay" (::1).` within ~1 second; `GET /api/v1/servers` immediately empty — confirms real behavior, not the 5-minute Python stale window |
| Announce with `ApiVersion: 999` | `rejected`, code `api_version`, explanatory reason |
| Announce with empty name | `rejected`, code `invalid`, reason "name is required" |
| First message not an `announce` | `rejected`, code `invalid`, explanatory reason |
| Two relays announcing the same `address:port` | Second is accepted; first's listing is silently replaced; first's socket is closed by the server the next time it sends anything (observed: its next heartbeat got a socket close, not a reply) |

Every documented behavior in the contributor's `docs/MASTER-SERVER.md`
matched what was actually observed. No discrepancies found between the doc
and the running service.

**Not tested**: the full register → appear in launcher's list → join flow,
because that requires launcher-side and relay-side code changes first (see
Contract comparison) — testing it as delivered would just prove the
mismatch again, which is already established by direct comparison. Also not
tested: behavior under `Registry:MaxServers` actually being hit (500 is a lot
to simulate for a config check already visible in source), and behind an
actual reverse proxy / `ForwardedHeaders`.

## Adoption decision

**Adopted.** The human gave explicit go-ahead for the full 3-way rewrite and
said the contributor does not want credit — nothing added to `docs/` or code
comments for that reason (not an oversight).

## What was actually changed

- `dotnet/KcdMp.Protocol/MasterApi.cs` — added (the contributed contract,
  unchanged).
- `dotnet/KcdMp.Server/Features/ServerInformation/MasterRegistrationService.cs`
  — deleted, replaced by `MasterAnnounceService.cs` (contributed, unchanged).
  `Program.cs` updated to register it.
- `dotnet/KcdMp.Server/Features/ClientHandling/ClientHandler.cs` — added
  `ReadyClientCount` (handshaken clients only). `MasterAnnounceService`
  expected this property; the existing `ClientCount` includes a connection
  still mid-handshake, which is exactly the "a launcher's reachability probe
  looks like a player" false positive the contributed code's own doc comment
  warns about. Confirmed by reading `TcpSocketService.cs`: `AddClient` runs on
  raw TCP accept, before `ClientSession.IsReady` (`Name is not null`) is set
  by the handshake.
- `dotnet/KcdMp.Server/appsettings.json` — `MasterServer` section comment and
  fields updated (`HeartbeatSeconds` removed; the master dictates this now).
- `dotnet/KcdMp.Server/KcdMp.Server.csproj` — added the VERSION-file stamping
  block `KcdMp.Client.csproj`/`KCDMP_launcher.csproj` already had. **Found
  during live testing, not by inspection**: the relay's `releaseVersion` came
  back as `1.0.0+<gitsha>` instead of the repo's real `0.11.6`, because the
  relay had never had a reason to read its own version before this contract
  gave it a `releaseVersion` field to publish. Fixed and re-verified.
- `dotnet/KcdMp.MasterServer/` — the whole contributed project, added.
- `dotnet/KcdMp.sln` and `KCD2-MP.sln` — new project added to both.
- `KCDMP_launcher/Models/AppModels.cs` — `MasterServerEntry` (bare
  snake_case DTO) removed; `NetService` now deserialises directly into
  `KcdMp.Wire.ServerListResponse`/`ServerListing`, so there is one copy of the
  contract instead of a second one that can drift, per the contributed code's
  own stated rationale. `ServerInfo.InfoPort` added (the master now publishes
  each relay's real one). `MasterServerUrl` default changed to
  `http://localhost:5100`.
- `KCDMP_launcher/Models/NetService.cs` — `GetServersFromMasterAsync` rewritten
  for the wrapped/camelCase/versioned response, with an `ApiVersion` mismatch
  check mirroring the relay's own.
- `KCDMP_launcher/Pages/Home.razor.cs` — `RefreshApp` now uses each server's
  published `InfoPort` for the `/api/information` poll instead of the global
  `AppSettings.ServerInfoPort` guess, falling back to that guess only for a
  manually-added server the master never told us about. Kept the existing
  per-server info poll rather than switching to the contributed design's
  bare-TCP-probe reachability model — that model is a real design opinion in
  the contributed `docs/MASTER-SERVER.md`, not something needed to fix the
  reported error, and the existing poll already works and gets strictly
  better with a real per-relay port instead of a guessed global one.
- `kcd2_master_server/` (Python) — removed (`git rm -r`); fully replaced, nothing to migrate (registry is in-memory only).
- `README.md`, `docs/LAUNCHING.md`, `docs/PROJECT-STATE.md` — updated to
  reflect the replacement. `docs/MASTER-SERVER.md` — added (the contributed
  doc, credited nowhere per the human's instruction, with one factual
  correction: it claimed `MasterApi.TimeoutSeconds` is 90s; the actual
  constant is 30s).

## Live end-to-end verification (post-adoption)

Ran all three real programs together — the actual production code, not a
simulation:

1. `dotnet run --project dotnet\KcdMp.MasterServer` on `localhost:5100`.
2. `dotnet run --project dotnet\KcdMp.Server` (the real relay, unmodified
   business logic) on test ports (`17778`/`15273`, to avoid a stale
   unrelated `KcdMpServer.exe`/`KcdMpClient.exe` pair already holding
   `7778`/`5273` on this machine — left untouched, not this session's
   process), pointed at the master via `MasterServer:Url`.
3. A throwaway console app that project-references `KCDMP_launcher.csproj`
   directly and calls the real, unmodified `NetService.GetServersFromMasterAsync`
   — not a reimplementation of its logic.

Observed:

- Master's `GET /api/v1/servers` showed the relay with every field correct:
  real address, real ports, `mapName` from the relay's own `ServerInfo:MapName`
  config, `tags` from its config, `protocolVersion` 6, and (after the csproj
  fix) `releaseVersion` "0.11.6" matching the repo's `VERSION` file.
- The real launcher `NetService.GetServersFromMasterAsync("http://localhost:5100")`
  returned one populated `ServerInfo` with every field mapped correctly,
  including `Token` (the master's listing id) and `InfoPort`.
- Stopping the relay delisted it within ~1 second, confirmed by both the
  master's log and a follow-up `GET /api/v1/servers` returning empty —
  reproducing the WO-35 standalone test's result with the real integrated
  system this time, not a simulation.

Whole solution (`KCD2-MP.sln`, all 7 projects including the new one) builds
clean: 0 errors, 8 pre-existing warnings (none introduced by this work).

**Not tested**: an actual game launch through the full launcher UI (Photino
window), and behavior with two relays behind a real reverse proxy. Both are
out of what was needed to verify the master-server chain itself.
