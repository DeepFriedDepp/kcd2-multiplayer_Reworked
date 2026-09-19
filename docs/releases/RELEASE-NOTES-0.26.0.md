# KCD2-MP 0.26.0 — native position reads, uncapped authority radius

The label for everything on `main` as of WO-103 (2026-09-18), packaged as
`KCDMP-Setup-0.26.0.exe`. Setup exe only — there is no DirectInstall ZIP
(retired in 0.22.0). **To go back:** the tag `rollback/0.25.1` and
`KCDMP-Setup-0.25.1.exe`, or simply `mp_authority_host_off`, which returns
every WO-102/WO-102.5/WO-103 authority mechanism to the 0.23.2 claim model
in one command.

No game ran this session (same standing constraint as WO-102's and
WO-102.5's own opening sessions) — every claim below not marked
**(observed)** is **(code-verified)** or **(synthetic)**, stated plainly
throughout `docs/WO-103-findings.md`.

---

## ⚠ Matched set, both machines

Agent, pak, `KCDMP.dll` all from 0.26.0, on both machines. The wire is
**additive** — a mixed 0.25.1 / 0.26.0 pair does not lose sight of each
other — but it degrades:

* the native scan reply (agent ↔ `KCDMP.dll` only, never the relay) grew a
  4-byte header field (`droppedCount`); an older DLL simply never answers
  the request shape a 0.26.0 agent still sends identically (0x0B is
  unchanged), so this degrades exactly like every prior native-pipe
  addition — the agent's 20-consecutive-refusal give-up, same as always;
* the position/yaw push (agent → Lua, a local `ExecuteString` call, never a
  network packet) is new payload shape (`name:x:y:z:yaw:isHorse` instead of
  a bare name) — an old pak's `KCD2MP_ApplyNativeScan` would silently parse
  nothing out of the new format and track nothing from it (the old parser
  expects bare names with no colons); a mismatched pak+agent pair should
  simply not be run, not relied on to degrade gracefully here.
* no relay/wire-protocol change at all this release — `KcdMp.Relay.Tests`
  13/13, unchanged.

---

## What is actually in this build

### Uncapped authority radius (`#KCD2MP_SetAuthorityRadius`)

The upper clamp (300 m) is **gone** — only the 10 m floor and non-numeric/
NaN input are rejected now. The point is to find the real ceiling by
testing to failure in the field, not stop at a guessed number
(`docs/WO-103-field-runbook.md` §2, not run this session). **Default raised
150 → 300 m** — the maintainer's original target; nothing measured argues
against it (WO-102.5's own 150 m result held cleanly), but 300 m itself has
not been measured either. `#KCD2MP_SetAuthorityRadius("150")` is one line
back down if the field runbook finds a real cost.

### Native position and yaw (`mp_npc_read_native_on`, default **on**)

The native NPC scan (WO-102.5) already read every entity's position/yaw and
already put it on the wire — the entire gap was the agent discarding it
before forwarding only names to Lua. Fixed: the read loop now takes
position/yaw from the native push when it's fresh, falling back to exactly
the same live `e:GetWorldPos()` call it always made otherwise. **Nothing
ships stale** — the fallback is free, not a slower path, because the
entity handle is fetched every tick regardless (health/dead/KO/drawn/
engaged still need it — those offsets are unmapped, explicitly the next
session's job, not this one's). `mp_npc_read_compare` is the known-answer
check (native vs a live read, tolerance scaled by the push's age at a
generous walking-speed bound); a genuine mismatch auto-disables the toggle
rather than shipping a wrong position.

**Stated plainly, not hopefully**: because state (health/dead/KO/drawn/
engaged) still forces the same `System.GetEntityByName` call this WO did
not touch, this phase's own isolated performance win is expected to be
small — the real payoff arrives once a future session moves that state
natively too and the entity lookup disappears entirely. This is not a
disappointing result of this release; it is the necessary first half of a
two-part change.

### Native scan truncation, now honest and loud

Two real bugs found while building the above, not just the one named by
the work order:

* A truncated native scan reply used to silently drop every match past its
  8000-byte budget with no count kept anywhere. Now counted
  (`droppedCount`) and logged loudly on both the native and agent sides.
* **The same truncation used to silently under-report its own
  `total_walked`/entity counters** — the walk stopped early, so those
  numbers stopped incrementing early too, reading as a normal (if smaller)
  number while quietly being wrong. Fixed alongside the above: the walk
  now always finishes counting, truncated or not.
* A second, self-found ceiling: pushing position/yaw made the agent→Lua
  payload big enough to risk exceeding the local `ExecuteString`
  transport's own 4000-character batching budget at the old 200-name push
  cap. Lowered to 40 with the arithmetic shown in `GameBridge.cs` — a real,
  named consequence is that at very high tracked counts the push, not the
  native wire, becomes the tighter bottleneck; most such NPCs simply keep
  using the (safe, correct) live fallback instead of the new push.

### Instrumentation

`MP-NPCREAD path=lua|native|mixed n= mean_ms= p50_ms= p95_ms= max_ms=
window_s=` (a Lua-side mirror of the agent's own `MP-POSCADENCE` scheme) and
`MP-NPCTRACK tracked= culled=`, both every 15 s — Phase 0's baseline
measurement, which this session could not take against a live game
(`docs/WO-103-field-runbook.md` §1). `MP-NPCSCAN-TRUNCATED` and
`NPCSCAN: reply truncated …` (edge-triggered).

---

## Verification status, stated plainly

| item | status |
|---|---|
| radius uncap + new 300 m default | (synthetic) scenario `bb` updated, 4 checks (floor/NaN rejection, large-radius acceptance); **not** measured live at 300 m or beyond — `docs/WO-103-field-runbook.md` §2 |
| native position/yaw substitution | (synthetic) scenario `dd`, 18 checks, including the substitution proven by the EMITTED value (not just a flag); **never run live** |
| known-answer check + fail-closed | (synthetic) match and genuine-mismatch verdicts both proven, including the automatic toggle-disable; **never run live** |
| reply-truncation accounting fix | (code-verified); the underlying `total_walked` undercount bug (found, not assumed) is fixed by the same change |
| Phase 0 A/B (native vs Lua read cost) | **not taken** — no game ran this session; this release's own honest expectation is a SMALL difference, not a dramatic one (see above) |
| agent unit tests | (observed) 157/157, incl. 7/7 `NpcScanCodecTests` |
| Lua synthetic suite | (observed) 194/194 (was 169), zero regressions across every other suite in the repo |
| relay round-trip | (observed) 13/13, unchanged — no wire/relay change this release |

---

## Every toggle, its shipped default, and the one-line reason

All argless — the console drops arguments — except
`#KCD2MP_SetAuthorityRadius("<m>")`, which genuinely needs a number.

| toggle | default | reason |
|---|---|---|
| `#KCD2MP_SetAuthorityRadius` | ~~150 m, capped 300~~ **300 m, no cap** | the maintainer's original target; nothing measured argues against it, but 300 m itself is unmeasured — the point of this release is to let the field find the real ceiling |
| `mp_npc_read_native_on` / `_off` | **on** (new) | ships on per the project's standing rule for new mechanisms; fails itself closed automatically on a real known-answer mismatch, so "on" here does not mean "trusted blind" |
| everything from 0.25.1 | unchanged | untouched by this WO except where stated above |

**Standing rule for this project's toggle defaults** (stated by the
maintainer, carried forward from 0.25.1's release notes): new mechanisms
ship on by default so real play surfaces what still needs fixing, rather
than shipping off and calling that a "safe" default.
