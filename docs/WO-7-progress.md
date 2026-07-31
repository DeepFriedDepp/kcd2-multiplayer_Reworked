# WO-7 progress — launcher completion, networking docs, README rewrite

Session date: 2026-07-30. One dev machine, no second human/PC today — every
game-dependent claim below is marked unverified rather than assumed. Branch
`main`. No engine, protocol, or session-framework changes this session (rule
6 of the brief) — everything here is launcher orchestration, packaging, and
docs.

## Phase 0 — ground-truth ledger

Full status ledger is now in `README.md`'s Status table (baked in, not
duplicated here). Method: a research pass cross-checked every `docs/*.md`
claim against actual code (file:line), then three of the highest-stakes
claims were spot-verified directly in this session before trusting them:

- Relay binds `IPAddress.Any` — `dotnet/KcdMp.Server/Features/Tcp/TcpSocketService.cs:42`.
- The native DLL's 0-frames abort race is still live and un-retried —
  `native/KCDMP/dllmain.cpp:53-59`.
- The launcher's dice window is actually gone — `Glob KCDMP_launcher/**/Dice*` → no results.

Two corrections worth carrying forward: `docs/WO-5-dice.md`'s architecture
diagram still shows the deleted `DiceWindow.razor` launcher flow — it's
stale, trust `docs/WO-6-progress.md` and the code instead. `InteractionKind.Duel`
exists as a wire enum value with zero handling in `SessionManager.cs` — it
reads like a shipped feature to someone skimming `Protocol.cs`; it isn't.

## Phase 1 — launcher

The launcher (`KCDMP_launcher/`) had **no host flow at all** before this
session — only join (server list + manually-added custom servers). That was
the single biggest gap against "a friend can actually play," bigger than
anything `docs/LAUNCHING.md` flagged, because that doc only covered the
join path. Fixed this session, along with the two gaps it did flag.

### 1. Correct game build detection — already present, unchanged

`Home.razor.cs: IsModdingToolsBuild` already checked for `Framework.dll` +
`CrySystem.dll` beside the exe, not a filename. Verified still correct;
nothing to do here.

### 2. Injection race — gated, not fixed at the native layer

The real bug, confirmed in code this session: the launcher used to inject
the instant `WHGame.dll` became loadable (near-instant after process start),
but the native DLL's own liveness check
(`native/KCDMP/dllmain.cpp:53-59`, one `Sleep(1000)` sample, no retry) only
survives once the game is deep into an actually-loaded save — confirmed by
`docs/VERIFICATION-REPORT.md`'s own test (injecting a second copy into a
mid-session process succeeded immediately; injecting at menu/load-screen
time found 0 frames and aborted). Because Windows does not re-run `DllMain`
for an already-loaded module, there is no software retry once that happens —
only a fresh game launch recovers.

Fix, in `KCDMP_launcher/Pages/Home.razor.cs`: `LaunchGame` now only starts
the game and waits for the module to be loadable, then stops and shows a
"load your save, then click CONNECT" banner (`LaunchStage.WaitingForConnect`).
Injection itself only happens from the new `ConnectToGame()`, triggered by
the user, and only once — by construction, the user has (in the intended
flow) already loaded into the world by the time they click it. After
injecting, `VerifyInjectionAsync` polls the DLL's own log
(`kcdmp-native.log`, written beside the DLL per `native/KCDMP/log.h`) for
this run's `pid=<pid>` line and the `frames in ~1s` sample that follows it,
and only starts the agent if frames > 0. If verification fails (clicked
Connect too early, or the log never shows a conclusive result within 8s),
the user gets an explicit message that a fresh game launch is required —
no silent "looks connected but isn't" state, which is what the old flow
produced (injector exit code 0 either way).

**This moves the race from "silent" to "the user is told to wait and gets a
straight answer either way," but does not eliminate the possibility of a
too-early click.** A future session could poll a real gameplay signal (e.g.
the debug REST API responding meaningfully) to auto-enable Connect instead
of trusting the user's judgement — flagged, not built, since it's exploratory
and this session's fix already satisfies "user never sees a silent race."

### 3. Agent auto-start, voice as a normal setting

Unchanged: the agent is started automatically after successful verification.
New: `AppSettings.VoiceChatEnabled` (`KCDMP_launcher/Models/AppModels.cs`),
a checkbox in Settings, appends `--no-voice` to the agent's args when off —
mirrors `KcdMp.Client`'s existing `--voice`/`--no-voice` flags
(`ClientConfig.cs:186-191`), no agent-side change needed.

### 4. Dependencies bundled

Confirmed via `native/CMakeLists.txt:13`
(`CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded..."`, i.e. static CRT): the
native DLL and injector need **no VC++ redistributable** — nothing to bundle
or check there.

The .NET side (launcher, agent, relay) was framework-dependent by default —
a friend without the .NET 8 runtime would hit a cold OS-level "framework not
found" dialog before any of our own error handling could run. Fixed by
adding `SelfContained=true` / `RuntimeIdentifier=win-x64` to each project's
own `Properties/PublishProfiles/FolderProfile.pubxml` — **deliberately not**
in the `.csproj` files themselves, because setting a `RuntimeIdentifier` at
the project level changes `dotnet build`'s own output path to a
`win-x64`-suffixed folder, which would have broken every hardcoded path the
`tools\Test-*.ps1` suites and normal `dotnet run` workflow assume. Publish
profiles only apply to `dotnet publish`, so ordinary dev builds and the test
suites are untouched — verified by rebuilding the full solution and rerunning
all four suites after making this change (see Testing below).

New `tools\Publish-Release.ps1` publishes all three self-contained, builds
native artifacts if missing, and assembles one release folder with
everything the launcher's relative-path settings
(`DllPath`/`AgentPath`/`RelayPath`) expect to find beside it. **Not run this
session** — it's straightforward `dotnet publish`/copy plumbing built from
confirmed paths, but exercising the actual multi-hundred-MB self-contained
publish end to end is real, unverified follow-up work; mark it as such
before cutting a release.

### 5. Host vs. Join — Host built from scratch

New: `AppSettings.RelayPath` (default `KcdMpServer.exe`, resolved the same
way as `AgentPath`/`DllPath`) and `AppSettings.HostPort` (default `7778`,
matching the relay's own default). A "HOST GAME" button
(`KCDMP_launcher/Components/StatusBar.razor`) calls `Home.OpenHostModal()`,
which starts the relay as a child process (`--port <HostPort>`, confirmed
accepted — `dotnet/KcdMp.Server/Program.cs:17`) if not already running, and
shows a new `HostInfoModal.razor`: every non-loopback IPv4 address this
machine has (`NetService.GetLocalIPv4Addresses`, so a VPN adapter's address
shows up alongside the LAN one), the port, and a plain-language note on
LAN/VPN/port-forward with a pointer to `docs/NETWORKING.md`. "START GAME"
from that modal runs the same `LaunchGame`/`ConnectToGame` flow against
`127.0.0.1:<HostPort>` — the host's own agent always talks to its own
machine's relay regardless of what address a friend is told to use. The
relay child process is killed on launcher exit (`ConfirmExit` →
`StopHostedRelay`).

Join was already functional (server list + "Add Server" for a manual
address) and needed no structural change — the master-server chain behind
the list is the part that's unverified (Python side never run, per Phase 0),
not the manual-address path, which only needs the address a host's launcher
now actually shows.

**Bug caught during review:** `ExitModal`'s `OnConfirm` called
`Environment.Exit(0)` directly from an inline lambda in `Home.razor` — the
`ConfirmExit()` method that stops the hosted relay was never actually wired
to the exit button (dead code, pre-existing this session's `StopHostedRelay`
call too). Fixed by pointing `OnConfirm` at `ConfirmExit` directly, so
exiting the launcher while hosting now kills the relay process it started
instead of leaving it running.

### 6. Dead dice window

Confirmed already gone (Phase 0). `AppSettings.DiceIpcPort` remains as an
inert, already-undocumented-in-UI settings field (never shown in
`SettingsModal.razor` before or after this session) — left alone rather than
removed, since its own code comment already explains why it's kept
(round-tripping an existing `settings.json`) and removing it now would be
scope creep on a field that isn't actually causing confusion.

## Phase 2 — networking

Confirmed from code, not assumed (see Phase 0 spot-check): the relay binds
`0.0.0.0` by default and nothing in the agent or launcher is hardcoded to
`localhost` in a way that would block LAN or VPN-overlay play — the agent's
`localhost` is an editable default, and the launcher already passes whatever
IP the user gave it straight through. **No config-knob fix was needed** for
Phase 2; the gap was purely that nothing in the launcher ever showed a host
their own address or ran their own relay, which Phase 1 §5 above closes.

Wrote `docs/NETWORKING.md`: host-vs-join model, LAN (no setup), VPN overlay
(Tailscale et al., recommended default for a friend group), port forwarding
(the no-VPN alternative, with the real caveat that it opens a port to the
internet), exactly what to share (`address:port`), and a troubleshooting
section (firewall prompts are the most likely first failure). Linked from
`README.md`'s "How to play with a friend" section.

## Phase 3 — README

Replaced. New README leads with what the fork actually is now (not the
original position/voice-sync description), the Phase 0 status table with
honest labels, install/launch pointing at the launcher and the new
Host/Join flow, a link to `NETWORKING.md`, and a License/provenance section
carried forward unchanged from the old README (it was already accurate:
GPLv3, forked from `marczukmichal/kcd2-multiplayer` with permission,
upstream correctly described as carrying no license of its own rather than
being GPL itself) plus a more prominent credit line and a "not affiliated
with Warhorse Studios" disclaimer at the top, which the old README lacked
entirely.

## Testing

All green, this session, after every code change above:

- `dotnet build KCD2-MP.sln` — 0 errors (7 pre-existing warnings, unrelated).
- `dotnet build KCDMP_launcher\KCDMP_launcher.csproj` — 0 errors (1
  pre-existing warning), confirming the new Home.razor.cs/HostInfoModal.razor/
  StatusBar.razor/SettingsModal.razor code compiles.
- `tools\Test-Combat.ps1` — 14/14.
- `tools\Test-Sessions.ps1 -IncludeTimeout` — 23/23.
- `tools\Test-Dice.ps1` — 10/10.
- `dotnet test dotnet\KcdMp.Farkle.Tests` — 59/59.
- `tools\Test-Pipe.ps1` — **not run**, needs the real game with the plugin
  injected (game-dependent, no game today — see manual procedure below).

## Manual test procedure — needs the game, not run this session

Mark each step executed or not when a second sitting (or second machine) is
available. None of these were run this session; nothing below should be
read as a pass.

**A. Single-machine host+join sanity (one PC, one game copy — as far as this
setup can go without a second human):**
1. [ ] Launch `KCDMP_launcher.exe`. Confirm it finds the Modding Tools build
   (or shows the "looks like retail" error if pointed at the wrong exe).
2. [ ] Click HOST GAME. Confirm the relay starts (check for a
   `KcdMpServer.exe` process) and the modal shows at least one LAN address.
3. [ ] Click START GAME. Confirm `KingdomCome.exe` launches and the launcher
   shows "load your save, then click CONNECT."
4. [ ] Load a save, get in-world (character moving), click CONNECT.
5. [ ] Confirm the modal reaches "Connected," `kcdmp-native.log` shows a
   nonzero `frames in ~1s` line for this run's `pid=`, and `KcdMpClient.exe`
   started.
6. [ ] Deliberately click CONNECT immediately after step 3 (before loading a
   save) on a separate attempt, to confirm the failure path: verification
   should fail within ~8s with the "click Launch again" message, not hang or
   falsely report success.

**B. Two machines, two humans (the real test — genuinely blocked today, no
second PC/human available):**
1. [ ] PC A hosts, shares the LAN address shown.
2. [ ] PC B adds that server and joins.
3. [ ] Both load saves, connect (per A.4-5 above on each machine).
4. [ ] Confirm each sees the other's ghost, hears proximity voice, and that
   a shared-combat hit registers both ways.
5. [ ] Start a dice match via in-game invite; play a full match to
   completion on both screens.
6. [ ] Repeat A/B with one PC on a different network, using a VPN overlay
   address per `docs/NETWORKING.md`, to validate the internet-play path.

**C. Release packaging (no game needed, but not run this session):**
1. [ ] Run `tools\Publish-Release.ps1` on a clean checkout.
2. [ ] Copy the output folder to a machine with no .NET runtime installed
   and confirm the launcher starts without a runtime-missing dialog.

## Known follow-up, not built this session

- Auto-detecting "the game is actually in a loaded world" (instead of
  relying on the user's own judgement before clicking Connect) would close
  the last sliver of the injection race. Needs a reliable signal; flagged in
  §2 above, not designed.
- `tools\Publish-Release.ps1` itself is unexercised — see Manual test
  procedure C.
- Pre-existing uncommitted change to `kdcmp/Data/kdcmp.pak` was present at
  the start of this session (not made by this session, not touched by it) —
  carry it forward or resolve it separately; it's unrelated to WO-7.

## Next session should start from

This file, plus `README.md`'s Status table (now the canonical ledger — don't
re-derive it from scratch, but do re-verify anything load-bearing before
trusting it, same as this session did). The manual test procedure above is
the actual next step once a second machine/human is available.
