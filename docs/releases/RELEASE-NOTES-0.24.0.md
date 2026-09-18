# KCD2-MP 0.24.0 — host-authoritative NPCs

The label for everything on `main` as of WO-102 (2026-09-18), packaged as
`KCDMP-Setup-0.24.0.exe`. Setup exe only — there is no DirectInstall ZIP
(retired in 0.22.0). **To go back: the tag `rollback/0.23.2`** and
`KCDMP-Setup-0.23.2.exe`.

---

## ⚠ Matched set, both machines

Agent, pak, `KCDMP.dll` and relay all from 0.24.0, on both machines,
including whoever runs the relay. The wire is **additive** this time — a
mixed 0.23.2 / 0.24.0 pair does not lose sight of each other (WO-101's
failure class) — but it **degrades**:

* a 0.23.2 joiner keeps claiming NPCs and the new host's stream is muted for
  those names → that joiner runs the old claim model;
* a 0.23.2 receiver turns every resync sample into a puppet that the 3 s
  silence release then drops — noisy, harmless;
* the two new action kinds (`NpcRequest`, `NpcResync`) are counted as
  `unknown_kind` by a 0.23.2 agent;
* with `mp_pos_native_on` against a 0.23.2 `KCDMP.dll`, the agent blocks on
  the reply deadline for ~100 s before giving up and falling back to the log
  line. (That toggle ships off.)

**Native change.** `KCDMP.dll` is rebuilt: one new read-only pipe command
(`0x0A ReadLocalState`). Source-identical otherwise.

---

## Verification status, stated plainly

**Nothing in this build has run on a live game.** Everything is (synthetic)
or (code-verified). The build ships with host authority **on** anyway, and
here is why, in one sentence: the behaviour it replaces is known-broken from
the 2026-09-17 session (every NPC claim expiring mid-fight, NPCs dragged
24–97 m between the two worlds), and the old model is one console command
away on either machine.

| item | status |
|---|---|
| host NPC authority (no claims, no hand-backs, owner scans around every player) | (synthetic) 109/109 mod checks incl. a 200-tick invariant run; **not live-verified** |
| the pause lever (`wh_ai_PauseNPC`) | (code-verified) exists and is the engine's own NPC pause-request system; **what it does to a body is unverified** — `mp_probe_npc_pause` decides it in ~3 minutes, solo |
| native position path | (code-verified) read established from the engine's own scriptbind; **not measured** against the log path; ships off |
| request channel | (synthetic) relay round trip + in-process; resolves through the existing damage path |
| NPC resync on sleep / fast travel / reload / new peer | (synthetic) 12/12 relay gate incl. the new flag |
| the claim model (`mp_authority_host_off`) | unchanged 0.23.2 code, still passes its eleven older suites |

`docs/WO-102-field-runbook.md` is the two-machine A/B this build exists for.

---

## Every toggle, its shipped default, and the one-line reason

All argless — the console drops arguments. `mp_wo102_status` prints them.

| toggle | default | reason |
|---|---|---|
| `mp_authority_host_on` / `_off` | **on** | replaces a known-broken model; synthetic-proven; rollback is the `_off` command |
| `mp_authority_pause_on` / `_off` | **off** | the lever is real but unverified live; run `mp_probe_npc_pause` first (runbook §0). Without it, host authority trades the old *divergence* for continuous *contention* on fought NPCs — expected, and what the A/B measures |
| `mp_pos_native_on` / `_off` | **off** | unmeasured; the runbook's two-window comparison settles it |
| `mp_resync_npcs` | — | manual one-shot resync (needs host authority) |
| everything from 0.23.2 (`mp_npc_sync`, `mp_npc_proximity`, `mp_npc_yield`, `mp_npc_diverge`, …) | unchanged | under host authority the yield and divergence rules are refused (logged as violations); under `_off` they behave exactly as before |

---

## What is actually in this build

### One machine owns every NPC (`mp_authority_host_on`, default on)

The damage-authority holder — normally the host — owns every NPC it has
loaded near **any** player. The other machine displays: it never claims (the
WO-39 drag claim and WO-60 proximity claim are bypassed, not removed), never
hands a body back to its own AI (the WO-90 180 s release and the WO-99 yield
are refused and logged as `MP-AUTHORITY-VIOLATION`), and every ownership
event is on the `MP-AUTHORITY` channel with `model=host`. The relay is
untouched: with no claim packets arriving, its table stays empty.

Costs, stated: an NPC only the far player's game has loaded is theirs alone
until you meet up; a quest-divergent NPC stands where the **host's** story
has it (the joiner's quest may be blocked until the host catches up — the
quest layer says why); a paused body's animation and hit registration are
what the probe checks.

### The brain pause lever (`mp_authority_pause_on`, default off)

`wh_ai_PauseNPC <name>` / `wh_ai_ResumeNPC <name>` are shipped console
commands; the decompile shows they file a per-NPC pause request in the
engine's own refcounted pause system (the brain host, not the entity). Under
host authority the non-owner pauses each puppet's brain on start and resumes
it on release. Off until `mp_probe_npc_pause` says HELD.

### Position off the log tail (`mp_pos_native_on`, default off)

Position, yaw, riding and the WO-100.5 body state from one native read per
frame over the DLL pipe, gated on the entity's vtable identity and checked
against the log line every sample (`MP-POSNATIVE oracle`). Both paths'
cadences are measured at once (`MP-POSCADENCE`). Ships off until the
comparison is run.

### The request channel

A non-owner's committed attack at the owned NPC it is facing is sent to the
owner as intent (`MP-REQUEST`), and resolved by the damage report that
follows — so the ask-to-hit gap is finally measurable on both sides. The
native queued-attack resolution on an NPC has never been attempted and is a
STOP for the maintainer.

### NPC resync

After a sleep/wait, a fast travel, a reload or a new peer — and on
`mp_resync_npcs` — the owner pushes one position/life-state sample per NPC
within 60 m of any player. Receivers snap copies that drifted more than 1 m
(never a body you are next to, talking to, or a local corpse) and apply the
owner's death state. This is the net for ambient drift; it does not and
cannot fix an NPC only one game has loaded.

### Instrumentation (0.23.2 had none of these)

`MP-AUTHORITY`, `MP-AUTHORITY-VIOLATION`, `MP-REQUEST`, `MP-NPCRESYNC`,
`MP-POSCADENCE`, `MP-POSNATIVE`, relay `[CLAIM] muted` + `packets=` /
`silentSec=` on releases. All in `docs/WO-98-log-format.md`.

---

## Corrected in place

From the 2026-09-17 relay log: 52 grants were 44 to the joiner's first id
and 8 to its reconnected id (zero to the host — that holds); median hold
47.4 s not 44.9; two divergences the prompt did not list (86 m and 96 m)
never tripped the WO-90 release at all. `docs/WO-102-findings.md` §2.
