# WO-89 — build a release from WO-88

Release-cut session, 2026-09-12. Mechanical: build and package WO-88's four
changes, none of it built or installed before this session. No feature,
protocol, or gameplay code changed here. Every claim below is tagged
**(observed)** — read directly from a command's own output this session —
or **(code-verified)** — confirmed by reading the source.

---

## 0. Phase 0 — ground truth

- `git pull`: already up to date. `main` at `570bbbf` (WO-88's head)
  **(observed)**.
- `git log --oneline` since WO-85 (`12f924a`, version `0.21.1`) shows exactly
  one thing landed: `570bbbf WO-88: post-reload reconciliation fixes,
  dialogue premise refuted on evidence` **(observed)**.
- `git log --oneline --all -- native/KCDMP` and `-- dotnet/KcdMp.Protocol`,
  both ranged `12f924a..HEAD`: **empty**. No native or protocol commit exists
  after WO-85's build **(observed)**. This confirms WO-88's own claim ("not
  changed, on purpose: Protocol.cs, the relay, the native DLL") rather than
  assuming it.
- No `KingdomCome*`/`KcdMp*` process running at session start **(observed,
  `Get-Process`)**.

## 1. Version

`0.21.5`, stated explicitly by the user in the session-start message (not
derived, not asked for separately — the brief's own "never guess" rule is
satisfied by an explicit prior instruction). `0.21.2`–`0.21.4` skipped,
consistent with this project's history of the user skipping numbers
(`0.20.7`, `0.21.0` before it).

## 2. Native DLL — confirmed unneeded, not assumed

Before any build step, hashed the two copies already on disk from WO-85's
session:

```
native\build\KCDMP\KCDMP.dll   sha256 be76ba6a578a356357485b542dffa5175c4a86d452ce4c376b615c5a872c8984  (327,680 bytes)
release\KCDMP\KCDMP.dll        sha256 be76ba6a578a356357485b542dffa5175c4a86d452ce4c376b615c5a872c8984  (327,680 bytes, same mtime)
```

Identical **(observed)**. `Publish-Release.ps1` only invokes
`native\Build-Native.ps1` when `native\build\KCDMP\KCDMP.dll` is missing
(`-not (Test-Path $nativeDll)`, code-verified) — since it already existed,
this session's `Build-Installer.ps1` run did not recompile it. After the full
pipeline ran, the shipped manifest's own entry was checked again:

```
release\KCDMP\install-manifest.txt:  APP|KCDMP.dll|327680|BE76BA6A578A356357485B542DFFA5175C4A86D452CE4C376B615C5A872C8984
```

Same hash **(observed)**. The installer embeds the exact DLL WO-85 built;
nothing recompiled it, nothing silently drifted.

## 3. Build

- `tools\Build-Installer.ps1` (no `-SkipPublish`): rebuilt `kdcmp.pak`
  (590,993 bytes), republished `KCDMP_launcher`, `KcdMp.Client`,
  `KcdMp.Server`, `KcdMp.MasterServer`, generated the install manifest
  (1,024 entries), compiled `KCDMP-Setup-0.21.5.exe` (95.8 MB) **(observed)**.
- `tools\Build-DirectInstall.ps1 -SkipPublish`: packaged
  `KCDMP-DirectInstall-0.21.5.zip` (130 MB) from the same payload **(observed)**.
- `dotnet build KCD2-MP.sln -c Release --no-incremental`: **0 errors, 8
  warnings** — same 8 pre-existing warnings as WO-85 (1 `CS8602`, 1 `CS8603`,
  6 `CA1416`), nothing new **(observed)**.

## 4. Regression suite (Phase 2)

All green, **436 checks, 0 failures** (WO-85's 415 + the 21 new
`KcdMp.Client.Tests`):

| Suite | Result | Notes |
|---|---|---|
| Test-Sessions | 22/22 | fresh relay on 7778 |
| Test-Combat | 14/14 | same relay |
| Test-Dice | 15/15 | separate fresh relay (stale-relay trap avoided) |
| Test-NpcClaimValidation | 29/29 | self-starting relay |
| Test-NpcClaimLifecycle | 28/28 | self-starting relay, own `-WorkingDirectory` |
| Test-TimeSkipRelay | 35/35 | self-starting relay |
| Test-ItemSyncRelay | 11/11 | self-starting relay |
| Farkle unit tests | 59/59 | `dotnet test`, Release |
| **KcdMp.Client.Tests** | **21/21** | new this session, matches WO-88's own reported figure |
| Test-NpcSmoothSynthetic | 48/48 | MoonSharp, no relay/game |
| Test-GhostInterpSynthetic | 35/35 | MoonSharp, no relay/game |
| Test-WO84Synthetic | 72/72 | MoonSharp, no relay/game |
| Test-WO86Synthetic | 47/47 | MoonSharp, no relay/game |

Nothing needed fixing. All figures match their originating session's own
reported numbers exactly.

## 5. Install matrix (Phase 1 step 5)

Per `[[appdata-sandbox-redirection]]`, this shell's `%LocalAppData%` is
virtualized — running the real Setup against it would prove nothing. Used
the same fixture-based approach as WO-82/85, all three against the real
`KCDMP-Setup-0.21.5.exe`:

- `Test-InstallerDetect.ps1`: **21/21**.
- `Test-InstallerUpgrade.ps1`: **33/33**, six-cell matrix, including a real
  upgrade from `KCDMP-Setup-0.21.1.exe` (found on disk from WO-85).
- `Test-Installer.ps1`: **43/43**, full install/upgrade/uninstall lifecycle.
  Add/Remove Programs version confirmed as `0.21.5`.

**97/97, 0 failures.** Combined with §4: **533 checks total this session, 0
failures.**

Additionally ran `tools\Verify-Install.ps1` to confirm the two new Lua/agent
markers added this session (§7) are actually present in what got built:
`[BUILT app]` and `[BUILT pak]` both reported `present` for all three new
markers. `[BUILT vs INSTALLED]` reported stale/absent, as expected — that
comparison reads this shell's sandboxed `%LocalAppData%\KCDMP` copy from an
old build, not a real result, consistent with the same trap this project has
hit before. Not a regression; not evidence of anything about a real install.

## 6. Phase 3 — smoke pass

Not reachable: no `KingdomCome*` process at any point this session, no
listener on ports 1403 or 4600 **(observed)**. Per the brief, this phase is
opportunistic only. Skipped, stated plainly rather than left silent.

## 7. Verify-Install.ps1 markers added

Two new agent markers and one new pak marker, following the existing
pattern (a literal string that only exists in code introduced by the fix):

| File | Marker | Owner |
|---|---|---|
| `KcdMpClient.dll` | `body respawned` | WO-88 appearance-after-respawn fix |
| `KcdMpClient.dll` | `re-sending the convergence` | WO-88 reload time-sync convergence resend |
| `kdcmp.pak` | `function KCD2MP_ProbeDialog` | WO-88 `mp_probe_dialog` |

No literal marker added for the death-tag race fix: it is a pure logic gate
(`health > 0`) on the existing `KCD2MP_SetGhostDead` call, which already has
a marker from WO-28/34, and introduces no new distinctive string.

## 8. What changed, this session

`VERSION`, `README.md` (main badge), `docs/VERSIONING.md` (new row),
`kdcmp/Data/kdcmp.pak` (rebuilt from unchanged sources, not edited),
`tools/Verify-Install.ps1` (three new markers), `docs/releases/RELEASE-NOTES-0.21.5.md`
(new), this file and `docs/WO-89-progress.md`.

Not changed: any `.cs`, `.lua`, or `native/` source file. `KCDMP.dll` is
byte-identical to WO-85's build (§2).
