# WO-118 — progress: what ran, what did not, what it cost

Session 2026-09-23, solo. Findings: `docs/WO-118-findings.md`. Field page:
`docs/WO-118-runbook.md`. Harness: `tools/wo118/README.md`.
**Nothing ran two-player.** Paths: `<install>` (Modding Tools install),
`<saves>`, `<scratch>` (the session scratchpad, not committed).

## 1. Phases

| phase | status | note |
|---|---|---|
| 0 — addresses by anchor, fail closed | **done** | RTTI vftables + required instruction bytes per slot; armed on all 4 launches; DISARMED path code-verified (findings §3.1) |
| 1 — agent→DLL samples, ring, sender clock, WUID check, Z on the segment | **done** | 906 binds, 0 WUID mismatches; two stale-state traps fixed (§3.2); 1 ms stamps (§3.13) |
| 2 — per-frame write; Lua keeps start/release/pause/gait/draw/swings/death | **done** | render = written 0.000 mm; slope and fight: no sinking (§3.3) |
| 2b — the peer's ghost | **done** | traced first (50.1 % frozen), moved to the native write (0 %); pace wobble remains (§3.4) |
| 3 — detach, skipped in dialogue/cutscene, MP-DETACH | **done** | 16-NPC table incl. bartender, field worker, guard spot, sellers, carpenter, sawyer (scale runs); 1 m / 3 m / 30 m walk-away → 0.0000 (§3.5) |
| 4 — MP-NPCPULL; Lua detectors labelled legacy | **done** | lag frames separated (9aefa8f); `path=legacy` (a1c5b5f) (§3.6) |
| 5 — `mp_npc_trace` CSV gate | **done** | green three times this WO; `tools/wo118/phase5_gate.py` (§3.7); shipped-build run §5 below |
| 6 — cost at 40 and 80; network noise | **done** | noise found the sender-clock headroom defect, fixed (92023cc, §3.8); cost §3.9; 80 needed a 200 ms emit (§3.10) |
| 7 — presets, WO118-BUILD, runbook, predictions | **done** | toggles in both presets (4781c86, cfea218); runbook; predictions in findings §1 |
| end gate | see §5 | the version is the maintainer's call |

## 2. Live sessions

Steam running. Every launch: `<install>\Bin\Win64ReleaseSteamLTO_DLL\KingdomCome.exe`
started directly, `wh_sys_LoadGame 1 <save>` once the API answered, world-time
ratio 1, the WO-111 `death_protection` guard added (non-persistent), KCDMP.dll
injected from `<scratch>` with `KCDMP_LauncherInjector --pid --dll`, the relay
on 7778, the agent connected as the joiner behind a placeholder peer (relay
rule 2). `kcd.log`, `logbackups\kcd.log` and the native mirror log were copied
to `<scratch>` before every relaunch.

| session | DLL | what ran |
|---|---|---|
| 1 | writer + agent feed + Lua bind (d1164e4–4781c86) | `quicksave027` loaded, **fresh throwaway `quicksave033` written at once** (`wh_sys_TestSaveGame`); smoke, walker/seat traces, detach A/B, the 16-NPC activity runs, the legacy baselines, the stale-authority bug |
| 2 | + lag frames, restarts, 1 ms stamps, ghost (9aefa8f–6258502) | ghost traced legacy then native; the first noise runs (contaminated, §4) |
| 3 | + cost line, a lateness-only allowance | noise batch (found the headroom defect), scale 40/64, slope, fight, ghost before |
| 4 | + the need tracker, ring 16 (92023cc) | noise batch (clean), ghost after, scale 40/80 (100 and 200 ms emit, minimized), Phase 5 gate ×2 |

`quicksave024/026/028/031/032` untouched. Nothing was saved after
`quicksave033` (each relaunch killed the process). Daytime throughout
(09:30–10:00 in-game at ratio 1).

## 3. Commits

`d1164e4` writer · `af18b09` agent feed · `4781c86` Lua bind + fallback ·
`cfea218` detach · `eb0436c` CombatRole fix · `9aefa8f` lag frames / restarts /
parented · `bd26225` 1 ms stamps · `6258502` ghost · `4d92c14` cost line ·
`92023cc` jitter allowance · `a1c5b5f` `path=legacy` · `f299310` pak ·
`704845a` `tools/wo118` · docs. Nothing reverted.

## 4. Gaps, side effects, stated plainly

* **Methodology error, session 2:** noise runs spaced less than 15 s / 60 s apart
  inherited the previous run's stream sequence and sender-clock minimum (the
  two traps fixed in 9aefa8f and the 5 s clock reset). Those runs were
  discarded and redone on sessions 3–4.
* **The background frame limiter** (findings §3.11) put several session-3/4 runs
  at 26 fps before it was understood (P0–P3 of the lateness-only batch, the
  ghost-after batch, the first 80-puppet run). They are reported with their fps
  and not compared with 75 fps runs.
* **REST under load:** with dozens of puppets, harness commands were refused
  (503) or silently lost; the scale schedule moved into Lua timers.
* **Henry was teleported** 83 m for the slope run and back (throwaway, not
  saved). Scale runs puppeted most of the village and released it; NPCs walked
  back to their activities.
* **Not done:** two-player; 80 walkers at 10 Hz (ingress, §3.10); ghost sender
  time (protocol); the dice minigame with detach; a traced reload with puppets
  bound.

## 5. End gate

**Dress rehearsal before the bump** (the version is the maintainer's; everything
else ran first so the bump is the only step left):

* **Pushed first.** `rollback/0.27.0` (annotated) tagged on `ab51371` — the last
  commit with 0.27.0 code and `VERSION`, docs-only on top of the 0.27.0 build
  `5aada66` — and pushed **before** any bump.
* **Built from a fresh clone of `origin/main` at `66ebace`** with
  `tools\Build-Installer.ps1`, green on the first run (exit 0) (observed): relay
  round-trip 26/26, agent unit tests 181/181, seventeen synthetic suites
  (GhostInterp 35, NpcSmooth 48, WO-100.5 33, WO-102 196, WO-104 92, WO-108 96,
  WO-110 86, WO-113 23, **WO-118 85**, WO-84 72, WO-86 47, WO-90 70, WO-94 101,
  WO-95 32, WO-96 160, WO-98 50, WO-99 39), static checks 7/7 and 6/6, native
  plugin rebuilt, payload smoke `RELAY-SMOKE ok id=0 protocol=v7 release=0.27.0
  rtt_ms=25`, install manifest 1,024 entries, Inno Setup compile. (WO-100.5's
  trailing `RESULT: 0 passed, 0 failed` is its driver's own tally, as before.)

| artifact (pre-bump, not shipped) | size | sha256 |
|---|---|---|
| `release\KCDMP-Setup-0.27.0.exe` | 100,764,626 B | `92936e30e00b0d18505b1b9ddcf5c3bc87ab27727952912c4dd86c7cea193b58` |
| `kdcmp\Data\kdcmp.pak` (built in the clone) | 909,095 B | `eb72b13eb0a9f93e27d0d2305585206eede1cd2587f17fb2addbd0a5a25d310b` |
| `KCDMP.dll` | 582,144 B | `f4dc0763381520b02ac306cfe5870837917a4c78b57840cf9f867104f52d45b6` |
| `KcdMpClient.exe` | 151,552 B | `12fe05d3517941170126636ecb9b5eda0cc07b94e8463d37983332b892b8fe8e` |
| `KcdMpServer.exe` | 151,552 B | `1fdf45b2ec8029a251364cf96201e6821816af3f2aad233b4d631cad8e6ef309` |

* **Pak content check** (code-verified): `Scripts/Startup/kdcmp.lua` from the
  built pak carries `WO118-BUILD`, `KCD2MP_SetNpcNativeWrite`,
  `mp_npc_native_write`, `KCD2MP_SetNpcDetach`, `mp_npc_detach`,
  `KCD2MP_NpcDetach`, `mp_npc_trace`, `KCD2MP_NpcNativeAlive`,
  `KCD2MP_NpcNativeSync`, `KCD2MP_GhostNativeSync`, `KCD2MP_NpcNativeHold`, the
  preset rows and `path=legacy`; the manifest's MOD row carries the pak's
  sha256. Against the committed pak: four entries byte-identical; `kdcmp.lua`
  identical after LF normalisation (the clone's `core.autocrlf` checkout adds one
  CR per line, 13,879).
* **Privacy sweep** (code-verified): all 1,024 files in the release folder, read
  as UTF-8 and UTF-16LE, for the Windows user name, the personal mail address
  parts, `duckdns`, `nip.io`, the repository owner, private-range IPv4 literals,
  repository paths and any `<drive>:\Users\…` path. Every hit benign and as
  WO-113 recorded: NAudio's third-party PDB build paths (six assemblies, the
  NAudio author's machine); the launcher's links to this project's public GitHub
  Releases page and its `myserver.duckdns.org` placeholder; `10.0.0.0` /
  `10.1.0.0` assembly-version strings (26 files) and one example address in the
  master server's `appsettings.json`. No first-party binary carries a
  user-profile path. The 47 files WO-118 committed (`ab51371..66ebace`), swept the
  same way: only the repository owner inside a pre-existing public credit URL in
  `kdcmp.lua` (1 occurrence before and after WO-118). Save files: none
  committed; no save header quoted anywhere.
* **Phase 5 gate against this build: GREEN** — clone's pak installed, clone's
  DLL injected, clone's relay and agent (findings §4). Jitter runs P1/P2 on it:
  0 frozen, speed sd 0.02 m/s.
* No GitHub Release. Nothing installed through Setup (the pak was copied into
  `<install>\Mods\kdcmp\Data\` as `Build-And-Install-Mod.ps1` does; the DLL was
  injected from the session scratchpad).

**After the maintainer names the version:** `VERSION` + README badge commit,
release notes `docs/releases/RELEASE-NOTES-<version>.md`, push, a new fresh
clone, `Build-Installer.ps1`, pak check, privacy sweep, the Phase 5 gate once
more, then this section records the final artifacts.
