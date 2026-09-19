# WO-104 — progress

Session 2026-09-18. Findings: `docs/WO-104-findings.md`. Field runbook:
`docs/WO-104-field-runbook.md`. Input: the first two-player session since
0.23.2 (0.26.1, same day, both machines).

## Phases

| phase | state | evidence |
|---|---|---|
| 0 — time sync formatting | **shipped, alone, first** (`6637e5e`, pushed): `time_now` formatted `%.0f`, never `tostring()`; dice wager hardened the same way; parser left strict. Audit of every other numeric field on the Lua→agent channel: two exposed, both fixed; rest named in findings §1.3 | (observed) the failure in agent.log; (code-verified) fix + audit; (synthetic) WO-104 suite (a) 7/7 with a `%g` tostring mimic that reproduces `1.00255e+06`; agent `WorldTimeFormatTests` +13 → 170/170 |
| 1 — replicas for contested NPCs | **built behind `mp_npc_replica_on\|off\|status`, default OFF** (`5ad5b06`). Body is `NPC`+`NoAI=true` soul-bound to the original's `soul:GetId()` — not `NPC_NAI`, which is unreachable with a soul on this build (findings §3.1). Promote on the first violation, one-call spawn-then-hide; demote on sheathed 10 s / death / release / toggle / host-off / stop / sweep. `npcid` + new `npc_replica` event re-point native swings and outbound damage. No wire change | (code-verified); (synthetic) WO-104 suite (b)–(i), 91/91 total; **nothing live** |
| 2 — pause lever default | **shipped OFF** (`f9df723`). 155/155 violations `paused=1` recorded next to WO-102.5 §1.1, §6.1 and WO-102 §4.3. Code + toggle kept | (observed) joiner kcd.log; (synthetic) WO-104 (j), WO-102 (f) updated |
| 3 — verification | **done** (`4ae2e6e`): WO-104 suite added to `Build-Installer.ps1`'s pre-publish gate; WO-101 relay gate unchanged (no packet change); field runbook written | (synthetic) all suites green — see below |
| end gate | **blocked on the version string** — the maintainer names it (standing rule). Everything up to the build is pushed | — |

## Commits (`WO-104:` on `origin main`)

1. `6637e5e` WO-104 Phase 0: time_now formatted with %.0f -- time sync died past 1e6
2. `5ad5b06` WO-104 Phase 1: brainless replicas for contested NPCs (mp_npc_replica_on, default OFF)
3. `f9df723` WO-104 Phase 2: mp_authority_pause defaults OFF -- 0/155 under a live stream
4. `4ae2e6e` WO-104 Phase 3: WO-104 suite in the installer gate, two-machine field runbook
5. docs — this file, `docs/WO-104-findings.md`

## Toggles and defaults after this WO

| toggle | default | changed this WO |
|---|---|---|
| `mp_authority_host_on\|off` | on | no |
| `mp_pos_native_on\|off` | on | no |
| `mp_npc_scan_native_on\|off` | on | no |
| `mp_authority_pause_on\|off` | **off** | **yes** (was on) |
| `mp_npc_replica_on\|off` | **off** | **new** |

## Test counts (this session's own runs, all (synthetic))

| suite | count | note |
|---|---|---|
| `tools/Test-WO104Synthetic.ps1` | 91/91 | new |
| `tools/Test-WO102Synthetic.ps1` | 196/196 | (f) updated for the pause default |
| agent `KcdMp.Client.Tests` | 170/170 | was 157, +13 |
| NpcSmooth / GhostInterp / WO-84 / WO-86 / WO-90 / WO-94 / WO-95 / WO-96 / WO-98 / WO-99 / WO-1005 | 48 / 35 / 72 / 47 / 70 / 101 / 32 / 160 / 50 / 39 / 33 | all 0 failed; WO-99 "exits 2" and WO-1005 "RESULT: 0" quirks pre-existing (WO-1005 re-run against HEAD's kdcmp.lua: identical) |
| relay round-trip (`KcdMp.Relay.Tests`) | not re-run here | no packet-shape change; runs in `Build-Installer.ps1` at the end gate |

## What is NOT verified

* Anything in Phase 1 against a real game: `XGenAI` binding a world NPC's
  `soul:GetId()`, the replica's face/outfit matching, `Hide(1)`'s
  physics, the swap being invisible, native swings on a `NoAI` body,
  zero `body=replica` violations. Runbook §3 is the test.
* Phase 0 live: the maintainer's past-1e6 save is the test case (runbook
  §1). The fix is one line and the mimic reproduces the exact log
  string, but "the sky moves on the other machine" has not been seen.

## End gate (pending)

Not started: needs the version string. When given: tag the previous
release, bump `VERSION` + README badge, release notes (time-sync fix
first, every toggle and default, matched-set warning), fresh-clone build
via `Build-Installer.ps1` (relay gate, agent tests, WO-102 + WO-104
suites), privacy sweep UTF-8 + UTF-16LE with file count, `/PDBALTPATH`
check, pak byte-scan for this session's markers (`%.0f` time_now line,
`MP-NPCREPLICA`, `authorityPause = false`).
