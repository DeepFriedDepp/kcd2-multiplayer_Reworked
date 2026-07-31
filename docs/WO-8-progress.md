# WO-8 progress — one-click installer

Session date: 2026-07-30. Branch `main`. One machine, and it is a development
machine — every claim below is either marked verified with what verified it,
or marked unverified. No engine, protocol or session-framework changes. The
launcher got exactly one change, the one Phase 3 permits.

The goal, restated as the test: a non-technical friend downloads one
`Setup.exe`, clicks through it, and ends with everything installed, the mod
deployed into the game, the game located, a shortcut on the desktop, and no
way to finish the wizard without the KCD2 Modding Tools present. Before this
session they had to unzip two folders, hand-copy `kdcmp` into a directory
they had to find themselves, and hand-point the launcher at an exe.

---

## Phase 0 — decisions and discovery

### Installer technology: Inno Setup 6.7.3

Installed on this machine with `winget install --id JRSoftware.InnoSetup`
(with the user's explicit approval, since it meant downloading and running a
third-party installer).

Why, concretely:

- `ISCC.exe` compiles a `.iss` from one command, so it drops into the release
  pipeline without ceremony.
- Custom wizard pages with a `NextButtonClick` hook. **This is the deciding
  feature** — the Modding-Tools hard gate is a wizard page that refuses to
  advance, and that needs a UI toolkit where "refuse to advance" is a
  first-class thing rather than a fight.
- `/VERYSILENT` with a `/LOG`, which is what makes the lifecycle test in
  `tools\Test-Installer.ps1` possible at all.
- A real uninstaller and Add/Remove Programs registration for free.
- `DownloadTemporaryFile` in the scripting layer, so the WebView2 bootstrapper
  needs no third-party plugin.
- Its licence permits redistributing installers for GPL software.

WiX/MSI buys nothing here: no per-machine policy story is wanted (this is a
per-user install by design), and custom UI in MSI is substantially worse.
NSIS is comparable on capability but weaker on wizard-page validation, which
is the one thing this installer most needs.

### Steam App ID: 2429020 — read from disk

`D:\SteamLibrary\steamapps\appmanifest_2429020.acf`:

```
"appid"      "2429020"
"name"       "Kingdom Come: Deliverance II Modding tools"
"installdir" "KCD2Mod"
```

Corroborating, from the same library: retail KCD2 is app `1771300`,
`"name" "Kingdom Come: Deliverance II"`, `installdir
"KingdomComeDeliverance2"` — a genuinely separate Steam entry, which is why
the "install the Modding Tools too" step exists at all.

The install resolves to
`D:\SteamLibrary\steamapps\common\KCD2Mod\Bin\Win64ReleaseSteamLTO_DLL\KingdomCome.exe`,
with 45 DLLs beside it including `Framework.dll` and `CrySystem.dll` — the
discriminator passes. Detection is written against Steam's metadata
(`libraryfolders.vdf` → per-library `appmanifest_2429020.acf` → `installdir`),
never against that literal path.

### Verified dependency manifest

| Component | Needed? | How detected | How installed |
|---|---|---|---|
| **WebView2 Runtime** | **Yes** — the launcher is Photino, which renders through it | `pv` value under `EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}` in `HKLM32`, `HKLM64` and `HKCU`, treating empty and `0.0.0.0` as absent | Evergreen bootstrapper downloaded from `https://go.microsoft.com/fwlink/p/?LinkId=2124703` and run `/silent /install`; per-user because Setup is not elevated |
| **.NET 8 runtime** | No — self-contained | n/a | n/a, it is in the payload |
| **VC++ redistributable** | No — static CRT | n/a | n/a |
| **Steam** | Yes, but not installed by us | `HKCU\Software\Valve\Steam\SteamPath`, falling back to `InstallPath` in both HKLM views | Not installed; its absence gets an explanatory page |
| **KCD2 Modding Tools** | Yes, hard requirement | appmanifest + discriminator (below) | Not installed; deep-linked and gated |

The WebView2 answer is evidence, not assumption. `Photino.Native` 4.0.22
ships `runtimes\win-x64\native\WebView2Loader.dll` (166 KB) and nothing else
WebView2-shaped — that DLL is the *loader stub*, whose whole job is to find a
machine-wide Evergreen runtime. On this machine that runtime is a separate
installation at `C:\Program Files (x86)\Microsoft\EdgeWebView\Application\150.0.4078.105`,
registered at
`HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-...}` with
`pv = 150.0.4078.105` and `name = Microsoft Edge WebView2 Runtime`; the HKCU
key is absent. Windows 11 and updated Windows 10 ship it, but Server images
and some LTSC/enterprise builds do not, so the installer cannot assume it.

Self-containment confirmed by inspecting the publish output rather than
trusting the property: `hostfxr.dll`, `System.Private.CoreLib.dll` and
`vcruntime140_cor3.dll` are all present beside the three apphost executables.
417 top-level files, 193 MB.

### Install location: `%LocalAppData%\KCDMP`, `PrivilegesRequired=lowest`

No UAC prompt at any point, which for a non-technical friend is worth a lot.
Justified on three counts:

1. The launcher writes `settings.json` in its own working directory, so a
   Program Files install would need elevation every time Settings was saved —
   or a change to launcher code this work order does not permit.
2. The mod's destination is inside the Steam library, and Steam grants
   `BUILTIN\Users FullControl` on its own tree — verified with `Get-Acl` on
   `C:\Program Files (x86)\Steam\steamapps\common` on this machine. So an
   unelevated install can write `<ModdingTools>\Mods` even for a Steam that
   lives under Program Files.
3. Everything else (shortcuts, Add/Remove entry, the `HKCU\Software\KCDMP`
   marker) is per-user anyway.

---

## Phase 1 — the installer

`installer\KCDMP.iss` is the wizard; `installer\SteamDetect.iss` is the
detection logic, factored out so `installer\tests\SteamDetectProbe.iss` can
compile *the same file* into a test harness rather than testing a copy of it.

### Detection and the gate

`GetSteamPath` reads `HKCU\Software\Valve\Steam\SteamPath` first — note it is
written with forward slashes (`c:/program files (x86)/steam` on this machine),
so it is normalised — and falls back to `InstallPath` under both HKLM views.
`GetSteamLibraries` returns the Steam root plus every `"path"` entry in
`steamapps\libraryfolders.vdf`, unescaping the doubled backslashes and
skipping roots that are not currently present (disconnected drives).
`DetectModdingToolsIn` looks for `appmanifest_2429020.acf` in each library,
reads `installdir`, and then finds the executable under
`<install>\Bin\<config>\KingdomCome.exe` — trying the known
`Win64ReleaseSteamLTO_DLL` first, then enumerating `Bin\*`.

Nothing counts as found until it passes the discriminator: `Framework.dll`
and `CrySystem.dll` beside the exe. That is deliberately the same test as the
launcher's `Home.razor.cs:IsModdingToolsBuild`, for the same reason — both
builds are called `KingdomCome.exe` and both ship `WHGame.dll`, so the only
honest test is for the modules the plugin actually hooks.

The mod's destination is derived by walking up from the exe until a folder
containing both `Data` and `Engine` is found, rather than by counting path
levels, so a differently-named `Bin` subfolder still resolves.

**The gate.** When detection fails, the wizard page explains what the Modding
Tools are and why the retail game will not do, offers a button that opens
`steam://install/2429020`, and offers Re-check. `NextButtonClick` returns
`False` until detection passes, so Next is dead. `PrepareToInstall` repeats
the whole check, which is what stops `/VERYSILENT` — where wizard pages never
run — from walking straight past it. Browse... exists for unusual setups and
is held to the same discriminator; picking a retail exe is rejected with an
explanation. "Steam not installed at all" is its own message rather than a
crash or a misleading "Modding Tools missing".

An installer cannot make Steam download anything — Steam owns that
transaction. Detect, deep-link, and refuse to advance until verified is the
strongest form this requirement can take on Windows, and that is what is
built.

### Deployment

- Everything `tools\Publish-Release.ps1` produces goes to `{app}`, flat,
  because the launcher resolves relative `DllPath`/`AgentPath`/`RelayPath`
  against its own directory and that is the layout `AppSettings`' defaults
  already assume.
- `kdcmp\` goes to `<ModdingTools>\Mods\kdcmp`, creating `Mods` if needed. An
  existing folder is emptied first so this is a clean replace, never a merge.
  If it was not put there by this installer (no `HKCU\Software\KCDMP\ModsPath`
  marker), the user is asked before it is replaced.
- `settings.json` is pre-seeded with the detected `GamePath` **and nothing
  else**. Every other `AppSettings` field has a usable C# default and a
  partial JSON file deserialises to exactly those defaults, so writing one key
  is both sufficient and the least likely thing to rot when the settings model
  changes. An existing `settings.json` whose `GamePath` is non-empty is not
  touched at all, which is what makes upgrade-in-place non-destructive.
- Shortcuts on the desktop (a task, checked by default) and in the Start Menu,
  both with `WorkingDir` pinned to `{app}` — see the correction below for why
  that is load-bearing rather than tidy.
- Finish page offers "Launch now" and states the one-line networking rule.

### Uninstall

Removes `{app}` wholesale (including the runtime-created `settings.json`,
`favorites.json` and `kcdmp-native.log`, which `[Files]` never installed),
both shortcuts, the marker key and the Add/Remove entry. The mod is flagged
`uninsneveruninstall` and removed only by answering the uninstaller's
question — **this flag is load-bearing**: without it Inno silently deletes the
mod files out of the player's game folder, which was observed in the first
uninstall test and is not ours to do unasked. An unattended uninstall has
nobody to ask, so it leaves the mod alone. The game itself is never touched.

---

## Phase 2 — build pipeline

```bash
powershell -ExecutionPolicy Bypass -File tools\Build-Installer.ps1
```

Runs `Publish-Release.ps1`, checks the payload is real (a missing or empty
`release\KCDMP` would otherwise compile happily into an installer that
installs nothing), then `ISCC` → `release\KCDMP-Setup-<version>.exe`. 64.9 MB.

Version lives in the `VERSION` file at the repo root and nowhere else. It is
stamped into the Setup filename, the Add/Remove Programs entry
(`DisplayVersion`) and the exe's own Win32 version resource. `0.8.0` to start
— the repo had no version anywhere before this.

### `Publish-Release.ps1` had never run, because it could not

WO-7 flagged it as unexercised. Exercising it found two bugs, each fatal on
its own, fixed in their own commit (`d03e4e5`):

1. `KCDMP_launcher\Properties\PublishProfiles\FolderProfile.pubxml` had `--`
   inside an XML comment. MSBuild refuses to load such a file (MSB4024), so
   the launcher could not be published at all.
2. `Publish-Project` logged with `Write-Output`, which in PowerShell *is* the
   return value — the caller got an array of log lines with the path last, and
   `Copy-Item` went looking for a drive named `Publishing C`.

The fix for (2) went through one wrong answer worth recording: switching the
logging to `Write-Host` fixed the return value but sent MSBuild's diagnostics
to the console host, where a redirected or background run cannot capture them
— which is exactly when they matter. The path now comes back through
`$script:PublishDir` so all logging can stay on the success stream.

### And then the packaged relay did not start

With publishing finally working, `KcdMpServer.exe` from `release\KCDMP` died
immediately:

```
Unhandled exception. System.IO.FileNotFoundException: Could not load file or
assembly 'Serilog.Sinks.File, Version=7.0.0.0'
```

It runs fine from its own publish folder. The release folder is a flat merge
of three self-contained publishes, and the launcher contributes
`Serilog.Sinks.File.dll` for its own logging.
`Serilog.Settings.Configuration` probes the `Serilog.*.dll` files it finds
beside the executable, and a self-contained host refuses to load an assembly
that is not in *that application's* `.deps.json`. So a neighbour's DLL was
enough to kill the relay on startup — in the exact layout the release ships
in, and only there. Fixed by referencing `Serilog.Sinks.File` 7.0.0 (the
launcher's version, so the merge stays one file) from `KcdMp.Server.csproj`,
which puts it in `KcdMpServer.deps.json` and makes the probe succeed. Commit
`2e7d2e8`.

This is the kind of bug that only exists in the packaged layout, and it would
have shipped in the first "one-click" release. Worth remembering as an
argument for exercising packaging rather than reading it.

---

## Phase 3 — the one permitted launcher change

`Home.razor.cs` now runs `CheckGamePathOnStartup()` after loading settings: if
`GamePath` is empty, missing, or fails the discriminator, it opens the
existing Settings surface with a message saying which. Same two conditions
`LaunchGame` already enforced, just checked at startup instead of at the
moment the user presses Launch.

The installer means the normal path never sees it. It is the net for someone
who unzipped a release by hand or whose game moved between Steam libraries.

No "Detect" button was added. It was offered as optional in the brief, and the
honest reading is that it would mean reimplementing the vdf/manifest parser in
C# — not a small clean addition, so it was left out rather than half-done.

---

## Corrections to the brief, where the code disagreed

**`settings.json` is CWD-relative, not exe-relative.** The brief said settings
"load/save from a `settings.json` next to the launcher exe". In fact
`Home.razor.cs:33` is `private const string SettingsFileName = "settings.json"`,
passed straight to `File.Exists`/`File.ReadAllText`/`File.WriteAllText` — so it
resolves against the process's *working directory*. Only
`DllPath`/`AgentPath`/`RelayPath` are exe-relative, via
`ResolveAgainstLauncher` and `AppDomain.CurrentDomain.BaseDirectory`.

Consequence: every shortcut the installer creates pins `WorkingDir` to
`{app}`, and so does the finish page's "Launch now". `Test-Installer.ps1`
asserts the shortcut's working directory for that reason, not for neatness.
Launched from somewhere else — a console `cd`'d elsewhere, say — the launcher
still reads and writes `settings.json` in *that* directory. Making the path
exe-relative is a one-line launcher change and is the right fix, but it is
outside the two changes Phase 3 permits, so it is flagged here rather than
made.

**`Publish-Release.ps1` had not "never been run" so much as "could not be
run"** — see Phase 2.

---

## Testing

### Executed this session, all green

| Suite | Result |
|---|---|
| `tools\Test-InstallerDetect.ps1` | **21/21** |
| `tools\Test-Installer.ps1` | **39/39** |
| `tools\Test-Combat.ps1` | 14/14 |
| `tools\Test-Sessions.ps1 -IncludeTimeout` | 23/23 |
| `tools\Test-Dice.ps1` | 10/10 |
| `dotnet build KCD2-MP.sln` | 0 errors, 8 warnings, all pre-existing |

Both installer suites were re-run against the final Setup.exe after the
launcher change and the relay fix, not only against the first build.

`Test-InstallerDetect.ps1` compiles `installer\SteamDetect.iss` into a probe
and runs it against synthetic fixtures — multi-library, app-in-root-library,
missing app, malformed vdf, no vdf at all, manifest-without-files,
retail-instead-of-Modding-Tools, a disconnected `Z:\` library, empty Steam
path — plus this machine's real Steam library, plus the token/unescape/install-
root parsing primitives.

`Test-Installer.ps1` runs the real Setup.exe unattended: install → upgrade →
uninstall, asserting deployed files, the self-contained runtime, mod
deployment, the seeded `settings.json` (parsed as JSON, matched against the
registry record, checked to exist), shortcut target and working directory, the
Add/Remove entry and its version, that an upgrade preserves a hand-edited
`settings.json` and unrelated files, and that uninstall removes everything it
owns and nothing it does not.

Two bugs were caught by these tests rather than by review: the uninstaller
deleting the mod out of the game folder unasked (fixed with
`uninsneveruninstall`), and an orphaned empty `HKCU\Software\KCDMP` key left
behind because `uninsdeletekeyifempty` on a later `[Registry]` line ran while
earlier values still existed (fixed by listing an `uninsdeletekey` entry
first, since uninstall replays the section in reverse).

One transient is worth recording: the very first silent install failed in
`PrepareToInstall` because `DelTree` could not remove the existing
`Mods\kdcmp` folder, while PowerShell removed the same folder seconds later
without complaint — a handle that had not closed yet. `RemoveModFolder` now
retries after a pause, falls back to `rd /s /q`, and judges success by whether
the folder is actually gone rather than by a return value. A running game, an
open Explorer window or an antivirus scan will do the same thing on a user's
machine.

### Needs a human at the wizard — not run

`docs\INSTALLER-TESTING.md` tier 2. `/VERYSILENT` skips every wizard page, so
nothing automated here has exercised the gate page, the Steam deep-link, the
Browse... rejection, the WebView2 download, or the replace-a-foreign-`kdcmp`
prompt. The tier-2 checklist includes deliberately renaming
`appmanifest_2429020.acf` to watch the gate refuse Next, then restoring it and
Re-checking.

### Cannot be verified here — checklist only

`docs\INSTALLER-TESTING.md` tier 3, every box unticked. A clean machine with
no WebView2, no Steam, or no Kingdom Come at all is out of reach: this project
has one machine and it is a development machine with all three present. The
WebView2 install path in particular is written from Microsoft's documented
bootstrapper contract and has **never been observed running**.

---

## Known limits

- **Unsigned.** SmartScreen will warn on first download. Worth a line in the
  release notes so a friend is not scared off by it.
- **The WebView2 bootstrapper is downloaded, not embedded.** Keeps Setup small
  and always current; means an offline install on a machine lacking WebView2
  cannot succeed.
- **A moved game is only half-handled.** Re-running Setup detects the new path
  and re-deploys the mod, but will not overwrite a non-empty `GamePath` in an
  existing `settings.json`. The launcher's new first-run check catches the
  stale path and opens Settings; it does not fix it automatically.
- **`/VERYSILENT` implies consent** to replacing an existing `kdcmp`, and
  declines to remove the mod at uninstall time. No UI to ask in, and those are
  the safer defaults in each direction.

## Next session should start from

This file, `docs\INSTALLER-TESTING.md`, and WO-7's still-unexecuted manual
test procedure. The two highest-value unexecuted things are the tier-2
interactive wizard run (one person, this machine, ~15 minutes, and it is the
only way to know the gate behaves as a gate) and WO-7's two-machine test,
which is still what "does this actually work" ultimately means.
