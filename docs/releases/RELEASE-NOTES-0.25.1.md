# KCD2-MP 0.25.1 — native NPC scan, uncapped co-located ownership

The label for everything on `main` as of WO-102.5 (2026-09-18), packaged as
`KCDMP-Setup-0.25.1.exe`. Setup exe only — there is no DirectInstall ZIP
(retired in 0.22.0). **To go back:** the tag `rollback/0.25.0` and
`KCDMP-Setup-0.25.0.exe`, or the tag `rollback/0.24.0` and
`KCDMP-Setup-0.24.0.exe` two steps back, or simply `mp_authority_host_off`
on the running build, which returns every WO-102.5 mechanism to the 0.23.2
claim model in one command.

---

## Why 0.25.1 and not a re-tag of 0.25.0

`KCDMP-Setup-0.25.0.exe` was built and packaged, then a live solo field
session ran against that exact build the same day
(`docs/WO-102.5-findings.md` §6) and changed two things in source:

* **`mp_npc_scan_native_on` now defaults ON** (0.25.0 shipped it off).
  Live-verified clean before the flip: 37,079 entities walked, zero vptr
  mismatches, known-answer check clean (`only_lua=0`). The maintainer's own
  call: exercise what is new by default so real play surfaces what still
  needs fixing, rather than defaulting back to the already-known-broken
  pre-WO-102.5 path.
* **A real bug in `KCD2MP_NpcScanCompare` itself** — the known-answer check
  used the 0.23.2 claim-model radius (30 m) instead of matching
  `mp_npc_rescan`'s own radius choice under host authority (the 45 m
  `wo1025.authorityRadius`). Found live when `only_native` looked
  implausibly high; fixed in source. `only_lua` was never wrong (a
  smaller-radius Lua set is trivially a subset of the larger native one) —
  only the `only_native` count's readability was affected. Not
  safety-critical, but a real fix, and it was never redeployed to the field
  session that found it (that would have needed a pak rebuild and a game
  restart mid-session).

Both changes landed on `main` the same day (commits `92f6400`, plus the
compare-tool fix earlier in the same session) but **`KCDMP-Setup-0.25.0.exe`
predates both** — it was built before the live session ran. 0.25.1 is that
exact same build re-cut from the current `main`, so what actually ships
matches what the toggle table below says, instead of needing a manual
`mp_npc_scan_native_on` after install. `mp_probe_npc_pause` also picked up
an explicit same-day warning (below); nothing else changed.

---

## ⚠ Matched set, both machines

Agent, pak, `KCDMP.dll` and relay all from 0.25.1, on both machines,
including whoever runs the relay. The wire is **additive** — a mixed
0.24.0 / 0.25.x pair does not lose sight of each other — but it degrades:

* the native NPC scan (agent ↔ `KCDMP.dll` only, never the relay) simply
  never answers against an older DLL; the agent gives up after 20
  consecutive refusals (~100 s blocking on the reply deadline) and the mod
  falls back to its own `System.GetEntitiesInSphere` walk, same shape as
  0.24.0;
* the relay's idle-timeout fix changes WHEN a silent disconnect is noticed,
  not what is sent — no packet-shape change at all this release.

**Native change from 0.24.0.** `KCDMP.dll` carries one new read-only pipe
command (`0x0B ScanNpcs`), same as 0.25.0. **Native change from 0.25.0:
none** — no native source changed between the two; this is a rebuild of the
same code, not a new binary behaviour.

---

## Verification status, stated plainly

Everything below is (synthetic) or (code-verified) except the pieces
explicitly marked (observed) or (real TCP round trip) — both from the
0.25.0 build's live solo field session, which this release is a re-package
of, not a re-run of.

| item | status |
|---|---|
| pause lever default | (observed) WO-102's own 8/8 solo probe **plus** WO-102.5's live session: 5/8 HELD on ambient NPCs (62.5%, materially below the original sample) and 1/1 HELD on one actively-engaged NPC (see the combat-probe warning below) — **still never run under a live two-machine puppet stream** |
| native NPC scan | (code-verified) the read recipe (Ghidra); **(observed)** live-verified clean, 37,079 entities, zero vptr mismatches, known-answer check passed after the compare-tool radius fix — ships on by default |
| uncapped ownership + runtime radius | (synthetic) scenario `bb`, 17 checks; **(observed)** 45/90/150 m all held zero violations/crashes in a busy town (radius runbook, same live session); **not** live-verified under two machines |
| culling | (synthetic) re-entry proven never-stale; **(observed)** confirmed live at 150 m (78 tracked → 22 streaming); **never seen against a real puppet stream** |
| co-location gating (hysteresis + dwell) | (synthetic) scenario `cc`, 19 checks; the 60/90/10 numbers are still a first guess — no two-machine session has exercised the transition itself |
| departure handoff (Rule 2 + idle timeout) | (synthetic Lua) + (real TCP round trip) for the idle-timeout mechanism specifically |
| pause save-persistence | (code-verified) `C_IntelligentObject::Save` DOES write the suspend byte to a save chunk, conditionally; load-side re-application still unconfirmed |
| 150 m radius FPS cost | (observed) a real, measured drop (~35fps baseline → `DEGRADED ~25fps floor` at 150m, WO-59's own `tickstat` diagnostic) — **not** why 150 m stays unshipped as the default (nothing has cleanly attributed the recovery time yet); the 45 m default is unaffected |
| combat pause-probe safety | (observed) one live run of `mp_probe_npc_pause` against an actively-engaged NPC was followed by the maintainer being launched into the air, timing suggestive of the probe's own position-displacement step — **not proven**, does not implicate the pause lever itself (which never touches position); the probe now warns against this explicitly |

`docs/WO-102.5-field-runbook.md` is the two-machine session this build
still exists for, including the falsifiable condition (two players, one
NPC, zero `MP-AUTHORITY-VIOLATION`, zero `MP-NPCDIVERGE`) the whole WO was
scoped against — **still genuinely untested**, solo play cannot run it.

---

## Every toggle, its shipped default, and the one-line reason

All argless — the console drops arguments — except
`#KCD2MP_SetAuthorityRadius("<m>")`, which genuinely needs a number and so
is deliberately NOT a console command (see the runbook). `mp_wo102_status`
prints every WO-102/WO-102.5 flag.

| toggle | default | reason |
|---|---|---|
| `mp_authority_host_on` / `_off` | **on** (unchanged from 0.24.0) | now also carries uncapped ownership, culling and co-location gating — all of it reachable through this one existing switch |
| `mp_authority_pause_on` / `_off` | **on** (was off in 0.24.0) | the solo probe now has 13/16 ambient HELD across two sessions; the alternative (no suppression at all under an uncapped radius) is continuous brain-vs-stream contention with no lever even tried — see the maintainer's standing call on defaults, below |
| `mp_npc_scan_native_on` / `_off` | **on** | flipped after a live session verified it clean (37,079 entities, zero vptr mismatches) and the compare-tool's own radius bug was found and fixed; 0.25.0 shipped this off, 0.25.1 ships what the field session actually validated |
| `mp_npc_cull_on` / `_off` | **on** | pure Lua logic (no native read, so no crash-class risk), the direct mitigation for the cap removal that ships on by default with it, and its one correctness property (re-entry is never stale) is both synthetically proven and live-confirmed (78 tracked → 22 streaming at 150 m) |
| `#KCD2MP_SetAuthorityRadius` | **45 m** (unchanged effective value) | the live radius runbook held 45/90/150 m all clean, but 150 m has a measured FPS cost with no clean recovery story yet — the default stays where it was measured safest without a caveat |
| co-location hysteresis (enter/exit/dwell) | **60 m / 90 m / 10 s**, always on under host authority | no separate toggle — `mp_authority_host_off` is the escape hatch for all of it; the constants themselves are a first guess with no live tuning knob yet (a named gap) |
| `mp_pos_native_on` / `_off` | **off** (unchanged from 0.24.0) | still unmeasured |
| everything from 0.23.2 / 0.24.0 | unchanged | untouched by this WO except where stated above |

**Standing rule for this project's toggle defaults, stated by the
maintainer during the field session that produced 0.25.1:** new mechanisms
ship on by default so real play surfaces what still needs fixing, rather
than shipping off and calling that a "safe" default — turning a toggle off
after a live finding is a real fix (documented as one, with the finding
that drove it); shipping off from the start to avoid ever finding out is
not.

---

## What is actually in this build

### The native NPC scan (`mp_npc_scan_native_on`, default **on**)

The enumerate+read half of the mod's own NPC-tracking scan, moved to C++.
Decompiled this session: the Lua binding behind `System.GetEntitiesInSphere`
walks the ENTIRE entity list on every call, not a spatially-scoped query —
that walk, repeated once per anchor every scan tick, is what the native
scan replaces. Only the resulting candidate NAME list is pushed back into
Lua; ranking, the cap, tracking and ownership stay entirely in Lua.
`mp_npc_scan_compare` is the known-answer check — live-verified clean
(37,079 entities, zero vptr mismatches, `only_lua=0`) after fixing its own
radius bug (it was comparing against the 30 m claim-model radius instead of
the 45 m authority radius actually in effect).

### Uncapped co-located ownership (rides `mp_authority_host_on`)

Under host authority, the 5-per-anchor cap is gone: every NPC within the
authority radius is owned, not just the nearest five. The radius is
runtime-adjustable (`#KCD2MP_SetAuthorityRadius`) and independent of the
0.23.2 claim model's own 30 m, which is untouched. Live-verified at 45, 90
and 150 m in a busy town with zero violations or crashes; 150 m measurably
cost FPS (a pre-existing WO-59 `tickstat` diagnostic: ~35fps baseline →
`DEGRADED ~25fps floor`), so it stays a manually-dialled ceiling, not the
default.

### Culling (`mp_npc_cull_on`, default on)

An owned NPC beyond 30 m of every player is tracked (nobody else can claim
it) but not actively streamed — what makes a larger radius affordable. An
engaged NPC (fighting a player) is never culled by construction. Re-entry
streams the NPC's CURRENT position and life state immediately, never a
stale one — proven synthetically and confirmed live at 150 m (78 tracked
NPCs, 22 actually streaming).

### Co-location gating (rides `mp_authority_host_on`)

One coarse together/apart state for the whole session — not per-NPC
proximity claiming, which WO-102 already showed producing 52-of-52 grants
to one player and mid-fight expiries. Hysteresis plus a 10 s dwell means a
boundary crossing has to be sustained to matter. Going apart never
interrupts a fight or a conversation: an engaged or in-dialogue NPC is
frozen and released the instant it stops being either. The 60/90 m
enter/exit and 10 s dwell numbers have not been exercised by an actual
two-machine transition yet.

### Departure handoff, and a real relay fix

If the damage authority disconnects, the relay's existing Rule 2
reassignment (unchanged) hands ownership to the survivor, who starts
scanning its own neighbourhood immediately — no new code needed for the
clean-disconnect case. The ungraceful case (a silently dead peer — cable
pulled, hard crash) was a genuine gap: the relay's read loop had no
timeout at all. Fixed with a 30 s idle timeout, proven against a real
two-peer TCP connection, not just a compiling field.

### Pause lever, on by default (`mp_authority_pause_on`)

Unchanged mechanism from 0.24.0 (`wh_ai_PauseNPC`/`wh_ai_ResumeNPC`).
Resume is guaranteed on more than the original three paths: `mp_stop`, the
agent disconnecting, and a 5 s periodic reconciliation sweep that catches
anything left paused with no puppet tracking it any more. Decompiled this
session: the engine's own `C_IntelligentObject::Save` DOES write the pause
state into a save chunk (conditionally) — the reconciliation sweep is a
real mitigation against that, not a belt-and-braces gesture.

The live sample grew and got noisier: WO-102's original solo probe was
8/8 HELD; the WO-102.5 field session added 8 more ambient runs at 5/8 HELD,
3/8 SNAPPED BACK — the same NPC gave opposite verdicts on different runs.
A 9th run against an NPC actively fighting the maintainer HELD, but was
followed by the maintainer being launched into the air; the timing is
suggestive of the probe's own `SetWorldPos` displacement step, not proven,
and does not implicate the pause lever itself (which never writes
position). **`mp_probe_npc_pause` now carries an explicit warning: never
run it against an NPC actively engaged in combat.**

### Instrumentation

`MP-NPCSCAN`, `WO1025-RADIUS`, `WO1025-CULL`, `WO1025-COLOCATE`,
`auth_paused_now=` in `MP-SUMMARY-MOD`.
