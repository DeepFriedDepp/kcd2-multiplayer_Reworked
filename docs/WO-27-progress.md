# WO-27 progress

Session 2026-08-07. Game running throughout, via Modding Tools, save
`playline2`, human present at the machine. `playline2` re-confirmed
disposable at session start.

## Coverage

| phase | status | result |
|---|---|---|
| 0 — what already existed | found, not requested by the brief | A prior, interrupted attempt at this WO had already written Phase 2's fix into `kdcmp.lua`, uncommitted, with no findings doc. Verified and finished rather than redone. |
| 1 — what does `mp_enable_aggro` do now? | done, live A/B | It adds a real native hostile-faction attach (~20s, faction-wide recognition) on top of the always-on reactive combat WO-26 found. Off, only the reactive baseline applies. Confirmed by reading the ghost's faction node before/after an identical hit in both toggle states. |
| 2 — fix ghost duplication/leak | done, live multi-reconnect test | The uncommitted fix works: 4 reconnects under the same identity, deliberately without closing prior connections, held at exactly 1 live ghost every time, verified by individual API read-back, not by the fix looking right. |
| 3 — bring docs in line with reality | done | `README.md` and `docs/PROJECT-STATE.md` §4 updated; two stale "ghosts never fight back" claims corrected in `README.md`. |

## What actually happened, in order

1. Read the brief's three source files. `git status` showed `kdcmp.lua`
   modified with no matching commit or findings doc — read the diff before
   doing anything else, and recognized it as an interrupted prior attempt at
   this exact WO's Phase 2, matching the brief's prescribed fix almost
   verbatim.
2. Confirmed the game, relay (`KcdMpServer.exe`), and agent
   (`KcdMpClient.exe`) were already up from the human's setup, with the DLL
   injected.
3. **Phase 1**: read `GameBridge.cs` to find the real mechanism behind
   `mp_enable_aggro` (`TriggerReactiveAggroAsync` → `SetFactionHostileAsync`,
   a native faction attach), then ran `tools\Test-AggroE2E.ps1` with the
   toggle off (PARTIAL — damage applied, no faction attach) and again with it
   on (PASS — faction attach fired), toggling live via
   `KCD2MP_EnableAggro`, reading the faction node back via the debug API
   each time. Toggled back off afterward.
4. **Phase 2**: called `KCD2MP_GhostAudit()` (part of the uncommitted fix) to
   sanity-check the environment and got `nil` — the live game was still
   running the last-committed `kdcmp.lua`, not the working-tree fix. Told the
   human; they closed the game. Ran `tools\Build-And-Install-Mod.ps1` to pack
   and install the updated pak. Human relaunched via Modding Tools and
   reloaded `playline2`. Confirmed the fix was live (`GhostAudit` now
   resolves).
5. Wrote `tools\Test-GhostReconnect.ps1` and ran it: 4 reconnects under one
   identity, prior connections deliberately left open (the harder,
   no-clean-disconnect case). Exactly 1 live ghost after every reconnect,
   confirmed by individual `SoulsByName` lookups per connection id, plus a
   global `KCD2MP_GhostAudit()` cross-check. An unrelated, incidental
   reconnect of the host's own local ghost (Steam nick `M31`, id `4 -> 1`)
   happened in the same window and also held at exactly one ghost.
6. **Phase 3**: updated `README.md`'s status table and known-limits list, and
   `docs/PROJECT-STATE.md` §4, to state Phase 1's finding precisely and to
   fix two stale claims that predated WO-22/WO-26 and still said ghosts never
   fight back.
7. Ran the Farkle unit suite (59/59) as the project's standing automated
   regression check — unrelated to this WO's changes, no automated suite
   touches `kdcmp.lua` or the aggro path directly.
8. Cleanup: verified every test ghost (ids 2, 3, 5, 6, 7, 8) gone by
   individual read-back, not by script exit code.

## Addendum — caught a live incident before push

After the initial commit, the human reported an NPC visibly attached to
their character. Not a leftover — an active incident: two `KcdMpClient.exe`
agents were simultaneously connected under the same identity (one survived
this session's game restart because only the game, not the launcher, was
restarted; the other was started fresh on reconnect), locked in an
unbounded reconnect/respawn war (~4000 spawn events). Killed the stray
process to stop it immediately, confirmed clean via `KCD2MP_GhostAudit`, a
direct proximity sweep, and the human's own visual confirmation. Then fixed
the actual gap — `ConnectToGame` in `KCDMP_launcher/Pages/Home.razor.cs` had
no check for an existing agent before starting a new one — by adding
`StopExistingAgent()`. Full account and the reasoning behind it in
`docs/WO-27-findings.md`'s addendum. **Not yet live-verified end-to-end**;
the running launcher won't have this fix until it restarts.

## Judgement calls worth flagging

- **Did not redo Phase 2's fix from scratch.** Found it already written,
  uncommitted, matching the brief closely. Read it carefully for
  correctness rather than assuming it was right, then verified it live
  rather than either discarding it or shipping it unverified.
- **Caught the stale-pak problem before it produced a false negative.**
  `KCD2MP_GhostAudit()` returning `nil` was diagnosed as "the fix isn't
  deployed," not as "the fix doesn't work" — the difference matters, since
  the wrong read would have led to debugging or discarding working code.
- **Deliberately did not close synthetic connections between reconnects** in
  `Test-GhostReconnect.ps1`. A clean disconnect already worked before this
  fix (it triggers the relay's own Disconnect broadcast). Testing that would
  have proven nothing about the actual bug, which was the race where the old
  connection is still technically open.
- **Left the game/relay/agent running** at end of session rather than tearing
  the environment down, since the human was present throughout and no
  instruction was given to close it.

## Corrections this session forces on prior docs

- **`README.md`'s aggro known-limits list** ("One-sided... no ghost has been
  seen to land a blow") — false since WO-26, left uncorrected until now.
- **`README.md`'s separate "known not achievable" list** ("NPC aggro...
  nothing reachable makes an NPC's AI react to it... they never fight back")
  — same correction, a second stale copy of the same wrong claim that had
  drifted out of sync with the first.
- **`docs/PROJECT-STATE.md` §4** — no correction needed there; it already
  carried the accurate WO-25/WO-26 amendments. Added the WO-27 amendment on
  top rather than rewriting anything.

## Open, ranked

1. **`InterpTick` vs a fighting ghost** — unchanged this session, still the
   real remaining engineering problem per WO-26's Phase 3 measurement and
   `docs/WO-26-shared-combat-design.md`. Not in scope here.
2. **The ~20s auto-revert of the native faction attach** was not
   independently re-observed live this session (the synthetic peer's own
   disconnect removed the ghost before the hold expired). Unchanged code,
   not a new open question, but worth a note for whoever next touches
   `GameBridge.cs`'s aggro path.
3. **The donor-soul dependency for the native attach** (README: "depends on
   a playthrough-specific donor soul... on a save that hasn't reached that
   ambush, the attach fails quietly") was not re-tested this session — this
   session's save had already reached that point, so it never exercised the
   fallback.

## Next session should

Read `docs/WO-27-findings.md` in full before touching `kdcmp.lua`'s ghost
spawn/remove path or `GameBridge.cs`'s aggro handling again. Do not re-derive
Phase 1 or Phase 2 — both are live-verified here. WO-28 is the health/death
sync system per the session brief; start there from
`docs/WO-26-shared-combat-design.md`, not from this WO.
