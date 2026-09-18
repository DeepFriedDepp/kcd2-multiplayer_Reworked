# KCD2-MP 0.25.0 — native NPC scan, uncapped co-located ownership

The label for everything on `main` as of WO-102.5 (2026-09-18), packaged as
`KCDMP-Setup-0.25.0.exe`. Setup exe only — there is no DirectInstall ZIP
(retired in 0.22.0). **To go back: the tag `rollback/0.24.0`** and
`KCDMP-Setup-0.24.0.exe`, or simply `mp_authority_host_off` on the running
0.25.0 build, which returns every new mechanism below to the 0.23.2 claim
model in one command.

---

## ⚠ Updated the same day, after this build was packaged

A live solo field session ran against this exact build immediately after
it shipped (`docs/WO-102.5-findings.md` §6). Two changes as a direct
result, **not yet re-packaged into a new Setup exe** — current as of the
repo, not as of the `KCDMP-Setup-0.25.0.exe` file itself:

* **`mp_npc_scan_native_on` now defaults ON** (was off, below). Live-
  verified clean: 37,079 entities walked, zero vptr mismatches,
  known-answer check clean (`only_lua=0`). The maintainer's own call:
  exercise what is new by default so real play surfaces what still needs
  fixing, rather than defaulting back to the already-known-broken
  pre-WO-102.5 path.
* **`mp_probe_npc_pause` now carries an explicit warning**: never run it
  against an NPC actively engaged in combat. A live run on one was
  followed by the maintainer being launched into the air, timing
  suggestive of the probe's own position-displacement step (not proven).
  Does not implicate the real pause lever, which never touches position.
* The pause lever's own live sample grew: 5/8 HELD on ambient NPCs (was
  8/8 in WO-102's original sample), 1/1 HELD in one combat case. Stays on
  by the same "exercise it" reasoning — see the toggle table below, now
  corrected.

The rest of this document is as originally written for the packaged
0.25.0 build; read it alongside the correction above, not instead of it.

---

## ⚠ Matched set, both machines

Agent, pak, `KCDMP.dll` and relay all from 0.25.0, on both machines,
including whoever runs the relay. The wire is **additive** — a mixed
0.24.0 / 0.25.0 pair does not lose sight of each other — but it degrades:

* the native NPC scan (agent ↔ `KCDMP.dll` only, never the relay) simply
  never answers against an older DLL; the agent gives up after 20
  consecutive refusals (~100 s blocking on the reply deadline) and the mod
  falls back to its own `System.GetEntitiesInSphere` walk, same shape as
  0.24.0;
* the relay's idle-timeout fix changes WHEN a silent disconnect is noticed,
  not what is sent — no packet-shape change at all this release.

**Native change.** `KCDMP.dll` is rebuilt: one new read-only pipe command
(`0x0B ScanNpcs`). Source-identical otherwise.

---

## Verification status, stated plainly

**Nothing in this build has run on a live game.** Everything is (synthetic)
or (code-verified), except one piece: the relay's idle-timeout fix, which
ran against a REAL two-peer TCP connection in `KcdMp.Relay.Tests` (not a
live game, but not a fake engine either).

| item | status |
|---|---|
| pause lever default | (observed) WO-102's own 8/8 solo probe, unchanged this release — **still never run under a live two-machine puppet stream** |
| native NPC scan | (code-verified) the read recipe (Ghidra, this session); **updated same day: live-verified clean** (37,079 entities, zero vptr mismatches, known-answer check passed) — now ships on, see the correction at the top |
| uncapped ownership + runtime radius | (synthetic) scenario `bb`, 17 checks; **not live-verified**, radius stays at 45 m (unmeasured) |
| culling | (synthetic) re-entry proven never-stale; **never seen against a real puppet stream** |
| co-location gating (hysteresis + dwell) | (synthetic) scenario `cc`, 19 checks; **the 60/90/10 numbers are a first guess** |
| departure handoff (Rule 2 + idle timeout) | (synthetic Lua) + **(real TCP round trip)** for the idle-timeout mechanism specifically |
| pause save-persistence | (code-verified) `C_IntelligentObject::Save` DOES write the suspend byte to a save chunk, conditionally; load-side re-application still unconfirmed |

`docs/WO-102.5-field-runbook.md` is the two-machine session this build
exists for, including the falsifiable condition (two players, one NPC, zero
`MP-AUTHORITY-VIOLATION`, zero `MP-NPCDIVERGE`) the whole WO was scoped
against.

---

## Every toggle, its shipped default, and the one-line reason

All argless — the console drops arguments — except
`#KCD2MP_SetAuthorityRadius("<m>")`, which genuinely needs a number and so
is deliberately NOT a console command (see the runbook). `mp_wo102_status`
prints every WO-102/WO-102.5 flag.

| toggle | default | reason |
|---|---|---|
| `mp_authority_host_on` / `_off` | **on** (unchanged from 0.24.0) | now also carries uncapped ownership, culling and co-location gating — all of it reachable through this one existing switch |
| `mp_authority_pause_on` / `_off` | **on** (was off in 0.24.0) | the solo probe passed 8/8; the alternative (no suppression at all under an uncapped radius) is continuous brain-vs-stream contention with no lever even tried |
| `mp_npc_scan_native_on` / `_off` | ~~off~~ **on**, updated same day | originally shipped off (zero live verification of a NEW native memory read); flipped after a live session verified it clean (37,079 entities, zero vptr mismatches) — see the correction at the top of this document |
| `mp_npc_cull_on` / `_off` | **on** | pure Lua logic (no native read, so no crash-class risk), the direct mitigation for the cap removal that ships on by default with it, and its one correctness property (re-entry is never stale) is synthetically proven |
| `#KCD2MP_SetAuthorityRadius` | **45 m** (unchanged effective value) | the 150 m target is not shipped as the default because nothing has measured what it costs — the radius runbook is how it gets raised |
| co-location hysteresis (enter/exit/dwell) | **60 m / 90 m / 10 s**, always on under host authority | no separate toggle — `mp_authority_host_off` is the escape hatch for all of it; the constants themselves are a first guess with no live tuning knob yet (a named gap) |
| `mp_pos_native_on` / `_off` | **off** (unchanged from 0.24.0) | still unmeasured |
| everything from 0.23.2 / 0.24.0 | unchanged | untouched by this WO except where stated above |

---

## What is actually in this build

### The native NPC scan (`mp_npc_scan_native_on`, default **on** as of the same-day correction above)

The enumerate+read half of the mod's own NPC-tracking scan, moved to C++.
Decompiled this session: the Lua binding behind `System.GetEntitiesInSphere`
walks the ENTIRE entity list on every call, not a spatially-scoped query —
that walk, repeated once per anchor every scan tick, is what the native
scan replaces. Only the resulting candidate NAME list is pushed back into
Lua; ranking, the cap, tracking and ownership stay entirely in Lua.
`mp_npc_scan_compare` is the known-answer check — run it before ever
switching this on for real play.

### Uncapped co-located ownership (rides `mp_authority_host_on`)

Under host authority, the 5-per-anchor cap is gone: every NPC within the
authority radius is owned, not just the nearest five. The radius is
runtime-adjustable (`#KCD2MP_SetAuthorityRadius`) and independent of the
0.23.2 claim model's own 30 m, which is untouched.

### Culling (`mp_npc_cull_on`, default on)

An owned NPC beyond 30 m of every player is tracked (nobody else can claim
it) but not actively streamed — what makes a larger radius affordable. An
engaged NPC (fighting a player) is never culled by construction. Re-entry
streams the NPC's CURRENT position and life state immediately, never a
stale one.

### Co-location gating (rides `mp_authority_host_on`)

One coarse together/apart state for the whole session — not per-NPC
proximity claiming, which WO-102 already showed producing 52-of-52 grants
to one player and mid-fight expiries. Hysteresis plus a 10 s dwell means a
boundary crossing has to be sustained to matter. Going apart never
interrupts a fight or a conversation: an engaged or in-dialogue NPC is
frozen and released the instant it stops being either.

### Departure handoff, and a real relay fix

If the damage authority disconnects, the relay's existing Rule 2
reassignment (unchanged) hands ownership to the survivor, who starts
scanning its own neighbourhood immediately — no new code needed for the
clean-disconnect case. The ungraceful case (a silently dead peer — cable
pulled, hard crash) was a genuine gap: the relay's read loop had no
timeout at all. Fixed with a 30 s idle timeout, proven against a real
two-peer TCP connection, not just a compiling field.

### Pause lever, now on by default (`mp_authority_pause_on`)

Unchanged mechanism from 0.24.0 (`wh_ai_PauseNPC`/`wh_ai_ResumeNPC`).
Resume is now guaranteed on more than the original three paths: `mp_stop`,
the agent disconnecting, and a 5 s periodic reconciliation sweep that
catches anything left paused with no puppet tracking it any more.
Decompiled this session: the engine's own `C_IntelligentObject::Save` DOES
write the pause state into a save chunk (conditionally) — the
reconciliation sweep is a real mitigation against that, not a
belt-and-braces gesture.

### Instrumentation (0.24.0 had none of these)

`MP-NPCSCAN`, `WO1025-RADIUS`, `WO1025-CULL`, `WO1025-COLOCATE`,
`auth_paused_now=` in `MP-SUMMARY-MOD`.
