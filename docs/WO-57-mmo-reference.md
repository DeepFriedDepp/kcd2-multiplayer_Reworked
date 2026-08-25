# MMO Design Reference — shared world vs. individual progression

An MMO (Massively Multiplayer Online game) is essentially a persistent game world where lots of players exist in the same world at the same time, and the game is designed around players interacting with one another rather than simply playing separate copies of the game.

The important part is that there are different ways an MMO can handle quests, progression, enemies, loot, and shared content.

## Quests

Player A accepts a quest on Monday. Player B doesn't accept it until Wednesday. Player A completes the first 3 objectives before B even starts. If they want to actually experience the quest together, A may have to wait for B to catch up. Alternatively, the game can synchronize/instance the quest so that B's progress determines what they see while A helps.

This is one of the major differences between a truly shared MMO world and a co-op game with separate progression.

## Enemies

Common systems:

Shared enemies: A giant wolf spawns in the world. Player A attacks it. Player B joins in. Both contribute to killing it and both receive credit/rewards.

Tagged enemies: Player A attacks the wolf first. The wolf becomes "A's" target. Player B might not get loot/credit unless the game specifically allows group participation.

Group/shared credit: A and B are grouped. Either player can attack the wolf and both receive credit.

MMOs often use the third system because it encourages players to cooperate rather than fight over every enemy.

## Loot

The game might give every player an individual loot pool (A gets a sword, B gets a helmet, C gets gold, D gets nothing — nobody fighting over the same physical items), or a shared loot pool where everyone rolls/competes for the same items (traditional Need/Greed).

## Quests + groups

Suppose there's a quest: "Kill the Necromancer." A accepts it at 2 PM, B accepts it at 5 PM. A goes into the dungeon and kills him. If the game has shared persistent progression, the Necromancer is now dead for everyone — or at least for that world/server, and B might have to wait for a respawn.

Most modern MMOs solve this through personal quest states or instancing: A sees the Necromancer dead because he already killed him. B enters the area and sees the Necromancer alive because B hasn't completed the quest. If A joins B's party, the game can temporarily synchronize the encounter so A can help B.

So you can have a world that is physically shared, while certain quest states are personal to each player.

## The biggest MMO concept: persistence

An MMO world generally doesn't reset when you log out. When you log back in, you're returning to the same persistent world, not loading a fresh copy of the game.

Player interaction generally falls into levels

1. Seeing other players — you simply encounter people in the world.
2. Cooperation — you can help each other.
3. Parties — players formally group together; the game can share quest credit, XP, enemy kills, dungeon progress, loot rules.
4. Guilds — large persistent player organizations with chat, shared storage, progression, quests, ranks, events.
5. Large-scale activities — 20-player raids, 100-player world events; the game coordinates dozens or hundreds of players around one objective.

## The core design question

Player A: Level 30, finished Chapter 4. Player B: Level 18, beginning Chapter 2. They meet. Possible designs:

* Traditional MMO approach: A and B can play together, but A's progression remains ahead; B gets credit for B's quests.
* Fully synchronized co-op: A joins B's game state; A temporarily experiences the world as B does.
* Shared-world approach: the world itself is the same, but quests are individually tracked.
* Hard shared progression: if A kills the king, the king is dead for everyone — creates an incredibly persistent world, but creates huge problems (what happens when one player's action permanently changes the world for everyone else?).

That's why most MMOs use a hybrid system: the world is shared, but individual quest progression and some encounters are personal or instanced.

## Summary

An MMO is a persistent shared world where players can independently progress their characters while interacting with other players through shared spaces, parties, quests, enemies, economies, PvE/PvP activities, guilds, and large-scale events. How much is actually shared — quests, enemies, loot, world changes, progression — is one of the biggest design decisions separating different MMOs.
