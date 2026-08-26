# WO-58 — Progress

## Session 2026-08-26

- Built the redacted evidence copy at `docs/WO-58-test-logs/` from the four
  raw tester exports (host x2, joiner x2). Scrubbed: 2 Windows usernames,
  2 machine hostnames, 1 DDNS hostname, 2 Steam ids, 2 Steam nicks,
  2 Discord handles, 3 LAN IPs. Verified zero residual hits before commit;
  placeholders are consistent so cross-referencing survives.
- Re-verified WO-54's cross-machine correlation properly: joiner timeout
  bursts track the joiner's OWN game freezes, not host restarts 1:1; the
  16:49:26 relay death is corroborated to the second on both machines.
  Established the joiner's game hard-froze/restarted at least twice
  (kcd.log launch headers 01:40:58, 01:59:17 joiner-clock).
- Found both joiner kcd.log exports end at `Spawning ghost 'N'` and the
  host's frozen-session kcd.log ends at `MountNPCOnHorse id=3` — pulled the
  surviving `logbackups\kcd.log` and `kcdmp-native.mirror.log` from the
  host's own disk (never exported by the bundle) and pinned the host freeze
  to a main-thread hang inside `human:ForceMount()` on the first-ever live
  world-horse adoption. Latency ruled out as root cause (pings healthy,
  wire quiet at every freeze onset).
- Quantified the chip-hit wire flood: 1,972 sub-0.05 hp messages in <4 min
  from the joiner's own siege battle, each costing the host a synchronous
  main-thread apply.
- Found version-ipc broken in the field on BOTH clean installs
  (System.IO.Pipelines 10 resolution failure, 500 every 3 s all session) —
  the version-mismatch notice has never worked.
- Phase 2: pinned the wrong-gender mechanism — nameless respawn after a
  mid-connection game restart face-picks from `"Player<id>"`;
  `hash("Player1")` is even, so the host's ghost spawned female on the
  joiner's screen at 17:00:13. The Aug-22 side of the four-day gap has no
  game/agent telemetry (launcher logs only), so the old-version face pick is
  unrecoverable; the save-embedded stale-ghost hole was confirmed by code
  review and closed regardless.
- Shipped 8 bounded fixes (see findings table): adopt-distance guard,
  chip-hit threshold, never-equip blacklist, name re-assert + late-name
  respawn, stray-ghost sweep, log-bundle native-log collection, hand-rolled
  version-ipc JSON.
- Solution builds clean; 59/59 tests pass. Scoped-not-attempted: receive-loop
  decoupling, publish layout separation, DLL pipe drop-on-full.
- Full analysis: `docs/WO-58-findings.md`.
