# WO-80 — pause detection for dialogs and cutscenes

Extension session, 2026-09-11, of WO-13's menu/inventory/skip-time pump and
WO-78's named follow-up ("the agent's pause detector misses dialogs and
cutscenes"). Companion: `docs/WO-80-progress.md`.

Evidence discipline, same as WO-75–78: **(observed)** seen this session · **(code-verified)**
read directly in the source tree · **(read-but-unrendered)** stated by a prior
doc, not re-checked here · **(inconclusive)** the evidence does not settle it.

Privacy: the same two field bundles WO-78 used (**host**, `kcd.log`
253,509 lines; **joiner**, `kcd.log` 557,773 lines) are cited again here by
line number. Their on-disk paths contain real usernames and are not quoted.
WO-78's own session extracted them to *its* scratchpad, "never into the
repo"; that scratchpad directory outlived its session and was located again
on disk for this WO (a different session, same machine) — no re-capture, no
new field session, same two real files WO-78 already analyzed. This is
stated plainly because it is a genuine methodological wrinkle: this WO
re-reads WO-78's raw data rather than generating its own.

---

## 0. Ground truth (Phase 0)

- (observed) `git pull` on `main`: already up to date at `6cc71e5`, WO-78's
  head. No newer work.
- (code-verified) `ProcessPauseMarkers` (`LogTailGameTransport.cs`) read in
  full: three independent booleans (`_menuOpen`, `_inventoryOpen`,
  `_skipTimeActive`) OR'd into `AggregatePaused`; each is a substring match
  against raw (untagged) engine log lines, entry and exit tracked
  independently so overlapping states don't produce a spurious "exited" when
  only one closes. `PauseStateChanged` fires only when the **aggregate**
  transitions.
- (code-verified) The WO-13 pump (`GameBridge.cs`) traced end to end:
  `OnLocalPauseDetected(bool paused)` is the *only* subscriber to
  `PauseStateChanged`; it starts/stops `StartInterpPump()`/`StopInterpPump()`,
  which loops `ExecuteNowAsync("KCD2MP_InterpPump()")` unbatched as fast as
  the round trip allows (WO-13 measured 35–86 Hz), with no awareness of *why*
  the aggregate is true. This means the pump needed **zero changes** for this
  WO — it already reacts generically to any aggregate transition. The entire
  fix is confined to what feeds that aggregate.
- (observed) Live-game check for a `human:IsInDialog()` probe (WO-57,
  documented, never probed): both candidate debug ports were closed this
  session (`Test-NetConnection 127.0.0.1 1403` → `False`,
  `127.0.0.1 4600` → `False`). No game was running, so nothing on the
  Lua-poll path could be probed live this session. This is load-bearing for
  the Phase 1 decision below.

---

## 1. Phase 1 — mechanism choice

### 1.1 Cutscenes: `CutscenePlayer::PlayCutscene` / `OnCutsceneEnd`, scoped to `Rendered`

(observed) Every `CutscenePlayer::` line in both field logs, by kind:

| event | host | joiner |
|---|---|---|
| `OnCutsceneInitialized` | 0 | 6 |
| `PlayCutscene` | 0 | 6 |
| `OnRequestFastForwardedBehavior` | 0 | 6 |
| `OnPositioningFinished` | 0 | 6 |
| `FinalizeCutscene` | 0 | 6 |
| `ReleaseScene` | 0 | 6 |
| `FinishCutscene` | 0 | 3 |
| `OnCutsceneEnd` | 0 | 6 |
| **`OnCutsceneStart`** | **0** | **0** |

The candidate named in the brief, `CutscenePlayer::OnCutsceneStart`, **does
not appear in either field log** — 811,282 combined lines, zero hits. It has
drifted or never existed on this build. `PlayCutscene` is used as the entry
edge instead: it fires once per cutscene, immediately after
`OnCutsceneInitialized`, and pairs 6-for-6 with `OnCutsceneEnd` for the same
cutscene name with no orphans (joiner log, in file order):

| # | type | cutscene | `PlayCutscene` line | `OnCutsceneEnd` line | span (lines) | DATA flowed during span? |
|---|---|---|---|---|---|---|
| 1 | Fader | `crime_secondArrestFader` | 92,440 | 92,441 | 1 | n/a (instant) |
| 2 | Fader | `crime_secondArrestFader` | 152,453 | 152,454 | 1 | n/a (instant) |
| 3 | Fader | `crime_fader` | 152,481 | 152,482 | 1 | n/a (instant) |
| 4 | SkipTime | `crime_skipTime` | 152,496 | 159,500 | 7,004 | **yes, normally** (see below) |
| 5 | **Rendered** | `crime_pillory_trosecko_firstRun` | 159,507 | 159,732 | 225 | **no — the real stall** |
| 6 | Text | `crime_punishmentTimeAdvance` | 159,739 | 162,840 | 3,101 | **yes, normally** |

Both `PlayCutscene`/`OnCutsceneEnd` are class-level CryEngine events — the
holder/module strings vary per quest, the event name and the type word
(`Rendered`/`Text`/`Fader`/`SkipTime`) do not — confirmed generic rather than
assumed, per the brief's instruction.

**Scoped to `Rendered` specifically, not every cutscene, on direct evidence:**
the emitter's own `[KCD2-MP-DATA]` line is the ground truth for "is
`Script.SetTimer` actually running." Checked for all four types:

- **Fader** (#1–3): 1 line apart, no measurable duration either way.
- **SkipTime** (#4): DATA flows continuously and normally from line 152,471
  (`os.clock` 1162.488) through 159,274 (1181.773) — 19.3 real seconds, ~6,800
  lines, entirely spanning this `PlayCutscene`. **This cutscene type's own
  entry does not freeze anything.** The real freeze starts only when the
  *separate*, already-tracked `Readiness observer 'AfterSkipTime' ... started
  async waiting` marker fires, at line 159,276 — inside this span, ~19 s after
  `PlayCutscene`. Tracking `PlayCutscene` for this type would just duplicate
  the existing skip-time marker with a 19 s head start for no benefit.
- **Rendered** (#5): the *only* one of the six that sits inside a real DATA
  gap — last DATA line before the stall at 159,274 (`os.clock` 1181.773,
  `seq` 56217), first after at 159,744 (`os.clock` 1241.451, `seq` 56218) —
  **59.68 s with zero new DATA lines**, matching WO-78's cited 60.69 s figure
  for this same event. This is the real stall this WO exists to cover.
- **Text** (#6): DATA resumes normally at 159,744 (inside this span, right
  after it starts) and flows at a normal rate through to 162,848 (`seq` 58766,
  `os.clock` 1244.437 — 2,549 samples over 62.7 s, ≈ 40.7 Hz against a nominal
  50 Hz emit interval). **This 62 s "cutscene" does not freeze anything
  either** — it is a UI text/notification overlay, not an engine pause.
  Tracking it would pump needlessly for over a minute with the native timer
  chain already running fine underneath, on every occurrence of this quest
  step.

Net: only `Rendered` is evidenced to correlate with an actual freeze in this
dataset (1 real instance, matching the stall exactly; the other three types
each have direct DATA-flow evidence of *not* freezing). The match is:

```csharp
if (line.IndexOf("CutscenePlayer::PlayCutscene called for Rendered cutscene") >= 0) _cutsceneActive = true;
else if (line.IndexOf("CutscenePlayer::OnCutsceneEnd called for Rendered cutscene") >= 0) _cutsceneActive = false;
```

Sample size caveat, stated honestly: one real `Rendered` instance, one `Text`,
one `SkipTime`-via-`PlayCutscene`, three `Fader`. This is what the one
available field session contains — not exhaustive. If a future log shows a
stall during a `Text` or `Fader` cutscene, that is the trigger to broaden the
match (§5).

**The overlap this design is actually needed for is directly observed, not
hypothetical:** the `Rendered` cutscene starts (159,507) *while* the
already-tracked skip-time marker is still active, and the skip-time marker
clears (159,539, `Readiness observer 'AfterSkipTime' ... is ready`) *before*
the cutscene ends (159,732). Pre-WO-80, the aggregate has only
`_skipTimeActive` covering this stretch and drops at 159,539 — 193 log lines
before the real freeze actually ends — which is exactly the reappeared WO-13
freeze the brief describes. Post-WO-80, `_cutsceneActive` is already true by
159,539 (set at 159,507) and keeps the OR'd aggregate true until 159,732. See
§3 for this run against the real compiled code.

### 1.2 Dialogs: log markers rejected on evidence; `IsInDialog()` deferred, not built

(observed) Both candidate dialog markers, checked for false-positive risk as
the brief asked, both fail:

- **`Dialog ends`** — 648 (joiner) / 682 (host) occurrences. Sample:
  `[ID: 29] Dialog ends but no response was played. (Forced: 'N') [Ex0:
  ttkc_inkeeper state: CLEANUP flags: 9088]`. This is ambient NPC small talk
  cleanup (innkeeper, woodworker, passers-by), not a marker of the *local
  player* being in a blocking dialog. There is **no** `Dialog starts` or
  equivalent counterpart anywhere in either log (0 hits) — it is not even a
  matched pair the way the other four markers are.
- **`Localization/dialog/`** — 1,646 (joiner) / 1,832 (host) occurrences.
  Sample: `[ATL] (tick:420611718; instance 512, file
  'Localization/dialog/open_world/professions/gand_zaka_zakaznik...') ...
  eACMRT_REPORT_STARTED_FILE`. This is the audio system (Wwise/ATL) reporting
  *any* dialogue sound file starting to stream, anywhere in the world,
  including two background NPCs greeting each other or monologuing near the
  player. It fires roughly 300× more often than an actual cutscene in this
  session and has no relationship to whether the local player's own screen is
  blocked.
- For context, unfiltered "dialog"-adjacent lines in the joiner log are
  dominated by things like `Attempting to start new dialogue ... meta
  override: ROLNIK_SAMOMLUVA` (228×, ambient peasant monologue) and `New
  dialogue ... (AI::DoMonologue) ... forced = true` (227×) — engine-internal
  NPC chatter bookkeeping, not player-facing modal dialog.

Using either as a pause boundary would make the aggregate spuriously true for
a large fraction of ordinary play, which is worse than the gap it would
close. **Rejected on this evidence**, per the brief's own instruction not to
build the log-marker path if it doesn't hold up.

That leaves the brief's secondary candidate, `human:IsInDialog()` (WO-57,
documented, never probed). Per this project's standing rule (WO-65: a
documented bind is not a verified one) the brief requires probing it live
*before* trusting it. §0 already establishes that no game was reachable this
session (both debug ports closed). **Not built.** Shipping an unverified
native-bind poll here would repeat exactly the mistake WO-65 was named for —
guessing a signature works because a doc says so. Deferred as a named
follow-up (§5) for the next session with a live game.

---

## 2. Phase 2 — what was changed

All in `dotnet/KcdMp.Client/LogTailGameTransport.cs`, plus doc-comment
accuracy fixes in `dotnet/KcdMp.Client/GameBridge.cs`. **No Lua change; no
`GameBridge.cs` behavioral change.**

- `_cutsceneActive` field, next to the three WO-11 booleans; `AggregatePaused`
  now ORs in a fourth term. Same shape, same independence rationale (the
  §1.1 overlap is the concrete instance of exactly what the existing doc
  comment on `PauseStateChanged` already anticipated in the abstract).
- The `Rendered`-scoped `PlayCutscene`/`OnCutsceneEnd` block added to
  `ProcessPauseMarkers`, in the same position/shape as the existing three
  (substring match, independent entry/exit, no nesting/counting — matches how
  menu/inventory/skip-time are already handled).
- **The WO-13 pump required no changes** (§0) — `StartInterpPump`/
  `StopInterpPump`/`OnLocalPauseDetected` all key off the aggregate alone.
  Entering a cutscene now engages the existing pump the same way a menu
  already does; leaving one hands back to the native `Script.SetTimer` tick
  the same way closing a menu already does. No new pump, no new transition
  logic — reused exactly as instructed.
- Deliberately **not renamed**: the pump's console log tag stays
  `[menu] local menu open -- pumping interp tick` / `[menu] local menu closed
  ...`, even though it now also fires for a cutscene. WO-78's own findings
  (§1) grep this exact string (`agent [menu] local menu open`, counted 9/6)
  as a load-bearing metric for classifying menu-driven restarts in a field
  log. Renaming it would break that established diagnostic without being
  asked to, for a cosmetic gain. Noted here rather than silently decided.
- Three doc-comment updates for accuracy, no behavior change:
  `ProcessPauseMarkers`'s summary, the `ProcessLine` prose next to it, and
  `GameBridge.cs`'s `slow_time_toggle` comment (previously said "three states
  confirmed live", now four, and now names dialogs explicitly as still
  uncovered).
- **Confirmed untouched**, via `git diff --stat` before committing:
  `kdcmp/Data/Scripts/Startup/kdcmp.lua` (chain-safety code — `chainMayStart`,
  both leak detectors, `mp_npc_chainfix`/`mp_ghost_chainfix` — is entirely
  Lua-side and this session made zero changes to that file) and
  `GameBridge.cs`'s pump/`ApplyPeerPauseAsync` methods (comment-only diff,
  confirmed by reading the diff, not assumed).

Build: `dotnet build KCD2-MP.sln` (all 7 projects) — 0 errors, 0 warnings.

---

## 3. Phase 3 — verification

### 3.1 Primary: replayed the real field-log window through the actual compiled class (observed)

Rather than re-derive the fix from grep alone, a throwaway console harness
(`Wo80Replay`, scratchpad-only, never committed — see rationale below) was
built with a `ProjectReference` to `KcdMp.Client.csproj` and drove the **real,
compiled `LogTailGameTransport`** — not a reimplementation:

1. Point it at an empty temp file (so the tail's `Seek(0, SeekOrigin.End)`
   starts at 0, matching production behavior).
2. `await transport.StartAsync()` (the HTTP emitter-start send fails fast
   against an unreachable loopback port — expected and caught; the tail task
   itself is already spawned before that call, so it keeps running).
3. Subscribe to the real `PauseStateChanged` and `SkipTimeStateChanged`
   events.
4. Append the real joiner-log window, lines 152,470–159,745 (7,276 lines,
   ~1.04 MB — brackets all three back-to-back cutscenes: the `SkipTime`
   entry, the `Rendered` stall, and the following `Text` cutscene), to the
   temp file in one write, then wait for the tail loop to drain it.

Result — exactly 4 events fired, in this order:

```
SkipTimeStateChanged   -> True     (line 159,276: AfterSkipTime starts waiting)
PauseStateChanged agg  -> True     (same line: first state, aggregate follows)
SkipTimeStateChanged   -> False    (line 159,539: AfterSkipTime is ready)
PauseStateChanged agg  -> False    (line 159,732: Rendered cutscene's OnCutsceneEnd)
```

The critical assertion is the *absence* of an event at line 159,539: skip-time
clearing there does **not** flip the aggregate, because `_cutsceneActive` had
already gone true at line 159,507 and does not clear until line 159,732. A
debug instrumentation pass (temporarily added, removed before the diff above
was finalized) confirmed this directly by printing all four flags at both
aggregate transitions:

```
AGGREGATE False->True  menu=False inv=False skip=True  cutscene=False   (@159,276)
AGGREGATE True->False  menu=False inv=False skip=False cutscene=False   (@159,732)
```

At the second transition, `skip` had already been `False` for 193 lines with
no aggregate change — because `cutscene` was still `True` until that same
line. This is the fix working against real, replayed data: the aggregate
pause window now runs 159,276→159,732, matching the real ~60 s stall
(§1.1's 59.68 s DATA-gap measurement) instead of 159,276→159,539 (dropping
out ~193 lines / a large fraction of the real stall early, which is the
freeze the brief describes). No aggregate event at all fired for the
following `Text` cutscene (159,739–162,840) — confirming the type-scoping
decision is inert for the type it was designed to exclude, on the same real
data, not just by inspection.

This is stronger than re-deriving it from grep alone: it is the actual
shipped `IndexOf` matching, the actual `AggregatePaused` OR, and the actual
event-firing code, executed against real bytes.

**Not committed, deliberately**: neither the harness nor any excerpt of the
real log window was added to the repository. This mirrors WO-78's own stated
practice ("Extracted both field bundles to the scratchpad ... never into the
repo") — the project's existing privacy discipline for this specific
dataset, applied consistently rather than re-decided.

### 3.2 Spot-checked: all six cutscene events in the dataset, not just the cited one

§1.1's table already covers every `CutscenePlayer::PlayCutscene`/
`OnCutsceneEnd` pair in both field logs (all six live in the joiner log; the
host log has **zero** `CutscenePlayer::` lines of any kind this session — no
cutscene rendered locally on that machine, so nothing to check there). This
exceeds "a couple more" — it is the complete population available.

### 3.3 Live check: not run

No game was reachable this session — both `127.0.0.1:1403` and
`127.0.0.1:4600` refused a TCP probe, confirming no running instance to talk
to. **What is confirmed is log-replay accuracy against real captured data,
not how it actually looks or feels live.** That is the honest boundary of
this session's verification; the next field/live session is where "does a
connected ghost keep rendering smoothly through a cutscene" gets watched by
a human, the same gap WO-78 named for its own fix.

---

## 4. What this WO did not do

- **No dialog detection shipped** (§1.2) — rejected the log-marker path on
  direct evidence, and did not build the `IsInDialog()` poll without a live
  probe. This is a real, named scope reduction from the brief's title, stated
  plainly rather than glossed over.
- **No change to `chainMayStart`, either leak detector, or either
  `mp_*_chainfix` toggle** — confirmed via `git diff` before this was
  written, not assumed.
- **No change to `kdcmp.lua`** at all — this was .NET-side work throughout.
- **No `VERSION` change** (still whatever `main` carries at `6cc71e5`'s head
  — the maintainer's call, per project convention).
- **No pak rebuild or install** — nothing here is live until
  `Build-And-Install-Mod.ps1` runs and the game restarts, same caveat WO-78
  already flagged for its own Lua change (this WO has no Lua change, but the
  same "nothing is live until a restart" caveat applies to the agent binary
  itself).

## 5. Named, not attempted

1. **`human:IsInDialog()` live probe.** The one concrete next step for
   dialog coverage: probe it with a live game (`mp_probe_*` pattern, per
   project convention) before trusting it for anything. Only build the
   Lua-poll path if that probe actually works and a design for polling
   cadence vs. `Script.SetTimer` suspension is worked out (the poll itself
   would need to run from the *pump*, since ordinary Lua timers are exactly
   what stops during the state it is meant to detect).
2. **Broadening the cutscene type match**, only if a future field log shows a
   real stall during a `Text` or `Fader` cutscene. None did in this dataset
   (§1.1); this is not evidenced today.
3. **Cosmetic**: the peer ghost's nameplate tag (`KCD2MP_SetGhostMenuState`,
   Lua-side) still renders the literal text `[in menu]` when the trigger was
   actually a cutscene. Out of scope here (Lua, cosmetic, not chain-safety) —
   named rather than fixed opportunistically.
4. Everything WO-78 already named and did not touch (`GHOST_DEATH` flapping,
   the horse teleport, ExecuteString batch truncation, animation-queue
   overflow) — untouched here too, out of scope.
