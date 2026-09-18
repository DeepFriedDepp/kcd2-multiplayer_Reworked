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
| 5 — request channel | **built**: `ActionKind.NpcRequest` (accepted input + target name) at the commit edge, owner-side correlation with the `0x30` that follows, specific refusals; `0x76500` on an NPC is a STOP deferred to the maintainer; resolution = the existing damage path | (synthetic) agent 146/146, relay 11/11 incl. the new round-trip case, Lua 81/81 |
| 6 — sleep resync + limits | **built**: owner bursts `0x26` + `NpcStateFlagResync` (0x40) around every player on sleep / fast travel / reload / new peer / `mp_resync_npcs`; non-owner asks via `ActionKind.NpcResync`; one-shot snap + owner death state on receive; limits and the still-divergent categories stated in §6.2–6.3 | (synthetic) agent 150/150, relay 12/12, Lua 99/99 |
| 7 — verification + A/B | **done**: invariant scenario (y), three pre-publish gates in `Build-Installer.ps1`, `docs/WO-102-field-runbook.md` | (synthetic) Lua 109/109, agent 150/150, relay 12/12 |
| end gate | **built: `KCDMP-Setup-0.24.0.exe`** from a fresh clone of `origin main` at `93aaf8c`; version 0.24.0 named by the maintainer; defaults host authority on / native position off / pause lever off (findings §8); `rollback/0.23.2` tagged and pushed | inside the clone: relay 12/12, agent 150/150, Lua 109/109; privacy sweep 1023 files, zero first-party hits; pak Lua content-identical to the repo |

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

9. End gate (defaults) — `HostAuthorityEnabled = true`, `KCD2MP.wo102`
   agrees; native position and the pause lever stay off; the older Lua
   suites pin the claim model; findings §8.
10. `WO-102: VERSION 0.24.0, badge, release notes` (`93aaf8c`) — the commit
    the installer was built from.
11. End gate (built) — this progress doc, findings §8.2.

## Not done, and why

* **No live game ran.** Every phase's verification that needs one is in
  `docs/WO-102-field-runbook.md` (§0 solo, §1 two machines).
* `KCDMP.dll` was rebuilt (383,488 bytes) and **not injected**.
* `0x76500` (native queued attack) on an NPC — a STOP for the maintainer.

## End gate — built

* Version **0.24.0**, named by the maintainer when asked. `VERSION`, README
  badge and `docs/releases/RELEASE-NOTES-0.24.0.md` committed as `93aaf8c`
  and pushed first; the build ran from a fresh `--depth 1` clone of
  `origin main` at that commit, not the working tree.
* Inside the clone, in order: pak rebuild (759,358 bytes), **relay
  round-trip gate 12/12**, **agent unit tests 150/150**, **WO-102 Lua suite
  109/109**, four publishes, native build (`KCDMP.dll` 383,488 bytes, same
  size as the working-tree build; sha256 differs by MSVC timestamp), ISCC
  (41.97 s).
* `KCDMP-Setup-0.24.0.exe`, **100,562,717 bytes**, sha256
  `967CF2B0B1511DA3B107A76DF7345BB7A7DC3C6C0D6D7D5898B7EF0BCDBA18A9`.
  Copied to `release/` (gitignored, as every installer is). **Setup exe
  only** — DirectInstall is retired (WO-94).
* **Privacy re-verified (WO-98 §0), UTF-8 and UTF-16LE**: the whole publish
  output, **1023 files**, grepped for the build machine's username,
  `C:\Users`, the repo folder name, the scratchpad session id, the temp
  path, the clone path and the maintainer's mail domains. **Zero first-party
  hits.** The same six NAudio DLLs as WO-98 / WO-100.5 / WO-101 carry their
  own author's `C:\Users` path (UTF-8) — third-party, not ours.
* **Shipped pak verified to carry this session's Lua.** `Scripts/Startup/kdcmp.lua`
  inside the clone's `kdcmp.pak` is byte-identical to the clone's checkout
  and content-identical to the repo's (`git autocrlf` gives the clone CRLF
  line endings; the working tree has LF; Lua is indifferent). Every WO-102
  marker is present: `KCD2MP_Wo102Set`, `mp_authority_host_on`,
  `KCD2MP_NpcResyncBurst`, `mp_probe_npc_pause`, `MP-AUTHORITY-VIOLATION`,
  and the shipped default `authorityHost  = true`.
* **Matched set:** both machines on 0.24.0, including whoever runs the relay.
* **Not live-verified across two machines.** The next session starts with
  `docs/WO-102-field-runbook.md` §0 (solo: the pause probe and the position
  cadence) and §1 (the A/B).
