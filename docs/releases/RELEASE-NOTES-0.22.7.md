# KCD2-MP 0.22.7

The label for everything on `main` as of WO-99 (2026-09-16), packaged as
`KCDMP-Setup-0.22.7.exe`. Setup exe only — there is no DirectInstall ZIP
(retired in 0.22.0).

**No native change.** `KCDMP.dll` is source-identical to 0.22.4/0.22.5. The
pak, agent, relay, launcher and master server are republished as a matched
set; deploy all of it together (the CombatEvent wire format grew by two
bytes, and an old relay would drop the new packets).

**Verification status, stated plainly.** Everything here is
**synthetic-verified, not live-verified**: 101/101 agent unit tests, the new
`Test-WO99Synthetic` suite 39/39, every prior MoonSharp suite green. Nothing
has run across two machines. The first two-player session on this build is
the A/B for two of the changes below; `docs/WO-99-findings.md` says what to
watch.

---

## Fixed: your friend's wounds were landing on you (WO-99 Phase 0)

Both players' characters are named `Dude` by the game. When one player took
damage, the mod's native sampler reported it as damage to an NPC called
`Dude`, and the other machine applied that damage to *its own* player. On
2026-09-16 the joiner lost 89 of 100 hp to nothing, echoed the same blow
back twelve seconds later, and the host died of it. The local player is now
excluded from NPC damage sync on both send and receive, by soul identity
rather than by name (the name is a fallback for the seconds after a save
load), and a receiver never re-sends a value it just applied from a peer
(hits and deaths alike). Every dropped or refused packet is logged.

## Fixed: a friend in a menu looked like a dropped connection (WO-99 Phase 1)

While a player sits in a menu, a loading screen or a cutscene, the game
halts the mod's position emitter, so the peer saw 20-second holes in the
stream. Analysis of both machines' logs found **every** such hole to be this
(none were network); the connection's latency was unchanged from the night
before. The agent now keeps sending its last position every two seconds
while the emitter is halted, flagged as stale, so the other side can tell
"paused" from "gone".

## New: NPCs stop fighting your friend's game for their body (WO-99 Phase 2, A/B)

When an NPC is being driven by the other player's world but this world's AI
keeps moving it, the mod used to drag it back fifty times a second — the
"glitching NPCs" the host saw in the cabin. Now, when that contention is
sustained (0.3 m of displacement for half a second), the mod yields the body
to the local AI and only re-asserts when the other player's copy actually
moves more than a metre. **Default on.** Toggle live with `mp_npc_yield_on`
/ `mp_npc_yield_off`. Known trade-off: an NPC your friend is fighting may
walk away on your screen — that is the two worlds disagreeing, made visible
rather than jittery.

## Diagnostics

* `MP-NPCYIELD` logs every yield / re-pin; `MP-DMG dir=drop` and
  `result=refused` name why a damage packet was not sent or applied.
* The `MP-SUMMARY` blocks now print every five minutes as well as on
  disconnect (the last session ended without one).
* Swings carry a cross-machine id, so "did my swing play on their screen"
  is answerable from the two logs.
* Loading fades and sleep now leave `MP-CUTSCENE` lines (`acted=0`).

## Known and accepted

* If one player reloads a save in which an NPC the other player killed is
  still alive, that NPC is alive for the reloader and dead for the other.
  The mod notices and clears its own bookkeeping; it does not re-kill.
  Killing it again is harmless on both machines.
