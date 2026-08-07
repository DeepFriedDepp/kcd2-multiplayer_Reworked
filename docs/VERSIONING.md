# Versioning — the user owns the version number

Written 2026-07-31, in WO-14, after two sessions in a row picked a version
number on their own judgement. This is a hard rule, not a preference.

---

## The rule

1. **Version numbers are chosen by the user, exclusively.** No session
   auto-increments `VERSION`, ever — not even when the next number looks
   obvious.
2. **Any session about to touch `VERSION`, or about to run
   `tools\Build-Installer.ps1` or `tools\Build-DirectInstall.ps1`, asks the
   user for the exact target version string first and waits for an explicit
   answer.** Blocking is correct here: a wrong version ships under a label
   the user did not choose and cannot be recalled once anyone downloads it.
3. **"Bump to X" means X is the label for the current state of `main`.** It
   does not necessarily mean an increase over the last value. A session must
   not reinterpret a stated version as a typo, "round it up logically," or
   pick a different number because the stated one looks lower, reused, or
   otherwise wrong. If a stated version genuinely collides with one already
   shipped, **say so and ask** — do not silently pick another.
4. `VERSION` is the single source of truth. `Build-Installer.ps1` and
   `Build-DirectInstall.ps1` both read it and nothing else, so the Setup exe,
   its Add/Remove Programs entry, its Win32 version resource and the
   DirectInstall zip cannot drift apart from each other.

## Why this rule exists — it is not hypothetical

It has already gone wrong twice on this project, in two different ways.

**The unprompted increments.** WO-9 set `VERSION` `0.8.0` → `0.9.0` and WO-10
set it `0.9.0` → `0.9.1`, both on the session's own judgement, neither asked
for. Nothing about either number was wrong, exactly — but nobody chose them,
and a release label is not a session's to invent.

**The label that never existed.** `RELEASE-NOTES-0.8.5-Beta.md` sat at the
repo root describing the armor-sync release under the version `0.8.5-Beta`.
`VERSION` never held that string: it went `0.8.0` straight to `0.9.0` for that
exact work. A `release\KCDMP-Setup-0.8.5.exe` (no `-Beta`) exists on disk from
the same period, matching neither. Three labels, one release. Resolved in
WO-14 by renaming the file to
[`docs/releases/RELEASE-NOTES-0.9.0.md`](releases/RELEASE-NOTES-0.9.0.md) —
the version it actually shipped under — with the mismatch documented in the
file rather than quietly erased.

## Real version history

Confirmed from `git log --follow -- VERSION`, not assumed:

| Version | Commit | Content |
|---|---|---|
| `0.8.0` | `5447c34` | WO-8 — the installer itself |
| `0.9.0` | `4fd2ff8` | WO-9 — armor / appearance sync |
| `0.9.1` | `10ad471` | + WO-10 — weapon sync, injection liveness fix |
| `0.9.2` | WO-14 | + WO-13 — ghost-freeze fix, `[in menu]` tag. User-chosen. |
| `0.9.5` | WO-17 | + WO-15/16 — NPC aggro on ghosts (opt-in). User-chosen. Never published as its own GitHub release. |
| `0.10.0` | WO-19 | + launcher visual refresh, bug-report modal, version-mismatch notice. User-chosen. First release to actually publish everything since `0.9.2` — see `docs/releases/RELEASE-NOTES-0.10.0.md`. |
| `0.11.5` | WO-29 | + WO-20/22/26/27/28 — real per-player ghost faces, the soul/brain fix and reactive combat, reconnect + launcher duplicate-agent fixes, shared player health/death/NPC-hits, and both save-reload bugs. User-chosen. See `docs/releases/RELEASE-NOTES-0.11.5.md`. |

`0.9.2` was stated by the user explicitly. It is the label for everything on
`main` as of WO-14 — WO-9, WO-10 and WO-13 together — not an increment
derived from `0.9.1`. `0.9.5` and `0.10.0` were likewise stated by the user,
not derived.

## Building a release

Both steps read `VERSION`. Run them in this order; the second reuses the
publish the first already did:

```
powershell -ExecutionPolicy Bypass -File tools\Build-Installer.ps1
powershell -ExecutionPolicy Bypass -File tools\Build-DirectInstall.ps1 -SkipPublish
```

Produces `release\KCDMP-Setup-<version>.exe` (full install) and
`release\KCDMP-DirectInstall-<version>.zip` (update-only, `App\` +
`Mod\`). Building them is a session's job when asked; **uploading, publishing
or otherwise distributing them is the user's, always.**
