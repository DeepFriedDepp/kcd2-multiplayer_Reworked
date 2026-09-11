# WO-80 — progress

Session 2026-09-11. Extend the agent's pause detector to recognize dialogs and
cutscenes, so the WO-13 interp pump engages for both the way it already does
for menus/inventory/skip-time. Findings and every number:
`docs/WO-80-findings.md`.

Privacy: this WO re-reads the same two field bundles WO-78 extracted to its
own (now orphaned but still present) scratchpad directory, found again on
disk this session. No new capture; on-disk paths not quoted anywhere.

## Status

- **Phase 0** done: `main` at WO-78's head (`6cc71e5`); `ProcessPauseMarkers`
  and the WO-13 pump read in full; confirmed the pump needs no changes
  (already generic over the aggregate).
- **Phase 1** done: **cutscenes** — `CutscenePlayer::PlayCutscene` /
  `OnCutsceneEnd`, scoped to the `Rendered` type only (the other three types
  present in the data — `Fader`, `SkipTime`, `Text` — do not freeze
  `Script.SetTimer`, evidenced via DATA-line flow, not assumed). **Dialogs** —
  rejected on evidence (`Dialog ends` / `Localization/dialog/` are ambient
  NPC-chatter/audio-streaming noise at 650–1,800× the real cutscene count,
  with no measurable relationship to the local player's own dialog state);
  `human:IsInDialog()` deferred, not built, because no live game was reachable
  this session to probe it first.
- **Phase 2** done: `_cutsceneActive` field + `AggregatePaused` OR +
  `Rendered`-scoped marker pair added to `LogTailGameTransport.cs`. Doc-only
  accuracy fixes in `GameBridge.cs`. Zero Lua changes, zero pump changes.
- **Phase 3** done: replayed the real joiner-log window (lines
  152,470–159,745) through the actual compiled `LogTailGameTransport` via a
  throwaway harness (not committed) — confirmed the aggregate now spans the
  full real stall (159,276→159,732) instead of dropping early at 159,539.
  Spot-checked all six real cutscene events in the dataset (the full
  population, not a sample). Live check not run — no game reachable.
- `VERSION` unchanged. No pak built or installed.

## Commits, in order (all on `main`, pushed to `origin main`)

See `git log --oneline` for hashes; messages prefixed `WO-80:`.

1. `WO-80: Rendered-cutscene pause detection, dialogs rejected on evidence`
2. `WO-80: findings and progress docs, README/PROJECT-STATE rows`

## What was done, in order

1. Pulled; confirmed head at WO-78's `6cc71e5`.
2. Read `ProcessPauseMarkers` (`LogTailGameTransport.cs`) and the WO-13 pump
   wiring (`GameBridge.cs`: `OnLocalPauseDetected`, `StartInterpPump`,
   `StopInterpPump`) end to end. Confirmed the pump is keyed off the
   aggregate `PauseStateChanged` alone, with no awareness of which marker
   caused it — so it needed no changes for this WO.
3. Located WO-78's two real field-log bundles (still present in a prior
   session's now-orphaned scratchpad directory on this machine) and confirmed
   the brief's candidate markers against them:
   - `CutscenePlayer::OnCutsceneStart` — **0 occurrences** in 811,282 combined
     lines. Drifted/never existed on this build.
   - `CutscenePlayer::OnCutsceneEnd` — 6 occurrences, joiner only, all
     cleanly paired with a prior `PlayCutscene` for the same cutscene name.
   - `Dialog ends` (648/682) and `Localization/dialog/` (1,646/1,832) — both
     present, both confirmed unusable (ambient NPC monologue/audio-streaming
     noise, not a player-facing dialog boundary; `Dialog ends` also has no
     `Dialog starts` counterpart at all).
4. Classified all six real `PlayCutscene`/`OnCutsceneEnd` pairs in the joiner
   log by type against the emitter's own DATA-line flow (the ground truth for
   "did `Script.SetTimer` actually freeze"). Only the one `Rendered` instance
   (the `crime_pillory_trosecko_firstRun` cutscene WO-78 already cited) sat
   inside a real DATA gap (59.68 s, matching WO-78's 60.69 s figure for the
   same event). `SkipTime`, `Text` and `Fader` types all had DATA flowing
   normally through their entire span.
5. Checked for a live game to probe `human:IsInDialog()` (WO-57's documented,
   never-verified bind): `127.0.0.1:1403` and `127.0.0.1:4600` both refused a
   TCP connection. No game running. Per WO-65's standing rule (documented is
   not verified), did not ship this poll unverified.
6. Wrote the code: `_cutsceneActive` field, `AggregatePaused` OR, the
   `Rendered`-scoped marker block in `ProcessPauseMarkers`; doc-comment
   accuracy fixes in `GameBridge.cs`'s `slow_time_toggle` case. Deliberately
   left the pump's `[menu] local menu open` log tag unchanged — WO-78's own
   findings grep that exact string as a metric.
7. `dotnet build KCD2-MP.sln` — 0 errors, 0 warnings, all 7 projects.
8. Built a throwaway console harness (`ProjectReference` to
   `KcdMp.Client.csproj`, ~50 lines) that drives the real compiled
   `LogTailGameTransport` against the real joiner-log window
   (152,470–159,745) appended to a temp file after the tail loop had already
   started (matching production's tail-from-current-end behavior). Confirmed
   exactly 4 events in the expected order, with the aggregate spanning the
   full real stall. Not committed — matches WO-78's stated practice of never
   putting the field bundles (or, here, a tool built directly against them)
   into the repo.
9. Confirmed via `git diff --stat` that `kdcmp/Data/Scripts/Startup/kdcmp.lua`
   has zero changes, and that the `GameBridge.cs` diff is comment-only.
10. Wrote the docs.

## Not done, deliberately

- No dialog pause detection shipped. The log-marker path was rejected on
  direct evidence (§1.2 of findings); the Lua-poll path needs a live probe
  this session could not perform (no game running). Named as the top
  follow-up.
- No change to `chainMayStart`, either leak detector, or either
  `mp_*_chainfix` toggle. Confirmed, not assumed.
- No Lua change of any kind.
- No `VERSION` bump, no release, no install.
- No new permanent test tool committed — the field-log replay used real,
  privacy-sensitive data, so (matching WO-78's own choice) it stayed
  scratchpad-only rather than becoming a committed fixture.

## For the next field/live session

- Watch a real cutscene and a real dialog with a connected ghost: confirm the
  ghost keeps rendering smoothly through the cutscene (should now work) and
  still freezes through a dialog (expected, until the follow-up above ships).
- If `human:IsInDialog()` gets probed live and works, that is the next
  session's Phase 2 for dialogs — reuse the same pump, do not build a second
  one.
- Grep any new `kcd.log` for `CutscenePlayer::PlayCutscene called for
  Rendered cutscene` / `CutscenePlayer::OnCutsceneEnd called for Rendered
  cutscene` pairs; each pair not fully bracketed by a DATA gap would mean a
  `Rendered` cutscene that doesn't actually freeze anything either, which
  would be new evidence the type-scoping needs revisiting in the other
  direction.
- This WO changed the agent (`KcdMp.Client`), not the Lua pak —
  `Build-And-Install-Mod.ps1` is not needed for this change and does not
  touch it. Whatever the launcher's configured `AgentPath` points at needs to
  be rebuilt (or the launcher pointed at this session's build output) before
  any of this is live; not otherwise verified this session (no game running
  to test against).
