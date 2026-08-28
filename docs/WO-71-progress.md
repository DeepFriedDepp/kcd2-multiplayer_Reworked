# WO-71 progress — does a headless path survive in our renderer init?

Session 2026-08-27. Investigation only: **no product code changed**. Two new
read-only Ghidra scripts were added under `native/ghidra_scripts/` (tooling,
not product); everything else is documentation.

## What was done

1. **Phase 0 — record + target map.** Read `docs/WO-53-findings.md` in full and
   stated the delta precisely (WO-53 settled "no shipped headless *surface*";
   this WO tests "no surviving headless *branch*"). Inventoried the renderer
   surface of the Modding Tools install and swept CrySystem / CryRenderD3D12 /
   KingdomCome.exe / WHGame / TestModule for branch-stump vocabulary, recording
   module + byte offset for every hit.
2. **Phase 1 — reversed the init.** Imported the Modding Tools binaries into
   Ghidra 12.1.3 headless (CrySystem, KingdomCome.exe, CryRenderD3D12, WHGame,
   CryAction, Cry3DEngine, CryInput, CryFont, CrySoundSystem, CryScriptSystem,
   CryNetwork, CryEntitySystem, CryMovie, CryPhysics, CryAnimation, CryAISystem,
   GUIModule, Framework, TestModule), located `CSystem::Init` /
   `CSystem::InitRenderer` / `CSystem::OpenRenderLibrary`, and walked forward to
   window + device creation in `CD3D9Renderer::Init`.
3. Worked **backwards** from renderer creation and graded every guard, with
   writers and readers, at both decompile and disassembly level.
4. Measured **breadth of readers** for the winning flag across all 45 shipped
   modules (byte-pattern census) and confirmed the census against Ghidra
   xref data in ten modules.
5. Checked the compiled-in test module for an init-param/renderer test that
   would give a free field map — **none exists** (see findings §5).

## Tooling added (read-only, static)

- `native/ghidra_scripts/DumpWo71GenvFlag.java` — finds every read/write of a
  fixed byte offset off a global pointer, recovers which global the base
  register came from, and tallies globals so `gEnv` self-identifies.
- `native/ghidra_scripts/DumpWo71FnStrings.java` — names a function cheaply by
  listing the string literals it references (these builds keep `__FUNCTION__`
  and source paths, WO-42).
- `native/ghidra_scripts/DumpWo71Range.java` — raw disassembly of an address
  window with string/symbol comments resolved, for ABI-shaped checks.

## Traps hit

- `analyzeHeadless.bat` needs forward-slash import paths from this shell; a
  backslash-joined path silently became one malformed argument and the batch
  file then blocked on `Press any key to continue`, so five parallel imports
  died without an obvious error in the task summary.
- A Ghidra *project* is locked while any headless job runs against it, so
  parallel work needs one project per concurrent job, not one project shared.
- The generic offset scanner reports stack-frame accesses at the same
  displacement (`base=RBP`, no global) — `CryPhysics.dll`'s hits are all
  `MOVSS [RBP+0x3d4]` float spills, not `gEnv`. Always read the `global=`
  column before counting a module as a reader.

## Phase 2

Not run. Phase 2 is gated on the human approving a specific flip after seeing
the branch map; the branch map is `docs/WO-71-findings.md` §3–§4. See the
findings doc's verdict and the "what a decision session would weigh"
paragraph.
