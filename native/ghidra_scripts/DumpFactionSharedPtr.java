// WO-15 continuation: recover the real shared_ptr<C_Faction> refcounting
// behaviour used by RPGModule.dll, so SetParent can be called with a
// genuinely owned copy instead of a borrowed reference into RTTR's own
// variant storage (the bug that corrupted the faction tree and crashed the
// game once already -- see the disabled block in native/KCDMP/rttr_abi.cpp).
//
// Targets, by name substring, in the currently-processed program:
//   - SetParent      : shows how the by-value shared_ptr parameter is
//                       consumed/destroyed at the end of the call -- the
//                       decrement side.
//   - GetFaction     : returns shared_ptr<C_Faction> by value from a stored
//                       map entry -- shows the construct/increment side.
//   - GetRelation    : another shared_ptr-returning/consuming faction method,
//                       kept as a second data point if the above are thin.
//
// Read-only: operates on a static, already-imported copy of the DLL, never
// touches a running process.
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.List;

public class DumpFactionSharedPtr extends GhidraScript {
    @Override
    public void run() throws Exception {
        String outPath = getScriptArgs().length > 0 ? getScriptArgs()[0]
            : "C:\\Users\\Jonasty\\AppData\\Local\\Temp\\claude\\C--Users-Jonasty-Documents-KCD2-MP\\f1286127-ee8c-452a-95b3-954d5baa1b64\\scratchpad\\faction_sharedptr_decompiled.txt";
        PrintWriter out = new PrintWriter(outPath, "UTF-8");

        String[] needles = {
            "SetParent", "GetFaction", "GetRelation", "C_FactionBase", "C_FactionManager"
        };

        List<Function> targets = new ArrayList<>();
        FunctionManager fm = currentProgram.getFunctionManager();
        for (Function f : fm.getFunctions(true)) {
            String name = f.getName();
            for (String n : needles) {
                if (name.contains(n)) { targets.add(f); break; }
            }
        }

        out.println("Found " + targets.size() + " candidate functions.\n");

        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        for (Function f : targets) {
            out.println("=====================================================");
            out.println("FUNCTION: " + f.getName() + " @ " + f.getEntryPoint());
            out.println("SIGNATURE: " + f.getSignature());
            out.println("=====================================================");
            DecompileResults res = decomp.decompileFunction(f, 60, monitor);
            if (res != null && res.decompileCompleted()) {
                out.println(res.getDecompiledFunction().getC());
            } else {
                out.println("(decompile failed: " +
                    (res != null ? res.getErrorMessage() : "null result") + ")");
            }
            out.println();
        }

        decomp.dispose();
        out.close();
        println("Wrote " + targets.size() + " functions to " + outPath);
    }
}
