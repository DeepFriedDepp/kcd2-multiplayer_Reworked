# WO-109 — progress: what ran, what did not, what blocked it

Session 2026-09-22, solo. Findings: `docs/WO-109-audit.md`.
**Docs only. No code, no pak rebuild, no installer, no VERSION bump.
Nothing ran two-player.** Paths: `<repo>`, `<install>` (Modding Tools
install), `<saves>`.

## 1. What ran

| phase | status | how |
|---|---|---|
| read-first docs | done | WO-108 findings/inventory/runbook/progress, WO-107 (both), WO-106 findings/native-migration/progress, WO-105 contradictions, in full |
| 0 — map | done | line counts from `git ls-files`; boundary and per-tick tables from code (audit Appendix A) |
| 1.1 — joiner path trace | done | read in full: `kdcmp.lua` 2200-6045, plus the chain gate (575-656), the menu pump, the hit-sensor setter, the combat cues and the console registration block; `GameBridge.cs` connect/main loop/receive 0x27/event handler/scan push; `HttpGameTransport.cs`; `LogTailGameTransport.cs` (code-verified) |
| 1.2 — identity | done | code plus §1.4 plus the offline save parse (below) |
| 1.3 — other writers | done | every `SetWorldPos`/`SetWorldAngles`/`Hide` call in `kdcmp.lua` classified; engine-side movers marked (inconclusive) where not provable |
| 1.4 — determinism probe | **ran live** | §3 below |
| 1.5 — sinking | done (static) | no Z instrument exists, so nothing could be measured |
| 1.6 — predictions | done | audit §1, dated 2026-09-22 |
| 2 — bug hunt | done | own reads plus three parallel read-only sweeps (relay/protocol; Lua bug classes; agent/DLL/pipeline). **Every sweep claim that reached the ranked list was re-read at its cited lines by the author** before inclusion; one line citation was corrected |
| 3 — Lua vs C++ | done | verdict table, audit Phase 3 |
| 4 — relay | done | bandwidth arithmetic from codec byte layouts and observed entity counts |
| 5 — structure | done | the main-chunk local count (180) by column-0 scan; upvalue estimate by per-function identifier intersection |

## 2. Offline save parse (observed, no game needed)

- `.whs` layout per `SaveGameReader.cs`: `[FFFFFFFF][descLen][XML]` followed
  by zlib blocks. Inflating `<saves>\playline1\quicksave023.whs` (137
  blocks, 4.46 MB) and `<saves>\playline2\save021.whs` (138 blocks, 4.49 MB)
  gives the engine state stream.
- Inside it, each entity record has the shape
  `e5 0c | u32 len | name | 00 | u32 entityId | 8-byte GUID`, where
  `len = strlen(name) + 13`.
  - 580 and 582 records.
  - 564 names in common.
  - **519 with the identical entity id and GUID. The 45 that differ are all
    `SpawnedAnimal_*`.**
- The stored ids equal WO-108's live `eid=` values (`ttkc_barbora 2F836`,
  `ttkc_woman_10 2F835`, `ttkc_woman_2 2472`).
- Soul WUIDs (`soul:GetId()`) appear nowhere in either stream as a
  little-endian u64, so they are assigned at load.
- **Use after the session:** to check a joiner's `MP-PAUSE … eid=` against
  the owner without host-side identity logging, parse the owner's save the
  same way. The scripts are in the session scratchpad (`whs_inflate.py`,
  `whs_cmp.py`); they are not committed.

## 3. The live read (§1.4)

- **Launch.** `KingdomCome.exe` (Modding Tools build) started the way the
  launcher does: no args, working directory = `<install>`.
  - The 0.26.4 pak loaded (`MOD INIT` ×2). No agent, no DLL, no network.
  - Console per WO-106 §2 (`GET …/ExecuteString?command=`, `#`-Lua).
- **Probe.** One Lua line per run. For every NPC, NPC_Female and Horse within
  250 m of the player it logged `WO109-ID …`:
  - name, class, entity id, WUID, position, distance;
  - same-name entity count (any class);
  - whether `GetEntityByName(name)` returns that entity.
- **Runs.**
  - `pl1-a`: `wh_sys_LoadGame 1 quicksave023` from the menu. World clock
    running after 47 s; dumped 20 s later.
  - `pl1-b`: the same command again, in-process quick path. Dumped 35 s later.
  - `pl2-a`: `wh_sys_LoadGame 2 save021`, the other playthrough. Dumped 40 s
    later.
  - Plus one map-wide count (20 km sphere): 22,644 entities, 456 NPC-class,
    1 duplicate NPC name, 2 NPCs with runtime ids ≥ 0x70000 at that moment.
- **Results.** Audit §1.4 table (observed):
  - 74/80 identical across the same save's two loads; the 6 that differ are
    runtime event spawns.
  - 72/72 identical across the two playthroughs.
  - 0 duplicates within 250 m.
  - 0 lookups returning another entity.
- **Not run.**
  - A cold-relaunch variant. Cross-process agreement is already on record
    (WO-106 §1.4's three WUIDs, 2026-09-19, match today's), and every extra
    launch costs a kcd.log rotation (§5).
  - A same-spot, two-machine dump, which needs a peer.
- **Cleanup.** `#System.Quit()`; the process was gone in 2 s. No save was
  written. The probe's own `kcd.log` is copied to the session scratchpad.

## 4. Not done, stated plainly

- **Two-player: everything.** Every two-player statement in the audit is a
  prediction (audit §1).
- **R2 (console quoting) was not confirmed live, deliberately.** The WO
  allows one live read, and that was §1.4. The evidence:
  - the 38 templates are code-verified;
  - the engine's quoting of `%line` was *observed* in WO-106 §1.1.

  The one-line confirmation is audit §1.6.0 step 1.
- **Nothing was measured on the agent path:**
  - main-loop and flush cadence (`MP-POSCADENCE`);
  - native scan duration (`dur_ms`);
  - the joiner's puppet-tick cost.

  §3 had no agent or DLL. R6 and R13's magnitudes stay (inconclusive).
- **R3's coverage estimate** uses the observed walk order of
  `System.GetEntitiesInSphere`. Whether the DLL's iterator yields the same
  order is (inconclusive).
- **The WO-104 two-player contention (148 at ~0.41 m with the lever on,
  2026-09-18) is unexplained.**
  - WO-107/108's relax reading does not fit it: a stationary stream could
    not provoke the relax.
  - It is carried as failure mode 3; nothing here resolves it.
- **The 50 ms→1000 ms sinking A/B** named in the prompt is recorded in no
  repo doc. Whether it actually changed the rate (R2) can only be settled
  from that session's kcd.log (`NPC-PUPPET-RATE set=`).

## 5. Side effects on the machine (disclosed)

- **Steam was not running.**
  - The first launch logged `SteamApi_Init failed`, started the Steam client
    about 12 s later as a side effect, and sat at a "License not verified"
    window with the console API down.
  - That instance (no save loaded) was killed and the game relaunched once
    Steam was up.
  - **The Steam client is still running.** Close it if it is not wanted.
- **kcd.log rotation.**
  - Each launch moves `<install>\kcd.log` into `<install>\logbackups\`, which
    holds one file.
  - The two launches therefore **overwrote the 2026-09-21 WO-108 smoke-test
    kcd.log**; only the stub of the failed launch is in `logbackups\` now.
  - WO-108's findings doc quotes the lines that mattered. Recorded as a
    memory for future sessions.
- `System.Quit()` wrote no save. The saves used were only read.

## 6. Session hygiene and tooling notes

- Three read-only sweeps ran in parallel. Their scratch files (scripts, a
  harness copy for the WO-90 run) are in the session scratchpad, not the repo.
- The WO-90 harness was run in memory against a scratch copy with a one-line
  `SetFlags` stub: 69/70 as shipped, 70/70 with the stub. No repo file was
  touched.
- Bash heredocs in this harness collapse `\\` in Python source (WO-108's
  note); scripts with backslashes went through the Write tool.

## 7. End gate

Docs only: `docs/WO-109-audit.md`, `docs/WO-109-progress.md`. Committed with
the `WO-109:` prefix and pushed to `origin main`. The privacy sweep of both
files found no username, hostname, DDNS name, Steam id or personal path.
