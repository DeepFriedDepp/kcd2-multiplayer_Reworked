// WO-96: decompile the functions at the given addresses and append the C to
// <outFile>, with the function's symbol and prototype first. Used to settle
// the calling convention / argument shape of ConceptModule.dll's exported
// read surface (FindNode / GetPort / Read) statically, before any live call.
//
// Usage: -postScript DumpWo96Decompile.java <outFile> <addr> [<addr> ...]
// @category KCD2
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.*;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import java.io.*;
public class DumpWo96Decompile extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        PrintWriter pw = new PrintWriter(new FileWriter(a[0], true));
        DecompInterface di = new DecompInterface();
        di.openProgram(currentProgram);
        for (int i = 1; i < a.length; i++) {
            Address addr = toAddr(a[i]);
            Function f = getFunctionContaining(addr);
            if (f == null) { pw.println("== " + a[i] + ": no function"); continue; }
            pw.println("== " + a[i] + " " + f.getName(true));
            pw.println("   entry=" + f.getEntryPoint() + " proto=" + f.getPrototypeString(true, true)
                + " cc=" + f.getCallingConventionName() + " params=" + f.getParameterCount());
            DecompileResults r = di.decompileFunction(f, 60, monitor);
            if (r != null && r.getDecompiledFunction() != null) pw.println(r.getDecompiledFunction().getC());
            else pw.println("   (decompile failed: " + (r == null ? "null" : r.getErrorMessage()) + ")");
            pw.println();
        }
        di.dispose();
        pw.close();
        println("DumpWo96Decompile done");
    }
}
