# WO-81 — progress

Session 2026-09-11. Instrumentation-only: give the relay's NPC-claim table a
voice (grant/release/reassignment logging, mirroring WO-66's `[TAG]` +
counter shape), add a contested-claim detector to test the field report that
NPC jitter got worse when players stood close together, and wire the relay's
log into Collect Logs — which had never included it. Findings and every
number: `docs/WO-81-findings.md`.

This WO does not change any claim decision anywhere. It only makes the
existing decisions visible.

## Status

- **Phase 0** done: read `RouteNpcState`/`ClearNpcClaimsFor` end to end.
  Position packets were already parsed but never cached (small addition, as
  anticipated). The relay had **no persistent log file at all** — Console-only
  Serilog, `Serilog.Sinks.File` already a project dependency for an unrelated
  reason (merged-publish-folder DLL probe) but never wired up — and Collect
  Logs had never bundled one because there was nothing to bundle. Unplanned
  extra finding: none of the existing `Test-*Relay.ps1` scripts actually load
  `appsettings.json` (no `-WorkingDirectory` on their `Start-Process` calls),
  so this WO's own new test deliberately does, to exercise the real config.
- **Phase 1** done: `[CLAIM] granted|released|reassigned` lines + counters on
  a new sibling endpoint, `GET api/information/npc-claims`.
- **Phase 2** done: `[CLAIM-CONTESTED]` detector, two paths (quick
  reassignment, and a stale-owner rejection against a still-live claim),
  distance correlation from a new diagnostic-only position cache, `unknown`
  when a session has no cached position. Config-gated
  (`NpcClaimValidation:ClaimLifecycleLogging`), default **on** — reasoning in
  findings. A real bug in the first cut (reassignment `gapSec` always read
  `0.0`, caught by the new test's slow-reassignment case) was found and fixed
  before this shipped — see findings §3.3.
- **Phase 3** done: Serilog File sink added to both `appsettings.json` and
  `appsettings.Development.json` (`relay<date>.log`, daily rolling, 10
  retained); `LogBundle.Collect` gained a `relayDirectory` parameter and a
  `relay*.log` collection block identical in shape to its existing `app*.log`
  one; `Home.razor.cs`/`Home.razor`/`ReportBugModal.razor` thread it through,
  resolved unconditionally like `AgentDirectory` so a joiner or a
  never-hosted install degrade to "nothing to collect" via the existing
  `AddIfPresent` skip, not an error. **Verified end-to-end**, not assumed: a
  throwaway harness called `LogBundle.Collect` against a real relay run that
  had produced real `[CLAIM]`/`[CLAIM-CONTESTED]` lines, and the resulting
  zip was opened and confirmed to contain them.
- **Phase 4** (periodic authority snapshot) — not built. Phases 1–3 took the
  full session; per the brief, this was optional and not the point of the WO.
- **Phase 5** done: new suite `tools/Test-NpcClaimLifecycle.ps1`, 28/28.
  Full existing suite set re-run: `Test-NpcClaimValidation` 29/29 unchanged,
  `Test-Sessions` 22/22, `Test-Combat` 14/14, `Test-TimeSkipRelay` 35/35,
  `Test-ItemSyncRelay` 11/11, Farkle unit tests 59/59, solution build clean.
  `Test-Dice.ps1` has one pre-existing flaky assertion, confirmed present on
  the untouched `main` baseline via `git stash` before this WO's changes —
  not a regression, out of scope, not touched.
- `VERSION` unchanged. No pak built, no game session anywhere in this WO —
  relay + launcher + PowerShell test tooling only.

## Commits, in order (all on `main`, pushed to `origin main`)

See `git log --oneline` for hashes; messages prefixed `WO-81:`.

1. `WO-81: claim-lifecycle logging + contested-claim detector`
2. `WO-81: wire the relay log into Collect Logs`
3. `WO-81: claim-lifecycle test suite`
4. `WO-81: findings and progress docs`

## What was done, in order

1. Pulled; confirmed `main` current at WO-80's head.
2. Read `ClientHandler.RouteNpcState`/`ClearNpcClaimsFor`,
   `ClientSession.cs`'s NpcStateUp and Position branches,
   `TcpBroadcastService.Broadcast`, `InformationController.cs`,
   `NpcValidationCounters.cs`, and `docs/WO-66-progress.md` end to end before
   changing anything, per the brief.
3. Answered both Phase 0 questions by reading code, not guessing (§1.1/1.2 of
   findings); found the unplanned `-WorkingDirectory` gap in the existing
   test scripts along the way (§1.3).
4. Added the diagnostic position cache (`RecordPlayerPosition`/
   `ClearPlayerPositionFor`/`DistanceBetweenLocked`) to `ClientHandler`, wired
   from `ClientSession`'s Position branch and `TcpSocketService`'s disconnect
   continuation.
5. Added `GrantedUtc` to the `_npcClaims` tuple, `_recentReleases` (previous
   owner + last-active timestamp per name), the claim counters, and the
   grant/release/reassignment/contested logging in `RouteNpcState`/
   `ClearNpcClaimsFor`. Added `NpcClaimCounters.cs` and the `npc-claims`
   endpoint.
6. Added the Serilog File sink to both appsettings files and the
   `ClaimLifecycleLogging`/`ContestedGapSeconds` config keys.
7. `dotnet build KCD2-MP.sln` — 0 errors, 0 new warnings.
8. Smoke-tested the built relay directly (PowerShell `Start-Process`, then
   isolated ports after discovering a real relay from tonight's own field
   session already held 5273) — confirmed `relay<date>.log` gets created and
   captures both `[INF]` startup lines and a real unhandled-exception stack
   trace.
9. Wrote `Test-NpcClaimLifecycle.ps1` (T0–T7, see findings §5), ran it,
   found and fixed the `gapSec` bug (§3.3), re-ran to 28/28.
10. Wired `LogBundle.Collect`'s new `relayDirectory` parameter and the
    launcher's `RelayDirectory` plumbing (`Home.razor.cs`, `Home.razor`,
    `ReportBugModal.razor`).
11. Built a throwaway console harness (`ProjectReference` to
    `KCDMP_launcher.csproj`, not committed) to call `LogBundle.Collect`
    directly; generated real claim events against a real relay; ran the
    harness; opened the produced zip and confirmed `relay<date>.log` was
    present, non-empty, and contained the exact lines generated. Deleted the
    test zip afterward.
12. Ran the full existing suite set; found and root-caused the Test-Dice
    flake as pre-existing (§ findings table) rather than assuming it was a
    WO-81 regression.
13. Wrote the docs.

## Not done, deliberately

- No claim-decision change anywhere — every gate WO-39/60/66 shipped behaves
  identically; this WO only added logging/counters around them.
- Phase 4 (periodic authority snapshot) — optional per the brief, skipped for
  time; Phases 1–3 and their verification were the point of the WO.
- No edit to any tester checklist file — none exists in this repo that
  mentions a manual relay-log step (checked); noted for the maintainer
  instead (findings §4.6).
- No fix for the pre-existing `Test-Dice.ps1` flake — confirmed present on
  the untouched baseline, unrelated to this WO's area, out of scope.
- No `VERSION` change, no release, no install.

## For the next field/live session

- The original field report — jitter worsening at close range — is now
  **testable, not yet tested live**. Everything in this WO is wire-verified
  only; no game was reachable this session. Watch for `[CLAIM-CONTESTED]`
  lines correlating with reported jitter, and check `distanceBetweenPlayers`
  against what the players actually reported.
- Given §3.2 of findings (every stale-owner rejection is contested under
  default constants), a genuinely informative read of a real log is the
  **reassignment-path** contested events and their `gapSec` values, not the
  raw contested count.
- Drop the manual "grab the relay log" step from whatever checklist or habit
  the maintainer was using — Collect Logs covers it now.
- If `ContestedGapSeconds` turns out too sensitive or not sensitive enough
  against real field data, it is config-backed
  (`NpcClaimValidation:ContestedGapSeconds` in `appsettings.json`) — no code
  change needed to retune it.
