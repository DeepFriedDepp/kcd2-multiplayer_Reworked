# WO-35 progress

Session 2026-08-15. No engine involved — code review, contract comparison,
and standalone integration testing of a community-contributed C# master
server, delivered as `kcd2-mp.tar.gz`.

## Coverage

| phase | status | result |
|---|---|---|
| 0 — provenance | done | Human confirmed contributor gave the code with full permission for GPLv3 inclusion. Contributor name/handle for credit still outstanding — asked. |
| 1 — contract comparison | done | Does **not** match the existing (never-run) launcher/relay/Python contract wired in `54af330`. Different transport (WebSocket vs HTTP POST/GET), different JSON shape (wrapped+camelCase vs bare+snake_case), different expiry model. Requires a 3-sided rewrite (launcher, relay, protocol DTOs) to actually replace it — not a drop-in. |
| 2 — safety review | done | GET-only HTTP surface, no DB (nothing to inject), all announce fields bounded/clamped, address spoofing blocked. One real gap: no rate limiting on raw WebSocket connection attempts (same posture the Flask service would have had). Binds `0.0.0.0` by design, documented as needing a reverse proxy for TLS. |
| 3 — actually run it | done, live-tested | Built and ran `KcdMp.MasterServer` standalone in an isolated copy. Verified via a throwaway WebSocket test client: status/list endpoints, announce→accept, tag-drop warning, live update, immediate delist on disconnect (~1s, vs. Python's 5-minute stale window), API-version rejection, empty-name rejection, wrong-first-message rejection, same-address replacement. Did not test the full launcher-integrated flow — blocked on the Phase 1 mismatch, would just re-prove it. |
| 4 — adoption decision | **done, adopted** | Human approved the full rewrite; contributor declined credit. Implemented and live-tested end-to-end with the real relay, real master, and real launcher `NetService` code together. See "Adoption" section of `docs/WO-35-findings.md`. |

## What actually happened, in order

1. Extracted `kcd2-mp.tar.gz` to an isolated scratch directory (never touched
   the working repo tree) and diffed its file list against the current repo
   to isolate the actual contribution: `dotnet/KcdMp.MasterServer/` (new),
   rewritten `dotnet/KcdMp.Protocol/MasterApi.cs`, rewritten
   `dotnet/KcdMp.Server/Features/ServerInformation/MasterAnnounceService.cs`
   (replaces the existing `MasterRegistrationService.cs`), and the
   contributor's own `docs/MASTER-SERVER.md`.
2. Asked the human the two Phase-0 blocking questions (specific reported
   error; contributor permission) before reading further — both answered.
3. Read `MasterRegistrationService.cs` (current, HTTP/POST) and
   `kcd2_master_server/app/routes/servers.py` (current, Flask) to pin down
   the exact live contract, then read the contributed
   `MasterAnnounceService.cs`, `MasterApi.cs`, `ServerConnectionEndpoint.cs`,
   `AnnounceValidator.cs`, `ServerRegistry.cs`, `RegisteredServer.cs`,
   `ServersController.cs`, `StatusController.cs`, `Program.cs`,
   `appsettings.json` line by line to compare.
4. Built `dotnet/KcdMp.MasterServer` standalone (`dotnet build` /
   `dotnet run --no-build`, `DOTNET_ROOT` set per the user-scope SDK note),
   ran it on `localhost:5100`, and wrote a small disposable WebSocket client
   project (`relaysim`, referencing the real `KcdMp.Protocol` types) to
   exercise announce/update/heartbeat/close and the three rejection paths,
   plus `curl` for the HTTP side. All results in `docs/WO-35-findings.md`
   are from this live run, not inferred from source.
5. Killed the test master server process, wrote findings.

## Adoption (second half of the session)

Human said: do the full rewrite; the contributor doesn't want credit. Did:

6. Added `MasterApi.cs` to `KcdMp.Protocol`. Swapped
   `MasterRegistrationService.cs` for `MasterAnnounceService.cs` in
   `KcdMp.Server`, added `ClientHandler.ReadyClientCount` (the existing
   `ClientCount` includes not-yet-handshaken connections — traced through
   `TcpSocketService.cs` to confirm `AddClient` runs before `IsReady`).
   Updated `Program.cs` and `appsettings.json`. Added the whole
   `dotnet/KcdMp.MasterServer/` project and wired it into both `.sln` files.
7. Rewrote the launcher's `AppModels.MasterServerEntry`/`NetService.
   GetServersFromMasterAsync` for the new wrapped/camelCase contract, added
   `ServerInfo.InfoPort`, and updated `Home.razor.cs`'s `RefreshApp` to use
   each server's real published info port instead of a single guessed global
   one.
8. `git rm -r kcd2_master_server/` — fully replaced, in-memory registry, no
   migration story needed.
9. Built the whole solution (`dotnet build KCD2-MP.sln`) clean.
10. Ran the real master server, the real relay (on non-default test ports,
    to avoid a stale unrelated `KcdMpServer.exe` process already holding
    7778/5273 on this machine), and a throwaway console app that
    project-references the actual `KCDMP_launcher.csproj` and calls the real
    `NetService.GetServersFromMasterAsync` — not a reimplementation. Found and
    fixed a real bug this exposed: the relay's `releaseVersion` published as
    `1.0.0+gitsha` because `KcdMp.Server.csproj` was missing the VERSION-file
    stamping block `KcdMp.Client.csproj`/`KCDMP_launcher.csproj` already had.
    Re-verified after the fix: `0.11.6`.
11. Confirmed delisting within ~1s of stopping the relay, using the real
    integrated system this time.
12. Updated `README.md`, `docs/LAUNCHING.md`, `docs/PROJECT-STATE.md`, and
    added `docs/MASTER-SERVER.md` (the contributed doc, with one factual
    correction: it claimed a 90s timeout; the code says 30s).

## Round 3: auto-start (same session, after the human hit the error live)

The human launched the actual packaged 0.11.6 build and still got "Could not
connect to Master Server!" — expected, since nothing had ever made anything
listen on `MasterServerUrl`. Asked whether the master server starts with the
launcher; it didn't. Implemented, mirroring the existing `RelayPath`
auto-start-on-Host pattern but firing at launcher startup instead:

- `AppSettings.MasterServerPath` (default `KcdMpMasterServer.exe`), exposed in
  `SettingsModal.razor`.
- `Home.razor.cs`: `EnsureLocalMasterServerAsync()`, called from
  `OnInitializedAsync()` before `RefreshApp()`. Only starts a local instance
  when `MasterServerUrl`'s host is loopback — pointing at a friend's real
  master should never spin up a redundant local one nobody's relay announces
  to. Stopped alongside the relay in `ConfirmExit()`.
- `MigrateStaleMasterServerUrl()`: an existing `settings.json` predating this
  session has the pre-WO-35 default (`http://localhost:5000/servers/servers_list`)
  baked in — a fresh `AppSettings()` only supplies the new default for a
  settings.json that doesn't exist yet. Migrated only when it is exactly that
  known old literal.
- `tools/Publish-Release.ps1` + a new `dotnet/KcdMp.MasterServer/Properties/PublishProfiles/FolderProfile.pubxml`
  (self-contained win-x64, matching the relay's own profile): the packaged
  release now bundles `KcdMpMasterServer.exe` beside the launcher, or there
  would be nothing for `EnsureLocalMasterServerAsync` to start.

**Two real bugs found by actually testing the full self-contained merged
release folder** (not just `dotnet build`, which can't catch either):

1. A quick dev-mode manual-copy test first showed `KcdMpMasterServer.exe`
   crashing with `FileNotFoundException` on `Microsoft.Extensions.Configuration.Abstractions`
   — traced to mixing a framework-dependent Debug build into a folder built
   for self-contained Release; not a real bug, an artifact of the shortcut.
2. Building and merging the **actual** self-contained Release publish output
   of all four projects (matching `Publish-Release.ps1` exactly) surfaced a
   real one: `KcdMpMasterServer.exe` crashed with `Could not load
   Serilog.Sinks.File` — the exact DLL-probe collision `KcdMp.Server.csproj`'s
   own comment already documents (`Serilog.Settings.Configuration` probes
   every `Serilog.*.dll` sitting beside the executable regardless of whether
   it's referenced, and a self-contained host refuses to load one that isn't
   in that app's own `.deps.json`), just hitting a second project. Fixed the
   same way: added an unused `Serilog.Sinks.File` `PackageReference` to
   `KcdMp.MasterServer.csproj` so its own deps.json lists the assembly.
   Re-verified against the real merged self-contained folder: clean start,
   `GET /api/v1/status` answers.

Live-verified after the fix, from the actual merged self-contained release
folder (not `dotnet run`): a fresh install (no `settings.json`) auto-starts
the master server and `OnInitializedAsync`'s `RefreshApp()` succeeds with no
error logged; an existing install with the stale pre-WO-35 URL migrates and
also succeeds. Checked `app.log` in both cases for the absence of "Could not
connect to Master Server!" rather than assuming from the UI.

## Round 4: the auto-start fix didn't work the first time, on the real machine

Deployed round 3 over the human's actual install (`%LocalAppData%\KCDMP`,
confirmed against `installer\KCDMP.iss`'s `DefaultDirName`) and asked them to
relaunch. Still got the error. Added logging rather than guessing again, and
the real cause was visible in one relaunch: `EnsureLocalMasterServerAsync`
*did* start `KcdMpMasterServer.exe` successfully (confirmed via the new pid
log line), but the readiness poll against `http://localhost:5100` never
succeeded within its 5s budget and gave up -- even though the process was
genuinely up. Root cause, reproduced live: resolving `localhost` on this
machine tries IPv6 (`::1`) first, which sits in `SYN_SENT` rather than
refusing outright, before falling back to IPv4 -- slower than the 1s
per-attempt timeout in the readiness probe, and plausibly also marginal
against `NetService`'s own 5s timeout for the real fetch, which is what
produced the original "actively refused" errors on the very first launch
after redeploying (the master genuinely wasn't up yet on those runs -- a
separate, real bug in round 3's blind `Task.Delay(500)`, fixed by the same
change that surfaced this one).

Fixed by defaulting `MasterServerUrl` to `http://127.0.0.1:5100` instead of
`http://localhost:5100`, sidestepping hostname resolution for the loopback
case entirely. `MigrateStaleMasterServerUrl` extended to also catch the
intermediate `http://localhost:5100` default from round 3, alongside the
original pre-WO-35 Flask one. Re-verified live, on the actual deployed
install, with the human's own real (restored) `settings.json`: master starts,
answers within ~0.5s, no error.

**Process note**: while testing the "fresh install" scenario I deleted the
human's real `settings.json` to simulate a first launch, rather than reusing
the isolated test I'd already done for that path in round 3. Restored it
immediately from content read earlier in the same session. Flagging this as
a mistake, not something to repeat -- there was no need to touch a real file
to answer a question I already had evidence for.

## Round 5: remove the error dialog entirely, and the real "sometimes" cause

Human: still intermittent, and asked for the error to never show at all,
"remove it from the launcher entirely."

1. `NetService.GetServersFromMasterAsync`'s three failure paths (bad URL,
   API version mismatch, connect failure) no longer call
   `UiService.ShowError`/`LogError` -- they log to `app.log` only (`Log.Debug`
   for the ordinary "nothing's there" case, `Log.Warning` for the two that
   indicate real misconfiguration). The master server is optional by design;
   nothing about it should ever interrupt the player. The status bar's
   `Master: Online/Offline` (wired up in round 4) remains the one passive,
   non-blocking place this is still visible.
2. Hardened `EnsureLocalMasterServerAsync` against the TOCTOU race between
   two launcher instances: the responsiveness check and `Process.Start` are
   not atomic, so a losing instance's own copy can exit immediately after the
   other one claims the port. It now re-checks for a responding master once
   before giving up in that case, and the poll deadline moved 5s -> 8s for
   extra cold-start margin.
3. **The real, structural cause of "doesn't always work":** reproduced live
   via a routine partial redeploy (publishing just the launcher and copying
   only its files over the install). `KcdMpMasterServer.exe` crashed with
   `Could not load Microsoft.Extensions.Configuration.Abstractions,
   Version=10.0.0.0` -- a later Copy-Item into the shared, flat-merged
   install folder had overwritten one of its dependency DLLs with an
   incompatible version from another project's own bundle. This is not a
   one-off; it is the same DLL-probe-collision *class* already hit twice this
   WO (Serilog.Sinks.File, twice), now demonstrated to be triggerable by any
   partial update to the shared folder, not just a full from-scratch publish
   done wrong. Fixed structurally rather than procedurally: `KcdMpMasterServer.exe`
   now gets its own `MasterServer\` subfolder instead of being flat-merged
   with everything else (`tools/Publish-Release.ps1`, `AppModels.MasterServerPath`
   default updated to match, `MigrateStaleMasterServerPath` added for an
   existing settings.json that saved the old bare-filename default).

Re-verified live on the real install: the isolated copy starts and answers
cleanly (confirmed both by running it directly and through the real
launcher), and a normal `dotnet publish`-only redeploy of the launcher no
longer touches or can touch its dependencies at all.

## Note for the human, unrelated to this work

`git status` shows `kdcmp/Data/kdcmp.pak` as modified (same size, different
bytes, mtime during this session) — not touched by anything in this session's
work. Left alone; flagging so it isn't lost track of or assumed to be part of
this change. Also noticed (pre-existing, also untouched): a `KcdMpServer.exe`/
`KcdMpClient.exe`/`KCDMP_launcher.exe` set still running from a
`LocalCache\Local\Packages\...` sandbox path, and a separate
`KCDMP_launcher.exe` running from `%LOCALAPPDATA%\KCDMP\` — the latter is
plausibly the actual install the human used for the reported error.

## Open items for the human

None outstanding for WO-35 itself. Not committed — awaiting the human's
go-ahead to commit (per standing instruction: never commit without being
asked).
