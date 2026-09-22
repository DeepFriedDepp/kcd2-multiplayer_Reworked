# WO-110 — progress: what ran, what did not, what blocked it

Session 2026-09-22, solo. Findings: `docs/WO-110-findings.md`. Runbook:
`docs/WO-110-peer-test-runbook.md`. Release notes:
`docs/releases/RELEASE-NOTES-0.26.5.md`. **Nothing ran two-player. Nothing
was deleted. One commit per fix; nothing reverted.** Paths: `<repo>`,
`<install>` (the Modding Tools install), `<saves>`.

## 1. What ran

| phase | status | note |
|---|---|---|
| read-first docs | done | WO-109 audit + progress, WO-108 findings + toggle inventory + runbook + progress, WO-106 §1.1/§2/§3.6/§3.7, in full |
| 0.1 — confirm R2 live | **done, R2 held** | `mp_entity_id Dude` → `')' expected near 'Dude'` on the 0.26.4 pak; bare worked (observed) |
| 0.2 — the 200-local cliff | done | 180 → 124 (four namespace tables), `Test-WO110LuaLocals.ps1` (≤ 170), live `loadfile` compile ok |
| 1.1 — R2 | done + **live checklist run** | 38 templates unquoted (41 by the end), nil-safe handlers, static test; 76 forms then 82 forms live, 0 errors |
| 1.2 — R10 | done | glob over every suite + 2 static checks; WO-90 mock 70/70; payload smoke (found §3.2 of the findings); DLL always rebuilt |
| 2.1 — R1 | done | `readNative=false`; presets rebased (clean = 0.26.5, legacy = 0.26.4) |
| 2.2 — R3 | done | nearest-first, chunked, `mp_npc_track_max` 200; comment fixed; observed live 78 pushed / 40 nearest under legacy |
| 2.3 — R13 | done | gate on authority (code-verified; solo is always the authority) |
| 2.4 — cull radius | done | 60 m default, `mp_cull_radius`, floor 10, ceiling 150 loud; legacy 30 |
| 2.5 — R14 | done | Z interpolation, `MP-NPCZ`, 3-D detectors; observed silent before a reload, firing after (§3.4) |
| 3.1 — R4 | done | relay-local else lowest id; SortedSet pool; Ack before ready; `MP-AUTHORITY-OWNER`; reconnect got id 0 back (observed) |
| 3.2 — R5 | done | `MP-NPCID` on acquire + first emit; eid rule in the runbook |
| 3.3 — R7 | done | `KCD2MP_OnChainDeadRestart`; observed on a live quick-load |
| 3.4 — R11 | done | `ExecuteNowAsync`; kill test: peer saw `Disconnect` in 2 ms (relay path) |
| 4.1 — R9 | done | drop counters both sides; 0x3D release refusal (observed); protocol v7 |
| 4.2 — R15 | done | sanitiser, anchored tag, `EscapeLua`, case-fold; relay test |
| 4.3 — R6 | done | seq + senderMs on 0x26/0x27; sender-time renderer; `mp_npc_senderclock`; `TCP_NODELAY`; before/after A/B **not** run (no Lua joiner solo) |
| 4.4 — queue policy | done | bytes + pressure coalescing (code-verified; never engaged solo) |
| 5.1 — R12 | done | DLL rebuilt 402,432 B; used live for the whole stack run |
| 5.2 — R8 | **not shipped** | bounded search found no entity → intelligent-object path; flagged (findings §5) |
| 6 — silent failures | done | one commit |
| + console ceiling | **found and fixed live** | two commits (encoded budget; atomic check-and-add) |
| 7 — presets, marker, runbook, predictions | done | 19 rows per preset; `WO110-BUILD`; runbook rewritten; predictions in findings §1 |
| 8 — smoke, 12 items | 11 ran (observed), 1 n/a (R8) | findings §4 |
| end gate | see §4 | the first two fresh-clone runs each failed on a synthetic suite that PASSED every check yet exited 2: `Test-WO110Synthetic.lua` (new) and `Test-WO99Synthetic.lua` (never gated before R10) printed their results instead of setting the driver's `OUT` global. Both fixed; a print-only scenario can no longer ship |

### Method notes

* Every edit went through a scratch Python helper that asserts each old
  string occurs exactly once and preserves the file's line endings and BOM
  (CRLF and BOM files are mixed in this repo; two edits failed on that and
  were redone). Bash heredocs collapse `\b` in Python source — raw strings.
* Console transport: the WO-106 §2 shape. **Do not `Start-Sleep` more than
  ~30 s in a foreground tool call; poll with a bounded loop.**
* Live Lua probes with `loadfile` of a scratch driver (WO-48 pattern), no
  pak rebuild: `zdriver.lua` streamed one real NPC at 100 ms with seq and
  sender ms, this machine as the joiner.
* The live stack for items 3/4/7 was the launcher's pieces by hand: the
  rebuilt relay from `bin\Release`, `KCDMP_LauncherInjector` into the running
  game, the rebuilt agent from `bin\Release`, all started `-WindowStyle
  Hidden` after the injector had stolen focus once.
* Three pak rebuilds and three cold relaunches (R2 confirmation, R2
  checklist, Phase 8). `kcd.log` was copied to the session scratchpad
  before every relaunch (four copies; none committed).
* Synthetic runs at every commit: WO-108 87→94, WO-102 196, WO-104 92,
  WO-110 (new) 54→85, WO-90 69/70→70/70, WO-84 72, WO-86 47, WO-94 101,
  WO-95 32, WO-96 160, WO-98 50, WO-99 39, WO-100.5 33, NpcSmooth 48,
  GhostInterp 35; relay tests 13→17; agent unit tests 170→174.

## 2. Decisions taken

* **R4's rule: (a) and (b) both.** Relay-local client when exactly one
  ready client is on a loopback socket (the launcher starts relay and agent
  on the host), else lowest id from a sorted free-id pool so a reconnect
  gets its old id back. Both fall through to the old behaviour for a
  dedicated relay box or a same-machine test.
* **R3's cap: 200.** The largest count observed inside 150 m of a dense
  town spot was 76, 60 m holds 45–48, the native reply's own byte ceiling
  is ~200–400 entries, and the owner's per-tick state reads scale to ~4 ms
  per 100 ms at 200 (WO-103 §5.1 × 2.5). Legacy = 40.
* **R1's toggle keeps the 0.26.4 semantics** (6 s freshness) rather than a
  "fresh as the live read" native path: the toggle exists only as the
  legacy rollback, and a native path as fresh as a live read would be the
  live read.
* **R14's attractor counter stays XY**; the contention/violation/diverge
  detectors are 3-D. The WO-40 `MP-NPCFIGHT` numbers stay comparable with
  WO-104's.
* **The relax tag's band was not widened** although §3.4 shows the relax
  at ratio 0.2–0.33 above `RATIO_MAX` 0.12: a heuristic change needs a live
  A/B, and the lines are logged either way.
* **The console budget is 1,900 encoded** against a measured ceiling of
  2,067–2,166: margin for the `#`, the pcall wrapper and any escaping.
* **`mp_spawn_armor` stays in the checklist** but the runbook and the
  scratch script now say to run it last or not at all (§3).

## 3. Side effects on the machine (disclosed)

* **Henry died.** GAME OVER, "bled to death", at ~14:02 during the smoke
  run, most likely from the two factionless armed NPCs `mp_spawn_armor`
  spawned 3 m from him during the R2 checklist. The Game Over screen was
  left for ~12 minutes (every Lua timer frozen, the console API answering)
  before it was noticed; `E` was pressed and `quicksave023` reloaded. The
  earlier two game instances of this session "exited on their own" 40–45
  minutes after the same checklist ran; `Gameplay ended` was not searched
  for in their logs (inconclusive).
* **`<saves>\playline1\quicksave024.whs`** was written by
  `wh_sys_TestSaveGame` at 14:00 with the Z driver running and Henry
  possibly already bleeding. **Do not reuse it; delete it.** `quicksave023`
  is still the WO-108 throwaway.
* Two mod test NPCs (`kcd2mp_npc_1`, `kcd2mp_npc_2`) were spawned per
  launch by the checklist; NO_SAVE-flagged, gone with the reload.
* **The game is left running** (the Modding Tools build, WO-110 pak,
  `quicksave023` reloaded after the death, `KCDMP.dll` injected), no agent,
  no relay: both of mine were killed. **Relaunch through the launcher before
  any peer session.**
* Steam was already running and was not touched.
* `kcd.log` rotated three times; every predecessor is in the session
  scratchpad.
* The rebuilt paks were installed into `<install>\Mods\kdcmp\` by
  `Build-And-Install-Mod.ps1` (the WO-110 pak is what the game runs now).
* Two detached git worktrees were created under the scratchpad for the
  payload-smoke publishes and pruned.

## 4. End gate

Version `0.26.5` as named by the maintainer in the prompt (not assumed).
`rollback/0.26.4` tagged at `f698046` -- the last commit with 0.26.4 code
and VERSION (WO-109's docs-only commit on top of the 0.26.4 build) -- and
pushed. `VERSION`, README badge, release notes and the rebuilt tracked pak
committed and pushed to `origin main` **before** the build. (Side effect:
`git push --tags` also pushed a pre-existing local tag `BETA` that was not
on the remote; it was deleted from the remote in the same minute.)

Built from a **fresh clone of `origin/main`** (not the working tree) with
`tools\Build-Installer.ps1`, three runs:

1. **Failed** at `Test-WO110Synthetic.ps1`: 85 checks passed, exit 2 --
   the scenario printed its results instead of setting the driver's `OUT`
   global. Fixed (`f86d763`, after `f2191bd`, whose heredoc turned the
   escape into a literal newline).
2. **Failed** at `Test-WO99Synthetic.ps1`: 39 passed, exit 2, the same
   print-only contract, pre-existing since WO-99 and never gated before
   R10. Fixed (`55bf1a6`).
3. **Green** at `55bf1a6`: relay round-trip 17/17, agent unit tests
   174/174, fourteen synthetic suites green (35/48/33/196/92/94/85/72/47/
   70/101/32/160/50/39), both static checks (7/7, 6/6), native plugin
   rebuilt, payload smoke `RELAY-SMOKE ok id=0 protocol=v7 release=0.26.5`
   with no assembly-load line, install manifest 1,024 entries, Inno Setup
   compile 47 s.

| artifact | size | sha256 |
|---|---|---|
| `release\KCDMP-Setup-0.26.5.exe` | 100,611,295 B | `2817918a24555b1ba801d69bb2384ed3d2818cb32cb3bb59336b6a84851a6f3b` |
| `kdcmp\Data\kdcmp.pak` (built in the clone; not byte-deterministic) | 883,977 B | `6204fa53f45fed71f1078be95df22aaaae3c375711ed9a265126a30dd8a31dae` |
| `KCDMP.dll` | 402,432 B | `98a0d9683e1ba38a0705a3c78bf38ecbee08c48dae756072eda884c62b985aa9` |
| `KcdMpClient.exe` | 151,552 B | `2886641fba8fd3b64d3d58b3fa2f4e6b57d105a7719a0259e65913d483f23a36` |
| `KcdMpServer.exe` | 151,552 B | `33001074c87d6b025063fe41e1837c764c3cb2ef11a117b1c8aa4c99c8370d06` |

**Pak content check:** `Scripts/Startup/kdcmp.lua` extracted from the
built pak contains `WO110-BUILD`, `KCD2MP_SetCullRadius`,
`KCD2MP_SetNpcTrackMax`, `KCD2MP_SetNpcSenderClock`, `MP-NPCZ`,
`KCD2MP_OnChainDeadRestart`, `KCD2MP_AuthorityOwnerLog`, `MP-NPCID`, the
unquoted `(%line)` templates and `pause_issued_npcs`; the manifest's MOD
row carries the same pak sha256.

**Privacy sweep:** every file in the release folder (1,024), read as UTF-8
and as UTF-16LE, for the Windows user name, `duckdns`, `nip.io`, the
personal mail domain, the maintainer's Steam persona (taken from the relay
log, never written here), private-range IPv4 literals and repository
paths. Eight hits, all benign: the launcher's own placeholder text
`myserver.duckdns.org` (WO-55 UI copy, in the public source), NAudio's
third-party PDB build paths, and one `10.1.0.0` assembly version. The
committed WO-110 docs were swept the same way: clean. No GitHub Release
was created.

The Setup exe is in the fresh clone under the session scratchpad
(`fresh\release\KCDMP-Setup-0.26.5.exe`); nothing was installed on this
machine from it (the running game carries the working-tree pak and DLL of
the same commit).
