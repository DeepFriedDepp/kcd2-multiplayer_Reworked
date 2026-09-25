# WO-121 peer test — movement and combat, one page

**Both machines must run this build.** Protocol v8: the relay refuses a
0.28.x machine with a clear message on both sides. A relay run on its own (a
server) must be updated too.

**Copy both `kcd.log` files before either game relaunches.** Each launch
keeps only one backup.

**Keep the game window in front** on both machines where you can.

---

## What you should see on load (nothing typed)

kcd.log:

```
[KCD2-MP] WO121-BUILD avatar_gait=on npc_gait=on avatar_moves=on avatar_combat=on npc_rows=on npc_attribution=on friendly_fire=on protocol=v8 -- friendly fire default ON: …
```

`kcdmp-native.mirror.log` (beside kcd.log), once the launcher injected the DLL:

```
WO121-MOTION gait=armed moves=armed combat=armed capture=armed(…)
WO121-HITS hit_slot=armed attribution=armed …
```

A line with `NOT armed -- <reason>` names the one piece that stayed off. Send it.

## What should now look different

1. **Your partner walks, runs and sprints** with legs that match the speed:
   no gliding, no stepping in place.
2. **Crouch and jump** show on the partner.
3. **In a fight** your partner's guard side, held block and swings show as
   they chose them: overhead, left, right, thrust, dodges, perfect blocks.
4. **NPCs your partner is fighting** swing with the moves the host saw.
5. **Hitting your partner hurts them** (friendly fire), on their own Henry:
   - it starts no fight and no crime;
   - fists knock them down, they never die from fists;
   - a lethal weapon hit gives them a grave and a respawn;
   - **bleeding does not carry over** (known).
6. **An NPC your partner hits** turns on your partner's figure. It may not
   swing back yet (known). Bystanders can join in.

## A/B toggles (type in the console, one machine)

| command | what off gives you |
|---|---|
| `mp_avatar_gait on/off` | the old clip-loop walk on your partner |
| `mp_npc_gait on/off` | NPC copies without engine gait |
| `mp_avatar_moves on/off` | no crouch / jump replay |
| `mp_avatar_combat on/off` | the partner's figure fights on its own again (0.28.x) |
| `mp_npc_rows on/off` | NPC copies swing generically |
| `mp_npc_attribution on/off` | your partner's hits on NPCs carry no attacker |
| `mp_friendly_fire on/off` | **host only, whole session**: hits between players do nothing |
| `mp_preset_legacy` / `mp_preset_clean` | all of the above to 0.28.x / back to this build's defaults |

Turn friendly fire off with `mp_friendly_fire off` on the host if duelling
gets annoying.

## Lines worth grepping afterwards

- `WO121-GAIT` (native log): `state=fresh` while your partner moves.
- `MP-SWING hop=queued ok=1` (agent console): the partner's swings played.
- `MP-FF dir=out|in … result=sent|applied`: friendly fire each way.
- `MP-ATTRIB … result=applied damage=1 history=1 skirmish=1 brain_msg=1`:
  your partner's hit on an NPC, on the host.
- `MP-WO121-STATS` every 60 s: event counts, stale drops, friendly fire.

## If something goes wrong

- Your partner's figure fights by itself: send the `WO121-MOTION` lines
  (combat not armed?).
- An NPC takes double damage: send the agent console around `MP-ATTRIB`.
- The game crashes on a save load after a fight: note it with the time. It
  was seen once in testing (findings §8).
