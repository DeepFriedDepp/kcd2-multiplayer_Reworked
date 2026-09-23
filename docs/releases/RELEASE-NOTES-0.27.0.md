# KCD2-MP 0.27.0 — death without Game Over

The label for everything on `main` as of WO-113 (2026-09-23), packaged as
`KCDMP-Setup-0.27.0.exe`. Setup exe only. **To go back:** the tag
`rollback/0.26.5` and `KCDMP-Setup-0.26.5.exe` — or, without reinstalling,
type `mp_respawn off` (or `mp_preset_legacy`) in the console.

**Both machines must run 0.27.0. The relay refuses anything else.** A 0.26.x
agent and a 0.27.0 relay (or the reverse) are turned away at the handshake
with a message on both sides. The wire protocol stays v7 — the new messages
are additive — but the release check already refuses a mixed pair, and a
mixed pair would not show each other's graves or respawns.

**Verified solo, with the maintainer at the keyboard for the fights.**
Nothing here has run two-player yet (`docs/WO-113-findings.md` §1 has the
predictions; `docs/WO-113-progress.md` §4 is the one-page runbook).

---

## When you die in a multiplayer session

No Game Over, no reload. Weapons, bleeding, poison, starvation, falls:

* the screen fades and stays black for about 6 seconds;
* **a grave** is left where you died: a stone roadside cross, and a grave
  icon on the map. Everything you carried goes into it — worn gear, the
  backpack, money — except quest items and your keyring. Saddlebags are not
  touched;
* you wake at the nearest blackout wake-up spot **at least 100 m away**, at
  full health, bleeding and poison cured; nearby NPCs ignore you for 8 s;
* walk back and loot the grave: when it is empty the cross and the icon go.
  An untouched grave disappears after 3 in-game days. Graves are saved with
  your game.

## When you lose a fistfight

A **knockdown**, not a death: you were unarmed, the last hit was a fist, and
no one near you has a weapon out. Black for about 6 seconds, then you wake
**where you fell** at 30 health. The game's own "stop the fight" ends the
brawl — the NPC walks off. No grave, nothing lost, no robbery, no arrest.
(Walk up to him again and he may still be angry: he remembers.)

## When you are executed

Treated as a death: a grave, the crime cleared the way a served punishment
clears it, the punishment's lock on random events lifted, and you wake at the
nearest spot outside the town.

## What your friend sees

Your ghost falls, then appears at the wake-up spot (no walking across the
map). A cross and a grave icon where you died — theirs to look at, not to
loot. Both vanish when you empty your grave, when it expires, or when you
load a save it isn't in.

## The toggle

`mp_respawn on|off` (default **on**). Off = vanilla death and Game Over,
exactly. Outside a multiplayer session the game is always vanilla.
`mp_preset_legacy` turns it off with the rest of the 0.26.4 defaults;
`mp_preset_clean` turns it back on.

## Fixed along the way

* Opening the full map after reloading a save could crash the game while a
  grave or a friend's grave was marked. Marks are now taken off the map
  before a load can pull their objects away.

## Known limits

* **Some story scenes end in a scripted death** (a duel you are meant to
  lose, a few ambushes): those now respawn you instead of reloading, and the
  quest may not move on. Reload a save if a quest stalls after one
  (`docs/WO-113-findings.md` §7 lists them).
* Quest brawls (the tavern and arena fights) were not tested with this build.
* The black screen has no caption yet.
* On very steep or broken ground the cross can sit a little off the ground.

## New log lines to grep

* `WO113-BUILD` — native: every piece armed or `OFF`; Lua: the toggle state.
* `MP-RESPAWN` — the whole sequence: `classify -> death|knockdown` with the
  reasons, `downed`, `grave`, `wake spot`, `done after … ms`.
* `MP-GRAVE` — made / snapped / removed (looted, expired, vanished with a
  load) / mirror shown / map marks.
* `MP-GAMEOVER id=<n> decision=swallow|pass` — every Game Over.
* Agent console: `[respawn]`, `[grave]`.
