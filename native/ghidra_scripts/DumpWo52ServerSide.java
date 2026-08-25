// WO-52: is the SERVER half of CryNetwork real in this build, or compiled out
// by PURE_CLIENT? Report RTTI vftables for the server classes plus the
// function sizes of the server-side context-view handlers.
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import java.util.*;

public class DumpWo52ServerSide extends GhidraScript {
    @Override
    public void run() throws Exception {
        SymbolTable st = currentProgram.getSymbolTable();
        String[] classes = {
            "CServerContextView", "CClientContextView", "CNetChannel", "CNetNub",
            "CNetContext", "CNetContextState", "CNetwork", "CEngineModule_CryNetwork",
            "CCTPEndpoint", "CNetworkThread"
        };
        println("== RTTI type-info / vftable symbols per class ==");
        for (String c : classes) {
            int vft = 0, rtti = 0;
            List<String> samples = new ArrayList<>();
            SymbolIterator si = st.getSymbolIterator();
            while (si.hasNext() && !monitor.isCancelled()) {
                Symbol s = si.next();
                String n = s.getName(true);
                if (!n.contains(c)) continue;
                if (n.endsWith("::vftable")) { vft++; if (samples.size() < 3) samples.add(n + " @ " + s.getAddress()); }
                if (n.contains("RTTI") || n.contains("class_type_info") || n.contains("typeinfo")) rtti++;
            }
            println(String.format("%-28s vftables=%d rttiSyms=%d %s", c, vft, rtti, samples));
        }

        println("== function count & size around known server handlers ==");
        FunctionManager fm = currentProgram.getFunctionManager();
        long[] addrs = {0x18004ad80L, 0x180006dc0L, 0x180006f70L, 0x1800083b0L,
                        0x1800337d0L, 0x180090ea0L, 0x180098330L, 0x1800384f0L,
                        0x18003bfa0L, 0x18003cc50L, 0x1800414e0L};
        for (long a : addrs) {
            Function f = fm.getFunctionContaining(toAddr(a));
            if (f == null) { println(String.format("%x -> NO FUNCTION", a)); continue; }
            println(String.format("%x -> %s size=%d callers=%d callees=%d",
                a, f.getName(), f.getBody().getNumAddresses(),
                f.getCallingFunctions(monitor).size(), f.getCalledFunctions(monitor).size()));
        }

        println("== CreateNetwork decompile ==");
        ghidra.app.decompiler.DecompInterface di = new ghidra.app.decompiler.DecompInterface();
        di.openProgram(currentProgram);
        for (Symbol sym : st.getSymbols("CreateNetwork")) {
            Function f = fm.getFunctionContaining(sym.getAddress());
            if (f == null) continue;
            ghidra.app.decompiler.DecompileResults r = di.decompileFunction(f, 60, monitor);
            if (r.decompileCompleted()) println(r.getDecompiledFunction().getC());
            break;
        }
        di.dispose();
    }
}
