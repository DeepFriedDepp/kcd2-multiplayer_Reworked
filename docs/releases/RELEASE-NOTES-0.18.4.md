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

This build ships the first half of the fix, ported from a source read of
KCD2Online (WO-64): **`mp_probe_contexts`**, a read-only console command that
dumps whether the script-context isolation surface
(`Contexts.SetPersistentOption`, `soul:RestrictDialog`,
`human:InterruptDialogs`, `soul:HasScriptContext`, and the seven
`switch_disabled*`/`crime_disableReport` context names) actually exists on
our game build. All seven context names are confirmed as real rows in the
game's own tables; the setter is the open question the probe answers.

The isolation feature itself (`mp_ghost_isolate`, default on) lands once the
probe's live output is recorded — probe first, feature second.

Honest status: nothing in this build changes ghost behaviour yet.
`mp_probe_contexts` is write-free. See `docs/WO-65-progress.md` for the full
evidence trail.
