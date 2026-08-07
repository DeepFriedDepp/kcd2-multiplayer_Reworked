# WO-27 — session summary

**Date:** 2026-08-07 · **Branch:** `main` · **Commits:** `b631acb`, `911a515`, `af06d53`

This is the short, shareable version, written for whoever builds the next
release (WO-28) to pull player-facing language from without re-reading the
full investigation. Full evidence and reasoning:
[`WO-27-findings.md`](WO-27-findings.md).

`VERSION` untouched — by design, this WO's own scope. The human will fold
this into WO-28's release.

---

## What was done

Three things, in order:

1. **Finished an interrupted prior attempt.** `kdcmp.lua` already had an
   uncommitted, untested fix for ghost duplication on reconnect, sitting in
   the working tree with no findings doc — read it, verified it was
   correct, and confirmed it live rather than redoing it.
2. **Pinned down what `mp_enable_aggro` actually does**, live, in both
   toggle states — it turned out to be additive to WO-26's always-on
   reactive combat, not the thing gating whether ghosts fight at all.
3. **Caught and fixed a live incident before push**, unrelated to either of
   the above: the launcher could let two agent processes run simultaneously
   under one identity, and it just happened, live, during this session.

## What's new (release-note material)

- **Ghosts have always fought back — this is the first release to say so.**
  Since WO-22, a ghost has defended itself when attacked (treats it as a
  crime, arms itself, lands real damage) and joined a fight already
  happening nearby, with no toggle involved. This shipped over two releases
  ago and was never in the README's feature list as a player-facing thing
  until now.
- **`mp_enable_aggro` does something narrower than it sounded like it did.**
  It was never the switch that lets a ghost fight — that's always been on.
  What turning it **on** actually adds: a ghost that lands or takes a hit
  gets recognized as hostile by *any* nearby NPC of an opposing faction for
  about 20 seconds, not just whoever it's already fighting. Off (the
  default), a ghost still fights back, just without that wider recognition.
- **Reconnecting no longer leaves a duplicate ghost behind.** Previously,
  rejoining under a new connection could orphan your old ghost instead of
  replacing it — live-tested WO-26 found three registered ghosts for one
  player after repeated reconnects. Fixed: identity (not connection id) now
  decides which ghost is "yours," and removal is verified by reading the
  entity back rather than trusted on a single call.
- **The launcher no longer allows two agents to run for one player.** Found
  live, during this session: closing only the game (not the launcher)
  between actions could leave a stale agent running, and reconnecting
  started a second one on top of it — both fighting over the same ghost
  forever, visible in-game as an NPC seemingly attached to the player. The
  launcher now stops any existing agent before starting a new one.

## Corrections this session forces on prior docs

- **README's aggro "known limits" — "one-sided, ghost never fights back"**
  was already false as of WO-26 and had drifted uncorrected in two separate
  places in the file. Both fixed.
- **`docs/PROJECT-STATE.md` §4** — no correction needed, already carried the
  accurate WO-25/WO-26 amendments; this session's finding was added on top.

## The live incident, briefly

Not a leftover from testing — it happened *during* this session. Closing
the game to redeploy the Lua fix (see "Files touched" note below) left an
old agent process running; reconnecting started a new one under the same
identity without killing the old one. The two spent about ten minutes
fighting over one ghost, ~4,000 spawn events, which is what the human saw
as an NPC attached to their character. Killed the stray process to stop it
immediately, then fixed the actual gap in the launcher
(`StopExistingAgent()`, kills any existing agent — tracked or stray, by
process name — before starting a new one), and reproduced the failure
precondition afterward to confirm the fix holds, not just that it builds.

**Worth flagging for whoever writes the actual release notes:** this is a
real bug a real player could have hit (anyone who closes just the game and
reconnects without restarting the launcher), not a testing artifact, and
probably deserves its own bullet rather than being buried under the aggro
changes.

## A workflow note worth keeping

Editing `kdcmp.lua` does nothing to an already-running game — it loads from
`kdcmp.pak`, rebuilt and installed by `tools\Build-And-Install-Mod.ps1`,
which requires the game closed first. This cost real time mid-session (a
"fixed" function read back as `nil` live, because the fix was never
deployed) and directly set up the launcher incident above by requiring a
game-only restart mid-session. Recorded in memory for next time, not
repeated in the findings doc's main body.

## Open, unrelated to this WO

Everything WO-26 left open (`InterpTick` vs a fighting ghost, the shared
combat protocol, whether a ghost de-escalates) is untouched — this WO's
scope was verification and two bug fixes, not new mechanism. WO-28 is next.
