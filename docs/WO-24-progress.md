# WO-24 progress — three live checks WO-23 could only flag

Session run 2026-08-06. Game running throughout (`KingdomCome.exe`,
`KcdMpServer.exe`, `KCDMP_launcher.exe`, `localhost:1403` responding), human
present and playing. Save backed up before Phase 2/3. All shipped-code
prohibitions from the WO honored — nothing shipped changed.

## Coverage

All three phases run, in order, as specified. No phase skipped.

| phase | result |
|---|---|
| 1. `Dice` scriptbind liveness | **Live.** 8/9 methods present (`GetDice` absent). `SetScore` (additive, not overwrite), `HoldDie`, `RollDie` all confirmed real against a live match. `OverrideNextThrow`'s `tbl` shape untried-successfully — one guess, no effect, shape stays undocumented. |
| 2. Hostile soul, no `SchedulerProxyName` | **Worked.** Position byte-stable pre-engagement (60 s). Once a real NPC noticed it, killed 3 real named NPCs in town. New correction to WO-22: position stability only holds pre-combat — a soul-only ghost moves under its own power once real combat starts, proxy or not. |
| 3. `AI.AddPersonallyHostile`/`SetAttentiontarget` on soul-backed ghost | **No distinguishable additional effect.** Both binds fault-free and verified (re-confirms WO-20). Outcome (rapid engagement, ghost wins, real NPCs killed) matched Phase 2's soul-hostility-alone result; the test as specified couldn't isolate the binds' own contribution. |

## What's fixed

Nothing. This was a live-verification WO, not an implementation WO, per its
own explicit scope.

## What's a promising, flagged, untested lead for the next session

1. **`Dice.OverrideNextThrow`'s real `tbl` shape** — architecturally the
   strongest lead of this session. If recovered, the mod could drive the
   real native dice UI (`SetScore` already confirmed working) instead of the
   current Lua overlay.
2. **Soul-row hostility as a `KCD2MP_SpawnGhost` replacement** — Phase 2
   worked cleanly and is a real candidate to replace the native
   `SetParent`-attach mechanism's donor-soul fragility. Follow-up decision,
   not made this session.
3. **Isolating `AI.AddPersonallyHostile`/`SetAttentiontarget`'s own
   contribution** — needs a non-hostile-faction (e.g. commoner) soul with and
   without the binds, compared head to head. Phase 3's design (matching
   Phase 2's hostile-soul shape, per the WO) could not separate the binds'
   effect from the soul's own faction hostility.

## Real-world session cost

Phase 2 and 3 killed 5 real, named NPCs total (3 in Phase 2's town encounter,
2 in Phase 3's field encounter) on the human's actual test save
(`playline2`). A clean pre-test backup exists at `playline2_wo24backup`. The
human explicitly chose to let both engagements run to completion rather than
intervene, on the basis that this save is disposable for exactly this kind of
test.

## Files touched

- `tools/wo24-lua.ps1` (new)
- `docs/WO-24-findings.md` (new)
- `docs/WO-24-progress.md` (this file, new)
- Save backup: `playline2_wo24backup` (new, copy)

No changes to `kdcmp.lua`, `native/`, `dotnet/`, `VERSION`, or the installer.
