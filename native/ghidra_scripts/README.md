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
