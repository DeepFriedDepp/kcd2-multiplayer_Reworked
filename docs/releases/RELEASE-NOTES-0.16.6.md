# KCD2-MP 0.16.6

The label for everything on `main` as of WO-48 (2026-08-24). Covers WO-44
through WO-48 — everything since `0.15.0`. This is the first build intended
for two-human testing of the native combat swings and dropped-item sync.

## New since 0.15.0

### Native ghost combat swings (WO-45/46, live-verified)
Peers' swings now render as real, complete Mannequin attack animations on
their ghost, driven through the native DLL (pipe command 0x06), replacing the
guard-transition cue that was the best the Lua route could do. The ghost's
weapon must be drawn; draw/sheathe/block stay on the existing Lua path.

### Per-weapon swing animations (WO-47, live-verified)
The swing a ghost plays now matches the weapon class the peer actually holds
— mace, axe, longsword and halberd verified live, catalog built from the
shipped game tables (675 melee items). Polearm draw fixed (DrawFromInventory
ordering). Ranged action names recorded for a future WO.

### Dropped-item sync (WO-48, new wire layer 0x32–0x35)
A player who deliberately drops an item on the ground now shares it: peers
see the same item appear at the same spot, anyone can pick it up, and the
first pickup wins for everyone — the loser sees it vanish, and a pickup that
raced and lost is rolled back automatically. Works generically for any item
type (verified across food, a bandage stack, armor, and weapons). Late
joiners converge via a 30 s re-broadcast; a save reload self-heals both
directions. Kill switch: `mp_item_sync off`.

Deliberately NOT shared: chests and NPC pockets. Each player keeps their own
loot pool — only deliberate player-to-player handoffs sync.

### Reverse-engineering groundwork (WO-42/43/44, no gameplay change)
The combat-animation route disassembly, the `combat_playanim` diagnostic and
the ghost-swing precondition probes that made WO-45/46 possible.

## Known limits in this build

- The two-human race for one dropped item is arbitrated by the relay and
  verified at the wire level; this build is its first real two-human test.
- Weapon condition may not carry on synced drops (a sword sent at 80%
  showed 100% on the receiver; consumables carried correctly).
- Ranged/bow swings on ghosts are not yet animated (melee only).

## Wire protocol

Protocol version stays at 6 — every layer since is additive. New type bytes
0x32–0x35 (ItemDrop/ItemClaim up/down). Next free: 0x36.
