// WO-6 R2: decompile rttr::type::get_methods / get_properties (and a few
// neighbors) to recover array_range<T>'s real layout from how these
// functions fill in their hidden sret return buffer. Read-only analysis of
// a static file copy; touches nothing running.
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolTable;
import ghidra.program.model.symbol.SymbolIterator;
import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.List;

public class DumpArrayRangeFuncs extends GhidraScript {
    @Override
    public void run() throws Exception {
        String outPath = getScriptArgs().length > 0 ? getScriptArgs()[0]
            : "C:\\Users\\Jonasty\\AppData\\Local\\Temp\\claude\\C--Users-Jonasty-Documents-KCD2-MP\\c71496b2-fa59-470a-86de-1505de001485\\scratchpad\\array_range_decompiled.txt";
        PrintWriter out = new PrintWriter(outPath, "UTF-8");

        String[] needles = {
            "get_methods", "get_properties", "array_range", "method_wrapper",
            "SetPauseWorldTime"
        };

        SymbolTable st = currentProgram.getSymbolTable();
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
