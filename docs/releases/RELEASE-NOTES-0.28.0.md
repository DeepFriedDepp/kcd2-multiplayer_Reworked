# KCD2-MP 0.28.0 — smooth NPCs

The label for everything on `main` as of WO-118 (2026-09-23), packaged as
`KCDMP-Setup-0.28.0.exe`. Setup exe only. **To go back:** the tag
`rollback/0.27.0` and `KCDMP-Setup-0.27.0.exe` — or, without reinstalling,
type `mp_preset_legacy` (or just `mp_npc_native_write off`) in the console.

**Both machines must run 0.28.0. The relay refuses anything else.** The wire
protocol is unchanged (v7); the release check turns a mixed pair away at the
handshake with a message on both sides.

**Verified solo** — a synthetic host through a real local relay, this machine as
the joiner, every frame traced. Nothing here has run two-player yet
(`docs/WO-118-findings.md` §1 has the predictions; `docs/WO-118-runbook.md` is
the one page for the session).

---

## NPCs walk smoothly on the joiner

The host's NPCs used to be placed 20 times a second, at a moment in the frame
where the game undid the placement on most frames: walkers stood, then dashed
(three frames in four frozen), and NPCs pulled off a bench or a workstation
flickered toward their seat. Now the mod's DLL places every streamed NPC on
**every frame**, at the right moment:

* walking NPCs: no frozen frames, even pace;
* NPCs the host has moved away from a seat, bed, stall or workstation stay where
  the host put them — the joiner's copy is freed from its activity first
  (not while it is in a conversation);
* nothing sinks: checked on a slope and in a fight;
* network jitter is absorbed: the delay adapts to how late the host's updates
  actually arrive (tested with 40–100 ms of jittery delay and lag spikes);
* the other player's character no longer freezes between position updates.

Cost: about 7 microseconds per NPC per frame — 0.45 ms with 70 NPCs moving.

## Known

* Keep the game window **in front** on the joiner. KCD2 slows itself to ~26 fps
  in the background, and in a crowd of walking NPCs the updates then pile up:
  NPCs lag and step until the window is back in front.
* The other player's pace can wobble slightly on a bad connection (their
  position updates carry no timestamp yet).
* An NPC freed from its seat hops once, a few centimetres, at that moment.
* In a fight, an NPC that moved on the host during its own swing catches up in
  one step when the swing ends (as before).

## Also fixed

* Restarting the agent under a running game could leave that machine thinking
  it still decided NPC hits on the player.
* NPC update timestamps were 16 ms coarse; now 1 ms.

## The toggles

`mp_npc_native_write on|off` (default **on**) — off = the previous 20-per-second
placement, for comparison. `mp_npc_detach on|off` (default **on**).
`mp_preset_legacy` turns both off with the rest of the previous defaults;
`mp_preset_clean` turns them back on. `mp_puppet_rate` only applies with the
native write off. `mp_npc_trace <npc> [seconds]` records what the renderer drew
for one NPC, frame by frame, to a CSV in the game folder.
