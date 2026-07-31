# Testing `KCDMP-Setup-<version>.exe`

Three tiers, and they are not interchangeable. Tier 1 runs on any dev machine
and is green. Tier 2 needs a human sitting in front of the wizard. Tier 3
needs a machine that is *not* a dev machine, and nothing in tier 3 has been
executed — every box in it is unticked and stays unticked until someone runs
it and edits this file.

Written 2026-07-30 (WO-8), against Setup 0.8.0 built on Windows 11 Pro
22631 with Inno Setup 6.7.3.

---

## Tier 1 — automated, executed

Both suites were run this session and passed. Re-run them after any change to
`installer\*.iss`, `tools\Publish-Release.ps1` or `tools\Build-Installer.ps1`.

```bash
powershell -ExecutionPolicy Bypass -File tools\Test-InstallerDetect.ps1
```

21/21 — Steam/Modding-Tools detection. Compiles `installer\SteamDetect.iss`
(the file the installer itself includes, not a copy) into a probe and runs it
against synthetic fixtures plus this machine's real Steam library:

| Case | Asserted |
|---|---|
| multi-library | both library roots enumerated, app found in the second |
| app-in-root-library | app found in the Steam root library |
| missing-app | both libraries enumerated, nothing found |
| malformed vdf | degrades to the Steam root, still finds a root-library app |
| no vdf at all | still finds a root-library app |
| manifest-but-no-files | rejected (manifest names an app whose files are gone) |
| retail-not-modding-tools | rejected by the `Framework.dll` + `CrySystem.dll` discriminator |
| offline library (`Z:\...`) | skipped, no crash |
| empty Steam path | finds nothing, no crash |
| this machine | Steam located from the registry, real Modding Tools found, discriminator passes |
| parser | quoted key/value tokens, `\\` unescaping, quote-less line yields empty, install root derived from the exe path |

```bash
powershell -ExecutionPolicy Bypass -File tools\Test-Installer.ps1
```

39/39 — full lifecycle against the real Setup.exe. Silent install into a temp
directory, then an upgrade over it, then a silent uninstall. Asserts the
deployed executables and the self-contained runtime, the mod's arrival at
`<ModdingTools>\Mods\kdcmp`, `settings.json` seeded with the detected game
path (parsed as JSON, compared against the registry's record, checked to
exist on disk), the shortcut's target *and* working directory, the Add/Remove
Programs entry and its version, that an upgrade preserves a hand-edited
`settings.json` and unrelated files in the install directory, and that
uninstall removes the install directory, both shortcuts, `HKCU\Software\KCDMP`
and the Add/Remove entry while leaving the mod alone.

It does deploy the mod into the real game folder and removes it again
afterwards. It refuses to run if a KCDMP install is already registered.

**What tier 1 cannot see:** `/VERYSILENT` skips every wizard page. The
Modding-Tools gate page, the Steam deep-link button, Browse..., the WebView2
download, and the replace-a-foreign-`kdcmp` prompt are all unexercised by it.

## Tier 2 — interactive, one human, this machine

Run `release\KCDMP-Setup-<version>.exe` by double-clicking it.

- [ ] Welcome page appears; GPLv3 licence page shows the real licence text.
- [ ] The Modding Tools page shows **Modding Tools found** and the correct
      `KingdomCome.exe` path, plus the `...\Mods\kdcmp` target.
- [ ] **Browse...** → pick the *retail* `KingdomCome.exe` (app 1771300,
      `KingdomComeDeliverance2`) → rejected with the "that is the retail
      game" message, and the previously detected path is kept.
- [ ] Install location page defaults to `%LocalAppData%\KCDMP`. No UAC prompt
      appears at any point.
- [ ] Desktop-icon task is checked by default.
- [ ] Install completes; finish page mentions Host and `docs/NETWORKING.md`.
- [ ] **Launch now** starts the launcher, and it opens with the game already
      configured — Settings shows the right path and no first-run warning.

**The gate, deliberately provoked** (this is the point of the exercise).

> **Do not fake "not installed" by renaming the real
> `appmanifest_2429020.acf`.** It looks reversible and is not. Steam reads
> the absence of that file as "the app is not installed", drops the app's
> entitlement, and the game then refuses to start with **"no license
> found"** — the only way back is a full redownload. This was done once, on
> 2026-07-30, and cost 8.8 GB. Setup takes a `/STEAMROOT` override precisely
> so nobody has to do it again.
>
> The trigger is Steam *noticing*. Clicking **Get it on Steam** while the
> manifest is missing is what does it. Do not rely on "I'll close Steam
> first" — the deep-link starts it.

Point Setup at a fixture tree instead. `tools\Test-InstallerDetect.ps1`
builds one at `%TEMP%\kcdmp-detect-fixtures`; run it once first, then:

```bash
"release\KCDMP-Setup-0.8.0.exe" /STEAMROOT="%TEMP%\kcdmp-detect-fixtures\missing\Steam"
```

- [ ] The Modding Tools page says they are not installed and explains what
      they are.
- [ ] **Next is refused** — clicking it produces the explanation message and
      does not advance.
- [ ] **Get it on Steam** opens Steam on the Modding Tools entry
      (`steam://install/2429020`). Safe here: real Steam still has its
      manifest, so it just shows you the app. Close Steam's window.
- [ ] **Re-check** → "still nothing".
- [ ] Now make the fixture succeed without restarting the wizard: copy
      `%TEMP%\kcdmp-detect-fixtures\rootlib\Steam\steamapps` over
      `%TEMP%\kcdmp-detect-fixtures\missing\Steam\steamapps`, then click
      **Re-check** → the page flips to found and Next advances.
- [ ] Cancel out at that point rather than installing — the fixture's
      "game" is a folder of empty files, so letting it deploy the mod there
      proves nothing and seeds a junk directory.

- [ ] Separately, `/STEAMROOT="C:\definitely\not\here"` → the *Steam not
      found* page, not the *Modding Tools missing* page.

**Replacing a foreign mod folder:**

- [ ] With no KCDMP install registered (`HKCU\Software\KCDMP` absent), create
      `<ModdingTools>\Mods\kdcmp\marker.txt` by hand and run Setup.
- [ ] Setup asks before replacing it, and cancelling leaves the folder intact.

**Uninstall:**

- [ ] Uninstall from Add/Remove Programs asks whether to remove the mod from
      the game folder; answering No leaves it, answering Yes removes it.
- [ ] Either way the game itself is untouched.
- [ ] **With the launcher deliberately left running**, start the uninstaller:
      it must refuse with "KCD2 Multiplayer is still running" and a
      Retry/Cancel choice, and Cancel must leave the install completely
      intact — not half-removed. Close the launcher, click Retry, and confirm
      it then completes cleanly with no leftover files in
      `%LocalAppData%\KCDMP`.

      *Why this is on the list:* it was observed failing. Uninstalling with
      the launcher open removed the registry entries and the uninstaller
      itself but left ~120 of ~680 files behind, because Inno's built-in
      CloseApplications uses the Restart Manager over `[Files]` entries and
      does not cover the `[UninstallDelete]` sweep of `{app}`.

## Tier 3 — clean machine — NOT EXECUTED

None of this has been run. This project has one machine, and it is a
development machine with Steam, the Modding Tools, the .NET SDK and the
WebView2 runtime all already present — which is precisely the machine that
cannot test any of the following. Do not treat anything here as verified.

**A fresh Windows install with no WebView2 runtime** (Windows Server images
and some LTSC/enterprise Windows 10 builds ship without it; confirm absence
via `HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}`):

- [ ] Setup detects it as missing.
- [ ] The Evergreen bootstrapper downloads, with visible progress, and
      installs silently and per-user (no UAC prompt).
- [ ] The launcher's window actually renders afterwards.
- [ ] With networking disabled, the download fails with the explanatory
      message rather than hanging, and Setup does not proceed.

**A machine with no Steam at all:**

- [ ] The Modding Tools page says Steam was not found, rather than crashing
      or claiming the Modding Tools are missing.
- [ ] Browse... still works if the game was copied there by hand.

**A machine with Steam but no Kingdom Come at all:**

- [ ] The gate holds; `steam://install/2429020` opens the store page for a
      user who does not own the Modding Tools yet.

**Steam in a non-default location:**

- [ ] Steam installed somewhere other than `C:\Program Files (x86)\Steam` is
      found via `HKCU\Software\Valve\Steam\SteamPath`.
- [ ] A library on a second drive, and a library on a drive that is
      disconnected at install time, both behave (fixtures cover the parsing;
      real Steam has not been tested in this shape).

**Non-elevated write access:**

- [ ] A Steam library whose ACL does *not* grant `BUILTIN\Users` write access
      (unusual — Steam's own installer grants it — but possible after a
      manual move) produces a clear failure rather than a half-deployed mod.

**Other:**

- [ ] A non-ASCII Windows username (`C:\Users\Jörg\...`): the seeded
      `settings.json` is written UTF-8 without BOM and the launcher reads the
      path back correctly.
- [ ] SmartScreen: the installer is unsigned, so a first-time download will
      show "Windows protected your PC". Note what a friend has to click.
- [ ] Install, then move the Steam library, then re-run Setup: the new path
      is detected and `settings.json`'s stale `GamePath` is *not* corrected
      (a known limit — seeding only fills an empty `GamePath`; the launcher's
      first-run check catches it and opens Settings instead).

## Known limits, by design

- **Unsigned.** No code-signing certificate, so SmartScreen will warn.
- **Needs internet only when WebView2 is missing.** The bootstrapper is
  downloaded rather than embedded, which keeps Setup small and always
  current, but means a fully offline install on a machine without WebView2
  cannot succeed.
- **`/VERYSILENT` implies consent** to replacing an existing `kdcmp` folder
  and answers "no" to removing the mod at uninstall time. There is no UI to
  ask in, and those are the safer defaults in each direction.
- **Steam owns the download.** Setup can deep-link and refuse to continue; it
  cannot make Steam install anything.
