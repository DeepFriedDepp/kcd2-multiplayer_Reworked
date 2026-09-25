# WO-121 — progress

Model Opus 5.5, effort high, mostly unattended; the maintainer joined for
the two items that needed a person. All live work was solo on one machine
(Modding Tools build, synthetic peers, a throwaway save made for this WO; no
save file is committed).

## Commits

| commit | what |
|---|---|
| `8dca84b` | Phase 1: the wire, protocol v8 (state block on flag 0x10, v8 events, PlayerHit 0x44/0x45, one length list at the relay) |
| `96be83f` | Phases 2–4: native gait / crouch / jump, held combat state, row capture and replay |
| `82a8390` | Phases 5–6: attributed NPC hits, friendly fire watch-and-restore, avatar contexts, engagement |
| (this one) | follow-ups: attributed echo guard, captured hitReaction values, test tooling, docs |

Phases 2, 3 and 4 went in one commit, each behind its own toggle, because
`motion.cpp` carries all three and splitting the file would not have built.
Phases 5 and 6 share `hits.cpp` for the same reason.

## Sessions

1. **Probe only** (no KCDMP.dll). Henry references in photo mode. The row GUID
   sits at descriptor+0x84. Automation off holds combat mode for 60 s with
   nothing self-directed. Skipping the hit slot **crashed** the game, so the
   design became measure-and-restore.
2. **KCDMP.dll with motion.** All anchors armed. Guard zones, held block and
   four longsword rows on the avatar. Found: the Lua body state was dropped
   on packets without a block; v8 events were dropped after an agent restart
   (no avatar entity id). Both fixed in the agent.
3. **Gait debug line.** The avatar's readback equals the stream; WO-119's
   probe offset was wrong. Walk / run / sprint screenshots (after the photo
   mode trap). WO-118 gate green with gait on. First friendly-fire attempt:
   the avatar barked at Henry's drawn weapon → script contexts.
4. **Hit-slot dumps.** No damage inside the call, no amount in the data.
5. **Watch-and-restore.** `combat_suppressFriendlyFire` zeroed all damage →
   dropped from the list. Then the full chain to the peer. Gate items 1–5.
   The maintainer answered: friendly fire on (bleeding gap noted); run both
   maintainer items now.
6. **With the maintainer.** Vanilla sword-hit capture. Fight-back tries 1–3.
   A game crash on a load after the bystander brawl (not reproduced by two
   narrower repeats). Engagement un-ignore built and live-injected: mechanism
   verified, the victim still doesn't swing. Maintainer: ship it on.
7. **Shipped pak.** WO-118 gate green; NPC copy rows; v7 refused; 60 s held
   combat; legacy preset; a smoke re-shoot. The game was quit, no mod
   processes left.

## Decisions (recorded as they were made)

- The avatar keeps its brain; only combat automation goes off (the WO's
  settled decision). NoAI and SuspendedAI were not used.
- The gait source: the avatar's streamed speed while fresh (< 1.5 s), else
  the rendered speed. NPC copies always use the rendered speed.
- Rows, not animations: the receiver turns the GUID into `fragment, tags`
  through Tables.pak. An unknown GUID is dropped and counted (`ev_norow`),
  never guessed.
- Friendly fire measures on the attacker's machine. The avatar there wears the
  partner's armour replica, so the damage is the engine's own figure for that
  armour. The victim applies it as plain damage with no attacker.
- The imm+upr buff stays on avatars as the belt-and-braces guard. It does not
  block damage, so measurement works.
- Engagement un-ignore is agent-timed: one Lua write per edge, no per-tick
  Lua (the maintainer's native-first rule).
- The version is not bumped here: the maintainer names it.

## Test tooling (not shipped)

- `tools/wo121/avatarpeer`: a scripted or file-controlled v8 host/joiner. Its
  commands: `stand`, `move`, `strafe`, `state`, `jump`, `attack`,
  `block_impulse`, `dodge`, `draw`/`sheathe`, `ff`, `hit`, `npchit`,
  `freeze`/`unfreeze`, `quit`. Control-file commands run in file order.
- `tools/wo118/synthpeer`: a new plan verb, `row <t> <npc> <guid>`, sends an
  `NpcAttack`.

## Caught by the release gate

- `Test-WO108Synthetic` expected 22 preset values; WO-121 adds seven (29).
- `Test-WO106ConsolePlaceholder`: the seven WO-121 commands were registered
  as `KCD2MP_Wo121Set("key", %line)`. A bare `mp_avatar_gait` would compile
  to `Fn("key", )`, a Lua syntax error (the WO-109 lesson). Each command now
  has its own one-line handler taking `%line` alone.

## Suites

Client 195/195, Relay 36/36, Farkle 59/59; all 18 Lua synthetic suites,
including the new `Test-WO121Synthetic` (55 checks), and the static gates, as
run by `Build-Installer.ps1` on the final tree. Installer:
`release/KCDMP-Setup-0.29.0.exe` (local only).
