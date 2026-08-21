// WO-42: list callers (and their names) of given addresses, so a constructor
// can be traced back to the allocation site that decides sizeof and to the
// code that decides what gets paired with what.
//
// Usage: -postScript DumpWo42Callers.java <outFile> <addr> [<addr> ...]
// @category KCD2
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import java.io.*;

public class DumpWo42Callers extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        PrintWriter pw = new PrintWriter(new FileWriter(a[0], true));
        ReferenceManager rm = currentProgram.getReferenceManager();
        for (int i = 1; i < a.length; i++) {
            Address t = toAddr(a[i]);
            Function tf = getFunctionContaining(t);
            pw.println("##### callers of " + a[i]
                     + (tf == null ? "" : " (" + tf.getName() + ")"));
            for (Reference r : rm.getReferencesTo(t)) {
                Function f = getFunctionContaining(r.getFromAddress());
                pw.println("   " + r.getFromAddress() + " " + r.getReferenceType()
                         + "  in " + (f == null ? "<data>"
                              : f.getName() + " @ " + f.getEntryPoint()
                                + " size=" + f.getBody().getNumAddresses()));
            }
            pw.println();
        }
        pw.close();
        println("DumpWo42Callers done");
    }
}
