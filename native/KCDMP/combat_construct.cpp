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
// Opt-in, read-mostly trigger (kcdmp-faction.txt / kcdmp-playanim.txt
// precedent): reads "kcdmp-combat.txt" beside the DLL. Absent = skip.
//   line 1: "player", or a decimal CryEngine entity id (the ghost's).
//   line 2 (optional): "probe" (default; raw read of the combat-actor field,
//           zero mutation) or "create" (call C_Actor::GetOrCreateCombatActor,
//           EntityModule 0x92260 -- creates the combat actor if the ghost has
//           none yet, exactly as the game does when combat begins).
//
// All RVAs are for Modding Tools 1.5.5.0, ReleaseSteamLTO_DLL build
// 1166656_117 (docs/WO-42-findings.md §1), re-verified against the installed
// EntityModule.dll / CombatModule.dll this session (docs/WO-44-findings.md).

#include "pe_exports.h"
#include "log.h"

#include <windows.h>
#include <cstdio>
#include <cstring>
#include <cstdint>

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

using PtrFn            = void* (*)(const void*);
using ResolveByIdFn    = void* (*)(void* scriptBindHuman, uint32_t entityId);
using GetOrCreateFn    = void* (*)(void* actor);
using CharPredicateFn  = char  (*)(void*);
using GetNameFn        = const char* (*)(void*);

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

bool read_combat_config(uint32_t* entityId, bool* wantPlayer, bool* doCreate) {
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
    char l1[64]{}, l2[64]{};
    const bool haveTarget = std::fgets(l1, sizeof(l1), f) != nullptr;
    const bool haveMode   = std::fgets(l2, sizeof(l2), f) != nullptr;  // optional
    std::fclose(f);
    if (!haveTarget) return false;

    auto trim = [](char* s) {
        size_t k = std::strlen(s);
        while (k && (s[k - 1] == '\n' || s[k - 1] == '\r' || s[k - 1] == ' ')) s[--k] = 0;
    };
    trim(l1);
    if (haveMode) trim(l2);

    *doCreate = haveMode && std::strcmp(l2, "create") == 0;

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

} // namespace

void probe_combat_construct() {
    uint32_t entityId = 0;
    bool wantPlayer = false, doCreate = false;
    if (!read_combat_config(&entityId, &wantPlayer, &doCreate)) {
        logf("COMBAT: no kcdmp-combat.txt -- skipping");
        return;
    }
    logf("COMBAT: direction-B precondition probe. target=%s mode=%s",
         wantPlayer ? "player" : "entityId", doCreate ? "create" : "probe(read-only)");
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
    if (!combatActor && doCreate) {
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

    logf("COMBAT: precondition probe complete. No action was constructed or queued. "
         "See docs/WO-44-findings.md for the rung-2 construction spec these pointers feed.");
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

} // namespace kcdmp::rttr
