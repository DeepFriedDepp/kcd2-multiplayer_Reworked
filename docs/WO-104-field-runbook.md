# WO-104 — field runbook (two machines)

Terse. Findings: `docs/WO-104-findings.md`. Both machines on the same
build (matched set: Setup exe, agent, DLL, pak). Nothing below is
verified until it is run; every line is (synthetic) until then.

## 1. Time sync (Phase 0) — 5 minutes, either save

The maintainer's save is already past 1,000,000 world-seconds, so it is
the test case.

1. Both connected. In `agent.log` on both: `[timeskip] announcing clock t=<7 digits>`
   and no `malformed time_now`. A single `malformed` line fails Phase 0.
2. One player sleeps or waits an hour. Other machine: `[timeskip] <who> ->
   worldTime=<n>` and the sky moves. Pass = the other clock advances within
   one poll (~10 s). Fail = nothing crosses.
3. `mp_status` / MP-SUMMARY-MOD is not involved; this is agent.log only.

## 2. Pause lever default (Phase 2) — read-only

`WO102-STATUS ... authority_pause=off` in kcd.log at connect on both
machines (`mp_wo102_status`). Nothing else to do; if a session still shows
`paused=1` on any `MP-AUTHORITY-VIOLATION`, someone switched it on.

## 3. Replicas (Phase 1) — the actual test

Default OFF. Run it ON deliberately, on the JOINER (the non-owner under
host authority is the only machine that promotes).

1. Both connected, `mp_authority_host_on` (default). Joiner:
   `mp_npc_replica_on`. Expect the toast "NPC replicas for contested NPCs:
   ON" and `MP-NPCREPLICA toggle state=on` in kcd.log.
2. Stand together. Host attacks one ambient male townsman (class `NPC`,
   not a guard: crime-authority souls enforce drawn weapons, WO-83). Joiner
   watches, then joins the fight.
3. Joiner kcd.log, in order, for that NPC:
   * `MP-AUTHORITY-VIOLATION npc=<n> kind=contention ... body=npc` (the
     trigger, once)
   * `MP-NPCREPLICA npc=<n> event=promote why=violation-contention body=kcd2mp_r_<n>`
   * the swap itself: **watch the body**. Pass = no flicker, no second body,
     no fall, same face and clothes. Fail = any of those (say which).
   * from then on: **zero** `MP-AUTHORITY-VIOLATION ... body=replica` for
     that NPC for the rest of the fight. This is the pass condition. Any
     `body=replica` line means something other than the stream moved a
     brainless body (physics push? — record `dist_m`).
   * joiner's own hits: agent.log `[combat] hit on replica 'kcd2mp_r_<n>'
     attributed to '<n>'` then `sent hit`. Host: `[npcdmg] in: ... hit '<n>'
     -> applied`. Fail = "no local soul answers to that name" on the host.
   * native swings on the replica: `[npcsync] puppet <n> entity id 0x...
     cached for native swings` right after the promote line.
4. End the fight (host sheathes, walks off). Joiner, ~10 s later:
   `MP-NPCREPLICA npc=<n> event=demote why=sheathed held_s=<n>`. Watch the
   body again: the real NPC must reappear exactly where the replica stood,
   the replica gone, no second body. Then it walks off on its own schedule.
5. Kill one instead. Expect `event=demote why=dead` at once and the corpse
   on the ground is the REAL NPC (lootable, named). A second body = fail.
6. `mp_npc_replica_status` on the joiner at the end: `active=0
   violations_on_replica=0`. MP-SUMMARY-MOD on quit: `replica_promotes=
   replica_demotes= ... replica_violations=0`.
7. Refusals to look for (all expected, none a failure): `event=refuse
   why=class=NPC_Female` on a woman, `why=in-dialog` if anyone was talking
   to the NPC, `why=soul-id-unreadable` (this one IS interesting — it means
   `soul:GetId()` does not read as a WUID on that NPC; paste the line).

## 4. If it goes wrong

* A body left hidden or a `kcd2mp_r_` body standing around after a save
  reload: connect, wait 5 s, `event=orphan` should log and clean it. If it
  does not: `mp_npc_replica_off` (demotes everything), then
  `mp_npc_replica_status` should read `active=0`.
* Anything visibly wrong in the swap: `mp_npc_replica_off` and report the
  exact kcd.log lines around the promote. The lever stays off by default
  precisely so this can be switched off without a rebuild.

## 5. What to bring back

Both machines' kcd.log and agent.log, plus: which NPC, who attacked first,
what the swap looked like in words, and the counts from step 6.
