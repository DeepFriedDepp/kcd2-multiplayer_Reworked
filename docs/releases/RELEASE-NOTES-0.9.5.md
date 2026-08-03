# KCD2 Multiplayer — 0.9.5

## New things

- **NPC aggro on ghosts — opt-in, off by default.** Turn it on with
  `mp_enable_aggro on` in the in-game console (`off` to turn it back off).
  Decided locally, just for you — your friend doesn't need to enable
  anything on their end for it to work on your screen. When it's on, a ghost
  that lands a hit or takes one gets treated as hostile by nearby NPCs for as
  long as the fight is active, then goes back to being invisible to them
  ~20 seconds after things quiet down — the same way it's always worked when
  the toggle is off.

  **What it actually is, honestly:** NPCs can now notice and attack a
  ghost. It is **one-sided** — the ghost can be hurt, it can't hit back — and
  a long fight can leave the ghost stuck on the ground looking stuck, even
  though the game still considers it alive. Both are known, disclosed v1
  limits, not secrets. Full detail, evidence, and the complete limitations
  list: [docs/WO-16-release-candidate.md](../WO-16-release-candidate.md) and
  the README's status section — not repeated here.

  **An important distinction for anyone testing this with a real second
  player, not a stand-in:** "the ghost can't fight back" and "can both of us
  actually contribute to beating the same enemy" are two different questions
  with two different answers.

  The ghost itself never fights back — that's the limit above, confirmed,
  not going to change by itself.

  But shared combat (already shipped, unrelated to this toggle) means that
  when your friend lands a real hit on an NPC *in their own game*, that
  damage already applies to the same NPC in your world too. So an NPC both
  of you are actually fighting, each in your own game, genuinely can take
  damage from both of you — the ghost standing there doing nothing visually
  is not the same as "your friend's hits don't count."

  What's genuinely unverified, and testers should watch for specifically:
  - **The NPC may not know who hit it.** Attacker attribution on a relayed
    hit is a known gap (documented since the original combat work) — the NPC
    takes real damage but the game has no record of who dealt it. Whether
    its AI correctly turns to fight the nearer real player (Henry) as a
    result, or just takes an unexplained wound and keeps doing whatever it
    was doing, has not been tested.
  - **No animation sync.** The ghost will not visibly swing a weapon even
    while its side of the damage is landing — expect a real visual disconnect
    between what the ghost looks like it's doing and what's actually
    happening to the NPC's health.
  - **Every test of this feature so far used a synthetic peer script standing
    in for a second player**, not two real people playing at once with real
    latency, real independent decisions, and two real local AI simulations
    running side by side. That is exactly the situation this needs testing
    against — a script cannot surface what real simultaneous play will.

Everything else carries over unchanged from 0.9.2 — see the main
[README](../../README.md) for the full feature list and current status.

## Already installed 0.9.2? Update in 2 steps — no reinstall needed

Everyone you play with needs this update, not just the host — an old and a
new version won't connect to each other.

Download **`KCDMP-DirectInstall-0.9.5.zip`** from this release, then:

1. Copy the **`App`** folder's contents into your existing install folder
   (`%LocalAppData%\KCDMP` — paste that into Explorer's address bar),
   overwriting when asked.
2. Copy the **`Mod`** folder's contents into your game's mod folder
   (`<your KCD2 Modding Tools folder>\Mods\kdcmp`), overwriting when asked.

That's it — no need to run Setup.exe again, and nothing else on your PC is
touched. (Prefer a full reinstall instead? The `KCDMP-Setup-0.9.5.exe` in
this release does that too.)
