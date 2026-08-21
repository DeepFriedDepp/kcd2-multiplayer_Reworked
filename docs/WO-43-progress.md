# WO-43 progress

Worked 2026-08-21 (Sonnet). No disassembler opened. Game never launched this
session (sandboxed AppData — see [[appdata-sandbox-redirection]]). Deliverable
is `docs/WO-43-findings.md`.

## What was done, in order

1. Read `docs/WO-42-findings.md` §9.5/§9.6 (the direct-call route), §9.2 (real
   shipped fragment/tag data), §4-5 (the Phase 2 fallback construction
   sequence), and `docs/WO-40-findings.md` (the three already-closed
   scripting-layer attempts).
2. Searched `native/KCDMP/*.cpp,*.h` for any existing `C_Actor`/`EntityModule`
   resolution code (as instructed, before assuming new plumbing was needed):
   none exists. Every existing native capability is RTTR-by-name. Confirmed
   this is genuinely new territory for the DLL.
3. Found, by reading `kdcmp.lua`'s existing combat-visibility code
   (`KCD2MP_GhostCombat`, `mp_combat_frag`), that the Lua path
   `ghost.entity.human:PlayAnim(fragment, tags)` is — per WO-42 §9.6's own
   trace — bit-for-bit the same native call WO-43's Phase 1 asks for. It was
   already eyeball-confirmed live (2026-08-20, `MotionJump`) to render on a
   ghost, and already tried (and failed) on combat fragments — but every one
   of those attempts used placeholder tag data, never a real Tables.pak row.
   This reframed what was actually untested.
4. Implemented `native/KCDMP/combat_playanim.cpp`: resolves a `C_Actor*` (local
   player via the fully-verbatim `GetPlayerActor` export, or an arbitrary
   actor via `GetScriptBindHuman` [resolved by prefix — the one genuine gap,
   see findings §3] + `FUN_180B3C2D0`), replicates the `actor[+0x28]->
   vtbl[0x80]()` guard with logging, and calls `actor->vtbl[0xE48](actor,
   fragment, tags)` through the object's own vtable. Opt-in via
   `kcdmp-playanim.txt`, matching the `kcdmp-faction.txt` precedent.
5. Wired it into `dllmain.cpp`'s existing startup sequence (next to
   `probe_faction()`) and `CMakeLists.txt`. Hit one compile error (MSVC C2712:
   `__try` can't share a frame with a `std::vector` local) and fixed it by
   moving every SEH-guarded call into its own tiny helper, matching the
   pattern `rttr_abi.cpp` already uses for the same reason.
6. Built clean: `native/Build-Native.ps1` → `KCDMP.dll`, 282,624 bytes, 0
   errors.
7. Added `mp_entity_id [name]` to `kdcmp.lua` (prints an entity's raw
   CryEngine id — needed to fill in `kcdmp-playanim.txt` for the arbitrary-
   actor case) and a comment documenting the real §9.2 fragment/tag row next
   to `KCD2MP.combatSwingFragment` for a zero-new-code live test of the same
   hypothesis via the already-shipped `mp_combat_frag` command. Neither
   changes any existing default.
8. Ran what could be run without the game: `dotnet build KCD2-MP.sln` (0
   errors) and `dotnet test dotnet/KcdMp.Farkle.Tests` (59/59 passed). The
   `Test-*E2E.ps1` suites need the live game and were not run.

## Gate 1

**Inconclusive — by construction, not by evasion.** Both a native diagnostic
and a corrected real-data test of the existing Lua path are built and ready;
neither has been watched run. `docs/WO-43-findings.md` §4-5 is a literal run
sheet for the human, with a table mapping every possible log/game outcome to
what it would mean and what to do next (including exactly which single
outcome — the vtable call itself faulting — is the one that should go to
Fable rather than continue with Sonnet).

## Handoff

Not proceeding to Phase 2. Per the session brief, Phase 2 needs a real Phase 1
result (success or observed failure) to react to, and this session has
neither yet. Next: the human runs `docs/WO-43-findings.md` §4's two tests and
reports back what `kcdmp-native.log` and the actual fight showed.
