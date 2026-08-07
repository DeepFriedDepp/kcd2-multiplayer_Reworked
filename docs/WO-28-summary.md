# WO-28 — session summary

**Date:** 2026-08-07 · **Branch:** `main` · **Commit:** `c13604e` (pushed)

The short, shareable version. Full evidence and reasoning:
[`WO-28-findings.md`](WO-28-findings.md). Blow-by-blow account:
[`WO-28-progress.md`](WO-28-progress.md).

`VERSION` untouched, per [`VERSIONING.md`](VERSIONING.md) — **the version
number for this release is the human's to choose.** The "What's new" section
below is written to drop in under whatever number gets picked. WO-27's release
notes were also deliberately left unshipped and should go out with this one;
[`WO-27-summary.md`](WO-27-summary.md) has that language ready.

---

## What was done

Implemented [`WO-26-shared-combat-design.md`](WO-26-shared-combat-design.md)'s
three flows — a player's own health reaching everyone else, NPC hits crossing
between players, and death — and, unplanned, fixed two long-standing bugs that
the required pre-work uncovered.

Four things, in order:

1. **Investigated what a mid-session save reload actually does** before
   building the death flow on an assumption about it. This was the WO's own
   Phase 0 and it was expected to be groundwork. It found two real defects,
   live since WO-13.
2. **Fixed both**, and re-verified against the fixed build with a second live
   reload.
3. **Built the three flows** — continuous player health, NPC→player hits,
   and death — with the wire protocol extended by seven type bytes.
4. **Confirmed the design doc's own recommendation** on what a ghost's AI
   should do about its own attacks (leave it) is still right, given what the
   other three phases turned up.

## The finding worth knowing about

The reload investigation was meant to be a checkbox. It was the most valuable
part of the session.

A mid-session save reload leaves the relay connection completely untouched and
never tears down the mod's Lua state. But it kills all three of the mod's timer
chains while their "is this running?" flags stay reading `true` — and only two
of the three ever came back. The third was the **emitter**, which is a client's
only outbound channel. So a player who loaded a save stopped transmitting
anything at all and simply vanished for every other player, for the rest of the
session. Measured at 197 seconds and still going when the test window ended.

Separately, the same reload destroyed every *other* player's ghost body in that
player's world while the mod carried on believing it still had them — producing
a floating nameplate walking its path with nothing underneath it, indefinitely.
The human, watching it happen live: *"the ghost is invisible for me but I can
see its nametag continuing in the same path."*

Both had been shipped since WO-13, and WO-13's own partial fix is what hid
them: ghosts visibly recovering after a reload made the whole thing look
handled.

Both are fixed and both now recover on their own in about 14 seconds,
confirmed by instrument and by eye.

## What's new (release-note material)

- **Other players' health now shows above their heads.** Every player's own
  health and stamina reach everyone else, so a companion's ghost displays their
  real `HP`/`ST` on its nameplate instead of looking permanently healthy while
  its owner is being beaten to death somewhere else. Health comes from the
  player it belongs to and nobody else — your own game is the only thing that
  decides how hurt you are.

- **Death is now shared, and it works the way single-player does.** When a
  player dies, their own game announces it (it is never guessed from their
  health hitting zero) and everyone else sees their character tagged
  **`[dead - reloading]`**. That player reloads their own most recent save,
  exactly as in single-player. **Nobody else's world reverts** — every player
  has always had a completely separate save, and this mod has never had, and is
  not getting, a way to push one player's save into another's. Their character
  simply reappears wherever their save point puts them, and the tag clears
  itself once they're back.

- **NPCs can now hurt a remote player, not just their stand-in.** When an NPC
  attacks your character in someone else's game, that damage is reported back
  and lands on the real you. Exactly one player's game is in charge of this at
  a time — otherwise everyone's NPCs would independently damage everyone and
  multiply the damage by the number of players in the session. *Built and every
  safeguard around it verified, but the hit actually crossing two machines has
  not been tested — there was one machine and no second player. Treat this one
  as untested in real play.*

- **Loading a save mid-session no longer breaks you for everyone else.** This
  is the big fix. Previously, loading a save permanently stopped you
  transmitting — you vanished for every other player for the rest of the
  session, with nothing on your own screen to suggest anything was wrong — and
  destroyed every other player's character in your world, leaving their name
  floating around with no body under it. Both now sort themselves out in about
  14 seconds. This matters far beyond dying: it affected *any* save load, for
  any reason, and has done since an early update.

- **A mixed-version session degrades instead of breaking.** If one side is on
  an older mod file than the other, health simply doesn't show for that player;
  position, movement and everything else keep working normally.

## Honest limits, unchanged by this release

- **This does not synchronise NPCs.** Each player still sees their own version
  of a fight. What is shared is who got hurt and who died — not the battle
  itself. That remains a much larger problem than this work.
- **Whoever holds NPC-damage authority matters.** If their game is paused or
  the NPCs near them aren't running, NPC-versus-player combat stops mattering
  for everyone. Authority moves automatically if that player disconnects, but
  not if they're simply idle.
- **A ghost's own attacks are still unreplicated.** A remote player's character
  can kill NPCs in your world that its owner never attacked. Deliberately left
  alone this release — see §5 of the design document; suppressing it needs a
  mechanism nobody has found yet.
- **No second-player verification.** As with shared combat and appearance sync
  before it, everything here was verified on one machine with synthetic peers
  plus a real game. The genuinely two-machine step is called out as untested
  rather than quietly implied to work.

## Loose end for whoever picks this up

**Three test scripts had silently drifted off the protocol version and could
not connect at all** — `Test-AppearanceE2E.ps1` pinned 5, `Test-CombatE2E.ps1`
pinned 3, `Bot-DiceOpponent.ps1` pinned 4, against a relay speaking 6. The
relay refuses a mismatch outright, so these did not fail subtly; they could not
handshake. Fixed by deriving the number from `Protocol.cs` in a shared
`tools/ProtocolVersion.ps1` rather than copying it into eleven scripts, since
three independent drifts is a mechanism problem rather than three typos.

**That fix made a real, previously-invisible failure visible.**
`Test-AppearanceE2E.ps1` now connects and runs the whole flow, and reports
**2 of 5 item classes never equip** (`belt_2slot` and `GambesonShort02`) —
reproducibly, at the default settle window as well as a shortened one, so it is
not the known "equips take a while under load" flakiness.

This is **not a WO-28 regression**: the WO-28 diff contains zero changes to the
appearance path (every appearance mention in it is a comment or unchanged
context). The likeliest explanation is the same slot-exclusivity the script's
own header already documents for `Hood08` — a ghost's spawn-time outfit
occupying the slot — which would have changed shape in WO-22 when ghosts began
inheriting their roster soul's own appearance. That is a guess and is labelled
as one; nobody could run this test to find out until now.

**It deserves its own investigation and was deliberately not folded into this
WO.**
