// WO-97: print every reference to a data address and decompile the referencing
// functions. Used to recover the value of a runtime-constructed global -- the
// C_ConceptPath tokenizer's separator string, which lives in .data and is
// therefore not readable from the file image.
//
// Read-only.  Usage: -postScript DumpWo97Refs.java <outFile> <addr> [<addr> ...]
// @category KCD2
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.*;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Reference;
import java.io.*;
import java.util.*;

public class DumpWo97Refs extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        PrintWriter pw = new PrintWriter(new FileWriter(a[0], true));
        DecompInterface di = new DecompInterface();
        di.openProgram(currentProgram);
        for (int i = 1; i < a.length; i++) {
            Address target = toAddr(a[i]);
            pw.println("######################################################");
            pw.println("### references to " + target);
            Set<Function> seen = new LinkedHashSet<>();
            for (Reference r : getReferencesTo(target)) {
                Function f = getFunctionContaining(r.getFromAddress());
                pw.println("   from " + r.getFromAddress() + "  " + r.getReferenceType()
                    + "  in " + (f == null ? "(no function)" : f.getName(true) + " @" + f.getEntryPoint()));
                if (f != null) seen.add(f);
            }
            for (Function f : seen) {
                pw.println("---- " + f.getName(true) + " @" + f.getEntryPoint() + " ----");
                DecompileResults res = di.decompileFunction(f, 90, monitor);
                if (res != null && res.getDecompiledFunction() != null) pw.println(res.getDecompiledFunction().getC());
                else pw.println("   (decompile failed)");
            }
        }
        di.dispose();
        pw.close();
        println("DumpWo97Refs done");
    }
}
