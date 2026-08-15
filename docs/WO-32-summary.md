# WO-32 summary — NPC synchronization: proven, built, shipped on by default

*One-page summary. Full evidence: `WO-32-findings.md`. Session log:
`WO-32-progress.md`.*

## The question

Can one player's world dictate what real, hand-placed NPCs are doing in
everyone else's world — the problem that makes mods like Skyrim Together take
years? This WO was staged to allow a clean "no" at every gate.

## The answer

**Yes — and by a much cheaper mechanism than budgeted for.** The expected hard
part (suppressing a real NPC's own AI so network data can drive it) turned out
not to exist:

- A **single** external position write on a real NPC lands and is silently
  reverted by the engine to the NPC's schedule anchor within ~1.5 s.
- A **continuous 50 ms write stream wins completely** — the NPC's AI stays
  fully awake and simply loses, the same result WO-26 found for ghosts,
  reproduced here on a real scheduled villager (`ttkc_man_16`, vetted clean:
  civilian crime role, no publicEnemy ancestry, no quest references).
- **Stopping the stream is the entire release mechanism.** The engine restores
  the NPC to its own schedule within ~3 s — back on its exact anchor, dialogue
  working (human-verified), zero crime/reputation/faction contact on the NPC,
  on an unmodified control NPC observed in the same session, or on the player.
- Ghost-style forced animation works on real NPCs (human saw him walk;
  without it he slid along in his seated pose).

## What shipped

**Wire protocol `0x26`/`0x27` (NpcStateUp/Down), protocol version unchanged.**
NPCs are addressed by their authored entity name (byte-identical on every
install), validated at three layers so relay data can never inject Lua.

**Authority reuses WO-28's Rule 2 role**: exactly one client — in practice the
host — emits NPC state, and the relay drops NPC packets from anyone else
(verified in the relay's own log). Non-authority machines just render.

**Scope bound, deliberately**: the 5 nearest human NPCs within 30 m of the
authority's player, change-gated at 4 Hz with a 2 s heartbeat. Ghosts are
excluded by registry reference. Receivers drive their local copy through the
same interpolation shape as ghosts, apply WO-34's corpse rule (dead NPCs are
never dragged), and release any NPC whose stream goes silent for 3 s.

**On by default** (human's recorded decision). Turn off with `mp_npc_sync off`
in the console on the authority's machine; other machines are unaffected
either way.

## Verification

`tools/Test-NpcSyncE2E.ps1`, final run **15/15** against the real relay, real
agent, real game: emitted packets match engine-resolved positions; the
authority guard drops a forged packet; a synthetic peer holding authority
drove the real NPC over the real wire (tracking confirmed mid-drive), and the
release/restore cycle completed cleanly. Relay regression 21/21, Farkle 59/59.

## Cost

Measured ~150 B/s for a live street scene (5 NPCs), 740 B/s worst case —
**less than one player's position stream** (~1 KB/s). A 50-NPC town
extrapolates to ~7.4 KB/s on the wire (trivial); the true ceiling is the
receiving client's apply path, unmeasured past 5 NPCs, which is why the cap
stays.

## The extra work this session: release 0.11.8 and the installer hardening

The same session also shipped the release and fixed a failure it caused:

- **VERSION `0.11.8`** (user-chosen), carrying WO-32 (NPC sync), WO-33 (dice
  wagers), WO-34 (bandit roster + walking-corpse fixes) and WO-35 (C# master
  server) — all four verified present *inside* the built artifacts by
  extracting and scanning them, not by trusting the source tree.
  `KCDMP-Setup-0.11.8.exe` and `KCDMP-DirectInstall-0.11.8.zip` are in
  `release\`, upload is the user's.
- **A real half-applied install, caught and closed.** The user's first Setup
  run silently left the agent and relay DLLs on an old build (this session's
  own leftover test processes were running at install time) — NPC sync would
  have been inert for any tester it happened to, with no error anywhere.
  Three defence layers now ship:
  1. **Setup refuses to install over a running stack** (launcher/agent/relay/
     game) — Retry/Cancel interactively; silent installs close our own
     processes but abort rather than touch the game.
  2. **Every install proves itself**: a 1,019-file size manifest ships in the
     payload, every file is compared after install, and the verdict lands in
     `install-verify.txt` (plus an error box on interactive failures).
  3. **The launcher detects a mixed install at startup** by comparing every
     sibling DLL's version stamp against its own — the check the wire
     protocol can never do, because the mix is inside one machine.
  Both user-facing paths were **verified live by the user**: a clean install
  (verdict PASS) and a deliberate re-run with the launcher open (gate fired).
- **A suite bug that had been biting silently**: `Test-Installer.ps1` deleted
  the real mod deployment from the game folder on every run while claiming to
  restore it. It now snapshots and restores — observed working.
- Suites after all of it: installer 41/41, detection 21/21, Farkle 59/59.

## Still open (honest list)

- Not tested with a second real human (same standing as every cross-machine
  feature since WO-28).
- Dialogue with an NPC *while* actively driven (before/after verified).
- Combat-state NPCs: position will obey (WO-26 proved that on a fighting
  ghost), but combat-AI behaviour under external drive was not observed.
- Cross-machine divergence rate of unsynced NPCs (needs two machines).
- Crime/reputation stays per-machine — a synced guard may visibly chase a
  criminal that doesn't exist in your world. Stated simplification, not a bug;
  the full authority question is WO-36's neighbour.
