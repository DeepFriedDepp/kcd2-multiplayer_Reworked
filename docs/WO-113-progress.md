# WO-113 — progress: what ran, what did not, what blocked it

Companion to `docs/WO-113-findings.md` (the results). Evidence marks as
there. `<game>` = the Modding Tools install root; `<repo>` = this repository.

---

## 1. What ran

| phase | status | note |
|---|---|---|
| 0 — re-find every address by anchor | **done** | findings §4; every piece fails closed and names itself in `WO113-BUILD` |
| 1 — the guard | done | `kcdmp_death_guard` (imm=1,upr=1, non-persistent) in the pak's buff table; session-gated; 250 ms presence check (a load strips it) |
| 2 — detector + fist/weapon split | done | findings §3 |
| 3 — executors | done, **reworked live** | fade, grave, cleaners, native HealBleeding, native teleport (ExecuteTeleportImpl, SetPos-shaped fallback), fall-damage hold; knockdown rebuilt twice with the maintainer (findings §5.8) |
| 4 — the grave | done, **reworked live** | map-mark crash fixed (§5.1); model and height fixed with the maintainer (§5.12) |
| 5 — Game Over guard | done | ids 0–8, 26 (alive) and 44 swallowed; loud log on every call |
| 5+ — execution | done (synthetic trigger) | reconcile + punishment gameplay reset (§5.11); the WO's bounded condition met |
| 6 — multiplayer | done | pipe 0x0C–0x0F/0x88/0x91–0x93; wire 0x3E–0x43; mirrors; heartbeat re-announce; disconnect clears |
| 7 — toggle, presets, marker, runbook, predictions, catalogue | done | `mp_respawn`; clean on / legacy off; `WO113-BUILD` (Lua + native); §4 below; findings §1, §7 |
| 8 — solo smoke, 11 items | 10 pass, 1 not run | findings §6; items 8–10 with the maintainer; item 10: no quest brawl in the save |
| end gate | see §5 | |

### Method notes

* About a dozen game launches (the Modding Tools build), each after
  copying `kcd.log`, the logbackups slot and the native mirror log to the
  session scratchpad (none committed). One crash (the map, findings §5.1).
* The DLL was injected into a running game after `wh_sys_LoadGame 1
  quicksave031`/`025` with `KCDMP_LauncherInjector --pid`; the relay and
  agent were the repo's Debug builds on loopback; a small Python TCP client
  stood in for the second player; the pipe was driven by a scratch client
  before the real agent was used.
* Live triggers: REST `CombatSoul/TakeDamage`, `SetState` (hunger/health),
  Lua `AddBuff` for bleeding and poison, a Lua lift + impulse for the fall,
  and the DLL's opt-in `kcdmp-respawn-test.txt` (`gameover <id>`, `spots`,
  `hud`, `punish`, `classprobe`, `mapdump`, `marktype`, `gravemodel`,
  `knockmode`, `snaptest`). Lua `inventory:AddItem` returned grave contents
  between runs.
* Every edit went through a scratch Python helper asserting each old string
  occurs once (bash heredocs mangle backslashes; long heredocs are cut).
* Gates at the last code commit: relay tests 17 → 26 (9 new WO-113 cases),
  agent tests 174, Farkle 59, synthetic suites (WO-113 new: 23/23; WO-108
  96; WO-102 196; WO-104 92; WO-110 85; WO-96 160; WO-94 101; WO-84 72;
  WO-90 70; WO-98 50; WO-86 47; WO-99 39; WO-95 32; WO-100.5 33; NpcSmooth
  48; GhostInterp 35), static checks 7/7 and 6/6.

---

## 2. Decisions taken

With the maintainer, in the session:

* **Version 0.27.0.**
* **Respawn ≥ 100 m from the death** (nearest otherwise), plus an 8 s
  targeting exclusion from the wake — after a respawn beside the killer.
* **Map marker: keep digging** (not ship without) — found the crash cause
  and the drawn type (findings §5.1–5.3).
* **Knockdown: disengage, not the vanilla knockout** — the WO's rule; the
  game's own `StopFight` does it (findings §5.8).
* **A 6 s black screen** after deaths and knockdowns (asked for 5–10 s).
* **The grave model: #11, `conciliation_cross_d`**, picked live from 21.
* "A caption on the black screen" — wanted, not required for this release.

Mine:

* The keyring stays with the player (quest keys live on it; vanilla will not
  drop it).
* The grave sits 0.2 m below the navmesh (the measured navmesh-over-terrain
  gap), with one 4× wider search when the first misses.
* The vanilla-knockout path and the shenanigans context stay in the DLL as
  test-only code (`knockmode knockout`), off by default.
* No grave when nothing is movable; a floor within 10 s of a respawn only
  restores (no second grave or teleport); a knockdown floor is always new.
* The punishment reset only fires when `disabledEvents` reads true.

---

## 3. Side effects on the machine (disclosed)

* **Saves:** `wh_sys_TestSaveGame` wrote `playline1/quicksave031` (a grave in
  it). WO-111's `quicksave025` was loaded, never written. All throwaway;
  safe to delete.
* **A crash** (the map, §5.1 of the findings): BugSplat left
  `<game>/BugSplatAttachments/2026-09-23_14_22_47_*` (kcd.log, a copy of
  `quicksave031`, `whdlversions.json`). Not uploaded by us; safe to delete.
* **Installed:** `kdcmp.pak` into `<game>` several times (last: the 0.27.0 pak).
* **Probe files:** `<game>/kcdmp-respawn-test.txt` created and deleted;
  `<game>/kcdmp-concept.txt` changed for two probes and restored to its
  WO-97 content.
* **CVars touched, all restored:** `wh_rpg_DisablePlayerFallDamage` (by
  hand for the A/B, and by the DLL's hold), `wh_rpg_ExcludePlayerFromTargeting`.
* **The agent's Debug-folder log files** rotated (they are not in the repo);
  its settings file was not rewritten (overrides were command-line only).
* No GitHub Release. Nothing was sent anywhere but loopback.

---

## 4. Runbook — the first two-player 0.27.0 session

1. Both machines install `KCDMP-Setup-0.27.0.exe`. The relay refuses a mixed pair.
2. After the DLL is injected, each native log must show
   `WO113-BUILD … guard=armed c2=installed … knockdown=disengage stop_fight=on`
   and kcd.log `WO113-BUILD respawn=on …`. Anything `OFF`/`NOT-` → that
   piece is off on that machine; say which.
3. **Death:** A picks a fight with an armed NPC and loses. A: black ~7 s,
   wake at a spot ≥ 100 m away, full health, a grave where A died. B: A's
   ghost falls, then snaps to the spot; a cross and a grave icon at A's
   death spot (B cannot open it).
4. **Loot:** A walks back and takes everything. Both: cross and icon gone
   within ~5 s (B: plus network).
5. **Reload:** A reloads an older save. B: A's grave disappears within 1 s.
   B reloads: A's graves come back on B within 30 s.
6. **Knockdown:** A starts a fistfight with an unarmed NPC, sheathed, and
   loses. A: black ~7 s, wake in place at 30 hp, the NPC walks away. B: A's
   ghost lies down, then stands. No grave.
7. **Off:** A types `mp_respawn off` → the next death is a vanilla Game Over
   (and B sees the old death behaviour). `mp_respawn on` restores.
8. Collect both native logs, both kcd.log, both agent.log, the relay log.
   Grep: `MP-RESPAWN`, `MP-GRAVE`, `MP-GAMEOVER`, `[respawn]`, `[grave]`.
9. Mark every findings §1 row hit / miss.

---

## 5. End gate

(filled below as it runs)
