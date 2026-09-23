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
| end gate | **done** | §5: fresh-clone build green, `KCDMP-Setup-0.27.0.exe`, pak and privacy checks clean, no GitHub Release |

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

* **Version 0.27.0**, named by the maintainer when asked. `rollback/0.26.5`
  (annotated, on `774fc39`) tagged and pushed **before** `VERSION` moved;
  `VERSION`, README badge, release notes and the rebuilt tracked pak
  committed and pushed (`5aada66`) before the build.
* **Built from a fresh clone of `origin/main` at `5aada66`** with
  `tools\Build-Installer.ps1`, green on the first run (exit 0)
  (observed): relay round-trip 26/26, agent unit tests 174/174, sixteen
  synthetic suites (GhostInterp 35, NpcSmooth 48, WO-100.5 33, WO-102 196,
  WO-104 92, WO-108 96, WO-110 85, **WO-113 23**, WO-84 72, WO-86 47, WO-90
  70, WO-94 101, WO-95 32, WO-96 160, WO-98 50, WO-99 39), static checks
  7/7 and 6/6, native plugin rebuilt, payload smoke
  `RELAY-SMOKE ok id=0 protocol=v7 release=0.27.0 rtt_ms=15` with no
  assembly-load line, install manifest 1,024 entries, Inno Setup compile 39 s.
  * Noise, not failures: WO-100.5's trailing `RESULT: 0 passed, 0 failed` is
    the driver's own tally for a scenario that prints its own results (its
    gate reads the scenario's 33/0; unchanged since WO-102); the deps.json
    coherence check's 14-row WARN is informational by design (the smoke
    decides).

| artifact | size | sha256 |
|---|---|---|
| `release\KCDMP-Setup-0.27.0.exe` | 100,655,252 B | `9c00c9620c881784584b0f181c4ce90d2cdc04b2d9e95d1431c863478689184a` |
| `kdcmp\Data\kdcmp.pak` (built in the clone; not byte-deterministic) | 888,410 B | `6d98b59993000b286ec1a0126453c98f8321f4f594578da5be247d3561ffccbb` |
| `KCDMP.dll` | 511,488 B | `d5118f5a1480b5d7e56ac86006f59beca9ddb891d3f6c28bcaa9e4e816a4f765` |
| `KcdMpClient.exe` | 151,552 B | `01e15f132cdc32cbba87ee1b10b3a671050122bc2345f12eccd4369daea3395f` |
| `KcdMpServer.exe` | 151,552 B | `19ba88de9ca4f2cb73a9fc023f96f5bd74be6b8755b8ed3d6416442f4c45b271` |

* **Pak content check** (code-verified): `Scripts/Startup/kdcmp.lua` from
  the built pak carries `WO113-BUILD`, `KCD2MP_SetRespawn`, `mp_respawn`,
  `knockdown=disengage-stopfight`, `black_hold_s=6`,
  `grave_model=conciliation_cross_d`, `wake=nearest-hangoverSpot-100m+`
  and `grave_expiry_game_days=3`; `Libs/Tables/rpg/buff__kcdmp.xml` has
  both rows (`kcdmp_death_guard` `imm=1,upr=1` …`0a13`,
  `kcdmp_knockout_guard` `imm=1` …`0a14`, both `is_persistent="false"`);
  the manifest's MOD row carries the pak's sha256. Against the committed
  pak: four entries byte-identical; `kdcmp.lua` differs only in line
  endings (the clone's `core.autocrlf` checkout adds one CR to each of its
  13,532 lines — the whole 888,410 vs 874,878 B gap; LF-normalised it is
  byte-identical).
* **Privacy sweep** (code-verified): all 1,024 files in the release folder,
  read as UTF-8 and as UTF-16LE, for the Windows user name, the personal
  mail address parts, `duckdns`, `nip.io`, the repository owner, the
  maintainer's other handles (Steam persona, Discord name — never written
  here), private-range IPv4 literals, repository paths and any
  `<drive>:\Users\…` path. Every hit benign:
  * the launcher's placeholder `myserver.duckdns.org` (WO-55 UI copy,
    public source);
  * the launcher's links to this project's own GitHub Issues and Releases
    pages (the public repository URL);
  * 54 hits on `10.0.0.0` / `10.1.0.0` assembly-version strings (.NET and
    third-party assemblies, deps.json) and one private-range example
    address in a comment of the master server's `appsettings.json` (public
    source since WO-35);
  * NAudio's third-party PDB build paths (six assemblies). No first-party
    binary carries a user-profile path.
* The 42 files WO-113 committed (`774fc39..5aada66`), swept the same way:
  only the repository owner inside the pre-existing public repository URLs
  (README, the `kdcmp.lua` header, so the pak) — occurrence counts
  unchanged by WO-113. This section was swept after it was written.
* **Not run:** a live smoke of the fresh-clone DLL (the game was closed by
  the end gate; the live runs above used working-tree builds). The last
  native change, `cb65945` (the 4× snap retry), has not been seen finding
  ground live (findings §8).
* **Cleanup:** the Debug relay and agent stopped;
  `<game>/kcdmp-respawn-test.txt` absent; `<game>/kcdmp-concept.txt` holds
  its WO-97 line (77 B). The Setup exe stays in the session scratchpad's
  fresh clone; nothing was installed from it.
* No GitHub Release.
