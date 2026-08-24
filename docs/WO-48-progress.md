# WO-48 progress

## 2026-08-24 — full session

**Phase 1 (reachability): all three questions answered YES, live-probed** on
the running game over RemoteConsole (`docs/WO-48-findings.md` for evidence
classes and the exact probes):

1. Spawn: `System.SpawnEntity{class="PickableItem"}` alone binds no item
   (all-zero wuid — the WO-22 properties lesson again), but
   `inventory:CreateItem` + `Human.PlaceItem(wuid, anchorEntity, false)`
   makes the engine mint a real, bound, interactable pickup at the anchor's
   position. Works through a ghost's inventory/human, so the receiver never
   touches the player's inventory. `ItemManager.CreateItem` is NOT registered
   in this build (docs list it; the live table doesn't) — the entity-scoped
   `inventory:CreateItem` is the real surface. Placement 60 m away fell
   through the world (z −217) → receivers materialize only within 70 m.
2. Identity: agent-minted random uint32 dropId (string in Lua — 2^24 float
   ceiling); item type travels as the WO-9 ItemClass GUID + amount + health,
   all readable off the ground entity's Properties (`sItemClassId`,
   `nAmount`, `fHealth`).
3. Drop detection: new PickableItem near the player + that class's inventory
   count decreased — both halves required (filters streaming and NPC drops).

**Phase 2 (build): shipped and tested.** Wire 0x32–0x35 (next free: 0x36).
Transactional, the time-skip shape — deliberately NOT the NPC
continuous-authority stream. Race arbitration is the relay's arrival order:
claims are echoed to ALL peers including the claimant, every client resolves
a dropId on the first echo it sees; a losing claimant rolls back the gained
item by recorded wuid. Relay stays stateless (leaner than TimeSkip's table).

- Relay half: `tools/Test-ItemSyncRelay.ps1` **11/11 PASS** including the
  race-ordering scenario (I3) and malformed-packet survival.
- Game half: every path observed live in one game by loading the new Lua
  section into the running process — sender emit, receiver materialize (via
  ghost), pickup→claim emit, won-claim keep, remote-claim removal without
  re-claim echo, and lost-race rollback on a second item type (bandage
  stack x2, count 11→13→11).
- One real bug found and fixed live: the detector marks freshly placed
  entities seen before the materializer's finalize pass looks for them —
  finalize now diffs against a pre-place snapshot (`d.preIds`).
- All existing suites green: TimeSkip relay 26/26, Farkle 59/59, installer
  detect 21/21. Lifecycle suite human-run as always.
- `kdcmp.pak` rebuilt (`-NoInstall` — game was running; install needs it
  closed). Deploy matched sets (WO-46) when the human runs the 2-machine E2E.

**Live-gated for the human** (findings §Live-gated): real UI drop signature,
two-machine loop, two-human race, reload resweep under a real save load.
