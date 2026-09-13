# KCD2-MP 0.21.5

The label for everything on `main` as of WO-89 (2026-09-12), packaged as
`KCDMP-Setup-0.21.5.exe` and the update-only `KCDMP-DirectInstall-0.21.5.zip`.

WO-89 is a release-cut session: it did not write new mod behaviour, it built
and packaged **WO-88** — three post-reload/death agent fixes plus a read-only
Lua diagnostic — which had landed on `main` but never been through a
production build. No native, protocol, or gameplay code changed in this
build; `KCDMP.dll` is byte-identical to the one already shipped in
`KCDMP-Setup-0.21.1.exe` (sha256
`be76ba6a578a356357485b542dffa5175c4a86d452ce4c376b615c5a872c8984`, confirmed
against this build's own install manifest).

**Verification status, stated plainly:** all four WO-88 changes are proven by
21 new unit tests pinned to this session's actual field numbers, plus the
existing Lua regression suites — 533 checks total this session across 15
suites plus the install matrix, 0 failures. **None of it has run in a real,
live game yet.** The real two-player verification — does the death-tag
flicker stop, does appearance survive a respawn, does time-sync hold across
repeated deaths — is explicitly the maintainer's own follow-up session.

---

## Fixed: a peer's own death could clear its own "dead" tag within milliseconds

A dying player's game sends two independent messages on the same tick: "I
died" and "my health is now 0". Whichever one the relay happened to deliver
second could stomp the first and clear the just-set death tag on the
receiving machine — a flicker, not the previously-reported "stays dead
forever" (that symptom was not reproduced against real field logs). The
death tag now only clears when a vitals packet reports health above zero.

## Fixed: a peer's outfit reverted to default after a death and reload, and never came back

After a death and reload, the game rebuilds a peer's ghost body from
scratch — but the other player's "what have I already sent this ghost"
bookkeeping survived the rebuild and kept assuming the new, bare body already
had the old outfit applied. The 30-second heartbeat resync had nothing to
diff against, so the ghost was stuck in default gear for the rest of the
session. That bookkeeping is now cleared on the same respawn edge that
detects the rebuild, and the peer's last known outfit re-applies immediately.

## Fixed: a silently dropped clock resync could desync the session by hours, with no error anywhere

Reloading a save sends a one-shot message to converge both players' game
clocks. That message could be dropped by a transient HTTP failure during the
post-load window with nothing logged — in one observed field session, a
15,808-game-second (4.4 hour) desync traced to exactly this. The resync now
stays pending and re-sends until it is confirmed applied. Independently, each
side's understanding of the other's clock previously only refreshed at
connect or at a real time-skip; a small periodic clock-share now keeps it
current even across a quiet stretch with no such event.

## Added: `mp_probe_dialog`, a read-only diagnostic (no behavior change)

Tests whether this game build exposes a usable "am I in a dialogue" signal,
for a future session's use. Logs `type=`/`ok=`/`val=` and changes nothing.

## Not fixed by this build: dialogue-related NPC jitter

An earlier session's working theory — that dialogue suspends the mod's
internal update loop the way menus and inventories do — was checked against
real two-player field logs and disproven: a 48-second real conversation
suspended nothing on either machine. Whatever causes NPC jitter around a
player in dialogue is a different, already-known issue (puppeted NPCs
fighting local AI when fed infrequent position updates) and this build does
not address it. Don't expect it to have changed.

## Verified this session

Full regression pass, all green (436 checks across 13 suites, 0 failures):

| Suite | Result |
|---|---|
| Test-Sessions | 22/22 |
| Test-Combat | 14/14 |
| Test-Dice (fresh relay) | 15/15 |
| Test-NpcClaimValidation | 29/29 |
| Test-NpcClaimLifecycle | 28/28 |
| Test-TimeSkipRelay | 35/35 |
| Test-ItemSyncRelay | 11/11 |
| Farkle unit tests | 59/59 |
| **KcdMp.Client.Tests (new, WO-88)** | **21/21** |
| Test-NpcSmoothSynthetic | 48/48 |
| Test-GhostInterpSynthetic | 35/35 |
| Test-WO84Synthetic | 72/72 |
| Test-WO86Synthetic | 47/47 |

Plus the fixture-based install matrix (97 checks, 0 failures) against the
real `KCDMP-Setup-0.21.5.exe`: `Test-InstallerDetect` (21/21),
`Test-InstallerUpgrade` (33/33, six-cell matrix including a real upgrade from
`KCDMP-Setup-0.21.1.exe`), `Test-Installer` (43/43, full install/upgrade/
uninstall lifecycle). `dotnet build KCD2-MP.sln -c Release`: 0 errors, 8
warnings, identical set to the prior build — nothing new.

**No live game was available this session** (no `KingdomCome*` process
running, no listener on ports 1403/4600), so Phase 3's solo smoke pass —
confirming `mp_probe_dialog` runs cleanly in-game — did not happen and is not
claimed. The install matrix was run against synthetic fixtures, not this
machine's real `%LocalAppData%`, which is sandbox-redirected for tool
processes in this environment.

## Console commands added

`mp_probe_dialog` (read-only diagnostic, no behavior change). Requires the
rebuilt pak to be live.

## Upgrading

Run `KCDMP-Setup-0.21.5.exe` with the game, the launcher, the agent and the
relay all closed, or unpack `KCDMP-DirectInstall-0.21.5.zip` with
`Apply.ps1` over an existing install. Either way, run
`tools\Verify-Install.ps1` afterwards and confirm it reports agreement.

**Both players need this build for the periodic clock-share to help.** An
older peer still works — it announces its clock at connect and applies
skips forward-only, same as before — it just doesn't get the new quiet
mid-session refresh. Mixed versions are not worse than the previous release,
just not improved for that half of the pair. The death-tag and appearance
fixes are local to whichever machine is updated and help regardless of the
peer's version.

## Reading further

- `docs/WO-89-findings.md` / `docs/WO-89-progress.md` — this release-cut
  session: what was rebuilt, what was verified, what is still the
  maintainer's job.
- `docs/WO-88-findings.md` / `docs/WO-88-progress.md` — the four fixes'
  design and field-log evidence.
