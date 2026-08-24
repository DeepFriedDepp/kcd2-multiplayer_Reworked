# WO-50 progress

## Session 1 — 2026-08-24 (Sonnet 5)

Research only, per the brief — nothing built. Full detail in
`docs/WO-50-findings.md`.

1. Copied the human-provided `docs/branding/npp_kcd_mp_color.png` to the
   tracked `docs/branding/kcd2-mp-logo.png`; confirmed 2048×2048 8-bit RGBA
   with real alpha via `file`, matching spec.
2. **Discord presence:** confirmed no Discord Application exists yet in
   this repo (only an unrelated community-server invite link) — human must
   create one and hand over a Client ID + Rich Presence asset key before a
   build WO can start. Confirmed `DiscordRichPresence` (Lachee) is still
   current via NuGet directly (1.6.1.70, published 2025-08-04, net9.0
   target) rather than trusting memory. Decided the presence-owning process
   is the agent (`KcdMp.Client`), not the launcher — read
   `Home.razor.cs`'s `ConnectToGame`/`ConfirmExit` directly: the UI tells
   the player "you can close this once you're playing" and the launcher's
   own exit handler never kills the agent process. Flagged that
   hosting-vs-joined isn't currently knowable from the agent's own config
   and needs a new launcher→agent flag.
3. **HUD CVar:** game was launched live by the human mid-session
   specifically so this could be verified rather than guessed.
   `r_DisplayInfo` confirmed via the standard debug REST API
   (`GetCvarValue` → 3; `ExecuteString` set to 0; readback confirmed 0;
   restored to 3 after). Human visually confirmed live: the debug block
   disappeared, the ping indicator did not. Read `kdcmp.lua` and confirmed
   the ping indicator is mod-drawn (`System.DrawText`), an entirely
   different mechanism from the CVar — not just "a different setting."
   Found `System.SetCVar`/`AddCCommand` are real callable Lua bindings
   already used for the identical off-by-default-but-toggleable problem
   elsewhere in this file (`mp_dice_gate`), so the release-default fix is a
   mod-side Lua change, not an engine config file.
4. **Launcher icon:** confirmed `KCDMP_launcher.csproj` has no
   `ApplicationIcon` today (ships the SDK's generic icon) and confirmed
   `installer/KCDMP.iss`'s shortcuts have no `IconFilename` override, so
   fixing the exe's own icon is the only change point. Confirmed neither
   ImageMagick nor Python is available on this machine; identified two
   real conversion paths (ImageMagick install, or an in-repo C# ICO writer
   using `System.Drawing.Common`, already pulled in via
   `UseWindowsForms`). Found and flagged a real, currently-open
   Photino.NET GitHub issue (#106): `ApplicationIcon`/`SetIconFile` may
   still leave the Windows 11 taskbar icon generic even when done
   correctly — spec calls for both settings plus a live post-install
   taskbar check, not a silent assumption it's fully fixed.
5. Live game session used only for the two read/toggle/read round-trips on
   `r_DisplayInfo` above (plus the human's visual check) — no Lua edits,
   no pak rebuild, no other state changed in the running game or the mod.

**Nothing implemented in session 1.** `docs/WO-50-findings.md` has all
three ready-to-build specs and exactly what blocks each: Phase 1 needs the
human's Discord Client ID + asset key; Phases 2 and 3 need nothing further
from the human before a build WO can start.

## Session 2 — 2026-08-24 (Sonnet 5, same day)

Human asked for the icon fixed and a walkthrough to get the Discord
Client ID, then supplied it (`1541566715140243506`) and the asset key
(`kcd_mp_color_2`) after uploading the logo themselves. Built both
Phase 1 and Phase 3 from the session-1 specs. Full detail in
`docs/WO-50-findings.md`'s "Session 2 — implementation" section.

1. **Icon:** wrote `tools/Build-LauncherIcon.ps1`, generated
   `KCDMP_launcher/app.ico` (real 6-size multi-resolution ICO, confirmed
   via `file`), wired `ApplicationIcon` into the csproj and
   `SetIconFile` into `Program.cs`. Verified by extracting the built
   exe's own embedded icon and confirming it's the new logo pixel-for-
   pixel, not the SDK default.
2. **Discord presence:** built `DiscordPresence.cs`, wired into
   `GameBridge`/`ClientConfig`/`Home.razor.cs` per the session-1 spec.
   Smoke-tested the real compiled agent against a bogus relay (isolates
   Discord from needing the full game+relay stack) and found a real bug
   immediately: `System.NullReferenceException` inside
   `DiscordRPC.Assets.Merge`, non-fatal (library catches it internally)
   but real. Diagnosed by pulling the actual library source at the exact
   installed tag rather than guessing — confirmed `Assets.Merge` in
   `v1.6.1` calls `.StartsWith()` on a possibly-null field with no guard
   (fixed upstream on `master`/`v1.6.2`, never republished to NuGet).
   Fixed by always setting `SmallImageKey = ""` rather than leaving it at
   its C# default.
3. Re-ran the smoke test with added connection-state logging
   (`OnReady`, `OnPresenceUpdate`, explicit `SetPresence` argument
   logging) to get a real answer instead of guessing from silence:
   confirmed `Initialize()` succeeded, `OnReady` fired with the real
   logged-in Discord username, and `SetPresence` carried the exact
   configured text/image key.
4. Human's own Discord initially still showed the auto-detected
   "Kingdom Come: Deliverance II Modding Tools" line instead of the new
   presence. Rather than assume the code was broken, walked through:
   is the game actually running (auto-detect is a separate mechanism),
   is there a second activity entry on the full profile card, and
   finally the real answer — Discord's "Display current activity as a
   status message" privacy setting, separate from the game-auto-detect
   one. Human confirmed it was already on and sent a screenshot:
   Discord showing "Playing — KCD2 Multiplayer — Connecting... —
   v0.16.8 · solo" with the logo and a live elapsed timer, exactly
   matching the code. It "reverted" afterward only because the smoke
   test's own `timeout` command killed the process — correct behavior
   (presence should clear on exit), not a bug.
5. Farkle suite re-run after all changes: 59/59 PASS.

**Phase 1 and Phase 3 are done and live-verified. Phase 2 (HUD CVar) is
still just a spec** — not touched this session.

## Session 3 — 2026-08-24 (Sonnet 5, same day)

Human asked for Phase 2 built too, and set the version for this whole WO:
`0.17.0`.

1. Human reported Discord had reverted to showing the auto-detected
   "Kingdom Come: Deliverance II Modding Tools" line again. Checked
   directly instead of guessing: `tasklist` found no `KingdomCome.exe`,
   and `localhost:1403` refused the connection — neither the game nor
   the agent was running. Nothing to fix; Discord's own UI was just
   showing a stale auto-detect line with nothing live feeding either
   activity.
2. Bumped `VERSION` `0.16.8` → `0.17.0` — explicit string from the
   human, per `docs/VERSIONING.md`.
3. Built Phase 2 per the session-1 spec: `KCD2MP.debugHud = false` +
   `System.SetCVar("r_DisplayInfo","0")` at MOD INIT in `kdcmp.lua`,
   `KCD2MP_DebugHud(arg)` mirroring the existing `KCD2MP_EnableAggro`
   shape, registered as `mp_debug_hud on|off`.
4. Confirmed the game was closed (same tasklist/1403 check as step 1),
   then ran `tools\Build-And-Install-Mod.ps1` for real (no `-NoInstall`)
   — deployed straight into
   `D:\SteamLibrary\steamapps\common\KCD2Mod\Mods\kdcmp\`.
5. Rebuilt both .NET projects so the shipped binaries carry the new
   `0.17.0` informational version; re-ran Farkle: 59/59 PASS.

**All three WO-50 phases are now built.** Not done: no installer/
DirectInstall build (`Build-Installer.ps1`/`Build-DirectInstall.ps1`) —
that's a separate step for whenever the human wants to actually cut the
release, and Phase 2's mod-side change hasn't been re-verified live
in-game this session (would need a fresh launch + save load).

## Session 4 — 2026-08-24 (Sonnet 5, same day)

1. Built `release\KCDMP-Setup-0.17.0.exe` (95.7 MB) via
   `tools\Build-Installer.ps1` — clean compile, 1022-file manifest,
   `app.ico` present. `kdcmp.pak` re-packed identically (same as the
   0.16.6 precedent: content unchanged, zip entry timestamps only).
2. Human installed and ran the real 0.17.0 build; reported Discord stuck
   on the auto-detected "Kingdom Come: Deliverance II Modding Tools" line
   with the real game and agent both running together for the first
   time (every prior check had only one or neither running). Read the
   real installed `agent.log` (`%LocalAppData%\KCDMP\agent.log`) instead
   of re-guessing: it showed the exact same correct sequence as the
   working screenshot — `Initialize() = True`, `OnReady` with the real
   username, `SetPresence` for both "Connecting..." and "Hosting" with
   the right version and image key. Code confirmed doing its job
   correctly; pointed at Discord's own handling of two simultaneous
   activities (auto-detected game + custom RPC) as the remaining
   variable, and asked the human to check the full profile card rather
   than the compact hover status. **Resolved: working correctly** — no
   code change needed.
