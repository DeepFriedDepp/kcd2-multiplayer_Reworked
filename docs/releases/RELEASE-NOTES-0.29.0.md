# KCD2-MP 0.29.0 — your partner moves and fights like Henry

Everything on `main` as of WO-121 (2026-09-25), packaged as
`KCDMP-Setup-0.29.0.exe`. Setup exe only.

**To go back:** the tag `rollback/0.28.3` and `KCDMP-Setup-0.28.3.exe`. Or,
without reinstalling, type `mp_preset_legacy` in the console for the 0.28.x
look.

**Both machines must run 0.29.0, and so must the relay, wherever it runs.**
The protocol is now **v8**, and a 0.28.x machine is turned away at the
handshake with a message on both sides.

**Verified solo:** one machine, a synthetic partner through a real local
relay, every animation judged by screenshot against Henry doing the same
thing. Nothing here has run two-player yet. The numbers are in
`docs/WO-121-findings.md`; the one page for a session is
`docs/WO-121-runbook.md`.

---

## Your partner walks, runs, sprints, crouches and jumps like Henry

- Their legs now move with the engine's own gait, at the speed they're
  actually going. No more gliding or a looped walk clip.
- Crouching and jumping show on their figure.
- NPCs synced from the host use the same gait.

## Fights look like the fight your partner is having

- Your partner's guard side, held block and every swing show as they chose
  them: overhead, left, right, thrust, plus dodges and perfect blocks. These
  are the moves the game itself played on their machine.
- Your partner's figure no longer fights on its own; only their inputs move
  it.
- NPCs the host sees swinging swing the same moves on your screen.

## Friendly fire is on

- Hitting your partner hurts **their own Henry**, and starts no fight and no
  crime on either machine.
- Fists knock them down; they never die from fists.
- A lethal weapon hit gives them a grave and a respawn, as for any death.
- The host decides for the session: `mp_friendly_fire off` turns it off for
  both of you.
- **Known:** a hit that would make them bleed doesn't make them bleed. Only
  the damage carries over.

## NPCs know who hit them

- When your partner hits an NPC, that NPC now knows it was your partner's
  figure: it turns on them, joins a fight with them, remembers them, and
  bystanders may join in.
- **Known:** the NPC that was hit targets your partner but may not swing back
  yet.

## Known

- One crash was seen in testing: a save load right after a brawl between
  villagers and the partner's figure. It didn't happen again in two repeats.
- Ranged combat (bows, crossbows) is not synced yet. Ladders and vaults are
  not synced yet.

## The toggles (default **on**; `off` gives the 0.28.x behaviour)

`mp_avatar_gait`, `mp_npc_gait`, `mp_avatar_moves`, `mp_avatar_combat`,
`mp_npc_rows`, `mp_npc_attribution`, and `mp_friendly_fire` (host, whole
session). `mp_preset_legacy` turns them all off; `mp_preset_clean` restores
this build's defaults.
