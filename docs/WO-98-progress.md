# WO-98 — progress

Field-session diagnosis of 2026-09-15 (0.22.4, protocol v6). Findings in
`WO-98-findings.md`; log channel reference in `WO-98-log-format.md`. No
native calls, no live-game tests, no quest writes this session. `VERSION`
unchanged (0.22.4).

| Phase | Status |
|---|---|
| 0 privacy leak + app.ico crash | **done** — `Directory.Build.props` (PathMap, SourceLink off), icon resolved absolutely; forced-exception trace verified, full publish output scanned clean |
| 1 clock skew | **done** — derivation reproduced five ways (4.75–4.79 s, joiner ahead); every timestamp use enumerated (none cross-machine); ClockSync 0x39/0x3A landed, logged, not applied; loopback wire test only |
| 2 claim asymmetry | **done** — design intent, code-verified (authority packets never claim); SWING asymmetry direction corrected |
| 3 tug-of-war | **done (diagnosis)** — confirmed against source; arbitration options stated; nothing landed |
| 4 AI storm | **done** — Target A re-attributed (guard PickUpRight loop, stock-with-mod-amplification), Target B confirmed-but-tiny with the lever named (native), Target C re-attributed to the NPC-DIVERGE toast and fixed; saturation ruled out by tick-spacing measurement |
| 5 cutscene | **done** — Rendered+Ingame edges logged both sides, peer state via StoryBeat kind 6, prompt held/re-offered around cutscenes, keys logged; lockout (inconclusive) with two candidates ruled out; co-op gating assessed |
| 6 instrumentation | **done** — 12 structured channels, monotonic + offset stamps, summaries; `WO-98-log-format.md` |
| 7 cadence | **done** — re-push on MOD INIT + 60 s heartbeat; repeats collapse to a counter line; NPC-DIVERGE toast reworded/gated/throttled |
| 8 confirmed-working | **recorded** |

## Verification

* `KcdMp.Client.Tests`: 89/89.
* Lua under MoonSharp: `Test-WO98Synthetic` (new) 50/50; `WO-96` 160/160,
  `WO-95` 32/32, `WO-94` 101/101, `WO-90` 70/70, `WO-86` 47/47, `WO-84`
  72/72, `NpcSmooth` 48/48, `GhostInterp` 35/35.
* Relay wire test (loopback, Python client against the built relay):
  ClockSync offset 0.03 ms / RTT 0.19 ms over 8 samples; unknown opcode
  skipped; Ping/Pong intact.
* Launcher: forced exception prints `/_/KCDMP_launcher/Program.cs:line N`;
  full `Publish-Release.ps1` output (435 files) has zero first-party
  profile-path strings.
* **Not live-verified:** everything above the harness — the Ingame cutscene
  edges on a real build, the cutscene-held prompt in the field, the
  structured lines' real volume, the clock offset across two machines.

## Commits

`WO-98: Phase 0`, `Phase 1`, `Phases 5-7`, `rebuild kdcmp.pak`, `docs`.
Deploy is a matched set: pak + agent + relay (Protocol changed additively;
an old relay skips 0x39, an old agent ignores 0x3A and kind 6). The native
DLL is untouched.

## Deviations

Recorded in `WO-98-findings.md` (Deviations + WO-99 candidates). Summary:
two fixes deliberately not landed (native situation context; sub-8 m puppet
yield), one synthetic wire test taken, six premises of the prompt corrected
in place with the evidence.

## Next session starts here

1. Two-machine run with this build; pull both bundles. The `MP-SUMMARY` /
   `MP-SUMMARY-MOD` blocks and `MP-CLOCK` are the first things to read; the
   `off=` field on agent lines makes the two logs directly comparable.
2. If the joiner lockout recurs: `MP-KEY`, `MP-SWING hop=sent` vs the host's
   `hop=recv/queued`, `MP-DMG dir=out` on the joiner, and the engine's
   `requested end of combat due unlocking` count will say whether input,
   sending, or the combat lock is where swings die.
3. WO-99 candidate 1 (native `DisableSituationParticipation`) is one line
   plus a rebuild; candidate 2 (`Movie.PauseSequences` at a cutscene edge)
   is one live probe.
