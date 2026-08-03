# KCD2 Multiplayer — 0.10.0

`VERSION` went `0.9.2` → `0.10.0` for this release. Both `0.9.5` (NPC aggro)
and the launcher work below were built earlier but never actually published
as a GitHub release — the last one that shipped was `0.9.2-beta`. This
release folds both in together, so nobody who only follows the Releases page
misses either.

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
  with two different answers. The ghost itself never fights back — that's
  the limit above, confirmed, not going to change by itself. But shared
  combat (already shipped, unrelated to this toggle) means that when your
  friend lands a real hit on an NPC *in their own game*, that damage already
  applies to the same NPC in your world too. So an NPC both of you are
  actually fighting, each in your own game, genuinely can take damage from
  both of you — the ghost standing there doing nothing visually is not the
  same as "your friend's hits don't count."

  Genuinely unverified, watch for it: whether the NPC's AI correctly turns to
  fight the nearer real player once it's hurt a ghost (attacker attribution
  on a relayed hit is a known gap), no animation sync (the ghost won't
  visibly swing while its side of the damage lands), and every test so far
  used a synthetic peer standing in for a second player, not two real people
  at real latency.

- **The launcher has a real visual identity now**, instead of ad hoc colours
  picked per component. The palette — aged parchment, oak, iron, candle-warm
  gold, tavern shadow — is pulled directly from the in-game dice overlay's
  own art direction, so the launcher and the in-game UI read as one product.
  Covers the whole app: home screen, status bar, filters, server list, every
  modal. Along the way: keyboard focus is now visible everywhere (it wasn't,
  anywhere, before this), and the version shown in the status bar is the
  actual shipped version rather than a stale leftover placeholder.

- **A "Report Bug" button**, next to Host Game in the status bar. Opens
  either the GitHub Issues page or this project's Discord, whichever you'd
  rather use — no need to go dig up either link yourself.

- **A friendly heads-up when you and your host are on different versions.**
  If you connect to someone running a different release than you — but your
  builds are still wire-compatible — you'll get a small notice saying which
  of you needs to update, with a direct link to the releases page. This is
  new and separate from the existing hard "these builds can't talk to each
  other at all" refusal, which still works exactly as before: this only
  covers the friendlier case where the connection *would* work, but you're
  not both on the same build.

Everything else carries over unchanged from 0.9.2 — see the main
[README](../../README.md) for the full feature list and current status.

## Already installed? Update in 2 steps — no reinstall needed

Everyone you play with needs this update, not just the host — an old and a
new version won't connect to each other.

Download **`KCDMP-DirectInstall-0.10.0.zip`** from this release, then:

1. Copy the **`App`** folder's contents into your existing install folder
   (`%LocalAppData%\KCDMP` — paste that into Explorer's address bar),
   overwriting when asked.
2. Copy the **`Mod`** folder's contents into your game's mod folder
   (`<your KCD2 Modding Tools folder>\Mods\kdcmp`), overwriting when asked.

Close the launcher first. That's it — no need to run Setup.exe again, and
nothing else on your PC is touched. (Prefer a full reinstall instead? The
`KCDMP-Setup-0.10.0.exe` in this release does that too, and keeps your
settings.)
