# KCD2-MP 0.18.4

The label for everything on `main` as of WO-65 (2026-08-27). No installer or
GitHub Release is published for this version — it labels `main` only. Update
from source if you want it before the next packaged release.

## In progress in this build: ghosts leaving the vanilla crime system (WO-65)

Since WO-34 we have known that another player's ghost is a **full crime
victim**: punch your friend in front of a guard and the game files a real
crime report, with real fines, real jail time and real settlement reputation
loss — against your actual save. The `Civilians` faction override never
worked.

This build ships what our game build actually allows of the fix, ported from
a source read of KCD2Online (WO-64):

- **`mp_probe_contexts`** — read-only console command that dumps the
  script-context isolation surface. Its live output settled the question:
  the seven `switch_disabled*`/`crime_disableReport` context names are real
  rows in our game's own tables, but **no Lua-reachable setter exists on our
  build** — `Contexts.SetPersistentOption` is a KCSE-lineage surface we
  don't have, and no alternative exists under any name.
- **`mp_ghost_isolate`** (new toggle, default **on**) — applies the
  reachable half on every ghost spawn: the ghost can no longer be talked to
  (`RestrictDialog`, live-verified with readback) and any dialog it is in is
  interrupted. Each of the seven crime contexts is honestly logged
  `missing-on-this-build` and skipped; if a future game patch ships the
  setter, this build lights it up without a code change. `off` cleanly
  removes the dialog restriction from live ghosts.

Honest status: **the crime-victim defect is NOT fixed by this build** —
punching a ghost in front of a guard still files a real crime. Fixing that
on this game build requires a native (KCDMP.dll) call into RPGModule's
context layer, proposed as a follow-up work order. See
`docs/WO-65-progress.md` for the full evidence trail.
