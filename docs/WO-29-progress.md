# WO-29 progress — package the release

Session 2026-08-07/08. Human not at the machine for most of this — no live
game required for what this WO actually did. `VERSION` set to `0.11.5` on the
human's explicit instruction, given mid-session after being asked.

## What was done, in order

1. **Read the real history, not summaries.** `docs/WO-26/27/28-progress.md`
   and their shareable summaries, `git log 27fe118..HEAD` (the `0.10.0`
   commit to `HEAD`), and both commits the brief flagged as unattributed:
   - `06279a1` ("WO-17: clarify ghost-can't-fight-back...") — **correction to
     the brief's premise**: this commit is chronologically *before* the
     `0.10.0` commit (`27fe118`), not after. It is not actually in the
     `0.10.0..HEAD` range. Its content (the attacker-attribution and
     no-animation-sync caveats) is already in
     `docs/releases/RELEASE-NOTES-0.9.5.md`. Folded the still-true parts into
     this release's honest-limits section anyway, since they remain accurate.
   - `fa619d3` ("Update README.md") — one line, adding the "alt-tab into the
     launcher and choose Connect" step. Genuinely in range. Already reflected
     in the current README; carried forward as-is in the rewrite.
2. Read current `README.md` and `docs/PROJECT-STATE.md`. Found both already
   substantially updated by WO-27/28 (they update these files as part of
   their own scope) — less drift than the brief assumed, but real gaps
   remained: no mention anywhere of the WO-20 face roster, the WO-27
   reconnect/launcher-duplicate-agent fixes, or the WO-19 launcher polish;
   no explicit "does not synchronise NPCs" or "ghost's own attacks
   unreplicated" caveat.
3. Wrote `docs/releases/RELEASE-NOTES-0.11.5.md` — full changelog since
   `0.10.0`, player-facing language pulled from the WO-26/27/28 summaries
   rather than rewritten, plus an "Investigated, not shipped" section
   (retail RemoteConsole, native dice score/selection vs. force-roll,
   can't-be-Henry).
4. Rewrote `README.md`: added the ghost-face-roster row, a reconnect/
   duplicate-agent-fix row, the WO-19 launcher-polish description folded
   into the existing launcher row, the ghost's-own-attacks and
   NPC-not-synchronised caveats, and the new WO-28 test scripts
   (`Test-PlayerCombat.ps1`, `Test-PlayerVitalsE2E.ps1`,
   `Test-ReloadBehaviour.ps1`) in the Testing section. Left
   `docs/PROJECT-STATE.md` untouched — it already carries the accurate
   WO-27/28 amendments and was not asked to be rewritten.
5. **Phase 3's "known loose end" was already fixed.** The brief said
   `tools/Test-AppearanceE2E.ps1` still pinned protocol version 5. It does
   not — the last commit on `main` before this session (`9976ff6`) already
   made it (and ten other scripts) derive the version from `Protocol.cs` via
   `tools/ProtocolVersion.ps1`. Confirmed by reading both files; `Protocol.cs`
   currently reads `Version = 6`. Nothing to fix.
6. Asked the human for the version string per `docs/VERSIONING.md` before
   touching `VERSION` or building anything. Given: **`0.11.5`**.
7. The human separately said the game-dependent PowerShell E2E suites
   (`Test-AppearanceE2E.ps1`, `Test-PlayerVitalsE2E.ps1`, `Test-Pipe.ps1`) can
   be deferred — most players only touch the game/launcher/installer, and
   nobody was available to run the real game this session. **Not run.** This
   is a deliberate scope cut by the human, not a gap discovered and hidden.
8. Set `VERSION` to `0.11.5`, updated the two literal `0.10.0` strings in
   `README.md`'s install-update section, and appended `0.11.5` to
   `docs/VERSIONING.md`'s version-history table (consistent with that
   document's own existing pattern for every prior release).
9. Built both release artifacts:
   - `tools\Build-Installer.ps1` → `release\KCDMP-Setup-0.11.5.exe` (65 MB).
   - `tools\Build-DirectInstall.ps1 -SkipPublish` →
     `release\KCDMP-DirectInstall-0.11.5.zip` (86.4 MB).
10. Ran the regression suites that don't need the live game:

| Suite | Result | Note |
|---|---|---|
| `dotnet build KCD2-MP.sln` (Release) | clean, 0 errors | pre-existing warnings only |
| `KcdMp.Farkle.Tests` (xUnit) | 59/59 | |
| `Test-Combat.ps1` | 14/14 | |
| `Test-Sessions.ps1 -IncludeTimeout` | 23/23 | |
| `Test-Dice.ps1` | 10/10 | needed a **Debug** relay build — its seeded-match check only works against a Debug relay (documented in the script's own header); not a regression |
| `Test-PlayerCombat.ps1` | 21/21 | starts its own isolated relay |
| `Test-InstallerDetect.ps1` | 21/21 | no game/Steam interaction needed |
| `Test-Installer.ps1 -SetupExe release\KCDMP-Setup-0.11.5.exe` | 41/41 | full install/upgrade/uninstall lifecycle against the real build; self-cleaned its real `Mods\kdcmp` deployment afterward |

**Deliberately not run this session** (per the human's explicit scope cut):
`Test-AppearanceE2E.ps1`, `Test-PlayerVitalsE2E.ps1`, `Test-Pipe.ps1` — all
three need the real game running via Modding Tools, and `Test-Pipe.ps1`
additionally needs the native plugin injected. `docs/PROJECT-STATE.md` §7
still records `Test-AppearanceE2E.ps1`'s known `belt_2slot`/`GambesonShort02`
equip failure as open and unresolved; this WO did not touch it.

## Judgement calls worth flagging

- **Did not treat the brief's WO-17-commit claim as correct without checking
  it.** `git merge-base --is-ancestor` showed it predates `0.10.0`; reported
  the correction rather than silently working around it or forcing it into
  the "since 0.10.0" framing.
- **Added a `0.11.5` row to `docs/VERSIONING.md`'s history table** on my own
  initiative, not explicitly requested. Judged low-risk and consistent with
  the document's own established pattern (every prior version has a row);
  flagging it here rather than treating it as unremarkable.
- **Did not push back on deferring the live-game suites.** The human's
  reasoning (most players only touch game/launcher/installer, nobody was at
  the machine) is sound and explicit, not a corner being cut silently.

## Not done, deliberately

- Nothing uploaded or published. Both artifacts sit in `release\` only, per
  standing instruction — distributing them is the human's call.
- `docs/PROJECT-STATE.md` not rewritten — out of this WO's stated scope
  (README only) and not stale enough to need it.
- The three game-dependent E2E suites — see above.
