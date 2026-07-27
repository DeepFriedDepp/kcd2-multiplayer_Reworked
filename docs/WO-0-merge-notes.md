# WO-0 — Merge and stabilise: what happened

Reconciled `feat/voice-chat`, `master-server`, `feat/kcdmp-launcher` and
`refactor/server-framework` onto `main`.

## Merge order and why

1. **`feat/voice-chat`** — fast-forward, no conflicts.
2. **`master-server`** — clean; it only adds `kcd2_master_server/`.
3. **`feat/kcdmp-launcher`** — one conflict, `.gitignore`.
4. **`refactor/server-framework`** — one conflict, `RelayServer.cs`.

Voice-chat went first deliberately. The server-framework refactor *moves*
`ClientSession.cs` to `Features/ClientHandling/`, so merging voice-chat first
let git's rename detection carry the voice hunks into the moved file
automatically. Merging in the other order would have meant porting them by hand.

## Conflicts and how they were resolved

**`RelayServer.cs` — modify/delete.** The refactor deletes it; voice-chat adds
`BroadcastVoice` to it. Resolved by taking the delete and porting
`BroadcastVoice` into `TcpBroadcastService`.

**`ClientSession.cs` — content, auto-merged but wrong.** Git merged the
`0x07`/`0x08` hunks cleanly, but the voice hunk calls `_server.BroadcastVoice`
and the refactor had replaced the `_server` field with `_broadcastService`.
A textually clean merge that would not compile. Retargeted by hand.

**`.gitignore` — content.** Took the union of both sides and added `.vs/`,
`.idea/`, `*.user`, `*.suo`.

**`GameBridge.cs` and `kdcmp.lua` did not conflict.** WO-0 anticipated conflicts
there, but `refactor/server-framework` touches only `dotnet/KcdMp.Server/`, so
voice-chat's client-side and Lua changes came across untouched.

## Nothing was dropped

No feature or commit was discarded to make the merge work. The changes below go
beyond a plain merge; they are called out because they are decisions, not
mechanics.

## Decisions made during the merge

**Relay retargeted from net10.0 to net8.0.** `refactor/server-framework` had
moved the relay to `net10.0` while the agent and launcher stayed on `net8.0`,
and the project's stated stack is .NET 8. No package changes were needed —
Serilog 4.3.1 and the Serilog.\* 10.x packages all publish `net8.0` targets
(verified against the NuGet nuspecs). The explicit
`Microsoft.Extensions.DependencyInjection` / `.Hosting` references were dropped
because `Microsoft.NET.Sdk.Web` already supplies both; pinning them just
created a second version to keep in step with the TFM.

**`.vs/` stripped at the tip, not from history.** `bin`/`obj` were already gone
at the launcher branch tip (commit 565131c), but `.vs/` was still committed —
42 MB `Browse.VC.db`, Copilot index DBs, `.suo` — plus
`KCDMP_launcher.csproj.user` and `FolderProfile.pubxml.user`. All removed and
now git-ignored. **The blobs remain in history**, so a fresh clone is still
~43 MB. Removing them needs a history rewrite and a force-push, which is
destructive to anyone who has already cloned; left for a decision rather than
done unilaterally.

**Two solutions kept, root one extended.** The launcher branch added
`KCD2-MP.sln` at the root containing only the launcher, alongside
`dotnet/KcdMp.sln` containing agent and relay. `KCD2-MP.sln` now references all
three projects so `dotnet build KCD2-MP.sln` builds everything;
`dotnet/KcdMp.sln` is kept for working without the launcher.

**Voice chat got an off switch.** Merging voice-chat made the microphone
unconditionally hot on every connect with no way to disable it. Added
`VoiceChatEnabled` (default `true`, so behaviour is unchanged) and `--no-voice`.

**Relay HTTP listener pinned.** Added `Urls: http://0.0.0.0:5273`. Without it a
published relay binds the framework default (`localhost:5000`), where the
master server cannot reach `/api/information`. Note this exposes the info
endpoint on all interfaces — which is the point of the endpoint, but it is a
new listening socket.

## Bugs fixed while reconciling

These were latent in `refactor/server-framework`, not caused by the merge:

- **`ClientHandler`'s list was guarded by two different locks.**
  `TcpSocketService` took its own `SemaphoreSlim` to add/remove; `TcpBroadcastService`
  took a private `_lock` to read. The two never excluded each other, so
  `GetClients()` could run `List.ToArray()` during an `Add`. `ClientHandler` now
  locks internally and both outer locks are gone.
- **Shutdown threw.** `TcpSocketService` caught `TaskCanceledException`, but
  `AcceptTcpClientAsync` throws the base `OperationCanceledException` on
  cancellation, so the `BackgroundService` faulted instead of stopping cleanly.
  The `TcpListener` was also never stopped.
- **A fault-swallowing continuation.** The disconnect bookkeeping ran in an
  `async` lambda passed to `ContinueWith`, so the returned task — and any
  exception in it — was discarded. Now synchronous.
- **`ServerInfo`'s non-nullable strings had no initialisers**, warning under
  `Nullable: enable`.

## Protocol version negotiation

Handshake `0x00` payload is now `[version:1][nameLen:1][name]`. The relay reads
`payloadLen` from the header rather than reusing its low byte as the name
length, which is what it did before.

On mismatch the relay replies with the new `0x09 VersionMismatch`
`[serverVersion:1]` and closes. The agent raises
`ProtocolVersionMismatchException` and **stops reconnecting**, instead of
looping every 3 s against a relay it cannot talk to.

Because the version is pinned at connect time, the old payload-length sniffing
is gone: Position is exactly 17 bytes and Ghost exactly 18, rather than
accepting 16-or-17 and 17-or-18.

Packet types now live in `Protocol.cs`. **Two things worth knowing:**

- **`0x07` and `0x08` are taken by voice chat.** The engineering brief says
  "`0x07`+ are free", which was true of `main` but not once voice-chat merges.
  **The next free type byte is `0x0A`** — relevant to WO-2's interaction packets.
- `Protocol.cs` is **duplicated** between the two projects, which share no
  assembly. The constants are mirrored by hand and must be changed together.
  Extracting a shared `KcdMp.Protocol` project is worth doing but is its own
  work order.

## Verification

Initially written without a .NET SDK on the machine; a user-scope .NET 8 SDK
(8.0.423, `%USERPROFILE%\.dotnet-sdk8`, not on PATH) was installed afterwards
and the following was verified:

- **`dotnet build KCD2-MP.sln` succeeds** — all three projects, 0 errors.
  8 warnings, all pre-existing (CA1416 in the client's Steam registry helpers,
  two nullability/unused-variable warnings in the launcher). The launcher
  restores and compiles; Photino needed no extra native assets to build.
- **The relay starts and behaves.** Serilog resolves from DI, the commented
  `appsettings.json` parses (the JSON config provider skips comments), the
  listener binds 7778, and `/api/information` returns the expected JSON.
- **Version negotiation, probed over raw TCP:**
  - v1 handshake → `FF` Ack with assigned id
  - v9 handshake → `09` VersionMismatch carrying the relay's version
  - legacy pre-version handshake (bare name payload) → rejected with `09`
  - full session: Position accepted, Ping echoed back as Pong
- **Legacy CLI flags:** `--port 7779` remaps to `Tcp:Port`, bare `--echo`
  survives `NormaliseArgs`, and echo mode reflects a Ghost (`0x02`, 18-byte
  payload, ghostId 0).
- **The agent** writes `kcdmp-client.json` with defaults on first run, layers
  `--host/--name/--no-voice` overrides on top, and waits for the game.

Not verified: an end-to-end run with the actual game (needs KCD2 + Modding
Tools running), and the Python master server (needs its own venv and database;
no interaction with the .NET build).

## Suggested next step

WO-1 (transport replacement) is the stated next work order. The relay/agent
baseline works; the remaining prerequisite for WO-1's latency benchmark is a
run against the real game's debug API.
