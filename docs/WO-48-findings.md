# WO-48 — Dropped-item sync between players

Scope: a player deliberately drops an item; the other player sees it, can pick
it up, and whoever picks it up first gets it — for both. Chests and NPC
pockets are deliberately out of scope (independent loot pools are better for
both players; see the WO prompt). Transactional design — the time-skip
"first claim wins, broadcast once" shape — NOT the NPC continuous-authority
stream.

## Phase 1 — reachability (all live-probed on the running game, 2026-08-24)

Every probe below ran over the retail RemoteConsole (`:1403` ExecuteString +
kcd.log read-back, WO-43's driveable-from-the-shell finding) against a live
save. Evidence class for each line: **observed** unless marked otherwise.

### Q1 — can a pickup item be spawned at an arbitrary position? YES, two-step.

- Ground items are entities of class `PickableItem`. Their entity Properties
  carry the full item identity readable from Lua: `sItemClassId` (the ItemClass
  GUID — the SAME per-type key the appearance layer has used on the wire since
  WO-9), `nAmount`, `fHealth`. Observed on an authored world item
  (`alias_zachrana_huntingSword000208`) and on every runtime drop probed.
- `System.SpawnEntity{class="PickableItem", properties={sItemClassId=...}}`
  succeeds but binds NO item — the spawned entity's `item:GetId()` is
  all-zeroes, `GetUIName()` nil. The shipped `PickableItem.lua` says the item
  is "attached from C++"; `item:Reset()` does not attach it either (observed).
  Property-spawn alone is a dead end — same lesson as WO-22's nested-
  SharedSoulGuid: properties set ≠ item bound.
- **The working recipe** (observed end-to-end, twice, onion + bandage):
  1. `who.inventory:CreateItem(classGuid, health, amount)` — creates a real
     item instance in that entity's inventory. Works on the player AND on a
     spawned ghost (`kcd2mp_91`). NOTE: `ItemManager.CreateItem` — which
     kdcmp.lua's WO-30-era `KCD2MP_SpawnArmoredNPC` calls, and the shipped
     `ItemUtils.AddMoneyToInventory` builds on — is NOT registered in this
     build's sandbox (live table has only AddOnEquipBuff/GetItem/GetItemName/
     GetItemOwner/GetItemUIName/IsItemOversized/RemoveItem). The
     entity-scoped `inventory:CreateItem` is the one that exists.
  2. `who.human:PlaceItem(itemWuid, anchorEntity.id, false)` — engine mints a
     real, bound `PickableItem` entity at the anchor entity's position
     (engine-generated name like `onion002346`), removes the item from the
     inventory. Verified interactable: `item:OnUsed(player.id)` — the exact
     call the shipped `PickableItem:Use` makes — picked it up (entity removed,
     item in inventory).
  - The anchor can be an unbound `PickableItem` shell spawned at the exact
    target position (the dead end above turns out to be the perfect position
    anchor). Removed afterwards with `System.RemoveEntity`.
- **Distance caveat (observed):** placing at an anchor 60 m away created the
  entity at the right x/y but it fell through the world (z: expected ~119.7,
  found at −217.7). At 1.5–4 m placements always landed correctly. So the
  receiver only materializes a drop when the local player is within a
  conservative radius (70 m), holding it pending until then.
- Amounts: `CreateItem(class, health, 3)` on a stackable (bandage) created
  amount=3 and PlaceItem produced one ground entity with `nAmount=3`
  (observed). On a non-stackable food item the amount arg yielded 1 — pass
  amounts through and let the engine cap them.
- `System.RemoveEntity` on a placed pickable works but is deferred ~a frame
  (name still resolves immediately after the call, gone on the next probe).

### Q2 — identity of a player-dropped item across worlds? A minted drop id.

Nothing pre-existing identifies "the same dropped sword": the ground entity's
name is engine-generated per world (`onion002200` here is nothing anywhere
else), and the item WUID is per-save. So the dropping client's AGENT mints a
random 32-bit dropId at broadcast time — the same runtime-minting idiom as
ghost ids — and every client keys its local bookkeeping (dropId → my local
entity/wuid) off it. The item TYPE travels as the ItemClass GUID (16 bytes,
the established WO-9/WO-10 key), plus amount + health + position.

In Lua the dropId is handled as a STRING everywhere — the stripped Lua 5.1
floats lose integer precision above 2^24 (the WO-46 ghostid lesson), and a
random uint32 usually exceeds that.

### Q3 — detecting the real local drop? Entity scan + inventory decrement.

No drop event/log marker is known; detection is a poll (~0.75 s) built from
two proven pieces:
- `System.GetEntitiesInSphere(playerPos, 8)` filtered to class `PickableItem`
  — a NEW entity id (not seen before, not spawned by us) near the player is a
  drop candidate. Its Properties carry class/amount/health, its GetWorldPos
  the settled drop position.
- Confirmation gate: the player's inventory count of that class
  (`GetCountOfClass`, cached per tick) DECREASED since the last tick. This
  kills the false positives — items streaming in with the world, an NPC
  disarmed mid-fight dropping a weapon nearby, loot flying off a corpse —
  none of which decrement the local player's inventory.
- Verified live: a programmatic drop (`PlaceItem` from the player's inventory)
  decrements the count while the item lies on the ground (onion 1→0 on the
  ground, →1 again after pickup — observed).
- **Assumption, live-gated:** a real manual UI drop produces the same
  PickableItem-entity-plus-inventory-decrement signature as `PlaceItem`. It
  is the same engine inventory→world transition, but the manual-UI variant
  needs the human's E2E pass to be called observed. Note: menus freeze
  `Script.SetTimer` (WO-12), so a drop made inside the inventory screen is
  detected on menu close, a few seconds late — acceptable.
- Pickup detection is the same watcher inverted: a tracked drop's entity
  disappearing without us having removed it = something in THIS world took it
  (the local player, normally). Checked only while the player is within 80 m
  so streaming can't fake it; removal-by-us sets a flag first (loop
  prevention, the 0x13 idiom).

### Gate 1 verdict

Everything needed is reachable, generically (no per-item-type special cases:
class GUID + amount + health describe any inventory item). Phase 2 proceeds.

## Phase 2 — design

Wire (0x32–0x35, additive, no Protocol.Version bump — the standing idiom):

```
C→S 0x32 ItemDropUp:   [dropId:4 LE][itemClass:16][amount:2 LE][health:4f][x:4f][y:4f][z:4f]  (38)
S→C 0x33 ItemDropDown: [sourceGhostId:1] + upstream body verbatim                              (39)
C→S 0x34 ItemClaimUp:  [dropId:4 LE]                                                           (4)
S→C 0x35 ItemClaimDown:[claimerGhostId:1][dropId:4 LE]                                         (5)
```

- Drop: A's mod detects (Q3), A's agent mints dropId, sends 0x32; relay
  broadcasts 0x33 to others; B's mod holds it pending and materializes (Q1)
  when B is near. A's agent re-sends open (unclaimed) drops every 30 s so a
  late joiner converges — receivers dedupe by dropId (relay replays nothing;
  the Appearance idiom).
- Claim: whichever world's pickup watcher sees its local copy vanish sends
  0x34. **The relay echoes 0x35 to ALL clients including the claimant, in
  arrival order** — the relay's TCP serialization IS the arbiter, with zero
  relay state (leaner than the TimeSkip table: pure order-and-forward).
  Every client resolves a dropId on the FIRST 0x35 it receives and ignores
  the rest:
  - copy still on the ground here → remove it (flag first — no re-claim echo);
  - I had claimed it and claimer==me → confirmed, keep;
  - I had claimed it and claimer!=me → I lost the race: delete the gained
    item from my inventory by the recorded wuid (rollback), show a toast.
- The race case is exactly the both-claims-in-flight scenario: both clients
  send 0x34 within one RTT; the relay's arrival order picks the winner;
  the loser's rollback runs off the winner's 0x35. Neither client ever
  decides "I won" from local state alone — a client that never receives its
  own echo never confirmed.
- Why claimer-echo instead of broadcast-to-others: with others-only, two
  simultaneous claimants each see only the OTHER's claim and both roll back —
  the item evaporates. Echo-to-all makes the decision the same on every
  client. (Reasoned, then covered by the relay suite's ordering tests.)

Local bookkeeping (mod): `KCD2MP.itemSync.drops[dropIdStr]` = state machine
pending → ground → resolved/claimed_local, with entity name + wuid recorded at
materialize/registration time so rollback and removal are precise. Kill
switch: `mp_item_sync on|off`, default ON (the mp_npc_sync precedent).

## Phase 2 — results

Built exactly as designed. Files: `Protocol.cs` (0x32–0x35 + doc block),
`ClientSession.cs` + `TcpBroadcastService.cs` (relay: drop broadcast to
others, claim ECHO to all), `GameBridge.cs` (event parsing, dropId minting,
send/receive, 30 s heartbeat, per-connection lifecycle), `kdcmp.lua`
(`KCD2MP.itemSync` section: detector / materializer / watcher / claim
resolution, `mp_item_sync on|off`). `kdcmp.pak` rebuilt (`-NoInstall`; the
running game holds the old pak — the standing deploy gotcha).

### Wire/relay verification — observed (synthetic peers, no game)

`tools/Test-ItemSyncRelay.ps1`, **11/11 PASS**:
- I1 drop broadcast verbatim to others, nothing echoed to the dropper.
- I2 claim echo reaches ALL three peers including the claimant.
- I3 **the race**: B then C claim the same dropId; every peer — winner,
  loser, bystander — sees B's echo first and C's second, identical order.
  That order is the entire arbitration.
- I4 malformed (short) drop dropped by the relay; connection stays healthy.

### In-game verification — observed (one live game, functions driven exactly
as the agent drives them, via RemoteConsole)

The new Lua section was loaded into the RUNNING game (loadfile of an
extracted copy with shims for the file-local `mp_log`/`tickAlive`), so every
game-side path below is observed on real entities, not reasoned:

- **Sender detect**: a simulated drop (inventory item PlaceItem'd 2 m from
  the player — same engine transition as the UI drop) emitted
  `[KCD2-MP-EVT] … item_drop 4a6fa310-… 1 0.5496 2351.234 2145.826 117.889
  onion002697` — the exact contract the agent parses. The CreateItem a tick
  earlier (count going UP) correctly emitted nothing.
- **Receiver materialize**: `KCD2MP_ItemDropAdd` → pending → ghost-placed →
  `state=ground`, real entity `onion002779` at the requested position with
  the right class and amount. First attempt FAILED (`placed entity never
  appeared`) and exposed an ordering bug: the detector runs before the
  finalizer in the same tick and had already marked the new entity seen,
  which the finalizer used as its "is this the one I placed" filter. Fixed
  by snapshotting the pickables at the drop spot before PlaceItem
  (`d.preIds`) and diffing against that instead. Re-run: works.
- **Pickup → claim**: vanilla pickup (`item:OnUsed`) of the materialized
  copy → watcher emitted `item_claim 777010` on the next tick.
- **Won claim**: `ItemDropClaimed(…, isMine=true)` → resolved, item kept.
- **Remote claim of my drop**: ground copy removed (`removedByUs` flagged
  first — the watcher did NOT re-emit a claim for the removal).
- **Lost-race rollback, second item type**: a bandage STACK (amount 2) ran
  the whole receiver cycle — materialized with `nAmount=2`, picked up
  (count 11 → 13), then `ItemDropClaimed(…, isMine=false)` rolled it back
  by recorded wuid: count 13 → 11. Generic across item types as designed —
  nothing anywhere is per-item-type.

### Suites

- `tools/Test-ItemSyncRelay.ps1` (new): **11/11 PASS**.
- `tools/Test-TimeSkipRelay.ps1`: **26/26 PASS**.
- Farkle: **59/59 PASS**. Installer detection: **21/21 PASS**.
- Installer lifecycle suite: **not run** (real installs; sandbox-redirected
  `%LocalAppData%` — the standing WO-32 constraint; human-run before any
  release).

### One-human live session (same day, second half) — OBSERVED

Ran with the real game + the REAL rebuilt agent and relay + synthetic wire
peers (`tools/Bot-ItemPeer.ps1`, `tools/Bot-ItemClaim.ps1`), the human at the
keyboard. The old installed stack (launcher/agent/relay) was stopped first —
it predates 0x32 and cannot carry the packets. The game itself never
restarted: the new Lua section was already injected live, and the new agent's
re-arm loop auto-started `KCD2MP_StartItemSync` within seconds of connecting.

1. **Real manual UI drop** (Phase 1's one assumption) — OBSERVED. The human
   dropped an armor piece (`LegsPadded02_m01_E1`) from the inventory screen:
   detector emitted the exact contract line, the agent minted dropId
   1659804366 and put it on the wire, the synthetic peer received it with
   matching class/amount/health/position. The signature is identical to the
   programmatic PlaceItem drop.
2. **Inbound loop with real eyes and hands** — OBSERVED. A synthetic peer
   sent a drop; the mod materialized it via a bot ghost; the human SAW a
   hunting sword lying on the dirt (screenshot), got the genuine vanilla
   "Pick up E" prompt, picked it up by hand; the watcher claimed it; the
   relay echo confirmed (`claimed by us`) and both synthetic peers logged
   `claimer=1`. (A first onion attempt was reported not-seen in tall grass —
   likely occlusion, unresolved; the sword on dirt settled the render
   question.)
3. **Loser-sees-it-vanish** — OBSERVED. The human dropped a sword, kept
   looking at it; a synthetic peer claimed the dropId; the sword visibly
   disappeared in front of them; mod state `resolved`, `removedByUs` set
   first (no re-claim echo emitted).
4. **Reload restart-sweep under a real save load** — OBSERVED, all branches:
   `reload detected, re-baselined` (ghost-liveness discriminator; zero false
   drop emits from the rewound inventory), the human's own open drop
   reclaimed over the wire (peers converge to the owner's save state), and
   the peer-drop copy went back to pending and self-healed —
   re-materialized, after correctly retrying while ghosts were still being
   reconciled.
5. The 30 s heartbeat was watched live re-sending the one open drop.

Fidelity notes from the session:
- Weapon condition may not carry: the sword was sent health=0.8 but its
  tooltip showed 100% (the bandage's 0.8 DID carry to inventory earlier).
  Cosmetic-grade gap, not chased.
- The restart sweep's entity-missing check has no distance guard (unlike the
  watcher). A far-away own drop could be reclaimed even where a nearer check
  would have seen it. The outcome is still safe — peers drop their copies,
  the owner's world keeps whatever the save says, no duplication — the drop
  just leaves the sync early.

### Still live-gated (needs a second human / second machine — next build)

- The two-HUMAN race: both grabbing the same item within one RTT. The relay
  ordering half is wire-verified (I3) and the rollback half is game-verified
  (R6 + the vanish test above), but the combined human-timing case has not
  been run.
- The true two-machine loop with two full game installs (deploy matched
  sets, WO-46). The rebuilt pak is committed but NOT yet installed — the
  session ran on live-injected Lua; the next game restart loses item sync
  until `Build-And-Install-Mod.ps1` runs with the game closed.

### Known limits (deliberate)

- Chests/NPC pockets: out of scope by design; independent loot pools.
- A drop made while no relay connection is up broadcasts nothing (the tick
  only runs while the agent re-arms it).
- Orphan window: a heartbeat in flight when a claim lands can leave one
  just-joined peer holding a stale copy for at most one heartbeat interval;
  the next claim/removal converges it.
- `_itemSeen` grows with pickables encountered (strings, bounded by world
  content encountered per session; cleared on reload resweep).
