# 0.26.4 peer test — the one page for two people mid-session

**Both machines must run 0.26.4.** A 0.26.3 machine paired with a 0.26.4
machine is not this test; it is a mixed-version session and nothing below
applies to it.

No console command is needed. Load the game through the launcher, connect,
play. The build is configured for this test out of the box.

---

## What you should see on load (nothing typed)

Open `kcd.log` (or just trust it) — within the first seconds after
`[KCD2-MP] === MOD INIT ===` there is one line:

```
[KCD2-MP] WO108-BUILD pause_lever=on npc_replica=off npc_yield=off resume_dwell_s=10.0 -- 0.26.4 defaults (mp_preset_legacy = 0.26.3)
```

If that line is missing, or says `pause_lever=off`, the old pak is still
installed. Stop; nothing you observe is about 0.26.4.

On the **joiner** (the machine that is not the damage authority), every NPC
the host streams gets one line when it starts being driven:

```
[KCD2-MP] MP-PAUSE npc=<name> event=pause wuid=<hex> eid=<hex> body=NPC exec=ok why=puppet-start owner=<id> ...
```

On the **host**, none of those lines appear (the host's own brains are the
truth and are never suspended). If the host logs `MP-PAUSE ... event=refused
why=this-machine-is-authority`, that is expected and harmless.

## The one-line pass/fail

**Walk into a crowd together. Do the NPCs jitter? Do they sink into the
ground?**

* Jitter gone, no sinking → pass. Say so, capture the logs anyway.
* Jitter unchanged → **first check the identity lines** (below), not the
  lever. The most likely failure is that the two machines resolved the same
  NPC name to different bodies, so the joiner suspended the wrong NPC.
* NPCs standing frozen where they should be moving, or a "statue" that never
  wakes → `mp_resume_all`, then note the time and which NPC.

## Three commands worth knowing

| command | when |
|---|---|
| `mp_preset_legacy` | "It is worse than before." Puts every 0.26.3 default back in one command (pause lever off, replicas on, yield on, no dwell). `mp_preset_clean` returns to 0.26.4. Both log every value they set. |
| `mp_resume_all` | Panic. Resumes every NPC this session ever suspended and switches the pause lever **off** so nothing re-pauses. `mp_authority_pause_on` (or `mp_preset_clean`) re-enables it. |
| `mp_puppet_rate <ms>` | The write-rate A/B nobody has run yet: `mp_puppet_rate 200`, then `500`, while an NPC is sinking. Default 50. |

Also handy: `mp_wo102_status` (one line: every relevant flag, how many NPCs
are paused/pending on this machine), `mp_summary` (the session counters).

## What to capture

* **Both** `kcd.log` files, whole. The point of capturing both is the
  identity lines: for the same `npc=<name>`, the joiner's
  `MP-PAUSE ... event=pause wuid=… eid=…` line and the host's
  `MP-AUTHORITY npc=<name> event=acquire owner=self` line can be compared
  after the session. Different `wuid` for the same name = wrong body paused.
* The **timestamp** (any clock, wall or the `t=` field) of anything odd,
  with one sentence: which NPC, what it did.
* If you used a command, which one and when.

Log lines that matter, greppable:

| line | meaning |
|---|---|
| `MP-PAUSE … event=pause/resume/release/cancel` | the lever's every action, with identity |
| `MP-PAUSE-GAP` | a paused NPC that was not being written — the safety net fired (expected to be rare; if it is frequent, say so) |
| `MP-AUTHORITY-VIOLATION … kind=contention` | something on the joiner still moved a driven body (the jitter mechanism, if any is left) |
| `MP-AUTHORITY-VIOLATION … kind=relax` | the engine's own settle-back, tagged; **not** a brain and not a bug |
| `MP-AUTHORITY-VIOLATION … kind=diverge` | a body yanked far away by the local world (different story beats) |
| `MP-PRESET` | a preset was applied; one line per value |

## Known in 0.26.4 — do not report these as new bugs

A suspended brain stops doing everything it did for free. What the wire
carries about an NPC is position, yaw, health, and six flags (dead,
unconscious, weapon drawn, a swing cue, carried, engaged). Everything else
below is **not on the wire** and comes from the local brain, which is now
suspended for driven NPCs on the joiner:

* **Generic legs, not the NPC's own gait.** The joiner's mod already plays a
  plain walk/run/sprint loop from the stream's speed, so a moving NPC should
  not glide — but it walks like a mannequin, turns without turn animations,
  and a *standing* driven NPC shows a generic idle instead of what it was
  doing (sweeping, sitting, working). Whether the loop always plays on a
  suspended body under a live two-player stream is (inconclusive) until this
  test; solo it did. **Please judge: is this bad enough to block play?**
  That judgement is the main thing this session should produce beyond the
  jitter answer.
* **No head-look, no gestures, no barks or ambient lines** from driven NPCs
  on the joiner. No door, chair, bench or prop interaction — a driven NPC
  walks to a door and stops; the host's copy opened it.
* **No combat decisions on the joiner's copy**: a driven NPC's swings are
  cued from the host (one flag), but it does not choose targets, block or
  dodge on its own. Weapon draw/sheathe follows the host.
* **No reactions to the joiner**: a driven NPC does not turn to look, greet,
  or get out of the way.
* **Attacking a driven NPC may raise no crime response on the joiner**, and
  the two clients may disagree about whether a crime happened (WO-107 §10,
  observed solo). Do not test crime this session unless you want to.
* **~14 s before a resumed NPC moves again** (observed). When the host stops
  streaming an NPC (you walk apart, it leaves the radius), the joiner holds
  its pause for 10 s (`mp_resume_dwell`), resumes it, and the brain then
  re-plans for ~14 s before it walks. Up to ~25 s of a standing NPC after
  you leave it is expected, not a statue. A statue is one that never moves
  again — that is `mp_resume_all` plus a note.
* Standing open issues unchanged from 0.26.3: cutscene clock skew,
  conversation lockouts, F11 quest catch-up, walking-corpse fight targets.

## If jitter is unchanged

1. Grep both logs for the same NPC name. Compare `wuid=` on the joiner's
   `MP-PAUSE event=pause` line against what the host has for that name
   (the host does not print wuid for its own tracked NPCs; the joiner's
   `npcid` event and the host's `MP-AUTHORITY … acquire` line are the
   nearest pair). Two names mapping to different bodies is a resolution
   problem, not a lever problem.
2. Check the joiner's `MP-AUTHORITY-VIOLATION` lines: `kind=contention`
   with `pause_issued=1 pause_exec=ok` means the lever was issued and the
   body still moved — that is the result WO-107 could not produce solo and
   the one worth reporting verbatim. `kind=relax` lines are not that.
3. `mp_preset_legacy` and compare by eye. Then `mp_preset_clean`.

Nothing in this build has run two-player. Solo, 46 NPCs were suspended in
one batch and all 46 stood motionless for 30 s with no frame hitch; after the
bulk resume 21 of them were walking again within 60 s (14 had been walking
before the pause; the rest had nowhere to go). The suspension did not survive
any save-load path (good: nothing leaks into a save). That is the evidence;
this session is what it was built to collect.
