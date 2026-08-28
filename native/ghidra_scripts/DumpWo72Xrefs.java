// WO-72: list write references to a data address, with the containing function.
// Usage: -postScript DumpWo72Xrefs.java <outFile> <addr>...
// @category KCD2
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import java.io.*;

public class DumpWo72Xrefs extends GhidraScript {
    @Override public void run() throws Exception {
        String[] a = getScriptArgs();
        PrintWriter pw = new PrintWriter(new FileWriter(new File(a[0]), true));
        ReferenceManager rm = currentProgram.getReferenceManager();
        for (int i = 1; i < a.length; i++) {
            Address ad = currentProgram.getAddressFactory().getAddress(a[i]);
            pw.println("\n##### refs to " + ad + " in " + currentProgram.getName());
            for (Reference r : rm.getReferencesTo(ad)) {
                Function f = getFunctionContaining(r.getFromAddress());
                Instruction ins = getInstructionAt(r.getFromAddress());
                pw.println("  " + r.getFromAddress() + "  " + r.getReferenceType()
                    + "  " + (ins == null ? "<data>" : ins.toString())
                    + "   fn=" + (f == null ? "-" : f.getName() + "@" + f.getEntryPoint()));
            }
        }
        pw.close(); println("DumpWo72Xrefs done");
    }
}
