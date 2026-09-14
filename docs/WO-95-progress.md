# WO-95 — progress

Investigation of the 2026-09-13 live two-player session on 0.22.0.
Findings: `docs/WO-95-findings.md`.

## What this session did

| Phase | Outcome |
|---|---|
| 0 — master timeline | Built. Build confirmed 0.22.0 on both machines from the relay handshake, both agents and the WO-94 registry line. All eleven reports located on both machines' logs. |
| 1 — the five groupings | All five given a verdict. **Three hold** (B as one event, C, D, E). **Two do not** (A splits into three unrelated mechanisms; B's *suspected cause* is refuted even though the items group). |
| 2 — open sweep | Run as a first-class pass. **Nine findings nobody reported**, one of them larger than anything on the list (30,495 engine movement-validation errors on the host). |
| 3 — fix | **One** fix, clean and low-risk: the NPC packet-cadence instrument. Eight further findings named as follow-ups rather than patched blind. |
| 4 — priority | Stated: raise the readiness prompt from the story-divergence signal **before** extending prologue coverage. Evidence in findings §5. |

No `VERSION` change. Nothing deployed; the pak was not rebuilt.

## Verification

| Suite | Result |
|---|---|
| `tools/Test-WO95Synthetic.ps1` (new) | **32 passed, 0 failed** |
| `tools/Test-WO94Synthetic.ps1` | 101 passed, 0 failed |
| `tools/Test-WO86Synthetic.ps1` | 47 passed, 0 failed |
| `tools/Test-WO84Synthetic.ps1` | 72 passed, 0 failed |
| `tools/Test-NpcSmoothSynthetic.ps1` | 48 passed, 0 failed |
| `tools/Test-GhostInterpSynthetic.ps1` | 35 passed, 0 failed |

335 checks green. All synthetic — no live game was available to this session,
and none was needed for phases 0–2 or for the one fix.

## Files touched

| File | Change |
|---|---|
| `kdcmp/Data/Scripts/Startup/kdcmp.lua` | `KCD2MP_ApplyNpcState` classifies each inbound packet motion vs idle heartbeat; only motion-to-motion gaps enter the cadence mean; heartbeats counted separately; the dump line reports both and names the heartbeat interval. `KCD2MP.npcPacketStats` gains `idleN`. |
| `tools/Test-WO95Synthetic.lua` (new) | Seven scenarios (a)–(g) against the real `kdcmp.lua` under MoonSharp. |
| `tools/Test-WO95Synthetic.ps1` (new) | Thin driver, same pattern as the WO-94 wrapper. |
| `docs/WO-95-findings.md` (new) | The investigation. |
| `docs/WO-95-progress.md` (new) | This file. |
| `README.md` | Shared Quests row updated: it has now run live. |

## Reading order for the next session

1. **Findings §5** — the priority recommendation and why prologue coverage is
   the second step, not the first.
2. **Findings §1.2** — the 0.80 s clock skew between the two machines. Any
   future cross-machine timing work is wrong without it.
3. **Findings §3.3** — the movement-validation storm. The largest unexplained
   thing in the session and the best-defined next investigation.
4. **Findings §4 "Named, not attempted"** — the eight follow-ups, with the
   reason each was left alone.

## Traps confirmed or added this session

* **New: the two test machines' wall clocks differ by ~0.80 s.** Derived three
  ways from relay-receipt-before-sender-log. Larger than the cutscene offset
  being investigated. Nothing in the tooling measures or reports it.
* **New: `[KCD2-MP-DATA] v2 <seq> <t>` is the only clock in `kcd.log`.** It is
  `os.clock()` since mod init and does not drift (22 ms over 52 minutes), so
  one anchor per machine maps the whole log onto wall time. This is the method
  every future forensic WO should use.
* **New: the relay's reject tag is `WO66-REJECT`, not `WON-REJECT`.** A
  digit-stripping pass over the log turns `66` into `N` and the wrong string
  greps to zero matches.
* **Confirmed: a `pcall` returning true proves nothing** (WO-43). The
  catch-up fire logs before and after precisely for this reason, and that is
  what made item 8 answerable.
* **Confirmed: console-registered commands reject typed arguments** (WO-94).
  Not touched this session; no console behaviour changed.
