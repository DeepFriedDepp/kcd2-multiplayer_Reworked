// WO-15 continuation: SetParent's body calls two un-named helpers --
// FUN_1803d7f80 (assigns the incoming shared_ptr<C_Faction> into the member,
// presumably incrementing it) and FUN_1800f3dc0 (releases/decrements a
// shared_ptr-shaped value, called repeatedly throughout this file on
// different shared_ptr members). Decompiling both by address gives the real
// refcount offset and increment/decrement mechanism, rather than assuming
// textbook std::shared_ptr internals.
//
// Read-only: operates on a static, already-imported copy of the DLL.
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import ghidra.program.model.address.Address;
import java.io.PrintWriter;

public class DumpSharedPtrHelpers extends GhidraScript {
    @Override
    public void run() throws Exception {
        String outPath = getScriptArgs().length > 0 ? getScriptArgs()[0]
            : "C:\\Users\\Jonasty\\AppData\\Local\\Temp\\claude\\C--Users-Jonasty-Documents-KCD2-MP\\f1286127-ee8c-452a-95b3-954d5baa1b64\\scratchpad\\sharedptr_helpers_decompiled.txt";
        PrintWriter out = new PrintWriter(outPath, "UTF-8");

        // Addresses as seen inside SetParent's decompiled body.
        long[] addrs = { 0x1803d7f80L, 0x1800f3dc0L,
                         // corroborating: same-shaped helpers seen elsewhere
                         0x180433980L, 0x18046c830L, 0x18046c8a0L, 0x180165770L };

        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        for (long a : addrs) {
            Address addr = currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(a);
            Function f = currentProgram.getFunctionManager().getFunctionAt(addr);
            out.println("=====================================================");
            if (f == null) {
                out.println("NO FUNCTION at " + addr + " (not a recognized function start)");
                out.println();
                continue;
            }
            out.println("FUNCTION: " + f.getName() + " @ " + f.getEntryPoint());
            out.println("SIGNATURE: " + f.getSignature());
            out.println("=====================================================");
            DecompileResults res = decomp.decompileFunction(f, 60, monitor);
            if (res != null && res.decompileCompleted()) {
                out.println(res.getDecompiledFunction().getC());
            } else {
                out.println("(decompile failed: " +
                    (res != null ? res.getErrorMessage() : "null result") + ")");
            }
            out.println();
        }

        decomp.dispose();
        out.close();
        println("Wrote helper decompilations to " + outPath);
    }
}
