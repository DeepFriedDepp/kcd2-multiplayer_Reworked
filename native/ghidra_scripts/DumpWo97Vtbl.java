// WO-97 Phase 2: dump C++ vtables by symbol-name substring, resolving each slot
// to the function it points at. Used to confirm which virtual slot a call like
// `(*(code **)(*(longlong *)port + 0x78))(port)` actually lands on, rather than
// trusting a slot number read off a decompile.
//
// Read-only.  Usage: -postScript DumpWo97Vtbl.java <outFile> <nameSubstring> [<slots>]
// @category KCD2
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;
import java.io.*;

public class DumpWo97Vtbl extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        PrintWriter pw = new PrintWriter(new FileWriter(a[0], true));
        String needle = a[1];
        int slots = (a.length > 2) ? Integer.parseInt(a[2]) : 24;

        SymbolIterator it = currentProgram.getSymbolTable().getAllSymbols(true);
        int found = 0;
        while (it.hasNext() && !monitor.isCancelled()) {
            Symbol s = it.next();
            String n = s.getName(true);
            if (!n.contains(needle) || !n.contains("vftable")) continue;
            found++;
            pw.println("======================================================================");
            pw.println("### " + n + "  @" + s.getAddress());
            for (int i = 0; i < slots; i++) {
                Address slotAddr = s.getAddress().add((long) i * 8);
                long v;
                try { v = getLong(slotAddr); } catch (Exception e) { break; }
                if (v == 0) { pw.println(String.format("   [%2d] +0x%02X  0", i, i * 8)); continue; }
                Address target = toAddr(v);
                Function f = getFunctionContaining(target);
                pw.println(String.format("   [%2d] +0x%02X  %s  %s",
                    i, i * 8, target, f == null ? "(no function)" : f.getName(true)));
            }
        }
        pw.println("### " + found + " vftable symbol(s) matching \"" + needle + "\"");
        pw.close();
        println("DumpWo97Vtbl done: " + found);
    }
}
