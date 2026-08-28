// WO-71: find every read/write of a fixed byte offset off a global pointer
// (gEnv), across a module. Usage:
//   -postScript DumpWo71GenvFlag.java <outFile> <hexOffset> [<hexOffset> ...]
// Prints, per hit: instruction address, mnemonic, RW class, the global the
// base register was loaded from (if recoverable), and the containing function.
// @category KCD2
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.lang.Register;
import ghidra.program.model.listing.*;
import ghidra.program.model.scalar.Scalar;
import ghidra.program.model.symbol.*;
import java.io.*;
import java.util.*;

public class DumpWo71GenvFlag extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        if (a.length < 2) { println("need outFile + >=1 hex offset"); return; }
        PrintWriter pw = new PrintWriter(new FileWriter(new File(a[0]), true));
        Set<Long> offs = new LinkedHashSet<>();
        for (int i = 1; i < a.length; i++) offs.add(Long.decode(a[i]));
        pw.println("\n##### program=" + currentProgram.getName()
                 + " imageBase=" + currentProgram.getImageBase());
        Listing lst = currentProgram.getListing();
        InstructionIterator it = lst.getInstructions(true);
        Map<String,Integer> globalTally = new HashMap<>();
        List<String> rows = new ArrayList<>();
        while (it.hasNext() && !monitor.isCancelled()) {
            Instruction ins = it.next();
            for (int op = 0; op < ins.getNumOperands(); op++) {
                Object[] rep = ins.getOpObjects(op);
                Long disp = null; Register base = null; int nreg = 0;
                for (Object o : rep) {
                    if (o instanceof Scalar) { long v = ((Scalar)o).getUnsignedValue(); if (offs.contains(v)) disp = v; }
                    else if (o instanceof Register) { base = (Register)o; nreg++; }
                }
                if (disp == null || base == null || nreg != 1) continue;
                // walk back for MOV base, [global]
                String glob = "?";
                Instruction p = ins;
                for (int k = 0; k < 24 && p != null; k++) {
                    p = p.getPrevious();
                    if (p == null) break;
                    if (!p.getMnemonicString().toUpperCase().startsWith("MOV")) continue;
                    Object[] d = p.getOpObjects(0);
                    if (d.length != 1 || !(d[0] instanceof Register)) continue;
                    if (!((Register)d[0]).getName().equals(base.getName())) continue;
                    Reference[] rr = p.getReferencesFrom();
                    for (Reference r : rr) {
                        if (r.getReferenceType().isData()) {
                            Symbol s = getSymbolAt(r.getToAddress());
                            glob = (s != null ? s.getName() : "DAT") + "@" + r.getToAddress();
                        }
                    }
                    break;
                }
                boolean write = op == 0 && (ins.getMnemonicString().toUpperCase().startsWith("MOV")
                              || ins.getMnemonicString().toUpperCase().startsWith("SET"));
                Function f = getFunctionContaining(ins.getAddress());
                rows.add(String.format("%s  +0x%x  %-6s %-5s  base=%s  global=%s  fn=%s",
                        ins.getAddress(), disp, ins.getMnemonicString(),
                        write ? "WRITE" : "read", base.getName(), glob,
                        f == null ? "<none>" : f.getName() + "@" + f.getEntryPoint()));
                globalTally.merge(glob, 1, Integer::sum);
                break;
            }
        }
        pw.println("# globals tally (most-hit is very likely gEnv):");
        globalTally.entrySet().stream()
            .sorted((x,y)->y.getValue()-x.getValue()).limit(12)
            .forEach(e -> pw.println("#   " + e.getValue() + "  " + e.getKey()));
        pw.println("# rows=" + rows.size());
        for (String r : rows) pw.println(r);
        pw.close();
        println("DumpWo71GenvFlag: " + rows.size() + " hits");
    }
}
