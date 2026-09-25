#include "anchors.h"

#include <cstdio>
#include <cstring>

namespace kcdmp::anchor {

namespace {

// --- PE plumbing (no destructible locals: several callers sit under __try) ---

const IMAGE_NT_HEADERS64* nt_headers(HMODULE mod) {
    if (!mod) return nullptr;
    auto* base = reinterpret_cast<const uint8_t*>(mod);
    auto* dos  = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return nullptr;
    auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return nullptr;
    return nt;
}

struct Pdata {
    const RUNTIME_FUNCTION* fns = nullptr;
    size_t                  count = 0;
};

bool pdata(HMODULE mod, Pdata* out) {
    const IMAGE_NT_HEADERS64* nt = nt_headers(mod);
    if (!nt) return false;
    const auto& dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION];
    if (!dir.VirtualAddress || dir.Size < sizeof(RUNTIME_FUNCTION)) return false;
    out->fns = reinterpret_cast<const RUNTIME_FUNCTION*>(
        reinterpret_cast<const uint8_t*>(mod) + dir.VirtualAddress);
    out->count = dir.Size / sizeof(RUNTIME_FUNCTION);
    return true;
}

// Binary search: the entry whose [Begin, End) holds rva. The table is sorted
// by BeginAddress (a PE requirement the loader itself relies on).
const RUNTIME_FUNCTION* entry_for(const Pdata& p, uint32_t rva) {
    size_t lo = 0, hi = p.count;
    while (lo < hi) {
        const size_t mid = (lo + hi) / 2;
        if (p.fns[mid].BeginAddress <= rva) lo = mid + 1; else hi = mid;
    }
    if (lo == 0) return nullptr;
    const RUNTIME_FUNCTION* e = &p.fns[lo - 1];
    return (rva >= e->BeginAddress && rva < e->EndAddress) ? e : nullptr;
}

// UNWIND_INFO: byte0 = version(3) | flags(5)<<3; byte2 = CountOfCodes. With
// UNW_FLAG_CHAININFO the parent RUNTIME_FUNCTION follows the (even-padded)
// code array. Follow at most a few links -- a real chain is 1-2 deep.
const RUNTIME_FUNCTION* root_of(HMODULE mod, const RUNTIME_FUNCTION* e) {
    auto* base = reinterpret_cast<const uint8_t*>(mod);
    for (int i = 0; i < 8 && e; ++i) {
        // RUNTIME_FUNCTION_INDIRECT: an odd UnwindData is the RVA of another
        // RUNTIME_FUNCTION, not of an UNWIND_INFO.
        if (e->UnwindData & 1u) {
            e = reinterpret_cast<const RUNTIME_FUNCTION*>(base + (e->UnwindData & ~1u));
            continue;
        }
        const uint8_t* ui = base + e->UnwindData;
        const uint8_t flags = ui[0] >> 3;
        if (!(flags & UNW_FLAG_CHAININFO)) return e;
        const uint8_t codes = ui[2];
        const size_t  slots = (static_cast<size_t>(codes) + 1) & ~static_cast<size_t>(1);
        e = reinterpret_cast<const RUNTIME_FUNCTION*>(ui + 4 + 2 * slots);
    }
    return e;
}

// Every fragment of the function rooted at `root`, handed to `visit` as a
// Range. Returns true as soon as visit does.
template <typename F>
bool for_each_fragment(HMODULE mod, const Pdata& p, const RUNTIME_FUNCTION* root, F&& visit) {
    auto* base = reinterpret_cast<const uint8_t*>(mod);
    const uint32_t rootBegin = root->BeginAddress;
    for (size_t i = 0; i < p.count; ++i) {
        const RUNTIME_FUNCTION* e = &p.fns[i];
        const RUNTIME_FUNCTION* r = (e->BeginAddress == rootBegin) ? e : root_of(mod, e);
        if (!r || r->BeginAddress != rootBegin) continue;
        Range fr{ base + e->BeginAddress, base + e->EndAddress };
        if (visit(fr)) return true;
    }
    return false;
}

bool scan_rip_ref(const Range& r, const uint8_t* target) {
    // Any disp32 whose "next instruction" address + disp lands on target. The
    // disp32 is the instruction's last field for LEA/MOV reg,[rip+x], which is
    // how code references data; a random 32-bit collision on one specific
    // 64-bit target inside one function is not a practical concern.
    if (r.size() < 4) return false;
    for (const uint8_t* p = r.begin; p + 4 <= r.end; ++p) {
        int32_t disp;
        std::memcpy(&disp, p, 4);
        if (p + 4 + disp == target) return true;
    }
    return false;
}

bool scan_bytes(const Range& r, const uint8_t* pat, size_t n) {
    if (!n || r.size() < n) return false;
    for (const uint8_t* p = r.begin; p + n <= r.end; ++p)
        if (p[0] == pat[0] && std::memcmp(p, pat, n) == 0) return true;
    return false;
}

bool scan_sequence(const Range& r, const uint8_t* a, size_t na, const uint8_t* b, size_t nb, size_t window) {
    if (!na || !nb || r.size() < na) return false;
    for (const uint8_t* p = r.begin; p + na <= r.end; ++p) {
        if (p[0] != a[0] || std::memcmp(p, a, na) != 0) continue;
        const uint8_t* lim = p + na + window;
        if (lim > r.end) lim = r.end;
        for (const uint8_t* q = p + na; q + nb <= lim; ++q)
            if (q[0] == b[0] && std::memcmp(q, b, nb) == 0) return true;
    }
    return false;
}

const uint8_t* find_sequence(const Range& r, const uint8_t* a, size_t na, const uint8_t* b, size_t nb, size_t window) {
    if (!na || !nb || r.size() < na) return nullptr;
    for (const uint8_t* p = r.begin; p + na <= r.end; ++p) {
        if (p[0] != a[0] || std::memcmp(p, a, na) != 0) continue;
        const uint8_t* lim = p + na + window;
        if (lim > r.end) lim = r.end;
        for (const uint8_t* q = p + na; q + nb <= lim; ++q)
            if (q[0] == b[0] && std::memcmp(q, b, nb) == 0) return p;
    }
    return nullptr;
}

bool scan_call(const Range& r, const uint8_t* target) {
    // A direct call (E8) or a tail jump (E9) -- MSVC turns a final call into
    // a jmp, and the ground re-snap slot is exactly such a wrapper.
    for (const uint8_t* p = r.begin; p + 5 <= r.end; ++p) {
        if (*p != 0xE8 && *p != 0xE9) continue;
        int32_t rel;
        std::memcpy(&rel, p + 1, 4);
        if (p + 5 + rel == target) return true;
    }
    return false;
}

// --- SEH isolation for the scans (no C++ objects with destructors here) ----

bool guarded_section(HMODULE mod, const char* name, Range* out) {
    __try {
        const IMAGE_NT_HEADERS64* nt = nt_headers(mod);
        if (!nt) return false;
        const IMAGE_SECTION_HEADER* s = IMAGE_FIRST_SECTION(nt);
        for (WORD i = 0; i < nt->FileHeader.NumberOfSections; ++i, ++s) {
            char n8[9]{};
            std::memcpy(n8, s->Name, 8);
            if (std::strcmp(n8, name) != 0) continue;
            auto* base = reinterpret_cast<const uint8_t*>(mod);
            const DWORD sz = s->Misc.VirtualSize ? s->Misc.VirtualSize : s->SizeOfRawData;
            out->begin = base + s->VirtualAddress;
            out->end   = out->begin + sz;
            return true;
        }
        return false;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

const char* guarded_find_cstring(const Range& r, const char* s, size_t n, int* count) {
    const char* first = nullptr;
    int c = 0;
    __try {
        for (const uint8_t* p = r.begin; p + n + 1 <= r.end; ++p) {
            if (*p != static_cast<uint8_t>(s[0])) continue;
            if (p > r.begin && p[-1] != 0) continue;
            if (std::memcmp(p, s, n) != 0 || p[n] != 0) continue;
            if (!first) first = reinterpret_cast<const char*>(p);
            ++c;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { return nullptr; }
    if (count) *count += c;
    return first;
}

// RTTI (x64): TypeDescriptor { void* vftable; void* spare; char name[]; } lives
// in .data. CompleteObjectLocator { u32 signature(=1); u32 offset; u32 cdOffset;
// i32 typeDescriptor RVA; i32 classDescriptor RVA; i32 self RVA; } in .rdata.
// The qword just before a vftable is the COL's absolute address.
void* const* guarded_find_vftable(HMODULE mod, const Range& data, const Range& rdata,
                                  const char* decorated, uint32_t colOffset) {
    __try {
        const size_t n = std::strlen(decorated);
        auto* base = reinterpret_cast<const uint8_t*>(mod);
        void* const* found = nullptr;
        int hits = 0;
        for (const uint8_t* p = data.begin; p + n + 1 <= data.end; ++p) {
            if (*p != static_cast<uint8_t>(decorated[0])) continue;
            if (std::memcmp(p, decorated, n) != 0 || p[n] != 0) continue;
            const uint8_t* td = p - 0x10;
            const uint32_t tdRva = static_cast<uint32_t>(td - base);
            for (const uint8_t* c = rdata.begin; c + 24 <= rdata.end; c += 4) {
                uint32_t col[6];
                std::memcpy(col, c, sizeof(col));
                if (col[0] != 1 || col[3] != tdRva || col[1] != colOffset) continue;
                if (col[5] != static_cast<uint32_t>(c - base)) continue;
                const uint64_t colVa = reinterpret_cast<uint64_t>(c);
                for (const uint8_t* v = rdata.begin; v + 16 <= rdata.end; v += 8) {
                    uint64_t q;
                    std::memcpy(&q, v, 8);
                    if (q != colVa) continue;
                    found = reinterpret_cast<void* const*>(v + 8);
                    ++hits;
                }
            }
        }
        return (hits == 1) ? found : nullptr;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return nullptr; }
}

bool guarded_function_range(HMODULE mod, const void* addr, Range* out) {
    __try {
        Pdata p{};
        if (!pdata(mod, &p)) return false;
        auto* base = reinterpret_cast<const uint8_t*>(mod);
        const auto rva = static_cast<uint32_t>(static_cast<const uint8_t*>(addr) - base);
        const RUNTIME_FUNCTION* e = entry_for(p, rva);
        if (!e) return false;
        const RUNTIME_FUNCTION* r = root_of(mod, e);
        if (!r) return false;
        out->begin = base + r->BeginAddress;
        out->end   = base + r->EndAddress;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

enum class Scan { Ref, Bytes, Seq, Call, Find };

struct ScanArgs {
    Scan kind;
    const uint8_t* target;
    const uint8_t* a; size_t na;
    const uint8_t* b; size_t nb; size_t window;
    const uint8_t** found = nullptr;   // Scan::Find: the match
};

bool guarded_scan_function(HMODULE mod, const void* fn, const ScanArgs& s) {
    __try {
        Pdata p{};
        if (!pdata(mod, &p)) return false;
        auto* base = reinterpret_cast<const uint8_t*>(mod);
        const auto rva = static_cast<uint32_t>(static_cast<const uint8_t*>(fn) - base);
        const RUNTIME_FUNCTION* e = entry_for(p, rva);
        if (!e) return false;
        const RUNTIME_FUNCTION* root = root_of(mod, e);
        if (!root) return false;
        return for_each_fragment(mod, p, root, [&](const Range& fr) {
            switch (s.kind) {
                case Scan::Ref:   return scan_rip_ref(fr, s.target);
                case Scan::Bytes: return scan_bytes(fr, s.a, s.na);
                case Scan::Seq:   return scan_sequence(fr, s.a, s.na, s.b, s.nb, s.window);
                case Scan::Call:  return scan_call(fr, s.target);
                case Scan::Find: {
                    const uint8_t* m = find_sequence(fr, s.a, s.na, s.b, s.nb, s.window);
                    if (m && s.found) *s.found = m;
                    return m != nullptr;
                }
            }
            return false;
        });
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// Every LEA reg,[rip+disp32] (REX.W 8D, ModRM mod=00 rm=101) in .text whose
// target is `str`; distinct root functions counted. Returns the root when
// exactly one function references the string.
const uint8_t* guarded_function_by_string(HMODULE mod, const Range& text, const uint8_t* str, int* count) {
    __try {
        Pdata p{};
        if (!pdata(mod, &p)) return nullptr;
        auto* base = reinterpret_cast<const uint8_t*>(mod);
        const uint8_t* roots[8]{};
        int nroots = 0;
        for (const uint8_t* q = text.begin; q + 7 <= text.end; ++q) {
            if ((q[0] & 0xF8) != 0x48 || q[1] != 0x8D || (q[2] & 0xC7) != 0x05) continue;
            int32_t disp;
            std::memcpy(&disp, q + 3, 4);
            if (q + 7 + disp != str) continue;
            const RUNTIME_FUNCTION* e = entry_for(p, static_cast<uint32_t>(q - base));
            const RUNTIME_FUNCTION* r = e ? root_of(mod, e) : nullptr;
            if (!r) continue;
            const uint8_t* rb = base + r->BeginAddress;
            bool seen = false;
            for (int i = 0; i < nroots; ++i) if (roots[i] == rb) { seen = true; break; }
            if (!seen && nroots < 8) roots[nroots++] = rb;
        }
        if (count) *count = nroots;
        return (nroots == 1) ? roots[0] : nullptr;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return nullptr; }
}

// WO-121: every distinct E8/E9 rel32 target in the function (all fragments)
// that lands on a primary function start of the same module.
int guarded_call_targets(HMODULE mod, const void* fn, const uint8_t** out, int max) {
    __try {
        Pdata p{};
        if (!pdata(mod, &p)) return 0;
        auto* base = reinterpret_cast<const uint8_t*>(mod);
        const auto rva = static_cast<uint32_t>(static_cast<const uint8_t*>(fn) - base);
        const RUNTIME_FUNCTION* e = entry_for(p, rva);
        if (!e) return 0;
        const RUNTIME_FUNCTION* root = root_of(mod, e);
        if (!root) return 0;
        int n = 0;
        for_each_fragment(mod, p, root, [&](const Range& fr) {
            for (const uint8_t* q = fr.begin; q + 5 <= fr.end; ++q) {
                if (q[0] != 0xE8 && q[0] != 0xE9) continue;
                int32_t disp;
                std::memcpy(&disp, q + 1, 4);
                const uint8_t* t = q + 5 + disp;
                if (t < base) continue;
                const uint32_t trva = static_cast<uint32_t>(t - base);
                const RUNTIME_FUNCTION* te = entry_for(p, trva);
                if (!te || te->BeginAddress != trva) continue;
                bool seen = false;
                for (int k = 0; k < n; ++k) if (out[k] == t) { seen = true; break; }
                if (!seen && n < max) out[n++] = t;
            }
            return false;
        });
        return n;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return 0; }
}

} // namespace

bool section(HMODULE mod, const char* name, Range* out) {
    return out && guarded_section(mod, name, out);
}

const char* find_cstring(HMODULE mod, const char* s, int* count) {
    if (count) *count = 0;
    if (!s || !*s) return nullptr;
    const size_t n = std::strlen(s);
    Range rd{}, d{};
    const char* hit = nullptr;
    if (section(mod, ".rdata", &rd)) hit = guarded_find_cstring(rd, s, n, count);
    if (section(mod, ".data", &d)) {
        const char* h2 = guarded_find_cstring(d, s, n, count);
        if (!hit) hit = h2;
    }
    return hit;
}

void* const* find_vftable(HMODULE mod, const char* decorated, uint32_t colOffset) {
    Range data{}, rdata{};
    if (!section(mod, ".data", &data) || !section(mod, ".rdata", &rdata)) return nullptr;
    return guarded_find_vftable(mod, data, rdata, decorated, colOffset);
}

bool function_range(HMODULE mod, const void* addr, Range* out) {
    return out && addr && guarded_function_range(mod, addr, out);
}

bool function_refs(HMODULE mod, const void* fn, const void* target) {
    if (!fn || !target) return false;
    ScanArgs s{ Scan::Ref, static_cast<const uint8_t*>(target), nullptr, 0, nullptr, 0, 0 };
    return guarded_scan_function(mod, fn, s);
}

const uint8_t* function_by_string(HMODULE mod, const char* s, int* count) {
    if (count) *count = 0;
    const char* str = find_cstring(mod, s);
    if (!str) return nullptr;
    Range text{};
    if (!section(mod, ".text", &text)) return nullptr;
    return guarded_function_by_string(mod, text, reinterpret_cast<const uint8_t*>(str), count);
}

bool function_has_bytes(HMODULE mod, const void* fn, const uint8_t* pat, size_t n) {
    if (!fn || !pat || !n) return false;
    ScanArgs s{ Scan::Bytes, nullptr, pat, n, nullptr, 0, 0 };
    return guarded_scan_function(mod, fn, s);
}

bool function_has_sequence(HMODULE mod, const void* fn,
                           const uint8_t* first, size_t n1,
                           const uint8_t* second, size_t n2, size_t window) {
    if (!fn || !first || !second) return false;
    ScanArgs s{ Scan::Seq, nullptr, first, n1, second, n2, window };
    return guarded_scan_function(mod, fn, s);
}

bool function_calls(HMODULE mod, const void* fn, const void* target) {
    if (!fn || !target) return false;
    ScanArgs s{ Scan::Call, static_cast<const uint8_t*>(target), nullptr, 0, nullptr, 0, 0 };
    return guarded_scan_function(mod, fn, s);
}

const uint8_t* function_find_sequence(HMODULE mod, const void* fn,
                                      const uint8_t* first, size_t n1,
                                      const uint8_t* second, size_t n2, size_t window) {
    if (!fn || !first || !second) return nullptr;
    const uint8_t* found = nullptr;
    ScanArgs s{ Scan::Find, nullptr, first, n1, second, n2, window, &found };
    return guarded_scan_function(mod, fn, s) ? found : nullptr;
}

int function_call_targets(HMODULE mod, const void* fn, const uint8_t** out, int max) {
    if (!fn || !out || max <= 0) return 0;
    return guarded_call_targets(mod, fn, out, max);
}

const void* rip_target(const uint8_t* insn, size_t dispOffset, size_t insnLen) {
    if (!insn) return nullptr;
    int32_t disp = 0;
    std::memcpy(&disp, insn + dispOffset, 4);
    return insn + insnLen + disp;
}

void describe(const void* p, char* out, size_t n) {
    if (!p) { _snprintf_s(out, n, _TRUNCATE, "null"); return; }
    HMODULE mod = nullptr;
    char name[MAX_PATH]{};
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                           GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           static_cast<LPCSTR>(p), &mod) && mod) {
        GetModuleFileNameA(mod, name, MAX_PATH);
        const char* slash = std::strrchr(name, '\\');
        const char* base = slash ? slash + 1 : name;
        _snprintf_s(out, n, _TRUNCATE, "%s+0x%llX", base,
                    static_cast<unsigned long long>(
                        reinterpret_cast<const char*>(p) - reinterpret_cast<const char*>(mod)));
    } else {
        _snprintf_s(out, n, _TRUNCATE, "%p (heap)", p);
    }
}

} // namespace kcdmp::anchor
