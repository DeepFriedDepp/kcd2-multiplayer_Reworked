# KCD2-MP 0.26.1 — read known-answer check, staleness-gated

The label for everything on `main` as of WO-103's live field session
(2026-09-18), packaged as `KCDMP-Setup-0.26.1.exe`. Setup exe only — there
is no DirectInstall ZIP (retired in 0.22.0). **To go back:** the tag
`rollback/0.26.0` and `KCDMP-Setup-0.26.0.exe`, or `rollback/0.25.1` two
steps back.

---

## ⚠ Corrected the same day, after this build was packaged

This exe was already built and handed off when the root-cause paragraph
below (native scan / stale agent) turned out to be wrong. **No code
changed** — this build is still correct and current — only the diagnosis
was wrong, and it is corrected here so this document doesn't keep pointing
at a deployment problem that never existed:

* **There was no stale-agent deployment failure.** The maintainer's own
  `certutil -hashfile` check (run from their own terminal) and Setup's own
  install log (`Installation process succeeded` / `verify: PASS`, two
  minutes before the game session in question ever connected) both confirm
  the agent was the correct, freshly-installed 0.26.0 build the entire
  time. The "stale agent, dated 8/15" conclusion below came from hashing
  the same file from the coding assistant's own shell — a path this
  project's own standing notes already document as sandbox-redirected and
  unreliable in either direction (see `docs/WO-103-findings.md` §5.2's
  correction).
* **This means the native scan bug is real and still open** — it happened
  against correct, matched code, not mismatched code. The leading theory
  is now a length limit in the debug console's own HTTP request handling,
  tripped by this WO's own richer per-entry push format. Not yet confirmed
  or fixed.

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
Lua fix). If you want to verify the hash yourself, run `certutil -hashfile`
from your OWN terminal — not through the coding assistant, whose shell
reads a stale, sandboxed shadow copy of this exact install directory (this
is what produced the incorrect "stale agent" diagnosis corrected above).

---

## Verification status, stated plainly

| item | status |
|---|---|
| known-answer staleness fix | (synthetic) 2 new checks, 196/196 total; **(observed)** the exact live failure that motivated it, reproduced and then fixed |
| Phase 0 baseline | **(observed)**, live, for the first time — see numbers above |
| Phase 3 radius ceiling | **(observed)**, live, 300-5000m, zero crashes; the ceiling is the engine's NPC-streaming distance, not this mod |
| native position substitution itself | **(observed)** working correctly when manually driven (fresh vs stale fallback both proven live); **never observed end-to-end through the agent's own automatic push, even against a confirmed-fresh, correctly-matched agent** — a real, still-open bug (see the correction banner above), leading theory a debug-console request-length limit |
| everything from 0.26.0 | unchanged | untouched by this release except the one Lua fix above |

`docs/WO-103-findings.md` §5 and `docs/WO-103-progress.md` have the full
live-session write-up.
