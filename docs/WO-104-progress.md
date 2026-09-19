# WO-104 — progress

Session 2026-09-18. Findings: `docs/WO-104-findings.md`. Field runbook:
`docs/WO-104-field-runbook.md`. Input: the first two-player session since
0.23.2 (0.26.1, same day, both machines).

## Phases

| phase | state | evidence |
|---|---|---|
| 0 — time sync formatting | **shipped, alone, first** (`6637e5e`, pushed): `time_now` formatted `%.0f`, never `tostring()`; dice wager hardened the same way; parser left strict. Audit of every other numeric field on the Lua→agent channel: two exposed, both fixed; rest named in findings §1.3 | (observed) the failure in agent.log; (code-verified) fix + audit; (synthetic) WO-104 suite (a) 7/7 with a `%g` tostring mimic that reproduces `1.00255e+06`; agent `WorldTimeFormatTests` +13 → 170/170 |
| 1 — replicas for contested NPCs | **built behind `mp_npc_replica_on\|off\|status`** (`5ad5b06`), built default off, **flipped ON for 0.26.2 by the maintainer at the end gate**. Body is `NPC`+`NoAI=true` soul-bound to the original's `soul:GetId()` — not `NPC_NAI`, which is unreachable with a soul on this build (findings §3.1). Promote on the first violation, one-call spawn-then-hide; demote on sheathed 10 s / death / release / toggle / host-off / stop / sweep. `npcid` + new `npc_replica` event re-point native swings and outbound damage. No wire change | (code-verified); (synthetic) WO-104 suite (b)–(i), 91/91 total; **nothing live** |
| 2 — pause lever default | **shipped OFF** (`f9df723`). 155/155 violations `paused=1` recorded next to WO-102.5 §1.1, §6.1 and WO-102 §4.3. Code + toggle kept | (observed) joiner kcd.log; (synthetic) WO-104 (j), WO-102 (f) updated |
| 3 — verification | **done** (`4ae2e6e`): WO-104 suite added to `Build-Installer.ps1`'s pre-publish gate; WO-101 relay gate unchanged (no packet change); field runbook written | (synthetic) all suites green — see below |
| end gate (0.26.2) | **built: `KCDMP-Setup-0.26.2.exe`** from a fresh clone of `origin main` at `ec49601`; version named by the maintainer; `rollback/0.26.1` tagged at `255f9a0` before the bump. Built TWICE: the first exe (at `dad1988`, replica default off) was superseded the same hour when the maintainer flipped the replica default on; only the second is kept | see "End gate details (0.26.2)" below |

## Commits (`WO-104:` on `origin main`)

1. `6637e5e` WO-104 Phase 0: time_now formatted with %.0f -- time sync died past 1e6
2. `5ad5b06` WO-104 Phase 1: brainless replicas for contested NPCs (mp_npc_replica_on, default OFF)
3. `f9df723` WO-104 Phase 2: mp_authority_pause defaults OFF -- 0/155 under a live stream
4. `4ae2e6e` WO-104 Phase 3: WO-104 suite in the installer gate, two-machine field runbook
5. `4da8216` docs — this file, `docs/WO-104-findings.md`
6. `dad1988` WO-104: VERSION 0.26.2, README badge, release notes
7. `ec49601` WO-104: mp_npc_replica ships ON for 0.26.2 (maintainer's call)
8. end-gate details — this file

## Toggles and defaults after this WO

| toggle | default | changed this WO |
|---|---|---|
| `mp_authority_host_on\|off` | on | no |
| `mp_pos_native_on\|off` | on | no |
| `mp_npc_scan_native_on\|off` | on | no |
| `mp_authority_pause_on\|off` | **off** | **yes** (was on) |
| `mp_npc_replica_on\|off` | **on** | **new** (built off; ON by the maintainer's call at the end gate) |

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

## End gate details (0.26.2)

* **Version** `0.26.2`, named by the maintainer. `rollback/0.26.1` tagged
  at `255f9a0` (the last pre-WO-104 commit) and pushed before the bump.
* **Fresh-clone build.** `git clone` of `origin main` into a new scratch
  directory (never the working tree), `tools\Build-Installer.ps1`
  end-to-end (it rebuilds the pak from the clone's Lua and builds the
  native plugin itself when `native\build` is absent). Gates inside the
  build: relay round-trip 13/13, agent 170/170, WO-102 196/196, WO-104
  92/92. Built twice: first at `dad1988` (replica off), then the maintainer
  flipped the replica default on; the clone was fast-forwarded to
  `ec49601`, `release\` wiped, rebuilt. The first exe was deleted; only the
  second exists.
* **Privacy sweep, re-run on the second build**: 1,024 files under the
  clone's `release\` (same count as 0.25.1/0.26.0/0.26.1), three
  real-identity needles (build account name, DDNS provider domain, mailbox
  name — not printed, by design) as UTF-8 and UTF-16LE. **Two hits, both
  the already-known generic `myserver.duckdns.org` example string in
  `KCDMP_launcher.dll`** (UTF-16LE; the WO-55 validation message and the
  launcher's placeholder text), read in context. **Zero real hits.**
  `KCDMP.dll` (396,800 bytes, unchanged from 0.26.1 — no native change this
  WO) and `KCDMP_LauncherInjector.exe` (158,720 bytes) carry zero `Users\`
  path fragments — `/PDBALTPATH` still applying.
* **Pak carries this session's Lua** — read `Scripts/Startup/kdcmp.lua`
  out of the clone's `kdcmp/Data/kdcmp.pak` directly: the `%.0f` `time_now`
  line (1), `MP-NPCREPLICA` (5), `authorityPause = false,` (1),
  `mp_npc_replica_on` (6), `WO-104` (22), the replica default-ON line (1)
  and the default-OFF line (0). The tracked pak in git is NOT updated
  (last committed at 0.23.1; every release since ships the installer's
  own rebuild — unchanged convention).
* **Artifact**: `KCDMP-Setup-0.26.2.exe`, sha256
  `94899572aa8e743eec6c3404e06df1f63d010dc707fd462353ca550086f792cf`,
  100,576,182 bytes. Copied into the working tree's `release\` and
  re-hashed there — identical. Payload: `KcdMpClient.dll`
  `e0397f5405f0095fabe48813660ec3b02cdd436b22f23dc1f849f00879627fd6`
  (858,112 bytes; the code — `KcdMpClient.exe` is only the apphost and
  hashes the same across both builds), `KCDMP.dll`
  `c427e1d31d867ec295eb1e03ae6f20d1aa2636ca43b043d94b4547081047ac32`.
* **Not done**: the installer was not run from here (AppData sandbox
  redirection — the maintainer runs Setup and verifies from their own
  terminal). Nothing in Phase 1 has run against a game; the pause-lever
  flip and the time-sync fix are (synthetic) until the next two-machine
  session (`docs/WO-104-field-runbook.md`).
