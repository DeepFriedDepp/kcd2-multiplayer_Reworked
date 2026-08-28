# WO-74 findings — why Setup could half-apply, and what the reproduction actually showed

Written 2026-08-28. Every claim below is marked **(observed)**, **(code-verified)**
or **(inferred)**. Reproductions were run against `KCDMP-Setup-0.18.8.exe` and
`KCDMP-Setup-0.18.2.exe`, unattended, into throwaway directories, with Steam
detection pointed at a fixture tree (`/STEAMROOT`) so the real game folder was
never touched.

---

## The headline, and a correction to the premise

The work order arrived with the premise *"the WO-69/70 session found the Setup
half-applies on upgrade"*. Two halves of that turned out to be true in
different ways, and one part of the evidence behind it does not survive
inspection.

**Setup 0.18.8 CAN leave an install half-applied, and it exits looking like a
user cancel when it does.** Reproduced deterministically — see *Root cause 1*.
That is real, it is the release blocker, and it is fixed.

**But the specific field evidence WO-69 recorded for it — a
`Microsoft.Extensions.Configuration.*` family at 8.0.x under a
DependencyInjection/Hosting set at 10.0.25 in `%LocalAppData%\KCDMP` — cannot
have come from any shipped installer**, and the reading of that directory was
not trustworthy in the first place:

- (observed) **Every DirectInstall zip this project has ever built ships
  `Microsoft.Extensions.Configuration.Abstractions.dll` at 27,952 bytes**,
  which is 10.0.25. All fourteen of them, 0.9.2 through 0.18.8. No release
  payload has ever carried the 8.0.23 build (27,936 bytes) that was found on
  the machine.
- (observed) **The file lists are stable across releases.** 0.17.5, 0.18.2 and
  0.18.8 have byte-identical *sets* of filenames; the only apparent drop
  anywhere in the archive (0.10.0 → 0.11.5, "21 files") is directory entries
  differing in zip layout, not files. So "an older release shipped a file the
  newer one dropped, and the stale copy stayed behind" is ruled out for every
  shipped pair.
- (observed) **This shell cannot read that directory truthfully.**
  `%LocalAppData%\Packages\Claude_*\LocalCache\Local\KCDMP` holds a complete
  1,021-file shadow copy dated 2026-08-15, and it merges into every read of
  `%LocalAppData%\KCDMP` from a tool process here. Reading the install
  directory from this session returns a mixture of that shadow and the real
  tree — a launcher exe of the wrong size, assemblies stamped 0.11.6, and a
  fresh `install-manifest.txt` from a later date, all at once. WO-69's
  hybrid-directory description was produced from this same shell.

So: the *symptom* WO-69 recorded (the relay could not cold-start; the launcher
said "The relay process exited immediately") was real and user-observed. The
*file-level diagnosis* of it was made through a sandbox that is known to lie
about that path, and should not be carried forward as established. What is
established is the mechanism below, which was reproduced from scratch.

---

## Root cause 1 — one unreplaceable file aborts everything, after the mod is already gone

**(observed, reproduced deterministically)**

Recipe: install 0.18.8 clean, mark a single file in the install directory
read-only (`appsettings.json` — third alphabetically), run Setup 0.18.8 over
it unattended.

What Setup's own log records:

```
Dest filename: ...\appsettings.json
Defaulting to Abort for suppressed message box (Abort/Retry/Ignore):
The existing file could not be replaced because it is marked read-only.
User canceled the installation process.
Rolling back changes.
```

Consequences, all four observed in that one run:

1. **Setup exits 5.** That is Inno's "user cancelled during installation" —
   indistinguishable from someone pressing Cancel. Nothing in the exit code
   says a file could not be written.
2. **The game's mod folder is left EMPTY.** `PrepareToInstall` deletes
   `<ModdingTools>\Mods\kdcmp` wholesale *before* the file copy runs, and the
   abort happens after that and before the two mod files are redeployed.
   Inno's rollback undoes what this run wrote; it does not restore a folder
   the script deleted. A player is left with no mod at all.
3. **Every file after the failing one keeps its old build.** In the reproduced
   run: `KcdMpServer.dll` 68,096 bytes (0.18.2) where 0.18.8 ships 72,192;
   `KcdMpClient.dll` 272,896 vs 274,944; `KcdMp.Protocol.dll` 27,136 vs
   27,648; a truncated `KCDMP.dll`; a missing `KcdMp.Farkle.dll`. That IS the
   half-apply, and the alphabetical cut point is arbitrary.
4. **`install-verify.txt` still reads `PASS` from the previous run.** The file
   every tool consults to judge the install was, at that moment, actively
   lying about a directory that had just been half-replaced and a game folder
   that had just been emptied.

Interactively the same condition raises an Abort/**Retry**/**Ignore** dialog.
**Ignore** continues the install, skips that file, and reaches the green
Finish page — the silent half-apply with a success screen. `/SUPPRESSMSGBOXES`
picks Abort, which is why the unattended reproduction ends at exit 5 instead.

A read-only attribute is not exotic (backup restores, copies off read-only
media, some antivirus quarantine-restores). But the attribute is only the
cheapest way to *provoke* the class: **any** file Setup cannot replace lands
in the same code path.

## Root cause 2 — the install directory was an OPEN set, and the check was a whitelist

**(observed)**

`install-manifest.txt` listed what *should* be present. `VerifyInstalledFiles`
checked only that those files existed at the right size. Nothing looked at
what *else* was in the directory, and `[Files]` only ever copies — it never
removes.

Reproduced: plant `KcdMpMasterServer.dll`, `KcdMpMasterServer.deps.json` (the
shape a hand `dotnet publish` of another project into the install directory
leaves — the exact hazard `Publish-Release.ps1`'s own header documents from
WO-35) and a `LegacyRelay.dll` into a clean 0.18.8 install, then upgrade.
Result: **all three survive the upgrade untouched, and `install-verify.txt`
says `PASS`.** They are invisible to the check by construction.

This matters because .NET resolves assemblies by filename out of that
directory. One foreign assembly there is enough to stop the relay
cold-starting — which is (inferred) the most plausible mechanism behind the
symptom WO-69 actually saw, even though the file-level reading of it was
unreliable.

## Root cause 3 — the mod half was verified by nothing at all

**(observed)** The manifest covered the install directory only. `mod.manifest`
and `Data\kdcmp.pak` land in the game folder, outside it, and had no entries.
In the root-cause-1 reproduction the mod folder was *empty* and Setup's
verdict file still read `PASS`.

## Root cause 4 — a failed verification could not change the exit code

**(code-verified)** `VerifyInstalledFiles` wrote `install-verify.txt` and, when
not silent, showed a message box. Then `CurStepChanged` returned and Setup
finished normally: **exit 0, green Finish page**. Under `/VERYSILENT` there was
no message box at all, so a detected failure produced nothing but a text file
nobody was required to read. Automation asserting "exit code 0" — which
`tools\Test-Installer.ps1` did — passed over it.

## Root cause 5 — the verdict file could outlive the run that wrote it

**(observed, part of root cause 1)** It was only written at `ssPostInstall`. Any
abort before that left the previous run's verdict in place as the record of
what happened.

## Root cause 6 — the master server was in none of the process lists

**(code-verified)** `FirstInstallBlocker`, `KillOursQuietly` and
`AnyOfOursRunning` named the launcher, agent, relay and game.
`KcdMpMasterServer.exe` — which the launcher starts itself (WO-35), and which
runs out of the install directory's `MasterServer\` subfolder — was in none of
them. **(observed)** In practice Inno's `CloseApplications` / Restart Manager
does close it (`RestartManager found an application using one of our files:
KcdMpMasterServer`, and the upgrade then completed green), so this never
caused a failure on its own. RM is a courtesy, not a guarantee — it cannot
reach a process in another session, and a process may ignore the request.

## Root cause 7 — sizes, not hashes

**(code-verified)** The manifest carried `<path>|<size>`. A stale file that
happens to match on length passed. WO-32's note that "every stale-vs-built pair
observed differed in size" was an observation about a sample, not a property.

---

## What was ruled OUT, with evidence

- **(observed) A plain upgrade is byte-perfect.** 0.18.2 installed clean, then
  0.18.8 over it, then compared file-by-file (path + size + sha256) against a
  clean 0.18.8 install: **identical except `unins000.dat`**, which legitimately
  grows with a second install logged into it. The ordinary path was never
  broken.
- **(observed) A locked file does not defeat it either.** With an external
  process holding `KcdMpClient.dll`, `KcdMpServer.dll` and `KCDMP.dll` open
  `FileShare.None` (verified by a rename that failed from outside), the 0.18.8
  upgrade still landed all three: `RestartManager found an application using
  one of our files: Windows PowerShell` → `Attempting to restart
  applications` → every hash correct afterwards. WO-32's process gate plus
  `CloseApplications` genuinely work.
- **(observed) A deny ACL is NOT an unreplaceable file.** Denying
  `W,D,WDAC,WO` to the current user on `KcdMpServer.dll` still let Setup
  replace it — deleting a file needs only `FILE_DELETE_CHILD` on the parent
  directory. The install came out green and correct. Use a *directory* placed
  where the file has to go if you want a deterministic blocker; that one
  cannot be talked past.
- **(observed) No release ever dropped a file.** See the headline section.

---

## Two more defects found while building the fix

**(observed) `kdcmp.pak` is not byte-deterministic.** Two rebuilds from
identical sources gave 539,481 bytes both times and sha256 `A4343EF0…` then
`9C180836…`. This is why the manifest must be generated *after* the last pak
rebuild and from the bytes actually being shipped: `Build-DirectInstall.ps1`
was rebuilding the pak under `-SkipPublish`, after `Build-Installer.ps1` had
already stamped a manifest, which would have made a freshly built zip fail its
own verification. Both scripts now generate through
`tools\New-InstallManifest.ps1`, and `-SkipPublish` no longer rebuilds the pak.

**(observed, pre-existing, not a relay bug) `Test-Dice.ps1` could only ever
pass against a Debug relay.** `SessionManager.CreateDiceGame` reads the invite's
seed override inside `#if DEBUG` and hands a Release build `CryptoDiceRng`
instead (code-verified, `SessionManager.cs:343-347`). Three of its assertions
therefore depend on a seed that no shipped relay honours:

| | Debug relay, source build | Installed Release relay |
|---|---|---|
| seeded match, run A / run B | 1200/300 and 1200/300, **5 runs out of 5** | different every time; 0.18.8 and 0.19.0 behave identically |

This is the first time the suites have been run against an *installed* relay —
WO-32's stale-relay trap always pushed sessions toward a source build — so it
had never surfaced. It is **not** a regression and **not** a relay defect;
WO-74 changed no relay code. Fixed in the suite: `-ReleaseRelay` skips the
three seed-dependent assertions with a printed reason, and section 3 now takes
the current player from the state each roll instead of assuming the seed put a
particular player on turn (a bust hands the turn over, which against a CSPRNG
happens at random and produced a spurious `NotYourTurn`).

---

## Not established

- **(inferred, not proven)** That a foreign assembly in the install directory
  is what actually broke the relay on the user's machine in WO-69. The
  mechanism is sound and the class is real, but the only file-level evidence
  came through the sandbox shadow described above.
- **(not run)** Whether any tester in the field is currently on a half-applied
  install. Nothing here can see that; the 0.19.0 installer repairs it either
  way, and reports what it repaired.
- **(not run)** The interactive **Ignore** path, end to end, in front of a
  human. It is reasoned from Inno's dialog and the suppressed-box log line,
  and `overwritereadonly` removes the commonest way to reach it, but nobody
  has clicked Ignore and watched what 0.19.0 does. The verification would now
  catch it — that is code-verified, not observed.
- **(not run)** `Test-Pipe`. It needs the native DLL injected into a live game;
  no game ran this session.
