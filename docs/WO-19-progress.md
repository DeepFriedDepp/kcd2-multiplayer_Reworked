# WO-19 — launcher visual refresh, bug-report modal, version-mismatch notice

Three independent deliverables, shipped separately per the work order. `VERSION`
was not touched (still `0.9.5`); no release was built. See `VERSIONING.md`.

---

## D1 — visual refresh

### The design decision

Extending, not inventing: the in-game dice overlay already has a settled art
direction (`WO-6-overlay-design.md` §2 — aged parchment, oak, iron,
candle-warm gold, tavern shadow, described as linear 0..1 RGB draw-call
values). The launcher had none of its own — every component hardcoded its own
hex literals ad hoc (`#d4af37` for gold repeated across nine files, `#4a3b22`
for oak-ish borders, `#eee`/`#f0e6d2` for two slightly different "light text"
greys, etc.), and `StyleProfile.cs`/`Globals.CurrentStyleProfile` existed but
had **zero consumers** — a font-only profile class, save/load plumbing wired,
never read by any component or stylesheet.

So: converted the overlay's own palette from linear RGB to sRGB hex and made
it the launcher's palette too, rather than picking a second, different one.
Both UIs now read as one product instead of two reskins of a generic dark app.

| Token | Hex | Source | Used for |
|---|---|---|---|
| `--kcd-gold` | `#D9AD4D` | overlay `gold` | primary accent, active/selected |
| `--kcd-gold-bright` | `#FFDB73` | overlay `goldBright` | hover glow, flourish |
| `--kcd-parchment` | `#DBC9A1` | overlay `parchment` | body text |
| `--kcd-parchment-dim` | `#C7B99A` | derived | secondary text |
| `--kcd-oak` | `#573D24` | overlay `oak` | borders, separators |
| `--kcd-oak-lit` | `#856138` | overlay `oakLit` | (reserved — bevels, unused yet) |
| `--kcd-iron` | `#6B6963` | overlay `iron` | (reserved) |
| `--kcd-ink` | `#211A12` | overlay `ink` | text on a gold/parchment background |
| `--kcd-shadow` | `#0F0D0A` | overlay `shadow` | drop shadows, overlay tint (replaces pure `#000`) |
| `--kcd-blood` | `#9E211C` | overlay `blood` | danger/offline |
| `--kcd-danger-bright` | `#D6453D` | derived | danger hover/emphasis |
| `--kcd-warn` | `#C2793D` | derived | warning hints (`.kcd-hint`, replaces `#c86a4a`) |
| `--kcd-dim` | `#615747` | overlay `dim` | inactive elements |
| `--kcd-muted` | `#A99B7E` | derived | labels, de-emphasized text |
| `--kcd-muted-dim` | `#6B6355` | derived | separators, footer text |
| `--kcd-online` | `#5FBF4A` | derived | server-online status |
| `--kcd-track` | `#17120C` | derived | scrollbar track (replaces cool navy `#121a24`) |

Every hardcoded hex literal in `KCDMP_launcher` (`.razor`, `.razor.css`,
`site.css`, `modals.css` — verified by grep, zero remain outside the palette
definition itself) was replaced with one of these tokens. Coverage: `site.css`,
`modals.css`, `StatusBar`, `Home`, `ServerList`, `FilterSidebar`,
`ErrorModal`, `ExitModal`, `SettingsModal`, `HostInfoModal` — the whole
launcher, not just the home page, per the WO's requirement.

Small deliberate calls made along the way:
- **Hover states glow gold-bright, not stark white.** `color: #fff` on
  hover (StatusBar, ServerList's `.frame-btn`) became
  `var(--kcd-gold-bright)`, and the accompanying glow shadows use its RGB
  instead of pure white — reads as candlelight, not a generic UI highlight.
- **`ExitModal`'s title changed from red to gold.** Quitting the launcher is
  a routine confirmation, not an error; red framing (matching `ErrorModal`'s
  actual-error red) was borrowed without reason. `ErrorModal` keeps the red.
- **Sharp corners, no border-radius added anywhere.** Medieval parchment/oak
  does not read as rounded-corner software; this is a legibility-neutral,
  identity-positive choice stated explicitly rather than a default left alone.
- **`.kcd-hint` now has a real style** (`var(--kcd-muted)`, 13px) — it was
  used in `SettingsModal`/`HostInfoModal` but never defined, so it rendered
  as unstyled inherited text before this.
- **`focus-visible` outlines added** to `.kcd-btn` and `.status-btn` (gold,
  2px) — a real accessibility gap that did not exist before; keyboard
  navigation had no visible focus state anywhere in the app.
- **`.kcd-btn.danger` given real styling** — used by `HostInfoModal`'s "STOP
  HOSTING" button already, but no rule for it existed anywhere; it fell back
  to the plain `.kcd-btn` look with no danger signal at all.

### Making the profile live, not just documented

`StyleProfile.cs` gained matching colour properties and
`ToCssVariables()`, and `Home.razor.cs` pushes them over `site.css`'s `:root`
defaults via a new `applyKcdTheme` JS function (`wwwroot/index.html`) on first
render and on every `Globals.OnStyleChanged`. This was a deliberate, scoped
choice: wire the *existing* profile mechanism into actual rendering (it had
none before) rather than also building a profile-switching UI nobody asked
for — that would have been new feature surface beyond the WO's scope. The
`:root` CSS block in `site.css` is now documented as the fallback/default;
the `StyleProfile` instance is the live source of truth once JS interop is
available.

### Also fixed in passing (found while reading the read-first files)

`Globals.Version` was a hardcoded `"0.1.0"`, stale against the real shipped
version (`VERSION` said `0.9.5`) — nothing had ever wired it up. Both
`KCDMP_launcher.csproj` and `dotnet/KcdMp.Client/KcdMp.Client.csproj` now read
the repo-root `VERSION` file into `$(Version)` at build time
(`IncludeSourceRevisionInInformationalVersion` explicitly `false`, or the SDK
appends a git commit hash that both looks wrong in the status bar and breaks
D3's version parsing outright — caught by testing, see below).
`Globals.Version` and the new `ReleaseVersionInfo.Current` (agent) both now
read `AssemblyInformationalVersion` at runtime. **`VERSION`'s content itself
was never touched.**

---

## D2 — report-a-bug modal

`ReportBugModal.razor`, `@inherits ModalBase` exactly like `ErrorModal`
/`ExitModal` — no new modal pattern invented. Two buttons:

- **GitHub Issues** → `https://github.com/DeepFriedDepp/kcd2-multiplayer_Reworked/issues`
  (the Issues page specifically, not the repo root).
- **Discord** → `https://discord.gg/m4U95xUZ5` (supplied directly by the user
  in the commissioning message).

Both open via `Process.Start(UseShellExecute = true)` — hands the URL to
whatever the OS has registered (default browser, or the Discord app itself if
it has claimed `discord.gg` links), rather than the launcher trying to embed
or parse anything. Factored into a small shared `UrlLauncher.Open` helper
(`Components/Shared/UrlLauncher.cs`) since `VersionMismatchModal` (D3) needed
the identical behaviour for its own release-page link.

**Placement: `StatusBar`, next to `HOST GAME`.** The status bar already
splits into a left group of unkeyed action buttons (`HOST GAME`) and a right
group of keybound app controls (`[F10] SETTINGS`, `[F5] REFRESH`,
`[ESC] EXIT`). "Report a bug" has no keybind and is conceptually the same
kind of thing as "host a game" — an occasional, deliberate action a player
reaches for — so it joined that group rather than starting a third location
or a help menu that does not otherwise exist.

---

## D3 — version-mismatch notification

### Mechanism, confirmed before building

Per the WO's own instruction, checked rather than assumed:

1. **`Protocol.Version` (the wire-protocol byte) and release versioning
   (`VERSION`) are already two separate things in this codebase.**
   `ClientSession.RunAsync` rejects a `Protocol.Version` mismatch with
   `VersionMismatch` (0x09) and drops the connection, hard, unconditionally —
   confirmed unchanged (see Regression below). Nothing about D3 touches that
   path; a new, independent, additive wire packet type was used instead.

2. **No live launcher↔agent channel exists.** Read `WO-6-progress.md`
   ("Launcher window: retired, and the IPC decision") and
   `dotnet/KcdMp.Client/DiceIpcServer.cs`'s own doc comment: WO-6 deleted
   `DiceWindow.razor`, `Services/DiceIpcClient.cs` and the launcher-side DI
   registration. `DiceIpcServer` survives *only* as a documented headless-test
   surface — its own comment says explicitly "nothing in the launcher polls
   this any more." `LAUNCHING.md` confirms the launcher starts
   `KcdMpClient.exe` as a bare subprocess and never reads or writes anything
   from it afterward. So: **a new small channel was required**, not an
   assumption to verify away.

### What was built

**Wire layer** (`dotnet/KcdMp.Protocol/Protocol.cs`), additive, no
`Protocol.Version` bump:
- Handshake gains an **optional trailing field** after `[name:UTF-8]`: the
  sender's release version as UTF-8 text. Same idiom already used for
  Invite's `[configLen][config]` — the field has no explicit length prefix of
  its own, because the outer `[type][payloadLen]` framing already carries the
  total, so "whatever is left after the name" is exactly the release version.
  An old relay reads only `[version][nameLen][name]` and never looks past it,
  so a new client's extra bytes are silently ignored — verified, see below.
- **`0x1E ReleaseVersion: [ghostId:1][releaseVersion:UTF-8]`** (S→C), same
  shape as `Name` (0x03). Broadcast to existing peers when a client's
  Handshake carried one (`TcpBroadcastService.BroadcastReleaseVersion`,
  mirrors `BroadcastName`) and replayed to a new joiner for every existing
  peer that has one (`SendAllReleaseVersionsTo`, mirrors `SendAllNamesTo`).
  Never sent for a client whose Handshake carried none.
- `ReleaseVersionCompare` (new file): parses two `Major.Minor.Patch[.Build]`
  strings and returns `Equal` / `LocalIsOlder` / `LocalIsNewer` / `Ambiguous`.
  Anything that fails to parse (either side) is `Ambiguous`, never guessed.

**Relay** (`ClientSession.cs`, `TcpBroadcastService.cs`): parses the trailing
field into `ClientSession.ReleaseVersion` (null if absent), broadcasts and
replays it exactly as described above.

**Agent** (`dotnet/KcdMp.Client`):
- `ReleaseVersionInfo.Current` reads the agent's own build version from
  `AssemblyInformationalVersion` (see D1's build-time `VERSION` wiring).
- Handshake construction appends the trailing field; `ReceiveLoopAsync`
  handles inbound `0x1E` into a new `_ghostReleaseVersions` map (mirrors
  `_ghostNames`).
- **`VersionIpcServer`** (new, `VersionIpcPort` config, default `5902`): a
  second small loopback `HttpListener`, same reasoning as `DiceIpcServer`'s own
  doc comment (no channel exists, both processes must still work started
  independently, a polled HTTP endpoint is the smallest thing that fits) —
  but a **separate** listener rather than an extra route on `DiceIpcServer`,
  because that one is explicitly a kept-for-testing survivor and this is a
  live, load-bearing feature; conflating them would have muddied both
  comments. `GET /version-status` → `{ myReleaseVersion, peers: [{ghostId, releaseVersion}] }`.

**Launcher**:
- `AppSettings.VersionIpcPort` (mirrors `DiceIpcPort`'s existing, unused
  field — this one is actually read).
- `NetService.GetVersionStatusAsync` polls the endpoint (same idiom as
  `GetDedicatedServerInfoAsync`).
- `Home.razor.cs`'s `PollVersionMismatchAsync`: started right after
  `ConnectToGame` starts the agent process, polls every 3s for up to 5
  minutes, stops on the first peer seen (match → silent, mismatch → modal,
  ambiguous → neutral modal message) or on timeout (solo session). Cancelled
  on `ResetLaunchState`/`ConfirmExit` so it never outlives a launch.
- `VersionMismatchModal.razor`, `@inherits ModalBase` like everything else.
  Message is direction-aware: *"You're on X, your host is on Y — you'll need
  to update"* (or the reverse), falling back to a neutral *"Versions don't
  match — make sure everyone's on the latest release"* only when
  `ReleaseVersionCompare` returns `Ambiguous`. Links to
  `https://github.com/DeepFriedDepp/kcd2-multiplayer_Reworked/releases`.

### Verified

- **Wire layer, synthetic** (`tools/Test-ReleaseVersion.ps1`, new, 6/6):
  two clients declaring different release versions receive each other's
  `0x1E`; a client sending the exact pre-WO-19 handshake shape (no trailing
  field at all, not just an empty one) is accepted normally and never
  triggers a `ReleaseVersion` packet about itself; a late joiner is replayed
  an existing peer's release version; a `Protocol.Version` mismatch is still
  refused hard regardless of release version.
- **Full solution builds clean** (`dotnet build KCD2-MP.sln`), only
  pre-existing warnings.
- **Assembly version stamping**: confirmed via `Get-Item ... VersionInfo` on
  both built exes — both report a clean `0.9.5`, matching `VERSION`, with no
  git-hash suffix (the `IncludeSourceRevisionInInformationalVersion` fix was
  caught exactly this way — the first build embedded
  `0.9.5+<commit-hash>`, which would have made `ReleaseVersionCompare` treat
  every version as `Ambiguous`).
- **Launcher starts clean** with all new components (`ReportBugModal`,
  `VersionMismatchModal`) rendering with no exceptions, confirmed against the
  app's own Serilog log — the only errors logged are the pre-existing "no
  local master server/relay running" ones, unrelated to this work.

### Not verified (honest gaps)

- **No real two-different-release-version test.** Only one build of this repo
  exists here (one machine, one game copy, per `PROJECT-STATE.md` §6) — the
  synthetic wire test stands in for it, same reasoning as every other
  two-peer feature in this project.
- **No screenshot of the modal or the D1 redesign.** `KCDMP_launcher` is a
  Photino-hosted native desktop window, not a web server — it was launched
  directly and its log inspected for crashes/render errors (clean), but there
  is no way to visually inspect a native window's pixels from here. Actual
  visual review is still owed to a human with the game and a screen.

---

## Regression

Run this session, relay started locally, no game involved:

| Suite | Result |
|---|---|
| `KcdMp.Farkle.Tests` (xUnit) | 59/59 |
| `Test-Combat.ps1` | 14/14 (includes "a v2 agent is refused rather than silently dropping hits" — the protocol hard-refusal path) |
| `Test-Sessions.ps1` | 22/22 |
| `Test-Dice.ps1` | 10/10 |
| `Test-ReleaseVersion.ps1` (new, WO-19) | 6/6 |

Not run: `Test-Pipe.ps1`, `Test-Installer.ps1`, `Test-InstallerDetect.ps1` —
all need the game and/or a built installer, neither available in this
environment (consistent with every prior WO's regression notes).

**The existing protocol-version hard refusal is unaffected** — re-verified
directly in both `Test-Combat.ps1` (unchanged, still passes) and
`Test-ReleaseVersion.ps1`'s own case 4, added specifically because this
session's changes touched the same handshake-parsing code path.
**Same-release-version connections are unaffected** — every existing suite's
handshake carries no trailing release-version field at all (they predate
WO-19) and all pass unchanged, which is itself the backward-compatibility
proof: an old-shaped handshake is still accepted identically.
