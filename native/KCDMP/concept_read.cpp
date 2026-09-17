#include "concept_read.h"
#include "log.h"

#include "pe_exports.h"
#include "rttr_abi.h"

#include <windows.h>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <vector>

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

// --- CryStringT<char> -------------------------------------------------------
// The object is a single `char* m_str` pointing at the data; the header sits
// at m_str[-12] as {int32 refCount, int32 length, int32 capacity} (verified in
// FUN_180002fd0 and FUN_180011200).
//
// The refCount convention matters more than it looks, and WO-97's first attempt
// got its CONSEQUENCE backwards. Corrected here from the observed result (every
// path returned null, including first hops that must exist) plus a re-read of
// the C_ConceptPath constructor at 0xC6D70:
//
//     if (refCount < 0) { str = <the shared empty string>; }   // NO _Assign
//     else              { str = ours; ++refCount; }
//
// A NEGATIVE refCount does not mean "immortal, deep-copied when retained". In
// this path it means the engine silently substitutes "" and tokenizes THAT; the
// root scan then compares "" against "Barbora"/"Haste", matches nothing, and
// FindNode returns null for every path. That is exactly what was observed.
//
// A LARGE POSITIVE refCount takes the branch we want -- the engine reads our
// bytes -- and is still unfreeable: Release frees only on the 1 -> 0
// transition, which a sentinel this size cannot reach, and the add/release
// pairs inside one call are balanced. Storage is function-static rather than
// stack so that even a pointer retained past the call stays valid.
constexpr size_t  kMaxPath     = 480;
constexpr int32_t kRefSentinel = 0x40000000;   // huge, positive, never reaches 0

struct CryStr {
    alignas(8) char storage[12 + kMaxPath + 1]{};
    char* data = nullptr;

    bool init(const char* s) {
        const size_t n = strnlen(s, kMaxPath);
        if (n == 0) return false;
        const int32_t hdr[3] = { kRefSentinel, static_cast<int32_t>(n), static_cast<int32_t>(n) };
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
    static CryStr s;                    // static: outlives the call (see above)
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
    // Read our own header back. If refCount moved off the sentinel, or the text
    // changed, the engine did something to the string -- and then a null result
    // is a fact about the STRING, not about the tree. This is the check whose
    // absence made the first attempt's null ambiguous.
    int32_t back[3]{};
    std::memcpy(back, s.storage, sizeof(back));
    logf("CONCEPT: string after the call: refCount=0x%08X len=%d cap=%d text=\"%s\"",
         back[0], back[1], back[2], s.data ? s.data : "<null>");

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

// ===========================================================================
// WO-99.5 Phases 1-2 -- the port surface on top of WO-97's node read.
//
// WO-97 s3 mapped C_PortRef::Trigger statically and established that the
// reachable lever is not C_PortRef at all (no public constructor, and building
// one needs a fabricated I_PortDef) but the concrete port's own vtable:
//
//     FindNode(path)          -> C_Node*      (WO-97 Phase 1, live-verified)
//     C_Node::GetPort(name)   -> I_Port*      (exported, ordinal 199)
//     port->vtbl[15]()        -> Trigger
//     port->vtbl[16]()        -> Read
//
// GetPort's signature is taken from the export table, not inferred:
//
//   ?GetPort@C_Node@conceptmodule@wh@@QEBA?AV?$_smart_ptr@VI_Port@...@AEBV?$CryStringT@D@@@Z
//   public: _smart_ptr<I_Port> __cdecl C_Node::GetPort(CryStringT<char> const&) const
//
// QEBA, not UEBA: it is a NON-VIRTUAL public member, so the exported address is
// the real implementation. That matters, because the exported I_Port::Read
// (0x2B1CF0) and I_Port::Trigger (0x2B1DB0) are the EMPTY BASE virtuals -- they
// return cleanly having done nothing (WO-96 s7, WO-97 s2). Nothing here calls
// either of them; both are resolved only to be used as comparands.
//
// The return is by value, so MSVC's member-function layout applies exactly as
// it does for FindNode: RCX = this, RDX = hidden return buffer, R8 = the
// string. _smart_ptr<I_Port> is one pointer, so the buffer is 8 bytes.
//
// THE STEP-0 CHECK. WO-97 s3.5: of 17 I_Port subclasses only C_ActiveTriggerPort
// and C_DebuggerPort have a real slot 15; C_TriggerPort, C_EdgePort and
// C_DataPort inherit the empty base. Both the real and the empty implementation
// return void, so a fire is unfalsifiable without knowing which one is there.
// This probe answers that two independent ways:
//
//   1. the vptr against C_ActiveTriggerPort::vftable (ConceptModule+0x3F3130),
//      which is what WO-97 s4.4 specified; and
//   2. every vtable slot resolved against ConceptModule's exported symbols by
//      ADDRESS, so slot 15 and slot 16 print the name of the function that
//      will actually run.
//
// (2) is the stronger of the two: two of its comparands (I_Port::Trigger,
// I_Port::Read) are exported by name, so the empty-base rejection is anchored
// on a symbol rather than on an RVA, and it confirms WO-97's slot map on this
// binary instead of assuming it. Both are reported; neither is skipped.
// ===========================================================================

namespace {

// Non-virtual, public, exported -- safe to call through the export table.
constexpr const char* kExpGetPort      = "?GetPort@C_Node@conceptmodule@wh@@";
constexpr const char* kExpGetDirection = "?GetDirection@I_Port@conceptmodule@wh@@";

// Comparands only. NEVER called: these two are the empty base virtuals.
constexpr const char* kExpBaseTrigger  = "?Trigger@I_Port@conceptmodule@wh@@";
constexpr const char* kExpBaseRead     = "?Read@I_Port@conceptmodule@wh@@";

// WO-97 s3.2's slot map, and s3.5's real implementations.
constexpr size_t kSlotGetName      = 9;
constexpr size_t kSlotIsEmpty      = 10;
constexpr size_t kSlotTrigger      = 15;
constexpr size_t kSlotRead         = 16;
constexpr size_t kSlotsToDump      = 20;

// From Ghidra (WO-97 s3.5), against ConceptModule.dll sha256 ab4032ac...
constexpr size_t kRvaActiveTriggerVftable = 0x3F3130;
constexpr size_t kRvaActiveTriggerTrigger = 0x000C78E0;

using GetPortFn      = void* (*)(void* self, void* retSmartPtr, const void* cryStrRef);
using GetDirectionFn = int   (*)(const void* self);
using PortTriggerFn  = void  (*)(void* self);
using PortReadFn     = void* (*)(void* self, kcdmp::rttr::Variant* ret);
using PortGetNameFn  = const void* (*)(const void* self);
using PortIsEmptyFn  = bool  (*)(const void* self);

bool call_get_port(GetPortFn fn, void* self, const void* str, void** out) {
    void* sp = nullptr;
    __try { fn(self, &sp, str); *out = sp; return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_get_direction(GetDirectionFn fn, const void* self, int* out) {
    __try { *out = fn(self); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_is_empty(PortIsEmptyFn fn, const void* self, bool* out) {
    __try { *out = fn(self); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_get_name_ref(PortGetNameFn fn, const void* self, const void** out) {
    __try { *out = fn(self); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_port_read(PortReadFn fn, void* self, kcdmp::rttr::Variant* ret) {
    __try { fn(self, ret); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_port_trigger(PortTriggerFn fn, void* self) {
    __try { fn(self); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// Address -> exported symbol name, exact match. Null when the address is not an
// export (an override the module does not export by name).
const char* export_name_at(const std::vector<kcdmp::ExportEntry>& exports, const void* addr) {
    for (const auto& e : exports)
        if (e.addr == addr) return e.name;
    return nullptr;
}

enum class PortAction { Probe, Read, Trigger };

struct PortRequest {
    PortAction action = PortAction::Probe;
    char       path[kMaxPath + 1]{};
    char       port[128]{};
    bool       confirmed = false;    // the literal token FIRE, required to trigger
};

// kcdmp-concept.txt, one line:
//     <probe|read|trigger> <node.path> <portName> [FIRE]
//
// Same two-location convention as script_context.cpp's config_path: the game's
// working directory first (the game root, which the coding shell can write --
// %LocalAppData% is sandbox-redirected and a write there lands somewhere the
// game never reads), then beside the DLL.
bool concept_config_path(char* path, size_t n) {
    char cwd[MAX_PATH]{};
    if (GetCurrentDirectoryA(MAX_PATH, cwd) && cwd[0]) {
        char candidate[MAX_PATH]{};
        _snprintf_s(candidate, sizeof(candidate), _TRUNCATE, "%s%skcdmp-concept.txt",
                    cwd, (cwd[std::strlen(cwd) - 1] == '\\') ? "" : "\\");
        if (GetFileAttributesA(candidate) != INVALID_FILE_ATTRIBUTES) {
            strncpy_s(path, n, candidate, _TRUNCATE);
            return true;
        }
    }
    HMODULE self = nullptr;
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                       GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCSTR>(&concept_config_path), &self);
    if (!GetModuleFileNameA(self, path, static_cast<DWORD>(n))) return false;
    char* slash = std::strrchr(path, '\\');
    if (!slash) return false;
    std::strcpy(slash + 1, "kcdmp-concept.txt");
    return true;
}

bool parse_port_request(const char* text, PortRequest* out) {
    char verb[32]{}, node[kMaxPath + 1]{}, port[128]{}, token[32]{};
    const int got = sscanf_s(text, "%31s %480s %127s %31s",
                             verb, static_cast<unsigned>(sizeof(verb)),
                             node, static_cast<unsigned>(sizeof(node)),
                             port, static_cast<unsigned>(sizeof(port)),
                             token, static_cast<unsigned>(sizeof(token)));
    if (got < 3) return false;

    if (_stricmp(verb, "probe") == 0)        out->action = PortAction::Probe;
    else if (_stricmp(verb, "read") == 0)    out->action = PortAction::Read;
    else if (_stricmp(verb, "trigger") == 0) out->action = PortAction::Trigger;
    else return false;

    strncpy_s(out->path, node, _TRUNCATE);
    strncpy_s(out->port, port, _TRUNCATE);
    out->confirmed = (got >= 4) && (std::strcmp(token, "FIRE") == 0);
    return true;
}

} // namespace

bool port_op(const char* path, const char* portName, int actionCode, bool confirmed) {
    const auto action = static_cast<PortAction>(actionCode);
    char d[256]{};

    if (!path || !*path || !portName || !*portName) {
        logf("PORT: refused -- need both a node path and a port name");
        return false;
    }

    HMODULE cm_mod = GetModuleHandleA("ConceptModule.dll");
    if (!cm_mod) { logf("PORT: abort -- ConceptModule.dll is not loaded"); return false; }

    auto* findNodeFn = reinterpret_cast<char*>(cm_mod) + kRvaFindNode;
    if (!prologue_matches(findNodeFn, kPrologueFindNode, sizeof(kPrologueFindNode))) {
        logf("PORT: abort -- FindNode prologue mismatch; this is not the build these "
             "RVAs came from, so nothing is called");
        return false;
    }

    const auto exports = kcdmp::module_exports(cm_mod);
    void* getPortFn   = kcdmp::find_export(exports, kExpGetPort);
    void* getDirFn    = kcdmp::find_export(exports, kExpGetDirection);
    void* baseTrigger = kcdmp::find_export(exports, kExpBaseTrigger);
    void* baseRead    = kcdmp::find_export(exports, kExpBaseRead);
    if (!getPortFn) {
        logf("PORT: abort -- C_Node::GetPort is not exported under the expected name");
        return false;
    }
    describe(getPortFn, d, sizeof(d));
    logf("PORT: C_Node::GetPort = %s (exported, non-virtual)", d);

    // --- node ---------------------------------------------------------------
    void* giFn = nullptr;
    if (HMODULE shared = GetModuleHandleA("Shared.dll"))
        giFn = GetProcAddress(shared, kGetGameIfaceName);
    if (!giFn) { logf("PORT: abort -- GetGameIface export not found"); return false; }

    const void* gi = nullptr;
    if (!call_get_game_iface(reinterpret_cast<GetGameIfaceFn>(giFn), &gi) || !gi) {
        logf("PORT: abort -- GetGameIface() faulted or returned null");
        return false;
    }
    void* cm = nullptr;
    void* mgr = nullptr;
    if (!read_ptr(gi, kOffGameIfaceConceptModule, &cm) || !cm ||
        !read_ptr(cm, kOffConceptModuleManager, &mgr) || !mgr) {
        logf("PORT: abort -- C_ConceptModule/C_ConceptManager unreadable");
        return false;
    }

    static CryStr pathStr;          // static: outlives the call (WO-97 s2.1b)
    if (!pathStr.init(path)) { logf("PORT: path empty or too long"); return false; }

    void* node = nullptr;
    if (!call_find_node(reinterpret_cast<FindNodeFn>(findNodeFn), mgr, &node, pathStr.ref())) {
        logf("PORT: FindNode FAULTED -- treat the layout as unproven");
        return false;
    }
    {   // Read our own string header back: a null result has to be a fact about
        // the TREE, not about a string the engine quietly swapped for "".
        int32_t back[3]{};
        std::memcpy(back, pathStr.storage, sizeof(back));
        logf("PORT: path string after FindNode: refCount=0x%08X len=%d text=\"%s\"",
             back[0], back[1], pathStr.data ? pathStr.data : "<null>");
    }
    if (!node) {
        logf("PORT: FindNode(\"%s\") returned NULL -- no such node; nothing further", path);
        return false;
    }
    describe(node, d, sizeof(d));
    logf("PORT: node = %p (%s)", node, d);

    // --- port ---------------------------------------------------------------
    static CryStr portStr;
    if (!portStr.init(portName)) { logf("PORT: port name empty or too long"); return false; }

    void* port = nullptr;
    if (!call_get_port(reinterpret_cast<GetPortFn>(getPortFn), node, portStr.ref(), &port)) {
        logf("PORT: GetPort FAULTED -- nothing further");
        return false;
    }
    {
        int32_t back[3]{};
        std::memcpy(back, portStr.storage, sizeof(back));
        logf("PORT: port string after GetPort: refCount=0x%08X len=%d text=\"%s\"",
             back[0], back[1], portStr.data ? portStr.data : "<null>");
    }
    if (!port) {
        logf("PORT: GetPort(\"%s\") returned NULL -- the node has no port by that name",
             portName);
        return false;
    }
    describe(port, d, sizeof(d));
    logf("PORT: port = %p (%s)", port, d);

    // --- step 0: what will actually run -------------------------------------
    void* vptr = nullptr;
    if (!read_ptr(port, 0, &vptr) || !vptr) {
        logf("PORT: port vtable pointer unreadable -- refusing to go further");
        return false;
    }
    void* expectedVftable = reinterpret_cast<char*>(cm_mod) + kRvaActiveTriggerVftable;
    void* expectedTrigger = reinterpret_cast<char*>(cm_mod) + kRvaActiveTriggerTrigger;
    const bool vftableMatches = (vptr == expectedVftable);

    describe(vptr, d, sizeof(d));
    logf("PORT: vtable = %p (%s)", vptr, d);
    logf("PORT: C_ActiveTriggerPort::vftable = %p -- %s",
         expectedVftable, vftableMatches ? "MATCH" : "does NOT match");

    // Cross-check the hard-coded vftable RVA against a symbol: its slot 15 must
    // be C_ActiveTriggerPort::Trigger (0xC78E0). If that fails the RVA is wrong
    // for this binary and the vptr comparison above means nothing.
    {
        void* slot15OfExpected = nullptr;
        if (read_ptr(expectedVftable, kSlotTrigger * 8, &slot15OfExpected)) {
            logf("PORT: vftable+0x78 = %p, expected C_ActiveTriggerPort::Trigger %p -- %s",
                 slot15OfExpected, expectedTrigger,
                 (slot15OfExpected == expectedTrigger) ? "RVA self-check OK"
                                                       : "RVA SELF-CHECK FAILED");
        }
    }

    void* slotTrigger = nullptr;
    void* slotRead    = nullptr;
    for (size_t i = 0; i < kSlotsToDump; ++i) {
        void* fn = nullptr;
        if (!read_ptr(vptr, i * 8, &fn) || !fn) break;
        if (i == kSlotTrigger) slotTrigger = fn;
        if (i == kSlotRead)    slotRead    = fn;
        const char* name = export_name_at(exports, fn);
        describe(fn, d, sizeof(d));
        logf("PORT:   vtbl[%2zu] +0x%02zX = %p (%s)%s%s",
             i, i * 8, fn, d, name ? "  " : "", name ? name : "");
    }

    const bool triggerIsReal  = (slotTrigger == expectedTrigger);
    const bool triggerIsEmpty = (baseTrigger && slotTrigger == baseTrigger);
    logf("PORT: slot 15 verdict -- %s",
         triggerIsReal  ? "C_ActiveTriggerPort::Trigger (REAL propagation)"
       : triggerIsEmpty ? "I_Port::Trigger (EMPTY BASE -- a fire here does nothing)"
                        : "neither the real nor the empty base; unclassified");
    if (baseRead && slotRead == baseRead)
        logf("PORT: slot 16 verdict -- I_Port::Read (EMPTY BASE -- reads nothing)");

    // --- descriptive reads (non-virtual export + vtable slots) --------------
    if (getDirFn) {
        int dir = -1;
        if (call_get_direction(reinterpret_cast<GetDirectionFn>(getDirFn), port, &dir))
            logf("PORT: GetDirection() = %d (%s)", dir,
                 dir == 1 ? "In -- triggerable" : dir == 2 ? "Out -- CanTrigger refuses" : "?");
        else
            logf("PORT: GetDirection() FAULTED");
    }
    {
        void* nameFn = nullptr;
        if (read_ptr(vptr, kSlotGetName * 8, &nameFn) && nameFn) {
            const void* ref = nullptr;
            if (call_get_name_ref(reinterpret_cast<PortGetNameFn>(nameFn), port, &ref) && ref) {
                char* str = nullptr;
                char nameBuf[256]{};
                if (read_ptr(ref, 0, reinterpret_cast<void**>(&str)) && str &&
                    copy_cstr_guarded(str, nameBuf, sizeof(nameBuf)))
                    logf("PORT: GetName() = \"%s\"", nameBuf);
            }
        }
        void* emptyFn = nullptr;
        if (read_ptr(vptr, kSlotIsEmpty * 8, &emptyFn) && emptyFn) {
            bool empty = false;
            if (call_is_empty(reinterpret_cast<PortIsEmptyFn>(emptyFn), port, &empty))
                logf("PORT: IsEmpty() = %s", empty ? "true" : "false");
        }
    }

    if (action == PortAction::Probe) {
        logf("PORT: action=probe -- read-only, nothing was triggered");
        return true;
    }

    // --- Phase 2: the value read --------------------------------------------
    if (action == PortAction::Read) {
        if (!slotRead) { logf("PORT: no slot 16 -- cannot read"); return false; }
        if (baseRead && slotRead == baseRead) {
            logf("PORT: refusing to read -- slot 16 is the empty base I_Port::Read, "
                 "which returns an empty variant and would present as \"works, value "
                 "is none\" (WO-96 s7). That is the trap, not a result.");
            return false;
        }
        kcdmp::rttr::Variant v{};
        if (!call_port_read(reinterpret_cast<PortReadFn>(slotRead), port, &v)) {
            logf("PORT: Read FAULTED");
            return false;
        }
        // No RTTR Api here on purpose: the variant's policy pointer identifies
        // the held type by exported symbol, which needs nothing but the export
        // table. CrySystem.dll is where the variant_data_policy<T> symbols live.
        char pd[256]{};
        describe(v.policy, pd, sizeof(pd));
        const char* policyName = nullptr;
        if (HMODULE crySys = GetModuleHandleA("CrySystem.dll")) {
            const auto cryExports = kcdmp::module_exports(crySys);
            policyName = export_name_at(cryExports, v.policy);
            if (policyName) {
                logf("PORT: Read() -> variant policy=%p (%s)  %s", v.policy, pd, policyName);
            } else {
                logf("PORT: Read() -> variant policy=%p (%s)  <not an export>", v.policy, pd);
            }
        } else {
            logf("PORT: Read() -> variant policy=%p (%s)", v.policy, pd);
        }
        logf("PORT: Read() -> variant data = "
             "%02X %02X %02X %02X %02X %02X %02X %02X  %02X %02X %02X %02X %02X %02X %02X %02X",
             v.data[0], v.data[1], v.data[2],  v.data[3],  v.data[4],  v.data[5],  v.data[6],  v.data[7],
             v.data[8], v.data[9], v.data[10], v.data[11], v.data[12], v.data[13], v.data[14], v.data[15]);
        // If the payload is a pointer to a CryStringT, the first eight bytes are
        // the char*. Print it when it reads as text, clearly marked as a guess.
        {
            char* maybeStr = nullptr;
            std::memcpy(&maybeStr, v.data, sizeof(maybeStr));
            char textBuf[256]{};
            if (maybeStr && copy_cstr_guarded(maybeStr, textBuf, sizeof(textBuf)) && textBuf[0])
                logf("PORT: Read() -> first 8 bytes as a char*: \"%s\" "
                     "(only meaningful if the policy above says string)", textBuf);
        }
        logf("PORT: the returned variant is NOT destroyed -- this translation unit has "
             "no resolved variant dtor. One leaked variant per read, deliberately.");
        return true;
    }

    // --- Phase 1: the fire ---------------------------------------------------
    if (!confirmed) {
        logf("PORT: action=trigger but the FIRE token was absent -- refusing. "
             "Append FIRE to the request line to arm it.");
        return false;
    }
    if (!triggerIsReal) {
        logf("PORT: REFUSING to fire -- slot 15 is not C_ActiveTriggerPort::Trigger. "
             "Calling an empty base returns cleanly having done nothing, which is "
             "indistinguishable from a real fire (WO-97 s3.5). Unfireable, not fired.");
        return false;
    }
    if (!vftableMatches) {
        logf("PORT: REFUSING to fire -- slot 15 matches but the vptr does not match "
             "C_ActiveTriggerPort::vftable. The two checks disagree; that is a reason "
             "to stop, not to pick the convenient one.");
        return false;
    }
    {
        int dir = -1;
        if (getDirFn &&
            call_get_direction(reinterpret_cast<GetDirectionFn>(getDirFn), port, &dir) &&
            dir == 2) {
            logf("PORT: REFUSING to fire -- direction 2 (Out). CanTrigger refuses these, "
                 "and C_PortRef::Trigger does not consult CanTrigger (WO-97 s3.4).");
            return false;
        }
    }

    logf("PORT: === FIRING slot 15 on %p (%s / %s) ===", port, path, portName);
    logf("PORT: watch the ENGINE log for \"Infinite loop detected at port\" -- that "
         "line means the depth guard refused and the fire did NOT happen.");
    const bool ok = call_port_trigger(reinterpret_cast<PortTriggerFn>(slotTrigger), port);
    logf("PORT: the call %s.", ok ? "returned without faulting" : "FAULTED");
    logf("PORT: this return value proves NOTHING about whether the trigger propagated "
         "-- Trigger returns void and the empty path is byte-identical from here "
         "(WO-43 in native clothing). The only admissible evidence is the game world.");
    return ok;
}

void port_watch() {
    char path[MAX_PATH]{};
    if (!concept_config_path(path, sizeof(path))) return;

    char text[1024]{};
    FILE* f = nullptr;
    if (fopen_s(&f, path, "r") == 0 && f) {
        const size_t n = std::fread(text, 1, sizeof(text) - 1, f);
        text[n] = 0;
        std::fclose(f);
    }
    static char lastSeen[1024]{};
    static bool haveLast = false;
    if (haveLast && std::strcmp(text, lastSeen) == 0) return;
    strncpy_s(lastSeen, text, _TRUNCATE);
    haveLast = true;

    if (text[0] == 0) { logf("PORT-WATCH: kcdmp-concept.txt cleared/absent -- idle"); return; }

    PortRequest req{};
    if (!parse_port_request(text, &req)) {
        logf("PORT-WATCH: unparsable request -- expected "
             "\"<probe|read|trigger> <node.path> <portName> [FIRE]\"");
        return;
    }
    logf("PORT-WATCH: %s %s :: %s%s",
         req.action == PortAction::Probe ? "probe" :
         req.action == PortAction::Read  ? "read"  : "trigger",
         req.path, req.port, req.confirmed ? "  [FIRE]" : "");
    port_op(req.path, req.port, static_cast<int>(req.action), req.confirmed);
}

} // namespace kcdmp::conceptread
