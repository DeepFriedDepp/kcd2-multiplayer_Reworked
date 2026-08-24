# WO-49 — real swing animations for puppeted NPCs, not just player ghosts

Worked 2026-08-24 (Fable 5). Extends the WO-45/46/47 native swing mechanism
(`ghost_swing` + the weapon-class catalog) from player ghosts to the NPC
puppet stream, replacing the WO-40 Phase 6 guard-flick cue.

**Status: code staged and suites green; NOT yet live-verified.** The game was
not running during this session (REST :1403 refused), so every claim below is
tiered explicitly. `tools/Test-NpcSwingE2E.ps1` is the one-human live gate.

> **Label collision, flagged:** memory from a same-day session
> (`kcd2mp-wo49-state`) describes a *different* WO-49 — the dice-payout
> `inventory:CreateItem` port. None of that work is in this tree (the dice
> win path at kdcmp.lua:1301 still calls the broken
> `ItemUtils.AddMoneyToInventory`, and no WO-49 commits/docs existed before
> this session). This document is the in-repo WO-49. The dice fix is real,
> still needed, and lost or living elsewhere — re-do or recover it.

---

## Phase 1 — what's different about an NPC versus a player ghost

### 1.1 The observer's copy is a REAL local entity — and that decides the design

A player ghost is a spawned soul whose weapon truth arrives over the wire
(appearance sync). A puppeted NPC (WO-32) is the observer's **own world's
copy** of the same-named entity, with its own real equipment. The swing an
observer should see is the one matching the weapon **visible in the
observer's world** — so the weapon is resolved locally, receiver-side, and
**nothing changes on the wire** (0x26/0x27 payloads and the flags byte are
untouched; old peers interoperate).

### 1.2 Reading the NPC's weapon class

- **Chosen surface:** the same per-soul REST read the appearance layer uses —
  `SoulsByName/{name}/EquipmentManager/Equipped{Armors,Weapons}ByClassId`,
  already wrapped as `ReadGhostEquippedItemClassesAsync`. Proven for spawned
  ghost souls (WO-10, WO-47 Gate 1). **Unproven (stated plainly): whether a
  world NPC's soul resolves by its entity name on this surface.** The live
  harness answers this; an empty read degrades to the WO-46 longsword
  constant — the same visual every ghost swing had before WO-47 — and never
  blocks the swing.
- **Rejected alternatives:** `human:GetItemInHand(handId)` exists in the
  shipped scriptbind docs (`C_ScriptBindHuman`), but is unobserved on this
  build and returns an item handle with **no proven handle→ItemClass-GUID
  step** in this sandbox (WO-48 mapped the live `ItemManager` table:
  GetItem/GetItemName/GetItemOwner/GetItemUIName/... — none verified to
  yield a class GUID). Two unproven links versus one; kept as the backup
  route if SoulsByName fails the probe.
- Class → fragment rows is the existing WO-47 catalog, unchanged
  (`WeaponClassOfItem`, `SpecFor`, `RowsFor`).

### 1.3 The swing trigger — unchanged, and why

The authority still cannot see an NPC's real swings from Lua (WO-39/40:
Mannequin-locked, no OnAction hook for NPC attacks; nothing new has appeared
since). The one visible signal remains the authority's **own health dropping
near a weapon-drawn tracked NPC** → flags bit 3 on 0x26. Known limits carry
over verbatim: misses are invisible, NPC-versus-NPC attacks are invisible,
and only hits on the authority itself cue. A more direct signal would be a
native hook on the NPC attack path — new research, out of scope here.

### 1.4 Confirmed vs uncertain, before building

| claim | tier |
|---|---|
| Puppet stream applies to the real local NPC; DrawWeapon/health/KO bits work | observed (WO-32/38/40, shipped) |
| `ghost_swing` renders a full swing on a spawned ghost, per-weapon | observed (WO-45/46/47) |
| `ghost_swing` addresses actors by entity id generically (resolve → GetOrCreateCombatActor → parse vs own animDB → QueueAction) | read in `combat_construct.cpp`; **never run against a world NPC** |
| World NPC's live brain tolerates a queued combat action (no AI suppression in the puppet stream) | **unknown — the central live question** |
| SoulsByName REST resolves world NPCs by entity name | **unknown — probed by the harness** |
| Entity-id emit idiom (`tostring(e.id)` hex tail) works for any entity | observed for ghosts/horses/pickables (WO-46/48) |

## Phase 2 — what was built (staged, UNTESTED live)

No wire change, no DLL change, no protocol bump — the exact WO-47 shape.

| layer | change |
|---|---|
| Lua | `KCD2MP_ApplyNpcState` puppet-start now emits `npcid <name> <entityIdHex>` (ghostid idiom). New `KCD2MP_NpcNativeSwingHold(name)` (one-shot window + clears any pending Lua cue, so a raced packet cannot double-render), `KCD2MP_NpcSwingCueFallback(name)` (re-arms the WO-40 cue when native fails), `KCD2MP_NpcSetOversized(name, guid)`. The puppet draw branch routes an Oversized main-hand through `DrawFromInventory` INSTEAD of `DrawWeapon` (WO-47's polearm lesson + ordering trap, applied receiver-side). |
| agent | Caches `npcid` (name → local entity id; re-validated against `NpcNamePattern` because the name is later interpolated into Lua on the fallback path). On cache and on each sheathed→drawn stream transition, reads the local copy's equipped set (SoulsByName). On an incoming 0x27 with bit 3 set, dead/KO bits clear, and a cached entity id: **strips bit 3 from the flags handed to Lua** and queues the native swing (`GhostSwingAsync` on pipe 0x06) + `KCD2MP_NpcNativeSwingHold`; on failure (DLL absent, stale id after reload) calls `KCD2MP_NpcSwingCueFallback` — late but visible, the ghost path's exact degradation ladder. `ResolveNpcSwingSpec` prefers the Oversized class's rows when one is equipped (so the swing matches the item `DrawFromInventory` put in hand — `SpecFor`'s min-class-first pick would choose a sidearm's rows), then `SpecFor`, then the WO-46 longsword constant. Per-NPC swing index rotates rows (slash/stab), same as ghosts. |
| tools | `Test-NpcSwingE2E.ps1` — one-human live gate: synthetic peer claims world authority (Test-NpcSyncE2E's restart idiom), streams drawn heartbeats then swing-cue packets at a real NPC near the observer; auto-checks puppet start, npcid emit, native `SWING entity=` lines matching the npcid, and that the old Lua cue did NOT run; render quality is the human's verdict. |

Staleness policy matches ghosts: `npcid` entries are only ever overwritten by
the next puppet start (a reload mints new ids and restarts puppets); a stale
id in the window fails clean in the DLL and falls back to the Lua cue.

## Suites

- Farkle 59/59 PASS.
- Test-SwingCatalog PASS (rebuilt client).
- `dotnet build` clean (0 errors), `kdcmp.pak` rebuilt (`-NoInstall`).

## The live gate (pending — run when the game is up)

1. Deploy the matched set (client + server, client-first copy order — the
   Json-10 trap) and the rebuilt pak; restart the game.
2. `tools/Test-NpcSwingE2E.ps1` next to a weapon-carrying NPC (a guard is
   ideal). Watch the NPC.
3. Pass = real, complete swings at WO-47 player-ghost quality; the
   `equipped item class(es) read` agent line also settles the SoulsByName
   question. If the equipped read comes back empty, swings still render on
   the longsword fallback row — that outcome = "mechanism generalizes,
   weapon fidelity needs the GetItemInHand backup route" and is a valid,
   documented partial.
4. If practical, repeat near NPCs of other weapon families (WO-47 catalog
   already covers them; nothing per-weapon was added here).

## Explicitly out of scope, flagged for the next two-person session

**Joint damage on a shared NPC:** whether two players simultaneously
attacking the same NPC produce one consistent, shared outcome (health
merging, kill attribution, loot state) is untouched by this WO — this WO
only changes what an NPC's own attack *looks like* to an observer. It is a
real, separate, deeper question (authority arbitration, not rendering) and
belongs to a dedicated session with two humans.

Also not done: no VERSION/release change (docs/VERSIONING.md — user owns
version strings); ranged NPC attacks (WO-47 §6's scope statement stands);
NPC swing-zone mirroring (the cue carries no zone information).
