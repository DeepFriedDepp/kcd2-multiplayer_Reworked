// WO-42: dump vtable slots (byte offset, target, symbol) for a given address,
// so a claimed "slot [N]" can be checked against the function actually there.
//
// Usage: -postScript DumpWo42Vtbl.java <outFile> <count> <addr> [<addr> ...]
// @category KCD2
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Symbol;
import java.io.*;

public class DumpWo42Vtbl extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        int n = Integer.parseInt(a[1]);
        PrintWriter pw = new PrintWriter(new FileWriter(a[0], true));
        for (int i = 2; i < a.length; i++) {
            Address base = toAddr(a[i]);
            Symbol bs = getSymbolAt(base);
            pw.println("##### vtable at " + base + (bs == null ? "" : "  " + bs.getName(true)));
            for (int s = 0; s < n; s++) {
                Address slot = base.add(s * 8L);
                long v;
                try { v = getLong(slot); } catch (Exception e) { break; }
                if (v == 0) { pw.println(String.format("  +0x%03X  [%d]  0", s * 8, s)); continue; }
                Address t = toAddr(v);
                Function f = getFunctionAt(t);
                Symbol sy = getSymbolAt(t);
                pw.println(String.format("  +0x%03X  [%2d]  %s  %s", s * 8, s, t,
                        f != null ? f.getName() : (sy != null ? sy.getName(true) : "?")));
            }
            pw.println();
        }
        pw.close();
        println("DumpWo42Vtbl done");
    }
}
