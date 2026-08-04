#include "lua_closure.h"
#include "log.h"

#include <windows.h>
#include <cstdio>

namespace kcdmp::luaintrospect {

namespace {

// Every __try-containing function here holds no C++ objects with
// destructors, same rule rttr_abi.cpp documents: __try/__except cannot
// coexist with unwinding in the same frame (C2712). All results come back
// through POD out-params; std::string construction happens only in
// resolve(), which itself contains no __try.

bool read_u64_raw(uint64_t addr, uint64_t* out) {
    __try {
        *out = *reinterpret_cast<const uint64_t*>(static_cast<uintptr_t>(addr));
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

// Bounded, SEH-guarded C-string read into a fixed buffer. Stops at bufLen-1
// or the first non-printable byte -- a wrong pointer landing in binary data
// should read as "not resolved", not produce a plausible-looking garbage
// string. Returns false (and leaves out untouched) on any failure.
bool read_cstring_raw(uint64_t addr, char* out, size_t bufLen) {
    __try {
        const char* p = reinterpret_cast<const char*>(static_cast<uintptr_t>(addr));
        for (size_t i = 0; i + 1 < bufLen; ++i) {
            char c = p[i];
            if (c == '\0') {
                if (i == 0) return false;
                out[i] = '\0';
                return true;
            }
            if (c < 0x20 || c > 0x7E) return false;
            out[i] = c;
        }
        return false; // never terminated within bound
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool read_bytes_raw(uint64_t addr, unsigned char* out, size_t n) {
    __try {
        const auto* bytes = reinterpret_cast<const unsigned char*>(static_cast<uintptr_t>(addr));
        for (size_t i = 0; i < n; ++i) out[i] = bytes[i];
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

struct RawResult {
    bool ok = false;
    uint64_t descriptor = 0;
    uint64_t nativeAddr = 0;
    char name[97] = {};
    char modulePath[MAX_PATH] = {};
    uint32_t rva = 0;
    unsigned char prologue[48] = {};
    bool havePrologue = false;
};

RawResult resolve_raw(uint64_t closure_addr) {
    RawResult r;
    if (!closure_addr) return r;

    if (!read_u64_raw(closure_addr + 0x28, &r.descriptor) || !r.descriptor) return r;
    if (!read_u64_raw(r.descriptor + 0x28, &r.nativeAddr) || !r.nativeAddr) return r;

    // descriptor+0x40: try as a pointer-to-string first (the typical
    // layout); WO-18's doc didn't specify which, so both are tried.
    uint64_t namePtr = 0;
    if (read_u64_raw(r.descriptor + 0x40, &namePtr) && namePtr) {
        read_cstring_raw(namePtr, r.name, sizeof(r.name));
    }
    if (r.name[0] == '\0') {
        read_cstring_raw(r.descriptor + 0x40, r.name, sizeof(r.name));
    }

    // Which module does nativeAddr live in? Strongest corroborating
    // evidence available: a plausible name string can happen by luck,
    // landing inside CryAISystem.dll at a real RVA cannot.
    HMODULE hmod = nullptr;
    if (GetModuleHandleExA(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCSTR>(static_cast<uintptr_t>(r.nativeAddr)), &hmod) && hmod) {
        GetModuleFileNameA(hmod, r.modulePath, MAX_PATH);
        r.rva = static_cast<uint32_t>(r.nativeAddr - reinterpret_cast<uint64_t>(hmod));
    }

    // First 48 bytes of the callback's own prologue, captured for the same
    // manual-decoding approach NATIVE-PLUGIN-findings.md already used for
    // the RTTR ABI -- not disassembled here, just read out safely.
    r.havePrologue = read_bytes_raw(r.nativeAddr, r.prologue, sizeof(r.prologue));

    r.ok = true;
    return r;
}

} // namespace

ClosureInfo resolve(uint64_t closure_addr) {
    const RawResult r = resolve_raw(closure_addr);

    ClosureInfo info;
    info.ok         = r.ok;
    info.descriptor = r.descriptor;
    info.nativeAddr = r.nativeAddr;
    info.name       = r.name;
    info.rva        = r.rva;

    if (r.modulePath[0]) {
        std::string full(r.modulePath);
        const auto pos = full.find_last_of("\\/");
        info.moduleName = (pos == std::string::npos) ? full : full.substr(pos + 1);
    }

    if (r.havePrologue) {
        char hex[3 * 48 + 1] = {};
        int n = 0;
        for (int i = 0; i < 48; ++i) {
            n += sprintf_s(hex + n, sizeof(hex) - n, "%02X", r.prologue[i]);
        }
        info.prologueHex = hex;
    }

    if (info.ok) {
        logf("LUACLOSURE: descriptor=%p native=%p module=%s+0x%X name=%s",
             reinterpret_cast<void*>(info.descriptor), reinterpret_cast<void*>(info.nativeAddr),
             info.moduleName.c_str(), info.rva, info.name.c_str());
    } else {
        logf("LUACLOSURE: resolve failed for closure=%p", reinterpret_cast<void*>(closure_addr));
    }
    return info;
}

} // namespace kcdmp::luaintrospect
