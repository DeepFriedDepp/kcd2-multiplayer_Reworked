# WO-128 — live leash data (0.30.0)

Live read-only monitor run alongside a real two-player 0.30.0 session (host +
"the joiner"), reading the host's leash recorder CSV (WO-127 §4), `agent.log`,
`kcd.log` and the native mirror log as they were written. No console
commands, no input, nothing written into the game's folders. Evidence marks:
(observed) / (inconclusive). Numbers come from the trace or a log line.

**Coverage gap up front**: the joiner's files (agent log, `kcd.log`, native
mirror log, `leash-joiner-*.csv`, `mp_npc_trace` captures) were not collected
after this session, so everything here is **host-side only**. The
joiner-vs-host sinking-body comparison and "what the joiner saw" sections
WO-128 originally asked for are not answerable from this run; see Coverage.

## 0. Answer first

- **No edge was seen.** Across the whole session (host-joiner distance 0.6 m
  to **1276.6 m**, avg 149.4 m), every NPC sampled within 200 m of the joiner
  came back live — none showed the game's own brain-suspension bit
  (mask bits other than our own 0x08). 42,739 NPC-observations, 0 suspended.
  (observed)
- **Why, most likely**: WO-129 made every player a permanent NPC scan anchor
  ("apart never releases"). The leash recorder only samples NPCs within 200 m
  of *either* anchor, so any NPC close enough to the joiner to appear in this
  data already has the joiner itself as a live anchor within 200 m — it can
  never be suspended by distance from the host, only by distance from the
  joiner. **The real edge, if one exists, is a function of distance from the
  joiner specifically (out past the recorder's own 200 m radius), not of
  host-joiner separation.** This session's play pattern (fighting side by
  side most of the time, with one solo excursion to ~1.3 km) never tested
  that. (inconclusive — plausible from WO-129's own logged design intent,
  not directly measured because the recorder can't see past 200 m from an
  anchor)
- **Leash / warning distance for WO-114**: nothing here justifies a
  host-joiner leash distance at all — the mechanism this data was meant to
  bound (world stops simulating around the joiner past some host-joiner gap)
  wasn't observed acting that way. Recommend WO-114 instead test distance
  **from the joiner outward past 200 m** (their own local edge, independent
  of the host), which this session did not cover.
- **Per-context**: only one context was ever sampled — "town" (by the
  joiner's own `joiner_town`/`joiner_interior`/`joiner_riding` flags, which is
  what the recorder's radius is actually centered on). The joiner stayed in
  or near the settlement all session; the host's one long solo excursion
  didn't move the joiner's own context, so wilderness/indoors/riding are
  uncovered. (observed)
- **Two-anchor cost**: `MP-NPCSCAN dir=native anchors=2` stayed inexpensive
  the whole session — `dur_ms` mostly 15–20 ms (one late outlier at 54.1 ms,
  at game-quit teardown), matched count 72–77 of a 200 cap, never truncated.
  Host fps ranged 20.1–89.2, avg 60.5 over 585 one-second samples; the drop
  to the low 20s tracked with active multi-NPC combat, not with anchor
  distance (see 0.30.0-session-notes.md). (observed)

## 1. The band table

`live` = not suspended by the game (brain mask bit other than our own 0x08).
Context is the joiner's own town/interior/riding flags (see note above on why
this is joiner-centric, not host-centric).

| host-joiner band | context | live | total |
|---|---|---:|---:|
| 0–50 m | town | 25,996 | 25,996 |
| 50–100 m | town | 360 | 360 |
| 100–200 m | town | 940 | 940 |
| 200–400 m | town | 10,531 | 10,531 |
| 400–800 m | town | 1,263 | 1,263 |
| 800+ m | town | 1,770 | 1,770 |

Every cell is 100% live. No band, including 800+ m (up to 1276.6 m), ever
showed a sustained (3+ consecutive tick) suspension near the joiner.
(observed)

## 2. Moments

- **14:36:28** — leash CSV appears; recorder starts writing (`mp_leash_trace
  on` was live by then).
- **14:36:43** — one NPC (`ttkc_woman_10`) read `moved_1s=0 phys_sim=0` at
  67 m host-joiner / 47 m from joiner, brain mask `00`, state `0` — i.e. the
  game itself says not suspended. This was the monitor's *first* classifier
  (moved-only), which produced a false "not-live" reading; fixed mid-session
  to gate on the brain-suspension bit instead. Kept here as a caution: a
  single idle/standing tick looks identical to a suspended one (matches
  WO-127 §4.3's "hidden != stopped"). (observed, then corrected)
- **~14:37:30** — the session's farthest separation, 1276.6 m (host outside
  the settlement, joiner inside it). NPCs near the joiner at this moment
  were still all live by the brain-suspension signal. (observed)
- **14:40:16–14:40:21** — a fight ends and restarts within 5 seconds, host
  5–7 m from the joiner; this is also the window with the largest sinking-body
  cluster of the session (see 0.30.0-session-notes.md). (observed)

## 3. What the joiner saw

Not answerable — joiner-side files weren't collected this session.

## 4. Coverage

- **Distance**: 0.6–1276.6 m covered, avg 149 m, 585 one-second summary
  samples over ~587 s (~9.8 min) of trace time. Good coverage of "close
  together fighting"; only one brief excursion into the 800+ m band, and it
  wasn't held there deliberately (no "wait 30 s" pause at distance).
- **Context**: town only, for the whole session (by the joiner's own
  location). Wilderness, indoors and riding are all uncovered — the joiner
  never left the settlement.
- **Duration at any one band**: mostly seconds to tens of seconds per
  excursion; nothing held at a fixed distance long enough to call a fade
  vs. hard-edge judgment for anything past 200 m of the joiner.
- Overall: (inconclusive) for the WO-128 question as originally framed. The
  session does answer a *related* question cleanly — host-joiner distance
  alone, up to 1.3 km, does not suspend NPCs near the joiner — but that's a
  different claim from "found the edge."

## 5. Inputs for WO-114

- The native teleport exists (WO-113) and should be preferred over any new
  leash mechanism if a real per-joiner edge is later found.
- Respawn-within-leash is moot until an edge is actually measured (see §0).
- The scan's two anchors stay cheap (§0) — a leash mechanism doesn't need to
  economize on anchor count for performance reasons based on this data.
- **Recommendation**: re-run WO-128 with the joiner deliberately riding
  200–1000 m *away from their own last position* (not just away from the
  host) and holding there, sampling in wilderness and indoors too, and this
  time collect the joiner's own CSV/logs afterward so the cross-comparison
  in the original brief can actually run.
