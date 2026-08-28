// WO-72 experiment -- NOT product code. Lives under native/experiments/ and is
// never shipped or installed.
//
// Purpose: WO-71 established that `-dedicated` skips renderer creation cleanly
// and that the first thing to die is CryAnimation's character-manager init,
// which does an unconditional `if (!pSystem->GetIRenderer()) CryFatalError(...)`
// (CryAnimation.dll +0xAF900). The open question is how many *more* consumers
// sit behind that one. Guessing is worthless; measuring is cheap.
//
// This DLL has two modes, selected by the KCDMP_WO72_MODE environment variable:
//
//   MODE=scan   Passive. Waits for CryRenderD3D12.dll to exist (i.e. a normal,
//               non-dedicated launch), then walks gEnv looking for the slot
//               that holds a pointer to an object whose vtable lives inside
//               CryRenderD3D12's image. That slot *is* gEnv->pRenderer, and
//               this settles it empirically instead of trusting a vtable dump.
//               Writes nothing.
//
//   MODE=stub   Active. On a `-dedicated` launch, waits until CryAnimation.dll
//               is loaded (which happens after the renderer step and before the
//               character-manager init that fatals), then writes a stub
//               IRenderer into gEnv->pRenderer. Every stub vtable slot is a
//               distinct thunk that records "slot N was called" and returns 0.
//               The log then names exactly which IRenderer methods a headless
//               boot actually needs, in call order.
//
// The stub deliberately does nothing useful. A slot that returns 0 where the
// caller needs a real object will crash -- that is the intended signal, and the
// log's last lines say which slot it was.

#include <windows.h>
#include <psapi.h>

#include <cstdint>
#include <cstdio>
#include <cstdarg>
#include <share.h>

namespace {

// ---------------------------------------------------------------- logging

CRITICAL_SECTION g_logLock;
FILE*            g_log = nullptr;

void log_open() {
    InitializeCriticalSection(&g_logLock);
    char path[MAX_PATH]{};
    // Next to the game executable's *working directory* (the install root),
    // which is where kcd.log already lands.
    GetCurrentDirectoryA(MAX_PATH, path);
    strncat_s(path, "\\wo72-nullrenderer.log", _TRUNCATE);
    // _fsopen with _SH_DENYWR: the game holds this open for the whole run and a
    // plain fopen locks readers out, which makes live tailing impossible.
    g_log = _fsopen(path, "w", _SH_DENYWR);
}

void logf(const char* fmt, ...) {
    if (!g_log) return;
    EnterCriticalSection(&g_logLock);
    SYSTEMTIME t{};
    GetLocalTime(&t);
    fprintf(g_log, "[%02d:%02d:%02d.%03d] ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
    va_list a;
    va_start(a, fmt);
    vfprintf(g_log, fmt, a);
    va_end(a);
    fputc('\n', g_log);
    fflush(g_log);  // a fatal error is the expected ending; never buffer
    LeaveCriticalSection(&g_logLock);
}

// ---------------------------------------------------------------- gEnv

// CrySystem.dll RVA of the `gEnv` global, recovered in WO-71 (findings §5).
// Modding Tools build only; retail is a different binary (WO-67).
constexpr uintptr_t kGEnvRva = 0x637260;

// Byte offsets inside SSystemGlobalEnvironment that WO-71 pinned by use site.
constexpr uintptr_t kEnvDedicated = 0x3d4;  // gEnv->bDedicated
constexpr uintptr_t kEnvEditor    = 0x3d2;  // gEnv->bEditor

// How far to walk gEnv when scanning. The flag block sits at +0x3d0, so the
// struct is at least that big; 0x600 covers it with margin.
constexpr size_t kEnvScanBytes = 0x600;

HMODULE wait_for_module(const char* name, DWORD timeoutMs) {
    const DWORD deadline = GetTickCount() + timeoutMs;
    for (;;) {
        HMODULE h = GetModuleHandleA(name);
        if (h) return h;
        if (GetTickCount() > deadline) return nullptr;
        Sleep(1);
    }
}

uintptr_t* gEnv_slot(HMODULE crySystem) {
    return reinterpret_cast<uintptr_t*>(reinterpret_cast<uintptr_t>(crySystem) + kGEnvRva);
}

bool module_range(HMODULE h, uintptr_t& lo, uintptr_t& hi) {
    MODULEINFO mi{};
    if (!GetModuleInformation(GetCurrentProcess(), h, &mi, sizeof(mi))) return false;
    lo = reinterpret_cast<uintptr_t>(mi.lpBaseOfDll);
    hi = lo + mi.SizeOfImage;
    return true;
}

// Name whichever loaded module an address falls inside. Cheap and good enough:
// we only care about attributing vtable pointers.
bool owning_module(uintptr_t addr, char* out, size_t outLen) {
    HMODULE mods[512];
    DWORD needed = 0;
    if (!EnumProcessModules(GetCurrentProcess(), mods, sizeof(mods), &needed)) return false;
    const size_t count = needed / sizeof(HMODULE);
    for (size_t i = 0; i < count; ++i) {
        uintptr_t lo = 0, hi = 0;
        if (!module_range(mods[i], lo, hi)) continue;
        if (addr >= lo && addr < hi) {
            char full[MAX_PATH]{};
            GetModuleBaseNameA(GetCurrentProcess(), mods[i], full, MAX_PATH);
            strncpy_s(out, outLen, full, _TRUNCATE);
            return true;
        }
    }
    return false;
}

bool readable(const void* p, size_t n) {
    MEMORY_BASIC_INFORMATION mbi{};
    if (!VirtualQuery(p, &mbi, sizeof(mbi))) return false;
    if (mbi.State != MEM_COMMIT) return false;
    const DWORD ok = PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY
                   | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
    if (!(mbi.Protect & ok)) return false;
    const uintptr_t end = reinterpret_cast<uintptr_t>(mbi.BaseAddress) + mbi.RegionSize;
    return reinterpret_cast<uintptr_t>(p) + n <= end;
}

// ---------------------------------------------------------------- stub

// Sized well above any plausible IRenderer vtable so an out-of-range slot call
// is impossible. Costs 8 KB of pointers; irrelevant.
constexpr int kStubSlots = 1024;

void*         g_stubVtbl[kStubSlots];
void*         g_stubObject[4] = { g_stubVtbl, nullptr, nullptr, nullptr };
volatile LONG g_slotCalls[kStubSlots];
volatile LONG g_callOrder = 0;

// Slots listed in KCDMP_WO72_RETURN_SELF return the stub object itself instead
// of 0. That is how we walk past `p = pRenderer->GetThing(); p->Method();`
// chains: the returned "thing" is another logging stub rather than a null
// deref. Off by default because a method that really returns an integer would
// then return a huge value, which can be worse than 0.
bool g_returnSelf[kStubSlots];

// Rolling record of the last calls, dumped when we fault, so a crash names the
// slot it came from instead of vanishing.
constexpr int kTraceLen = 32;
volatile LONG g_tracePos = 0;
int           g_trace[kTraceLen];

// One distinct thunk per slot. Four pointer parameters, because Win64 passes
// the first four arguments in RCX/RDX/R8/R9 and this captures them for the log;
// the caller cleans the stack, so a method that really takes more arguments is
// still called safely, we just do not see the stack ones. Integer and pointer
// returns come back in RAX, so returning nullptr reads as 0 / NULL / false.
// Float-returning and struct-by-value-returning methods are NOT modelled -- if
// one is hit the log shows the slot, and the misbehaviour is itself the finding.
template <int Slot>
void* stub_thunk(void* /*self*/, void* a1, void* a2, void* a3) {
    const LONG pos = InterlockedIncrement(&g_tracePos) - 1;
    g_trace[pos % kTraceLen] = Slot;
    if (InterlockedIncrement(&g_slotCalls[Slot]) == 1) {
        logf("IRenderer slot %4d (vtbl +0x%03X) first call  [order %ld]  "
             "args %p %p %p%s",
             Slot, Slot * 8, pos + 1, a1, a2, a3,
             g_returnSelf[Slot] ? "  -> returning stub self" : "");
    }
    return g_returnSelf[Slot] ? reinterpret_cast<void*>(g_stubObject) : nullptr;
}

LONG CALLBACK on_exception(EXCEPTION_POINTERS* ep) {
    const DWORD code = ep->ExceptionRecord->ExceptionCode;
    // Ignore the noisy, benign ones the engine raises on purpose.
    if (code == 0x406D1388 /* thread-name */ || code == DBG_PRINTEXCEPTION_C
        || code == DBG_PRINTEXCEPTION_WIDE_C) {
        return EXCEPTION_CONTINUE_SEARCH;
    }
    static volatile LONG once = 0;
    if (InterlockedIncrement(&once) != 1) return EXCEPTION_CONTINUE_SEARCH;

    const uintptr_t at = reinterpret_cast<uintptr_t>(ep->ExceptionRecord->ExceptionAddress);
    char owner[MAX_PATH]{};
    uintptr_t lo = 0, hi = 0;
    HMODULE h = nullptr;
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
                           | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           reinterpret_cast<LPCSTR>(at), &h) && h) {
        GetModuleBaseNameA(GetCurrentProcess(), h, owner, MAX_PATH);
        module_range(h, lo, hi);
    }
    logf("*** EXCEPTION 0x%08lX at %p  (%s +0x%llX)", code, (void*)at,
         owner[0] ? owner : "?", (unsigned long long)(lo ? at - lo : 0));
    if (code == EXCEPTION_ACCESS_VIOLATION) {
        logf("    access %s address %p",
             ep->ExceptionRecord->ExceptionInformation[0] ? "WRITE" : "READ",
             (void*)ep->ExceptionRecord->ExceptionInformation[1]);
    }
    const LONG n = g_tracePos;
    char line[512]{};
    int  used = 0;
    for (LONG i = (n > kTraceLen ? n - kTraceLen : 0); i < n; ++i) {
        used += _snprintf_s(line + used, sizeof(line) - used, _TRUNCATE, "%d ",
                            g_trace[i % kTraceLen]);
    }
    logf("    last slots called (oldest first): %s", line);

    // Poor-man's backtrace. x64 has no frame pointer to follow and StackWalk64
    // needs symbols we do not have, so instead scan the raw stack for values
    // that land inside a loaded module's image and print them in order. There
    // are false positives (any stack-resident pointer looks like a return
    // address), but the real caller chain is in there and module+RVA is enough
    // to identify a function in Ghidra.
    {
        const CONTEXT* c = ep->ContextRecord;
        logf("    RAX=%016llX RCX=%016llX RDX=%016llX R8=%016llX",
             (unsigned long long)c->Rax, (unsigned long long)c->Rcx,
             (unsigned long long)c->Rdx, (unsigned long long)c->R8);
        logf("    RBX=%016llX RSI=%016llX RDI=%016llX R9=%016llX",
             (unsigned long long)c->Rbx, (unsigned long long)c->Rsi,
             (unsigned long long)c->Rdi, (unsigned long long)c->R9);
    }
    logf("    stack scan (candidate return addresses, innermost first):");
    const uintptr_t rsp = static_cast<uintptr_t>(ep->ContextRecord->Rsp);
    int printed = 0;
    for (int i = 0; i < 2048 && printed < 40; ++i) {
        const uintptr_t* p = reinterpret_cast<const uintptr_t*>(rsp + i * 8);
        if (!readable(p, 8)) break;
        const uintptr_t v = *p;
        if (v < 0x10000) continue;
        HMODULE mh = nullptr;
        if (!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
                                | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                reinterpret_cast<LPCSTR>(v), &mh) || !mh) continue;
        MEMORY_BASIC_INFORMATION mbi{};
        if (!VirtualQuery(reinterpret_cast<void*>(v), &mbi, sizeof(mbi))) continue;
        const DWORD exec = PAGE_EXECUTE | PAGE_EXECUTE_READ
                         | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
        if (!(mbi.Protect & exec)) continue;  // only code addresses
        char nm[MAX_PATH]{};
        GetModuleBaseNameA(GetCurrentProcess(), mh, nm, MAX_PATH);
        uintptr_t mlo = 0, mhi = 0;
        module_range(mh, mlo, mhi);
        logf("      [rsp+0x%04X] %s +0x%llX", i * 8, nm,
             (unsigned long long)(v - mlo));
        ++printed;
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

// A 1024-wide fold expression or linear recursion blows MSVC's parser
// (`fatal error C1026: parser stack overflow`). Split the range in half
// instead, so instantiation depth is log2(kStubSlots) = 10.
template <int Lo, int Count>
struct FillRange {
    static void go() {
        FillRange<Lo, Count / 2>::go();
        FillRange<Lo + Count / 2, Count - Count / 2>::go();
    }
};
template <int Lo>
struct FillRange<Lo, 1> {
    static void go() { g_stubVtbl[Lo] = reinterpret_cast<void*>(&stub_thunk<Lo>); }
};
template <int Lo>
struct FillRange<Lo, 0> {
    static void go() {}
};

void fill_vtbl() { FillRange<0, kStubSlots>::go(); }

// --------------------------------------------------- gEnv slot census

// Log every pointer-sized slot in gEnv with the module that owns whatever it
// points at. Run this in both configurations at a comparable point and diff:
// the slots that are non-null in a normal boot and null under -dedicated are
// exactly the things the dedicated path never sets up. That turns "guess which
// pointer is null" into a list.
void dump_env_slots(uintptr_t env, const char* tag) {
    logf("--- gEnv slot census (%s) ---", tag);
    int nulls = 0;
    for (uintptr_t off = 0; off < 0x3d0; off += 8) {
        if (!readable(reinterpret_cast<void*>(env + off), 8)) continue;
        const uintptr_t v = *reinterpret_cast<uintptr_t*>(env + off);
        if (v == 0) { ++nulls; logf("  +0x%03llX  NULL", (unsigned long long)off); continue; }
        if (v < 0x10000) continue;  // small integers living in the struct
        char owner[MAX_PATH]{};
        // Attribute by the object's vtable, which is what identifies its class.
        const char* how = "ptr";
        uintptr_t probe = v;
        if (readable(reinterpret_cast<void*>(v), 8)) {
            const uintptr_t vptr = *reinterpret_cast<uintptr_t*>(v);
            if (owning_module(vptr, owner, sizeof(owner))) { probe = vptr; how = "vtable in"; }
        }
        if (!owner[0]) owning_module(probe, owner, sizeof(owner));
        logf("  +0x%03llX  %p  %s %s", (unsigned long long)off, (void*)v, how,
             owner[0] ? owner : "heap/unknown");
    }
    logf("--- end census (%s): %d null slots ---", tag, nulls);
}

uintptr_t g_censusEnv = 0;
DWORD WINAPI census_thread(LPVOID) {
    if (wait_for_module("XGenAIModule.dll", 120000)) Sleep(2000);
    dump_env_slots(g_censusEnv, "dedicated + stub");
    return 0;
}

// ------------------------------------------------------- missing cvars

// gEnv->pConsole. Pinned in WO-71 by use site: CrySystem reads gEnv+0xa8 and
// calls GetCVar at vtbl+0xb8 on it, the same object CSystem reaches through
// its own m_env copy at CSystem+0xe8.
constexpr uintptr_t kEnvConsole = 0xa8;

// IConsole vtable slots, read off CSystem::CreateSystemVars (@0x180208980):
//   +0x10 RegisterString(name, value, flags, help, onChange)
//   +0x18 RegisterInt   (name, value, flags, help, onChange)
//   +0x28 RegisterFloat (name, value, flags, help, onChange)
//   +0xb8 GetCVar(name)
using RegisterIntFn   = void*(__fastcall*)(void*, const char*, int, int, const char*, void*, bool);
using RegisterFloatFn = void*(__fastcall*)(void*, const char*, float, int, const char*, void*, bool);
using GetCVarFn       = void*(__fastcall*)(void*, const char*);

// The renderer module registers these. With no renderer they never exist, and
// CrySystem's spec auto-detect (FUN_18008f400) caches the lookup result once
// and then calls Set() on it unconditionally -- a null deref at
// CrySystem+0x8F5D6. Registering them ourselves, before that cache is primed,
// gives it something valid to write to.
void register_missing_renderer_cvars(uintptr_t env) {
    void* console = *reinterpret_cast<void**>(env + kEnvConsole);
    if (!console) { logf("gEnv->pConsole is null; cannot register cvars"); return; }
    void** vt = *reinterpret_cast<void***>(console);
    auto regInt   = reinterpret_cast<RegisterIntFn>(vt[0x18 / 8]);
    auto regFloat = reinterpret_cast<RegisterFloatFn>(vt[0x28 / 8]);
    auto getCVar  = reinterpret_cast<GetCVarFn>(vt[0xb8 / 8]);

    static const char* kInts[] = {
        "r_SuperResolution_Mode",
        "r_SuperResolution_NVIDIA_DLSS_QualityMode",
        "r_SuperResolution_AMD_FSR_QualityMode",
        "r_SuperResolution_INTEL_XeSS_QualityMode",
        "r_SuperResolution_QCOM_SGSR_QualityMode",
    };
    for (const char* n : kInts) {
        if (getCVar(console, n)) { logf("cvar %s already exists", n); continue; }
        void* c = regInt(console, n, 0, 0, "WO-72 stand-in for a renderer cvar", nullptr, true);
        logf("registered int cvar %s -> %p", n, c);
    }
    static const char* kFloats[] = {
        "r_SuperResolution_Sharpness",
        "r_SuperResolution_TextureMipBias",
    };
    for (const char* n : kFloats) {
        if (getCVar(console, n)) { logf("cvar %s already exists", n); continue; }
        void* c = regFloat(console, n, 0.0f, 0, "WO-72 stand-in for a renderer cvar", nullptr, true);
        logf("registered float cvar %s -> %p", n, c);
    }
}

// ---------------------------------------------------------------- modes

void mode_scan(HMODULE crySystem) {
    logf("MODE=scan -- looking for the gEnv slot that holds the renderer");

    HMODULE ren = wait_for_module("CryRenderD3D12.dll", 120000);
    if (!ren) { logf("CryRenderD3D12.dll never loaded; is this a -dedicated run?"); return; }
    uintptr_t rlo = 0, rhi = 0;
    if (!module_range(ren, rlo, rhi)) { logf("GetModuleInformation failed"); return; }
    logf("CryRenderD3D12.dll image %p..%p", (void*)rlo, (void*)rhi);

    uintptr_t* slot = gEnv_slot(crySystem);
    // Give the renderer time to be constructed and stored.
    for (int i = 0; i < 60000 && *slot == 0; ++i) Sleep(1);
    const uintptr_t env = *slot;
    if (!env) { logf("gEnv still null after 60s"); return; }
    logf("gEnv = %p  (CrySystem base %p + 0x%llX)", (void*)env, (void*)crySystem,
         (unsigned long long)kGEnvRva);
    logf("gEnv->bDedicated(+0x3d4) = %d   gEnv->bEditor(+0x3d2) = %d",
         *reinterpret_cast<unsigned char*>(env + kEnvDedicated),
         *reinterpret_cast<unsigned char*>(env + kEnvEditor));

    // Poll: the renderer pointer is stored partway through init, so re-scan
    // until it shows up rather than sampling once.
    for (int attempt = 0; attempt < 120; ++attempt) {
        bool found = false;
        for (uintptr_t off = 0; off + 8 <= kEnvScanBytes; off += 8) {
            if (!readable(reinterpret_cast<void*>(env + off), 8)) continue;
            const uintptr_t val = *reinterpret_cast<uintptr_t*>(env + off);
            if (val < 0x10000) continue;
            if (!readable(reinterpret_cast<void*>(val), 8)) continue;
            const uintptr_t vptr = *reinterpret_cast<uintptr_t*>(val);
            if (vptr >= rlo && vptr < rhi) {
                char owner[MAX_PATH]{};
                owning_module(val, owner, sizeof(owner));
                logf("HIT gEnv+0x%03llX -> object %p, vtable %p in CryRenderD3D12"
                     "  (object memory owned by: %s)",
                     (unsigned long long)off, (void*)val, (void*)vptr,
                     owner[0] ? owner : "heap");
                found = true;
            }
        }
        if (found) {
            if (wait_for_module("XGenAIModule.dll", 120000)) { Sleep(2000); dump_env_slots(env, "normal boot"); }
            logf("scan complete"); return;
        }
        Sleep(250);
    }
    logf("no gEnv slot pointed into CryRenderD3D12 within 30s");
}

void mode_stub(HMODULE crySystem, uintptr_t rendererOffset) {
    AddVectoredExceptionHandler(1, on_exception);
    {
        // KCDMP_WO72_RETURN_SELF="310,338" -- slots whose result is another
        // object the caller will call through. Discovered one crash at a time.
        char sel[512]{};
        GetEnvironmentVariableA("KCDMP_WO72_RETURN_SELF", sel, sizeof(sel));
        if (_stricmp(sel, "all") == 0) {
            for (int i = 0; i < kStubSlots; ++i) g_returnSelf[i] = true;
            logf("every slot will return the stub object (RETURN_SELF=all)");
            sel[0] = 0;
        }
        for (char* tok = sel; *tok;) {
            char* end = nullptr;
            const long v = strtol(tok, &end, 0);
            if (end == tok) break;
            if (v >= 0 && v < kStubSlots) { g_returnSelf[v] = true; logf("slot %ld will return the stub object", v); }
            tok = (*end == ',') ? end + 1 : end;
            while (*tok == ' ' || *tok == ',') ++tok;
        }
    }
    logf("MODE=stub -- will install a logging stub at gEnv+0x%llX",
         (unsigned long long)rendererOffset);
    fill_vtbl();
    logf("stub object %p, vtable %p, %d slots", (void*)g_stubObject, (void*)g_stubVtbl, kStubSlots);

    uintptr_t* slot = gEnv_slot(crySystem);
    for (int i = 0; i < 60000 && *slot == 0; ++i) Sleep(1);
    const uintptr_t env = *slot;
    if (!env) { logf("gEnv still null after 60s -- aborting, wrote nothing"); return; }
    logf("gEnv = %p", (void*)env);
    logf("gEnv->bDedicated(+0x3d4) = %d", *reinterpret_cast<unsigned char*>(env + kEnvDedicated));

    // Do this before the window opens: CrySystem primes its cached ICVar*
    // pointers once, and a null cached there is permanent.
    register_missing_renderer_cvars(env);

    // CryAnimation.dll loads at "Initializing Animation System", which is after
    // the renderer step (so InitRenderer has already taken its dedicated
    // early-out and will not try to call Init on our stub) and before the
    // character-manager init that fatals. That is the window.
    if (!wait_for_module("CryAnimation.dll", 120000)) {
        logf("CryAnimation.dll never loaded -- aborting, wrote nothing");
        return;
    }
    logf("CryAnimation.dll loaded; window open");

    uintptr_t* pRenderer = reinterpret_cast<uintptr_t*>(env + rendererOffset);
    if (!readable(pRenderer, 8)) { logf("gEnv+0x%llX not readable -- aborting",
                                        (unsigned long long)rendererOffset); return; }
    const uintptr_t existing = *pRenderer;
    if (existing != 0) {
        logf("gEnv+0x%llX is already %p (non-null) -- refusing to overwrite",
             (unsigned long long)rendererOffset, (void*)existing);
        return;
    }
    *pRenderer = reinterpret_cast<uintptr_t>(g_stubObject);
    logf("installed stub at gEnv+0x%llX", (unsigned long long)rendererOffset);
    g_censusEnv = env;
    CreateThread(nullptr, 0, census_thread, nullptr, 0, nullptr);

    // The scan found a SECOND renderer-owned object at gEnv+0x110 (heap, vtable
    // in CryRenderD3D12) -- almost certainly the aux-geom interface. Anything
    // listed in KCDMP_WO72_EXTRA_OFFSETS gets the same stub.
    char extra[256]{};
    GetEnvironmentVariableA("KCDMP_WO72_EXTRA_OFFSETS", extra, sizeof(extra));
    for (char* tok = extra; *tok;) {
        char* end = nullptr;
        const unsigned long long off = strtoull(tok, &end, 0);
        if (end == tok) break;
        uintptr_t* q = reinterpret_cast<uintptr_t*>(env + off);
        if (readable(q, 8) && *q == 0) {
            *q = reinterpret_cast<uintptr_t>(g_stubObject);
            logf("installed stub at gEnv+0x%llX", off);
        } else {
            logf("gEnv+0x%llX not null or not readable (%p); left alone", off,
                 readable(q, 8) ? (void*)*q : nullptr);
        }
        tok = (*end == ',') ? end + 1 : end;
        while (*tok == ' ' || *tok == ',') ++tok;
    }
}

DWORD WINAPI worker(LPVOID) {
    log_open();
    logf("WO-72 probe attached, pid %lu", GetCurrentProcessId());

    HMODULE crySystem = wait_for_module("CrySystem.dll", 120000);
    if (!crySystem) { logf("CrySystem.dll never loaded"); return 0; }
    logf("CrySystem.dll at %p", (void*)crySystem);

    char mode[32]{};
    GetEnvironmentVariableA("KCDMP_WO72_MODE", mode, sizeof(mode));
    char offs[32]{};
    GetEnvironmentVariableA("KCDMP_WO72_RENDERER_OFFSET", offs, sizeof(offs));

    if (_stricmp(mode, "stub") == 0) {
        if (!offs[0]) {
            logf("KCDMP_WO72_RENDERER_OFFSET not set -- run MODE=scan first. Aborting.");
            return 0;
        }
        mode_stub(crySystem, strtoull(offs, nullptr, 0));
    } else {
        mode_scan(crySystem);
    }
    return 0;
}

}  // namespace

BOOL APIENTRY DllMain(HMODULE self, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(self);
        CreateThread(nullptr, 0, worker, nullptr, 0, nullptr);
    }
    return TRUE;
}
