# The master server

`dotnet/KcdMp.MasterServer/` — the server browser's backend. It replaced the
Flask service that used to live in `kcd2_master_server/` (WO-35; see
`WO-35-findings.md` for the contract comparison, safety review, and live test
results that preceded adoption).

It does one thing: keep a list of the relays that are online right now, so a
player's launcher can show them. It never relays gameplay, never sees a player,
and is not needed to play — a launcher that has the host's address joins
without it.

---

## The shape of it

Two halves that meet at one in-memory list:

```
   relay  ── WebSocket, held open ──▶  master  ◀── HTTP GET ──  launcher
       announce / update / heartbeat        /api/v1/servers
```

**A relay is listed for exactly as long as its connection is open.** It opens
one WebSocket when it starts, announces itself, and pushes an update whenever
its player count or map changes. When the relay stops — cleanly or by being
killed — the socket closes and the listing goes with it, in the same second
(live-verified in WO-35: delisting observed within ~1 second of disconnect).

That is the part worth understanding, because it is the thing the old service
could not do. Registration-by-heartbeat cannot tell *stopped* from *slow*: a
crashed relay stayed in the browser for the full five-minute stale window,
because nothing can report its own death after the fact. Players picked those
rows and got nothing. Here the operating system reports it, which needs no
cooperation from a process that is already gone.

`MasterApi.TimeoutSeconds` (30s) still exists, but only for the case where no
close ever arrives at all — a half-open socket after a router reboot — not as
the way liveness is normally judged.

**The launcher's side is a plain GET.** Player counts and map names come back
already filled in, because the relay pushed them. The launcher additionally
polls each server's own `/api/information` (at the per-relay `infoPort` the
master now publishes) to confirm it is actually reachable and refresh live
counts — see `NetService.GetDedicatedServerInfoAsync`.

---

## Running it

```powershell
dotnet run --project dotnet\KcdMp.MasterServer
```

Listens on `http://0.0.0.0:5100` by default (`Urls` in `appsettings.json`;
loopback only under `ASPNETCORE_ENVIRONMENT=Development`).

Point a relay at it — off unless configured, since publishing a relay's address
to a third party is the operator's call:

```jsonc
// dotnet/KcdMp.Server/appsettings.json
"MasterServer": {
  "Url": "http://localhost:5100",
  "Name": "The Bathhouse",
  "Description": "Friendly, no PvP after dark"
}
```

The URL names *where the master is*, not which endpoint on it: the relay
appends the path itself and upgrades `http`/`https` to a `ws`/`wss` connection.

And point a launcher at it — Settings → Master Server URL, or
`MasterServerUrl` in the launcher's `settings.json`. Same rule: the base URL.

### Behind a reverse proxy

A listing is published under the address the relay's connection came from, so
behind nginx every server would be listed as the proxy. Turn on forwarded
headers *only* when something in front of this process is actually setting
them — honouring `X-Forwarded-For` from an untrusted caller lets anyone list a
server under any address:

```jsonc
"ForwardedHeaders": {
  "Enabled": true,
  "KnownProxies": []   // empty = loopback only, i.e. a proxy on this host
}
```

The proxy must be configured to forward WebSocket upgrades (`Upgrade` and
`Connection` headers) or no relay will ever be listed.

---

## The API

Version `1`. The whole contract is one file —
[`dotnet/KcdMp.Protocol/MasterApi.cs`](../dotnet/KcdMp.Protocol/MasterApi.cs) —
shared by the master, the relay and the launcher, so none of the three can
drift from the other two. (The old pair drifted exactly that way: the launcher
bound `ip`, the service emitted `ip_address`, and every server in the browser
had a blank address.)

### `GET /api/v1/servers`

```json
{
  "apiVersion": 1,
  "servers": [
    {
      "id": "ccc62c4790734b9297697edd2bd1aa57",
      "name": "The Bathhouse",
      "address": "203.0.113.9",
      "port": 7778,
      "infoPort": 5273,
      "mapName": "Kuttenberg",
      "players": 3,
      "maxPlayers": 64,
      "releaseVersion": "0.11.6",
      "protocolVersion": 6,
      "tags": ["PvE", "Friendly"],
      "description": "Friendly, no PvP after dark",
      "onlineSince": "2026-08-13T14:59:25.8027004+00:00"
    }
  ]
}
```

### `GET /api/v1/servers/{id}`

One listing, or `404` — which means that server went offline, since an id only
lives as long as the connection that owns it.

### `GET /api/v1/status`

`{"apiVersion":1,"servers":4,"players":11}`. What an uptime check wants, and
how the launcher's status bar tells "the master is down" from "the master is
fine and nobody is hosting" — two things an empty list looks like from outside.

### `GET /api/v1/servers/connect` — the relay's WebSocket

Messages are JSON, one object per frame, `type` says which:

| Direction | `type` | Carries |
|---|---|---|
| relay → master | `announce` | Name, versions, port, info port, map, players/max, tags, description. Must be first. |
| relay → master | `update` | Map, players, max. Sent when they change. |
| relay → master | `heartbeat` | Nothing. Sent when they have not. |
| master → relay | `accepted` | Listing id, the address it was published under, heartbeat interval, warnings. |
| master → relay | `rejected` | A code and a reason. The socket closes after it. |

Rejections are `api_version` (the two ends were built against different
contracts), `invalid` (no name, no usable port, first message was not an
announce), or `full` (the master is at `Registry:MaxServers`).

Anything the master can fix instead of refusing, it fixes and complains about
in `accepted.warnings`, which the relay writes to its own log: a fourth tag, a
tag that is not on the list, a `maxPlayers` above what a relay can address, an
over-long name. Hiding an otherwise healthy server from the browser over a
label would be worse than dropping the label — which is what the old service
did.

---

## Version checking

Three version numbers live here and none of them is the others:

| | What it is | Who checks it |
|---|---|---|
| `MasterApi.Version` | This API's message shapes | Master refuses a mismatched `announce`; launcher refuses a mismatched listing rather than misread it |
| `Protocol.Version` | The relay wire protocol | Carried in every listing. The launcher refuses to start the game for a server on a different one — the relay would hard-refuse the handshake anyway, and finding that out before the game loads is better than after |
| Release version | The repo's `VERSION` | Shown in the browser (hover a row). Compared with `ReleaseVersionCompare` |

A relay stamps its release version from `VERSION` at build time, the same way
the client and launcher do (WO-35 added this stamping to `KcdMp.Server.csproj`
— it had never needed to read its own version before there was a
`releaseVersion` field to put it in). Nothing here ever writes that file — see
[`VERSIONING.md`](VERSIONING.md).

---

## Reachability, and why the launcher still pings

The master can say a server is running. It cannot say a *particular player* can
reach it — that depends on their route, their ISP and the host's port
forwarding. So the launcher still checks for itself, per server, per refresh,
by hitting the relay's own `/api/information` at the `infoPort` the master
published (`NetService.GetDedicatedServerInfoAsync`) — a relay that does not
answer is marked offline rather than shown with invented counts.

---

## Storage: there isn't any

The registry is a `ConcurrentDictionary` and nothing else. A listing only
exists while its relay holds a socket open, so nothing outlives the process
anyway: restart the master and every relay reconnects within its retry window,
rebuilding the list from the servers that are actually up.

A database here would only preserve rows already known to be wrong. The old
service had one, and what it stored was the problem it then needed the
five-minute stale window to paper over.

---

## What a relay does when the master is down

Nothing that affects players. It logs a warning, retries with a delay that
doubles from 5s to a 5-minute ceiling, and relists itself when the master comes
back. Peers connect to the relay directly over TCP and never touch the master.

---

## Known gap

No rate limiting on raw WebSocket connection attempts to
`/api/v1/servers/connect` — `Registry:MaxServers` caps how many servers can be
*listed* at once, but nothing here stops a remote host from opening and
dropping connections faster than that. Same posture the Flask service would
have had; mitigate at the reverse-proxy layer if this is ever exposed without
one. See `docs/WO-35-findings.md`.
