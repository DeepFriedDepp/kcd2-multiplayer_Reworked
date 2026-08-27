#include "script_context.h"
#include "log.h"
#include "rttr_abi.h"

#include <windows.h>
#include <psapi.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cctype>

namespace kcdmp::sctx {

namespace {

// --- code-verified constants (docs/WO-68-findings.md §0) --------------------

// C_GameInterface members holding the two objects the chain starts from.
constexpr size_t kOffGiScriptCtxDbHolder = 0x168;  // -> vtbl[0x138]() = ScriptContext DB
constexpr size_t kOffGiManagerHolder     = 0x18;   // -> vtbl[0x118]() -> vtbl[0x38]() = manager

constexpr size_t kVtblGetScriptContextDb = 0x138;  // on *(gi+0x168)
constexpr size_t kVtblFindContextByName  = 0xC8;   // on the DB: (const CryString&) -> node*
constexpr size_t kVtblGetManagerOwner    = 0x118;  // on *(gi+0x18)
constexpr size_t kVtblGetManager         = 0x38;   // on the owner
constexpr size_t kVtblSetEntityContext   = 0x10;   // C_ScriptContextManager slot [2]
constexpr size_t kVtblHasEntityContext   = 0x38;   // C_ScriptContextManager slot [7]

// WHGame RVAs. Used ONLY as integrity checks on what the vtable slots point
// at -- the calls themselves go through the vtable, so a patch that moves the
// functions but keeps the class layout still works, and one that changes the
// layout fails closed here instead of calling something else.
constexpr uintptr_t kRvaManagerVftable   = 0x32AAD0;
constexpr uintptr_t kRvaSetEntityContext = 0x6BE80;
constexpr uintptr_t kRvaHasEntityContext = 0x6C4A0;

// First bytes of both functions, read out of the file (not out of memory).
constexpr uint8_t kPrologueSet[12] = {0x48,0x89,0x5C,0x24,0x10,0x55,0x56,0x57,0x48,0x81,0xEC,0x90};
constexpr uint8_t kPrologueHas[12] = {0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x74,0x24,0x18,0x48,0x89};

// S_ScriptContextDatabaseNode: +0x00 const char* Name, +0x08 int Class.
// Class must be 1 (Entity) for all seven isolation rows -- HasEntitySideEffect
// (WHGame 0x6B2B0) rejects anything else with "expected Entity".
constexpr size_t kOffNodeName  = 0x00;
constexpr size_t kOffNodeClass = 0x08;
constexpr int    kContextClassEntity = 1;

// The soul field the scriptbind hands to the manager as the entity key.
constexpr size_t kOffSoulWuid = 0x40;

constexpr const char* kGetGameIfaceName =
    "?GetGameIface@wh@@YAPEBVC_GameInterface@shared@1@XZ";

// The isolation block. Order is WO-64/WO-65's, and every name is a real row in
// Tables.pak :: Libs/Tables/ai/ScriptContext.xml with Class="Entity" -- the
// same seven KCD2MP.isolationContexts lists on the Lua side.
// WO-68 Phase 3: the first seven are KCD2Online's block, which this session
// applied and verified live -- and which then FAILED the WO-34 repro: the
// player was still outlawed for punching a fully-isolated ghost.
//
// The reason is in the game's own AI data. Scripts.pak ::
// AI/npc/basic/switch/handleAwareness_hitVolume.xml, the observer-side tree
// that turns a witnessed hit into a crime, checks
//
//   <EntityContextCheck context="crime_ignoredNPCHitVolume"
//                       target="$volumeData.target">  -> $ignore = true
//
// i.e. the context that makes a witness ignore the hit lives on the VICTIM,
// and it is not crime_disableReport. crime_disableReport governs whether the
// entity itself reports crimes it sees; nothing in those trees checks it
// against a victim at all.
//
// The four appended below are the victim-side members of that same family,
// each one taken from a real EntityContextCheck whose target is the victim /
// body / corpse / pickpocket pivot rather than the observer:
//
//   crime_ignoredNPCHitVolume     handleAwareness_hitVolume.xml   $volumeData.target
//   crime_ignoredUnconsciousBody  handleAwareness_unconsciousBody.xml / _bodyHolder / _enemy   $body / $enemy
//   crime_ignoredCorpse           handleAwareness_corpse.xml / _bodyCarrier   $corpse / $body
//   crime_ignoredPickpocket       handleAwareness_pickpocket.xml  $stimulus.pivot
//
// All four are Class="Entity" rows in Tables.pak :: Libs/Tables/ai/ScriptContext.xml.
// Deliberately NOT included: crime_ignoredCombat (a real table row, but no
// tree in any shipped pak checks it -- no evidence it does anything),
// crime_ignoredHorseTheft_NPC and crime_ignoreNPCHitVolumes (observer-side,
// target="$this.id" -- they would have to go on every witness, not the ghost),
// and crime_ignoreNPCHitVolume (a Relation context, needing slot [4] and a
// per-observer pair rather than one call).
constexpr const char* kIsolationContexts[] = {
    "switch_disabledInformationReaction",
    "switch_disabledHearingReaction",
    "switch_disabledPerceptionReaction",
    "switch_disabledPickpocketReaction",
    "switch_disabledNearMissReaction",
    "switch_disabledHitBehavioralReaction",
    "crime_disableReport",
    "crime_ignoredNPCHitVolume",
    "crime_ignoredUnconsciousBody",
    "crime_ignoredCorpse",
    "crime_ignoredPickpocket",
};

// Upper bounds for the file override below. Generous: the cost is stack, and
// the whole point is not needing a rebuild to try a different list.
constexpr int kMaxContexts    = 32;
constexpr int kMaxContextChars = 96;
constexpr int kIsolationContextCount =
    static_cast<int>(sizeof(kIsolationContexts) / sizeof(kIsolationContexts[0]));

constexpr const char* kDefaultProbeContext = "crime_disableReport";

// A context the shipped Storm rule contexts_playerHolsterWeaponInsteadDropOnUnconsciousness
// adds to <isPlayer/> (IPL_GameData.pak :: Libs/Storm/contexts/contexts.xml).
// The player should therefore already HAVE it: reading true here is what
// proves the manager instance and the WUID offset are both right, before
// anything is written.
constexpr const char* kPlayerControlContext = "UnconsciousHolsterInsteadDropWeapons";

// A name the database cannot know. Reading a null node for this while the real
// names resolve separates "the lookup works" from "the lookup returns
// something for anything".
constexpr const char* kBogusContext = "kcdmp_wo68_not_a_context";

// --- SEH-isolated primitives (no destructible locals; MSVC C2712) ----------

using GetGameIfaceFn = const void* (*)();

bool call_get_game_iface(GetGameIfaceFn fn, const void** out) {
    __try { *out = fn(); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool read_ptr(const void* base, size_t offset, void** out) {
    __try {
        *out = *reinterpret_cast<void* const*>(reinterpret_cast<const char*>(base) + offset);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool read_u64(const void* base, size_t offset, uint64_t* out) {
    __try {
        *out = *reinterpret_cast<const uint64_t*>(reinterpret_cast<const char*>(base) + offset);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool read_i32(const void* base, size_t offset, int32_t* out) {
    __try {
        *out = *reinterpret_cast<const int32_t*>(reinterpret_cast<const char*>(base) + offset);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool read_vptr(const void* obj, void** out) {
    __try { *out = *reinterpret_cast<void* const*>(obj); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool read_vtbl_slot(const void* obj, size_t byteOffset, void** out) {
    __try {
        auto* vtbl = *reinterpret_cast<void** const*>(obj);
        *out = vtbl[byteOffset / 8];
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool call_vtbl_ptr(void* obj, size_t byteOffset, void** out) {
    __try {
        auto* vtbl = *reinterpret_cast<void***>(obj);
        auto fn = reinterpret_cast<void* (*)(void*)>(vtbl[byteOffset / 8]);
        *out = fn(obj);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool call_vtbl_ptr_arg(void* obj, size_t byteOffset, const void* arg, void** out) {
    __try {
        auto* vtbl = *reinterpret_cast<void***>(obj);
        auto fn = reinterpret_cast<void* (*)(void*, const void*)>(vtbl[byteOffset / 8]);
        *out = fn(obj, arg);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// bool C_ScriptContextManager::HasEntityContext(WUID, const node*) -- slot [7].
bool call_has_entity_context(void* mgr, uint64_t wuid, const void* node, bool* out) {
    __try {
        auto* vtbl = *reinterpret_cast<void***>(mgr);
        auto fn = reinterpret_cast<bool (*)(void*, uint64_t, const void*)>(
            vtbl[kVtblHasEntityContext / 8]);
        *out = fn(mgr, wuid, node);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// void C_ScriptContextManager::SetEntityContext(bool, WUID, const node*) -- slot [2].
// Argument order and register assignment come from the shipped test's own call
// (WHGame 0x71C90): RCX=this, DL=value, R8=wuid, R9=node.
bool call_set_entity_context(void* mgr, bool value, uint64_t wuid, const void* node) {
    __try {
        auto* vtbl = *reinterpret_cast<void***>(mgr);
        auto fn = reinterpret_cast<void (*)(void*, bool, uint64_t, const void*)>(
            vtbl[kVtblSetEntityContext / 8]);
        fn(mgr, value, wuid, node);
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

// module+0xRVA description, matching combat_construct.cpp / rttr_abi.cpp.
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

// A CryString the engine will never free: header {refcount, length, capacity}
// at data-0xC with a NEGATIVE refcount marks it static, and the engine's
// assign/release path then skips it entirely (the same idiom
// combat_construct.cpp's FakeCryStr already relies on, and visible in
// C_ScriptBindSoul::HasScriptContext's own `if (-1 < *refcount)` guard).
// A CryStringT<char> IS one pointer to the character data, so the argument
// handed to the by-name lookup is the address of such a pointer.
struct StaticCryStr {
    int32_t ref, len, cap;
    char    data[96];
};

bool make_cry_string(StaticCryStr* s, const char* text) {
    const size_t n = std::strlen(text);
    if (n + 1 > sizeof(s->data)) return false;
    s->ref = -1;                       // static: never decremented, never freed
    s->len = static_cast<int32_t>(n);
    s->cap = static_cast<int32_t>(n);
    std::memcpy(s->data, text, n + 1);
    return true;
}

// --- the resolved chain ----------------------------------------------------

struct Chain {
    const void* gi   = nullptr;
    void*       db   = nullptr;
    void*       mgr  = nullptr;
    HMODULE     whgame = nullptr;
};

void* resolve_get_game_iface() {
    void* fn = nullptr;
    if (HMODULE shared = GetModuleHandleA("Shared.dll"))
        fn = GetProcAddress(shared, kGetGameIfaceName);
    if (!fn) {
        HMODULE mods[1024];
        DWORD needed = 0;
        if (EnumProcessModules(GetCurrentProcess(), mods, sizeof(mods), &needed)) {
            const DWORD n = needed / sizeof(HMODULE);
            for (DWORD i = 0; i < n && !fn; ++i)
                fn = GetProcAddress(mods[i], kGetGameIfaceName);
        }
    }
    return fn;
}

// Resolves gi -> DB + manager and verifies the manager really is a
// C_ScriptContextManager (vptr) and that its two slots really point at the two
// functions this file was written against (RVA + prologue). Fails closed and
// says which check failed.
//
// `permanent` (optional) distinguishes the two kinds of failure: "not ready
// yet" (a module or pointer that may exist later -- retry is legitimate) from
// "this build is not the one we disassembled" (retrying can only mis-call, so
// the feature must disarm). Only the latter sets it.
bool resolve_chain(Chain* out, bool* permanent = nullptr) {
    char d[256]{};
    if (permanent) *permanent = false;

    out->whgame = GetModuleHandleA("WHGame.dll");
    if (!out->whgame) { logf("SCTX: WHGame.dll not loaded"); return false; }

    void* giFn = resolve_get_game_iface();
    if (!giFn) { logf("SCTX: wh::GetGameIface() export not found in any module"); return false; }
    if (!call_get_game_iface(reinterpret_cast<GetGameIfaceFn>(giFn), &out->gi) || !out->gi) {
        logf("SCTX: GetGameIface() faulted/null"); return false;
    }
    describe(out->gi, d, sizeof(d));
    logf("SCTX: gameIface = %p (%s)", out->gi, d);

    // --- ScriptContext database: (*(gi+0x168))->vtbl[0x138]() --------------
    void* dbHolder = nullptr;
    if (!read_ptr(out->gi, kOffGiScriptCtxDbHolder, &dbHolder) || !dbHolder) {
        logf("SCTX: gi+0x168 unreadable/null"); return false;
    }
    if (!call_vtbl_ptr(dbHolder, kVtblGetScriptContextDb, &out->db) || !out->db) {
        logf("SCTX: (gi+0x168)->vtbl[0x138]() faulted/null"); return false;
    }
    describe(out->db, d, sizeof(d));
    logf("SCTX: ScriptContext DB = %p (%s)", out->db, d);

    // --- manager: ((*(gi+0x18))->vtbl[0x118]())->vtbl[0x38]() -------------
    void* mgrHolder = nullptr;
    if (!read_ptr(out->gi, kOffGiManagerHolder, &mgrHolder) || !mgrHolder) {
        logf("SCTX: gi+0x18 unreadable/null"); return false;
    }
    void* mgrOwner = nullptr;
    if (!call_vtbl_ptr(mgrHolder, kVtblGetManagerOwner, &mgrOwner) || !mgrOwner) {
        logf("SCTX: (gi+0x18)->vtbl[0x118]() faulted/null"); return false;
    }
    if (!call_vtbl_ptr(mgrOwner, kVtblGetManager, &out->mgr) || !out->mgr) {
        logf("SCTX: owner->vtbl[0x38]() faulted/null"); return false;
    }
    describe(out->mgr, d, sizeof(d));
    logf("SCTX: ScriptContextManager = %p (%s)", out->mgr, d);

    // --- integrity: is this really the class we disassembled? -------------
    void* vptr = nullptr;
    if (!read_vptr(out->mgr, &vptr)) { logf("SCTX: manager vptr read faulted"); return false; }
    void* expectVtbl = reinterpret_cast<char*>(out->whgame) + kRvaManagerVftable;
    describe(vptr, d, sizeof(d));
    if (vptr != expectVtbl) {
        logf("SCTX: manager vptr = %p (%s) but C_ScriptContextManager::vftable is "
             "WHGame+0x%llX -- WRONG OBJECT, refusing to call",
             vptr, d, static_cast<unsigned long long>(kRvaManagerVftable));
        if (permanent) *permanent = true;
        return false;
    }
    logf("SCTX: manager vptr = %p (%s) == C_ScriptContextManager::vftable OK", vptr, d);

    void* setFn = nullptr;
    void* hasFn = nullptr;
    if (!read_vtbl_slot(out->mgr, kVtblSetEntityContext, &setFn) ||
        !read_vtbl_slot(out->mgr, kVtblHasEntityContext, &hasFn)) {
        logf("SCTX: vtable slot read faulted"); return false;
    }
    void* expectSet = reinterpret_cast<char*>(out->whgame) + kRvaSetEntityContext;
    void* expectHas = reinterpret_cast<char*>(out->whgame) + kRvaHasEntityContext;
    describe(setFn, d, sizeof(d));
    logf("SCTX: slot[2] SetEntityContext = %p (%s) expected WHGame+0x%llX %s",
         setFn, d, static_cast<unsigned long long>(kRvaSetEntityContext),
         setFn == expectSet ? "MATCH" : "MISMATCH");
    describe(hasFn, d, sizeof(d));
    logf("SCTX: slot[7] HasEntityContext = %p (%s) expected WHGame+0x%llX %s",
         hasFn, d, static_cast<unsigned long long>(kRvaHasEntityContext),
         hasFn == expectHas ? "MATCH" : "MISMATCH");
    if (setFn != expectSet || hasFn != expectHas) {
        logf("SCTX: vtable layout differs from the disassembled build -- refusing to call");
        if (permanent) *permanent = true;
        return false;
    }
    if (!prologue_matches(setFn, kPrologueSet, sizeof(kPrologueSet)) ||
        !prologue_matches(hasFn, kPrologueHas, sizeof(kPrologueHas))) {
        logf("SCTX: prologue mismatch on Set/HasEntityContext -- refusing to call");
        if (permanent) *permanent = true;
        return false;
    }
    logf("SCTX: both prologues match -- addresses verified for this build");
    return true;
}

// name -> node, with the two integrity reads that make a non-null answer mean
// something: the node's own name must equal what was asked for, and its Class
// must be Entity(1).
const void* lookup_node(const Chain& c, const char* name, bool verbose) {
    StaticCryStr s{};
    if (!make_cry_string(&s, name)) {
        logf("SCTX: context name too long for the static CryString buffer: %s", name);
        return nullptr;
    }
    const char* dataPtr = s.data;      // CryStringT<char> is this one pointer
    void* node = nullptr;
    if (!call_vtbl_ptr_arg(c.db, kVtblFindContextByName, &dataPtr, &node)) {
        logf("SCTX: DB->vtbl[0xC8](\"%s\") FAULTED", name);
        return nullptr;
    }
    if (!node) {
        if (verbose) logf("SCTX: context \"%s\" -> node=null (database has no such row)", name);
        return nullptr;
    }
    void* namePtr = nullptr;
    char  nodeName[128]{};
    int32_t cls = -1;
    const bool haveName = read_ptr(node, kOffNodeName, &namePtr) && namePtr &&
                          copy_cstr_guarded(static_cast<const char*>(namePtr),
                                            nodeName, sizeof(nodeName));
    const bool haveCls  = read_i32(node, kOffNodeClass, &cls);
    if (verbose) {
        logf("SCTX: context \"%s\" -> node=%p name=\"%s\" class=%d %s",
             name, node, haveName ? nodeName : "<unreadable>", haveCls ? cls : -1,
             (haveName && std::strcmp(nodeName, name) == 0) ? "(name matches)"
                                                           : "(NAME DOES NOT MATCH)");
    }
    if (!haveName || std::strcmp(nodeName, name) != 0) {
        logf("SCTX: node for \"%s\" does not carry that name -- treating as unresolved", name);
        return nullptr;
    }
    if (!haveCls || cls != kContextClassEntity) {
        logf("SCTX: node for \"%s\" has class=%d, expected %d (Entity) -- not an entity context",
             name, haveCls ? cls : -1, kContextClassEntity);
        return nullptr;
    }
    return node;
}

// --- probe config ----------------------------------------------------------

struct Config {
    bool     usePlayer = true;
    unsigned char guid[16]{};
    bool     doWrite = false;
    char     context[96]{};
};

// Two candidate locations, in this order:
//   1. the game process's working directory (the game root, where log.h
//      already writes its mirror log) -- reachable from the coding shell,
//      which %LocalAppData% is NOT: WO-43 §7's sandbox redirection makes
//      writes there land somewhere the game never reads. Iterating on the
//      probe's inputs needs a path both sides can see.
//   2. beside the DLL, the kcdmp-combat.txt convention, for a human who would
//      rather keep everything in one folder.
// The first one that exists wins; falls back to (2)'s path so callers always
// have something to report.
bool config_path(char* path, size_t n) {
    char cwd[MAX_PATH]{};
    if (GetCurrentDirectoryA(MAX_PATH, cwd) && cwd[0]) {
        char candidate[MAX_PATH]{};
        _snprintf_s(candidate, sizeof(candidate), _TRUNCATE, "%s%skcdmp-contexts.txt",
                    cwd, (cwd[std::strlen(cwd) - 1] == '\\') ? "" : "\\");
        if (GetFileAttributesA(candidate) != INVALID_FILE_ATTRIBUTES) {
            strncpy_s(path, n, candidate, _TRUNCATE);
            return true;
        }
    }

    HMODULE self = nullptr;
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                       GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCSTR>(&config_path), &self);
    if (!GetModuleFileNameA(self, path, static_cast<DWORD>(n))) return false;
    char* slash = std::strrchr(path, '\\');
    if (!slash) return false;
    std::strcpy(slash + 1, "kcdmp-contexts.txt");
    return true;
}

bool parse_guid_hex(const char* hex, unsigned char out[16]) {
    for (int i = 0; i < 16; ++i) {
        char byteText[3] = { hex[i * 2], hex[i * 2 + 1], 0 };
        if (!std::isxdigit(static_cast<unsigned char>(byteText[0])) ||
            !std::isxdigit(static_cast<unsigned char>(byteText[1]))) return false;
        out[i] = static_cast<unsigned char>(std::strtoul(byteText, nullptr, 16));
    }
    return true;
}

bool read_config(Config* cfg) {
    char path[MAX_PATH]{};
    if (!config_path(path, sizeof(path))) return false;

    FILE* f = nullptr;
    if (fopen_s(&f, path, "r") != 0 || !f) return false;
    char l1[128]{}, l2[64]{}, l3[128]{};
    const bool have1 = std::fgets(l1, sizeof(l1), f) != nullptr;
    const bool have2 = std::fgets(l2, sizeof(l2), f) != nullptr;
    const bool have3 = std::fgets(l3, sizeof(l3), f) != nullptr;
    std::fclose(f);
    if (!have1) return false;

    auto trim = [](char* s) {
        size_t k = std::strlen(s);
        while (k && (s[k - 1] == '\n' || s[k - 1] == '\r' || s[k - 1] == ' ' || s[k - 1] == '\t'))
            s[--k] = 0;
    };
    trim(l1);
    if (have2) trim(l2);
    if (have3) trim(l3);

    if (_strnicmp(l1, "guid:", 5) == 0) {
        if (std::strlen(l1 + 5) < 32 || !parse_guid_hex(l1 + 5, cfg->guid)) {
            logf("SCTX: line 1 \"%s\" is not guid:<32 hex chars>", l1);
            return false;
        }
        cfg->usePlayer = false;
    } else if (_stricmp(l1, "player") == 0) {
        cfg->usePlayer = true;
    } else {
        logf("SCTX: line 1 must be \"player\" or \"guid:<32 hex>\", got \"%s\"", l1);
        return false;
    }

    cfg->doWrite = have2 && _stricmp(l2, "write") == 0;
    strncpy_s(cfg->context, sizeof(cfg->context),
              (have3 && l3[0]) ? l3 : kDefaultProbeContext, _TRUNCATE);
    return true;
}

// The list actually applied: kcdmp-isolation.txt if it exists (one context
// name per line, "#" comments and blanks ignored), otherwise the built-in list
// above. Same two-location search as the probe config -- game working
// directory first, then beside the DLL.
//
// Existing purely so that "which contexts stop a crime" can be answered by
// editing a text file and respawning a ghost, instead of a rebuild + reinstall
// + game restart per attempt. WO-68's live testing needed three such rounds
// before the answer was in hand.
int load_context_list(char names[kMaxContexts][kMaxContextChars]) {
    char path[MAX_PATH]{};
    bool found = false;
    char cwd[MAX_PATH]{};
    if (GetCurrentDirectoryA(MAX_PATH, cwd) && cwd[0]) {
        _snprintf_s(path, sizeof(path), _TRUNCATE, "%s%skcdmp-isolation.txt",
                    cwd, (cwd[std::strlen(cwd) - 1] == '\\') ? "" : "\\");
        found = GetFileAttributesA(path) != INVALID_FILE_ATTRIBUTES;
    }
    if (!found) {
        HMODULE self = nullptr;
        GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                           GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           reinterpret_cast<LPCSTR>(&load_context_list), &self);
        if (GetModuleFileNameA(self, path, MAX_PATH)) {
            char* slash = std::strrchr(path, '\\');
            if (slash) {
                std::strcpy(slash + 1, "kcdmp-isolation.txt");
                found = GetFileAttributesA(path) != INVALID_FILE_ATTRIBUTES;
            }
        }
    }

    if (found) {
        FILE* f = nullptr;
        if (fopen_s(&f, path, "r") == 0 && f) {
            int n = 0;
            char line[kMaxContextChars * 2];
            while (n < kMaxContexts && std::fgets(line, sizeof(line), f)) {
                size_t k = std::strlen(line);
                while (k && (line[k - 1] == '\n' || line[k - 1] == '\r' ||
                             line[k - 1] == ' '  || line[k - 1] == '\t')) line[--k] = 0;
                if (!line[0] || line[0] == '#') continue;
                strncpy_s(names[n], kMaxContextChars, line, _TRUNCATE);
                ++n;
            }
            std::fclose(f);
            if (n > 0) {
                logf("SCTX: context list overridden by %s (%d entries)", path, n);
                return n;
            }
            logf("SCTX: %s held no usable names -- falling back to the built-in list", path);
        }
    }

    for (int i = 0; i < kIsolationContextCount; ++i)
        strncpy_s(names[i], kMaxContextChars, kIsolationContexts[i], _TRUNCATE);
    return kIsolationContextCount;
}

// One HasEntityContext read, logged.
void log_has(void* mgr, uint64_t wuid, const void* node, const char* name, const char* stage) {
    bool has = false;
    if (!call_has_entity_context(mgr, wuid, node, &has)) {
        logf("SCTX: %s HasEntityContext(\"%s\") FAULTED", stage, name);
        return;
    }
    logf("SCTX: %s HasEntityContext(\"%s\") = %s", stage, name, has ? "true" : "false");
}

char g_lastSeen[512]{};
bool g_haveLast = false;

// --- Phase 2 feature state -------------------------------------------------

// Armed until something goes wrong once. Deliberately per-process and one-way:
// a fault here means our model of the engine is wrong, and the honest response
// is to stop touching it rather than retry on the next ghost and risk the same
// fault inside the game's own update.
bool g_isolationArmed = true;

void disarm(const char* why) {
    if (!g_isolationArmed) return;
    g_isolationArmed = false;
    logf("SCTX: *********************************************************");
    logf("SCTX: native context isolation DISARMED for this process: %s", why);
    logf("SCTX: ghosts keep spawning and keep the dialog half; the crime half");
    logf("SCTX: is off until the game restarts. This is the fail-closed path.");
    logf("SCTX: *********************************************************");
}

} // namespace

void probe_contexts() {
    Config cfg{};
    if (!read_config(&cfg)) {
        logf("SCTX: no usable kcdmp-contexts.txt -- skipping");
        return;
    }
    char cfgPath[MAX_PATH]{};
    if (config_path(cfgPath, sizeof(cfgPath))) logf("SCTX: config = %s", cfgPath);
    logf("SCTX: === WO-68 Phase 1 probe: target=%s mode=%s context=\"%s\" ===",
         cfg.usePlayer ? "player" : "guid", cfg.doWrite ? "write(set+verify+unset)" : "read-only",
         cfg.context);

    Chain c{};
    if (!resolve_chain(&c)) { logf("SCTX: chain unresolved -- nothing called"); return; }

    // --- the soul, and the WUID the scriptbind readback uses ---------------
    void* soul = nullptr;
    if (cfg.usePlayer) {
        soul = rttr::player_soul();
        if (!soul) { logf("SCTX: player soul not cached (walk_to_soul did not run?)"); return; }
        logf("SCTX: player soul = %p (from walk_to_soul)", soul);
    } else {
        soul = rttr::find_soul_by_guid(cfg.guid);
        if (!soul) {
            logf("SCTX: no soul in SoulsByGuid for the configured guid -- not loaded here?");
            return;
        }
        logf("SCTX: soul = %p (SoulsByGuid)", soul);
    }

    uint64_t wuid = 0;
    if (!read_u64(soul, kOffSoulWuid, &wuid)) {
        logf("SCTX: read of soul+0x40 (WUID) faulted"); return;
    }
    logf("SCTX: soul+0x40 (WUID) = 0x%016llX", static_cast<unsigned long long>(wuid));
    if (wuid == 0) {
        logf("SCTX: WUID reads zero -- either the offset is wrong or this soul has no WUID; "
             "not calling the manager with a zero key");
        return;
    }

    // --- lookup integrity: a real name, and a name that cannot exist -------
    const void* node = lookup_node(c, cfg.context, /*verbose=*/true);
    lookup_node(c, kBogusContext, /*verbose=*/true);   // expected: node=null

    // --- Stage A control read: a context the target should already have ----
    if (cfg.usePlayer) {
        if (const void* ctrl = lookup_node(c, kPlayerControlContext, /*verbose=*/true)) {
            log_has(c.mgr, wuid, ctrl, kPlayerControlContext, "control");
            logf("SCTX: control expectation -- the shipped Storm rule "
                 "contexts_playerHolsterWeaponInsteadDropOnUnconsciousness adds this to "
                 "<isPlayer/>, so true here validates the manager instance AND soul+0x40");
        }
    }

    if (!node) { logf("SCTX: target context unresolved -- stopping before any write"); return; }
    log_has(c.mgr, wuid, node, cfg.context, "before");

    if (!cfg.doWrite) {
        logf("SCTX: read-only mode -- nothing mutated. Set line 2 to \"write\" for stage B.");
        return;
    }

    // --- Stage B: exactly one write, verified, then undone -----------------
    logf("SCTX: SetEntityContext(true, wuid, \"%s\") ...", cfg.context);
    if (!call_set_entity_context(c.mgr, true, wuid, node)) {
        logf("SCTX: SetEntityContext(true) FAULTED -- stopping"); return;
    }
    log_has(c.mgr, wuid, node, cfg.context, "after-set");
    logf("SCTX: now check from Lua: %s:HasScriptContext('%s') -- it reads this same slot",
         cfg.usePlayer ? "player.soul" : "<that soul>", cfg.context);

    logf("SCTX: SetEntityContext(false, wuid, \"%s\") -- undoing the probe write", cfg.context);
    if (!call_set_entity_context(c.mgr, false, wuid, node)) {
        logf("SCTX: SetEntityContext(false) FAULTED -- the context is STILL SET; "
             "restart the game to clear it");
        return;
    }
    log_has(c.mgr, wuid, node, cfg.context, "after-unset");
    logf("SCTX: === probe done, target left as it was found ===");
}

bool isolation_enabled() { return g_isolationArmed; }

int isolation_context_count() { return kIsolationContextCount; }

bool apply_isolation(const unsigned char guid[16], bool on) {
    if (!g_isolationArmed) {
        logf("SCTX: isolate(%s) skipped -- feature disarmed earlier this process",
             on ? "on" : "off");
        return false;
    }

    Chain c{};
    bool permanent = false;
    if (!resolve_chain(&c, &permanent)) {
        if (permanent) disarm("chain integrity check failed");
        else logf("SCTX: isolate(%s) -- chain not resolvable yet, will retry on the next spawn",
                  on ? "on" : "off");
        return false;
    }

    // Not being able to find the soul is a legitimate, transient outcome: the
    // ghost may not have finished spawning, or may not be streamed in here.
    void* soul = rttr::find_soul_by_guid(guid);
    if (!soul) {
        logf("SCTX: isolate(%s) -- no soul in SoulsByGuid for that guid (not spawned yet?)",
             on ? "on" : "off");
        return false;
    }

    uint64_t wuid = 0;
    if (!read_u64(soul, kOffSoulWuid, &wuid)) {
        disarm("read of soul+0x40 (WUID) faulted");
        return false;
    }
    if (wuid == 0) {
        logf("SCTX: isolate(%s) -- soul %p has a zero WUID; refusing to key the manager on it",
             on ? "on" : "off", soul);
        return false;
    }

    static char names[kMaxContexts][kMaxContextChars];
    const int total = load_context_list(names);

    int inState = 0, changed = 0, unresolved = 0, mismatched = 0;
    for (int i = 0; i < total; ++i) {
        const char* name = names[i];
        const void* node = lookup_node(c, name, /*verbose=*/false);
        if (!node) {
            logf("SCTX: isolate %s: context unresolved on this build -- skipped", name);
            ++unresolved;
            continue;
        }

        // Read first. The store is refcounted, so setting something already
        // set would make one later removal insufficient.
        bool has = false;
        if (!call_has_entity_context(c.mgr, wuid, node, &has)) {
            disarm("HasEntityContext faulted");
            return false;
        }
        if (has == on) {
            logf("SCTX: isolate %s: already %s -- left alone (refcount untouched)",
                 name, on ? "set" : "clear");
            ++inState;
            continue;
        }

        if (!call_set_entity_context(c.mgr, on, wuid, node)) {
            disarm("SetEntityContext faulted");
            return false;
        }
        bool after = false;
        if (!call_has_entity_context(c.mgr, wuid, node, &after)) {
            disarm("HasEntityContext faulted after a write");
            return false;
        }
        logf("SCTX: isolate %s: %s -> readback=%s %s", name, on ? "set" : "clear",
             after ? "true" : "false",
             after == on ? "(applied-and-verified)" : "(WROTE BUT DID NOT TAKE)");
        if (after == on) ++changed; else ++mismatched;
    }

    const int good = inState + changed;
    logf("SCTX: isolate(%s) wuid=0x%016llX -- %d/%d in state (%d changed, %d already, "
         "%d unresolved, %d did not take)",
         on ? "on" : "off", static_cast<unsigned long long>(wuid),
         good, total, changed, inState, unresolved, mismatched);
    return good == total;
}

void probe_contexts_watch() {
    char path[MAX_PATH]{};
    if (!config_path(path, sizeof(path))) return;

    char text[512]{};
    FILE* f = nullptr;
    if (fopen_s(&f, path, "r") == 0 && f) {
        const size_t n = std::fread(text, 1, sizeof(text) - 1, f);
        text[n] = 0;
        std::fclose(f);
    }
    // Absent file reads as empty; only re-probe on an actual content change,
    // never every tick on an unchanged file.
    if (g_haveLast && std::strcmp(text, g_lastSeen) == 0) return;
    std::strcpy(g_lastSeen, text);
    g_haveLast = true;

    if (text[0] == 0) { logf("SCTX-WATCH: kcdmp-contexts.txt cleared/absent -- idle"); return; }
    logf("SCTX-WATCH: kcdmp-contexts.txt changed -- re-running the probe");
    probe_contexts();
}

} // namespace kcdmp::sctx
