# Ghidra headless pipeline (WO-6 R2)

Set up 2026-07-28 to recover `rttr::array_range<T>`'s real ABI by
decompilation instead of guessing, the same discipline
`NATIVE-PLUGIN-findings.md` used for `variant`/`argument`/`instance`, just
with a real disassembler instead of `dumpbin`.

**Installed locally, not part of this repo:** Ghidra 12.1.2 (official NSA
release) and Eclipse Temurin JDK 21 (Ghidra needs 17+; this machine only had
Java 8 on PATH otherwise). Both are large binary installs — reinstall from
their official sources if a future session needs this again.

## Running it

```powershell
$env:JAVA_HOME = "C:\Program Files\Eclipse Adoptium\jdk-21.0.11.10-hotspot"
$ghidra = "<path to extracted ghidra_12.1.2_PUBLIC>"
$proj   = "<a scratch directory>"

# One-time per DLL: import + full auto-analysis (~3-4 min for a DLL in the
# 6-10 MB range; scales with size).
& "$ghidra\support\analyzeHeadless.bat" $proj kcd2 `
    -import "D:\SteamLibrary\steamapps\common\KCD2Mod\Bin\Win64ReleaseSteamLTO_DLL\CrySystem.dll" `
    -analysisTimeoutPerFile 1800

# Re-run scripts against an already-imported file without re-analyzing:
& "$ghidra\support\analyzeHeadless.bat" $proj kcd2 `
    -process "CrySystem.dll" -noanalysis `
    -scriptPath "native\ghidra_scripts" `
    -postScript DumpArrayRangeFuncs.java
```

`-analysisTimeoutPerFile` (not `-analysisTimeout`) is the correct flag name
— the headless analyzer silently misparses the wrong one as another
positional import path rather than erroring clearly.

## `DumpArrayRangeFuncs.java`

Finds every function in the currently-processed program whose name contains
one of a small needle list (`get_methods`, `get_properties`, `array_range`,
`method_wrapper`, `SetPauseWorldTime` — edit the `needles` array for a
different target) and decompiles each to a text file. Read-only: operates on
a static, already-imported copy of the DLL, never touches a running process.

Pass an output path as the script's first argument, or it defaults to a
scratch-directory path baked in from this session — change that literal
before reusing.

## What this already answered

See `docs/WO-6-native-dice-findings.md` §"Ghidra brought in..." — this
pipeline is what recovered `array_range<T>`'s `{begin,end}` pointer-pair
layout (used in `native/KCDMP/rttr_abi.h`/`.cpp`,
`probe_dice_class()`) and is the tool to reach for if a future session wants
to decompile `C_UIDice::ShowDiceScore`'s caller — the next concrete lead
recorded in the findings doc.

---

# WO-42 additions (2026-08-21)

Five scripts added while reverse-engineering the native combat-animation route
(`docs/WO-42-findings.md`). Ghidra **12.1.3** was used; the flags above are
unchanged.

The key discovery that shapes all of them: the Modding Tools build **retains
`__FUNCTION__` strings, source paths and MSVC RTTI**. So identification is not
pattern matching — a function containing the literal
`"wh::animationmodule::C_AnimationController::QueueAction"` *is* that function.

- **`DumpWo42Anchors.java <outDir> <needle>...`** — the workhorse. For every
  defined string containing a needle, prints the string, every xref, and the
  containing function; also matches symbol names (so RTTI vftable labels get
  picked up with their referencing constructors/destructors); then decompiles
  every function it landed on. This is what turned six class names into an
  address map.
- **`DumpWo42Fns.java <outFile> <depth> <addr>...`** — decompile addresses, plus
  their callees to `<depth>` levels.
- **`DumpWo42Asm.java <outFile> <addr>...`** — raw disassembly of the containing
  function, with string/symbol comments resolved on each instruction.
  **Use this, not the decompiler, for anything ABI-shaped.** The decompiler's
  "unknown calling convention" guesses dropped three of `C_CombatAnimAction`'s
  seven arguments and hid a `float` parameter riding in XMM2.
- **`DumpWo42Callers.java <outFile> <addr>...`** — callers of an address. Finds
  factories from constructors, and `sizeof` from the allocation immediately
  before the constructor call.
- **`DumpWo42Vtbl.java <outFile> <count> <addr>...`** — vtable slots with
  resolved targets. Beware: `.pdata`/EH regions are packed 32-bit RVA triples
  and will decode as nonsense here — if the "pointers" look like two small
  values glued together, it is not a vtable.

---

# WO-71 additions (2026-08-27)

Three read-only scripts written while reversing renderer initialization
(`docs/WO-71-findings.md`). Ghidra **12.1.3**.

- **`DumpWo71GenvFlag.java <outFile> <hexOffset>...`** — the workhorse for
  "who reads this `gEnv` flag". Finds every instruction with a memory operand
  at one of the given displacements, walks backwards for the
  `MOV base,[global]` that loaded the base register, and reports
  address / offset / read-or-write / base / global / containing function, plus
  a tally of globals so `gEnv` self-identifies as the most-hit one.
  **Read the `global=` column** — stack frames hit the same displacements
  (`CryPhysics.dll`'s `MOVSS [RBP+0x3d4]` spills are not `gEnv`).
- **`DumpWo71FnStrings.java <outFile> <addr>...`** — names a function cheaply:
  for each address, the containing function plus every string literal it
  references. With `__FUNCTION__` and source paths compiled in (WO-42) this
  identifies a function without decompiling it.
- **`DumpWo71Range.java <outFile> <start> <end> [<start> <end>...]`** — raw
  disassembly of an address window with string/symbol comments resolved. Use
  for flag reads/writes where the decompiler's `undefined1 *` casts obscure
  which byte is actually touched.

Operational notes learned the hard way:

- Import paths must use **forward slashes** from a POSIX shell. A
  backslash-joined path collapses into one malformed argument and
  `analyzeHeadless.bat` then blocks on `Press any key to continue`, so a
  backgrounded batch dies with no useful error.
- A Ghidra **project** is locked for the duration of a headless job. Parallel
  imports need one project directory per concurrent job.
