# KCDMP Testing Footage Findings

## Context

PA = Player A. Assumed to be the HOST.
PB = Player B. Assumed to be the player CONNECTING to the host's game.

Network assumptions: both players were on the same LAN connection in the
same building. No Tailscale, no Windows firewall getting in the way — a
direct P2P connection within the same house, best-case scenario for the
network, since there's no VPN-overlay reliability/latency variable in play.

## A) Animations

Animation for the player viewing another player is stuttering. For example,
when Player A hosts a raid, Player B connects. When PA can see PB, PB's
movement and animation is stuttery and non-fluid. When PB sees PA move, it
is the same behavior. However, for them on their own screen, everything is
fine as expected. As mentioned below, this also is the case in combat,
where PA is watching PB, and PB is not swinging a sword or doing anything
in combat — he is stationary as far as PA, the watcher, can tell.

To go into more detail: it is almost as if there is desyncing happening
when you have lag in a game. PA watches PB move; PB takes 2 steps and
phases backwards one step. This does not happen for PB — he is moving
normally, but visually to PA, PB is desyncing. The animations are also not
smooth, with footsteps, leg movements and more not being fluid. When PB
jumps, on PA's screen he goes vertically into the air stationarily. PB has
his arms move, etc. normally, but for PA watching, PB is stiff as a log and
just scales upwards momentarily.

When in combat, since it is syncing the positions of an NPC to multiple
players, it seems to be causing an issue where that NPC phases back and
forth as discussed in Section C below, but also has no animations for
having open combat with the person they are fighting.

## B) Clothing sync

Clothing sync seems to work and almost always accurately reflects the
outfit changes to the other player's visuals, however some do not work.
For example, in a connection test, PA watched PB change outfits. When
removing the helmet, armor, boots and legs they all almost immediately
changed to reflect the "naked" body, however when PB put on a shirt,
boots, regular pants and a belt, only the belt and boots reflected. The
pants and shirt never appeared, even after waiting to ensure this was not
a sync-timing issue. It is mostly reliable outside that, but when changing
clothes frequently, some items seem to bug out and do not appear on the
other player visually.

### B.1

Because the NPC is assigned a brain of one of multiple random real-world
NPCs, dialogue will start and not stop. For example, PB is assigned a
Woodcutter NPC brain to inhabit. When combat starts for PB, his character
constantly yells "HELP! GET ME OUT OF HERE" non-stop. The brains of
connecting players should not have open-world dialogue capabilities — it
is annoying and a bug that it never stops, even long after combat has
ceased.

It was also observed that occasionally it takes a significant amount of
time for the clothing changes to sync for the players. For example, PA
changed clothes and for PB it took 5 minutes before PB was able to see PA's
new clothing.

## C) NPC state/position/rotation syncing

When syncing the NPC positions, occasionally, they phase horribly. For
example, PA is looking at PB. On PA's screen, a female NPC is wandering
nearby, walking past PA. PB is about 15 meters away, and for PB, the
female NPC begins phasing and glitching, looking as if she is teleporting
10,000 times in a second. It almost seems as though the female NPC is
fighting the syncing, struggling to determine which player it needs to
sync the position of, and does both instead, making it so it is phasing
between 2 positions.

There also was randomly an NPC seen floating in the air with his knees
curled on PB's screen, as if crouching, but this NPC is not present on
PA's screen.

Journal is working as intended.

## D) Horse riding

When using a horse, it spawns a new one. PA is watching PB in a field. PB
gets onto a Brown Horse to ride it, and instead, as soon as PB mounts the
horse, he mounts onto a newly spawned Gray horse and rides away — the
horse is also gray for PB. PA then mounts the Brown horse, unsure if this
spawns an entirely new horse for PA (the host). The horse that is spawned
when PB mounts is only interactable with PB. PA can see the horse, but is
unable to mount the horse, hit it with a sword, or anything — he can just
see it. When PB dismounts the horse, it despawns and disappears.

Additionally, in the wild, if PB has a horse, PA does not see the horse
until PB mounts it. For PA, it just looks as if PB walks up to nothing,
and then is suddenly riding a horse.

## E) Combat

Combat begins and starts for both players. However, combat is not seen for
both players. PB begins combat and is attacked, begins fighting back. PA
looks — is in a combat state (the little rabbit indicator showing someone
is angry and attacking appears) but is not seeing anything, or having the
NPCs that are attacking PB attack PA. To PA, PB is standing alone in a
field — no combat animations, just looks as though he is standing straight
in a field, moving around, arms down at his side.

In some cases, when an NPC is synced, they can be seen by both players. But
as discussed in Section G below, when combat begins, it only shows for one
party — the initiator of combat. For the other player, nothing happens.

During a combat test, PB died during combat. Due to this, PB is reloaded
to his most recent previous save to respawn. When this happens, some NPCs
are synced back. Additionally, when PB dies, his body stands there as if
alive, without issue — there is no animation of the body falling to the
ground or lying there dead. He just stands up straight, sits there, and
respawns when PB respawns back in.

## F) Day/night player-player syncing

When a player sets the time or sleeps, the night/day cycle only applies
for the player who slept. For example, if PB goes to sleep and wakes up at
midnight, it is still daytime for PA. This causes major syncing issues for
PB — the person who is not the host — because it is not the same time as
the host anymore, and NPCs are in different spots and do different things
at nighttime.

NPCs are seen doing the exact same phasing/teleporting behavior described
in Section C, where multiple NPCs are seemingly teleporting thousands of
times between multiple positions, trying to fight over which player to
sync with. This causes major jitters and other issues, where these NPCs
are also unable to be interacted with, because they are in so many places
at once, teleporting between these places.

## G) Wandering NPCs (and related combat with them)

These seem to be synced — PA and PB see the same NPC, wandering around in
the same place. When PB is watching and PA stands in front of the
wandering NPC, the NPC moves around PA, as if he is in the way, and PB
sees this happen — so that is good news.

However, when combat starts, it all breaks. PA is watching as PB attacks.
PB knocks the NPC out, picks up the body, and puts it down. The NPC is
knocked out now for PB, but still walking as if nothing happened — like
the earlier glitch where knocked out/killed NPCs would wander around
still. For PA, the NPC is alive and well — not glitching, not aggroed, not
hurt — just continuing on his regular walking path. This only occurs when
the NPC is knocked out, it seems.

At this point, PB decides to slaughter the NPC. For PB, he approaches the
knocked-out (but still wandering, glitched-into-the-ground) NPC and kills
him. At this point, the NPC drops dead for PA, who is watching — stops his
walk and falls to his death. This, for PB who killed him, also makes it so
the body is no longer glitched into the ground, and is now synced back
normally for both players.

PB then picks up the body to move it — this happens for PB, but for PA the
NPC remains on the ground dead, and PB never moves it on PA's screen.
Seems moving the body only syncs for one player at a time, not both. If
the body is dropped by PB in a different spot, PA does not see this
reflected. PB removes all clothing from the dead and moved NPC, and this
also does not sync for PA.

It was also observed that PB was fighting, and PA reloaded a save. When
this happened, the attacking NPC disappeared for PB. PA approached the
location of PB, who was completely invisible. The NPC was right next to
the invisible PB on PA's screen, but as far as PB could tell, that NPC was
gone and was not nearby. PA was not invisible to PB, but PB was invisible
to PA. Worth noting: when this happened, it was nighttime for PB and
daytime for PA.

## H) Fast travel

This is working. If PA looks at PB, and PB gets on a horse and fast
travels, for PA, PB seems to bolt away at lightning speed, traveling away.
This works the same without a horse.

The only issue is that when fast traveling, time is also sped up for the
person traveling. This means that if PA stays in Troskowitz, and PB fast
travels to Trosky, this might take 3 in-game hours for PB — meaning that
when PB arrives, it is 10pm and dark, but for PA it is still 7pm and not
quite dark, which, as observed, can cause the NPC-syncing issues discussed
in Section F.

## I) Username tags & map adjustments

It seems that player nametags cannot be seen past about 50 meters in-game.
Once this distance is covered between PA and PB, both players cannot see
the username tag, health, or stamina bar above the other player's head.
They just look as if they are regular players in the game, not a
connecting player.

This makes me want to have a moving marker when opening the map that
shows where the other players are. For example, if PA is in Trosky and PB
is hunting in a field 10km away, when PB opens the map and looks at
Trosky, he can see PA's player icon in Trosky. If PA starts moving, PB can
see PA's player icon moving on the map relative to where PA is moving in
space.

## J) Forge/smithing bug

In an example of a bug that was observed: PA follows PB into a forge. PB
begins to forge a sword. While PB is hammering at the hot sword, PA
approaches the anvil that PB is working on. PA cannot see any animations —
it just looks as if PB is standing there next to the forge. When PB swings
the hammer to strike the sword being worked on, PB is hurt because PA is
close. I.e., when you approach a character who is actively forging, the
approaching player's character will cause the character forging to be
damaged.
