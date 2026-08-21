// WO-42: string-anchored function recovery.
//
// The Modding Tools build compiles asserts/logs in, so every interesting
// function carries a literal copy of its own __FUNCTION__ name and its
// source-file path. That makes identification exact instead of pattern-based:
// the function that references the string
// "wh::combatmodule::C_CombatActorActionSyncAttack::EnterImpl" IS that
// function. This script turns needles into (string -> referencing function)
// pairs and decompiles every function found.
//
// Usage: -postScript DumpWo42Anchors.java <outDir> <needle> [<needle> ...]
// @category KCD2
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.*;
import ghidra.program.model.address.Address;
import ghidra.program.model.data.StringDataInstance;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import java.io.*;
import java.util.*;

public class DumpWo42Anchors extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        if (a.length < 2) { println("need outDir + >=1 needle"); return; }
        File outDir = new File(a[0]);
        outDir.mkdirs();
        List<String> needles = new ArrayList<>();
        for (int i = 1; i < a.length; i++) needles.add(a[i]);

        String prog = currentProgram.getName().replace(".dll", "");
        PrintWriter idx = new PrintWriter(new File(outDir, prog + "_anchors.txt"));
        idx.println("# program=" + currentProgram.getName()
                  + " imageBase=" + currentProgram.getImageBase());

        Set<Function> targets = new LinkedHashSet<>();
        ReferenceManager rm = currentProgram.getReferenceManager();

        // 1. strings -> referencing functions
        DataIterator di = currentProgram.getListing().getDefinedData(true);
        while (di.hasNext() && !monitor.isCancelled()) {
            Data d = di.next();
            if (!d.hasStringValue()) continue;
            String s;
            try { s = d.getValue().toString(); } catch (Exception e) { continue; }
            boolean hit = false;
            for (String n : needles) if (s.contains(n)) { hit = true; break; }
            if (!hit) continue;
            idx.println("\nSTRING " + d.getAddress() + "  \"" + s + "\"");
            for (Reference r : rm.getReferencesTo(d.getAddress())) {
                Address from = r.getFromAddress();
                Function f = getFunctionContaining(from);
                idx.println("    xref from " + from + "  in "
                          + (f == null ? "<none>" : f.getName() + " @ " + f.getEntryPoint()));
                if (f != null) targets.add(f);
            }
        }

        // 2. symbols whose names match a needle (RTTI vftables, demangled fns)
        SymbolIterator si = currentProgram.getSymbolTable().getAllSymbols(true);
        while (si.hasNext() && !monitor.isCancelled()) {
            Symbol sym = si.next();
            String nm = sym.getName(true);
            boolean hit = false;
            for (String n : needles) if (nm.contains(n)) { hit = true; break; }
            if (!hit) continue;
            idx.println("\nSYMBOL " + sym.getAddress() + "  " + sym.getSymbolType()
                      + "  " + nm);
            Function f = getFunctionContaining(sym.getAddress());
            if (f != null) targets.add(f);
            // who points at this symbol (vtable slots, ctor writes)
            int c = 0;
            for (Reference r : rm.getReferencesTo(sym.getAddress())) {
                Function ff = getFunctionContaining(r.getFromAddress());
                idx.println("    refd from " + r.getFromAddress() + " " + r.getReferenceType()
                          + "  in " + (ff == null ? "<data>" : ff.getName() + " @ " + ff.getEntryPoint()));
                if (++c > 40) { idx.println("    ... (truncated)"); break; }
            }
        }
        idx.flush();

        // 3. decompile every function we landed on
        DecompInterface dec = new DecompInterface();
        DecompileOptions opts = new DecompileOptions();
        dec.setOptions(opts);
        dec.openProgram(currentProgram);
        int n = 0;
        for (Function f : targets) {
            if (monitor.isCancelled()) break;
            DecompileResults res = dec.decompileFunction(f, 120, monitor);
            String body = (res != null && res.decompileCompleted())
                        ? res.getDecompiledFunction().getC()
                        : "// DECOMPILE FAILED: "
                          + (res == null ? "null" : res.getErrorMessage());
            File of = new File(outDir, prog + "__" + f.getEntryPoint() + "__"
                                     + f.getName().replaceAll("[^A-Za-z0-9_]", "_") + ".c");
            PrintWriter pw = new PrintWriter(of);
            pw.println("// " + f.getName(true));
            pw.println("// entry " + f.getEntryPoint() + "  size " + f.getBody().getNumAddresses());
            pw.println("// calling convention: " + f.getCallingConventionName());
            pw.println();
            pw.print(body);
            pw.close();
            n++;
        }
        dec.dispose();
        idx.println("\n# decompiled " + n + " functions");
        idx.close();
        println("DumpWo42Anchors: " + targets.size() + " functions, out=" + outDir);
    }
}
