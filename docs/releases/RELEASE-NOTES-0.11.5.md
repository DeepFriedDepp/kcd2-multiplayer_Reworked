# KCD2 Multiplayer 0.11.5 — Release notes

Everything shipped since `0.10.0`, in one place.

---

## What's new

- **Ghosts have real, distinct faces.** Previously every ghost used the same
  generic look. Each connected player is now deterministically assigned one
  of 48 real, hand-placed faces from the game's own NPC roster (a name always
  maps to the same face, so it doesn't change on reconnect), instead of a
  single reused model.

- **Ghosts have always fought back — this release says so for the first
  time.** Since the soul/brain fix below, a ghost defends itself when
  attacked (treats it as a crime, arms itself, lands real damage) and will
  join a fight already happening nearby — no toggle involved. This shipped
  two releases ago and was never in the README's feature list as a
  player-facing thing until now.

- **A knocked-out ghost gets back up.** Ghosts are now spawned with a real
  soul bound to them, which gives them the game's own AI brain. That fixed a
  standing bug where a ghost, once knocked unconscious in a sustained fight,
  simply never woke up again — recovery now happens in under a minute, same
  as it would for any other soul-backed NPC.

- **`mp_enable_aggro` does something narrower than it sounds.** It was never
  the switch that lets a ghost fight back — that's always on. What turning it
  **on** actually adds: a ghost that lands or takes a hit gets recognized as
  hostile by *any* nearby NPC of an opposing faction for about 20 seconds, not
  just whoever it's already fighting. Off (the default), a ghost still fights
  back, just without that wider recognition.

- **Reconnecting no longer leaves a duplicate ghost behind.** Previously,
  rejoining under a new connection could orphan your old ghost instead of
  replacing it, leaving stray ghosts stacked on top of you. Fixed: identity
  (not connection id) now decides which ghost is "yours."

- **The launcher no longer allows two agents to run for one player.** A real
  bug, not just a testing artifact: closing only the game (not the launcher)
  and reconnecting could start a second agent on top of a stale one, and the
  two would fight over the same ghost indefinitely — visible in-game as an
  NPC seemingly attached to the player. The launcher now stops any existing
  agent before starting a new one.

- **Other players' health now shows above their heads.** Every player's own
  health and stamina reach everyone else, so a companion's ghost displays
  their real HP/ST on its nameplate instead of looking permanently healthy
  while its owner is being beaten to death somewhere else. Health comes from
  the player it belongs to and nobody else — your own game is the only thing
  that decides how hurt you are.

- **Death is now shared, and it works the way single-player does.** When a
  player dies, their own game announces it (it is never guessed from health
  hitting zero) and everyone else sees their character tagged
  **`[dead - reloading]`**. That player reloads their own most recent save,
  exactly as in single-player. Nobody else's world reverts — every player has
  always had a completely separate save, and this mod has never had, and is
  not getting, a way to push one player's save into another's. Their
  character simply reappears wherever their save point puts them, and the tag
  clears itself once they're back.

- **NPCs can now hurt a remote player, not just their stand-in.** When an NPC
  attacks your character in someone else's game, that damage is reported back
  and lands on the real you. Exactly one player's game is in charge of this
  at a time — otherwise everyone's NPCs would independently damage everyone
  and multiply the damage by the number of players in the session. *Built and
  every safeguard around it verified, but the hit actually crossing two
  machines has not been tested — there was one machine and no second player
  available. Treat this one as unverified in real play.*

- **Loading a save mid-session no longer breaks you for everyone else.** This
  is probably the single most important fix in this release. It affected
  *any* save load, for any reason, on every version since an early update —
  not just death. Previously, loading a save permanently stopped you
  transmitting: you vanished for every other player for the rest of the
  session, with nothing on your own screen to suggest anything was wrong —
  and it destroyed every other player's character in your world, leaving
  their nametag floating around with no body under it. Both now sort
  themselves out on their own in about 14 seconds.

- **A mixed-version session degrades instead of breaking.** If one side is on
  an older mod file than the other, health simply doesn't show for that
  player; position, movement and everything else keep working normally.

- **The launcher has a new look, a bug-report button, and warns you about
  version mismatches.** Three separate pieces of polish:
  - The launcher now shares the in-game dice overlay's art direction (aged
    parchment, oak, gold) instead of looking like an unrelated generic dark
    app — every screen, not just the home page.
  - A **REPORT BUG** button in the status bar opens either this project's
    GitHub Issues page or its Discord, whichever you'd rather use.
  - If you and whoever you're playing with are on different mod versions,
    the launcher now tells you which side needs to update, instead of
    letting you connect into a session that may not talk to itself properly.

- Connection instructions gained a clarifying step: once both of you have
  loaded into the game world, alt-tab back into the launcher and choose
  **Connect** — easy to miss since the launcher window is behind the game at
  that point.

## Investigated, not shipped

- **Running on retail (no Modding Tools) via its RemoteConsole port.** A real,
  working transport: retail KCD2 opened with `-devmode` listens on port
  `4600` and will run `#`-prefixed Lua through it at roughly 30ms latency —
  contrary to an earlier assumption that Lua evaluation over RemoteConsole
  didn't work on this game version. This is a genuine path to running this
  mod without the Modding Tools install. **Deliberately not pursued**: the
  best version of it depends on tooling built by another modder, and using it
  requires asking their permission first. Nothing about it is built into the
  mod.
- **Forcing the native dice minigame's outcome.** The relay-authoritative
  dice board this mod ships is intentionally a separate system from KCD2's
  own dice minigame. Investigation found the native minigame *can* be pushed
  from outside — a real score can be added to a player's total, and
  individual dice can be selected/held/re-rolled by name. What still doesn't
  work: forcing a specific overall roll outcome (`Dice.OverrideNextThrow`) —
  seven different argument shapes were tried against it, all accepted
  without error, none changed what was actually rolled. Whether that's the
  wrong shape or a timing issue (this build auto-rolls with no "about to
  cast" moment to inject before) is still unknown.
- **Whether a connected player can be Henry**, not a ghost. Tested directly:
  the player is a distinct entity class from any NPC at three separate
  layers of the engine, and the game keeps exactly one slot for "the player"
  internally. Spawning a second one crashed the game outright. Closed,
  not something a future session should re-attempt the same way.

## Honest limits, unchanged by this release

- **This does not synchronise NPCs.** Each player still sees their own
  version of a fight. What's shared is who got hurt and who died — not the
  battle itself.
- **A ghost's own attacks are still unreplicated.** A remote player's
  character can kill NPCs in your world that its owner never attacked.
  Deliberately left alone — suppressing it needs a mechanism nobody has
  found yet.
- **No second-player verification** on the NPC-hits-player flow above,
  same as shared combat and appearance sync before it — everything was
  verified on one machine with synthetic peers plus a real game.
