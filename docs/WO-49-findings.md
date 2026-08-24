# WO-49 — real swing animations for puppeted NPCs, not just player ghosts

Worked 2026-08-24 (Fable 5). Extends the WO-45/46/47 native swing mechanism
(`ghost_swing` + the weapon-class catalog) from player ghosts to the NPC
puppet stream, replacing the WO-40 Phase 6 guard-flick cue.

**Status: LIVE-VERIFIED, one-human gate passed 2026-08-24** (two harness runs,
8/8 checks each; human watched real, complete swings on a world NPC). The
first run also exposed a real regression — the NPC's own brain re-holstering
mid-test — fixed and re-verified live the same session (§ Live gate below).

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
| `ghost_swing` addresses actors by entity id generically (resolve → GetOrCreateCombatActor → parse vs own animDB → QueueAction) | read in `combat_construct.cpp` at build time; **now observed on a world NPC** (live gate) |
| World NPC's live brain tolerates a queued combat action (no AI suppression in the puppet stream) | **observed — swings render fully; the brain's pushback is on the DRAWN STATE, not the action** (live gate) |
| SoulsByName REST resolves world NPCs by entity name | **observed** — `SoulsByName/ttkc_man_1/EquipmentManager/EquippedWeaponsByClassId` returned its real set (`longswordOld`, Type=4) |
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

## The live gate — PASSED (2026-08-24, two runs, one human)

Deploy verified first (Verify-Install ALL CHECKS PASSED — matched set +
fresh pak on disk). Test NPC: `ttkc_man_1` (world NPC, own real longsword).

**Run 1 (8/8 harness checks):** puppet start, npcid emit (entity 32981),
drawn apply, three native `SWING entity=32981` lines with **row rotation**
(slash→stab→slash — the stab row is proof the catalog + SoulsByName read
ran, since the fallback constant is slash-only), old Lua cue did NOT run.
**Human: the NPC drew his sword and did a real, successful swing** — but
after two swings **his own brain re-holstered and returned him to his wall
lean**, and cue 3 rendered bare-handed with a janky snap-back.

**Diagnosis:** puppets keep their AI unsuppressed by design (WO-32); the
drawn-state apply was transition-gated (`p.appliedDrawn`), so a brain-side
holster was never corrected — the stream kept saying "drawn", the gate never
fired again.

**Fix (same session):** the puppet tick now re-asserts the streamed drawn
state against the entity's REAL `IsWeaponDrawn()` every 1.5 s (live puppets
only, held off during one-shots and right after a transition apply); a
mismatch re-draws (Oversized-aware, via the shared `mp_npc_draw`) or
re-holsters, logging `re-asserted drawn (local brain fought back)`. Deployed
into the RUNNING game via loadfile injection (WO-48 idiom, mp_log shimmed —
the timer chain resolves the global by name each reschedule, so the
redefinition took effect on the next 50 ms tick), and into the pak for
future sessions.

**Run 2 (8/8 again):** kcd.log shows the re-assert fired twice; native log
shows all three swings queued with rotation. **Human: "Much better that
time, he sheathed his sword but then grabbed it back out and swung."** All
three swings rendered with the weapon in hand — the re-holster happens, the
re-assert corrects it before the next cue, exactly as designed.

**Weapon generality:** not separately re-proven live here — the per-weapon
rows are the SAME catalog WO-47 live-verified across four families on
ghosts, and this WO's resolution path feeds it the same class ids (the
longsword rotation above is the observed instance). The Oversized
draw-through-DrawFromInventory branch for NPCs is implemented from WO-47's
live-proven pattern but was not itself watched on a halberd NPC — stated
as read-but-unrendered.

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
