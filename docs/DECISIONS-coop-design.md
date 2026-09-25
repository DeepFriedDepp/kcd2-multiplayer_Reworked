# Co-op design decisions (settled)

The maintainer's settled decisions for the split-save co-op design
(WO-112 onwards). Recorded by WO-115 so every later WO reads them from one
place. A row changes only when the maintainer changes it; a WO that finds a
decision unworkable reports that instead of editing it here.

| topic | decision |
|---|---|
| world | one world: the host's own save. The joiner never loads their own world in co-op |
| join | joiner waits at the menu, receives the host's save, loads it; **host's world pauses** meanwhile |
| joiner saving | locked all session; only the host writes world saves |
| per-player | inventory incl. money, equipment, skills, perks, stats, health, status effects, position |
| world-shared | quests, NPCs, horses, merchants, crime, reputation, **renown** |
| first join | **import** the joiner's Henry from their own newest save |
| story progress stat | always from the **host's** world (hidden stat id 8) |
| host reload | the joiner reloads with the host; the joiner's Henry **rewinds** to the snapshot matching the host's save |
| Henry snapshots | taken **when the host's game saves**, as a matched pair with the world |
| saddlebags | per rider |
| whistle | each player's horse comes to its own rider |
| dialogue | world clock **keeps running** |
| punishment | the Henry in the dialogue pays or is punished; **no time skip** |
| sleeping | **both players must agree** (prompt); if declined, the sleeper gets the benefits without a skip |
| death | respawn at the game's blackout wake-up spots; grave with everything except quest items |
| fist knockdown | not a death: no grave, wake in place |
| grave | lootable **by anyone for 3 in-game days**, then gone for everyone |
| execution | a death: respawn outside that town + grave; **the crime is cleared** |
| distance | **leash** (WO-114); no far-apart play |
| respawn placement | pending WO-114's measured leash: wake at the nearest spot within the leash of the other player, else next to them |
| friendly fire | **on by default**, host lever `mp_friendly_fire on/off`, session-wide; shipped in 0.29.0 (WO-121). A partner's fist knockdown is never a death |
| pausing | **no pausing in a co-op session, either direction**: neither player's menu, dialogue or cutscene stops the other's world (planned) |
| cutscenes | whether story cutscenes play for both at once belongs to quest sync (later) |
| privacy | the rule is about the **public repo**. Saves moving between the maintainer's own machines may carry account names |

Design background: `docs/WO-112-split-save.md`. Where WO-112 laid out options
(renown R1/R2, time T1–T3, punishment J1–J3, first join F1–F3, graves E1–E3),
the rows above are the choices.
