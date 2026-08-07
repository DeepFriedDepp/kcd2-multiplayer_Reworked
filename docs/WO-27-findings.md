# WO-27 — release-ready the already-working aggro

Investigated 2026-08-07, live against KCD2 (Modding Tools build), save
`playline2`, human present at the machine throughout. `playline2` was
re-confirmed disposable at session start.

**Bottom line up front: no new mechanism was built. The reactive-combat
capability WO-26 found needed no code. What this session found and fixed was
narrower — the ghost dedupe/leak fix was already half-done, uncommitted, from
an interrupted prior attempt at this same WO, and the running game was still
executing the OLD `kdcmp.lua` the whole time until that was discovered and
corrected. Live A/B testing pinned down exactly what `mp_enable_aggro` still
does; a controlled multi-reconnect test proved the dedupe fix holds.**

---

## Starting state: a prior attempt was already in progress

`git status` at session start showed `kdcmp.lua` modified but uncommitted,
with no corresponding `docs/WO-27-*.md`. Reading the diff: `KCD2MP_GhostAudit`,
`mp_ghost_identity`, `KCD2MP_RemoveStaleGhostsForPlayer`,
`mp_remove_entity_verified`, and the `KCD2MP_SpawnGhost`/`KCD2MP_RemoveGhost`/
`KCD2MP_ApplyGhostName` changes described in this WO's Phase 2 brief were all
already written, matching the brief's own prescribed fix almost verbatim.
Nobody had tested or committed it. Treated as this session's own draft to
verify and finish, not re-derived from scratch.

---

## Phase 1 — what does `mp_enable_aggro` actually do now?

### Reading the code first

`KCD2MP.aggroEnabled` (`kdcmp.lua:22`) gates two things directly in Lua:

1. **`DrawWeapon`** (`kdcmp.lua:1549-1556`) — cosmetic only, already documented
   as such since WO-17 (does not flip `CombatSoul.HasMeleeWeapon`).
2. **`aggro_toggle` event emission** (`KCD2MP_EnableAggro`,
   `kdcmp.lua:1284-1297`) — read by the .NET agent, not acted on in Lua.

The real mechanism is in `GameBridge.cs`. `_aggroEnabled` (line 97) gates
`TriggerReactiveAggroAsync` (line 1306), which is called from two places:

- **Line 456-460** — `OnLocalHit`: Henry (the local player) lands a real hit
  on an NPC → every currently-named ghost is marked hostile, standing in for
  "any ghost present in this world is now recognisably part of the fight
  Henry started."
- **Line 1061** — inbound `DamageDown`: a peer's ghost lands a hit on an NPC
  in this world → that peer's own ghost is marked hostile.

`TriggerReactiveAggroAsync` (line 1306-1324) calls
`_combat.SetFactionHostileAsync(guid, hostile: true)` — the native `SetParent`
attach from WO-15/16/17, onto one real hostile faction
(`trosecko_enemies_bandits_prepadeniAmbushers_group1`, confirmed live below),
held for `AggroHoldDuration` = 20s (line 110), then released.

This is a **different, older mechanism** than the reactive combat WO-26
found. WO-26's finding — a ghost defends itself and joins nearby fights — is
unconditional and lives entirely in the engine's own AI/soul/brain system,
untouched by any of this. The toggle's mechanism is additive: real native
faction membership, broadcast to every nearby NPC of an opposing faction, not
just whoever the ghost is already fighting.

### Live A/B test

Full pipeline up: game running via Modding Tools with `KCDMP.dll` injected,
`KcdMpServer.exe` relay, `KcdMpClient.exe` agent connected. Target NPC
`ttkc_man_32` (guid `20dd03e3-8db2-4377-8427-99f25bcbffdd`), synthetic peer
via `tools\Test-AggroE2E.ps1`, which connects through the real relay, spawns a
real ghost via `KCD2MP_SpawnGhost`, and sends a `Damage` packet attributing a
hit to the target NPC — the exact path `GameBridge`'s `DamageDown` handler
sees from a real second player.

**Toggle OFF** (`KCD2MP.aggroEnabled=false`, read live before the test):

```
target NPC : ttkc_man_32  health=100
1. peer connected to relay as ghost id 2
2. sent Position -> agent spawns ghost 'kcd2mp_2'
3. sent Damage (peer's ghost hit ttkc_man_32 for 3)
   NPC health: 100 -> 97  (damage applied: True)
   ghost FactionNode/Parent/Name: trosecko_settlements_trosky_soldiers_guards
PARTIAL - damage applied, but the ghost was never attached to the hostile faction
```

Toggled on via `KCD2MP_EnableAggro("on")`, confirmed live
(`KCD2MP.aggroEnabled=true`, read back). **Toggle ON**, fresh synthetic peer:

```
target NPC : ttkc_man_32  health=97
1. peer connected to relay as ghost id 3
2. sent Position -> agent spawns ghost 'kcd2mp_3'
3. sent Damage (peer's ghost hit ttkc_man_32 for 3)
   NPC health: 97 -> 94  (damage applied: True)
   ghost FactionNode/Parent/Name: trosecko_enemies_bandits_prepadeniAmbushers_group1
PASS - damage applied, and triggered the reactive aggro attach on the peer's ghost
```

Toggled back off afterward, confirmed live
(`KCD2MP.aggroEnabled=false`), restoring the default.

**Read plainly: the only variable that changed between the two runs was the
toggle. Off, the ghost's faction node is untouched by the hit. On, the
identical hit flips it to the real hostile bandit faction.** This is the
same mechanism and the same faction WO-16/WO-25 already characterized; WO-27
is the first session to confirm it is still wired correctly against the
current spawn shape (post-WO-22 soul-backed ghosts) and to isolate it
cleanly from WO-26's always-on reactive combat via a controlled A/B.

The synthetic peer's own TCP disconnect at script end triggers
`KCD2MP_RemoveGhost`, which removes the ghost entirely — so the ~20s
auto-revert (still present in code, `GameBridge.cs:110`, unchanged this
session) was not independently re-observed live here; it was not in question
and nothing in this session's changes touches it.

### Gate 1 — stated plainly

- **Reactive combat (self-defense, joining fights) is always on**, exactly as
  WO-26 found. Confirmed again here: it does not depend on the toggle.
- **`mp_enable_aggro on` adds a real, live-verified, additive effect**: the
  ghost gets attached to a real hostile faction for ~20s after landing or
  receiving a hit, so any nearby NPC hostile to that faction — not only
  whoever it is already fighting — can target it. This is proactive,
  faction-wide recognition, layered on top of the reactive combat that
  happens regardless.
- **`mp_enable_aggro off` adds nothing beyond the reactive baseline.** No
  faction attach fires; engagement stays limited to whoever directly attacks
  the ghost or is already fighting near it.
- `DrawWeapon` remains cosmetic-only, gated the same way, unchanged.

---

## Phase 2 — fix the ghost duplication/leak

### The fix, as found (uncommitted, from the interrupted prior attempt)

- **`mp_remove_entity_verified`** (`kdcmp.lua:1312-1340`) — replaces a single
  unchecked `System.RemoveEntity` call with up to 4 passes, reading the
  entity back by id and by spawn name (`kcd2mp_<id>`, never the display
  name) between attempts, and logging if it is still alive after all 4.
- **`mp_ghost_identity` / `KCD2MP_RemoveStaleGhostsForPlayer`**
  (`kdcmp.lua:1392-1413`) — identity keyed on the Steam nick
  (`KCD2MP.ghostNames[id]`, arrives via the 0x03 Name packet at handshake,
  before the first Position packet), not the connection id. Called from
  `KCD2MP_SpawnGhost` **before** the new entity is spawned, so a reconnect
  never has a moment with two ghosts for one person.
- **`KCD2MP_SpawnGhost`** (`kdcmp.lua:1415-1454`) additionally checks for an
  untracked entity already standing under the target spawn name (a save
  load, a mod reinit, or a prior silent `RemoveEntity` failure) and removes
  it via the verified path before spawning over it.
- **`KCD2MP_ApplyGhostName`** (`kdcmp.lua:1619-1654`) — the `e:SetName(name)`
  call that used to rename the entity away from its `kcd2mp_<id>` spawn name
  (breaking `SoulList`'s own lookup key, per WO-26) is removed. The
  nameplate players actually see is drawn by this mod from
  `KCD2MP.ghostNames`, not the entity's engine name, so nothing depended on
  it.
- **`KCD2MP_RemoveGhost`** (`kdcmp.lua:2589-2613`) now calls
  `mp_remove_entity_verified` by spawn name instead of a single unchecked
  `RemoveEntity` by id.
- **`KCD2MP_GhostAudit`** (`kdcmp.lua:1346-1375`) — new, counts live ghost
  entities directly from the world (by probing spawn names), not from
  `KCD2MP.ghosts` agreeing with itself, specifically so a verification claim
  cannot be "the bookkeeping table says it worked."

### The running game was on the OLD code

`KCD2MP_GhostAudit()` returned `nil` when first called against the live
game — the fix above was sitting uncommitted in the repo but had never been
built into `kdcmp.pak` or installed. Closed the game (human's own action),
ran `tools\Build-And-Install-Mod.ps1` (packs `kdcmp.lua` into
`kdcmp\Data\kdcmp.pak`, installs to `<ModdingTools>\Mods\kdcmp\`; the game
must be closed because it holds the pak open), human relaunched via Modding
Tools and reloaded `playline2`. Confirmed the new code loaded: `[KCD2-MP]
MOD INIT` present, and `KCD2MP_GhostAudit()` now resolves and returns real
counts.

### Live multi-reconnect test

`tools\Test-GhostReconnect.ps1` (new, this session): connects a synthetic
peer under the **same identity** ('`wo27-reconnect-peer`') 4 times in a row,
deliberately **without closing the previous TCP connection first** — the
harder case than a clean disconnect, since a clean disconnect already
triggers `KCD2MP_RemoveGhost` via the relay's own Disconnect broadcast and
was never the bug. This exercises the pre-spawn identity dedupe specifically:
an old connection still technically open (dropped without a clean
disconnect, or not yet noticed by the relay) when a new one for the same
player arrives.

```
--- reconnect 1: id 5 -> ALIVE ---                                    PASS (1 live)
--- reconnect 2: id 6 -> ALIVE, id 5 -> gone ---                       PASS (1 live)
--- reconnect 3: id 7 -> ALIVE, ids 5,6 -> gone ---                    PASS (1 live)
--- reconnect 4: id 8 -> ALIVE, ids 5,6,7 -> gone ---                  PASS (1 live)

total live ghosts for 'wo27-reconnect-peer' across 4 reconnects: 1
GATE 2: PASS
```

Each prior id's `SoulsByName/kcd2mp_<id>` was read back individually via the
debug API after every reconnect — not inferred from the fix looking right.

A global `KCD2MP_GhostAudit()` taken after this test (and after closing all
4 leftover sockets, which triggers real disconnects) read
`registered=1 live=1 [kcd2mp_1]` — one ghost total in the whole world, which
is the host's own local loopback ghost (Steam nick `M31`, from the launcher's
own host+join-self setup), itself observed cycling ids **4 → 1** across an
unrelated organic reconnect during this same window, with the count staying
at exactly 1 throughout. Two independent reconnect sequences (one synthetic
and controlled, one organic and incidental) both held at exactly one ghost
per identity.

### Gate 2 — confirmed by count, not by the fix looking right

Exactly one live ghost per identity survived every reconnect in both the
controlled 4x synthetic test and the incidental host-side reconnect that
happened in parallel. `System.RemoveEntity`'s unreliability (WO-25, WO-26)
is worked around by `mp_remove_entity_verified`'s read-back retry rather than
trusted on a single call.

---

## Phase 3 — docs brought in line with reality

- **`README.md`** — added a new status-table row for reactive ghost combat
  as its own always-on, no-toggle, shipped-since-WO-22 feature (previously
  undocumented as a player-facing capability). Rewrote the
  `mp_enable_aggro` row to state precisely what the toggle adds on top of
  that baseline (per Phase 1's live A/B), rather than describing it as the
  thing that makes ghosts able to fight at all. Corrected two now-false
  "known limits" bullets that predated WO-22/WO-26 and still claimed ghosts
  "never fight back" — one in the aggro known-limits list, one in the
  separate "known not achievable" list further down the file, which had
  drifted out of sync with each other.
- **`docs/PROJECT-STATE.md` §4** — added a WO-27 amendment under the
  existing aggro/stimulus entry, stating the toggle's precise live-verified
  effect (native faction attach, additive to the always-on reactive combat)
  so a future session does not re-derive Phase 1 or misread the toggle as
  the thing gating whether ghosts can fight.

No change to `VERSION`, no installer build, per `docs/VERSIONING.md`.

---

## Regression

`dotnet test dotnet\KcdMp.Farkle.Tests\KcdMp.Farkle.Tests.csproj`:
**59/59 passed**, 31 ms. Unrelated to this WO's changes (dice engine), run as
the project's standing automated suite; nothing else in the repo has an
automated (non-live) suite that touches `kdcmp.lua` or `GameBridge.cs`'s
aggro path.

## Cleanup

All WO-27 test entities removed and confirmed by live read-back: the two
`Test-AggroE2E.ps1` ghosts (ids 2, 3) and all four `Test-GhostReconnect.ps1`
ghosts (ids 5-8) — 0 remaining, verified via `KCD2MP_GhostAudit` and
individual `SoulsByName` lookups, not assumed from script exit. `playline2`
was never saved over.

## Files touched

- `kdcmp/Data/Scripts/Startup/kdcmp.lua` — Phase 2 fix (found uncommitted at
  session start from an interrupted prior attempt; verified and completed
  here, not rewritten)
- `tools/wo27-lua.ps1` (new) — ExecuteString driver + `[WO27]` log reader,
  same shape as `tools/wo26-lua.ps1`
- `tools/Test-GhostReconnect.ps1` (new) — the multi-reconnect Gate 2 test
- `README.md`, `docs/PROJECT-STATE.md` — Phase 3
- `docs/WO-27-findings.md` (this file)
- `docs/WO-27-progress.md`

## Draft release-note language

> **Aggro toggle behavior clarified, ghost duplication on reconnect fixed.**
> Ghosts have defended themselves and joined nearby fights automatically
> since a much earlier update — this was previously undocumented. What
> `mp_enable_aggro` actually controls: turning it on makes a ghost that
> lands or takes a hit recognizable as hostile to nearby NPCs generally, not
> just whoever it's already fighting, for about 20 seconds. Off (the
> default), a ghost still fights back when attacked, just without that wider
> recognition. Separately, reconnecting no longer leaves a duplicate ghost
> behind — a player who disconnects and rejoins now cleanly replaces their
> old ghost instead of leaving it stranded.

Ready for the human to assign a version and ship when chosen.
