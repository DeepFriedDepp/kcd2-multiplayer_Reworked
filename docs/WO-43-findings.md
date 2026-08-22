# WO-43 — combat-swing fidelity, Phase 1: live-tested. **CORRECTED** — the guard blocks; there was no partial render.

Worked 2026-08-21/22 (Sonnet). Per the session brief, no disassembler was
opened this session; every address/offset for the *calling* side is taken
verbatim from `docs/WO-42-findings.md`. Implementation happened first (no game
access from the coding environment); live testing happened in a second half
of the session, driven jointly with the human at the machine — Sonnet fired
the actual test calls directly against the running game's debug REST API
(`localhost:1403/api/System/Console/ExecuteString`, reachable from the coding
shell — see §7), and the human supplied the one thing that can't be
automated: watching the screen.

**Evidence classes, as elsewhere in this project:** observed / read-but-
unrendered / inconclusive. Nothing below is rounded up — including, this time,
a correction of an earlier claim in this same document that *was* rounded up.

---

## ⚠ Correction (added after this document's own initial verdict, same
## overall investigation, one session later)

**This document originally concluded Gate 1 was "blocked by something else
entirely — a consistent, reproducible partial render," and stated the guard
value was `1` (passing) on every ghost test. That guard claim was never
actually measured — it was an unstated assumption — and a follow-up session
measured it directly and found the opposite.**

**What actually happened, re-verified three independent times with the native
diagnostic (which, unlike Lua's `pcall`, actually logs the guard's return
value): `actor[+0x28]->vtbl[0x80]()` returns `0` — the guard blocks — for
every ghost tested, touched or untouched, with or without a weapon drawn.
`vtbl[+0xE48]` (`PlayAnim`'s real call) is never reached at all.** This is
exactly **checkpoint 1** from this WO's own original session brief — the
guard-blocked case, explicitly anticipated and explicitly *not* something that
needed Fable.

**The "partial swing" pose this document built its verdict on was
misattributed.** Every one of the three "swing" tests below called
`KCD2MP_GhostCombat(id, 0)` (`DrawWeapon()` — a separate, unrelated native
call) immediately before the `PlayAnim` attempt. A follow-up session proved,
directly, that **`DrawWeapon()` alone — with no `PlayAnim`/swing call made at
all — produces the identical "janky, reaching" pose**, reproduced on two
separate untouched ghosts. Lua's `pcall` around `PlayAnim` reports "no
Lua-level error" whether the internal guard passes *or* blocks — a blocked
guard returns cleanly, with no exception either way — so "`ok=true`" was never
evidence the call did anything. The pose everyone (including this document)
attributed to a stalled Mannequin swing was `DrawWeapon()`'s own incomplete-
looking stance the whole time.

**Corrected Gate 1 verdict: guard-blocked (checkpoint 1), not "blocked by
something else."** §5 below (the three "swing" tests and §5.2's "what this
rules out") is now superseded by this correction and kept only for the
historical record — read it as *what this document incorrectly believed it
had ruled out*, not settled fact: none of those three tests ever actually
invoked `vtbl[+0xE48]`, so they ruled out exactly nothing about it. See
`docs/WO-44-findings.md`'s own correction section for what
this means for that document's decompilation work (short version: the
decompile of `C_Player::PlayAnim` is real and accurate *for the player*; it
does not explain the ghost's behavior, because the ghost's call never reaches
that function or any other function at `+0xE48` — the guard stops it first.
Phase 2's recommendation — build the real combat action, not a bare fragment
call — is unaffected and, if anything, reinforced by two independent reasons
now instead of one flawed one).

**What is *not* corrected, and remains real, load-bearing evidence:** the
native diagnostic on the **player** (§4) — guard passed (`1`), vtable resolved
inside `EntityModule.dll`, no fault — was measured directly, not assumed, and
stands. The `GetScriptBindHuman`/`FUN_180B3C2D0` entity-id resolution path
(§3's "one real gap") is now confirmed working for arbitrary ghosts, not just
in principle — every ghost test this correction is based on used it
successfully, cross-validated by a correct `GetName()` readback. Those two
facts are why this correction could be found and proven at all.

---

## Gate 1 verdict (as originally written, now superseded — see correction above)

Per the session brief's Gate 1 options (direct-call success / guard-blocked /
blocked by something else / inconclusive), the honest, evidenced answer is the
third one, and it is a *strong* result, not a shrug:

**The direct call executes cleanly — guard passes, vtable resolves inside
`EntityModule.dll`, no crash — and it visibly moves the character. But for
every real combat fragment tried, on every independently-validated fresh
ghost, it produces the same partial, broken pose (weapon drawn, character
reaches toward a swing) and never completes a real swing.** This was
reproduced three independent times, with three different pieces of real,
un-invented data, on three separately-spawned and validated ghosts, ruling out
the obvious alternative explanations one at a time (§6). This is *not* the
guard-blocked checkpoint (guard value was `1`, passing, every time) and *not*
the wrong-vtable checkpoint (no fault, ever; the target address resolves
inside `EntityModule.dll`). It is exactly the third case the session brief
names as the one that needs Fable: "does something unexpected — not just
'does nothing,' but visibly wrong."

**(Superseded: the "guard value was 1" claim above was assumed, not measured —
see the correction at the top of this document.)**

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
were run live before this document was finalized (§4-5).

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

**Not exercised this session.** The live tests in §4-5 all used the `player`
path (arbitrary-actor ghost targeting was done at the Lua level instead — see
§5 — so `GetScriptBindHuman` was never actually called). This gap is
therefore still open and unverified either way. **Recommended follow-up for a
future WO-42-style pass, if a future session needs the native diagnostic's
arbitrary-actor path specifically:** a ten-minute Ghidra pass against
`EntityModule.dll`, anchored the same way as everything else in WO-42
(RTTI/`__FUNCTION__` strings), to get the verbatim mangled name — or, more
directly, decompile `C_EntityModule`'s vtable to find `GetScriptBindHuman` as
a slot rather than an export at all, since not every one of the "~120 further
getters" may actually be independently exported.

---

## 4. Test B, run for real: the native diagnostic on the local player

`kcdmp-playanim.txt` set to `player` / `CombatAttackSyncGen` / the real
halberd tag string (§9.2). Fired automatically at DLL attach on a genuine
fresh launch (confirmed by a new pid and fresh timestamps after several
false starts caused by a sandboxing issue in the coding environment — see
§7). `kcdmp-native.log`, verbatim:

```
PLAYANIM: target=player fragment="CombatAttackSyncGen" tags="l_halberd+r_halberd+clinch1+eZ1+aZ2+attack_special+oppMale"
PLAYANIM: actor = 0000021D486071A0 (unmapped/heap)
PLAYANIM: guard actor[+0x28]=0000021B4BD5AE28, vtbl[0x80]() = 1
PLAYANIM: actor vtbl[+0xE48] = 00007FFA2B0917A0 (EntityModule.dll+0xAE17A0)
PLAYANIM: call returned without a structured exception -- check in-game whether the fragment actually rendered a swing.
```

**Observed:** guard passed (`1`, non-zero — checkpoint 1 did not fire), the
vtable slot resolved to a real address inside `EntityModule.dll` itself
(checkpoint 2 did not fire), no crash. The human reported no visible change on
their own character — but this fires within ~1 second of DLL attach, before
control is typically gained, so this negative is weak evidence on its own.
The ghost-side live tests below are the load-bearing evidence; this result's
value is confirming the native call path itself (module/export resolution,
guard replication, vtable dispatch) works exactly as WO-42 traced it, endpoint
to endpoint, with zero fabrication.

## 5. Test A, run for real — and the real test method that emerged

**⚠ Superseded — see the correction at the top of this document.** The
console-argument bug and the `ExecuteString` workaround below are still real
and still true. The causal conclusion drawn from the three "swing" tests
(§5.1/§5.2) is not: none of them measured the guard, and a follow-up
session found it blocks on every ghost tested — meaning `vtbl[+0xE48]` never
ran in any of these three tests, and the pose described below was
`DrawWeapon()`'s alone.

**The console typing plan from earlier in this document did not work, for a
reason worth recording.** `mp_combat_frag <name> <tags>` and `mp_ghost_combat
<n>` both failed with `[Warning] Too many arguments for: <command>` the moment
*any* argument was typed at the in-game console — one word or several, it
didn't matter. Neither Lua handler (`KCD2MP_SetCombatFragment`,
`KCD2MP_GhostCombatAll`) ever ran; their own confirmation log lines were
absent from `kcd.log` entirely. A follow-up guess — that the console falls
back to raw Lua evaluation for an unrecognized command name — was also wrong:
typing the bare function call produced `[Warning] Unknown command:
KCD2MP_GhostCombatAll("0")`. **This looks like a real, reproducible bug in
how this project's `System.AddCCommand`-registered commands parse arguments
in the current build, independent of WO-43** — every other command in
`kdcmp.lua` that takes a `%LINE` argument (`mp_dice_wager`, `mp_dice_mark`,
`mp_anim_tag`, `mp_dice_scan`, …) is presumably affected the same way and is
worth a dedicated look outside this WO.

**What actually worked:** this project already ships a debug REST endpoint,
`http://localhost:1403/api/System/Console/ExecuteString?command=<urlencoded>`,
used by `tools/Lua-Driver.ps1` and a string of past WOs (21/22/24-27/30) to
send a raw Lua chunk straight into the game, completely bypassing the
console's own command parser. It is a plain localhost HTTP call, not a
sandboxed file path, so — unlike everything under `%LocalAppData%\KCDMP` —
it was directly reachable from the coding session's own shell (§7). From that
point on, Sonnet fired every test call itself; the human's only job was
watching the screen.

### 5.1 Three independent live tests, three independent confirmed-healthy ghosts

Each test used a **freshly spawned ghost, validated before testing** (name
resolves, `human` binding present, a real animation reports a nonzero
`GetAnimationLength`) — earlier attempts on a ghost that had been repeatedly
respawned/hostility-toggled in the same session turned out to be silently
corrupted (§6) and produced misleading nothing-happens results that had to be
thrown out.

| # | fragment | tags (real, from `Tables.pak`, never invented) | weapon match | ghost | result |
|---|---|---|---|---|---|
| 1 | `CombatAttackSyncGen` (sync-attack) | `l_halberd+r_halberd+clinch1+eZ1+aZ2+attack_special+oppMale` (WO-42 §9.2's own example row) | ghost had a longsword, not a halberd | `wo43fresh`→ first hostile-AI confound, then a validated respawn | **drew sword, visible but janky/broken swing attempt** (screenshot: frozen mid-motion, sword low, off arm raised) |
| 2 | `CombatAttackSyncGen` (sync-attack) | `l_longsword+r_longsword+clinch1+eZ2+aZ2+slash+attack_heavy+step1+oppMale` — pulled fresh from `Tables.pak` (`combat_action_sync_attack.xml`) specifically to match this ghost's actual weapon | matched | `wo43fresh2`, freshly validated, male, real longsword animation set confirmed present | **same result: drew sword, same janky/broken swing attempt** |
| 3 | `FreeAttack` (**unpaired** — not a sync-attack, so WO-42 §5.1's pairing mechanism cannot be the explanation) | `l_longsword+r_longsword+freeGuard+endFreeGuard+slash+attack_heavy` — real row, pulled fresh from `combat_action_attack.xml` | matched | `wo43fresh4`, freshly validated, male, real longsword animation set confirmed present (never had anything else attempted on it first) | **same result again: drew sword, same janky/broken swing attempt** |

Screenshot from test 3 (representative of all three): the ghost stands with
its longsword held low at an odd angle, off hand raised near the chest — a
frozen, partial pose, not a completed swing and not the character's normal
idle stance either. Visibly different from doing nothing.

### 5.2 What this rules out, one at a time

- **Not bad tag data.** Test 1 used exactly the one verbatim real row WO-42's
  findings supplied; tests 2–3 used two more real rows pulled directly from
  the shipped tables specifically to fix the weapon mismatch test 1 had. All
  three: identical outcome.
- **Not a weapon/tag mismatch.** Test 1's tags named a halberd the ghost
  didn't have; tests 2–3 matched the ghost's actual longsword exactly (its
  longsword-specific animation set was confirmed present by nonzero
  `GetAnimationLength` before testing). Same outcome regardless.
- **Not sync-attack pairing (WO-42 §5.1/§5.3).** Test 3 used `FreeAttack`, an
  **unpaired** fragment with no sync-partner mechanism to be missing. Same
  broken pose anyway — pairing is not the explanation.
- **Not a corrupted/stuck ghost, for tests 2 and 3 specifically.** Both ran on
  a ghost spawned under a brand-new id, validated healthy immediately
  beforehand, with no prior combat fragment ever attempted on it. (Test 1's
  first attempt *did* hit ghost corruption and hostile-AI confounds along the
  way — see §6 — which is exactly why tests 2 and 3 were designed to control
  for it.)
- **Not the guard or the wrong vtable** — already ruled out independently by
  §4's native diagnostic on the player: guard passed, target address resolved
  inside `EntityModule.dll`, no fault.

**What's left, consistently, three times over:** the call does something real
and visible, reaches partway into a swing pose, and never completes it. Per
the session brief's own framing, a call that "does something unexpected — not
just 'does nothing,' but visibly wrong" is the one outcome that calls for a
fresh model on unfamiliar native-code ground rather than continued guessing
here. The specific native function this points at —
`EntityModule.dll+0xAE17A0`, the concrete implementation
`C_Actor` vtable slot `+0xE48` resolves to — was never decompiled by WO-42;
only the *calling* code (`C_ScriptBindHuman::PlayAnim`, resolving the slot)
was traced. **This document does not open a disassembler to go further, per
this session's own instructions — that decompilation is the natural next
step, and it belongs to whoever picks up Phase 2.**

---

## 6. Two things that ate a lot of round-trips, worth recording precisely

**Ghost respawn corruption under a reused id.** Every time `mp_spawn_test`
(id `"test_ghost"`) or a manual `KCD2MP_SpawnGhost` call reused an id that
already had a ghost tracked under it, the log showed:
```
[KCD2-MP] RemoveEntity ghost <id> STILL ALIVE after 4 passes
```
— twice per respawn (once for the tracked ghost, once for the "untracked
entity already named" cleanup `SpawnGhost` itself attempts) — followed by
clothing/weapon-assignment errors (`insufficient strength/agility for
<weapon>`) and, in the worst case, a completely un-named entity
(`GetName()` returning `nil`, `ApplyName ok1=false ok2=false`) with **every**
animation, including ones with nothing to do with combat (`relaxed_jump_start`,
previously confirmed live in WO-40), reporting `GetAnimationLength() == 0`. A
ghost in this state is not usable for *any* animation test, and the failure
looks identical to "nothing renders" from the outside. **Spawning under a
brand-new, never-before-used id sidesteps it entirely** — every ghost in the
table above that got a fresh id spawned clean on the first try. This is a
real bug worth a look outside WO-43; it was not investigated further here
because it wasn't this WO's target.

**The console argument-parsing bug (§5)** is the other one — both are
flagged rather than fixed, since neither is combat-swing fidelity itself.

---

## 7. How this session actually ran, for future reference

The coding environment's `%LocalAppData%\KCDMP` is sandboxed (per this
project's own `appdata-sandbox-redirection` note) — every read of
`kcdmp-native.log` at that path early in this session silently returned a
frozen first-read snapshot, which produced several rounds of "this looks
stale" that were actually a tooling artifact, not evidence about the game.
The fix that unblocked everything: `D:\SteamLibrary\steamapps\common\KCD2Mod\
kcd.log` (the game's own log, inside the Steam library, not AppData) and
`localhost:1403`'s debug REST API are **both directly reachable from the
coding shell, unsandboxed** — once discovered, Sonnet could read the game's
real-time log and drive live Lua tests directly, with the human needed only
for the one thing that can't be scripted: watching the result on screen. This
is worth remembering for any future live-testing session on this project.

---

## 8. Regression check (explicit, per the session brief)

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

## 9. Phase 2 — handoff

Per the session brief, Phase 2 is reachable once Phase 1 has a genuine
result — success or a real, observed failure. §4-5 delivered the latter: a
real, three-times-reproduced, well-characterized partial failure, not a
guess and not a shrug. Per the brief's own explicit routing, this is the
condition for handing off to a fresh Fable 5 session rather than continuing
here — the specific open question (what does
`EntityModule.dll+0xAE17A0` actually build/queue that produces a stuck
partial pose for every fragment tried) needs disassembly, which this session
was explicitly told not to open, and needs the kind of ground-up native
reconstruction work the brief itself flags as Fable's territory rather than
Sonnet's.

**What Phase 2 inherits, concretely:**

- Rung 1 (this WO's target — the bare `PlayAnim`/vtbl `+0xE48` call) is now
  **closed**: it reliably produces a visible-but-broken partial pose, for any
  real combat fragment, paired or unpaired, weapon-matched or not. Not worth
  re-attempting as-is.
- The natural next step is rung 2/3 from `docs/WO-42-findings.md` §4-5: the
  full `C_CombatAnimAction`/`C_CombatActorActionAttack` (or
  `SyncAttack`+`SyncHit` pair) construction sequence, which builds and queues
  a real combat action object rather than calling the high-level `PlayAnim`
  wrapper — a completely different code path from the one this WO tested and
  ruled out.
- Alternatively, decompiling `EntityModule.dll+0xAE17A0` itself (the actual
  `vtbl+0xE48` target, never yet traced) might reveal *why* the bare call
  stalls partway — e.g. a missing precondition it silently no-ops on, in
  which case rung 1 might still be salvageable with one more native call
  before it. Either angle is legitimate; neither should be guessed at without
  reading the function.
- The live-testing method from §5 (drive the game directly via
  `localhost:1403`'s `ExecuteString` debug API from the coding shell, read
  `kcd.log` directly, spawn ghosts under fresh ids) works well and is
  reusable for verifying whatever Phase 2 builds, once the human is at the
  machine with the game running.
- The two orthogonal bugs in §6 (console argument parsing, ghost-respawn
  corruption) are real but out of scope for Phase 2 too; flagging them again
  here so they aren't lost.
