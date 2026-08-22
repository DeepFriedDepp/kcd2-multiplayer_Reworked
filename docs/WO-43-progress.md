# WO-43 progress

Worked 2026-08-21/22 (Sonnet). No disassembler opened. `docs/WO-43-findings.md`
is the deliverable — read that for the full evidence chain; this is the
session log.

**⚠ Correction added same day, one session later:** this WO's own Gate 1
verdict was wrong. The "reproducible partial swing" was `DrawWeapon()`'s own
pose, not `PlayAnim`'s — the guard blocks on every ghost tested, so
`vtbl[+0xE48]` never actually ran in any of the three tests below. Full
correction in `docs/WO-43-findings.md`'s own correction section, written
during a live-testing follow-up session (same day) that added a native probe
watcher and re-measured the guard directly instead of inferring it from
Lua's `pcall`.

## Part 1 — implementation (no game access)

1. Read `docs/WO-42-findings.md` §9.5/§9.6 (the direct-call route), §9.2 (real
   shipped fragment/tag data), §4-5 (the Phase 2 fallback), and
   `docs/WO-40-findings.md` (the three already-closed scripting-layer
   attempts).
2. Confirmed via search that `native/KCDMP/*.cpp,*.h` had zero prior
   `C_Actor`/`EntityModule` code — every existing capability is RTTR-by-name.
3. Found that `ghost.entity.human:PlayAnim(...)` in `kdcmp.lua` is, per WO-42
   §9.6, the identical native call this WO's Phase 1 asks for.
4. Implemented `native/KCDMP/combat_playanim.cpp` (resolve `C_Actor*`, replicate
   the guard, call `vtbl[+0xE48]`, log every step), wired into `dllmain.cpp`
   and `CMakeLists.txt`. Fixed one MSVC C2712 (`__try` vs. `std::vector` in the
   same frame). Built clean.
5. Added `mp_entity_id` to `kdcmp.lua` and documented the real §9.2 fragment
   row next to `KCD2MP.combatSwingFragment`, both additive, no default changed.
6. `dotnet build`/`dotnet test` clean (0 errors, 59/59 Farkle tests).
7. Cut and installed `VERSION` 0.15.0 at the user's explicit request, carrying
   this work (see `docs/VERSIONING.md`).

## Part 2 — live testing (with the human at the machine)

This took far more back-and-forth than expected, almost all of it resolved,
in order:

1. **Console-typed commands never ran.** `mp_combat_frag`/`mp_ghost_combat`
   with any argument hit `[Warning] Too many arguments for: <command>` at the
   game's own console, silently no-opping — confirmed by the total absence of
   either Lua handler's own confirmation log line. A guessed workaround (typing
   the raw Lua call directly) also failed (`Unknown command`).
2. **A real fix:** this project already ships a debug REST endpoint
   (`localhost:1403/api/System/Console/ExecuteString`, used by
   `tools/Lua-Driver.ps1` since WO-21) that sends raw Lua straight into the
   game, bypassing the console parser entirely. It's a plain localhost HTTP
   call — reachable directly from the coding shell. From here on, Sonnet drove
   every test call itself; the human only had to watch and describe.
3. **A tooling trap on the reading side, too:** `%LocalAppData%\KCDMP` is
   sandboxed for the coding shell (per the `appdata-sandbox-redirection`
   memory) — several rounds of "the log looks stale" were the coding
   environment reading a frozen snapshot, not the game. Fixed by reading
   `kcd.log` directly from the Steam library path instead (not sandboxed).
4. **Native diagnostic result (local player, real halberd data):** guard
   passed (`1`), vtable resolved inside `EntityModule.dll`, no fault. Confirms
   the traced mechanism runs end-to-end exactly as WO-42 described.
5. **Three independent live ghost tests**, each on a freshly spawned and
   validated ghost, using three different real (never invented) fragment/tag
   rows pulled from the shipped `Tables.pak` (one via WO-42's own example, two
   pulled fresh this session to fix a weapon mismatch the first test revealed):
   all three produced the **same visible-but-broken partial swing pose** —
   sword drawn, character reaches toward a swing, never completes it.
6. Systematically ruled out: bad tag data, weapon/tag mismatch, sync-attack
   pairing (tested an unpaired `FreeAttack` fragment too — same result), and a
   stuck/corrupted ghost (two of the three tests used a ghost with no prior
   combat fragment ever attempted on it).
7. Found and recorded, as a side effect rather than the goal: a real ghost
   respawn corruption bug (reusing a ghost id after removal leaves the world in
   a broken state — `RemoveEntity ... STILL ALIVE after 4 passes`, then failed
   clothing/weapon/name assignment) that produces false "nothing renders"
   results and is worth its own look outside this WO.

## Gate 1

**Blocked by something else entirely — a real, reproducible partial render,
not a guard block or a crash.** Three independent confirmations, each ruling
out a different alternative explanation. This is the specific outcome the
session brief names as the trigger for a Fable handoff rather than continued
Sonnet iteration: the call does something visibly wrong (a stuck partial
pose), not just nothing.

## Handoff

Rung 1 (bare `PlayAnim`/`vtbl+0xE48`) is closed — not worth re-attempting as
built. Phase 2 (or a decompile of `EntityModule.dll+0xAE17A0`, the actual
`vtbl+0xE48` target, never yet traced by WO-42) is the next step, and per the
session brief that's a fresh Fable 5 session's job, not a continuation here.
`docs/WO-43-findings.md` §9 has the full handoff detail.
