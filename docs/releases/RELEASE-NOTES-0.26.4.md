# KCD2-MP 0.26.4 — NPC brain suppression on by default

The label for everything on `main` as of WO-108 (2026-09-21), packaged as
`KCDMP-Setup-0.26.4.exe`. Setup exe only. **To go back:** the tag
`rollback/0.26.3` and `KCDMP-Setup-0.26.3.exe` — or, without reinstalling
anything, type `mp_preset_legacy` in the console (below).

**This build exists to be tested with a peer.** Nothing in it has run
two-player. Read `docs/WO-108-peer-test-runbook.md` (one page) before the
session; it says what to look at and what not to report as new.

---

## What changed: the pause lever is ON

Since 0.26.1 the mod could ask the engine to suspend an NPC's brain
(`wh_ai_PauseNPC`) while another player's machine drives that NPC. 0.26.2
turned it off after a two-player session appeared to show it did nothing
(155 violations, all "paused"). WO-107 established that reading was wrong:
the field that said "paused" reported the mod's own bookkeeping, not the
engine, and the movement it counted was the engine settling a body back
toward where it had been, not a brain. The lever itself is the engine's own
latched, multi-owner suspension; solo it held through a 38 Hz stream,
melee damage, mid-combat application and ~50 minutes.

**0.26.4 turns it back on**, and this session added what was missing around
it:

* **It never leaks into a save.** Tested three ways — in-process quick-load,
  `wh_sys_LoadGame`, and a full quit-to-desktop, relaunch, load — the
  suspension is gone after every one. (observed)
* **Bulk holds.** 46 NPCs (a whole town square) suspended in one batch, all
  motionless for 30 s, no frame hitch, 21 walking again within 60 s of the
  resume. (observed, solo)
* **Only a body being driven is ever suspended**, and only on the machine
  that is not the authority. If a suspended NPC stops receiving writes for
  ~8 s the mod notices (`MP-PAUSE-GAP` in `kcd.log`), resumes it, and says
  so. A coverage gap can now only produce a jittery NPC, never a statue.
* **10 s release dwell** (`mp_resume_dwell <s>`): when a stream stops, the
  pause is held 10 s before the brain is resumed, so walking the edge of the
  radius does not resume-and-repause NPCs. After a resume the brain
  re-plans for ~14 s before it moves; that is normal.
* **Honest logs.** Every pause/resume line (`MP-PAUSE`) carries the NPC
  name, its soul id, its entity id and whether the console call succeeded.
  The old `paused=` field is gone; `pause_issued=` and `pause_exec=` say
  exactly what they mean. Displacement that looks like the engine's own
  settle-back is tagged `kind=relax` instead of being counted as a
  violation (this tag is synthetic-only so far — nothing live triggered it).

## Defaults that changed (three, and only these)

| default | 0.26.3 | 0.26.4 | why |
|---|---|---|---|
| `mp_authority_pause` | off | **on** | WO-107 (the lever works; the metric lied), WO-108 Phase 0 (no save leak) |
| `mp_npc_replica` | on | **off** | WO-106 §5: cannot work by construction (`SharedSoulGuid` cannot address a live NPC); it never promoted once in three builds |
| `mp_npc_yield` | on | **off** | inert under host authority since WO-102; turning it off stops the status line lying. Its thresholds still drive the contention detector |

Nothing was removed. Every toggle still has its console command.
`docs/WO-108-toggle-inventory.md` lists every runtime toggle in the mod
with its shipped default and status.

## New console commands

| command | what |
|---|---|
| `mp_preset_clean` | re-apply the 0.26.4 defaults (16 values, each logged as `MP-PRESET`) |
| `mp_preset_legacy` | the 0.26.3 defaults in one command — pause lever off, replicas on, yield on, no dwell. The "it got worse" button |
| `mp_resume_all` | panic: switch the lever off and resume every NPC this session suspended, no questions |
| `mp_resume_dwell <s>` | the release dwell (default 10; 0 = 0.26.3's resume-at-once); bare reports |
| `mp_puppet_rate <ms>` | (from 0.26.3) the write-rate A/B, still unrun: try 200, then 500, while an NPC sinks |

Neither preset touches the authority model (`mp_authority_host`,
`mp_pos_native`, `mp_npc_scan_native`).

## Known in 0.26.4 — please do not report these as new bugs

A suspended brain stops doing everything it did for free. The wire carries
an NPC's position, yaw, health and six flags (dead, unconscious, weapon
drawn, a swing cue, carried, engaged). Everything else is not on the wire:

* **Mannequin legs, generic idle.** A driven NPC on the joiner walks with
  a generic walk/run loop played from its speed (the mod has done this
  since 0.19), not its own gait, and turns without turn animations. A
  *standing* driven NPC shows a generic idle instead of what it was doing
  (sweeping, sitting, working). Whether the loop plays reliably on a
  suspended body under a real two-player stream is unconfirmed. **The main
  judgement this test should produce, beyond "is the jitter gone", is
  whether this is bad enough to block play.**
* **No head-look, gestures, barks or ambient lines** from driven NPCs on the
  joiner; **no door, chair or prop interaction**; **no combat decisions**
  on the joiner's copy (swings are cued from the host; it does not pick
  targets, block or dodge); **no reactions to the joiner** (no turning to
  look, greeting, stepping aside).
* **Attacking a driven NPC may raise no crime response on the joiner**, and
  the two clients may disagree about whether a crime happened.
* **~14 s before a resumed NPC moves again**, plus the 10 s dwell: an NPC
  you walk away from may stand for up to ~25 s. That is not a statue. A
  statue never moves again — `mp_resume_all`, note the time and the name.
* Standing open issues unchanged from 0.26.3: cutscene clock skew,
  conversation lockouts, F11 quest catch-up, walking-corpse fight targets.

If jitter is unchanged, the first thing to check is not the lever but the
identity lines: did both machines resolve the same NPC name to the same
body? Compare `wuid=` for a name across the two logs (runbook, last
section).

## Verification status

* **(observed, solo)** Phase 0 on three load paths; the 46-NPC bulk hold
  and resume; every Phase 5 smoke item against the shipped pak from a cold
  launch: identity lines, the `pause_issued/pause_exec` fields, a genuine
  20 m divergence still reported as a divergence, `mp_resume_all`, both
  presets round-tripping, the coverage-gap detector, and the
  `WO108-BUILD pause_lever=on` marker on a fresh load with nothing typed.
* **(synthetic)** the relax tag, the reload re-assert, the authority guard:
  `tools\Test-WO108Synthetic.ps1` 87/87; WO-102 196/196; WO-104 92/92.
* **(inconclusive)** everything two-player: whether jitter is gone, whether
  both machines suspend the same body, whether locomotion loops play on a
  suspended body under a live stream.

## Also in this build

* The agent acknowledges the `authority_pause` toggle event instead of
  logging it as unknown.
* Console help for `mp_authority_pause_on`, `mp_npc_replica_on`,
  `mp_npc_yield_on` and `mp_probe_npc_pause` no longer carries the refuted
  claim.
* `MP-SUMMARY-MOD` carries `pause_relax`, `pause_gaps`, `pause_reasserts`,
  `pause_dwell_resumes`, `pause_cancelled`, `pause_pending`,
  `pause_refused`; `mp_wo102_status` shows the dwell, pending and
  ever-paused counts and the replica/yield state.

## ⚠ Matched set, both machines

Both machines must run 0.26.4. A 0.26.3 machine sees none of the new log
lines, keeps replicas on, and its violation log still carries the old
`paused=` field — a mixed session cannot be interpreted. Verify with the
`WO108-BUILD pause_lever=on` line near `MOD INIT` in each `kcd.log`.
