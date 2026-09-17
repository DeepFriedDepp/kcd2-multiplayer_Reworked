// WO-100: dump vtable slots AND self-identify each slot from the __FUNCTION__
// strings the Modding Tools build leaves inside every function (WO-42's key
// discovery). DumpWo42Vtbl prints the target address and Ghidra's guessed
// name; that is not enough to name a slot in a class whose interface has no
// RTTI (IActionController is pure-virtual and unnamed in the binary). This
// script prints, per slot, every string the target function references that
// looks like a qualified C++ name -- which is what actually names the slot.
//
// Usage: -postScript DumpWo100Vtbl.java <outFile> <count> <addr> [<addr> ...]
// @category KCD2
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSetView;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import java.io.*;
import java.util.*;

public class DumpWo100Vtbl extends GhidraScript {

    private List<String> namesIn(Function f) {
        List<String> out = new ArrayList<>();
        if (f == null) return out;
        ReferenceManager rm = currentProgram.getReferenceManager();
        AddressSetView body = f.getBody();
        for (Address a : body.getAddresses(true)) {
            for (Reference r : rm.getReferencesFrom(a)) {
                Data d = getDataAt(r.getToAddress());
                if (d == null || !d.hasStringValue()) continue;
                String s;
                try { s = d.getValue().toString(); } catch (Exception e) { continue; }
                if (s.length() < 4 || s.length() > 220) continue;
                // qualified C++ names, source paths, and cvar/format anchors
                if (s.contains("::") || s.toLowerCase().contains(".cpp")
                        || s.toLowerCase().contains(".h")) {
                    if (!out.contains(s)) out.add(s);
                }
            }
        }
        return out;
    }

    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        if (a.length < 3) { println("need outFile count addr..."); return; }
        int n = Integer.parseInt(a[1]);
        PrintWriter pw = new PrintWriter(new FileWriter(a[0], true));
        pw.println("# program=" + currentProgram.getName()
                 + " imageBase=" + currentProgram.getImageBase());
        for (int i = 2; i < a.length; i++) {
            Address base = toAddr(a[i]);
            Symbol bs = getSymbolAt(base);
            pw.println("##### vtable at " + base + (bs == null ? "" : "  " + bs.getName(true)));
            for (int s = 0; s < n && !monitor.isCancelled(); s++) {
                Address slot = base.add(s * 8L);
                long v;
                try { v = getLong(slot); } catch (Exception e) { break; }
                if (v == 0) { pw.println(String.format("  +0x%03X [%3d]  0", s * 8, s)); continue; }
                Address t;
                try { t = toAddr(v); } catch (Exception e) { break; }
                if (!currentProgram.getMemory().contains(t)) { pw.println(String.format("  +0x%03X [%3d]  %016X  <not in image -- end of vtable>", s*8, s, v)); break; }
                Function f = getFunctionAt(t);
                Symbol sy = getSymbolAt(t);
                pw.println(String.format("  +0x%03X [%3d]  %s  rva=0x%X  %s", s * 8, s, t,
                        t.getOffset() - currentProgram.getImageBase().getOffset(),
                        f != null ? f.getName() : (sy != null ? sy.getName(true) : "?")));
                for (String nm : namesIn(f)) pw.println("              | \"" + nm + "\"");
            }
            pw.println();
        }
        pw.close();
        println("DumpWo100Vtbl done");
    }
}
