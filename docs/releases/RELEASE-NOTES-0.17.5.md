# KCD2-MP 0.17.5

The label for everything on `main` as of WO-58 (2026-08-26). Everything since
`0.17.1` — this is the stability release built from the first real
transatlantic two-human session's logs (see `docs/WO-58-findings.md` for the
full evidence chain). Update **both machines together**: the fixes span the
launcher, the agent and the mod pak, and a partial update recreates the exact
mixed-DLL failure this release diagnoses.

## Fixed since 0.17.1

### The reconnect hard-freeze (the "constantly crashing" / restart-cascade session)
The game's main thread could hang forever inside a ghost mount when a riding
peer reconnected: the mod adopted the same-named world horse wherever it
happened to exist in YOUR world — including kilometres away — and
`ForceMount` onto a distant, AI-owned horse froze the engine on its first
live use. Adoption now requires the horse to be standing within 60 m of the
ghost; otherwise the ghost rides the proven proxy horse (a cosmetic
downgrade, deliberate).

### Wrong gender/face on a returning player
Two bugs, both fixed:
- A ghost that respawned before its player's name was known got a face (and
  a coin-flip gender) hashed from a placeholder key. Names are now
  re-delivered every few seconds, and a ghost that spawned with the wrong
  body corrects itself within seconds of the name arriving.
- A ghost captured inside a save file (saved while a peer stood nearby)
  could survive into later sessions as a stray body wearing an old face.
  Every connect now sweeps and removes stray ghost/horse bodies, whatever
  session or mod version left them. Old saves are safe to keep using — no
  new game needed.

### FPS drag while both players are near NPC battles
NPC-vs-NPC contact chips (hundredths of a hit point, up to ~26/second during
a siege) were each sent over the wire and applied synchronously on the
peer's game thread — nearly 2,000 junk messages in four minutes in the
logged session. Hits below half a hit point no longer leave the machine.

### Version-mismatch notice never worked
The launcher's version poll against the agent has failed on every install
since it shipped (a .NET assembly-resolution defect in the flattened release
layout). Fixed; the "you're behind" notice can now actually fire.

### Endless clothing-retry churn
Items a ghost provably cannot equip were retried in a 10-second cycle every
30 seconds, forever, on both machines. One failed retry schedule now
blacklists the item for that ghost's lifetime.

### Log bundles now capture what actually matters
Collect Logs now also grabs the native DLL logs and the engine's own backup
of the PREVIOUS run's kcd.log — the two files that cracked this
investigation but existed in no tester export. If the game hard-freezes,
collect logs before killing it if you can, and again after restarting.

## Known limits in this build

- The FPS improvement is expected but unmeasured — no frame-time counter has
  run in a real session yet. Report what you see.
- The dice window's launcher IPC shares the assembly-layout risk that broke
  the version notice; it has not failed in any log yet and is unchanged.
- The deeper "one flat folder for four apps" packaging layout is unchanged
  (root cause of the version-notice defect); fixing it properly is scoped
  for a future WO.

## Wire protocol

Protocol version stays at 6; no new type bytes. Next free: 0x36.
