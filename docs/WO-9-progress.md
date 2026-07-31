# WO-9 progress — appearance sync

Session date: 2026-07-31. Branch `main`. One machine, one copy of the game,
no second player — every live test used the same synthetic-peer substitute
every other test script in `tools/` uses for that reason.

**Status: done.** Full detail, evidence and the one honest gap are in
`docs/WO-9-appearance-sync.md` — read that first for anything below that
needs more than a pointer. This file is the session log.

---

## What shipped

- **Phase 0** (research, live against the real game): established that
  `EquipmentManager.EquippedArmorsByClassId` (reflection debug API) reads the
  real per-item equipped state for any soul — player or ghost — where the
  Lua `BaseClothingPreset`/`GetInitialClothingPreset()` binding goes blank
  the moment a player stops matching a preset. Established that
  `EquipmentManager.EquipItem`/`UnequipItem` + `Inventory.CreateItems` can
  apply an **arbitrary, previously-unworn item class** to an NPC and have it
  render — user-confirmed twice live (helmet removed, boots swapped) —
  which is the reflection-layer upgrade on the old "Lua `EquipInventoryItem`
  doesn't render" finding, not a contradiction of it. Reached the **best
  case per-item tier**, not the preset-snapping fallback the brief planned
  for.
- **Phase 1**: `GameBridge.AppearanceLoopAsync`, a 3 s poll of the local
  player's equipped set via a new `IGameTransport.ReadEquippedItemClassesAsync`,
  entirely in the C# agent — no Lua involved in detection, since the
  reflection API is already open to the agent the same way position reads
  are.
- **Phase 2**: `Protocol.AppearanceUp`/`AppearanceDown` (`0x1A`/`0x1B`),
  relay forwarding in `ClientSession`/`TcpBroadcastService` (mirrors
  Damage/Death exactly, no new server state), and
  `GameBridge.ApplyAppearanceAsync` on the receiving end — diffs against
  per-ghost state tracked client-side, equips/unequips only what changed,
  and verifies-and-retries against a schedule sized to a real measured
  write-latency trait (see below), because a `true` return from `EquipItem`
  was repeatedly observed to precede the actual state change by anywhere
  from under a second to several seconds.
- **Phase 3**: `mp_sync_appearance` console command
  (`kdcmp.lua`/`KCD2MP_SyncAppearance`), same event-channel pattern as
  `mp_invite`. Verified live: command → `[KCD2-MP-EVT] appearance_sync` in
  `kcd.log` → agent log shows `manual resync requested` then a forced send.

Protocol version bumped 4 → 5 (existing test scripts' hardcoded
`$PROTOCOL_VERSION` updated to match — `Test-Combat.ps1`, `Test-Sessions.ps1`,
`Test-Dice.ps1`).

## New test script

`tools/Test-AppearanceE2E.ps1` — the two-agent local test the WO's
definition of done asks for, built the same way `Test-CombatE2E.ps1` is: a
synthetic TCP peer stands in for the second player, a real running agent
against a real game applies what it receives to a real ghost, verified
through the debug REST API.

## A real bug found and fixed after a live demo

Asked to demo this for a screenshot, found that a synced ghost showed almost
no visible change — the diff never accounted for the ghost's own spawn-time
`white_red` preset (full plate), so it could only ever add the real
player's items on top of an untouched suit of armor. Fixed by seeding each
ghost's tracked "applied" state with the known preset item list
(`GameBridge.GhostSpawnPresetItems`) instead of starting empty, so the first
diff correctly proposes removing the whole preset. Verified live
post-fix (`+4 -9` on first apply) and confirmed visually once the preset's
plate was stripped. This was a real correctness bug in Phase 2, not a
polish item — full detail in `WO-9-appearance-sync.md`.

## The one thing not fully nailed down

Write-path latency for `EquipItem`/`UnequipItem` is genuinely variable and
was chased at length without a clean root cause. The theory that held up
longest — relay/Position-spawned ghosts being structurally less reliable
than console-spawned ones — was **disproven** during the demo session: the
same console-spawned ghost that had worked instantly minutes earlier later
showed the identical flaky behavior. The one correlate that held across
every session was recency of the native DLL injection (fresh injection →
reliable writes; same session later, heavier churn → less reliable), but
appearance sync never touches the DLL/pipe at all, so this is a noted
correlation, not an explanation. Documented as a real, reproduced
characteristic rather than smoothed over — the design's answer is
"eventually converges via the heartbeat," not "converges within N seconds,"
and that was verified to actually hold, not just assumed.

## Verification run this session

- `Test-Combat.ps1` 14/14, `Test-Sessions.ps1` 22/22 (timeout case
  intentionally skipped), `Test-Dice.ps1` 10/10, `KcdMp.Farkle.Tests` 59/59 —
  all against a freshly built relay, all green, no regressions.
- `Test-Pipe.ps1` — PASS, against a freshly injected `KCDMP.dll` (rebuilt
  from unmodified native source; nothing in `native/` changed this session).
- `Test-AppearanceE2E.ps1` — PASS, multiple runs, including one full
  close/rebuild-pak/relaunch cycle to pick up the new `mp_sync_appearance`
  Lua command.
- Manual visual confirmation from the user, live: ghost helmet removal and a
  boots swap to a completely new item class, both via the raw reflection
  REST calls this design is built on.
- Two-real-human procedure: written, **not executed** — one machine, no
  second player today. See the procedure at the end of
  `WO-9-appearance-sync.md`.

## Next session starts here

Nothing outstanding from this WO. If picking up appearance sync again:

- **Weapon sync** is the obvious next increment — `EquippedWeaponsByClassId`
  has the identical shape to the armor map used here, same mechanism, out of
  scope for this WO because the motivating bug was specifically the outfit.
- **Hairstyle/face** are confirmed out of reach (`Soul.Archetype` has no
  such reflected property) — do not re-probe this without a new capability
  showing up elsewhere first.
- If the write-latency variance under load ever becomes a visible problem in
  real play, the next thing to try is the DLL-injection correlation noted
  above: is a freshly-injected `KCDMP.dll` genuinely making unrelated debug
  REST writes more reliable, and if so, why? This session found the
  correlation but didn't explain it, and ruled out the more specific
  "relay-spawned vs console-spawned ghost" theory that seemed to explain it
  at first.
- Otherwise: nothing else is known-broken. `docs/PROJECT-STATE.md`'s ledger
  should be updated to mark the brief's Emotes/Duelling work orders as the
  next candidates, per the priority call at the top of this WO's brief.
