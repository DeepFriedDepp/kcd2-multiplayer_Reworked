# WO-102 — progress

Session 2026-09-18. Findings: `docs/WO-102-findings.md`.

## Phases

| phase | state | evidence |
|---|---|---|
| 0 — toggles + revertability | **done** | (synthetic) 15/15 `Test-WO102Synthetic.ps1`; agent + relay build green; existing suites 33/33 (WO-100.5), 50/50 (WO-98) unchanged |
| 1 — position off the log tail | **built, not measured** — native `0x0A/0x86` read + agent path behind `mp_pos_native_on`, cadence + oracle instrumentation; DLL built, **not injected**; comparison is (inconclusive) until the §1.4 runbook runs | (code-verified) Ghidra + RTTI in findings §1.2; (synthetic) agent 139/139, relay 10/10 |
| 2 — baseline the claim model | **done** (committed before Phase 1, which waits on Ghidra) | (observed) figures reproduced + corrected in findings §2.1; (synthetic) 31/31 WO-102 suite, puppet suites unchanged; relay 10/10, agent 101/101 |
| 3 — locomotion suppression lever (native, read-only) | **lever named: `wh_ai_PauseNPC`/`wh_ai_ResumeNPC` (shipped console commands), live behaviour unverified; runbook = `mp_probe_npc_pause`** | (code-verified) strings, console help, scriptbind docs, RTTI in findings §3; (synthetic) probe sequencing 75/75 |
| 4 — permanent host authority | **built behind `mp_authority_host_on` (off): claim bypass, multi-anchor scan, diverge/yield refused + violation log, pause lever behind `mp_authority_pause_on` (off)** | (synthetic) 75/75 WO-102 suite + eleven older suites unchanged; not live-verified |
| 5 — request channel | pending | |
| 6 — sleep resync + limits | pending | |
| 7 — verification + A/B | pending | |
| end gate | pending — needs a version string from the maintainer | |

## Commits (all `WO-102:` on `origin main`)

1. Phase 0 — toggle set (`KCD2MP.wo102`, `KCD2MP_Wo102Set/Status`, five
   argless commands), agent mirror (`wo102_toggle`), `ClientConfig`
   `HostAuthorityEnabled` / `NativePositionEnabled` + CLI flags, connect-time
   default push, `MP-SUMMARY section=wo102`, `tools/Test-WO102Synthetic.*`,
   docs skeleton.

## Baseline before any change (observed this session)

* `dotnet build KcdMp.sln -c Release`: green. `KcdMp.Client.Tests` 101/101,
  `KcdMp.Relay.Tests` 10/10.
* Lua synthetic suites: WO-100.5 33/33, WO-98 50/50.
