// WO-33 Phase 1.2: OverrideNextThrow disassembly.
//
// OverrideNextThrow is NOT in PlayerModule.dll's export table (confirmed via
// dumpbin /exports -- only C_Dice::SetPauseWorldTime is exported). It is a
// private CScriptBind_Dice member registered with the Lua VM at construction
// time, string name and function pointer together. This script:
//   1. Finds the "OverrideNextThrow" ASCII string in the binary.
//   2. Finds every reference to it (almost certainly one: the registration
//      site inside CScriptBind_Dice's constructor).
//   3. Decompiles the containing function (the registration/constructor).
//   4. Scans that decompiled function's body for function-pointer constants
//      (candidates for the real OverrideNextThrow implementation) and
//      decompiles each candidate too.
//   5. Repeats the same for "RollDie" and "SetScore" as controls -- both
//      confirmed live and working (WO-24/WO-25) -- so the two decompiled
//      bodies can be compared structurally against OverrideNextThrow's.
//
// Read-only: operates on a static, already-imported copy of the DLL, never
// touches a running process.
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.listing.Listing;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.scalar.Scalar;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.model.symbol.ReferenceManager;
import ghidra.program.model.listing.DataIterator;
import java.io.PrintWriter;
import java.util.HashSet;
import java.util.Set;

public class DumpDiceOverride extends GhidraScript {

    private DecompInterface decomp;
    private PrintWriter out;
    private FunctionManager fm;

    @Override
    public void run() throws Exception {
        String outPath = getScriptArgs().length > 0 ? getScriptArgs()[0]
            : "C:\\Users\\Jonasty\\AppData\\Local\\Temp\\claude\\C--Users-Jonasty-Documents-KCD2-MP\\ebe537c9-98bf-4ac7-8360-1333eeea4fe7\\scratchpad\\dice_override_decompiled.txt";
        out = new PrintWriter(outPath, "UTF-8");
        fm = currentProgram.getFunctionManager();

        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        String[] needles = { "OverrideNextThrow", "RollDie", "SetScore" };
        for (String needle : needles) {
            out.println("#####################################################");
            out.println("### NEEDLE: " + needle);
            out.println("#####################################################");
            handleNeedle(needle);
            out.println();
        }

        decomp.dispose();
        out.close();
        println("Wrote results to " + outPath);
    }

    private void handleNeedle(String needle) throws Exception {
        // Find every defined string data item whose value contains the needle.
        Set<Address> stringAddrs = new HashSet<>();
        Listing listing = currentProgram.getListing();
        DataIterator di = listing.getDefinedData(true);
        while (di.hasNext()) {
            Data d = di.next();
            if (!d.hasStringValue()) continue;
            Object val = d.getValue();
            if (val != null && val.toString().contains(needle)) {
                stringAddrs.add(d.getAddress());
                out.println("STRING @ " + d.getAddress() + " = " + val.toString());
            }
        }
        if (stringAddrs.isEmpty()) {
            out.println("(no defined string data found containing \"" + needle + "\" -- trying raw memory scan)");
            rawScan(needle, stringAddrs);
        }

        ReferenceManager rm = currentProgram.getReferenceManager();
        Set<Function> containers = new HashSet<>();
        for (Address strAddr : stringAddrs) {
            ReferenceIterator refs = rm.getReferencesTo(strAddr);
            while (refs.hasNext()) {
                Reference ref = refs.next();
                Address from = ref.getFromAddress();
                out.println("  XREF from " + from);
                Function f = fm.getFunctionContaining(from);
                if (f != null) containers.add(f);
            }
        }

        if (containers.isEmpty()) {
            out.println("(no code references found to any \"" + needle + "\" string)");
            return;
        }

        Set<Function> candidatePointerTargets = new HashSet<>();
        for (Function f : containers) {
            out.println("=====================================================");
            out.println("CONTAINING FUNCTION: " + f.getName() + " @ " + f.getEntryPoint());
            out.println("=====================================================");
            String c = decompileToString(f);
            out.println(c);

            // Scan this function's own instructions for scalar operands that
            // are themselves the entry point of some OTHER function in the
            // program -- these are the function-pointer-constant candidates
            // (e.g. the real OverrideNextThrow implementation being handed
            // to a RegisterFunction-style call).
            InstructionIterator ii = currentProgram.getListing().getInstructions(f.getBody(), true);
            while (ii.hasNext()) {
                Instruction insn = ii.next();
                for (int i = 0; i < insn.getNumOperands(); i++) {
                    Object[] objs = insn.getOpObjects(i);
                    for (Object o : objs) {
                        if (o instanceof Address) {
                            Function target = fm.getFunctionAt((Address) o);
                            if (target != null && target != f) candidatePointerTargets.add(target);
                        } else if (o instanceof Scalar) {
                            long v = ((Scalar) o).getUnsignedValue();
                            Address maybe = currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(v);
                            Function target = fm.getFunctionAt(maybe);
                            if (target != null && target != f) candidatePointerTargets.add(target);
                        }
                    }
                }
            }
        }

        out.println("--- candidate function-pointer targets referenced inside the registration function(s) ---");
        for (Function t : candidatePointerTargets) {
            out.println("CANDIDATE: " + t.getName() + " @ " + t.getEntryPoint());
        }
        for (Function t : candidatePointerTargets) {
            out.println("=====================================================");
            out.println("CANDIDATE IMPL: " + t.getName() + " @ " + t.getEntryPoint());
            out.println("=====================================================");
            out.println(decompileToString(t));
        }
    }

    // Fallback: some strings live in non-"defined data" memory (e.g. plain
    // .rdata bytes never turned into a Ghidra String data type by
    // auto-analysis). Scan raw memory bytes for the ASCII needle and, if
    // found, define a fake single-address marker so the xref pass below has
    // something to search -- but since raw bytes without a data unit have no
    // xrefs of their own, instead search for xrefs to a few bytes into the
    // match (covers the common case where code takes &str[0] exactly at the
    // literal's start, which is standard for C string literals).
    private void rawScan(String needle, Set<Address> out2) throws Exception {
        Memory mem = currentProgram.getMemory();
        byte[] pattern = needle.getBytes("US-ASCII");
        Address start = currentProgram.getMinAddress();
        Address end = currentProgram.getMaxAddress();
        Address cur = start;
        while (cur != null && cur.compareTo(end) < 0) {
            Address found = mem.findBytes(cur, end, pattern, null, true, monitor);
            if (found == null) break;
            out.println("RAW MATCH @ " + found);
            out2.add(found);
            try { cur = found.add(1); } catch (Exception e) { break; }
        }
    }

    private String decompileToString(Function f) {
        try {
            DecompileResults res = decomp.decompileFunction(f, 60, monitor);
            if (res != null && res.decompileCompleted()) {
                return res.getDecompiledFunction().getC();
            }
            return "(decompile failed: " + (res != null ? res.getErrorMessage() : "null result") + ")";
        } catch (Exception e) {
            return "(decompile exception: " + e + ")";
        }
    }
}
