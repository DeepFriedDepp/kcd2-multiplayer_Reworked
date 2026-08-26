# KCD2-MP 0.18.2

The label for everything on `main` as of WO-60 (2026-08-26). Everything since
`0.17.5`: the WO-59 fix set (nine post-0.17.5 reports) plus WO-60's new NPC
tracking model. Update **both machines together**, as always — these changes
span the agent, the relay and the mod pak.

## New in this build: NPCs are tracked by whoever is actually near them (WO-60)

Until now, every synced NPC was tracked from wherever the **host** stood. An
NPC fighting the joining player 100 m from the host was never synced at all —
the host would see their friend "fighting nothing" (a real report, twice).

Now the joining player's machine also tracks NPCs near **its own** player and
streams them to everyone, using the same claim system that already handled
dragged bodies. A claim on an NPC that is actively being fought is **held**:
it cannot bounce to the other machine through a brief packet gap (a menu
pause, a short stall), which is the mechanism behind the old
NPC-teleporting-between-two-positions jitter.

**The rollback, if this build behaves worse than 0.17.5 for you**: open the
console on the joining (non-host) machine and run

    mp_npc_proximity off

That restores the old host-only tracking within seconds, no reinstall. If you
use it, please say so in your report.

Honest status: the claim/hold arbitration is machine-verified against a real
relay (35/35 wire tests, including two simulated players hammering the same
NPC); **no live two-machine session has run with it yet**. You are that test —
which is why the off switch exists.

## Fixed since 0.17.5 (WO-59)

- **One-way clothing sync** (peer stops seeing your outfit changes): two
  causes fixed — a busy host could send a half-read outfit as a real change
  (peers saw you half-stripped), and one timed-out check on the receiver
  permanently blacklisted whole clothing batches. Failed reads now prove
  nothing, and blacklists expire after 10 minutes. A one-way clothing freeze
  longer than ~10 min on this build is a new bug — collect logs on the
  machine that cannot see the changes.
- **Day/night divergence when connecting with saves from different dates**:
  there was no clock exchange at connect at all. Both sides now announce
  their clock on connect; the player behind in time is pulled forward within
  ~10 s ("Clock synced forward to the session's time").
- **Invisible after a reload**: standing perfectly still no longer makes you
  unspawnable to a peer who reloaded (2 s position heartbeat), and a ghost
  body embedded in a save can no longer impersonate the live one (identity
  check + respawn).
- **NPC jitter at the tracking edge**: NPCs near the 30 m boundary no longer
  flip between tracked/untracked every 2 s (hysteresis; tracked NPCs stay
  held to 45 m).
- **Ghost catching you stealing**: ghost deafness is now re-asserted every
  few seconds and logged, instead of being applied once and never checked.
  If a ghost still reacts to a crime, collect logs — the log lines now prove
  which of two remaining explanations is true.
- **FPS reports are now diagnosable**: the game log carries `tickstat`
  frame-time lines whenever FPS is genuinely low. Note whether an alt-tab
  preceded a drop, and Collect Logs **during** the episode.

## Known limits in this build

- Proximity tracking changes joint-combat dynamics on every session and has
  not been observed live — see the rollback above.
- A claimed NPC's health still converges by damage events only; simultaneous
  kill/loot arbitration remains unhandled (unchanged since 0.14.x).
- Animals (chickens, dogs, deer) do not sync — by design, not a bug.
- Everything here needs both machines on 0.18.2 (the launcher's version
  indicator works — check it).
