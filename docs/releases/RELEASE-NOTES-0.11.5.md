# KCD2 Multiplayer 0.11.5 — Release notes

Since `0.10.0`. Full detail lives in the [README](../../README.md) and `docs/`.

## What's New

- **Ghosts have real, distinct faces** — 48 real NPC faces, deterministically
  assigned per player, instead of one generic look for everyone.
- **Other players' health shows on their nameplate**, driven by their own
  game only.
- **Death is shared.** Everyone sees `[dead - reloading]`; the player reloads
  their own save, same as single-player.
- **NPCs can now hurt a remote player**, not just their local stand-in.
  *Built and safeguarded, but not yet tested across two real machines.*
- **Launcher refresh**: new look, a REPORT BUG button, and a warning if you
  and your peer are on mismatched versions.
- **Mixed-version sessions degrade gracefully** instead of breaking — health
  just won't show for the outdated side.
- Ghosts have always fought back on their own (self-defense, joining nearby
  fights) — this is the first release to actually say so.
- `mp_enable_aggro` clarified: fighting back was never gated by this toggle;
  it only widens *who else* notices the fight.

## Bug Fixes

- **Save reload used to break multiplayer for everyone else** — you'd stop
  transmitting and vanish, and everyone else's ghost body would disappear
  from under their nametag. This affected *any* reload, not just death.
  Fixed; both recover on their own in ~14s.
- **Reconnecting no longer leaves a duplicate ghost behind.**
- **The launcher no longer lets two agents run for one player** — the cause
  of ghosts appearing "attached" to a player.
- **A knocked-out ghost gets back up now** instead of staying unconscious
  forever.

## Investigated, not shipped

- Running on retail (no Modding Tools) via its RemoteConsole port — works,
  but depends on another modder's tooling; not pursued without permission.
- Forcing the native dice minigame's roll outcome — still not achievable.
- Whether a connected player can be Henry instead of a ghost — no; closed.

## Known limits

- NPCs themselves are not synchronised — only who got hurt and who died.
- A ghost's own attacks aren't replicated back to its owner.
- Nothing here has been tested with two real players on two real machines.
