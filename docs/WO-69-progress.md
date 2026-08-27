# WO-69 progress

Read `docs/WO-69-findings.md` first — it carries the diagnosis and the evidence
tags. This file is the state-of-play and the runbook.

## Status

| Item | State |
|---|---|
| Report 1 root cause | **Closed.** H1, deterministic. Observed + code-verified. |
| Report 1 fix | **Shipped in tree**, pak rebuilt. **Not yet observed live.** |
| Report 2 diagnosis | **Closed.** D1 confirmed arithmetically; D2 untested; D3 newly found. |
| Report 2 fix | **Deliberately not landed** — handed to WO-70 with reasons. |
| Witness A/B (WO-68 ledger) | **Not run** — needs a live game. |
| Relay suites | **Green, 119/0**, fresh source-built relay. |
| `Test-Pipe` | Not run — no injected DLL / no live game this session. |

Baseline: current `main` is **0.18.6**, not 0.18.4. Neither 0.18.5 nor 0.18.6
touches ghost spawning or puppet presentation. No `VERSION` change made — that
is the user's call (`docs/VERSIONING.md`).

## What changed

`kdcmp/Data/Scripts/Startup/kdcmp.lua` only. No engine, protocol, relay or
session-framework change; no C# change. No STOP condition was triggered.

1. `KCD2MP_PickFaceForPlayer` — gender no longer derives from hash parity;
   always `className = "NPC"`, always the male list.
2. The 24-entry `female` roster table deleted.
3. `KCD2MP.faceFallback` added — `ttkc_man_3`, guid live-verified this session.
4. `KCD2MP_SpawnGhost` — verify-after-spawn: a permanent
   `spawn verify … requested … | resolved …` line, plus a loud `SPAWN MISMATCH`
   and exactly one fallback respawn on a **definite** non-nil class
   disagreement.
5. Roster header comment corrected (it claimed "19 male, 24 female").

Deliberately untouched, and must stay untouched:
- The djb2 hash and the `math.floor(h / 2)` term — changing either re-rolls all
  19 male faces.
- The male table's contents and order — same reason.
- The two `cls == "NPC_Female"` filters in the NPC-sync rescan and the drag
  sensor. **These match real female world NPCs, not ghosts.** Removing them
  would silently drop roughly half the world's NPCs from sync and from body
  drag.
- `tools/Verify-Install.ps1`'s roster assertion — it matches the `male = {…}`
  sub-table and expects 19; deleting only the female sub-table leaves it
  passing, which was re-checked against the rebuilt pak.

## Runbook — start here next session

### 1. Live acceptance for Report 1 (the one thing missing)

Needs the game running via the **Modding Tools** Steam entry, and the rebuilt
pak installed (`tools\Build-And-Install-Mod.ps1`, then restart the game — a
`kdcmp.lua` edit is inert until the pak is rebuilt *and* the game restarts).

Acceptance is: **N repeated spawns across fresh / respawn / post-save-load
rebuild paths, zero non-male outcomes, every spawn logging requested-vs-resolved.**

Watch for, in `kcd.log`:
```
[KCD2-MP] spawn verify ghost '<id>': requested class=NPC soul=<x> guid=<g> | resolved class=NPC soul=<y>
```
Fail signals: any `class=NPC_Female`, any `SPAWN MISMATCH`, any
`fallback respawn failed`.

Cover all three spawn paths — they are genuinely different code:
fresh connect · ghost removed and respawned by the next position packet ·
**save-load rebuild** (the reconcile path; the field bundle shows three of its
four spawns came from exactly this).

Useful: a name whose hash is even is now harmless, but pick one anyway to prove
the old failure case is dead. Any 7-letter nick will do; the parity no longer
matters, which is the point.

### 2. Witness A/B — owed to WO-68's "not established" ledger

Not run this session (game exited). Procedure, unchanged from the work order:
test ghost up, isolation ON, **no real NPCs in line of sight**, commit a visible
theft with only the ghost watching, record bounty or none; then isolation OFF,
respawn, repeat.

Interpretation discipline that must survive into the write-up: **if the
un-isolated ghost also does not report, the tavern incident had a different
cause** — an unclocked real NPC witness, or the ghost pulling guard attention —
and that is the finding. Do not force the story onto `crime_disableReport`.
Append the result to WO-68's ledger either way.

### 3. Report 2 — do not fix it here

The interp port is WO-70's, for a documented reason
(`docs/WO-63-findings.md:182-193`): WO-60 proximity authority must be
live-verified **before** the puppet renderer is smoothed, or the smoothing
destroys the footage needed to judge WO-60. WO-63 also predicted this exact
field report in advance.

WO-70's ordered work list is in `docs/WO-69-findings.md` § *For WO-70* — seven
items, the first three of which (chain-identity tokens, per-packet
instrumentation, `p.fightN` rethreshold) are prerequisites, not polish. The D1
arithmetic and the matching field-log signature are the justification; the
D1-vs-D2 discriminator (`Test-NpcSyncE2E.ps1` Phase 3 + `AI.SetIgnorant`) has
still never been run and should decide the lever before anything is tuned.

## Traps hit or re-confirmed this session

- **The game exits.** It was live at session start (REST on :1403 answered, 19/19
  roster souls verified) and gone twenty minutes later. Bank live reads
  immediately; do not defer them.
- **The installed relay was the running one.** `%LocalAppData%\KCDMP\KcdMpServer.exe`
  was serving 7778. It was replaced with a source build before the suites ran —
  otherwise the suites grade a stale binary and pass meaninglessly (WO-32).
- **`awk`/`sed` rewrites destroy CRLF.** `kdcmp.lua` is CRLF; a stream-edit
  silently converted the whole file and produced a 7,693-line diff. Use the
  editor tooling, and check `git diff --stat` looks surgical.
- **No Lua syntax checker exists locally** (no `lua`, no `luac`), and the build
  script gates only on BOM. The only true Lua 5.1 syntax check available is the
  game's own interpreter — `loadfile` against the file path while the game runs.
  **This edit has not had that check**; it has had a clean pak build and a
  careful diff review only.
- No Python locally — log analysis is `grep`/`awk`/`sed` or PowerShell.

## Honest gaps

- The Report 1 fix is **code-verified and pak-verified, not observed**. It
  removes the mechanism that provably caused the field report, but no ghost has
  been watched spawning under it.
- The `SPAWN MISMATCH` fallback branch has **never executed** — there is no
  known way to force a roster soul to fail resolving on demand, so that branch
  is unexercised code.
- D3 (the chain leak) is **suspected, not established**; the log cannot separate
  it from legitimate restarts after five save loads.
