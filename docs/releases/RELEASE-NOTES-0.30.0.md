# KCD2-MP 0.30.0 — the shared world, on by default, with moving legs

Everything on `main` as of WO-129 (2026-09-26). The installer,
`KCDMP-Setup-0.30.0.exe`, comes from the maintainer and is not on GitHub.
The tester page is `docs/TEST-0.30.0.md`.

**Both machines and the relay must run the same build.** 0.30.0 refuses
0.29.9 and older at the handshake, and says so on both sides.

**Verified solo:** one machine, a synthetic partner through a real local
relay. The first two-player session ran 0.29.9; its logs are what this
release fixes. The numbers are in `docs/WO-129-findings.md`.

---

## The shared world is on by default

- One world, the host's. A joiner waits at the main menu and joins with the
  launcher's **Bring my character** / **Start fresh** buttons. Nothing is
  typed in the game.
- Only the host saves while you play together. A solo game saves as before.
- `mp_shared_world off` goes back to separate worlds, and so does
  `mp_preset_legacy`.
- Since 0.29.9: Steam as a way to connect (a join code, Find Friends),
  **Test connection**, and connection errors in plain words.

## The other player and NPCs move like people

- In 0.29.9 the other player and the NPC copies slid along the ground with
  still legs. They now walk, run, sprint, crouch, jump and step backwards
  with the engine's own animations, on both screens.
- Guards, blocks and attack rows play on the other player's figure.

## Fixed from the first two-player session

- A joiner who dies now leaves a grave with their things (0.29.9 made none).
- NPCs around the joiner keep moving when the two of you are far apart.
- The launcher's bottom line clears once connected. The join buttons show.
- The host's screen says which step a join is on and for how long.
- The Discord presence error in the agent log is gone.

## Known

- Your swings reaching the other screen: fixed in code but not yet tried
  with a real click. Please check it first (tester page, section 5).
- NPC copies sunk into the ground: reported once, not reproduced here.
- NPCs near the host are held still on the joiner's screen, and quest
  progress does not travel yet.
