# WO-102 — field-session runbook (the A/B)

**For the two-machine session.** Both machines on the WO-102 build (matched
set: agent, pak, `KCDMP.dll`, relay). Everything WO-102 changed is
**(synthetic)** or **(code-verified)** until this runs; nothing below has
been seen live.

Console commands are **argless** (the console drops arguments). Every toggle
is a pair.

| toggle | on | off | shipped default | what it does |
|---|---|---|---|---|
| host NPC authority | `mp_authority_host_on` | `mp_authority_host_off` | see release notes | one machine (the damage-authority holder) owns every NPC; the other never claims; no hand-backs |
| pause lever | `mp_authority_pause_on` | `mp_authority_pause_off` | **off** | under host authority, pause each puppet's local brain (`wh_ai_PauseNPC`) — **run §1 first** |
| native position | `mp_pos_native_on` | `mp_pos_native_off` | see release notes | position/yaw/riding from the DLL pipe instead of the log line |
| status | `mp_wo102_status` | | | prints every flag + this client's role |
| resync | `mp_resync_npcs` | | | one-shot NPC position/life-state push from the owner |
| probe | `mp_probe_npc_pause` | | | §1, single machine |

Bundle at the end, **from both machines**: `agent.log`, `kcd.log`,
`kcdmp-native.log`, and the relay log from the host. `mp_summary` on both
before quitting.

---

## 0. Before the A/B — five minutes, one machine

Do this **solo** first; it decides whether the pause lever may be switched on
in §2.

1. Launch normally through the launcher (agent + DLL). Stand within 15 m of a
   walking or working ambient NPC (not seated, not in dialogue).
2. `mp_probe_npc_pause`. Wait ~10 s.
3. In `kcd.log`, read the `MP-PAUSEPROBE` lines (findings §3.3 has each
   step's meaning). The three that matter:
   * `step=3 … verdict_pos=HELD` → the pause stops the brain's writes. **Lever works.**
   * `step=4 … anim_after=` different from `anim=` at step 0 → the body still animates while paused.
   * `step=5 … moved_since_resume_m=` > 0 within a few seconds → clean resume.
4. While a second NPC is paused by hand (`wh_ai_PauseNPC <name>` in the
   console, then `wh_ai_ResumeNPC <name>`), hit it once: the engine's
   `Skirmish event: HitTarget on Dude (target <name>)` line means a paused
   body still takes hits.
5. **Pass** = HELD + animation changes + hit registers + resume. Then the
   pause lever is allowed in §2. **Any fail** = leave `mp_authority_pause_off`
   for the whole session and report the exact lines; the A/B still runs
   without it.

Also solo, ~4 minutes, for Phase 1: walk / jog / sprint / mount / ride /
dismount for 2 minutes with the native path **off**, then `mp_pos_native_on`
and repeat. Read `MP-POSCADENCE path=log` and `path=native` (every 30 s in
`agent.log`) and `MP-POSNATIVE oracle … delta_max_m=` (must stay well under
3 m). The decision is p95 vs p95 — findings §1.4.

---

## 1. The session — the same fight twice

Pick a spot with a handful of ambient NPCs (a tavern, a market). Both players
present, standing together.

### 1.1 Arm A — the claim model (`mp_authority_host_off` on BOTH machines)

1. `mp_wo102_status` on both: `authority_host=off`. Note which machine says
   `authority=self` (the owner-to-be) — that is normally the host.
2. Both players start a brawl with the same two or three NPCs. Keep it going
   for **≥ 2 minutes**. Both players hit the same NPC at least a few times.
3. Stop. `mp_summary` on both. Note the wall-clock window.

### 1.2 Arm B — host authority (`mp_authority_host_on` on BOTH machines)

1. Flip **both** machines mid-session (no restart, no reconnect):
   `mp_authority_host_on`. Expect within seconds in `kcd.log`:
   * on the non-owner: `WO102-AUTHORITY host authority ON on a non-authority:
     dropped N claim stream(s)`, and every later `MP-AUTHORITY` line reading
     `model=host` with `event=acquire … via=stream` **only** — no
     `via=claim`, no `via=drag`, no `owner-change`;
   * on the owner: `WO102-AUTHORITY … scanning around every peer ghost`, then
     `WO102-AUTHORITY scan anchors=2 cap=10`;
   * on the relay: **no new `[CLAIM] granted` lines** from this moment on.
2. **If §0 passed:** `mp_authority_pause_on` on the **non-owner** (it is a
   no-op on the owner). Expect `MP-AUTHORITY … event=pause via=wh_ai_PauseNPC`
   per puppet.
3. Same brawl, same NPCs, **≥ 2 minutes**, both players hitting the same NPC.
   Then sleep in a bed (either player) — that is a resync trigger — and fight
   another minute.
4. Stop. `mp_summary` on both.

### 1.3 Optional arm C — pause lever off vs on, same model

If §0 passed and time allows: repeat 1.2 with `mp_authority_pause_off`, so the
violation count with and without the lever can be compared directly.

---

## 2. What to read, and what "it worked" looks like

Compare arm A's window with arm B's, per machine.

| signal | arm A (claim) — expected | arm B (host) — expected if ownership is truly single |
|---|---|---|
| relay `[CLAIM] granted / released reason=expiry / muted` | present, all to the non-host id, expiries mid-fight | **none** after the flip |
| `MP-AUTHORITY … event=owner-change` (non-owner) | some | **zero**. Any is a defect |
| `MP-AUTHORITY … via=claim` / `via=drag` (non-owner) | present | **zero** |
| `MP-NPCDIVERGE` releases | 0–3 per machine, some at 24–97 m | **zero** (the rule is refused under host authority) |
| `MP-AUTHORITY-VIOLATION kind=diverge` | n/a | **zero** = no second writer at all. Non-zero with `paused=0` = the local brain still fights (expected without the lever); non-zero with `paused=1` = **the lever does not stop the writer — report it** |
| `MP-AUTHORITY-VIOLATION kind=contention` | n/a | as above; the count is the tug-of-war made visible |
| `MP-NPCFIGHT … mean_m= max_m=` | mean 0.07–0.17 m, max up to 97 m | with the lever on: mean near zero, **max well under 8 m**; without it: like arm A's mean, but max also under 8 m because nothing is released |
| `MP-NPCYIELD` | present | **zero** (refused) |
| `MP-REQUEST dir=out/in … result=resolved dt_ms=` | none (channel off) | one pair per committed attack at an owned NPC; `dt_ms` is the ask-to-hit gap. `unresolved` = a swing that landed nothing |
| `MP-NPCRESYNC dir=burst … n=` after the sleep | `dir=skip cause=host-authority-off` | one burst on the owner, `dir=apply` lines on the non-owner, `moved=1` only for NPCs that had drifted |
| player-visible | NPC teleports/runs off when the second player attacks; NPC present for one, absent for the other | **the 97 m teleports are gone entirely.** If any NPC still jumps far mid-fight, ownership is not single — find the `MP-AUTHORITY` line that says who else acquired it |
| `MP-SUMMARY-MOD … auth_model= auth_violations= auth_owner_changes=` | `claim`, owner changes > 0 | `host`, `auth_owner_changes=0` |

The honest failure modes, so they are recognised rather than explained away:

* **Arm B jitter is worse than arm A** (without the pause lever): expected —
  the claim model's yield handed contested bodies to the local brain; host
  authority refuses to, so the tug-of-war is continuous instead of resolving
  into divergence. That is what `mp_authority_pause_on` exists for. If §0
  failed, this is the trade the release notes state.
* **An NPC only one player sees** is not fixed by any arm — findings §6.3.
* **The host's ghost of the joiner stands still while the joiner moves**: not
  WO-102 — check `MP-SUMMARY section=position ghost_stale_in` (WO-101).

---

## 3. Rollback, in the field

`mp_authority_host_off` on **both** machines returns the 0.23.2 claim model
within one tick; standing relay claims resume on the next non-host packet.
`mp_authority_pause_off` resumes every paused NPC. `mp_pos_native_off`
returns to the log line. Nothing needs a restart. The 0.23.2 installer is
the tag `rollback/0.23.2`.
