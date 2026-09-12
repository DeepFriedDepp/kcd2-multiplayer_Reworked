# KCD2-MP 0.20.9

The label for everything on `main` as of WO-83 (2026-09-12), packaged as
`KCDMP-Setup-0.20.9.exe` only. There is no `KCDMP-DirectInstall-0.20.9.zip`
for this release, by the maintainer's instruction.

One session lands here on top of 0.20.8: **WO-83**, which took one field
report out of the same two-player session WO-84 read — *"the other player's
ghost drew on me when I drew my weapon"* — and traced it to the game's own
data tables. Everything in 0.20.8 is still here unchanged.

**Verification status, stated plainly:** the cause was read out of the game's
own shipped tables and corroborated by the ghost's own voice lines in the
field log, and the fix was checked arithmetically against the face picker.
**Nothing in this build has been watched by a human in a live session.** The
game was not running when it was built.

---

## The headline: some ghosts were guards

Every ghost wears a real NPC's *soul* — that is what gives it a face, a voice
and a brain. The mod picks that soul from a fixed roster of nineteen, keyed on
your name, so you always get the same one.

Seven of the nineteen were the game's **authority figures**: three town
guards, three garrison soldiers with crime authority, and one gamekeeper
with crime authority. The game marks those classes with a crime role it
reserves for "authority figures", and an NPC in that role *enforces* the
drawn-weapon crime. So a ghost built from one of those souls behaved exactly
like a guard would: when the other player drew a weapon nearby, it warned
them in a guard's voice, and when they did not put it away, it drew and
fought.

That is what the field report described, and the logs show it in the ghost's
own lines. On the joiner's machine, the host's ghost was built from the town
guard `ttac_man_9`. Over the session it spoke the guard "I see you have a
drawn weapon" bark **13 times**, then the "put it away" follow-up, then
soldier combat barks — all attributed to the ghost itself. On the host's
machine the joiner's ghost was built from a plain soldier soul with a
civilian crime role: it spoke that bark **0 times**. Same mod, same session,
opposite behaviour, and the only difference between the two was the soul's
social class.

This is the third time a roster soul has turned out not to be neutral —
bandits were removed in 0.11.6 for carrying a hostile faction, and the female
table was removed in 0.18.8 — and it is the same underlying fact each time: a
borrowed soul brings the *whole* NPC with it, not just the face.

**What it is not.** It is not the faction. One of the game's own guards with a
*peasant* faction still barks the guard line; the joiner's ghost had a
*guards* faction and never did. It is the social class's crime role. The
earlier roster audit counted "four soldier-faction souls" and flagged the
consequence as unmeasured; counting by crime role finds seven, and the
consequence is now measured.

## The fix — and why your face probably did not change

The seven authority souls are gone from the roster. They were **replaced in
place**, not deleted: each of the seven slots now holds a commoner soul that
was already elsewhere in the list and was already read back from a running
game in 0.18.8. The picker chooses a slot by *position*, so deleting rows
would have re-rolled every player's face — 0.11.6 did exactly that, on
purpose, and this release deliberately does not.

Concretely, out of nineteen slots, **twelve are byte-for-byte what they were
in 0.20.8**. If your ghost was a commoner before, it is the same commoner now.
If it was one of the seven authority souls, it is now a specific commoner, the
same one every time. The fallback soul the mod uses when a spawn comes back
wrong was *also* a town guard; it is now a Troskovice hired hand.

The cost is variety: nineteen distinct faces become twelve for now. Twenty
candidate commoner souls for widening the list again are recorded in the
findings, but none goes in until it has been resolved against a running game,
because a soul the engine cannot bind produces a silent default body with no
error at all.

## What this does not fix

A ghost is still a real soul with a real home settlement. Attacking one still
counts as a crime against a real victim and still costs the attacker standing
with that settlement. WO-68 stopped ghosts *reporting* crimes against them;
this release stops them *enforcing* the law. Nothing in between changed.

## Also in this build

- `Verify-Install.ps1` gains one mod-side marker for the roster swap, so a
  half-applied install that still carries the old pak is caught by the
  existing check rather than by a guard drawing on you.
- The `kdcmp.pak` is rebuilt from the repo Lua as part of the installer
  build (the pak is tracked in git but is a build artifact). 0.20.8's pak predates WO-83.

## Console commands added

None. There is nothing to toggle; the roster is data.

## Upgrading

Run `KCDMP-Setup-0.20.9.exe` with the game, the launcher, the agent and the
relay all closed. It replaces the app and the mod folder wholesale and
verifies both by manifest afterwards.

If your ghost's face changes, you were one of the seven. Everyone else keeps
theirs.

## Reading further

- `docs/WO-83-findings.md` — the table rows, the bark counts, the slot-by-slot
  before/after and the candidate list, each tagged observed or code-verified.
- `docs/WO-83-progress.md` — the state of play and the runbook for the live
  check that has not yet run.
- `docs/WO-34-findings.md` §1 — the original audit of what a soul-backed
  ghost plugs into, which flagged this consequence as unmeasured.
