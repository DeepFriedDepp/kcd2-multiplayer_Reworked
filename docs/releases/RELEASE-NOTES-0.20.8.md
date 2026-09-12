# KCD2-MP 0.20.8

The label for everything on `main` as of WO-84 (2026-09-12), packaged as
`KCDMP-Setup-0.20.8.exe` plus the update-only `KCDMP-DirectInstall-0.20.8.zip`.

One session lands here: **WO-84**, which took three symptoms out of the first
real two-player field session and traced them to their causes. 0.20.6 shipped
the agent- and relay-side halves of WO-78/80/81 but was built before WO-84
existed, so **every fix below is new in this build**.

**Verification status, stated plainly:** all four fixes were proven in
synthetic tests against the real code — 72 new checks, plus the two existing
suites still green at 35/35 and 48/48. **None of it has been watched by a human
in a live two-player session.** The findings behind it, however, are not
speculative: they were read out of three real field logs totalling 550,000
lines, and three of the assumptions this work started from turned out to be
wrong and are corrected below.

---

## The headline: ghosts were being animated 50 times a second

Every connected ghost had its animation restarted on **every 20 ms tick** —
50 calls a second for someone standing still, about 100 for someone on
horseback. The NPC-puppet renderer does the identical job **once a second**.

The field logs show what that cost. Out of 9,192 animation-queue overflow
errors in one 150,000-line session, **9,037 belonged to a single entity: the
other player's ghost.** Every other character in the world — the whole village,
every animal, every guard — accounted for 155 between them. The other machine
showed the same shape on its own ghost.

It is worse during menus. While you have a menu, map or inventory open, the
mod keeps other players' ghosts moving by pumping updates in from outside the
game's frozen timers — measured at **62 to 100 frames per second** in that
session's own logs. Each of those frames queued another animation into a system
that was paused and therefore not consuming any of them.

This was never a deliberate design. It was introduced in a February commit
titled "Animation fix ??" that deleted the guard the ghost renderer originally
had.

**Fixed.** A looped animation now restarts when it actually changes, plus a
one-second keep-alive — the same rule the NPC path has used since 0.14.4, with
one addition it does not need: the check compares the *clip*, not just the
movement state, because "standing still" maps to two different clips depending
on whether that player has their weapon drawn. Pumped menu frames get the
change-driven restart and never the keep-alive.

Measured: a stationary ghost over two seconds goes from **101 animation calls
to 3**. Two seconds of menu pumping goes from 160 to 1.

If it behaves worse for you, `mp_ghost_anim_refresh 0` in the console restores
the old behaviour exactly, so it can be compared back to back on one build.

**What this does not promise.** Whether this resolves the reported "animation
isn't smooth" complaint in general is *not* established. It removes a large,
measurable source of animation-system churn. Jitter also has separate causes
already being worked (the 0.20.2 and 0.20.6 interpolation work), and only a
live session can say how much of the complaint this accounts for.

## A second kind of update-loop leak — one 0.20.6 could not have caught

0.20.6 fixed update-loop duplication caused by the mod mistaking a *suspended*
timer for a dead one. That fix is working. This is a different mechanism, and
the 0.20.6 gate is bypassed by design in this case.

When the NPC sync loop runs out of NPCs to drive, it stops itself — but it has
already scheduled its own next tick. If a packet arrives inside that window the
loop legitimately restarts at once, and the already-scheduled tick from the old
loop then wakes up inside the new one and gets reported as a leak it did not
cause. A menu widens that window from 50 milliseconds to the length of the
menu, because everything is released together when the menu closes. That is
exactly what the field log shows, 21 lines after a map screen closed.

**Fixed.** A loop that stops itself now retires its own pending tick, which
exits quietly instead of being blamed. Genuine leaks still report and still
raise the on-screen toast — and are now *counted* separately, so a second leak
is no longer hidden behind the first. The same protection is applied to the
ghost renderer as a precaution; that one has never actually been seen to
happen and is labelled that way in the code.

## Old ghost bodies left behind in your savegame

If you save while another player's ghost is standing near you, that body is
written into your save. Load it later — a different session, days later, a
different mod version — and it comes back as an empty shell that belongs to
nobody. The game logs a stream of errors about it on every single load: 265 of
them on one machine in that session, 266 on the other.

The sweeper for this was written back in 0.18.x and was correct. It had one
problem: **nothing ever called it during play.** It only ran when you shut the
mod down or typed a console command, so in three recorded sessions it never ran
at all.

**Fixed.** It now runs every 30 seconds off the check the agent was already
making, confirms a body over two passes before removing it so it can never
touch a live ghost, and covers all 64 possible player slots instead of the
first 32. `mp_ghost_sweep off` disables it; `mp_ghost_sweep now` forces a pass.

**Honest limit:** whether such a body actually *stands* in your world for the
rest of the session, or whether the engine quietly drops it, is genuinely not
established from the logs — there is no line either way. The sweep now reports
what it finds, so the first session that runs it settles the question.

## Three things we believed that were wrong

Recorded because they were stated confidently before this session and are not
true:

* **"A ghost had no faction for the whole session."** No. The live ghost never
  throws that error. On the machine where the two could be told apart, all 265
  errors named a ghost that machine never created — the save-restored body
  above.
* **"No timers were suspended when the leak happened."** They were, for 19.2
  seconds. The clue was being read from the wrong field of the mod's own log
  line.
* **"The animation storm is specific to that one character's soul."** It is
  not. Both machines, two different souls, two different animation clips, and
  no code path that branches on the soul at all.

Also checked and ruled out: the missing faction has **nothing** to do with the
animation storm. Neither live ghost ever threw a faction error, and the storm
is fully explained without one.

## Also in this build

* The ghost's faction assignment at spawn is now **logged**. It was two
  statements inside one silent error-swallowing wrapper, so in the project's
  whole history no log has ever said whether either of them did anything. It
  still behaves identically — this only makes it visible. (The engine's own
  warning elsewhere shows the faction name the mod uses is one the game
  rejects; that is recorded, not blindly changed, because previous work
  established the character's own soul overrides it anyway.)
* `tools\Verify-Install.ps1` — the script that proves an install actually
  landed — had not been updated since 0.11.x. Four releases of work shipped
  with nothing in it able to tell a new build from an old one, which is the
  exact half-applied-install failure it exists to catch. It now checks for
  0.20.6's and 0.20.8's features in both the mod pak and the agent and relay
  assemblies: **19 markers, all verified present in this build.**

## Console commands added

| Command | Effect |
|---|---|
| `mp_ghost_anim_refresh <seconds>` | How long a ghost's looped animation plays before a keep-alive restart. `0` restores the pre-0.20.8 behaviour. |
| `mp_ghost_sweep on\|off\|now` | The stray-body sweep: disable, re-enable, or force a pass immediately. |

## Upgrading

`KCDMP-Setup-0.20.8.exe` is the full installer. `KCDMP-DirectInstall-0.20.8.zip`
updates an existing install in place (`App\` and `Mod\`).

Close the game, the launcher and the relay before installing — a file held open
by a running process is how 0.11.8 shipped half an install. After installing,
`tools\Verify-Install.ps1` will confirm all 19 feature markers and re-check
every shipped file by SHA-256.

**Both players must be on the same version.** The animation and sweep changes
are local, but the mod compares release versions on connect and mismatches are
reported in the launcher.

## Reading further

* `docs/WO-84-findings.md` — the full evidence, with every claim labelled
  observed, code-verified or inconclusive, and the open questions a live
  session still has to answer.
* `docs/WO-84-progress.md` — what was done, what was deliberately not done, and
  what remains unverified.
