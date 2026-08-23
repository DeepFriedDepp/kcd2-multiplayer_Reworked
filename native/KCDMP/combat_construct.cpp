// WO-44 -- direction-B precondition probe (the combat-action construction route).
//
// WO-44 decompiled EntityModule.dll+0xAE17A0 (the C_Actor vtbl+0xE48 target
// that WO-43's live tests exercised) and found it builds a BARE
// TAction<SAnimationContext> (0x90 bytes, via the TAction ctor at
// EntityModule 0x121300) and queues it through IActionController::Queue
// (+0x98). It never touches the combat-actor state machine. That is why a
// combat swing stalls partway: PlayAnim is a generic single-fragment player,
// not a combat-action driver. See docs/WO-44-findings.md.
//
// The fallback (WO-42 §5.2 rung 2 / §5.1 rung 3) is to build and queue a real
// combat action object -- a C_CombatAnimAction (0x1A8) through the actor's own
// C_CombatAnimActionManager (I_CombatActor + 0x490), or the fuller paired
// C_CombatActorActionAttack route. All of that requires, first, an
// I_CombatActor* for the ghost and the offsets off it. This file does NOT
// construct or queue anything yet. It is the safe precondition check: resolve
// the ghost's C_Actor, obtain its I_CombatActor*, and log every pointer/offset
// the construction route depends on, so the next session (with a human at the
// machine) knows the route's inputs resolve on a live ghost before any risky
// allocation/queue is attempted. Everything here is a read or an idempotent
// engine call the game itself makes routinely; nothing is mutated or queued.
//
// It also settles WO-43's open class-dispatch question: it logs the actor's
// vptr and reports whether it matches C_Player's vtable (EntityModule RVA
// 0xE96F78) -- which is the only vtable in this build that carries PlayAnim
// (0xAE17A0) at +0xE48 (C_Human's primary vtable is shorter and has no slot
// there). If a ghost renders PlayAnim, this tells us what it actually is.
//
// WO-45 adds mode "rung2": actually build a C_CombatAnimAction (0x1A8, ctor
// CombatModule 0xF26F0) from a real "FragmentId, tag1+tag2" spec parsed by the
// engine's own ParseFragmentSpec (AnimationModule 0x12DB00), and queue it
// through the actor's own C_CombatAnimActionManager::QueueAction (CombatModule
// 0xF3C00, float -1.0f in XMM2). This is WO-42 §5.2 / WO-44 §5's rung 2 -- the
// first construction step, after the probe confirmed every input resolves.
//
// Opt-in, read-mostly trigger (kcdmp-faction.txt / kcdmp-playanim.txt
// precedent): reads "kcdmp-combat.txt" beside the DLL. Absent = skip.
//   line 1: "player", or a decimal CryEngine entity id (the ghost's).
//   line 2 (optional): "probe" (default; raw read of the combat-actor field,
//           zero mutation) or "create" (call C_Actor::GetOrCreateCombatActor,
//           EntityModule 0x92260 -- creates the combat actor if the ghost has
//           none yet, exactly as the game does when combat begins), or
//           "rung2" (probe + create if needed + construct and queue a real
//           C_CombatAnimAction -- the first mutating mode in this file).
//   line 3 (rung2 only): the fragment spec, "FragmentId, tag1+tag2+..." --
//           a real shipped row from Tables.pak (WO-42 §9.2), never invented.
//
// All RVAs are for Modding Tools 1.5.5.0, ReleaseSteamLTO_DLL build
// 1166656_117 (docs/WO-42-findings.md §1), re-verified against the installed
// EntityModule.dll / CombatModule.dll this session (docs/WO-44-findings.md).

#include "pe_exports.h"
#include "log.h"

#include <windows.h>
#include <psapi.h>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <cstddef>

namespace kcdmp::rttr {

namespace {

// EntityModule RVAs (docs/WO-44-findings.md, re-verified this session).
constexpr uintptr_t kRvaResolveActorById   = 0xB3C2D0;  // FUN_180B3C2D0 (§9.6)
constexpr uintptr_t kRvaGetOrCreateCombat  = 0x92260;   // C_Actor::GetOrCreateCombatActor (§9.5)
constexpr uintptr_t kRvaCPlayerVtable      = 0xE96F78;  // wh::entitymodule::C_Player::vftable

// I_CombatActor member offsets (CombatModule's view; WO-42 §4.4 / §9.5).
constexpr size_t kOffCombatActorInActor    = 0x300;     // C_Actor::m_pCombatActor
constexpr size_t kOffOwningEntity          = 0x2D8;     // I_CombatActor -> back to C_Actor
constexpr size_t kOffActionDirector        = 0x2E0;     // wh::framework::C_ActionDirector*
constexpr size_t kOffCombatStateBlock      = 0x2F0;     // combat state block
constexpr size_t kOffOpponentInState       = 0x1118;    // current opponent (off the state block)
constexpr size_t kOffAnimActionManager     = 0x490;     // C_CombatAnimActionManager (queue target)

// C_Actor vtable byte offsets.
constexpr size_t kVtblCombatCapable        = 0x988;     // combat-capability predicate (returns char)
constexpr size_t kVtblGetName              = 0x490;     // GetName() (returns const char*)
constexpr size_t kVtblGetActorClass        = 0x498;     // GetActorClass() (WO-42 §9.5)

// --- WO-45 rung 2 constants -------------------------------------------------
// AnimationModule RVAs (WO-42 §6.1; ParseFragmentSpec re-decompiled this
// session to pin its exact signature and out-struct layout).
constexpr uintptr_t kRvaParseFragmentSpec  = 0x12DB00;
// CombatModule RVAs (WO-42 §4.1/§5.2b, re-verified by WO-44 §4 and decompiled
// again this session for the ctor's init values).
constexpr uintptr_t kRvaCombatAnimCtor     = 0xF26F0;   // C_CombatAnimAction ctor (sizeof 0x1A8)
constexpr uintptr_t kRvaQueueAction        = 0xF3C00;   // C_CombatAnimActionManager::QueueAction
constexpr uintptr_t kRvaCombatAllocGlobal  = 0x80F930;  // module allocator fn-ptr global (§5.2 step 6)
// Prologue bytes (WO-42 §7 note 6) -- checked before any call, fail closed.
constexpr uint8_t kPrologueParse[12] = {0x48,0x89,0x5C,0x24,0x20,0x55,0x56,0x57,0x41,0x54,0x41,0x55};
constexpr uint8_t kPrologueCtor[12]  = {0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x6C,0x24,0x10,0x48,0x89};
constexpr uint8_t kPrologueQueue[12] = {0x4C,0x8B,0xDC,0x41,0x56,0x48,0x81,0xEC,0xF0,0x00,0x00,0x00};
// wh::GetGameIface() -- exported (namespace wh::shared); full mangled name
// extracted from the installed binaries this session.
constexpr const char* kGetGameIfaceName =
    "?GetGameIface@wh@@YAPEBVC_GameInterface@shared@1@XZ";

// ParseFragmentSpec's out struct, layout read off the decompilation of
// 0x12DB00 and its caller C_PlayAnim::Execute (0x12EF20) this session:
//   +0x00 CryString (the parsed fragment-name substring; refcount-assigned,
//         so it MUST hold a valid CryString before the call)
//   +0x08 fragmentID (int; caller inits to -1, stays -1 on unknown fragment)
//   +0x0C 20-byte TagState block A
//   +0x20 20-byte TagState block B  <-- the one Execute passes to the action
//         ctor, so the one rung 2 uses
//   +0x38 CryString (the tag substring; same validity requirement)
#pragma pack(push, 8)
struct ParseFragmentOut {
    char*    str0;        // +0x00
    int32_t  fragmentID;  // +0x08
    uint8_t  tagsA[20];   // +0x0C
    uint8_t  tagsB[20];   // +0x20
    uint32_t pad;         // +0x34
    char*    str38;       // +0x38
};
#pragma pack(pop)
static_assert(offsetof(ParseFragmentOut, fragmentID) == 0x08, "layout");
static_assert(offsetof(ParseFragmentOut, tagsA)      == 0x0C, "layout");
static_assert(offsetof(ParseFragmentOut, tagsB)      == 0x20, "layout");
static_assert(offsetof(ParseFragmentOut, str38)      == 0x38, "layout");

// A fake "static" CryString: header {refcount, length, capacity} sits at
// data-0xC, and a NEGATIVE refcount marks the string static -- the engine's
// assign/release code then never frees or decrements it (read off the
// refcount idiom in 0x12DB00's decompilation). Both out-struct string slots
// point at one of these so ParseFragmentSpec's refcounted assignment finds a
// valid header.
struct FakeCryStr {
    int32_t ref, len, cap;
    char    data[4];
};

using PtrFn            = void* (*)(const void*);
using ResolveByIdFn    = void* (*)(void* scriptBindHuman, uint32_t entityId);
using GetOrCreateFn    = void* (*)(void* actor);
using CharPredicateFn  = char  (*)(void*);
using GetNameFn        = const char* (*)(void*);
using GetGameIfaceFn   = const void* (*)();
using ParseFragSpecFn  = void  (*)(void* animDB, const char* spec, ParseFragmentOut* out);
using CombatAllocFn    = void* (*)(size_t size, size_t* actualSize, int zero);
using AnimCtorFn       = void* (*)(void* mem, void* memAgain, void* combatActor,
                                   uint32_t priority, uint32_t fragmentID,
                                   const void* tags20, uint32_t flags);
using QueueActionFn    = void  (*)(void* manager, void** smartPtr, float time);

// --- SEH-isolated primitives (no destructible locals; MSVC C2712). ----------

bool call_ptr_fn(PtrFn fn, const void* arg, void** out) {
    __try { *out = fn(arg); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool call_resolve_by_id(ResolveByIdFn fn, void* bind, uint32_t id, void** out) {
    __try { *out = fn(bind, id); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool call_get_or_create(GetOrCreateFn fn, void* actor, void** out) {
    __try { *out = fn(actor); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// vtbl call with zero / one pointer argument, SEH-isolated.
bool call_vtbl_ptr(void* obj, size_t vtblByteOffset, void** out) {
    __try {
        auto* vtbl = *reinterpret_cast<void***>(obj);
        auto fn = reinterpret_cast<void* (*)(void*)>(vtbl[vtblByteOffset / 8]);
        *out = fn(obj);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool call_vtbl_ptr_arg(void* obj, size_t vtblByteOffset, void* arg, void** out) {
    __try {
        auto* vtbl = *reinterpret_cast<void***>(obj);
        auto fn = reinterpret_cast<void* (*)(void*, void*)>(vtbl[vtblByteOffset / 8]);
        *out = fn(obj, arg);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool call_get_game_iface(GetGameIfaceFn fn, const void** out) {
    __try { *out = fn(); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool call_parse_fragment_spec(ParseFragSpecFn fn, void* animDB, const char* spec,
                              ParseFragmentOut* out) {
    __try { fn(animDB, spec, out); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool call_combat_alloc(CombatAllocFn fn, size_t size, void** out) {
    size_t actual = 0;
    __try { *out = fn(size, &actual, 0); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool call_anim_ctor(AnimCtorFn fn, void* mem, void* combatActor, uint32_t priority,
                    uint32_t fragmentID, const void* tags20, void** out) {
    __try { *out = fn(mem, mem, combatActor, priority, fragmentID, tags20, 0); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// The float rides in XMM2 -- WO-42 §2.3's classic trap. A correct C prototype
// (third parameter `float`) is exactly what puts it there under the MSVC x64
// convention; nothing manual needed beyond not declaring it as an int.
bool call_queue_action(QueueActionFn fn, void* manager, void** sp, float time) {
    __try { fn(manager, sp, time); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// IAction::Release -- vtbl[0x10] (WO-44 §4). Drops one reference through the
// object's own virtual, so the object's own destroy path (vtbl[0xB8]) runs if
// this was the last one.
bool call_release(void* obj) {
    __try {
        auto* vtbl = *reinterpret_cast<void***>(obj);
        reinterpret_cast<void (*)(void*)>(vtbl[0x10 / 8])(obj);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool read_u32(const void* base, size_t offset, uint32_t* out) {
    __try {
        *out = *reinterpret_cast<const uint32_t*>(reinterpret_cast<const char*>(base) + offset);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool prologue_matches(const void* fn, const uint8_t* expect, size_t n) {
    __try { return std::memcmp(fn, expect, n) == 0; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool read_ptr(const void* base, size_t offset, void** out) {
    __try {
        *out = *reinterpret_cast<void* const*>(reinterpret_cast<const char*>(base) + offset);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool read_vptr(const void* obj, void** out) {
    __try { *out = *reinterpret_cast<void* const*>(obj); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool call_char_vtbl(void* obj, size_t vtblByteOffset, char* out) {
    __try {
        auto* vtbl = *reinterpret_cast<void***>(obj);
        auto fn = reinterpret_cast<CharPredicateFn>(vtbl[vtblByteOffset / 8]);
        *out = fn(obj);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// Copies at most n-1 bytes of a possibly-not-our-memory C string into out,
// stopping at NUL, under SEH -- so a bad pointer logs "<unreadable>" instead
// of faulting.
bool copy_cstr_guarded(const char* s, char* out, size_t n) {
    __try {
        size_t i = 0;
        for (; i + 1 < n && s[i]; ++i) out[i] = s[i];
        out[i] = 0;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool call_get_name(void* obj, char* out, size_t n) {
    const char* name = nullptr;
    __try {
        auto* vtbl = *reinterpret_cast<void***>(obj);
        auto fn = reinterpret_cast<GetNameFn>(vtbl[kVtblGetName / 8]);
        name = fn(obj);
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
    if (!name) { _snprintf_s(out, n, _TRUNCATE, "<null>"); return true; }
    if (!copy_cstr_guarded(name, out, n)) { _snprintf_s(out, n, _TRUNCATE, "<unreadable>"); }
    return true;
}

// module+0xRVA description, matching combat_playanim.cpp / rttr_abi.cpp.
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

bool read_combat_config(uint32_t* entityId, bool* wantPlayer, bool* doCreate,
                        bool* doRung2, char* fragSpec, size_t fragSpecLen) {
    char path[MAX_PATH]{};
    HMODULE self = nullptr;
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                       GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCSTR>(&read_combat_config), &self);
    GetModuleFileNameA(self, path, MAX_PATH);
    char* slash = std::strrchr(path, '\\');
    if (!slash) return false;
    std::strcpy(slash + 1, "kcdmp-combat.txt");

    FILE* f = nullptr;
    if (fopen_s(&f, path, "r") != 0 || !f) return false;
    char l1[64]{}, l2[64]{}, l3[192]{};
    const bool haveTarget = std::fgets(l1, sizeof(l1), f) != nullptr;
    const bool haveMode   = std::fgets(l2, sizeof(l2), f) != nullptr;  // optional
    const bool haveSpec   = std::fgets(l3, sizeof(l3), f) != nullptr;  // rung2 only
    std::fclose(f);
    if (!haveTarget) return false;

    auto trim = [](char* s) {
        size_t k = std::strlen(s);
        while (k && (s[k - 1] == '\n' || s[k - 1] == '\r' || s[k - 1] == ' ')) s[--k] = 0;
    };
    trim(l1);
    if (haveMode) trim(l2);
    if (haveSpec) trim(l3);

    *doCreate = haveMode && std::strcmp(l2, "create") == 0;
    *doRung2  = haveMode && std::strcmp(l2, "rung2") == 0;
    if (*doRung2) {
        if (!haveSpec || !l3[0]) return false;   // rung2 without a fragment spec is meaningless
        strncpy_s(fragSpec, fragSpecLen, l3, _TRUNCATE);
    } else {
        fragSpec[0] = 0;
    }

    if (std::strcmp(l1, "player") == 0) { *wantPlayer = true; *entityId = 0; return true; }
    *wantPlayer = false;
    return std::sscanf(l1, "%u", entityId) == 1;
}

// Resolve the target's C_Actor*, exactly as combat_playanim.cpp does (the
// §9.5 player route, or the §9.6 entity-id route). Returns null on any gap.
void* resolve_actor(HMODULE entityModule, const std::vector<ExportEntry>& exports,
                    bool wantPlayer, uint32_t entityId) {
    void* instanceSlot = find_export(exports, "?m_Instance@C_EntityModule@entitymodule@wh@@");
    if (!instanceSlot) { logf("COMBAT: m_Instance export not found -- gap vs WO-42 §9.5"); return nullptr; }
    void* inst = *reinterpret_cast<void**>(instanceSlot);
    if (!inst) { logf("COMBAT: C_EntityModule singleton is null"); return nullptr; }

    void* actor = nullptr;
    if (wantPlayer) {
        void* fn = find_export(exports, "?GetPlayerActor@C_EntityModule@entitymodule@wh@@");
        if (!fn) { logf("COMBAT: GetPlayerActor export not found -- gap vs WO-42 §9.5"); return nullptr; }
        if (!call_ptr_fn(reinterpret_cast<PtrFn>(fn), inst, &actor)) { logf("COMBAT: GetPlayerActor faulted"); return nullptr; }
    } else {
        void* bindFn = find_export(exports, "?GetScriptBindHuman@C_EntityModule@entitymodule@wh@@");
        if (!bindFn) {
            logf("COMBAT: GetScriptBindHuman not found by prefix -- same open gap as "
                 "WO-43 (no verbatim mangled name); cannot take the entity-id route.");
            return nullptr;
        }
        void* bind = nullptr;
        if (!call_ptr_fn(reinterpret_cast<PtrFn>(bindFn), inst, &bind) || !bind) {
            logf("COMBAT: GetScriptBindHuman faulted/null");
            return nullptr;
        }
        auto resolve = reinterpret_cast<ResolveByIdFn>(
            reinterpret_cast<char*>(entityModule) + kRvaResolveActorById);
        if (!call_resolve_by_id(resolve, bind, entityId, &actor)) {
            logf("COMBAT: FUN_180B3C2D0 faulted (entityId=%u)", entityId);
            return nullptr;
        }
    }
    return actor;
}

void hex20(const uint8_t* p, char* out /* >= 64 */) {
    static const char* kHex = "0123456789ABCDEF";
    for (int i = 0; i < 20; ++i) {
        out[i * 3]     = kHex[p[i] >> 4];
        out[i * 3 + 1] = kHex[p[i] & 0xF];
        out[i * 3 + 2] = ' ';
    }
    out[59] = 0;
}

// WO-45 rung 2 (WO-42 §5.2 / WO-44 §5): build a real C_CombatAnimAction and
// queue it through the actor's own manager. Every step SEH-isolated + logged;
// every hardcoded RVA prologue-verified before the first call (WO-42 §7 note
// 2's discipline, fail closed).
void run_rung2(void* actor, void* combatActor, void* manager, const char* fragSpec) {
    char d[256]{};
    logf("COMBAT: === rung 2 -- construct + queue a real C_CombatAnimAction ===");
    logf("COMBAT: rung2 spec = \"%s\"", fragSpec);
    if (!combatActor || !manager) {
        logf("COMBAT: rung2 abort -- combatActor/manager missing");
        return;
    }

    HMODULE animModule   = GetModuleHandleA("AnimationModule.dll");
    HMODULE combatModule = GetModuleHandleA("CombatModule.dll");
    if (!animModule || !combatModule) {
        logf("COMBAT: rung2 abort -- AnimationModule/CombatModule not loaded");
        return;
    }

    auto* parseFn = reinterpret_cast<char*>(animModule)   + kRvaParseFragmentSpec;
    auto* ctorFn  = reinterpret_cast<char*>(combatModule) + kRvaCombatAnimCtor;
    auto* queueFn = reinterpret_cast<char*>(combatModule) + kRvaQueueAction;
    if (!prologue_matches(parseFn, kPrologueParse, sizeof(kPrologueParse))) {
        logf("COMBAT: rung2 abort -- ParseFragmentSpec (0x12DB00) prologue mismatch");
        return;
    }
    if (!prologue_matches(ctorFn, kPrologueCtor, sizeof(kPrologueCtor))) {
        logf("COMBAT: rung2 abort -- C_CombatAnimAction ctor (0xF26F0) prologue mismatch");
        return;
    }
    if (!prologue_matches(queueFn, kPrologueQueue, sizeof(kPrologueQueue))) {
        logf("COMBAT: rung2 abort -- QueueAction (0xF3C00) prologue mismatch");
        return;
    }
    logf("COMBAT: rung2 all three prologues match -- addresses verified for this build");

    void* allocFn = nullptr;
    if (!read_ptr(combatModule, kRvaCombatAllocGlobal, &allocFn) || !allocFn) {
        logf("COMBAT: rung2 abort -- CombatModule allocator global (0x80F930) unreadable/null");
        return;
    }
    describe(allocFn, d, sizeof(d));
    logf("COMBAT: rung2 module allocator = %s", d);

    // --- wh::GetGameIface(), exported from Shared.dll (extracted from the
    // installed binaries this session); fall back to a full module sweep. ----
    void* giFn = nullptr;
    if (HMODULE shared = GetModuleHandleA("Shared.dll"))
        giFn = GetProcAddress(shared, kGetGameIfaceName);
    if (!giFn) {
        HMODULE mods[1024];
        DWORD needed = 0;
        if (EnumProcessModules(GetCurrentProcess(), mods, sizeof(mods), &needed)) {
            const DWORD n = needed / sizeof(HMODULE);
            for (DWORD i = 0; i < n && !giFn; ++i)
                giFn = GetProcAddress(mods[i], kGetGameIfaceName);
        }
    }
    if (!giFn) { logf("COMBAT: rung2 abort -- GetGameIface export not found in any module"); return; }
    const void* gi = nullptr;
    if (!call_get_game_iface(reinterpret_cast<GetGameIfaceFn>(giFn), &gi) || !gi) {
        logf("COMBAT: rung2 abort -- GetGameIface() faulted/null");
        return;
    }
    describe(gi, d, sizeof(d));
    logf("COMBAT: rung2 GetGameIface() = %s", d);

    // --- The animDB chain, exactly as C_PlayAnim::Execute (0x12EF20) does:
    // actorClass = actor->vtbl[0x498](); key = *(actorClass+0x28);
    // sys = *(gi+0x08); a = sys->vtbl[0xB0](); b = a->vtbl[0x18]();
    // animDB = b->vtbl[0x20](key). ---------------------------------------
    void* actorClass = nullptr;
    if (!call_vtbl_ptr(actor, kVtblGetActorClass, &actorClass) || !actorClass) {
        logf("COMBAT: rung2 abort -- GetActorClass (vtbl+0x498) faulted/null");
        return;
    }
    void* dbKey = nullptr;
    if (!read_ptr(actorClass, 0x28, &dbKey) || !dbKey) {
        logf("COMBAT: rung2 abort -- actorClass+0x28 (animDB key) unreadable/null");
        return;
    }
    void* sys = nullptr;
    if (!read_ptr(gi, 0x08, &sys) || !sys) {
        logf("COMBAT: rung2 abort -- gameIface+0x08 unreadable/null");
        return;
    }
    void* a = nullptr, *b = nullptr, *animDB = nullptr;
    if (!call_vtbl_ptr(sys, 0xB0, &a) || !a) {
        logf("COMBAT: rung2 abort -- sys->vtbl[0xB0]() faulted/null");
        return;
    }
    if (!call_vtbl_ptr(a, 0x18, &b) || !b) {
        logf("COMBAT: rung2 abort -- a->vtbl[0x18]() faulted/null");
        return;
    }
    if (!call_vtbl_ptr_arg(b, 0x20, dbKey, &animDB) || !animDB) {
        logf("COMBAT: rung2 abort -- animDB load (b->vtbl[0x20](key)) faulted/null");
        return;
    }
    describe(animDB, d, sizeof(d));
    logf("COMBAT: rung2 animDB = %s", d);

    // --- Parse "FragmentId, tag1+tag2" with the engine's own parser. -------
    // The two string slots are refcount-assigned by the parser, so they must
    // hold valid CryStrings going in; a negative header refcount marks ours
    // static so the engine never frees them. The engine-allocated strings the
    // parser leaves behind are deliberately leaked (one-shot probe; safer
    // than replicating the engine's release idiom).
    FakeCryStr s0{-1, 0, 0, {0}}, s38{-1, 0, 0, {0}};
    ParseFragmentOut out{};
    out.str0 = s0.data;
    out.fragmentID = -1;
    out.str38 = s38.data;
    if (!call_parse_fragment_spec(reinterpret_cast<ParseFragSpecFn>(parseFn),
                                  animDB, fragSpec, &out)) {
        logf("COMBAT: rung2 abort -- ParseFragmentSpec faulted");
        return;
    }
    char nm[96]{};
    if (!copy_cstr_guarded(out.str0, nm, sizeof(nm))) std::strcpy(nm, "<unreadable>");
    char hexA[64]{}, hexB[64]{};
    hex20(out.tagsA, hexA);
    hex20(out.tagsB, hexB);
    logf("COMBAT: rung2 parsed fragment=\"%s\" fragmentID=%d", nm, out.fragmentID);
    logf("COMBAT: rung2 tagsA(+0x0C) = %s", hexA);
    logf("COMBAT: rung2 tagsB(+0x20) = %s (this block feeds the ctor)", hexB);
    if (out.fragmentID < 0) {
        logf("COMBAT: rung2 abort -- fragment unknown to this actor's animDB (id stayed -1)");
        return;
    }

    // --- Allocate 0x1A8 with the game's own module allocator, construct. ---
    void* mem = nullptr;
    if (!call_combat_alloc(reinterpret_cast<CombatAllocFn>(allocFn), 0x1A8, &mem) || !mem) {
        logf("COMBAT: rung2 abort -- allocator faulted/null");
        return;
    }
    void* anim = nullptr;
    if (!call_anim_ctor(reinterpret_cast<AnimCtorFn>(ctorFn), mem, combatActor,
                        /*priority*/ 5, static_cast<uint32_t>(out.fragmentID),
                        out.tagsB, &anim) || !anim) {
        logf("COMBAT: rung2 abort -- C_CombatAnimAction ctor faulted/null");
        return;
    }
    uint32_t status = ~0u, refc = ~0u;
    read_u32(anim, 0x28, &status);
    read_u32(anim, 0x58, &refc);
    logf("COMBAT: rung2 constructed C_CombatAnimAction %p: status(+0x28)=%u refcount(+0x58)=%u "
         "(ctor inits both 0; QueueAction's gate needs status 0 or 4)", anim, status, refc);

    // --- AddRef twice, then queue. One reference is consumed by QueueAction
    // (the game's own call site INCs immediately before the call, WO-42
    // §5.2b); the second is deliberately retained -- in the game the owning
    // attack action holds a stored reference for the fragment's lifetime, and
    // without one here the action could be destroyed under the controller if
    // IActionController::Queue does not take its own. A 0x1A8 leak per
    // invocation, chosen over a possible use-after-free. --------------------
    InterlockedIncrement(reinterpret_cast<volatile LONG*>(reinterpret_cast<char*>(anim) + 0x58));
    InterlockedIncrement(reinterpret_cast<volatile LONG*>(reinterpret_cast<char*>(anim) + 0x58));
    void* sp = anim;
    if (!call_queue_action(reinterpret_cast<QueueActionFn>(queueFn), manager, &sp, -1.0f)) {
        logf("COMBAT: rung2 QueueAction FAULTED");
        return;
    }
    read_u32(anim, 0x28, &status);
    read_u32(anim, 0x58, &refc);
    logf("COMBAT: rung2 QueueAction returned. status(+0x28)=%u refcount(+0x58)=%u "
         "(refcount 2 => the controller took its own reference; 1 => it did not)",
         status, refc);
    logf("COMBAT: rung2 done -- a real C_CombatAnimAction is queued on the actor's own "
         "C_CombatAnimActionManager. Watch the character now.");
}

} // namespace

void probe_combat_construct() {
    uint32_t entityId = 0;
    bool wantPlayer = false, doCreate = false, doRung2 = false;
    char fragSpec[192]{};
    if (!read_combat_config(&entityId, &wantPlayer, &doCreate, &doRung2,
                            fragSpec, sizeof(fragSpec))) {
        logf("COMBAT: no kcdmp-combat.txt -- skipping");
        return;
    }
    logf("COMBAT: direction-B probe. target=%s mode=%s",
         wantPlayer ? "player" : "entityId",
         doRung2 ? "rung2(construct+queue)" : doCreate ? "create" : "probe(read-only)");
    if (!wantPlayer) logf("COMBAT: entityId=%u", entityId);

    HMODULE entityModule = GetModuleHandleA("EntityModule.dll");
    if (!entityModule) { logf("COMBAT: EntityModule.dll not loaded"); return; }
    HMODULE combatModule = GetModuleHandleA("CombatModule.dll");
    logf("COMBAT: CombatModule.dll %s", combatModule ? "loaded" : "NOT loaded (rung 2/3 need it)");

    const auto exports = module_exports(entityModule);
    if (exports.empty()) { logf("COMBAT: EntityModule.dll has no export table"); return; }

    void* actor = resolve_actor(entityModule, exports, wantPlayer, entityId);
    if (!actor) { logf("COMBAT: actor resolution returned null"); return; }

    char d[256]{};
    describe(actor, d, sizeof(d));
    logf("COMBAT: C_Actor = %p (%s)", actor, d);

    // --- Class-dispatch question (WO-43's open thread). --------------------
    void* vptr = nullptr;
    if (read_vptr(actor, &vptr)) {
        describe(vptr, d, sizeof(d));
        void* cplayerVtbl = reinterpret_cast<char*>(entityModule) + kRvaCPlayerVtable;
        const bool isCPlayer = (vptr == cplayerVtbl);
        logf("COMBAT: actor vptr = %p (%s) -- %s", vptr, d,
             isCPlayer ? "IS C_Player (PlayAnim/vtbl+0xE48 valid here)"
                       : "NOT C_Player's vtable; identify this class before trusting +0xE48");
    } else {
        logf("COMBAT: actor vptr read faulted");
    }

    // A GetName round-trip is a cheap sanity read on the actor object.
    char nm[128]{};
    if (call_get_name(actor, nm, sizeof(nm))) logf("COMBAT: actor GetName() = \"%s\"", nm);

    // --- Combat-capability predicate (GetOrCreateCombatActor's own gate). --
    char capable = 0;
    if (call_char_vtbl(actor, kVtblCombatCapable, &capable)) {
        logf("COMBAT: actor->vtbl[0x988]() combat-capable = %d", static_cast<int>(capable));
    } else {
        logf("COMBAT: actor->vtbl[0x988]() faulted");
    }

    // --- The combat actor. Raw read first (zero mutation). ----------------
    void* combatActorRaw = nullptr;
    if (!read_ptr(actor, kOffCombatActorInActor, &combatActorRaw)) {
        logf("COMBAT: read of actor+0x300 (m_pCombatActor) faulted");
        return;
    }
    describe(combatActorRaw, d, sizeof(d));
    logf("COMBAT: actor+0x300 (m_pCombatActor, raw) = %p (%s)", combatActorRaw, d);

    void* combatActor = combatActorRaw;
    if (!combatActor && (doCreate || doRung2)) {
        auto fn = reinterpret_cast<GetOrCreateFn>(
            reinterpret_cast<char*>(entityModule) + kRvaGetOrCreateCombat);
        logf("COMBAT: m_pCombatActor null and mode=create -- calling GetOrCreateCombatActor (0x92260)");
        if (!call_get_or_create(fn, actor, &combatActor)) {
            logf("COMBAT: GetOrCreateCombatActor faulted");
            return;
        }
        describe(combatActor, d, sizeof(d));
        logf("COMBAT: GetOrCreateCombatActor returned %p (%s)", combatActor, d);
    }

    if (!combatActor) {
        logf("COMBAT: no combat actor (ghost not in combat). Re-run with mode=create "
             "to have the engine build one -- rung 2/3 need an I_CombatActor*.");
        return;
    }

    // --- The offsets rung 2/3 depend on, off the I_CombatActor. -----------
    void* owningEntity = nullptr, *director = nullptr, *stateBlock = nullptr, *manager = nullptr;

    if (read_ptr(combatActor, kOffOwningEntity, &owningEntity)) {
        describe(owningEntity, d, sizeof(d));
        logf("COMBAT: combatActor+0x2D8 (owning entity) = %p (%s) -- expect == C_Actor %p: %s",
             owningEntity, d, actor, owningEntity == actor ? "MATCH (round-trip ok)" : "MISMATCH");
    } else logf("COMBAT: combatActor+0x2D8 read faulted");

    if (read_ptr(combatActor, kOffActionDirector, &director)) {
        describe(director, d, sizeof(d));
        logf("COMBAT: combatActor+0x2E0 (C_ActionDirector) = %p (%s)", director, d);
    } else logf("COMBAT: combatActor+0x2E0 read faulted");

    if (read_ptr(combatActor, kOffAnimActionManager, &manager)) {
        describe(manager, d, sizeof(d));
        logf("COMBAT: combatActor+0x490 (C_CombatAnimActionManager, rung-2 queue target) = %p (%s)",
             manager, d);
    } else logf("COMBAT: combatActor+0x490 read faulted");

    if (read_ptr(combatActor, kOffCombatStateBlock, &stateBlock)) {
        describe(stateBlock, d, sizeof(d));
        logf("COMBAT: combatActor+0x2F0 (combat state block) = %p (%s)", stateBlock, d);
        if (stateBlock) {
            void* opponent = nullptr;
            if (read_ptr(stateBlock, kOffOpponentInState, &opponent)) {
                describe(opponent, d, sizeof(d));
                logf("COMBAT: state+0x1118 (current opponent) = %p (%s) -- %s", opponent, d,
                     opponent ? "opponent present (rung-3 paired route viable)"
                              : "no opponent (rung-3 needs one; rung-2 unpaired does not)");
            } else logf("COMBAT: state+0x1118 read faulted");
        }
    } else logf("COMBAT: combatActor+0x2F0 read faulted");

    if (!doRung2) {
        logf("COMBAT: precondition probe complete. No action was constructed or queued. "
             "See docs/WO-44-findings.md for the rung-2 construction spec these pointers feed.");
        return;
    }

    // WO-45 rung 2 -- the first mutating mode in this file. Runs only after
    // the reads above have already logged the ghost's state this invocation.
    run_rung2(actor, combatActor, manager, fragSpec);
}

namespace {

// Live-reload wrapper: entity ids are assigned fresh every launch, so a ghost
// id captured in one session is worthless in the next -- re-checking
// kcdmp-combat.txt on a timer instead of only once at DLL attach lets a human
// spawn a ghost, read its id via mp_entity_id, and drop that id into the file
// while the game keeps running, no relaunch needed. Deliberately outside any
// __try (raw file I/O + memcmp only) so it can hold an ordinary local buffer;
// probe_combat_construct() itself remains the SEH-isolated, one-shot body.
char g_lastSeen[256]{};
bool g_haveLast = false;

} // namespace

void probe_combat_construct_watch() {
    char path[MAX_PATH]{};
    HMODULE self = nullptr;
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                       GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCSTR>(&probe_combat_construct_watch), &self);
    GetModuleFileNameA(self, path, MAX_PATH);
    char* slash = std::strrchr(path, '\\');
    if (!slash) return;
    std::strcpy(slash + 1, "kcdmp-combat.txt");

    char text[256]{};
    FILE* f = nullptr;
    if (fopen_s(&f, path, "r") == 0 && f) {
        const size_t n = std::fread(text, 1, sizeof(text) - 1, f);
        text[n] = 0;
        std::fclose(f);
    }
    // Absent file reads as empty; only re-probe on an actual content change
    // (including empty -> non-empty), never every tick on an unchanged file.
    if (g_haveLast && std::strcmp(text, g_lastSeen) == 0) return;
    std::strcpy(g_lastSeen, text);
    g_haveLast = true;

    if (text[0] == 0) { logf("COMBAT-WATCH: kcdmp-combat.txt cleared/absent -- idle"); return; }
    logf("COMBAT-WATCH: kcdmp-combat.txt changed -- re-running the probe");
    probe_combat_construct();
}

// --- WO-46: the production swing path (combat_swing.h). ---------------------
// The lean twin of run_rung2 above: same WO-45-live-verified steps, one log
// line per swing instead of one per step, and a leak-free lifecycle -- hold a
// reference across the queue call (so the post-queue state read can never
// touch a destroyed object, even on QueueAction's internal no-controller
// path), then release it through the action's own virtual. The controller's
// own reference (live-measured in WO-45: refcount 2 with one retained ref
// held) then owns the action until it completes.
bool ghost_swing(uint32_t entityId, const char* fragSpec) {
    if (!fragSpec || !fragSpec[0] || std::strlen(fragSpec) > 191) {
        logf("SWING: rejected -- missing/oversized fragment spec");
        return false;
    }

    HMODULE entityModule = GetModuleHandleA("EntityModule.dll");
    HMODULE animModule   = GetModuleHandleA("AnimationModule.dll");
    HMODULE combatModule = GetModuleHandleA("CombatModule.dll");
    if (!entityModule || !animModule || !combatModule) {
        logf("SWING: entity=%u rejected -- a required module is not loaded", entityId);
        return false;
    }

    // Prologue-verify all three hardcoded RVAs once per process (fail closed,
    // WO-42 §7's discipline). A build mismatch disables native swings rather
    // than calling into the wrong bytes.
    auto* parseFn = reinterpret_cast<char*>(animModule)   + kRvaParseFragmentSpec;
    auto* ctorFn  = reinterpret_cast<char*>(combatModule) + kRvaCombatAnimCtor;
    auto* queueFn = reinterpret_cast<char*>(combatModule) + kRvaQueueAction;
    static int prologueState = 0;   // 0 unchecked, 1 ok, -1 mismatch
    if (prologueState == 0) {
        prologueState =
            (prologue_matches(parseFn, kPrologueParse, sizeof(kPrologueParse)) &&
             prologue_matches(ctorFn,  kPrologueCtor,  sizeof(kPrologueCtor))  &&
             prologue_matches(queueFn, kPrologueQueue, sizeof(kPrologueQueue))) ? 1 : -1;
        if (prologueState < 0)
            logf("SWING: RVA prologue mismatch -- native swings disabled for this build");
    }
    if (prologueState < 0) return false;

    const auto exports = module_exports(entityModule);
    if (exports.empty()) {
        logf("SWING: entity=%u -- EntityModule has no export table", entityId);
        return false;
    }
    void* actor = resolve_actor(entityModule, exports, /*wantPlayer*/ false, entityId);
    if (!actor) {
        logf("SWING: entity=%u -- actor did not resolve (despawned or stale id)", entityId);
        return false;
    }

    void* combatActor = nullptr;
    if (!read_ptr(actor, kOffCombatActorInActor, &combatActor)) {
        logf("SWING: entity=%u -- actor+0x300 read faulted", entityId);
        return false;
    }
    if (!combatActor) {
        auto fn = reinterpret_cast<GetOrCreateFn>(
            reinterpret_cast<char*>(entityModule) + kRvaGetOrCreateCombat);
        if (!call_get_or_create(fn, actor, &combatActor) || !combatActor) {
            logf("SWING: entity=%u -- GetOrCreateCombatActor faulted/null", entityId);
            return false;
        }
    }
    void* manager = nullptr;
    if (!read_ptr(combatActor, kOffAnimActionManager, &manager) || !manager) {
        logf("SWING: entity=%u -- anim-action manager (+0x490) unreadable/null", entityId);
        return false;
    }

    void* allocFn = nullptr;
    if (!read_ptr(combatModule, kRvaCombatAllocGlobal, &allocFn) || !allocFn) {
        logf("SWING: entity=%u -- CombatModule allocator global unreadable/null", entityId);
        return false;
    }

    void* giFn = nullptr;
    if (HMODULE shared = GetModuleHandleA("Shared.dll"))
        giFn = GetProcAddress(shared, kGetGameIfaceName);
    if (!giFn) {
        HMODULE mods[1024];
        DWORD needed = 0;
        if (EnumProcessModules(GetCurrentProcess(), mods, sizeof(mods), &needed)) {
            const DWORD n = needed / sizeof(HMODULE);
            for (DWORD i = 0; i < n && !giFn; ++i)
                giFn = GetProcAddress(mods[i], kGetGameIfaceName);
        }
    }
    const void* gi = nullptr;
    if (!giFn || !call_get_game_iface(reinterpret_cast<GetGameIfaceFn>(giFn), &gi) || !gi) {
        logf("SWING: entity=%u -- GetGameIface unavailable/faulted", entityId);
        return false;
    }

    // The animDB chain, exactly as C_PlayAnim::Execute does (WO-45 live-verified).
    void* actorClass = nullptr, *dbKey = nullptr, *sys = nullptr;
    void* a = nullptr, *b = nullptr, *animDB = nullptr;
    if (!call_vtbl_ptr(actor, kVtblGetActorClass, &actorClass) || !actorClass ||
        !read_ptr(actorClass, 0x28, &dbKey) || !dbKey ||
        !read_ptr(gi, 0x08, &sys) || !sys ||
        !call_vtbl_ptr(sys, 0xB0, &a) || !a ||
        !call_vtbl_ptr(a, 0x18, &b) || !b ||
        !call_vtbl_ptr_arg(b, 0x20, dbKey, &animDB) || !animDB) {
        logf("SWING: entity=%u -- animDB chain broke", entityId);
        return false;
    }

    FakeCryStr s0{-1, 0, 0, {0}}, s38{-1, 0, 0, {0}};
    ParseFragmentOut out{};
    out.str0 = s0.data;
    out.fragmentID = -1;
    out.str38 = s38.data;
    if (!call_parse_fragment_spec(reinterpret_cast<ParseFragSpecFn>(parseFn),
                                  animDB, fragSpec, &out)) {
        logf("SWING: entity=%u -- ParseFragmentSpec faulted", entityId);
        return false;
    }
    if (out.fragmentID < 0) {
        logf("SWING: entity=%u -- fragment unknown to this actor's animDB: \"%s\"",
             entityId, fragSpec);
        return false;
    }

    void* mem = nullptr;
    if (!call_combat_alloc(reinterpret_cast<CombatAllocFn>(allocFn), 0x1A8, &mem) || !mem) {
        logf("SWING: entity=%u -- allocator faulted/null", entityId);
        return false;
    }
    void* anim = nullptr;
    if (!call_anim_ctor(reinterpret_cast<AnimCtorFn>(ctorFn), mem, combatActor,
                        /*priority*/ 5, static_cast<uint32_t>(out.fragmentID),
                        out.tagsB, &anim) || !anim) {
        logf("SWING: entity=%u -- C_CombatAnimAction ctor faulted/null", entityId);
        return false;
    }

    // Two refs in: one for QueueAction to consume (the game's own convention),
    // one held by us across the call and the state read below.
    InterlockedIncrement(reinterpret_cast<volatile LONG*>(reinterpret_cast<char*>(anim) + 0x58));
    InterlockedIncrement(reinterpret_cast<volatile LONG*>(reinterpret_cast<char*>(anim) + 0x58));
    void* sp = anim;
    if (!call_queue_action(reinterpret_cast<QueueActionFn>(queueFn), manager, &sp, -1.0f)) {
        logf("SWING: entity=%u -- QueueAction FAULTED", entityId);
        call_release(anim);   // still drop our ref; the object outlives the fault path
        return false;
    }
    uint32_t status = ~0u, refc = ~0u;
    read_u32(anim, 0x28, &status);
    read_u32(anim, 0x58, &refc);
    // Drop our reference through the object's own virtual. refc includes it,
    // so the controller's view is refc-1.
    call_release(anim);
    logf("SWING: entity=%u queued fragment %d status=%u ref(controller)=%u spec=\"%s\"",
         entityId, out.fragmentID, status, refc ? refc - 1 : 0, fragSpec);
    return true;
}

} // namespace kcdmp::rttr
