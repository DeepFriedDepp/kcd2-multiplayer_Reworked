# KCD2-MP 0.22.5

The label for everything on `main` as of WO-98 (2026-09-16), packaged as
`KCDMP-Setup-0.22.5.exe`. Setup exe only — there is no DirectInstall ZIP for
this release (retired in 0.22.0).

**No native change.** `KCDMP.dll` is source-identical to 0.22.4. The pak,
agent, relay, launcher and master server are republished as a matched set;
deploy all of it together (the WO-46 / WO-86 mismatch trap).

**Verification status, stated plainly.** Everything in this release is
**synthetic-verified, not live-verified**: 89/89 agent unit tests, the new
`Test-WO98Synthetic` suite 50/50, and every prior MoonSharp suite green. The
clock-offset exchange was proven against the built relay over loopback only.
Nothing here has run across two machines. This release exists to make the
*next* two-player session diagnosable from its logs — see
`docs/WO-98-findings.md` for what the last one could and could not show.

---

## Fixed: the launcher leaked the build machine's user profile path (WO-98 Phase 0)

0.22.4's launcher, built from a clone under the maintainer's temp folder,
carried that path in every managed DLL and PDB. An unhandled exception on a
tester's machine printed it in the crash trace. Source paths are now rewritten
to `/_/` at compile time and SourceLink is disabled (it wrote a second copy of
the path that the rewrite did not touch). A forced exception now prints
`/_/KCDMP_launcher/Program.cs:line N`; the full release output was scanned and
carries no first-party profile path. Six third-party NAudio DLLs carry their own
author's path; that is theirs.

## Fixed: launcher crash "WindowIconFile: app.ico cannot be found"

Not a missing file. The window-icon call took a bare relative name and the UI
library re-checked it against the *working directory* at startup, so the
launcher hard-crashed whenever it was started from anywhere but its own folder.
The path is now absolute, and a missing icon is a warning, not a crash.

## New: clock-offset measurement (WO-98 Phase 1) — measured, not applied

The two machines' wall clocks were 4.75 s apart in the 2026-09-15 session
(0.80 s two days earlier — an unsynchronised clock, still drifting). Nothing in
the mod compares timestamps across machines, so nothing broke; but nothing
could see it either. The agent now samples the offset to the relay once per
ping (the relay runs on the host, so on a joiner this is the host-vs-joiner
skew), keeps a running median, logs it (`MP-CLOCK`), shows it beside the ping,
and stamps it on every `agent.log` line. **Nothing is corrected by it yet.**
Two new wire opcodes (0x39/0x3A), additive; no protocol version bump — an old
relay skips them.

## New: cutscene state on both sides (WO-98 Phase 5)

The engine's own cutscene start/end lines are now picked up for both the
`Rendered` and `Ingame` types (0.22.4 tracked only `Rendered`; every quest
cutscene is `Ingame`, so it saw none), logged with the peer's state, and sent
to peers. **The readiness prompt (F11/F12) is held while a cutscene plays** and
offered when it ends — in 0.22.4 it could be shown at a moment input could not
reach it. `mp_quest_yes` is refused mid-cutscene. Every F11/F12 press the mod
receives is logged with the state it landed in.

## New: structured log channels and session summaries (WO-98 Phase 6)

`MP-CLOCK`, `MP-CUTSCENE`, `MP-KEY`, `MP-TOAST` (every toast's final text —
never logged before), `MP-SCREEN` (persistent on-screen rows, on change only),
`MP-NPCFIGHT` / `MP-NPCDIVERGE` (puppet-vs-local-AI aggregates), `MP-SWING`
(swing path hops), `MP-DMG` (shared-combat damage with result and authority),
`MP-GHOSTPKT` (ghost packet timing aggregate; `KCDMP_LOG_LEVEL=verbose` adds
per-packet raw lines), and `MP-SUMMARY` / `MP-SUMMARY-MOD` blocks on
disconnect (also `mp_summary` at the console). Every mod line in `kcd.log`
ends with the mod clock (`t=`); every `agent.log` line carries a monotonic
stamp and the clock offset. Field reference: `docs/WO-98-log-format.md`.
Steady-state log volume is estimated neutral, not measured live.

## Changed: quieter divergence notifications (WO-98 Phase 7)

* A standing story divergence was re-pushed to the mod every 2.5 s for as long
  as it lasted (~50 identical log lines per side last session). It is now
  re-pushed when the game's Lua restarts, plus a 60 s heartbeat; repeats
  collapse into one counter line per minute. On-screen behaviour is unchanged
  (those repeats never drew anything).
* The "NPC is at a different point in your friend's story" toast led with the
  NPC's internal entity name (`KCD2-MP: ttkc_inkeeper …`), which is the likely
  source of the reported wrong peer name on screen. It now names the peer,
  puts the NPC last, stays quiet while the quest layer's own row or prompt is
  already explaining the divergence, and fires at most once per five minutes.

## Diagnosed, not changed

From the 2026-09-15 logs (`docs/WO-98-findings.md`):

* Every NPC claim going to the joiner is **by design** — the relay's damage
  authority (the host) streams by default and never claims.
* The post-brawl error storm is one guard NPC failing a pick-up action 16–18
  times a second in both worlds, present on the host while the mod was not
  driving him; classed as a stock failure the brawl triggers. The mod's own
  claim traffic was the largest single addition to the line rate.
* Neither machine's frame loop saturated during the brawl (the mod's tick
  spacing held at 26–29 ms throughout).
* The joiner's inability to fight back is **inconclusive**; saturation and a
  stuck cutscene input lock are both disfavoured by the logs.

## Not in this release

* No native change. The one-line native isolation context that would take the
  ghost out of the engine's social-situation scheduler is named and deferred.
* No cutscene synchronisation; the state is logged and shared, nothing is
  gated on it.
* No consumer of the clock offset.
