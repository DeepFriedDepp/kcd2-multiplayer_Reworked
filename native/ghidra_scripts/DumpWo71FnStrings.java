// WO-71: identify functions cheaply — for each address, print the containing
// function and every string literal it references (Warhorse builds keep
// __FUNCTION__ names and source paths, so this names the function).
// Usage: -postScript DumpWo71FnStrings.java <outFile> <addr> [<addr> ...]
// @category KCD2
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import java.io.*;
import java.util.*;

public class DumpWo71FnStrings extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        PrintWriter pw = new PrintWriter(new FileWriter(new File(a[0]), true));
        pw.println("\n##### " + currentProgram.getName());
        for (int i = 1; i < a.length; i++) {
            Address ad = currentProgram.getAddressFactory().getAddress(a[i]);
            Function f = getFunctionContaining(ad);
            if (f == null) { pw.println("\n== " + a[i] + " : <no function>"); continue; }
            pw.println("\n== " + a[i] + " fn=" + f.getName() + "@" + f.getEntryPoint()
                     + " size=" + f.getBody().getNumAddresses());
            Set<String> strs = new LinkedHashSet<>();
            InstructionIterator it = currentProgram.getListing().getInstructions(f.getBody(), true);
            while (it.hasNext()) {
                for (Reference r : it.next().getReferencesFrom()) {
                    if (!r.getReferenceType().isData()) continue;
                    Data d = getDataAt(r.getToAddress());
                    if (d != null && d.hasStringValue()) {
                        String s = d.getValue().toString();
                        if (s.length() > 4) strs.add(s.length() > 150 ? s.substring(0,150) : s);
                    }
                }
            }
            int n = 0;
            for (String s : strs) { pw.println("     \"" + s + "\""); if (++n > 25) { pw.println("     ..."); break; } }
        }
        pw.close();
        println("DumpWo71FnStrings done");
    }
}
