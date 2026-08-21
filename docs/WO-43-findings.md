# WO-43 — combat-swing fidelity, Phase 1: implemented, built, not yet live-tested

Worked 2026-08-21 (Sonnet). Per the session brief, no disassembler was opened
this session; every address/offset below is taken verbatim from
`docs/WO-42-findings.md`. **The game was never launched this session** — this
machine's sandboxed AppData means live injection/testing has to be done by the
human, not by this session. That is the load-bearing fact behind every
"inconclusive" verdict below: the code is real, built, and ready to test: it
has not been watched render anything.

**Evidence classes, as elsewhere in this project:** observed / read-but-
unrendered / inconclusive. Nothing below is rounded up to "works."

---

## Gate 1 verdict: **genuinely inconclusive — implementation complete, live test not run**

Per the session brief's own Gate 1 options (direct-call success / guard-blocked
/ blocked by something else / inconclusive), the honest answer this session
can give is the fourth one, and precisely why: the diagnostic tool and the
real-data test path both exist and both build clean, but no one has watched a
fight yet. §4 below is a literal run sheet for the human to execute; §5
explains exactly how to read whichever outcome comes back, so the *next*
message in this thread can state a real verdict instead of another
"inconclusive."

---

## 1. What Phase 1 actually needed, and what it turned out to require

The session brief frames Phase 1 as "resolve a `C_Actor*`, pull a real
fragment/tag pair, call it." Two things became clear while implementing that:

1. **This codebase has zero prior art for any of `C_Actor` /
   `EntityModule.dll` / raw vtable-offset calls.** A full search of
   `native/KCDMP/*.cpp,*.h` for `C_Actor`, `GetPlayerActor`, `EntityModule`,
   `ScriptBindHuman`, `entityId` returns nothing. Every existing native
   capability (`native/KCDMP/rttr_abi.cpp`) works by RTTR reflection — walking
   `wh::rpgmodule::Soul` / `CombatSoul` objects by type/property/method
   **name**, resolved through `CrySystem.dll`'s exported RTTR runtime. WO-42's
   direct-vtable-call route is a genuinely new capability for this DLL, not an
   extension of an existing one. It was built as a new file,
   `native/KCDMP/combat_playanim.cpp`, following this codebase's own
   established conventions (PE export prefix-matching from `pe_exports.h`, SEH
   isolation per call per the `call_get_by_name`-style pattern in
   `rttr_abi.cpp`, and the `kcdmp-faction.txt`/`kcdmp-target.txt` opt-in
   trigger-file precedent).

2. **The mechanism this WO calls "the direct call route" is, provably, the
   same call the mod's Lua layer already makes.** `docs/WO-42-findings.md`
   §9.6 traces `human:PlayAnim(fragment, tags)` down to: resolve a `C_Actor*`,
   check `actor->[+0x28]->vtbl[0x80]() != 0`, and if so call `actor->
   vtbl[0xE48](actor, fragment, tags)`. That is the *entire* body of
   `C_ScriptBindHuman::PlayAnim` — there is no additional Lua-side gating.
   `kdcmp/Data/Scripts/Startup/kdcmp.lua`'s `KCD2MP_GhostCombat` already calls
   exactly this, on a real ghost, via `ghost.entity.human:PlayAnim(...)`
   (`kdcmp.lua:3757`), and that specific call was eyeball-confirmed live
   2026-08-20 to render `MotionJump` on a ghost (`docs/WO-40-findings.md`,
   addendum, Phases 6/8). **So the mechanism is not untested — a variant of it
   already renders successfully on a ghost.** What is untested is that same
   mechanism with **combat** fragments carrying **real, complete Mannequin
   tag strings** — every prior attempt (WO-39 empty tags, WO-40 generic
   guesses like `lngsw`) used placeholder data, never a real shipped row.

Consequence: this session produced **two** complementary, real artifacts
rather than one — a native diagnostic (genuinely new capability, gives guard-
value visibility Lua's `pcall` cannot) and a corrected real-data test of the
existing Lua path (zero new code, but never tried with real data before). Both
are described below; both need the human to run them live.

---

## 2. Native diagnostic — `native/KCDMP/combat_playanim.cpp` (new file)

Implements exactly the §9.6 mechanism, instrumented, with every step logged to
`kcdmp-native.log`:

```
C_EntityModule* m = *(C_EntityModule**)FindExport("?m_Instance@C_EntityModule@entitymodule@wh@@");
C_Actor* actor = wantPlayer
    ? FindExport("?GetPlayerActor@C_EntityModule@entitymodule@wh@@")(m)
    : FUN_180B3C2D0(FindExport("?GetScriptBindHuman@C_EntityModule@entitymodule@wh@@")(m), entityId);
log(actor);
guardObj = actor[+0x28]; guardValue = guardObj->vtbl[0x80]();
log(guardValue);
if (guardValue) { target = actor->vtbl[0xE48]; log(target); actor->vtbl[0xE48](actor, fragment, tags); }
```

Every address/offset is from `docs/WO-42-findings.md`:

| thing | source | status here |
|---|---|---|
| `?m_Instance@C_EntityModule@entitymodule@wh@@...` | §9.5, verbatim mangled name | resolved by prefix, matching the codebase's own convention |
| `?GetPlayerActor@C_EntityModule@entitymodule@wh@@...` | §9.5, verbatim mangled name, RVA `0x71B330` | same |
| `?GetScriptBindHuman@C_EntityModule@entitymodule@wh@@...` | §9.3/§9.6 — **named as existing, full mangled signature not transcribed** | resolved by prefix (see §3 below — this is the one real gap) |
| `FUN_180B3C2D0` (RVA `0xB3C2D0`) | §9.6, exact RVA and call shape given | resolved by module base + RVA, called exactly as §9.6 shows it used |
| `actor[+0x28]->vtbl[0x80]()` guard | §9.6 | replicated exactly |
| `actor->vtbl[0xE48](actor, frag, tags)` | §9.6 | replicated exactly, via the object's own vtable (not a hardcoded class vtable — same requirement the session brief called out) |

**SEH note:** every one of the above calls lives in its own tiny helper
function with no destructible locals, because `probe_play_anim()` itself holds
a `std::vector<ExportEntry>` and MSVC's C2712 forbids `__try` and C++ object
unwinding in the same frame — the exact trap this codebase's own comments in
`rttr_abi.cpp` already document. Confirmed by hitting the compile error once
and refactoring; **not** a WO-42 finding, just this session's own build
feedback.

**Trigger (opt-in, read-only, matching `kcdmp-faction.txt`/`kcdmp-target.txt`
precedent):** `kcdmp-playanim.txt` beside the deployed `KCDMP.dll`. Absent =
skip entirely (confirmed: the function's first action is this file read, and
its absence logs one line and returns). Three lines:

```
player
CombatAttackSyncGen
l_halberd+r_halberd+clinch1+eZ1+aZ2+attack_special+oppMale
```

— or, for an arbitrary actor, replace line 1 with its decimal CryEngine entity
id (obtainable live via the new `mp_entity_id [name]` console command added to
`kdcmp.lua`, §3 below).

Runs once, automatically, right after `probe_faction()` in the existing
startup sequence (`dllmain.cpp`) — no new pipe command, no agent/launcher
change, so this needed no cross-process plumbing beyond what already exists.

**Built clean** (`native/Build-Native.ps1`, Release): `KCDMP.dll`, 282,624
bytes. One compile error hit and fixed during this session (the C2712 above);
final build has zero errors, zero new warnings.

---

## 3. The one real gap this session found in WO-42's output

`GetScriptBindHuman` is the piece WO-42 could not hand off complete: §9.3 and
§9.6 both state it exists and is name-resolvable ("`?GetScriptBindHuman@…`,
plus ~120 further `C_EntityModule` getters — all name-resolvable"), but no
session transcribed its full mangled signature or RVA the way `GetPlayerActor`
got (§9.5 gives that one verbatim, `?GetPlayerActor@C_EntityModule@
entitymodule@wh@@UEBAPEAVC_Actor@23@XZ`, RVA `0x71B330`).

This session did **not** open a disassembler to close that gap, per the
session brief's explicit instruction. Instead it resolves `GetScriptBindHuman`
by **prefix** — `"?GetScriptBindHuman@C_EntityModule@entitymodule@wh@@"` — the
same technique this codebase already uses everywhere it doesn't have a full
mangled name (`pe_exports.h`'s whole reason to exist). This is sound because
MSVC mangling always encodes the identifier chain (function name, class,
namespaces) literally before the signature-dependent suffix, and WO-42 already
confirmed the identifier, the class, and the namespace all exist. It is not a
guess at anything WO-42 didn't already tell us was there. But it is
**unverified**: if the prefix does not match — wrong namespace nesting, a
name mangled differently than expected, anything — `find_export` returns
null (by construction: it also refuses to guess between multiple matches),
`combat_playanim.cpp` logs exactly that and stops before touching any pointer,
and the arbitrary-actor path of this diagnostic simply won't run. The
player-only path does not depend on this at all.

**Recommended follow-up for a future WO-42-style pass, if the live run below
shows `GetScriptBindHuman export not found by prefix`:** a ten-minute Ghidra
pass against `EntityModule.dll`, anchored the same way as everything else in
WO-42 (RTTI/`__FUNCTION__` strings), to get the verbatim mangled name — or,
more directly, decompile `C_EntityModule`'s vtable to find `GetScriptBindHuman`
as a slot rather than an export at all, since not every one of the "~120
further getters" may actually be independently exported.

---

## 4. What the human needs to run to get a real Gate 1 answer

Two independent tests, either of which can move Gate 1 from "inconclusive" to
a real verdict. Both need `Build-And-Install-Mod.ps1` (for the Lua/pak change)
and, for the native diagnostic, a fresh `Build-Native.ps1` + redeploy of
`KCDMP.dll` — this session already built it once cleanly; rebuild is only
needed if further edits are made.

**Test A — real Mannequin data over the existing (already-live-proven) Lua
path.** Zero new native code involved; this alone could resolve the WO.
In a real fight with a ghost present:
```
mp_combat_frag CombatAttackSyncGen l_halberd+r_halberd+clinch1+eZ1+aZ2+attack_special+oppMale
mp_ghost_combat 2
```
Watch the ghost. If a real swing renders: **Phase 1 succeeded**, full stop —
per the session brief, do not proceed to Phase 2. (Caveat: this exact row's
tags reference `l_halberd`/`r_halberd`; it renders most faithfully with a
halberd-class weapon in play. If nothing renders, that alone doesn't rule out
the mechanism — see Test B.)

**Test B — the native diagnostic, for guard-value visibility Test A can't
give.** Write `kcdmp-playanim.txt` beside the deployed `KCDMP.dll`:
```
player
CombatAttackSyncGen
l_halberd+r_halberd+clinch1+eZ1+aZ2+attack_special+oppMale
```
Launch, load a save, check `kcdmp-native.log` for lines starting `PLAYANIM:`.
For the ghost/NPC case instead of `player`, first run `mp_entity_id
<ghostName>` (or with no argument, to list every spawned ghost's id) in the
in-game console, then put that decimal id on line 1 and relaunch.

## 5. Reading whichever result comes back

| what the log/game shows | verdict |
|---|---|
| Test A renders a real swing | **Phase 1 achieved via the direct call route.** Done — do not proceed to Phase 2. |
| Test B: `GetScriptBindHuman export not found by prefix` (arbitrary-actor case only; `player` case is unaffected) | the gap in §3 is real; needs the WO-42-style follow-up above before the arbitrary-actor native path can run at all |
| Test B: `guard blocked the call (value=0)` | **checkpoint 1, as anticipated.** The real `ScriptBindHuman::PlayAnim` would also do nothing for this actor right now — log the actor (player vs. entityId) and whatever state it was in (in/out of combat, weapon drawn or not) so a pattern can be read off repeated runs |
| Test B: `the vtbl[+0xE48] call itself faulted` | **checkpoint 2, as anticipated** — wrong concrete vtable landed. Per the session brief, this is the one outcome that warrants a Fable hand-off rather than continued Sonnet iteration |
| Test A still renders nothing, Test B shows the guard passing and the call returning without a fault, but nothing visible happens in-game | the mechanism runs clean end-to-end but the fragment doesn't visibly animate — the next lead per WO-42 §5.3 is ADB/Mannequin-scope state (e.g., locomotion or another Mannequin scope owner overriding it), not the guard or the vtable slot |

---

## 6. Regression check (explicit, per the session brief)

- `native/KCDMP/combat_playanim.cpp` is a wholly new file; the only existing
  file it touches is `dllmain.cpp` (one new forward declaration, one new call
  in the startup `run_sync` block, both additive) and `CMakeLists.txt` (one
  new source line). Nothing existing was rewired.
- `kdcmp.lua` changes are additive: one new function
  (`KCD2MP_ReportEntityId`), one new console command (`mp_entity_id`), and a
  comment block next to `KCD2MP.combatSwingFragment`/`combatSwingFragTags`.
  **Their default values are unchanged** (`nil` / `""`) — nothing about the
  existing swing-cue path, or the jump/vault/takedown/sleep-pose
  `StartAnimation`/`PlayAnim` paths WO-39/WO-40 built, changes unless a human
  deliberately runs `mp_combat_frag` or writes `kcdmp-playanim.txt`.
- `dotnet build KCD2-MP.sln` — 0 errors (8 pre-existing warnings, all
  unrelated to this change: nullable-reference and `Registry.GetValue`
  platform-analyzer warnings in `KcdMp.Client`/`KCDMP_launcher`).
- `dotnet test dotnet/KcdMp.Farkle.Tests` — 59/59 passed.
- The `Test-*E2E.ps1` suites need the live game/agent and were not run this
  session (no game access here — see the top of this document); this is the
  same constraint every prior WO in this project has had for its own E2E
  suites when work happened away from the machine that runs the game.

---

## 7. Phase 2

Not reached. Per the session brief, Phase 2 (the paired sync-attack/sync-hit
construction route) is reachable only after a genuine Phase 1 result — success
or a real, observed failure — and this session produced neither: the
mechanism is built and ready, but unwatched. Handing this to Fable now would
be handing over a guess about what Phase 1 found, which the brief is explicit
about not wanting. The right next step is the human running §4's two tests and
reporting back what `kcdmp-native.log` and their own eyes actually showed.
