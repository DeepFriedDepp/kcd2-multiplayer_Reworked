# KCD2-MP 0.28.3 — no snaps, crowds that keep up, an even-paced partner

The label for everything on `main` as of the WO-118 follow-ups (2026-09-24),
packaged as `KCDMP-Setup-0.28.3.exe`. Setup exe only. **To go back:** the tag
`rollback/0.28.0` and `KCDMP-Setup-0.28.0.exe` — or, without reinstalling,
type `mp_preset_legacy` (or just `mp_npc_native_write off`) in the console.

**Both machines must run 0.28.3, and so must the relay, wherever it runs.** The
relay turns anything else away at the handshake, with a message on both sides.
0.28.3's position updates carry a timestamp that 0.28.0 cannot read; the release
check is what keeps a 0.28.0 machine out. The protocol number is unchanged (v7).

**Verified solo** — a synthetic host through a real local relay, this machine as
the joiner, every frame traced. Nothing here has run two-player yet
(`docs/WO-118-findings.md` §8–§9 have the numbers; `docs/WO-118-runbook.md` is
the one page for the session).

---

## No snap when a swing ends or an NPC starts being synced

* In a fight, an NPC that moved on the host during its own swing used to catch
  up in one step when the swing ended (up to 1.3 m in the test). It now glides
  back in, about 4 cm per frame at most.
* An NPC that starts being synced away from where the host has it used to slide
  over in 40–65 cm steps and then jump. It now eases in from where it stands
  (about half a second from 1 m away).

## Crowds keep up, even with the game in the background

The agent now hands every NPC update to the mod's DLL the moment it arrives,
and sends the game's scripts only what they need: an NPC's latest state about
five times a second, and at once when it dies, is knocked out, draws a weapon,
swings, is carried or loses health.

* 40 walking NPCs, game minimized: every synced NPC moved on every frame
  (0.28.0: about one in four).
* 80 walking NPCs: every synced NPC moved on every frame (0.28.0: about one in
  six), with no change in frame time.

## The other player walks at an even pace

Their position updates now carry the sender's clock, and the DLL no longer
stretches each of their updates (one every ~30 ms) to 50 ms. Their pace varied
by 0.56 m/s from frame to frame on a clean connection; now 0.02 m/s. With
40–100 ms of jittery delay: 0.04 m/s instead of 1.04.

## Known

* On a very jittery connection the other player can stop for a single frame
  every few seconds.
* Under a heavy NPC load the game occasionally turns away one of the agent's
  command batches (once in ~10 minutes of 40–80 walking NPCs), as in 0.28.0.
* KCD2 still slows itself to ~26 fps in the background. NPCs now keep up at that
  rate; the game itself is slower.

## The toggles

As in 0.28.0: `mp_npc_native_write on|off` (default **on**), `mp_npc_detach
on|off` (default **on**), `mp_preset_legacy` / `mp_preset_clean`,
`mp_npc_trace <npc> [seconds]`.
