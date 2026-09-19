# KCD2-MP 0.26.1 — read known-answer check, staleness-gated

The label for everything on `main` as of WO-103's live field session
(2026-09-18), packaged as `KCDMP-Setup-0.26.1.exe`. Setup exe only — there
is no DirectInstall ZIP (retired in 0.22.0). **To go back:** the tag
`rollback/0.26.0` and `KCDMP-Setup-0.26.0.exe`, or `rollback/0.25.1` two
steps back.

---

## Why 0.26.1 and not a re-tag of 0.26.0

`KCDMP-Setup-0.26.0.exe` was built and handed off, then the maintainer ran
it live for the first time this WO's own code has ever run against a real
game. That session found:

* **A real bug, fixed in source**: `KCD2MP_NpcReadCompare`'s tolerance
  formula (`base + speed × age`) had no cap on age. A native-position push
  that went stale minutes earlier still reported `verdict=match` against
  wherever the live NPC had actually drifted to since, because the allowed
  drift grows without bound right alongside the staleness — caught live
  when a deliberately-stale test entry (~500 s old) matched against 50-130m
  of real drift, every single compare cycle. Fixed: a push older than the
  same freshness window the read substitution itself trusts is now excluded
  from the check outright (`verdict=no-data reason=stale`), not compared
  with an ever-widening allowance.
* **A live-verified, real Phase 0 baseline, for the first time**:
  `MP-NPCREAD path=lua mean_ms=1.5 p50_ms=1 p95_ms=2` at 78-80 tracked NPCs,
  growing to `mean_ms=7.0 p95_ms=15` at ~450 tracked — confirming the design
  claim that read-loop cost scales with tracked count, not streamed count.
* **A live Phase 3 radius ladder, 300→5000m, zero crashes**: tracked count
  grew 79→161→324→447 then plateaued around 457 — the ceiling turned out to
  be the *engine's* own NPC-streaming distance, not anything this mod's
  radius parameter controls. One real signal: mod-tick `max` rose from
  ~40ms to ~62-63ms past ~300 tracked (average unaffected) — a mild,
  occasional hitch, not a crash.
* **The native NPC scan itself never reached Lua in that session** — but
  the cause was environmental, not this WO's code: the running agent
  (`KcdMpClient.exe`) hashed to a build from weeks earlier, not the 0.26.0
  agent the Setup had just installed (very likely files locked by
  still-running processes during install — the exact WO-32/WO-74 failure
  class this project has hit before). The mod pak WAS confirmed fresh
  (`KCD2MP_ApplyNativeScan` manually invoked and verified working
  correctly, live). **This release does not fix that** — it is a
  deployment issue, not a code one — but it is why the maintainer closed
  everything and asked for a clean rebuild before testing native scan
  again. Confirm the agent hash after installing this build if native scan
  matters to your session.

Both landed on `main` the same day, `KCDMP-Setup-0.26.0.exe` predates the
fix, so 0.26.1 is that same build re-cut from current `main`.

---

## ⚠ Matched set, both machines

Unchanged from 0.26.0's own notes — agent, pak, `KCDMP.dll` all from the
same build, on both machines. No wire/protocol change this release (a pure
Lua fix). Verify after installing: `KcdMpClient.exe`'s file hash should
match what this build actually produced (this project has hit the
"install ran while old processes were alive, left a stale binary in place"
failure mode before — WO-32, WO-74 — and it happened again this same day,
which is the whole reason this release exists).

---

## Verification status, stated plainly

| item | status |
|---|---|
| known-answer staleness fix | (synthetic) 2 new checks, 196/196 total; **(observed)** the exact live failure that motivated it, reproduced and then fixed |
| Phase 0 baseline | **(observed)**, live, for the first time — see numbers above |
| Phase 3 radius ceiling | **(observed)**, live, 300-5000m, zero crashes; the ceiling is the engine's NPC-streaming distance, not this mod |
| native position substitution itself | **(observed)** working correctly when manually driven (fresh vs stale fallback both proven live); **never observed end-to-end through the agent's own automatic push** — blocked by the stale-agent deployment issue, not a code defect |
| everything from 0.26.0 | unchanged | untouched by this release except the one Lua fix above |

`docs/WO-103-findings.md` §5 and `docs/WO-103-progress.md` have the full
live-session write-up.
