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

**Nothing implemented.** `docs/WO-50-findings.md` has all three
ready-to-build specs and exactly what blocks each: Phase 1 needs the
human's Discord Client ID + asset key; Phases 2 and 3 need nothing further
from the human before a build WO can start.
