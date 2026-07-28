// Milestone 1: prove the RTTR reflection ABI is reachable from inside the process.
//
// This file deliberately does NOT call anything yet. It resolves the exports and
// reports what it found. Calling them correctly needs the MSVC class-passing
// rules handled per signature, and guessing at that is how you get a crash that
// looks like a logic bug -- see README.md for the plan.
//
// Exports are matched by PREFIX against CrySystem.dll's export table rather than
// by full mangled string. Transcribing a 200-character mangled name by hand is a
// silent-failure machine, and a prefix match survives a signature change across
// a game patch instead of quietly resolving to null.

#include "log.h"

#include <windows.h>
#include <cstring>
#include <vector>

namespace kcdmp {

namespace {

struct ExportEntry {
    const char* name;
    void*       addr;
};

// Walk a module's PE export directory. Returns every named export.
std::vector<ExportEntry> module_exports(HMODULE mod) {
    std::vector<ExportEntry> out;
    auto* base = reinterpret_cast<BYTE*>(mod);
    auto* dos  = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return out;

    auto* nt = reinterpret_cast<IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return out;

    const auto& dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
    if (dir.VirtualAddress == 0) return out;

    auto* exp    = reinterpret_cast<IMAGE_EXPORT_DIRECTORY*>(base + dir.VirtualAddress);
    auto* names  = reinterpret_cast<DWORD*>(base + exp->AddressOfNames);
    auto* ords   = reinterpret_cast<WORD*>(base + exp->AddressOfNameOrdinals);
    auto* funcs  = reinterpret_cast<DWORD*>(base + exp->AddressOfFunctions);

    out.reserve(exp->NumberOfNames);
    for (DWORD i = 0; i < exp->NumberOfNames; ++i) {
        out.push_back(ExportEntry{
            reinterpret_cast<const char*>(base + names[i]),
            base + funcs[ords[i]]
        });
    }
    return out;
}

void* find_by_prefix(const std::vector<ExportEntry>& exports, const char* prefix, int* match_count) {
    void* first = nullptr;
    int   n     = 0;
    const size_t len = std::strlen(prefix);
    for (const auto& e : exports) {
        if (std::strncmp(e.name, prefix, len) == 0) {
            if (!first) first = e.addr;
            ++n;
        }
    }
    if (match_count) *match_count = n;
    return first;
}

// The reflection entry points the plugin needs. Prefixes, not full signatures.
// Overload count is reported because `invoke` legitimately has one per arity and
// a count of 1 there would mean something changed.
struct Wanted {
    const char* label;
    const char* prefix;
};

constexpr Wanted kWanted[] = {
    { "type::get_by_name",        "?get_by_name@type@rttr@@" },
    { "type::get_method",         "?get_method@type@rttr@@" },
    { "type::get_property",       "?get_property@type@rttr@@" },
    { "type::get_property_value", "?get_property_value@type@rttr@@" },
    { "type::set_property_value", "?set_property_value@type@rttr@@" },
    { "type::get_types",          "?get_types@type@rttr@@" },
    { "type::is_valid",           "?is_valid@type@rttr@@" },
    { "method::invoke",           "?invoke@method@rttr@@" },
    { "method::invoke_variadic",  "?invoke_variadic@method@rttr@@" },
    { "method::get_name",         "?get_name@method@rttr@@" },
    { "method::get_signature",    "?get_signature@method@rttr@@" },
    { "method::is_valid",         "?is_valid@method@rttr@@" },
    { "property::get_value",      "?get_value@property@rttr@@" },
    { "property::set_value",      "?set_value@property@rttr@@" },
    { "property::is_valid",       "?is_valid@property@rttr@@" },
};

} // namespace

// Returns true only if every wanted entry point resolved.
bool probe_rttr() {
    HMODULE cry = GetModuleHandleA("CrySystem.dll");
    if (!cry) {
        logf("FAIL CrySystem.dll not loaded in this process -- injected too early, or "
             "this is the retail build, which is monolithic and exports nothing.");
        return false;
    }
    logf("CrySystem.dll base = %p", static_cast<void*>(cry));

    const auto exports = module_exports(cry);
    logf("CrySystem.dll named exports = %zu", exports.size());
    if (exports.empty()) {
        logf("FAIL no export table -- wrong build. Expected the Modding Tools build "
             "(Bin\\Win64ReleaseSteamLTO_DLL), not retail.");
        return false;
    }

    int rttr_total = 0;
    for (const auto& e : exports) {
        if (std::strstr(e.name, "@rttr@@")) ++rttr_total;
    }
    logf("exports mentioning rttr = %d", rttr_total);

    bool all = true;
    for (const auto& w : kWanted) {
        int n = 0;
        void* addr = find_by_prefix(exports, w.prefix, &n);
        if (addr) {
            logf("  OK   %-24s %p  (%d overload%s)", w.label, addr, n, n == 1 ? "" : "s");
        } else {
            logf("  MISS %-24s  prefix not found: %s", w.label, w.prefix);
            all = false;
        }
    }

    logf(all ? "RESULT reflection ABI fully reachable"
             : "RESULT incomplete -- see MISS lines above");
    return all;
}

} // namespace kcdmp
