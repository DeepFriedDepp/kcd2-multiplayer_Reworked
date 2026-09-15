#include "concept_read.h"
#include "log.h"

#include <windows.h>
#include <cstdint>
#include <cstring>
#include <cstdio>

namespace kcdmp::conceptread {

namespace {

// ---------------------------------------------------------------------------
// Modding Tools 1.5.5.0, Bin/Win64ReleaseSteamLTO_DLL, ConceptModule.dll
// (sha256 ab4032ac0410e9072a98c25307796b64..., SizeOfImage 0x5FE000).
// Every RVA below is prologue-verified before the first call, WO-42 s7's
// discipline: a build whose bytes do not match disables the probe rather than
// calling into whatever happens to live at that address now.
// ---------------------------------------------------------------------------
constexpr size_t kRvaFindNode = 0x16530;

const uint8_t kPrologueFindNode[] = {
    0x48, 0x89, 0x5C, 0x24, 0x10,   // mov [rsp+10h], rbx
    0x48, 0x89, 0x6C, 0x24, 0x18,   // mov [rsp+18h], rbp
    0x48, 0x89, 0x74, 0x24, 0x20,   // mov [rsp+20h], rsi
    0x57,                           // push rdi
};

// wh::GetGameIface(), exported from Shared.dll. Same mangled name the combat
// path already resolves (combat_construct.cpp) -- kept as its own constant so
// this file has no dependency on that translation unit.
constexpr const char* kGetGameIfaceName =
    "?GetGameIface@wh@@YAPEBVC_GameInterface@shared@1@XZ";

constexpr size_t kOffGameIfaceConceptModule = 0x128;  // C_GameInterface -> C_ConceptModule*
constexpr size_t kOffConceptModuleManager   = 0x18;   // == C_ConceptModule::GetConceptManager
constexpr size_t kOffManagerRootsBegin      = 0x48;   // vector<C_ModuleBase*> begin
constexpr size_t kOffManagerRootsEnd        = 0x50;   // vector<C_ModuleBase*> end
constexpr size_t kOffModuleName             = 0x10;   // char* the root scan strcmp's

// A root list longer than this means we are reading something that is not the
// vector we think it is; stop rather than walk off into the heap.
constexpr size_t kMaxRoots = 512;

using GetGameIfaceFn = const void* (*)();
// RCX = this (C_ConceptManager*), RDX = hidden _smart_ptr<C_Node>* return,
// R8 = const CryStringT<char>& (i.e. a pointer to the char* that is the string).
using FindNodeFn = void* (*)(void* self, void* retSmartPtr, const void* cryStrRef);

// --- small SEH-guarded primitives ------------------------------------------
// Each __try lives in its own function with no unwindable object, which is
// what MSVC requires and what the rest of this DLL already does.

bool read_ptr(const void* base, size_t offset, void** out) {
    __try {
        *out = *reinterpret_cast<void* const*>(reinterpret_cast<const char*>(base) + offset);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool prologue_matches(const void* fn, const uint8_t* expect, size_t n) {
    __try { return std::memcmp(fn, expect, n) == 0; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool copy_cstr_guarded(const char* s, char* out, size_t n) {
    __try {
        size_t i = 0;
        for (; i + 1 < n && s[i]; ++i) out[i] = s[i];
        out[i] = 0;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool call_get_game_iface(GetGameIfaceFn fn, const void** out) {
    __try { *out = fn(); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool call_find_node(FindNodeFn fn, void* self, void** outNode, const void* strRef) {
    __try {
        *outNode = nullptr;
        fn(self, outNode, strRef);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// module+0xRVA, matching combat_construct.cpp / rttr_abi.cpp's log style.
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
        _snprintf_s(out, n, _TRUNCATE, "%p (unmapped/heap)", p);
    }
}

// --- CryStringT<char>, built immortal --------------------------------------
// The object is a single `char* m_str` pointing at the data; the header sits
// at m_str[-12] as {int32 refCount, int32 length, int32 capacity}. refCount < 0
// means "static": the engine's AddRef/Release are both guarded by
// `if (refCount >= 0)`, so our buffer is never freed, and its copy constructor
// takes the deep-copy branch, so no pointer into our storage outlives the call.
// (WO-97 s2.2: the engine's own shared empty string is built exactly this way,
// refCount 0xFFFFFFFF.)
constexpr size_t kMaxPath = 480;

struct CryStr {
    alignas(8) char storage[12 + kMaxPath + 1]{};
    char* data = nullptr;

    bool init(const char* s) {
        const size_t n = strnlen(s, kMaxPath);
        if (n == 0) return false;
        const int32_t hdr[3] = { -1, static_cast<int32_t>(n), static_cast<int32_t>(n) };
        std::memcpy(storage, hdr, sizeof(hdr));
        std::memcpy(storage + 12, s, n);
        storage[12 + n] = '\0';
        data = storage + 12;
        return true;
    }
    // FindNode takes `const CryStringT<char>&`: a pointer to the m_str field.
    const void* ref() const { return &data; }
};

} // namespace

bool probe(const char* path) {
    char d[256]{};
    logf("CONCEPT: === WO-97 read probe (read-only; nothing is triggered) ===");

    HMODULE conceptModule = GetModuleHandleA("ConceptModule.dll");
    if (!conceptModule) {
        logf("CONCEPT: abort -- ConceptModule.dll is not loaded");
        return false;
    }
    auto* findNodeFn = reinterpret_cast<char*>(conceptModule) + kRvaFindNode;
    if (!prologue_matches(findNodeFn, kPrologueFindNode, sizeof(kPrologueFindNode))) {
        logf("CONCEPT: abort -- FindNode (0x16530) prologue mismatch; this is not the "
             "build these RVAs were taken from, so nothing is called");
        return false;
    }
    describe(findNodeFn, d, sizeof(d));
    logf("CONCEPT: FindNode prologue matches -- %s", d);

    // --- gEnv-equivalent: Shared.dll's GetGameIface ---------------------------
    void* giFn = nullptr;
    if (HMODULE shared = GetModuleHandleA("Shared.dll"))
        giFn = GetProcAddress(shared, kGetGameIfaceName);
    if (!giFn) {
        logf("CONCEPT: abort -- GetGameIface export not found in Shared.dll");
        return false;
    }
    const void* gi = nullptr;
    if (!call_get_game_iface(reinterpret_cast<GetGameIfaceFn>(giFn), &gi) || !gi) {
        logf("CONCEPT: abort -- GetGameIface() faulted or returned null");
        return false;
    }
    describe(gi, d, sizeof(d));
    logf("CONCEPT: GetGameIface() = %p (%s)", gi, d);

    void* cm = nullptr;
    if (!read_ptr(gi, kOffGameIfaceConceptModule, &cm) || !cm) {
        logf("CONCEPT: abort -- gameIface+0x128 (C_ConceptModule*) unreadable/null");
        return false;
    }
    void* mgr = nullptr;
    if (!read_ptr(cm, kOffConceptModuleManager, &mgr) || !mgr) {
        logf("CONCEPT: abort -- conceptModule+0x18 (C_ConceptManager*) unreadable/null");
        return false;
    }
    logf("CONCEPT: C_ConceptModule = %p, C_ConceptManager = %p", cm, mgr);

    // --- the root module list -------------------------------------------------
    // Pure pointer reads; no engine code runs here. This is the half that
    // settles what a path's FIRST segment has to be -- WO-96 guessed "Barbora"
    // from the save tree and could not confirm it.
    void* begin = nullptr;
    void* end = nullptr;
    if (!read_ptr(mgr, kOffManagerRootsBegin, &begin) ||
        !read_ptr(mgr, kOffManagerRootsEnd, &end)) {
        logf("CONCEPT: abort -- root vector (manager+0x48/+0x50) unreadable");
        return false;
    }
    if (!begin || !end || end < begin) {
        logf("CONCEPT: root vector looks wrong (begin=%p end=%p) -- not enumerating", begin, end);
        return false;
    }
    const size_t count = (reinterpret_cast<char*>(end) - reinterpret_cast<char*>(begin)) / 8;
    logf("CONCEPT: root modules: %zu (begin=%p end=%p)", count, begin, end);
    if (count > kMaxRoots) {
        logf("CONCEPT: %zu roots is past the %zu sanity cap -- refusing to walk it",
             count, kMaxRoots);
        return false;
    }
    for (size_t i = 0; i < count; ++i) {
        void* mod = nullptr;
        if (!read_ptr(begin, i * 8, &mod) || !mod) {
            logf("CONCEPT:   [%zu] <unreadable module pointer>", i);
            continue;
        }
        void* namePtr = nullptr;
        char nameBuf[256]{};
        if (!read_ptr(mod, kOffModuleName, &namePtr) || !namePtr ||
            !copy_cstr_guarded(static_cast<const char*>(namePtr), nameBuf, sizeof(nameBuf))) {
            logf("CONCEPT:   [%zu] %p  name <unreadable>", i, mod);
            continue;
        }
        logf("CONCEPT:   [%zu] %p  \"%s\"", i, mod, nameBuf);
    }

    if (!path || !*path) {
        logf("CONCEPT: no path given -- roots enumerated, FindNode not called");
        return true;
    }

    // --- the call itself ------------------------------------------------------
    CryStr s;
    if (!s.init(path)) {
        logf("CONCEPT: path is empty or longer than %zu bytes -- not calling", kMaxPath);
        return false;
    }
    logf("CONCEPT: FindNode(\"%s\") -- separator is '.', first segment is matched "
         "against the root names above", path);

    void* node = nullptr;
    if (!call_find_node(reinterpret_cast<FindNodeFn>(findNodeFn), mgr, &node, s.ref())) {
        logf("CONCEPT: FindNode FAULTED -- the call was caught, but treat this build's "
             "layout as unproven and do not call again until it is re-derived");
        return false;
    }
    if (!node) {
        logf("CONCEPT: FindNode returned NULL -- no node at that path. Either the first "
             "segment names no root above, or a hop below it does not exist.");
        return true;
    }
    describe(node, d, sizeof(d));
    void* vptr = nullptr;
    read_ptr(node, 0, &vptr);
    char vd[256]{};
    describe(vptr, vd, sizeof(vd));
    logf("CONCEPT: FindNode returned a NODE: %p (%s), vtable %p (%s)", node, d, vptr, vd);
    // The returned _smart_ptr arrived with a reference already taken. We do not
    // Release it: a concept node is owned by its module tree and outlives this
    // probe, so one extra count is inert, whereas a wrong Release would free a
    // live node. Deliberate leak, bounded by how often this probe is run.
    logf("CONCEPT: (the node's refcount is left +1 on purpose -- see concept_read.cpp)");
    return true;
}

} // namespace kcdmp::conceptread
