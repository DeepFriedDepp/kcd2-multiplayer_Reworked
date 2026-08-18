# WO-39 progress

Session of 2026-08-18. Game available throughout; live battery run on the
real 0.13.6 stack with the human at the machine. Full detail per phase in
`docs/WO-39-findings.md`.

| Phase | Item | Status |
|---|---|---|
| 1 | Combat visibility (0x2C/0x2D) | **Shipped + live-verified.** Outbound verified with a real fighter (draw/swing/block arrive as correct wire events); inbound draw/guard confirmed visually; swing/block ship as partial cues — true swings are Mannequin-locked on this build (documented ceiling). Two stomping mechanisms found and fixed live (anim-loop restart, per-tick SetWorldPos). |
| 2 | Per-entity authority (item C) | **Shipped.** Packet-free claim-by-sending, TimeSkip arbitration shape, relay-enforced; T10–T14 wire-verified; claim path live-spot-checked driving a real NPC from a non-authority peer. Drag sensor live-gated on real carry mechanics (two-human). |
| 3 | Knockout/death replication (item F) | **Answered.** Replicated health drain reproduces real unconsciousness (hp=1 ko=true). Discovery: the wire targetGuid is the per-save Guid, not SharedSoulGuid as documented — cross-install validity unknown, flagged as the lead suspect for the WO-38 "KO didn't cross" report. |
| 4 | Horse sync live verification | **Answered.** ForceMount onto a world horse works; stream beats horse AI; release clean. Gaits don't render on a live-brained adopted horse + jitter/clipping — polish deferred. |
| 5 | Forge bug (item D) | **Deferred at the human's direction.** Test mounted live but observation aborted; hypothesis unconfirmed, no fix shipped, explicitly not fully explored beyond WO-38. |
| 6 | Stuck barks A/B (item E) | **Bug does not reproduce on 0.13.6** (barks resolve). SetIgnorant confirmed targeting-safe; stays a manual toggle, not defaulted. |
| 7 | Shirt/pants source (item G) | **Closed.** Both class ids appear in EquippedArmorsByClassId and render on player and ghost. No third map exists. |
| 8 | Skip-kind detection (item H) | **Shipped.** BedTrigger proximity at skip start: sleep vs wait vs fast-travel all resolve. Wire kinds verified in the final install round. |
| 9 | WO-38 leftovers | **All three addressed.** Long fast travel → exactly one announced skip (live); quest timer not exercisable (no timed quest on save); phasing tug-of-war did not reproduce under a driven NPC (pinned steady, no vibration). |
| 10 | Diagnostics bundle (item K) | **Shipped.** Agent tees to agent.log; launcher COLLECT LOGS zips kcd.log + agent logs + app logs + config to the Desktop. |
| 11 | Launcher crashes + noise (items I/J) | **Resolved/mitigated.** "Silent crashes" are unproven (no clean-exit marker existed — one now does); Blazor render Debug chatter filtered (~80% of log volume). Triple-render itself deliberately not chased. |
| 12 | Map markers (item B) | **Cut**, per the WO's priority rule (protect Phases 1–3, cut from the bottom). |
| 13 | NPC sync scale (item N) | **Cut**, same rule. Cap unchanged. |

Also this session, at the human's request: VERSION bumped to 0.13.6
(user-chosen) and full release artifacts built mid-session, then rebuilt at
session end with the final pak. The installer lifecycle suite (41 tests)
remains human-run before distribution.

Suites: Test-TimeSkipRelay 22/22 (incl. new T9 combat + T10–T14 claims),
Test-ReleaseVersion 6/6, Test-InstallerDetect 21/21, Farkle at release build.
New live harnesses: Test-CombatVizE2E.ps1, Test-HorseAdoptE2E.ps1.
