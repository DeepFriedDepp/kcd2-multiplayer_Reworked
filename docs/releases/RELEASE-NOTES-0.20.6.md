# KCD2-MP 0.20.6

The label for everything on `main` as of WO-81 (2026-09-11), packaged as
`KCDMP-Setup-0.20.6.exe` plus the update-only `KCDMP-DirectInstall-0.20.6.zip`.
Three sessions land here together — WO-78 (the chain-leak fix), WO-80
(cutscene pause detection), WO-81 (relay claim diagnostics) — none of them
previously built or installed.

**Verification status, stated plainly:** every fix in this build was proven
correct in synthetic tests or by replaying real historical field data through
the actual compiled code. **This is the first build where any of it runs in a
real, live game.** Nothing here has been confirmed by a human watching a
live two-player session yet — that is the maintainer's own next step, not
something this release substitutes for.

## The headline: the chain leak is root-caused, not just dampened

0.20.2 shipped a smoother NPC-puppet renderer, but the first real two-player
field session that followed found something upstream of it: every menu,
inventory screen, dialogue and cutscene lasting more than a second made the
mod believe its own Lua timers had died, so it started a whole new set on top
of the ones that were only ever suspended. Several of these running at once
is the "two steps forward, jitter, one step back" that got reported — not the
renderer being wrong, but multiple renderers fighting over the same ghost or
NPC.

Fixed at the cause: a restart is no longer decided by "the heartbeat looks
stale" alone. A one-shot probe now confirms a chain is *actually* dead before
anything restarts it — a suspended chain resumes on its own and the restart
is refused. The **ghost** renderer (not just the NPC puppet one) now also
advances by real elapsed time rather than a fixed per-tick step, so even a
leaked or duplicated chain renders the same trajectory as a single one would.
Both stale-chain safety exits (`mp_npc_chainfix`, and the new
`mp_ghost_chainfix`) default **on**, and a `GHOST CHAIN LEAK CONFIRMED` /
`NPC-SYNC CHAIN LEAK CONFIRMED` line now also raises an on-screen toast, so a
human sees the condition mid-session instead of finding it in a grep
afterwards.

This likely further smooths **both** NPC puppet movement and ghost movement
beyond what 0.20.2 shipped — the same underlying defect touched both paths.
**Verified synthetically only** (`Test-GhostInterpSynthetic.ps1` 35/35,
`Test-NpcSmoothSynthetic.ps1` 48/48); not yet watched live.

## Cutscenes no longer freeze a connected ghost — dialogs still do

Since WO-13, a connected ghost kept moving through your own menus and
inventory screens instead of freezing. A real cutscene was never covered by
that fix, and the same field session caught a ~60-second cutscene freezing a
ghost solid, exactly like a menu used to. The agent's pause detector now also
recognizes a `Rendered`-type cutscene (the other cutscene types checked
against real field data — `Fader`, `SkipTime`, `Text` — don't actually freeze
anything, so they're deliberately not treated as pauses) and engages the same
interpolation pump menus already get.

**Dialogs are explicitly not covered by this fix.** The log markers that
looked like candidates turned out to be ambient NPC chatter and audio
streaming noise, not a boundary on the local player's own dialog state, and
were rejected rather than shipped on weak evidence. A real fix needs a live
probe of the documented `human:IsInDialog()` bind first — no game was
reachable to do that this session. Until then, a connected ghost still
freezes through your own dialog, the same as before this release.

Confirmed by replaying the real ~60-second field-log stall through the actual
compiled detector code, not just by inspection; not yet seen in a live game.

## New relay diagnostics (mostly invisible to players, but real)

A field report said NPC jitter seemed to get worse specifically when two
players stood close together, "as if it fought over authority" — but the
relay's NPC-claim table had never logged a grant, release, or reassignment,
only a rejection. It can now be watched instead of inferred:

- **`[CLAIM] granted / released / reassigned`** lines for every claim
  transition, plus counters at `GET api/information/npc-claims`.
- **`[CLAIM-CONTESTED]`** fires when a claim changes hands quickly enough
  that it looks like two players' machines were actually fighting over the
  same NPC, and reports the distance between the two players when both have
  reported a position recently.
- **The relay now writes its own log file** (`relay<date>.log`, next to
  `KcdMpServer.exe`, daily rolling) — it never did before, so a relay's own
  console output was never actually captured for a bug report unless someone
  remembered to copy it by hand. The launcher's **COLLECT LOGS** button now
  bundles it automatically, host-side only (a joiner or an install that's
  never hosted just has nothing there to collect).

This changes no claim decision anywhere — every gate the relay already
enforced behaves identically. It only makes those decisions visible.
Wire-verified only (`Test-NpcClaimLifecycle.ps1`, 28/28); the original field
report itself is not yet re-tested against a live session.

## If something looks wrong

Send, from **each** machine, via the launcher's **COLLECT LOGS** button
(now includes the relay's own log automatically, host-side):

- `kcd.log` — the game's log.
- The relay's log/console output (whoever hosted).
- `install-verify.txt` from the install folder if the install itself
  misbehaved.

Grep for: `GHOST CHAIN LEAK CONFIRMED` / `NPC-SYNC CHAIN LEAK CONFIRMED`
(should be absent — presence means the new gate failed), `CHAIN <key> was
suspended, not dead` (the gate correctly refusing a false restart), and
`[CLAIM-CONTESTED]` on the relay side if NPC jitter still seems to track two
players standing close together.

Protocol version is unchanged; no new packet types were added in this build.
Installing over 0.20.2 or any earlier version works the same way as always:
run the Setup, or unpack the DirectInstall zip and run its `Apply.ps1`.

Full evidence trail: `docs/WO-78-findings.md`, `docs/WO-80-findings.md`,
`docs/WO-81-findings.md`.
