// WO-42: raw disassembly dump for named addresses.
// A decompilation is an interpretation; the register-level truth (which arg
// rides in xmm2 vs r8, which vtable slot is called) only shows up in the
// instruction stream. This dumps it.
//
// Usage: -postScript DumpWo42Asm.java <outFile> <addr> [<addr> ...]
//        addr may be "0x18002 0410" style hex (no spaces) or a symbol name.
// @category KCD2
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSetView;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import java.io.*;

public class DumpWo42Asm extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        PrintWriter pw = new PrintWriter(new FileWriter(a[0], true));
        for (int i = 1; i < a.length; i++) {
            Address addr = null;
            try { addr = toAddr(a[i]); } catch (Exception e) { }
            if (addr == null) {
                for (Symbol s : currentProgram.getSymbolTable().getSymbols(a[i])) {
                    addr = s.getAddress(); break;
                }
            }
            if (addr == null) { pw.println("### NOT FOUND: " + a[i]); continue; }
            Function f = getFunctionContaining(addr);
            pw.println("############ " + a[i] + " -> " + addr
                     + (f == null ? "  <no function>"
                        : "  fn=" + f.getName() + " entry=" + f.getEntryPoint()
                          + " bytes=" + f.getBody().getNumAddresses()));
            AddressSetView body = (f != null) ? f.getBody() : null;
            InstructionIterator it = (body != null)
                ? currentProgram.getListing().getInstructions(body, true)
                : currentProgram.getListing().getInstructions(addr, true);
            int n = 0;
            while (it.hasNext() && n < 4000) {
                Instruction ins = it.next();
                StringBuilder sb = new StringBuilder();
                sb.append(ins.getAddress()).append("  ");
                sb.append(String.format("%-42s", ins.toString()));
                Reference[] rs = ins.getReferencesFrom();
                for (Reference r : rs) {
                    if (r.isMemoryReference()) {
                        Data d = getDataAt(r.getToAddress());
                        Symbol s = getSymbolAt(r.getToAddress());
                        String extra = "";
                        if (d != null && d.hasStringValue()) extra = "\"" + d.getValue() + "\"";
                        else if (s != null) extra = s.getName(true);
                        if (!extra.isEmpty()) sb.append("  ; ").append(r.getReferenceType())
                                                .append(" ").append(r.getToAddress())
                                                .append(" ").append(extra);
                    }
                }
                pw.println(sb);
                n++;
            }
            pw.println();
        }
        pw.close();
        println("DumpWo42Asm done");
    }
}
