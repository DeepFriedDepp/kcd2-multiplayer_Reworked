# Session prompt — finish WO-4 (shared combat) — SUPERSEDED

**Do not paste this into a new session.** WO-4 is complete: the pipe bug this
document describes as blocking was fixed on 2026-07-28 (`b8ffaae`), and the
launcher and master-server work it defers was done in `54af330`.

Its four hypotheses for the pipe bug were all wrong, which is worth knowing if
you are reading it for background — the cause was a synchronous pipe handle
serialising the game thread's write behind the serve loop's parked read.

Use instead:

- `SESSION-PROMPT-next.md` — the current copy-pasteable prompt.
- `WO-4-completion-report.md` — what was done, and what was and was not verified.
- `HANDOFF-WO4-combat.md` — the operational picture.

The original text is in git history: `git show c6b664b:docs/SESSION-PROMPT-wo4-continue.md`.
