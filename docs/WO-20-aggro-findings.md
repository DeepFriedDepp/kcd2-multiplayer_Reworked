# WO-20 Phase 2 — Lua `AI.*` aggro binds, re-tested with a corrected method

Investigated 2026-08-04, live against this project's own Modding Tools
build and injected `KCDMP.dll`, same session as `WO-20-faces.md`.

This re-tests `PROJECT-STATE.md` §4's closed finding — "Aggro / stimulus
injection... Lua `AI.*` — inert" — using the corrected method WO-18 P4
recommended: recover each bind's real native address via the Lua-closure
walk instead of guessing a call signature, per WO-18's own diagnosis that
the one prior probe (`Probe-AI-Behaviour.ps1`) used an **invented**
`CreateStimulusEvent(id, 0, "SOUND", {position=,radius=,threat=})`
signature and concluded "no effect" from that single wrong-shaped attempt.
The technique itself, and the observation that `scriptbinds-crossmatch.csv`
lists these binds as present in this build, is **Jefferson25625's** work
(`kcd2-exports`, used with permission, credited in `WO-20-faces.md`).

**Bottom line up front**: the "inert" verdict does not survive re-testing
unchanged, but it also isn't reversed. Two of five Lua `AI.*` binds tested
write real, verified engine state — a genuine, previously-undocumented
capability. None of them, alone or combined, produced observable NPC
movement or attack behavior toward a ghost within this session's test
window. **A1 (floored-ghost recovery) and A2 (one-sided combat) from
`WO-16-release-candidate.md` are not resolved.**

---

## Part 1 — the closure-walk technique, built and validated

Added `native/KCDMP/lua_closure.{h,cpp}` (new files) and pipe command
`0x05 ResolveLuaClosure` / `0x84 ClosureInfo` (`pipe_server.h/.cpp`) — pure
memory reads, SEH-guarded throughout, no writes to game state. Given a Lua
closure's address (`tostring(luaFn)`, hex, no `0x` prefix in this build's
`tostring` output), it walks WO-18's claimed offsets
(`closure+0x28 → descriptor`, `descriptor+0x28 → native callback`,
`descriptor+0x40 → name`) and reports the resolved address, which loaded
module it falls in, the RVA, a best-effort name, and the callback's first
48 prologue bytes. Driven from `tools/Probe-LuaClosure.ps1`, a raw named-pipe
client in the same style as `tools/Test-Aggro.ps1`.

Built with `native/Build-Native.ps1` (hit and fixed the same C2712
`__try`/object-unwinding constraint `rttr_abi.cpp` already documents — every
SEH-guarded function here holds only POD locals, string construction happens
after). Injected into the live game with the human's explicit go-ahead
(process injection, even read-only, is treated as a risk-worth-flagging
action in this project). **Game stayed healthy throughout** — debug API kept
answering, no crashes, across every closure resolved.

### What validated and what didn't

| Part of WO-18's technique | Status |
|---|---|
| `closure+0x28 → descriptor` | **works** |
| `descriptor+0x28 → native callback` | **works, strongly corroborated** — every resolved address landed inside a real, correctly-named loaded module at a plausible RVA (below), not garbage |
| `descriptor+0x40 → name string` | **does not reliably work** — empty for four of five functions tested; `AI.Signal` returned a single stray printable character ("H"), almost certainly noise from an unrelated byte happening to look like a bounded C-string, not a real name |

Resolved, live:

| Lua bind | Native address | Module + RVA |
|---|---|---|
| `AI.CreateStimulusEvent` | `0x7FF9284DB6C0` | `CryAISystem.dll+0x20B6C0` |
| `AI.SetFactionOf` | `0x7FF9284DBA80` | `CryAISystem.dll+0x20BA80` |
| `AI.AddPersonallyHostile` | `0x7FF9284DB930` | `CryAISystem.dll+0x20B930` |
| `AI.IsPersonallyHostile` | `0x7FF9284DB930` | `CryAISystem.dll+0x20B930` — **identical to AddPersonallyHostile** |
| `AI.Signal` | `0x7FF9284AD240` | `CryAISystem.dll+0x1DD240` |

**Correction to WO-18's own framing**: the technique proves these Lua
bindings route to real `CryAISystem.dll` code, not stubs — this alone is
strictly better evidence than the single invented-signature probe the prior
finding was based on. But it does **not** by itself recover the Lua-visible
parameter shape, which was the stated goal. Every resolved function shares
the *identical* top-level prologue shape (`mov rdi,rcx; mov rbx,rdx` after
the push sequence) — consistent with the standard CryEngine ScriptBind
convention, `ReturnType Method(IFunctionHandler* pH)`, where `rcx`=`this`
(the binding class instance) and `rdx`=`pH`. The actual Lua argument count
and types are read dynamically from `pH` deeper in the function body (via
`pH->GetParam(i, ...)` calls), not visible in the entry prologue. Recovering
those would need following the call graph further — a materially larger
disassembly task than reading 48 prologue bytes, not attempted this session.

**A real, unexplained finding**: `AI.AddPersonallyHostile` and
`AI.IsPersonallyHostile` resolve to the exact same native address, while
`CreateStimulusEvent` and `SetFactionOf` correctly resolved to *different*
addresses (ruling out a resolution bug that collapses everything to one
value). The empirical test below (Part 2) is consistent with this being a
genuine shared get/set dispatcher — calling the "Add" form with 2 args
changed what the "Is" form with the same 2 args reports — but this is
inference from behavior, not confirmed from the disassembly.

---

## Part 2 — empirical re-test against a real ghost and a real NPC

Setup: `mp_enable_aggro on`, a fresh brained ghost (`esModularBehaviorTree
="IdleSeq"`) spawned directly beside `ttkc_man_32`, a real, hand-placed,
independently-acting townsman (not a mod-spawned entity) — same subject
class WO-15/16/17 already used. Every call wrapped in `pcall`; every claimed
effect checked by reading real state back afterward, never inferred from a
fault-free return, per this project's own standing rule.

| Bind | Fault-free? | Verified state change? | Behavioral effect (NPC movement/attack)? |
|---|---|---|---|
| `AI.SetFactionOf` (4 argument-shape variants: `(id,str)`, `(entity,str)`, `(str,id)`, `(id,str,bool)`, `(name,str)`) | yes, all 4 | **no** — `FactionNode/Parent` read back empty (orphan) before and after every variant, immediate and 5s later | no |
| `AI.CreateStimulusEvent` (5 variants: entity-id pairs, position tables, string event names, `CreateStimulusEventInRange`) | yes, all 5 | **no** — `AI.GetAttentionTargetType`/`GetPeakThreatLevel` on the real NPC stayed `0` across 5 one-second samples after each batch | no |
| `AI.AddPersonallyHostile(npcId, ghostId)` | yes | **yes** — `AI.IsPersonallyHostile(npcId, ghostId)` read back `true` immediately after, where it would otherwise be unset. A genuine getter confirming a genuine setter, not a fault-free-but-empty read. | no — `GetAttentionTargetType`/`PeakThreatLevel` stayed 0, NPC position and `IsMoving` unchanged over 5s |
| `AI.SetAttentiontarget(npcId, ghostId)` + `AI.AddAggressiveTarget(npcId, ghostId)` | yes, both | **yes** — `AI.GetAttentionTargetEntity(npcId)` resolved to a real entity whose `:GetName()` matched the ghost's own display name (`Playerbrained2`), not nil/garbage | no — `GetAttentionTargetType` stayed 0, NPC position identical and `IsMoving=0` after 1.5s and again after 8s |
| All five combined, plus `AI.Signal(1,1,"OnEnemySeen",npcId)` | yes | (not independently re-checked; superseded by the individual results above) | **no** — NPC position byte-identical, not moving, ghost health unchanged (100) after a further 10s |

**`AI.SetFactionOf` is genuinely inert** — the negative result from the
single 2026-07-27 probe holds, now confirmed across four independent
argument shapes rather than one, so it isn't a signature-guessing artifact.
This means the risky, ownership-fragile native `SetParent` call
(`NATIVE-PLUGIN-findings.md`'s retracted-then-fixed faction-attach) still
has **no safer Lua-level alternative** — that hope from WO-18 P4 does not
pan out.

**`AI.AddPersonallyHostile`/`AI.IsPersonallyHostile` are real, working, and
new** — the first Lua `AI.*` write this project has ever confirmed actually
changes engine state, verified by an independent getter rather than a
fault-free return. **`AI.SetAttentiontarget`/`AI.AddAggressiveTarget` are
also real** — the NPC's own attention-target reference genuinely updated to
point at the ghost, confirmed by name, not merely accepted without error.

**Neither produced observable aggro.** Across every configuration tested,
individually and combined, the real NPC never moved (`IsMoving=0`
throughout, position identical to seven decimal places before and after),
never attacked (ghost health stayed 100), and `GetAttentionTargetType`/
`GetPeakThreatLevel` never left `0` even when `GetAttentionTargetEntity`
correctly pointed at the ghost. **Setting these flags is not sufficient to
make an NPC act on them** — whatever bridges "this NPC's AI state now
references a hostile target" to "this NPC's behaviour tree decides to
attack" is not reached by any of these five binds, at least not as called
here.

---

## What this means for A1 and A2 (`WO-16-release-candidate.md`)

**Not resolved, either one.** No fight was reproduced this session (the
real NPC never engaged the ghost at all under the Lua-bind path, so there
was no combat to examine for A1's floored-recovery question), and no new
lever for the ghost to attack back was found (A2) — `AddAggressiveTarget`
targets the *NPC's* attention at the ghost, not the reverse, and even that
one-directional write produced no visible behavior change. The proven,
working mechanism for real aggro remains WO-15/16/17's native faction
`SetParent` attach — unchanged, uncontested, and still the only path that
has ever produced a real NPC actually perceiving and attacking a ghost in
this project.

## Recommended `PROJECT-STATE.md` §4 amendment

WO-18 P4 recommended changing "Aggro / stimulus injection — no reachable
surface" to "no reachable surface *on the reflection and native surfaces
probed*," with the Lua binds noted as untested. That amendment is now
**partially superseded, not simply confirmed**: the Lua binds have been
probed, with a corrected method, and two of five turn out to write real
state. The accurate statement going into this project's memory is:

> Aggro / stimulus injection via Lua `AI.*`: **partially real, not
> sufficient.** `AI.AddPersonallyHostile`/`IsPersonallyHostile` and
> `AI.SetAttentiontarget`/`AddAggressiveTarget` write genuine, verified
> engine state (WO-20). `AI.SetFactionOf` and `AI.CreateStimulusEvent`
> remain inert under every argument shape tried. None of the working ones,
> alone or combined, caused an NPC to actually move toward or attack a
> ghost. The native faction-attach mechanism (WO-15/16/17) remains the only
> proven path to real aggro.

Applied to `docs/PROJECT-STATE.md` §4 as part of this WO.

## What wasn't attempted

- **Reproducing A1's floored-ghost fight** to see whether any of these
  binds affect recovery — no fight ever started via this path, so there
  was nothing to examine. Would need either the proven native faction
  attach (to get a real fight going) combined with these Lua binds during
  it, or a different provocation this session didn't try.
- **Following the disassembly further** to recover exact Lua-visible
  parameter types via the `pH->GetParam()` call sites — a materially larger
  task than the prologue read done here; flagged, not started.
- **A longer observation window.** Every "no behavioral effect" result
  above was checked over 5–10 seconds. A slower AI decision cadence over
  minutes was not ruled out, though WO-16's own native-mechanism testing
  produced visible perception within seconds, which is the standard this
  compares against.

## Files touched

- `native/KCDMP/lua_closure.h`, `native/KCDMP/lua_closure.cpp` (new)
- `native/KCDMP/pipe_server.h`, `native/KCDMP/pipe_server.cpp` — `0x05
  ResolveLuaClosure` / `0x84 ClosureInfo`
- `native/KCDMP/CMakeLists.txt` — added `lua_closure.cpp`
- `tools/Probe-LuaClosure.ps1` (new) — raw pipe client, same shape as
  `tools/Test-Aggro.ps1`
- `docs/PROJECT-STATE.md` §4 — amended per above
