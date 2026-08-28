// WO-71: raw disassembly of an address window (start end), with resolved
// string/symbol comments. Usage:
//   -postScript DumpWo71Range.java <outFile> <startAddr> <endAddr> [more pairs]
// @category KCD2
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import java.io.*;

public class DumpWo71Range extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        PrintWriter pw = new PrintWriter(new FileWriter(new File(a[0]), true));
        pw.println("\n##### " + currentProgram.getName());
        for (int i = 1; i + 1 < a.length; i += 2) {
            Address s = currentProgram.getAddressFactory().getAddress(a[i]);
            Address e = currentProgram.getAddressFactory().getAddress(a[i+1]);
            pw.println("\n--- " + s + " .. " + e);
            InstructionIterator it = currentProgram.getListing().getInstructions(s, true);
            while (it.hasNext()) {
                Instruction ins = it.next();
                if (ins.getAddress().compareTo(e) > 0) break;
                StringBuilder c = new StringBuilder();
                for (Reference r : ins.getReferencesFrom()) {
                    Data d = getDataAt(r.getToAddress());
                    Symbol sym = getSymbolAt(r.getToAddress());
                    if (d != null && d.hasStringValue()) c.append("  ; \"").append(d.getValue()).append("\"");
                    else if (sym != null) c.append("  ; ").append(sym.getName());
                }
                pw.println(ins.getAddress() + "  " + ins + c);
            }
        }
        pw.close();
        println("DumpWo71Range done");
    }
}
