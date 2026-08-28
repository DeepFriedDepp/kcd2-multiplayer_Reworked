# WO-74 progress — installer half-apply fixed, 0.19.0 built

2026-08-28. Read `docs\WO-74-findings.md` first: it carries the reproduction
and the evidence, including a correction to the premise this work order was
written on.

Scope held: **installer, launcher-install plumbing, tooling and `VERSION`
only.** No engine, protocol, relay or game code was changed. The one relay-side
thing this session touched is a *test suite* (`Test-Dice.ps1`), for a
Debug-vs-Release mismatch it had always had.

---

## What shipped

### `installer\KCDMP.iss`

| Change | Closes |
|---|---|
| `overwritereadonly` on all three `Source:` entries | root cause 1 — the read-only abort |
| Own upgrades **prune** the mod folder instead of deleting it (`PruneModFolder` / `PruneDirTo`); a *foreign* `kdcmp` still gets the full removal after the explicit ask | root cause 1 — an aborted install no longer leaves the game with no mod, only the previous version's |
| Manifest v2 reader (`LoadManifest`, `PipeField`) — `APP\|rel\|size\|sha256` and `MOD\|…` | root causes 3 and 7 |
| **Repair sweep** (`SweepDir`, `IsSweepCandidate`): deletes any `.dll`/`.exe`/`.pdb`/`.deps.json`/`.runtimeconfig.json` in the install directory that is not in the manifest, and names each one in the verdict | root cause 2 |
| `VerifyEntry` — existence, size and sha256, both halves, mod folder included | root causes 3 and 7 |
| `StampVerifyInProgress` at `ssInstall`: `install-verify.txt` is written **FAIL … has not finished** before the first file is copied | root cause 5 |
| `DeinitializeSetup` → `ExitProcess(101)` when verification failed | root cause 4 |
| Interactive failure box rewritten: **"THIS INSTALL IS NOT COMPLETE"**, up to eight named components | root cause 4 |
| `KcdMpMasterServer.exe` added to `FirstInstallBlocker`, `KillOursQuietly`, `AnyOfOursRunning` | root cause 6 |

Repair runs **before** judging, deliberately: a stale assembly the sweep
removes is a fixed install, not a failure.

Only `.dll`/`.exe`/`.pdb`/`.deps.json`/`.runtimeconfig.json` are ever swept —
the extensions that can change what the .NET runtime loads. `settings.json`,
`favorites.json`, `custom_servers.json`, logs, and anything a user put there
are never touched. `unins*` is exempt. An installer that eats user files while
tidying up would be a worse bug than the one being fixed.

### Tooling

- **`tools\New-InstallManifest.ps1`** (new) — one generator, called by both
  build scripts, so the format cannot drift. Generates from the bytes actually
  about to ship; `kdcmp.pak` is not byte-deterministic, so order matters.
- **`tools\Build-Installer.ps1`** — calls it instead of writing the manifest inline.
- **`tools\Build-DirectInstall.ps1`** — regenerates the manifest from what it
  *stages*; `-SkipPublish` no longer rebuilds the pak (which would have given
  the zip a different pak from the Setup.exe built moments earlier under the
  same version); stages `Apply.ps1` and a `README.txt`.
- **`tools\Apply-DirectInstall.ps1`** (new, ships in the zip as `Apply.ps1`) —
  the update-only route had no process gate and no verification at all, which
  made "unpack it over the top" the remaining way to reach the state this work
  order exists to fix. It now gates on running processes, copies, sweeps
  (files *and* the emptied stray directories — an emptied `Data\Libs\Tables`
  is no safer than a full one), verifies by sha256, and exits non-zero.
- **`tools\Test-InstallerUpgrade.ps1`** (new) — the six-cell matrix below.
- **`tools\Test-Installer.ps1`** — asserts the installer's own verdict, not just
  the exit code; new `-SteamRoot` runs the whole lifecycle against a fixture so
  the real game folder is never touched.
- **`tools\Verify-Install.ps1`** — reads the verdict file, independently
  re-checks every manifest entry by sha256, and hunts strays; a missing
  `release\KCDMP` is now a labelled skip rather than a failure, so the script
  is usable on a machine that has no build tree.
- **`tools\Test-Dice.ps1`** — `-ReleaseRelay`, and section 3 no longer assumes
  the seed decided who is on turn. See the findings doc.

### `VERSION` → `0.19.0`

**User-chosen this session**, per `docs\VERSIONING.md`. Recorded here because
that document requires it.

---

## Test matrix — every cell observed

`tools\Test-InstallerUpgrade.ps1`, **33/33**. Each cell is an independent
install into a throwaway directory; Steam detection is pointed at a fixture
tree built by the script, so nothing outside it is touched. Each cell asserts
exit code, the installer's own verdict, a path+size+sha256 comparison of the
whole install directory against a clean install of the same version, and that
the mod folder is exactly the two files a clean install deploys.

| Cell | Starting state, and how it was stood up | Result |
|---|---|---|
| 1 | virgin — no install, no `HKCU\Software\KCDMP` | green, `repaired 0 stale` |
| 2 | clean previous release (`KCDMP-Setup-0.18.8.exe`) → upgrade | green |
| 3 | 0.19.0 re-run over itself (idempotence) | green, `repaired 0 stale`, nothing spurious |
| 4 | **half-applied** — three DLLs rolled back to 0.18.8 bytes from that release's zip, two foreign `KcdMpMasterServer.*` at the root, a `LegacyRelay.dll`, one component deleted, one truncated, one read-only, plus a user file as a sentinel | green; named `LegacyRelay.dll` and `KcdMpMasterServer.dll` as removed; sentinel untouched |
| 5 | damaged mod folder — pak rolled back, loose `Data\Libs\Tables\stray.xml` planted, `mod.manifest` read-only | green; the stray tree is gone |
| 6 | **negative control** — a *directory* placed where `KcdMpServer.dll` must go | exit ≠ 0, verdict `FAIL`, never green |

Cell 4 is the cell this work order exists for. Cell 6 is the one that proves
the bug *class* is closed rather than this instance of it.

Separately, the verify-fails-anyway path (exit 101) was exercised end to end
with a purpose-built probe installer carrying a manifest that names a file it
does not ship: **exit 101**, `install-verify.txt` reading
`FAIL 1 component(s) did not install correctly: never-shipped.dll (missing)`,
under `/VERYSILENT /SUPPRESSMSGBOXES` with no dialog to answer.

### The other installer suites

- `tools\Test-Installer.ps1 -SteamRoot <fixture>` — **43/43**.
- `tools\Test-InstallerDetect.ps1` — **21/21**.
- `Apply.ps1` from inside the built zip, fresh then over a damaged install —
  **7/7**, `repaired 5 stale file(s)`, user `settings.json` preserved.

---

## Suites

**From source (Debug relay), 120 passed / 0 failed:** `Test-Sessions` 22/0,
`Test-Combat` 14/0, `Test-Dice` 15/0 (three consecutive runs, identical seeded
scores each time), `Test-NpcClaimValidation` 23/0, `Test-TimeSkipRelay` 35/0,
`Test-ItemSyncRelay` 11/0.

**Against the relay the INSTALLED 0.19.0 shipped** — the WO-32 stale-relay trap
in reverse; the installed binary is the one under test:
`Test-Sessions` 22/0, `Test-Combat` 14/0, `Test-Dice -ReleaseRelay` 12/0 with
three documented skips. `Test-NpcClaimValidation`, `Test-TimeSkipRelay` and
`Test-ItemSyncRelay` start their own relay from a hard-coded
`bin\Debug\net8.0` path, so they cannot be pointed at an installed relay
without changing them; they were run from source only.

**Post-install smoke on the final artifact**: install → verdict `PASS 1024
component(s) verified by sha256` → `Verify-Install.ps1` exit 0, `1024
components verified, no strays` → launcher starts and stays up (and starts
`KcdMpMasterServer` itself, as WO-35 says it does) → the installed relay
cold-starts and binds 7778 → the three suites above.

**`Test-Pipe` not run**: it needs the native DLL injected into a live game, and
no game ran this session.

---

## Artifacts

- `release\KCDMP-Setup-0.19.0.exe` — 95.7 MB, built from clean `main` with the fix in.
- `release\KCDMP-DirectInstall-0.19.0.zip` — 130 MB, now carrying `Apply.ps1` and `README.txt`.

Both carry the same 1,022 install-directory components and the same two mod
files, verified to the same sha256 manifest.

Older releases were moved into `release\Old-Installers\` during this session
(not by this work order). `Test-InstallerUpgrade.ps1` searches `release\`
recursively for that reason.

---

## Release notes snippet for testers

> **0.19.0 — the installer fixes itself.**
> If you are on 0.18.8, this is an installer release: Setup could stop part way
> through an upgrade — one file it could not overwrite was enough — and when it
> did, it left some components on the old build, emptied the mod folder in your
> game, and reported nothing worse than a cancel. 0.19.0 cannot end that way.
> It repairs an install that is already in that state (including removing files
> from older layouts that no release ships and that can stop the relay
> starting), checks every single file by SHA-256 before it says it is done, and
> fails loudly with a named list if anything is wrong instead of finishing
> green. The update-only zip now ships an `Apply.ps1` that does the same
> checks. Everything else in 0.19.0 — ghost gender, ghost crime isolation, ghost
> yaw smoothing, the relay's claim-update hardening — already reached you in
> 0.18.8; it is listed here for anyone upgrading from before that.
> **If you might be on a broken 0.18.8: just run the 0.19.0 installer. It
> repairs.**

---

## For the next session, cold

1. **The field session that five open questions depend on is now unblocked.**
   Nothing about the game changed in 0.19.0 — the shipping code is 0.18.8's
   plus the installer — so the WO-70 work list in
   `docs\WO-69-findings.md` § *For WO-70* is still the next thing, unchanged.
2. **Before trusting any report from a tester, get `install-verify.txt`.** It
   is in the install folder, it names the version, and it says what was
   repaired. A machine that cannot produce a `PASS` line is not evidence about
   anything else.
3. **Never judge `%LocalAppData%\KCDMP` from a coding session's shell.** There
   is a full shadow copy of it inside this sandbox and reads merge the two.
   The findings doc has the proof. Ask the user for
   `tools\Verify-Install.ps1` output instead — it is designed for exactly that
   and now works without a build tree present.
4. **`kdcmp.pak` is not byte-deterministic.** Any future step that stamps a
   hash of it must run after the last rebuild, from the bytes being shipped.
5. **Two interactive checks are still unticked** and want a human in front of
   the wizard: the Abort/Retry/**Ignore** dialog (does 0.19.0's verification
   catch an Ignored file? — reasoned, not observed), and the
   replace-a-foreign-`kdcmp` prompt. `docs\INSTALLER-TESTING.md` tier 2.
