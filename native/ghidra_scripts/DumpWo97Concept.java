// WO-97: resolve what WO-96 s3.1 left unread in ConceptModule.dll --
//   (a) the segment separator inside the C_ConceptPath tokenizer, and
//   (b) the C_ModuleBase::GetNode descent that FindNode hands the path to.
// Also maps C_PortRef::Trigger for Phase 2: the function, its callers, and
// how a C_PortRef is obtained or built.
//
// Read-only. Operates on a statically imported copy of the DLL.
//
// Usage: -postScript DumpWo97Concept.java <outFile> [<needle> ...]
//   With no needles, uses the WO-97 default set.
// @category KCD2
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.*;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import ghidra.program.model.data.StringDataInstance;
import ghidra.program.model.mem.MemoryBlock;
import java.io.*;
import java.util.*;

public class DumpWo97Concept extends GhidraScript {

    private PrintWriter pw;
    private DecompInterface di;

    private void decomp(Function f, String tag) {
        if (f == null) { pw.println("== " + tag + ": no function"); return; }
        pw.println("======================================================================");
        pw.println("== " + tag + "  " + f.getName(true));
        pw.println("   entry=" + f.getEntryPoint()
                + " proto=" + f.getPrototypeString(true, true)
                + " cc=" + f.getCallingConventionName()
                + " params=" + f.getParameterCount()
                + " thunk=" + f.isThunk());
        try {
            DecompileResults r = di.decompileFunction(f, 90, monitor);
            if (r != null && r.getDecompiledFunction() != null) pw.println(r.getDecompiledFunction().getC());
            else pw.println("   (decompile failed: " + (r == null ? "null" : r.getErrorMessage()) + ")");
        } catch (Exception e) {
            pw.println("   (decompile threw: " + e + ")");
        }
    }

    private void callers(Function f, String tag) {
        if (f == null) return;
        pw.println("---- callers of " + tag + " ----");
        for (Function c : f.getCallingFunctions(monitor)) {
            pw.println("   " + c.getEntryPoint() + "  " + c.getName(true));
        }
    }

    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        pw = new PrintWriter(new FileWriter(a[0], true));
        di = new DecompInterface();
        di.openProgram(currentProgram);

        String[] needles = (a.length > 1)
            ? Arrays.copyOfRange(a, 1, a.length)
            : new String[] { "PortRef", "GetNode", "ModuleBase", "ConceptPath", "Trigger",
                             "FindNode", "GetPort", "ConceptManager" };

        // 1. every named function matching a needle
        pw.println("######################################################################");
        pw.println("### WO-97 symbol sweep: " + String.join(", ", needles));
        pw.println("######################################################################");
        FunctionManager fm = currentProgram.getFunctionManager();
        List<Function> hits = new ArrayList<>();
        for (Function f : fm.getFunctions(true)) {
            String n = f.getName(true);
            for (String nd : needles) {
                if (n.contains(nd)) { hits.add(f); break; }
            }
        }
        pw.println("  " + hits.size() + " matching functions");
        for (Function f : hits) {
            pw.println("   " + f.getEntryPoint() + "  " + f.getName(true)
                + "   cc=" + f.getCallingConventionName() + " params=" + f.getParameterCount()
                + (f.isThunk() ? "  THUNK" : ""));
        }
        pw.println();

        // 2. __FUNCTION__-style strings that name the targets (MT builds keep them, WO-42)
        pw.println("### strings naming the targets");
        for (MemoryBlock b : currentProgram.getMemory().getBlocks()) {
            if (!b.isInitialized()) continue;
            DataIterator it = currentProgram.getListing().getDefinedData(b.getStart(), true);
            while (it.hasNext() && !monitor.isCancelled()) {
                Data d = it.next();
                if (d.getAddress().compareTo(b.getEnd()) > 0) break;
                String s = StringDataInstance.getStringDataInstance(d).getStringValue();
                if (s == null || s.length() < 4 || s.length() > 200) continue;
                for (String nd : needles) {
                    if (s.contains(nd)) {
                        pw.println("   " + d.getAddress() + "  \"" + s + "\"");
                        for (Reference r : getReferencesTo(d.getAddress())) {
                            Function rf = getFunctionContaining(r.getFromAddress());
                            if (rf != null) pw.println("        <- " + rf.getEntryPoint() + " " + rf.getName(true));
                        }
                        break;
                    }
                }
            }
        }
        pw.println();

        // 3. decompile every matching function, plus its callers
        for (Function f : hits) {
            decomp(f, f.getName(true));
            callers(f, f.getName(true));
        }

        di.dispose();
        pw.close();
        println("DumpWo97Concept done: " + hits.size() + " functions");
    }
}
