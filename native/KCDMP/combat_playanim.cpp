// WO-43 Phase 1 -- the direct call route from docs/WO-42-findings.md §9.5/§9.6.
//
// §9.6 traced human:PlayAnim(fragment, tags) -- already confirmed (WO-40) to
// render a Mannequin fragment on a ghost -- down to its native floor:
//
//   C_Actor* actor = FUN_180B3C2D0(scriptBindHuman, entityId);   // §9.5
//   if (actor && actor->[+0x28]->vtbl[0x80]() != 0)               // the guard
//       actor->vtbl[0xE48](actor, fragment, tags);                // the call
//
// This file replicates exactly that, natively, with every step logged. The
// point is not to bypass anything Lua's PlayAnim bind does -- it is the same
// call either way -- the point is instrumentation: Lua's pcall only reports
// "fault-free"; this reports the guard's actual return value and which
// concrete function address vtbl[0xE48] resolved to, which is what turns an
// unexplained "nothing rendered" into a diagnosed one.
//
// Every address/offset used here is given verbatim in WO-42's findings
// (§9.5 for the two EntityModule exports and their exact mangled names,
// §9.6 for FUN_180B3C2D0's RVA and the guard/call offsets). The one export
// resolved by PREFIX rather than a WO-42-verbatim full name is
// GetScriptBindHuman -- WO-42 §9.3/§9.6 states it exists and is
// name-resolvable but did not transcribe its full mangled signature. Prefix
// matching for exactly that situation is this codebase's own established
// idiom (see pe_exports.h), not a new guess: the prefix is the function's
// literal identifier chain, which MSVC mangling always encodes up front
// regardless of the (unknown-here) parameter/calling-convention suffix.
//
// Opt-in, read-only trigger, matching the kcdmp-faction.txt / kcdmp-target.txt
// precedent already in rttr_abi.cpp: reads "kcdmp-playanim.txt" beside the
// DLL. Absent means skip -- nothing here runs unless a human deliberately
// wrote the file before launching.
//
//   line 1: the literal word "player" (validation case, §9.5's fully
//           name-resolvable GetPlayerActor route), or a decimal CryEngine
//           entity id for an arbitrary actor (the FUN_180B3C2D0 route).
//   line 2: mn_fragment_id, e.g. CombatAttackSyncGen
//   line 3: mn_tags, e.g. l_halberd+r_halberd+clinch1+eZ1+aZ2+attack_special+oppMale
//           (docs/WO-42-findings.md §9.2 -- a real shipped row, not invented)

#include "rttr_abi.h"
#include "pe_exports.h"
#include "log.h"

#include <windows.h>
#include <cstdio>
#include <cstring>

namespace kcdmp::rttr {

namespace {

using GetPlayerActorFn     = void* (*)(const void* entityModule);
using GetScriptBindHumanFn = void* (*)(const void* entityModule);
// §9.6: FUN_180B3C2D0(self, entityId) -> C_Actor* or null. RCX=self, EDX=entityId.
using ResolveActorByIdFn   = void* (*)(void* scriptBindHuman, uint32_t entityId);
// §9.6: the guard predicate at actor[+0x28]->vtbl[0x80](). Returns a short.
using ShortPredicateFn     = short (*)(void*);
// §9.6: C_Actor vtable slot +0xE48 -- (actor, fragmentName, tags).
using PlayAnimFn           = void (*)(void* actor, const char* fragment, const char* tags);

// Every SEH-guarded operation below lives in its own tiny function with no
// locals that require unwinding (no std::string/vector/etc): __try cannot
// coexist with C++ object unwinding in the same frame (MSVC C2712), and
// probe_play_anim() itself holds a std::vector<ExportEntry>.

bool call_get_player_actor(GetPlayerActorFn fn, const void* inst, void** out) {
    __try { *out = fn(inst); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool call_get_script_bind_human(GetScriptBindHumanFn fn, const void* inst, void** out) {
    __try { *out = fn(inst); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool call_resolve_actor_by_id(ResolveActorByIdFn fn, void* bind, uint32_t id, void** out) {
    __try { *out = fn(bind, id); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// §9.6: `actor->[+0x28]->vtbl[0x80]()`. Returns false only on a fault; a
// clean read with a zero/absent guard object is a normal, expected outcome
// and still returns true (with *guardObj possibly null, *guardValue 0).
bool call_guard(void* actor, void** guardObj, short* guardValue) {
    __try {
        *guardObj = *reinterpret_cast<void**>(reinterpret_cast<char*>(actor) + 0x28);
        if (*guardObj) {
            auto* vtbl = *reinterpret_cast<void***>(*guardObj);
            auto fn = reinterpret_cast<ShortPredicateFn>(vtbl[0x80 / 8]);
            *guardValue = fn(*guardObj);
        }
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// §9.6's real work: read C_Actor vtable slot +0xE48 and call it.
bool call_play_anim(void* actor, const char* frag, const char* tags, void** targetOut) {
    __try {
        auto* vtbl = *reinterpret_cast<void***>(actor);
        void* target = vtbl[0xE48 / 8];
        *targetOut = target;
        auto playAnim = reinterpret_cast<PlayAnimFn>(target);
        playAnim(actor, frag, tags);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool read_playanim_config(uint32_t* entityId, bool* wantPlayer,
                          char* frag, size_t fragLen, char* tags, size_t tagsLen) {
    char path[MAX_PATH]{};
    HMODULE self = nullptr;
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                       GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCSTR>(&read_playanim_config), &self);
    GetModuleFileNameA(self, path, MAX_PATH);
    char* slash = std::strrchr(path, '\\');
    if (!slash) return false;
    std::strcpy(slash + 1, "kcdmp-playanim.txt");

    FILE* f = nullptr;
    if (fopen_s(&f, path, "r") != 0 || !f) return false;
    char l1[64]{};
    const bool ok = std::fgets(l1, sizeof(l1), f) != nullptr &&
                    std::fgets(frag, static_cast<int>(fragLen), f) != nullptr &&
                    std::fgets(tags, static_cast<int>(tagsLen), f) != nullptr;
    std::fclose(f);
    if (!ok) return false;

    auto trim = [](char* s) {
        size_t n = std::strlen(s);
        while (n && (s[n - 1] == '\n' || s[n - 1] == '\r')) s[--n] = 0;
    };
    trim(l1); trim(frag); trim(tags);

    if (std::strcmp(l1, "player") == 0) { *wantPlayer = true; *entityId = 0; return true; }
    *wantPlayer = false;
    return std::sscanf(l1, "%u", entityId) == 1;
}

// "module+0xRVA", matching the idiom already used elsewhere in this DLL
// (rttr_abi.cpp: describe_address) for turning a raw pointer into something
// a log reader can act on. No SEH here; callers pass only pointers already
// vetted by the call_* helpers above.
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

} // namespace

void probe_play_anim() {
    uint32_t entityId = 0;
    bool wantPlayer = false;
    char frag[64]{}, tags[256]{};
    if (!read_playanim_config(&entityId, &wantPlayer, frag, sizeof(frag), tags, sizeof(tags))) {
        logf("PLAYANIM: no kcdmp-playanim.txt -- skipping");
        return;
    }
    if (wantPlayer) {
        logf("PLAYANIM: target=player fragment=\"%s\" tags=\"%s\"", frag, tags);
    } else {
        logf("PLAYANIM: target=entityId(%u) fragment=\"%s\" tags=\"%s\"", entityId, frag, tags);
    }

    HMODULE entityModule = GetModuleHandleA("EntityModule.dll");
    if (!entityModule) { logf("PLAYANIM: EntityModule.dll not loaded"); return; }
    const auto exports = module_exports(entityModule);
    if (exports.empty()) { logf("PLAYANIM: EntityModule.dll has no export table"); return; }

    // §9.5 -- verbatim mangled name.
    void* instanceSlot = find_export(exports, "?m_Instance@C_EntityModule@entitymodule@wh@@");
    if (!instanceSlot) { logf("PLAYANIM: m_Instance export not found -- gap vs WO-42 §9.5"); return; }
    void* entityModuleInstance = *reinterpret_cast<void**>(instanceSlot);
    if (!entityModuleInstance) { logf("PLAYANIM: C_EntityModule singleton is null"); return; }

    void* actor = nullptr;

    if (wantPlayer) {
        // §9.5 -- verbatim mangled name, RVA 0x71B330.
        void* fn = find_export(exports, "?GetPlayerActor@C_EntityModule@entitymodule@wh@@");
        if (!fn) { logf("PLAYANIM: GetPlayerActor export not found -- gap vs WO-42 §9.5"); return; }
        if (!call_get_player_actor(reinterpret_cast<GetPlayerActorFn>(fn), entityModuleInstance, &actor)) {
            logf("PLAYANIM: GetPlayerActor faulted");
            return;
        }
    } else {
        // §9.3/§9.6: GetScriptBindHuman is one of the "~120 further getters"
        // WO-42 names but does not give a full mangled signature for -- see
        // the file header comment. If this prefix does not resolve, that is
        // the genuine gap to report, not something to work around blind.
        void* bindFn = find_export(exports, "?GetScriptBindHuman@C_EntityModule@entitymodule@wh@@");
        if (!bindFn) {
            logf("PLAYANIM: GetScriptBindHuman export not found by prefix -- "
                 "gap in WO-42's findings (no verbatim mangled name given); "
                 "not attempting FUN_180B3C2D0 blind. See WO-43-findings.md.");
            return;
        }
        void* bind = nullptr;
        if (!call_get_script_bind_human(reinterpret_cast<GetScriptBindHumanFn>(bindFn),
                                        entityModuleInstance, &bind)) {
            logf("PLAYANIM: GetScriptBindHuman faulted");
            return;
        }
        if (!bind) { logf("PLAYANIM: GetScriptBindHuman returned null"); return; }

        // §9.6: FUN_180B3C2D0, RVA 0xB3C2D0 in EntityModule.dll.
        auto resolveActorById = reinterpret_cast<ResolveActorByIdFn>(
            reinterpret_cast<char*>(entityModule) + 0xB3C2D0);
        if (!call_resolve_actor_by_id(resolveActorById, bind, entityId, &actor)) {
            logf("PLAYANIM: FUN_180B3C2D0 faulted (entityId=%u)", entityId);
            return;
        }
    }

    if (!actor) { logf("PLAYANIM: actor resolution returned null"); return; }
    char actorDesc[256]{};
    describe(actor, actorDesc, sizeof(actorDesc));
    logf("PLAYANIM: actor = %p (%s)", actor, actorDesc);

    // §9.6: `actor->[+0x28]->vtbl[0x80]()` -- must be non-zero or the real
    // C_ScriptBindHuman::PlayAnim never makes the call either. This is one
    // of WO-43's two anticipated checkpoints.
    void* guardObj = nullptr;
    short guardValue = 0;
    if (!call_guard(actor, &guardObj, &guardValue)) {
        logf("PLAYANIM: guard read/call faulted -- actor+0x28 or its vtbl[0x80] "
             "is not what WO-42 §9.6 expects on this actor");
        return;
    }
    logf("PLAYANIM: guard actor[+0x28]=%p, vtbl[0x80]() = %d", guardObj, static_cast<int>(guardValue));
    if (!guardObj || guardValue == 0) {
        logf("PLAYANIM: guard blocked the call (value=%d) -- checkpoint 1 from "
             "WO-43's session brief. The real ScriptBindHuman::PlayAnim would "
             "also have done nothing here; this is not a crash or a bug.",
             static_cast<int>(guardValue));
        return;
    }

    // §9.6's real work: C_Actor vtable slot +0xE48.
    void* target = nullptr;
    const bool called = call_play_anim(actor, frag, tags, &target);
    char targetDesc[256]{};
    describe(target, targetDesc, sizeof(targetDesc));
    logf("PLAYANIM: actor vtbl[+0xE48] = %p (%s)", target, targetDesc);
    if (!called) {
        logf("PLAYANIM: the vtbl[+0xE48] call itself faulted -- checkpoint 2 "
             "from WO-43's session brief (wrong concrete vtable, or the "
             "signature assumed here is wrong). Hand off to Fable per the "
             "session brief.");
        return;
    }
    logf("PLAYANIM: call returned without a structured exception -- "
         "check in-game whether the fragment actually rendered a swing.");
}

namespace {

// Live-reload wrapper, same rationale and pattern as
// combat_construct.cpp's probe_combat_construct_watch(): entity ids are only
// known once a ghost is already spawned in a running game, so re-checking
// kcdmp-playanim.txt on the existing repeating-task timer (instead of only
// once at DLL attach) lets a human spawn a ghost, read its id live, and drop
// it into the file without a relaunch. Deliberately outside any __try (raw
// file I/O + memcmp only), so it may hold an ordinary local buffer;
// probe_play_anim() itself remains the SEH-isolated, one-shot body.
char g_lastSeenPlayAnim[512]{};
bool g_havePlayAnim = false;

} // namespace

void probe_play_anim_watch() {
    char path[MAX_PATH]{};
    HMODULE self = nullptr;
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                       GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCSTR>(&probe_play_anim_watch), &self);
    GetModuleFileNameA(self, path, MAX_PATH);
    char* slash = std::strrchr(path, '\\');
    if (!slash) return;
    std::strcpy(slash + 1, "kcdmp-playanim.txt");

    char text[512]{};
    FILE* f = nullptr;
    if (fopen_s(&f, path, "r") == 0 && f) {
        const size_t n = std::fread(text, 1, sizeof(text) - 1, f);
        text[n] = 0;
        std::fclose(f);
    }
    if (g_havePlayAnim && std::strcmp(text, g_lastSeenPlayAnim) == 0) return;
    std::strcpy(g_lastSeenPlayAnim, text);
    g_havePlayAnim = true;

    if (text[0] == 0) { logf("PLAYANIM-WATCH: kcdmp-playanim.txt cleared/absent -- idle"); return; }
    logf("PLAYANIM-WATCH: kcdmp-playanim.txt changed -- re-running the probe");
    probe_play_anim();
}

} // namespace kcdmp::rttr
