// WO-52: verify CryNetwork.dll's multiplayer classes are linked code, not orphan strings.
// 1) For each needle string, find defined-string instances and the functions that
//    reference them (the project's proven __FUNCTION__ identification method).
// 2) List RTTI-derived vftable symbols for the key net classes with entry counts.
// 3) Report the exported CreateNetwork function's size and callee count.
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.data.StringDataInstance;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import java.util.*;

public class DumpWo52NetEvidence extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] needles = {
            "CNetContextState::FetchAndPropogateChangesFromGame",
            "CNetContextState::PropogateChangesToGame",
            "CNetContextState::UpdateAspectData",
            "CNetContext::SyncWithGame",
            "CServerContextView", "CClientContextView",
            "CNetChannel", "CNetNub"
        };
        Listing listing = currentProgram.getListing();
        DataIterator dataIter = listing.getDefinedData(true);
        Map<String, List<String>> hits = new TreeMap<>();
        while (dataIter.hasNext() && !monitor.isCancelled()) {
            Data d = dataIter.next();
            if (!d.hasStringValue()) continue;
            String s = StringDataInstance.getStringDataInstance(d).getStringValue();
            if (s == null) continue;
            for (String n : needles) {
                if (!s.contains(n)) continue;
                ReferenceIterator refs = currentProgram.getReferenceManager()
                        .getReferencesTo(d.getAddress());
                while (refs.hasNext()) {
                    Reference r = refs.next();
                    Function f = getFunctionContaining(r.getFromAddress());
                    String from = (f != null)
                        ? f.getName(true) + " @ " + f.getEntryPoint()
                        : "(data ref) @ " + r.getFromAddress();
                    hits.computeIfAbsent(s, k -> new ArrayList<>()).add(from);
                }
            }
        }
        println("== string -> referencing functions ==");
        for (Map.Entry<String, List<String>> e : hits.entrySet()) {
            println("STR: " + e.getKey());
            LinkedHashSet<String> uniq = new LinkedHashSet<>(e.getValue());
            int i = 0;
            for (String f : uniq) { println("   <- " + f); if (++i >= 6) { println("   ... " + uniq.size() + " total"); break; } }
        }

        println("== vftables for net classes ==");
        SymbolTable st = currentProgram.getSymbolTable();
        SymbolIterator si = st.getSymbolIterator();
        int vcount = 0;
        while (si.hasNext() && !monitor.isCancelled()) {
            Symbol sym = si.next();
            String path = sym.getName(true);
            if (!path.contains("vftable")) continue;
            if (path.contains("CNetChannel") || path.contains("CNetContext")
                || path.contains("ContextView") || path.contains("CNetNub")
                || path.contains("CGameContext") || path.contains("EngineModule_CryNetwork")) {
                println("VFT: " + path + " @ " + sym.getAddress());
                vcount++;
                if (vcount > 40) { println("... more"); break; }
            }
        }

        println("== exported CreateNetwork ==");
        for (Symbol sym : st.getSymbols("CreateNetwork")) {
            Function f = getFunctionAt(sym.getAddress());
            if (f == null) f = getFunctionContaining(sym.getAddress());
            if (f != null) {
                println("CreateNetwork @ " + f.getEntryPoint() + " size=" + f.getBody().getNumAddresses()
                    + " callees=" + f.getCalledFunctions(monitor).size());
            } else {
                println("CreateNetwork symbol @ " + sym.getAddress() + " (no function)");
            }
        }
        println("== function totals ==");
        println("total functions: " + currentProgram.getFunctionManager().getFunctionCount());
    }
}
