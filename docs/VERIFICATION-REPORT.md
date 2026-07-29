# Verification report — post-WO-5 pass

Session date: 2026-07-28. Machine: single dev machine (no second machine/human
today; Python not installed at session start but installable). Branch `main`.

Format: item — **verdict** (observed-pass / observed-fail / blocked) —
evidence — date/machine.

---

## Headless baseline (before any live testing)

- `dotnet build KCD2-MP.sln` — **observed-pass** — build succeeded, 0 errors,
  8 pre-existing warnings (nullable/CA1416, unrelated to this pass) — 2026-07-28.
- `native\Build-Native.ps1` — **observed-pass** — `KCDMP.dll` (231,424 bytes),
  `KCDMP_LauncherInjector.exe` (158,720 bytes) built — 2026-07-28.
- `tools\Test-Combat.ps1` — **observed-pass** — 14/14 — 2026-07-28.
- `tools\Test-Sessions.ps1 -IncludeTimeout` — **observed-pass** — 23/23 — 2026-07-28.
- `tools\Test-Dice.ps1` — **observed-pass** — 10/10 — 2026-07-28.
- `dotnet test dotnet\KcdMp.Farkle.Tests` — **observed-pass** — 59/59 — 2026-07-28.
- Game directory discriminator (`D:\SteamLibrary\steamapps\common\KCD2Mod\Bin\Win64ReleaseSteamLTO_DLL`)
  — **observed-pass** — `Framework.dll`, `CrySystem.dll`, `WHGame.dll` all
  present beside `KingdomCome.exe`, 51 files in the directory — 2026-07-28.

---

## Backlog items (to be filled in as tracks run)

1. **Launcher-driven launch** (Track 1) — **observed-pass, with a real finding**
   — 2026-07-28, single dev machine.

   Fixed forward first (small, obvious defects hit before the launch itself
   could be tested):
   - `Home.razor.cs` `RefreshApp()` only pinged/probed the master-fetched
     `servers` list, never `customServers` — so any manually-added/custom
     server (no master server running) stayed at `Ping = -1` forever and
     `Launch` was unconditionally refused with "Server is unreachable."
     Changed the ping/probe loop to `servers.Concat(customServers)`.
     Headless suites re-verified green after the fix (see below).
   - `KCDMP_LauncherInjector.exe`'s path is hardcoded to sit beside
     `KCDMP_launcher.exe` (`AppDomain.CurrentDomain.BaseDirectory`), not
     configurable via settings — it was missing from the launcher's build
     output entirely. Copied the built injector next to the launcher exe.
     Not a code defect, just an undocumented deployment requirement — noting
     it here so packaging remembers to include it.

   Then the actual launch, end to end, triggered by one click on a
   pre-configured custom server row (127.0.0.1:7778):
   - Game process started by the launcher (`KingdomCome.exe`, pid 14188,
     `StartTime` 16:48:09).
   - **Measured**, not reasoned: `WHGame.dll` is present in the process's
     module list essentially immediately (a static import, not lazily
     loaded) — well under the 20 s `InjectDelaySeconds` default. The
     `WaitForInjectableAsync` timeout itself is not the bottleneck; 20 s is
     more than sufficient headroom for module presence.
   - Injector ran automatically, exit code 0, `KCDMP.dll` attached
     (`kcdmp-native.log` 16:48:16.491): rttr ABI validated, IAT hook
     installed on `C_ModulesManager::Update`.
   - Agent (`KcdMpClient.exe`) started automatically by the launcher after a
     successful injection and **connected to the relay** on its own,
     confirmed in the relay's own log: `'M31' connected (id=23, protocol
     v4) from 127.0.0.1:56650` at 16:49:36. This is the ghost/ relay pipeline
     working, launched with zero manual steps beyond the one click.

   **Real finding — not fixed, structural:** the native DLL's own liveness
   check (`dllmain.cpp`: install the hook, `Sleep(1000)`, and permanently
   abort — no retry — if `frame_count() == 0`) fired on the *automatic*
   injection and found **0 frames**, aborting before the pipe or sampler
   ever started (`kcdmp-native.log`: "MAIN: 0 frames in ~1s" / "tick is not
   firing -- aborting before any game-state access"). Root cause, verified
   by direct test: `WHGame.dll` loads almost instantly (see above), but the
   game's actual per-frame `C_ModulesManager::Update` loop does not start
   ticking until much later — past the splash/menu screens and into an
   actually-loaded save. Injecting the instant the module is merely
   *loadable* hooks the import correctly but checks for ticks far too soon.

   Verified by direct test, not fixed: with the game already deep into an
   active session (same still-running process, pid 14188), a second copy of
   the same DLL injected into a separate directory (to avoid a log-file
   sharing collision) succeeded immediately — "MAIN: 25 frames in ~1s",
   soul walk succeeded, hook installed, **pipe listening**, sampler tracking
   26 souls (`native\build\KCDMP_retry\kcdmp-native.log`, 16:53:13–16:53:17).
   This isolates the defect to timing, not the hook/rttr mechanism itself.

   **Unblocking requirement for a future session:** either have
   `KCDMP_launcher.LaunchGame` wait for a real gameplay signal (e.g. poll
   until a save is loaded, or retry injection after a delay) instead of
   injecting the moment `WHGame.dll` is merely present, or make the native
   DLL's own check retry/wait longer instead of a single 1 s sample. Both
   are design changes, not one-line fixes — flagged as a background task
   rather than redesigned mid-session (see rules of engagement).
2. **Dice in-game keybind** (Track 2) — **observed-fail (guess is unreachable
   in real gameplay), fallback promoted** — 2026-07-28, single dev machine.

   Method: set `KCD2MP.logActions = true` via the game's own debug REST API
   (`GET http://localhost:1403/api/System/Console/ExecuteString?command=%23...`,
   the same `#`-prefixed-Lua mechanism `HttpGameTransport.SendNowAsync`
   already uses) rather than the in-game console, since the console captures
   keyboard focus and swallows the very keypress being tested. Verified the
   channel itself works with a raw `System.LogAlways` probe before trusting
   it (see traps note below).

   With logging live, the human pressed 1, 2, 3, and 4 outside any NPC
   dialogue (the ordinary "stand near another player and invite them"
   case). Observed in `kcd.log`:
   ```
   ACT 'action_qam_1' a=press/release
   ACT 'action_qam_2' a=press/release
   ACT 'action_qam_3' a=press/release
   ACT 'action_qam_4' a=press/release
   ```
   Never `dialog_answer1`–`dialog_answer4`. `action_qam_N` is the existing
   Quick Access Menu (item/consumable hotbar) binding — already a live,
   frequently-used feature, so reusing these keys is not just unconfirmed,
   it is the wrong target. `dialog_answer1`–`4` are almost certainly
   fired only by the game's own NPC-dialogue UI when a multi-option
   conversation is on screen, not general-purpose physical keybinds — not a
   trigger a player could use to spontaneously invite a nearby real player
   to dice or to accept/decline. This is the same guess family as WO-2's
   `ACCEPT_ACTIONS`/`DECLINE_ACTIONS` (`dialog_answer1`/`2`), and the
   evidence above applies equally to those — never confirmed, same failure
   mode.

   Per the session brief's own instruction for this outcome: **the console
   command `mp_invite dice` (and the pre-existing `mp_accept`/`mp_decline`)
   is promoted from fallback to the documented, reliable path.** No code
   change made — `DICE_INVITE_ACTIONS`/`ACCEPT_ACTIONS`/`DECLINE_ACTIONS`
   are left in place (harmless: they just never match outside a real
   dialogue, and the code's own comment already accepts the small residual
   risk of a stray invite if they ever did fire mid-dialogue). Finding a
   genuinely free, reliably-bindable key is exploratory work for a future
   session, not a same-session fix.

   **Trap hit and worth carrying forward:** `tail -N | grep` against
   `kcd.log` produced false negatives twice here before the fix. This log
   writes roughly 25 lines/second during active gameplay
   ([KCD2-MP-DATA] position ticks), so a probe response line can scroll
   past a small tail window before the next check — looked exactly like
   "the command had no effect" when it had, in fact, worked immediately.
   Always grep the whole file, not a tail slice, when correlating a
   just-issued command against this log.
3. **Dice UI on a real screen** (Track 3) — pending
4. **Real Python master server** (Track 4) — pending, gated on Python install
5. **Two machines, two humans** (Track 5) — **blocked** — no second
   machine/human available this session. Unblocking requirement: a second PC
   or second human on the LAN, running the game via KCD2 Modding Tools, with
   network reachability to this machine's relay port (7778 by default).

## Future work (never built, out of scope this session)

- **Emotes** (brief WO-4) — not started.
- **Duelling** (brief WO-5) — not started.
