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
#include <dxgi.h>

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
// gEnv->pConsole. Pinned in WO-71 by use site: CrySystem reads gEnv+0xa8 and
// calls GetCVar at vtbl+0xb8 on it, the same object CSystem reaches through
// its own m_env copy at CSystem+0xe8.
constexpr uintptr_t kEnvConsole   = 0xa8;

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
// Engine code does `obj = pRenderer->CreateThing(); obj->field_0x240 = 1.0f;`
// with no null check on the write (Cry3DEngine FUN_1801317a0 does exactly that).
// So the object handed back has to be big enough to absorb field writes at
// arbitrary offsets. 64 KB of zeroes with the vtable pointer at +0 costs
// nothing and stops a returned stub from corrupting the heap.
constexpr size_t kStubObjectBytes = 64 * 1024;
void*         g_stubObject[kStubObjectBytes / sizeof(void*)] = { g_stubVtbl };

// Returning ONE shared buffer for every getter makes unrelated "objects" alias
// each other, and the engine then corrupts its own state through us. Hand out a
// distinct zeroed block per call instead, bump-allocated from a fixed arena,
// each with the stub vtable at +0 and 16 bytes of slack below it so a
// CryString-style read at ptr-12 lands inside the arena rather than at -12.
constexpr size_t kArenaBytes = 32 * 1024 * 1024;
constexpr size_t kArenaBlock = 4096;
char*         g_arena = nullptr;
volatile LONG g_arenaNext = 0;

void* fresh_stub_object() {
    if (!g_arena) return g_stubObject;
    const LONG i = InterlockedIncrement(&g_arenaNext) - 1;
    if (static_cast<size_t>(i + 1) * kArenaBlock + 64 >= kArenaBytes) return g_stubObject;
    char* base = g_arena + static_cast<size_t>(i) * kArenaBlock + 32;
    *reinterpret_cast<void**>(base) = g_stubVtbl;
    return base;
}
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
    return g_returnSelf[Slot] ? fresh_stub_object() : nullptr;
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

// gEnv points at CSystem::m_env, which sits at CSystem+0x40: CrySystem reads
// pConsole as gEnv+0xa8 and as CSystem+0xe8 for the same object, so the member
// is 0x40 into the object. Validated at runtime by checking that CSystem+0x148
// (m_env.pRenderer, the field OpenRenderLibrary null-checks) holds the stub we
// just installed.
constexpr uintptr_t kEnvOffsetInCSystem = 0x40;

// The gEnv census misses anything the dedicated path skips that lives on
// CSystem rather than in gEnv -- the default font (CSystem+0xE70) being the
// obvious one, since CSystem::Init only creates it when !bDedicated. Same diff
// trick, wider window.
void dump_csystem_slots(uintptr_t env, const char* tag) {
    const uintptr_t sys = env - kEnvOffsetInCSystem;
    logf("--- CSystem slot census (%s), CSystem=%p ---", tag, (void*)sys);
    for (uintptr_t off = 0; off < 0x1200; off += 8) {
        if (!readable(reinterpret_cast<void*>(sys + off), 8)) continue;
        const uintptr_t v = *reinterpret_cast<uintptr_t*>(sys + off);
        if (v == 0) { logf("  CS+0x%04llX  NULL", (unsigned long long)off); continue; }
        if (v < 0x10000) continue;
        if (!readable(reinterpret_cast<void*>(v), 8)) continue;
        char owner[MAX_PATH]{};
        const uintptr_t vptr = *reinterpret_cast<uintptr_t*>(v);
        if (!owning_module(vptr, owner, sizeof(owner))) continue;  // objects only
        logf("  CS+0x%04llX  %p  vtable in %s", (unsigned long long)off, (void*)v, owner);
    }
    logf("--- end CSystem census (%s) ---", tag);
}

// The fault is `mov rcx,[rax+0x1A0]; mov rax,[rcx]` where RAX came from
// wh::GetGameIface(). So the null lives in Warhorse's own game-interface
// aggregate, not in gEnv. Same diff trick, third struct.
void dump_gameiface(const char* tag) {
    HMODULE shared = GetModuleHandleA("Shared.dll");
    if (!shared) { logf("Shared.dll not loaded; no game interface census"); return; }
    auto get = reinterpret_cast<void*(*)()>(GetProcAddress(
        shared, "?GetGameIface@wh@@YAPEBVC_GameInterface@shared@1@XZ"));
    if (!get) { logf("GetGameIface not exported as expected"); return; }
    const uintptr_t gi = reinterpret_cast<uintptr_t>(get());
    logf("--- C_GameInterface census (%s), iface=%p ---", tag, (void*)gi);
    if (!gi) { logf("  game interface is null"); return; }
    for (uintptr_t off = 0; off < 0x400; off += 8) {
        if (!readable(reinterpret_cast<void*>(gi + off), 8)) continue;
        const uintptr_t v = *reinterpret_cast<uintptr_t*>(gi + off);
        if (v == 0) { logf("  GI+0x%03llX  NULL", (unsigned long long)off); continue; }
        if (v < 0x10000 || !readable(reinterpret_cast<void*>(v), 8)) continue;
        char owner[MAX_PATH]{};
        if (!owning_module(*reinterpret_cast<uintptr_t*>(v), owner, sizeof(owner))) continue;
        logf("  GI+0x%03llX  %p  vtable in %s", (unsigned long long)off, (void*)v, owner);
    }
    logf("--- end C_GameInterface census (%s) ---", tag);
}

uintptr_t g_censusEnv = 0;
DWORD WINAPI census_thread(LPVOID) {
    if (wait_for_module("XGenAIModule.dll", 120000)) Sleep(2000);
    dump_env_slots(g_censusEnv, "dedicated + stub");
    dump_csystem_slots(g_censusEnv, "dedicated + stub");
    dump_gameiface("dedicated + stub");
    return 0;
}

// ------------------------------------------------------- WARP (CPU only)

// The point of a headless host is to run on a server VM with no GPU. There are
// two ways to get there:
//
//   1. No renderer at all (the -dedicated branch). Needs a null IRenderer, and
//      blocker 4 shows how big that job really is.
//   2. A REAL renderer on a SOFTWARE device. D3D12's WARP adapter is a CPU
//      rasteriser; it reports feature level 12_1, which is what KCD2's own GPU
//      gate demands ("A GPU with support for D3D FeatureLevel 12.0 is
//      required"), and r_HeadlessStartup covers having no display attached.
//
// Route 2 needs no reverse engineering *on the target*: a GPU-less VM
// enumerates only the Microsoft Basic Render Driver (WARP), so the shipped
// adapter-picking code should select it unaided. This hook exists purely to
// prove that here, on a box that does have a GPU, before anyone provisions a
// VM: CryRenderD3D12 statically imports CreateDXGIFactory1 (IAT RVA 0x4B0FB8),
// so redirecting that one pointer lets us hand the renderer a factory whose
// adapter enumeration yields WARP and nothing else.
constexpr uintptr_t kCreateDXGIFactory1IatRva = 0x4B0FB8;

using PFN_CreateDXGIFactory1 = HRESULT(WINAPI*)(REFIID, void**);
using PFN_EnumAdapters1      = HRESULT(STDMETHODCALLTYPE*)(void*, UINT, void**);

PFN_CreateDXGIFactory1 g_realCreateFactory  = nullptr;
PFN_EnumAdapters1      g_realEnumAdapters1  = nullptr;

// IDXGIFactory1::EnumAdapters1 is vtable index 12
// (3 IUnknown + 4 IDXGIObject + 5 IDXGIFactory).
constexpr int kEnumAdapters1Slot = 12;
// IDXGIFactory4::EnumWarpAdapter is vtable index 27.
constexpr int kEnumWarpAdapterSlot = 27;

const GUID kIID_IDXGIFactory4 =
    { 0x1bc6ea02, 0xef36, 0x464f, { 0xbf, 0x0c, 0x21, 0xca, 0x39, 0xe5, 0x16, 0x8a } };
const GUID kIID_IDXGIAdapter1 =
    { 0x29038f61, 0x3839, 0x4626, { 0x91, 0xfd, 0x08, 0x68, 0x79, 0x01, 0x1a, 0x05 } };

bool patch_pointer(void* slot, void* value, void** previous) {
    DWORD old = 0;
    if (!VirtualProtect(slot, sizeof(void*), PAGE_READWRITE, &old)) return false;
    if (previous) *previous = *reinterpret_cast<void**>(slot);
    *reinterpret_cast<void**>(slot) = value;
    VirtualProtect(slot, sizeof(void*), old, &old);
    return true;
}

// Hand back the WARP adapter as adapter 0 and nothing else, so the renderer's
// "pick the first suitable adapter" loop can only choose the CPU rasteriser.
HRESULT STDMETHODCALLTYPE warp_EnumAdapters1(void* self, UINT index, void** ppAdapter) {
    if (index != 0) return DXGI_ERROR_NOT_FOUND;
    void* factory4 = nullptr;
    void** vt = *reinterpret_cast<void***>(self);
    using QIFn = HRESULT(STDMETHODCALLTYPE*)(void*, const GUID&, void**);
    const HRESULT hr = reinterpret_cast<QIFn>(vt[0])(self, kIID_IDXGIFactory4, &factory4);
    if (FAILED(hr) || !factory4) {
        logf("WARP: QueryInterface(IDXGIFactory4) failed hr=0x%08lX", hr);
        return DXGI_ERROR_NOT_FOUND;
    }
    void** vt4 = *reinterpret_cast<void***>(factory4);
    using EnumWarpFn = HRESULT(STDMETHODCALLTYPE*)(void*, const GUID&, void**);
    const HRESULT hr2 = reinterpret_cast<EnumWarpFn>(vt4[kEnumWarpAdapterSlot])(
        factory4, kIID_IDXGIAdapter1, ppAdapter);
    using ReleaseFn = ULONG(STDMETHODCALLTYPE*)(void*);
    reinterpret_cast<ReleaseFn>(vt4[2])(factory4);
    static bool logged = false;
    if (!logged) { logged = true; logf("WARP: EnumWarpAdapter -> hr=0x%08lX, adapter=%p",
                                       hr2, ppAdapter ? *ppAdapter : nullptr); }
    return hr2;
}

HRESULT WINAPI hooked_CreateDXGIFactory1(REFIID riid, void** ppFactory) {
    const HRESULT hr = g_realCreateFactory ? g_realCreateFactory(riid, ppFactory) : E_FAIL;
    if (SUCCEEDED(hr) && ppFactory && *ppFactory) {
        void** vt = *reinterpret_cast<void***>(*ppFactory);
        if (!g_realEnumAdapters1) {
            void* prev = nullptr;
            if (patch_pointer(&vt[kEnumAdapters1Slot],
                              reinterpret_cast<void*>(&warp_EnumAdapters1), &prev)) {
                g_realEnumAdapters1 = reinterpret_cast<PFN_EnumAdapters1>(prev);
                logf("WARP: patched IDXGIFactory1::EnumAdapters1 (was %p)", prev);
            } else {
                logf("WARP: could not patch the factory vtable");
            }
        }
    }
    return hr;
}

void install_warp_hook() {
    HMODULE ren = LoadLibraryA("CryRenderD3D12.dll");
    if (!ren) { logf("WARP: CryRenderD3D12.dll would not load"); return; }
    HMODULE dxgi = LoadLibraryA("dxgi.dll");
    g_realCreateFactory = reinterpret_cast<PFN_CreateDXGIFactory1>(
        GetProcAddress(dxgi, "CreateDXGIFactory1"));
    if (!g_realCreateFactory) { logf("WARP: no real CreateDXGIFactory1"); return; }

    void* slot = reinterpret_cast<void*>(
        reinterpret_cast<uintptr_t>(ren) + kCreateDXGIFactory1IatRva);
    void* prev = nullptr;
    if (patch_pointer(slot, reinterpret_cast<void*>(&hooked_CreateDXGIFactory1), &prev)) {
        logf("WARP: IAT patched at %p (was %p, real %p) -- renderer will get a "
             "software adapter", slot, prev, (void*)g_realCreateFactory);
    } else {
        logf("WARP: IAT patch failed");
    }
}

// ------------------------------------------- real (uninitialised) renderer

// Blocker 4 showed a stub cannot work: Cry3DEngine takes the result of
// EF_CreateInputShaderResource and CryString-assigns into it, which needs a
// *constructed* C++ object, not a zeroed buffer.
//
// But we do not have to fake one. `CD3D9Renderer` is a STATIC object inside
// CryRenderD3D12.dll -- the MODE=scan run found gEnv->pRenderer pointing at
// image+0x76B200, inside the DLL's own data, not the heap. Loading the DLL runs
// its static constructors, so the object and all its C++ members exist. What we
// must never do is call Init() (vtable slot 4), which is what creates the
// window and the D3D12 device.
//
// So: LoadLibrary the renderer, point gEnv->pRenderer at the real object, and
// selectively replace only the vtable slots that touch the device with logging
// thunks. That is a real renderer minus the hardware.
constexpr uintptr_t kRendererObjectRva = 0x76B200;
constexpr uintptr_t kRendererVtableRva = 0x50F5D0;

// A copy of the real vtable, so neutering a slot does not modify the DLL's
// read-only data (and does not affect any other instance).
void* g_realVtblCopy[kStubSlots];

uintptr_t install_real_renderer(uintptr_t env, uintptr_t rendererOffset, const char* neuterList) {
    HMODULE ren = LoadLibraryA("CryRenderD3D12.dll");
    if (!ren) { logf("real renderer: LoadLibraryA failed, err=%lu", GetLastError()); return 0; }
    const uintptr_t base = reinterpret_cast<uintptr_t>(ren);
    logf("real renderer: CryRenderD3D12.dll loaded at %p", (void*)base);

    const uintptr_t obj = base + kRendererObjectRva;
    const uintptr_t expectVtbl = base + kRendererVtableRva;
    if (!readable(reinterpret_cast<void*>(obj), 8)) {
        logf("real renderer: object address %p not readable", (void*)obj);
        return 0;
    }
    const uintptr_t vtbl = *reinterpret_cast<uintptr_t*>(obj);
    logf("real renderer: static object %p, its vptr=%p, expected %p -> %s",
         (void*)obj, (void*)vtbl, (void*)expectVtbl,
         vtbl == expectVtbl ? "CONSTRUCTED" : "NOT constructed by static init");
    if (vtbl != expectVtbl) return 0;

    // Copy the real vtable, then neuter the requested slots.
    for (int i = 0; i < kStubSlots; ++i) {
        const uintptr_t p = expectVtbl + static_cast<uintptr_t>(i) * 8;
        g_realVtblCopy[i] = readable(reinterpret_cast<void*>(p), 8)
                          ? *reinterpret_cast<void**>(p) : g_stubVtbl[i];
    }
    int neutered = 0;
    for (const char* tok = neuterList; tok && *tok;) {
        char* end = nullptr;
        const long v = strtol(tok, &end, 0);
        if (end == tok) break;
        if (v >= 0 && v < kStubSlots) {
            g_realVtblCopy[v] = g_stubVtbl[v];
            logf("real renderer: neutered slot %ld (vtbl +0x%lX)", v, v * 8);
            ++neutered;
        }
        tok = (*end == ',') ? end + 1 : end;
        while (*tok == ' ' || *tok == ',') ++tok;
    }
    // Init (slot 4) creates the window and device -- never let it run.
    g_realVtblCopy[4] = g_stubVtbl[4];
    logf("real renderer: slot 4 (Init) always neutered; %d extra neutered", neutered);

    *reinterpret_cast<uintptr_t*>(obj) = reinterpret_cast<uintptr_t>(g_realVtblCopy);
    *reinterpret_cast<uintptr_t*>(env + rendererOffset) = obj;
    logf("real renderer: installed at gEnv+0x%llX -> %p (vtable copy %p)",
         (unsigned long long)rendererOffset, (void*)obj, (void*)g_realVtblCopy);
    return obj;
}

// ------------------------------------------------- sv_AISystem enable

// WO-71 §5 noted that CSystem::Init's AI-system condition gains a
// gEnv->bDedicated term. The full condition also has an escape hatch:
//
//   !bSkipAI && !minimal && (!gEnv->bDedicated || !m_svAISystem
//                            || m_svAISystem->GetIVal() != 0)
//
// i.e. a dedicated server DOES initialise the AI system if the shipped cvar
// `sv_AISystem` is non-zero. Without it, gEnv/game-interface AI is never
// created and XGenAIModule's constructor dereferences the null.
//
// The catch: AI init is SystemInit.cpp:0xec8, which runs *before* CryAnimation
// loads, so a command-line `+sv_AISystem 1` and our own install point are both
// too late. Set it the moment gEnv->pConsole exists instead.
//
// ICVar vtable slots, read off the crashing spec-detect function
// (CrySystem FUN_18008f400) and the AI condition itself:
//   +0x10 GetIVal()   +0x38 Set(int)
using GetCVarFn = void*(__fastcall*)(void*, const char*);  // identical redeclaration below
using GetIValFn = int(__fastcall*)(void*);
using SetIntFn  = void(__fastcall*)(void*, int);

// Setting cvars from here rather than with `+name value` on the command line is
// not a stylistic choice: CryEngine applies command-line cvars LATE in
// CSystem::Init, after renderer init has already read them. That is why WO-53's
// `+r_Driver NULL` stored the value but booted D3D12 anyway, and why
// `+r_HeadlessStartup 1` shows `[DUMPTODISK, REQUIRE_APP_RESTART]` and changes
// nothing that run. Poking the cvar as soon as it is registered lands the value
// before the reader runs -- and, unlike a config-file edit, leaves the install
// untouched.
//
// KCDMP_WO72_EARLY_CVARS="sv_AISystem=1,r_HeadlessStartup=1,..."
DWORD WINAPI early_cvar_thread(LPVOID param) {
    const uintptr_t env = reinterpret_cast<uintptr_t>(param);
    char spec[512]{};
    GetEnvironmentVariableA("KCDMP_WO72_EARLY_CVARS", spec, sizeof(spec));
    if (!spec[0]) strncpy_s(spec, "sv_AISystem=1", _TRUNCATE);

    void* console = nullptr;
    for (int i = 0; i < 60000; ++i) {
        console = *reinterpret_cast<void**>(env + kEnvConsole);
        if (console) break;
        Sleep(1);
    }
    if (!console) { logf("early cvars: pConsole never appeared"); return 0; }
    void** cvt = *reinterpret_cast<void***>(console);
    auto getCVar = reinterpret_cast<GetCVarFn>(cvt[0xb8 / 8]);

    for (char* tok = spec; *tok;) {
        char* eq = strchr(tok, '=');
        char* comma = strchr(tok, ',');
        if (comma) *comma = '\0';
        if (!eq) { tok = comma ? comma + 1 : tok + strlen(tok); continue; }
        *eq = '\0';
        const char* name = tok;
        const int value = atoi(eq + 1);
        bool done = false;
        for (int i = 0; i < 20000 && !done; ++i) {
            void* c = getCVar(console, name);
            if (c) {
                void** vt = *reinterpret_cast<void***>(c);
                const int before = reinterpret_cast<GetIValFn>(vt[0x10 / 8])(c);
                reinterpret_cast<SetIntFn>(vt[0x38 / 8])(c, value);
                const int after = reinterpret_cast<GetIValFn>(vt[0x10 / 8])(c);
                logf("early cvar %s: was %d, set %d, now %d%s", name, before, value, after,
                     after == value ? "" : "   <-- DID NOT TAKE");
                done = true;
            } else {
                Sleep(1);
            }
        }
        if (!done) logf("early cvar %s: never registered within 20s", name);
        tok = comma ? comma + 1 : tok + strlen(tok);
        while (*tok == ' ') ++tok;
    }
    return 0;
}

// ------------------------------------------------------- missing cvars

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
            if (wait_for_module("XGenAIModule.dll", 120000)) { Sleep(2000); dump_env_slots(env, "normal boot"); dump_csystem_slots(env, "normal boot"); dump_gameiface("normal boot t+2s");
                Sleep(20000); dump_gameiface("normal boot t+22s");
                Sleep(25000); dump_gameiface("normal boot t+47s"); }
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
    g_arena = static_cast<char*>(VirtualAlloc(nullptr, kArenaBytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE));
    logf("stub arena %p (%zu MB, %zu-byte blocks)", (void*)g_arena, kArenaBytes / (1024 * 1024), kArenaBlock);
    fill_vtbl();
    logf("stub object %p, vtable %p, %d slots", (void*)g_stubObject, (void*)g_stubVtbl, kStubSlots);

    uintptr_t* slot = gEnv_slot(crySystem);
    for (int i = 0; i < 60000 && *slot == 0; ++i) Sleep(1);
    const uintptr_t env = *slot;
    if (!env) { logf("gEnv still null after 60s -- aborting, wrote nothing"); return; }
    logf("gEnv = %p", (void*)env);
    logf("gEnv->bDedicated(+0x3d4) = %d", *reinterpret_cast<unsigned char*>(env + kEnvDedicated));

    // Must run as early as possible: the AI-init decision is made before
    // CryAnimation loads, which is where this DLL installs the stub.
    CreateThread(nullptr, 0, early_cvar_thread, reinterpret_cast<LPVOID>(env), 0, nullptr);

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

    char realFlag[16]{};
    GetEnvironmentVariableA("KCDMP_WO72_REAL_RENDERER", realFlag, sizeof(realFlag));
    if (realFlag[0] == '1') {
        char neuter[512]{};
        GetEnvironmentVariableA("KCDMP_WO72_NEUTER", neuter, sizeof(neuter));
        if (install_real_renderer(env, rendererOffset, neuter)) {
            g_censusEnv = env;
            CreateThread(nullptr, 0, census_thread, nullptr, 0, nullptr);
            return;
        }
        logf("real renderer unavailable; falling back to the synthetic stub");
    }

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
    {
        const uintptr_t sys = env - kEnvOffsetInCSystem;
        const uintptr_t r = readable(reinterpret_cast<void*>(sys + 0x148), 8)
                          ? *reinterpret_cast<uintptr_t*>(sys + 0x148) : 0;
        logf("CSystem base check: CSystem=%p, CSystem+0x148=%p, stub=%p -> %s",
             (void*)sys, (void*)r, (void*)g_stubObject,
             r == reinterpret_cast<uintptr_t>(g_stubObject) ? "MATCH" : "MISMATCH");
    }
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

    if (_stricmp(mode, "warp") == 0) {
        // CPU-only route: normal boot, real renderer, software adapter.
        AddVectoredExceptionHandler(1, on_exception);
        install_warp_hook();
        uintptr_t* slot = gEnv_slot(crySystem);
        for (int i = 0; i < 60000 && *slot == 0; ++i) Sleep(1);
        if (*slot) CreateThread(nullptr, 0, early_cvar_thread,
                                reinterpret_cast<LPVOID>(*slot), 0, nullptr);
        return 0;
    }
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
