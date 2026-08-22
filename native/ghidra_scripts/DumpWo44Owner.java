// WO-44: for each given data address (a vtable slot holding a function ptr),
// walk backwards to the nearest preceding primary symbol (the vtable label),
// and report the byte offset of the slot within it. This answers "which class's
// vtable, and which slot" for a raw slot address.
//
// Usage: -postScript DumpWo44Owner.java <outFile> <addr> [<addr> ...]
// @category KCD2
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.symbol.*;
import java.io.*;

public class DumpWo44Owner extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        PrintWriter pw = new PrintWriter(new FileWriter(a[0], true));
        SymbolTable st = currentProgram.getSymbolTable();
        for (int i = 1; i < a.length; i++) {
            Address slot = toAddr(a[i]);
            // scan back up to 0x2000 bytes for a named symbol
            Address cur = slot;
            Symbol found = null;
            for (long back = 0; back < 0x4000; back += 8) {
                Address probe = slot.subtract(back);
                Symbol[] syms = st.getSymbols(probe);
                for (Symbol s : syms) {
                    String n = s.getName(true);
                    if (n.contains("vftable") || n.contains("vtable")) { found = s; break; }
                }
                if (found != null) { cur = probe; break; }
            }
            long fnPtr = 0;
            try { fnPtr = getLong(slot); } catch (Exception e) {}
            if (found != null) {
                long off = slot.subtract(cur);
                pw.println(String.format("%s -> slot in %s  +0x%X  [%d]  target=0x%X",
                        a[i], found.getName(true), off, off / 8, fnPtr));
            } else {
                pw.println(a[i] + " -> no vtable symbol within 0x4000 back; target=0x" + Long.toHexString(fnPtr));
            }
        }
        pw.close();
        println("DumpWo44Owner done");
    }
}
