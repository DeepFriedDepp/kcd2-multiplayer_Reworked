// WO-42: decompile named addresses (plus each function's direct callees, so a
// construction sequence can be followed one level down without another round
// trip).
//
// Usage: -postScript DumpWo42Fns.java <outFile> <depth> <addr> [<addr> ...]
// @category KCD2
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.*;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.*;
import java.io.*;
import java.util.*;

public class DumpWo42Fns extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        int depth = Integer.parseInt(a[1]);
        LinkedHashSet<Function> set = new LinkedHashSet<>();
        List<Function> frontier = new ArrayList<>();
        for (int i = 2; i < a.length; i++) {
            Function f = getFunctionContaining(toAddr(a[i]));
            if (f == null) { println("no function at " + a[i]); continue; }
            if (set.add(f)) frontier.add(f);
        }
        for (int d = 0; d < depth; d++) {
            List<Function> next = new ArrayList<>();
            for (Function f : frontier)
                for (Function c : f.getCalledFunctions(monitor))
                    if (set.add(c)) next.add(c);
            frontier = next;
        }
        DecompInterface dec = new DecompInterface();
        dec.setOptions(new DecompileOptions());
        dec.openProgram(currentProgram);
        PrintWriter pw = new PrintWriter(new FileWriter(a[0], true));
        for (Function f : set) {
            if (monitor.isCancelled()) break;
            pw.println("//======================================================");
            pw.println("// " + f.getName(true) + "  entry=" + f.getEntryPoint()
                     + " size=" + f.getBody().getNumAddresses()
                     + " cc=" + f.getCallingConventionName());
            DecompileResults r = dec.decompileFunction(f, 180, monitor);
            pw.println(r != null && r.decompileCompleted()
                       ? r.getDecompiledFunction().getC()
                       : "// DECOMPILE FAILED " + (r == null ? "" : r.getErrorMessage()));
        }
        pw.close();
        dec.dispose();
        println("DumpWo42Fns wrote " + set.size() + " functions");
    }
}
