# WO-14 progress — the 0.9.2 release, and who owns version numbers

Session date: 2026-07-31. Branch `main`. A versioning/release WO, not a
feature one: no `.cs`, `.cpp` or `.lua` was touched.

---

## The point of this WO

The user owns version numbers. Two prior sessions incremented `VERSION` on
their own judgement (WO-9 `0.8.0` → `0.9.0`, WO-10 `0.9.0` → `0.9.1`),
neither asked for. `docs/VERSIONING.md` now records the rule durably:

- No session auto-increments `VERSION`.
- Any session about to touch `VERSION` or run `Build-Installer.ps1` /
  `Build-DirectInstall.ps1` **asks the user for the target string and waits**.
- "Bump to X" means X labels the current state of `main` — a session must not
  reinterpret a stated version as a mistake or round it up.

Linked from `docs/PROJECT-STATE.md`'s reading order as item 2, so it is part
of what a new session already reads before it can get this wrong again.

This session's target, `0.9.2`, was stated explicitly by the user and used
verbatim.

## What `0.9.2` is

Everything on `main`: WO-9 (armor/appearance sync), WO-10 (weapon sync + the
injection liveness fix), WO-13 (the ghost-freeze fix and the `[in menu]`
tag). `0.9.2` has never been used before — a clean label, no collision.

## The `0.8.5-Beta` loose end — resolved

`RELEASE-NOTES-0.8.5-Beta.md` sat committed at the repo root, describing the
armor-sync feature correctly under a version string `VERSION` never held
(`0.8.0` → `0.9.0` in `4fd2ff8` covered that same work).

**Resolved by `git mv` to `docs/releases/RELEASE-NOTES-0.9.0.md`** — renamed
to the version it actually shipped under *and* moved out of the repo root.
Both, not one, and deliberately: the rename is what fixes the wrong label,
the move is what stops the root accumulating one loose notes file per
release now that there will be more of them. A dated banner at the top of
the file states the mismatch and the real history rather than pretending the
`0.8.5-Beta` label never existed. Content otherwise unchanged except the
link paths the move broke.

The stale `release\KCDMP-Setup-0.8.5.exe` and `release\KCDMP-Update-0.8.5-Beta.zip`
on disk were left alone — `release\` is untracked build output, not the
repo's to curate.

## Build — 0.9.2 threaded through from `VERSION`, checked not assumed

```
Compiling installer\KCDMP.iss (version 0.9.2) ...
Successful compile (28.875 sec).
Installer: release\KCDMP-Setup-0.9.2.exe (64.9 MB)
```

Three independent confirmations of the version, not one:

| Evidence | Value |
|---|---|
| Filename | `release\KCDMP-Setup-0.9.2.exe` |
| Win32 version resource (`FileVersion`/`ProductVersion`) | `0.9.2` |
| Add/Remove Programs entry, asserted by `Test-Installer.ps1` | `0.9.2` |

`kdcmp.pak` was rebuilt from source as part of the build, and **it came out
different from the one committed on `main`** — 321,185 → 321,339 bytes. That
is not noise, it was checked: `babcbb5` (WO-13) committed a pak built at
21:19 alongside a `kdcmp.lua` last edited at 21:44, so the tracked pak was
stale by that last edit.

Diffed the packed Lua against the repo's Lua rather than assuming: the whole
difference is **one comment block** — WO-13's note about why nameplates stay
hidden during a menu, rewritten to include the measured 35–86 Hz pump rate.
**Zero executable difference.** The rebuilt pak is committed here so the
repo's build artifact matches its own sources again; this is exactly the
drift `Build-Installer.ps1`'s unconditional pak rebuild exists to catch, and
it caught it.

## Test suites

Both run against the freshly built `KCDMP-Setup-0.9.2.exe`:

| Suite | Result |
|---|---|
| `tools\Test-InstallerDetect.ps1` | **21 passed, 0 failed** |
| `tools\Test-Installer.ps1` | **41 passed, 0 failed** |

`Test-Installer.ps1` covers silent install, upgrade-preserves-`settings.json`,
and silent uninstall, and restored the machine's own mod deployment
afterwards (`Cleaned up test mod deployment at D:\SteamLibrary\...\KCD2Mod\Mods\kdcmp`).
Neither suite covers the interactive wizard — unchanged, see
`docs/INSTALLER-TESTING.md`.

No other suites were run. This WO changed no code they exercise; running them
would have been a checkbox, not evidence.

## `tools\Build-DirectInstall.ps1` — new, and a real script

The update-only zip was hand-built once before (the `KCDMP-Update-0.8.5-Beta.zip`
described in the old release notes). It is now a script, so the pattern is
repeatable rather than remembered:

- Reads the version from `VERSION`, **the same way `Build-Installer.ps1`
  does**, so the exe and the zip cannot disagree about which release they are.
- `App\` = the whole `Publish-Release.ps1` output → `%LocalAppData%\KCDMP`.
  That path is `DefaultDirName={localappdata}\KCDMP` in `installer\KCDMP.iss`,
  read there rather than assumed, and the script's comment names that file as
  the source of truth if it ever moves.
- `Mod\` = `mod.manifest` + `Data\kdcmp.pak` and **nothing else** →
  `<Modding Tools>\Mods\kdcmp`. This mirrors the `.iss`'s deliberately
  non-wildcard `[Files]` section: `kdcmp\Data\` also holds the pak's *sources*,
  and deploying those loose takes over the engine's table root and kills the
  game with "114 tables are not loaded". The script carries that reasoning
  inline so nobody "simplifies" it into a wildcard.
- `-SkipPublish` reuses the publish `Build-Installer.ps1` just did, which is
  how it was run here.

Output, and its contents verified by reading the zip back rather than
trusting the script:

```
release\KCDMP-DirectInstall-0.9.2.zip  (86.4 MB, 681 entries)
  Mod/mod.manifest
  Mod/Data/kdcmp.pak
  App/KCDMP_launcher.exe, App/KcdMpClient.exe, App/KcdMpServer.exe,
  App/KCDMP.dll, App/KCDMP_LauncherInjector.exe, + the self-contained runtime
```

`Mod/` holds exactly two files, confirmed. `App/` contains no `settings.json`
(confirmed by search, zero matches), so unzipping over an existing install
cannot clobber the user's game path — stated in the README as a promise, so
it was checked.

**It is much bigger than the hand-built one it replaces**: 86.4 MB against
`KCDMP-Update-0.8.5-Beta.zip`'s 0.3 MB, still sitting in `release\`. That old
zip carried only the handful of files that had actually changed; this one
carries the entire published `App\`, self-contained .NET runtime included,
because that is what the WO specified and what makes "copy the folder over
yours" correct regardless of which older version the player is coming from.
A changed-files-only variant would be smaller and more fragile — it would
need to know the previous version. Noted as a deliberate trade, not an
oversight, in case a future session wonders why the zip grew 280-fold.

## README

Extended, not restructured.

- Intro and status table now say armor **and weapons**.
- **Native plugin + injection** moved out of "Built but unverified" — the
  liveness race is fixed and verified by a real cold-start injection
  (`docs/WO-10-injection-fix.md`). The residual gap after it (the soul walk's
  own unretried 5s timeout) is stated in "Not done" rather than lost with the
  row it used to sit in.
- **Ghost presence** row now records that ghosts keep moving during your menu
  (6–7 m measured) and that a peer in a menu is tagged `[in menu]`.
- "Weapon sync is not implemented" in "Not done" is gone — it was true when
  written and is now false.
- Added to "Not done": the unequip-verification asymmetry (WO-10's
  reappearing-weapon anomaly), the soul-walk residual gap, and nameplates
  staying hidden during your *own* menu.
- Added to "Still needs a human": mounted ghosts during a menu, weapon
  pairings beyond those already watched, the `[in menu]` tag seen from a
  second real machine, and the launcher-driven cold-start injection. The
  CONNECT-too-early bullet now notes the launcher's 8s wait and the plugin's
  5-minute poll deliberately disagree.
- New "Already installed? Update in 2 steps" section with the
  `KCDMP-DirectInstall-0.9.2.zip` name and both target paths, and the build
  section now shows both build commands and links `docs/VERSIONING.md`.

**The retired broadcast slowdown appears nowhere in the README**, deliberately.
It was built, then removed on purpose (WO-13 §0.2), and never was user-facing
behaviour. Advertising it would document a feature that does not exist.

## Not done here, on purpose

- Nothing was uploaded, published or shared. Both artifacts sit in `release\`;
  distributing them is the user's call.
- No code changes. The open items above (the reappearing weapon, the soul-walk
  retry, `Test-Dice.ps1`'s seeded-reproducibility flake) are recorded, not
  fixed — this WO's own rule.

## Files touched

```
VERSION                                   0.9.1 -> 0.9.2 (user-stated)
RELEASE-NOTES-0.8.5-Beta.md               -> docs/releases/RELEASE-NOTES-0.9.0.md (git mv + banner)
README.md                                 status, not-done, needs-a-human, update+build sections
docs/VERSIONING.md                        new
docs/PROJECT-STATE.md                     reading order: VERSIONING.md as item 2
docs/WO-14-progress.md                    new (this file)
tools/Build-DirectInstall.ps1             new
kdcmp/Data/kdcmp.pak                      rebuilt by the build; comment-only drift vs main, see above
```

## Flagged, not touched: an unexplained file at the repo root

`RELEASE-NOTES-0.9.0-Beta.md` appeared at the repo root **during this
session** (created 22:14, untracked, not present in the file listing taken at
the start of it) and was not written by anything this session ran. It is a
draft release-notes for WO-13's menu fix, under yet another version label
(`0.9.0-Beta`) that `VERSION` has never held, and it opens with a note telling
the reader to *"rename this file and the heading to whatever you tag."*

**Left exactly where it is: not committed, not renamed, not deleted, and its
instruction not acted on.** It is content of unknown authorship, it names a
version the user did not state, and this WO's whole point is that version
labels are the user's call. Reported rather than absorbed. If it is a draft
the user wants to keep, it belongs in `docs/releases/` under `0.9.2` like the
one this session already relocated.
