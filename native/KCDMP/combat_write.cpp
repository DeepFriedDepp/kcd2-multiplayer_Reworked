// WO-100.5 Phase 1 -- the first combat WRITE.
//
// Everything before this WO read the combat model. This calls into it. It is
// therefore file-triggered and ONE-SHOT: nothing here runs until
// kcdmp-combatwrite.txt exists and names a command, and each distinct command
// fires exactly once, however long the file sits there. A write that repeats
// at the tick rate is not a probe, it is a hook.
//
// ---------------------------------------------------------------------------
// WO-100 handed over two RVAs. One of them was described wrongly, and the
// second-call-site rule is what caught it.
// ---------------------------------------------------------------------------
//
// (a) CombatModule 0x76500 -- CONFIRMED, three independent call sites agree.
//
//     WO-100 read it off ONE site and marked the argument roles
//     (inconclusive). Three sites now agree (code-verified, this WO):
//
//       0x1268C4  C_CombatAutomationBlock::FireAction
//                 rcx=[rsi+8] (the combat actor), rdx=lea [rsp+0x40] (out),
//                 r8b=6, r9d=eax (a zone, returned by a vtbl call),
//                 [rsp+0x20]=byte [rsi+0x51], [rsp+0x28]=dword -1
//       0x76CE5   a 4-argument wrapper (actor, out, int, byte) that hardcodes
//                 r8b=6 and [rsp+0x28]=-1 and forwards the other two --
//                 which pins arg4 as the int and arg5 as the byte
//       0x47E13   rcx is the combat actor (the same basic block reads
//                 [rcx+0x2F0] -- the MODEL, WO-100 S4.1's own offset -- and
//                 branches on [model+0xA20] / [model+0x9E0] to choose
//                 r8b = 4 or 1), r9d=0, [rsp+0x20]=0
//
//     So: (I_CombatActor*, void** outAction, uint8 actionTypeId, int32 zoneId,
//          uint8 handSlot, int32 param6).
//
//     WO-100 described the last two as one "int64 packed(strength, -1)". They
//     are two separate argument slots: a byte at [rsp+0x20] and a DWORD at
//     [rsp+0x28]. Corrected here, on three sites rather than one.
//
//     The caller contract, transcribed from FireAction's tail (0x1268C9):
//         if (out) out->vtbl[2]();          // release our reference
//         else     log "Automated block was not triggered - anim queue failed!"
//     -- so the engine reports this action's own failure, in kcd.log, without
//     us instrumenting anything.
//
// (b) CombatModule 0xF4C20 -- WO-100 called it "the property setter,
//     (propertyBase, value, flag)". IT IS NOT. Refuted, code-verified:
//
//       * 25 of its 26 direct call sites pass the SAME object,
//         model + 0xEE8 -- not 26 different property bases.
//       * its body is
//             if (((uint8*)obj)[8 + index] == value) return;   // early out
//             ... virtual call on obj ...
//         i.e. "cmp byte ptr [rbp + rsi + 8], dil" with rbp = movsxd(edx) and
//         dil = r8b. The second argument INDEXES A BYTE ARRAY; it is not a
//         value written into a property's +0x08 slot.
//
//     Signature: f(void* flagsObj, int32 index, uint8 value).
//     Object: model + 0xEE8, a flag array with a vptr at +0x00 and the bytes
//     at +0x08 (vtbl[1] is a bool query on it, vtbl[3] a busy/guard query).
//
//     Calling it with a model property base -- what WO-100's note would have
//     had us do -- would have written a byte at propBase + 8 + value. That is
//     the project's standing trap in write form, and it is why this file's
//     first write is the shipped call with the shipped arguments:
//     C_CombatPlayerController::SetStandardGuardRequest (0x33F110) does
//     exactly set(model + 0xEE8, 0, 1) after its own preconditions.
//
// ---------------------------------------------------------------------------
// Gates. Every one of them refuses rather than guessing.
// ---------------------------------------------------------------------------
//  1. CombatModule.dll is loaded.
//  2. Both RVAs' PROLOGUE BYTES match what was read out of this exact build.
//     A build mismatch disables the path instead of calling into the wrong
//     bytes -- the rule ghost_swing already follows.
//  3. The actor, its combat actor (+0x300) and its model (+0x2F0) all resolve.
//  4. KNOWN-ANSWER: the property at model+0x200 must report its own registered
//     name as "RequestedAtkZone" (WO-100 S4.1's self-checking layout, 20/20
//     live). If the model does not name itself, it is not the model.
//  5. A flag write reads the byte back AT ONE BYTE -- the correct width. A
//     4-byte read of a one-byte field returns a plausible number, not an
//     error (WO-100 S10.5).

#include "combat_write.h"
#include "pe_exports.h"
#include "log.h"

#include <windows.h>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <vector>

namespace kcdmp::combatwrite {

namespace {

constexpr size_t kOffActorCombatActor = 0x300;   // C_Actor -> I_CombatActor
constexpr size_t kOffCombatActorModel = 0x2F0;   // I_CombatActor -> the model
constexpr size_t kOffModelFlags       = 0xEE8;   // the flag-array object
constexpr size_t kOffFlagsBytes       = 0x08;    // flags[i] lives at obj + 8 + i
constexpr size_t kPropName            = 0x30;
constexpr size_t kKnownPropBase       = 0x200;   // RequestedAtkZone
constexpr const char* kKnownPropName  = "RequestedAtkZone";

constexpr uintptr_t kRvaRequestAction    = 0x76500;
constexpr uintptr_t kRvaSetFlag          = 0xF4C20;
constexpr uintptr_t kRvaResolveActorById = 0xB3C2D0;  // EntityModule (WO-44 S9.6)

// Read out of this build's CombatModule.dll. Compared against the LOADED
// image, so a different build disarms the path.
const uint8_t kPrologueRequestAction[] = {
    0x48,0x89,0x5C,0x24,0x20, 0x55, 0x57, 0x41,0x54, 0x41,0x56, 0x41,0x57,
    0x48,0x8D,0x6C,0x24,0xD9, 0x48,0x81,0xEC,0xE0,0x00,0x00,0x00
};
const uint8_t kPrologueSetFlag[] = {
    0x40,0x53, 0x55, 0x56, 0x57, 0x48,0x83,0xEC,0x48, 0x48,0x8B,0xF1, 0x48,0x63,0xEA
};

// Hard bound: the flag array's real length is not known, and reading or
// writing past it is exactly the kind of plausible-looking nonsense this file
// exists to avoid. 16 covers every index the shipped call sites use (0..7).
constexpr int kMaxFlagIndex = 15;

using PtrFn           = void* (*)(const void*);
using ResolveByIdFn   = void* (*)(void* scriptBindHuman, uint32_t entityId);
using SetFlagFn       = void  (*)(void* flagsObj, int32_t index, uint8_t value);
using RequestActionFn = void* (*)(void* combatActor, void** outAction,
                                  uint8_t actionTypeId, int32_t zoneId,
                                  uint8_t handSlot, int32_t param6);

// --- SEH-isolated primitives (no destructible locals; MSVC C2712) ----------

bool call_ptr_fn(PtrFn fn, const void* arg, void** out) {
    __try { *out = fn(arg); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_resolve_by_id(ResolveByIdFn fn, void* bind, uint32_t id, void** out) {
    __try { *out = fn(bind, id); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool read_ptr(const void* base, size_t off, void** out) {
    __try { *out = *reinterpret_cast<void* const*>(static_cast<const char*>(base) + off); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool read_u8(const void* base, size_t off, uint8_t* out) {
    __try { *out = *reinterpret_cast<const uint8_t*>(static_cast<const char*>(base) + off); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool copy_cstr(const char* src, char* dst, size_t n) {
    __try {
        size_t i = 0;
        for (; i + 1 < n && src[i]; ++i) dst[i] = src[i];
        dst[i] = 0; return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { dst[0] = 0; return false; }
}
bool bytes_match(const void* at, const uint8_t* want, size_t n) {
    __try { return std::memcmp(at, want, n) == 0; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_set_flag(SetFlagFn fn, void* obj, int32_t index, uint8_t value) {
    __try { fn(obj, index, value); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_request_action(RequestActionFn fn, void* actor, void** out,
                         uint8_t type, int32_t zone, uint8_t hand, int32_t p6) {
    __try { fn(actor, out, type, zone, hand, p6); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
// The caller contract from FireAction's tail: release our reference.
bool release_action(void* action) {
    __try {
        auto* vtbl = *reinterpret_cast<void***>(action);
        reinterpret_cast<void (*)(void*)>(vtbl[2])(action);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// ---- resolution -----------------------------------------------------------

void* resolve_actor(bool wantPlayer, uint32_t entityId) {
    HMODULE entityModule = GetModuleHandleA("EntityModule.dll");
    if (!entityModule) { logf("CW: EntityModule.dll not loaded -- REFUSING"); return nullptr; }
    const std::vector<ExportEntry> exports = module_exports(entityModule);
    if (exports.empty()) { logf("CW: no exports from EntityModule -- REFUSING"); return nullptr; }

    void* instanceSlot = find_export(exports, "?m_Instance@C_EntityModule@entitymodule@wh@@");
    if (!instanceSlot) { logf("CW: m_Instance export not found -- REFUSING"); return nullptr; }
    void* inst = *reinterpret_cast<void**>(instanceSlot);
    if (!inst) { logf("CW: C_EntityModule singleton is null -- REFUSING"); return nullptr; }

    void* actor = nullptr;
    if (wantPlayer) {
        void* fn = find_export(exports, "?GetPlayerActor@C_EntityModule@entitymodule@wh@@");
        if (!fn) { logf("CW: GetPlayerActor export not found -- REFUSING"); return nullptr; }
        if (!call_ptr_fn(reinterpret_cast<PtrFn>(fn), inst, &actor)) {
            logf("CW: GetPlayerActor faulted -- REFUSING"); return nullptr;
        }
    } else {
        void* bindFn = find_export(exports, "?GetScriptBindHuman@C_EntityModule@entitymodule@wh@@");
        if (!bindFn) { logf("CW: GetScriptBindHuman not found -- REFUSING"); return nullptr; }
        void* bind = nullptr;
        if (!call_ptr_fn(reinterpret_cast<PtrFn>(bindFn), inst, &bind) || !bind) {
            logf("CW: GetScriptBindHuman faulted/null -- REFUSING"); return nullptr;
        }
        auto resolve = reinterpret_cast<ResolveByIdFn>(
            reinterpret_cast<char*>(entityModule) + kRvaResolveActorById);
        if (!call_resolve_by_id(resolve, bind, entityId, &actor)) {
            logf("CW: entity-id resolve faulted (entityId=%u) -- REFUSING", entityId);
            return nullptr;
        }
    }
    return actor;
}

// Gate 3 + gate 4. Returns the model, or null with a reason logged.
void* resolve_model(void* actor) {
    void* combatActor = nullptr;
    if (!read_ptr(actor, kOffActorCombatActor, &combatActor) || !combatActor) {
        logf("CW: actor %p has no combat actor at +0x300 -- REFUSING"
             " (no fight has begun on this body)", actor);
        return nullptr;
    }
    void* model = nullptr;
    if (!read_ptr(combatActor, kOffCombatActorModel, &model) || !model) {
        logf("CW: combat actor %p has no model at +0x2F0 -- REFUSING", combatActor);
        return nullptr;
    }
    // KNOWN-ANSWER: does the model name its own property?
    void* namePtr = nullptr;
    char name[64]{};
    if (!read_ptr(static_cast<char*>(model) + kKnownPropBase, kPropName, &namePtr) || !namePtr ||
        !copy_cstr(static_cast<const char*>(namePtr), name, sizeof(name)) || name[0] == 0) {
        logf("CW: model+0x%zX has no readable registered name -- REFUSING", kKnownPropBase);
        return nullptr;
    }
    if (std::strcmp(name, kKnownPropName) != 0) {
        logf("CW: KNOWN-ANSWER FAILED -- model+0x%zX calls itself \"%s\", expected \"%s\"."
             " This is not the combat model on this build; refusing to write anything.",
             kKnownPropBase, name, kKnownPropName);
        return nullptr;
    }
    logf("CW: model=%p known-answer OK (model+0x%zX names itself \"%s\")",
         model, kKnownPropBase, name);
    return model;
}

// Gate 2.
bool verify_prologue(HMODULE combatModule, uintptr_t rva, const uint8_t* want,
                     size_t n, const char* what) {
    void* at = reinterpret_cast<char*>(combatModule) + rva;
    if (!bytes_match(at, want, n)) {
        logf("CW: PROLOGUE MISMATCH for %s at CombatModule+0x%llX -- refusing."
             " This build's bytes differ from the ones this code was read against,"
             " so the call would land on something else.", what,
             static_cast<unsigned long long>(rva));
        return false;
    }
    logf("CW: prologue OK for %s at CombatModule+0x%llX (%zu bytes)", what,
         static_cast<unsigned long long>(rva), n);
    return true;
}

// ---- the commands ---------------------------------------------------------

void dump_flags(void* model) {
    void* flags = static_cast<char*>(model) + kOffModelFlags;
    void* vptr = nullptr;
    read_ptr(flags, 0, &vptr);
    char line[256]{}; size_t used = 0;
    for (int i = 0; i <= kMaxFlagIndex; ++i) {
        uint8_t v = 0xFF;
        const bool ok = read_u8(flags, kOffFlagsBytes + static_cast<size_t>(i), &v);
        const int wrote = _snprintf_s(line + used, sizeof(line) - used, _TRUNCATE,
                                      "%s%d=%s", used ? " " : "", i,
                                      ok ? (v == 0 ? "0" : (v == 1 ? "1" : "?")) : "x");
        if (wrote <= 0) break;
        used += static_cast<size_t>(wrote);
        if (used + 8 >= sizeof(line)) break;
    }
    logf("CW-FLAGS: obj=%p vptr=%p bytes: %s   (one byte at a time -- the correct width)",
         flags, vptr, line);
}

void cmd_setflag(HMODULE combatModule, void* model, int index, int value) {
    if (index < 0 || index > kMaxFlagIndex) {
        logf("CW: flag index %d out of the bounded range 0..%d -- REFUSING", index, kMaxFlagIndex);
        return;
    }
    if (value != 0 && value != 1) {
        logf("CW: flag value %d is not 0 or 1 -- REFUSING", value);
        return;
    }
    if (!verify_prologue(combatModule, kRvaSetFlag, kPrologueSetFlag,
                         sizeof(kPrologueSetFlag), "SetFlag(0xF4C20)")) return;

    void* flags = static_cast<char*>(model) + kOffModelFlags;
    uint8_t before = 0;
    if (!read_u8(flags, kOffFlagsBytes + static_cast<size_t>(index), &before)) {
        logf("CW: flag[%d] not readable before the write -- REFUSING", index);
        return;
    }
    auto fn = reinterpret_cast<SetFlagFn>(reinterpret_cast<char*>(combatModule) + kRvaSetFlag);
    logf("CW-SET: calling SetFlag(obj=%p, index=%d, value=%d) -- flag[%d] reads %u before",
         flags, index, value, index, before);
    if (!call_set_flag(fn, flags, index, static_cast<uint8_t>(value))) {
        logf("CW-SET: the call FAULTED. No read-back is meaningful.");
        return;
    }
    uint8_t after = 0;
    if (!read_u8(flags, kOffFlagsBytes + static_cast<size_t>(index), &after)) {
        logf("CW-SET: flag[%d] not readable after the write", index);
        return;
    }
    logf("CW-SET: flag[%d] before=%u after=%u wanted=%d -- %s", index, before, after, value,
         (after == static_cast<uint8_t>(value))
            ? "TOOK (read back at one byte, the correct width)"
            : "DID NOT TAKE -- the call ran and the byte did not change");
    dump_flags(model);
}

void cmd_action(HMODULE combatModule, void* actor, int type, int zone, int hand, int p6) {
    if (!verify_prologue(combatModule, kRvaRequestAction, kPrologueRequestAction,
                         sizeof(kPrologueRequestAction), "RequestAction(0x76500)")) return;
    void* combatActor = nullptr;
    if (!read_ptr(actor, kOffActorCombatActor, &combatActor) || !combatActor) {
        logf("CW-ACT: no combat actor -- REFUSING"); return;
    }
    auto fn = reinterpret_cast<RequestActionFn>(
        reinterpret_cast<char*>(combatModule) + kRvaRequestAction);
    void* out = nullptr;
    logf("CW-ACT: calling RequestAction(actor=%p, &out, actionType=%d, zone=%d, hand=%d, p6=%d)"
         " -- actionType 6 is combat_action_type \"block\", the row the shipped AI uses",
         combatActor, type, zone, hand, p6);
    if (!call_request_action(fn, combatActor, &out, static_cast<uint8_t>(type), zone,
                             static_cast<uint8_t>(hand), p6)) {
        logf("CW-ACT: the call FAULTED.");
        return;
    }
    if (!out) {
        logf("CW-ACT: returned NULL -- the engine did not queue the action."
             " Its own line for this is \"Automated block was not triggered - anim queue failed!\";"
             " check kcd.log. A null return is a REAL answer, not a crash.");
        return;
    }
    logf("CW-ACT: returned %p (non-null). NOTE: a non-null return is NOT proof the block happened."
         " The admissible evidence is the block on screen. Releasing our reference, as"
         " C_CombatAutomationBlock::FireAction does.", out);
    if (!release_action(out))
        logf("CW-ACT: release (vtbl[2]) faulted -- one action's reference leaked");
}

// ---- trigger --------------------------------------------------------------

bool config_path(char* path, size_t n) {
    char cwd[MAX_PATH]{};
    if (GetCurrentDirectoryA(MAX_PATH, cwd) && cwd[0]) {
        char candidate[MAX_PATH]{};
        _snprintf_s(candidate, sizeof(candidate), _TRUNCATE, "%s%skcdmp-combatwrite.txt",
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
    std::strcpy(slash + 1, "kcdmp-combatwrite.txt");
    return true;
}

void run(const char* text) {
    char who[64]{}, cmd[32]{};
    int a = 0, b = 0, c = 0, d = -1;
    const int got = std::sscanf(text, "%63s %31s %d %d %d %d", who, cmd, &a, &b, &c, &d);
    if (got < 2) {
        logf("CW-WATCH: unparsable. Expected \"<player|entityId> flags\","
             " \"<player|entityId> setflag <index> <0|1>\" or"
             " \"<player|entityId> action <actionType> <zone> <hand> [p6]\"");
        return;
    }
    bool wantPlayer = false; uint32_t entityId = 0;
    if (_stricmp(who, "player") == 0) wantPlayer = true;
    else if (std::sscanf(who, "%u", &entityId) != 1) {
        logf("CW-WATCH: \"%s\" is neither \"player\" nor an entity id", who); return;
    }

    HMODULE combatModule = GetModuleHandleA("CombatModule.dll");
    if (!combatModule) { logf("CW: CombatModule.dll not loaded -- REFUSING"); return; }

    void* actor = resolve_actor(wantPlayer, entityId);
    if (!actor) return;
    void* model = resolve_model(actor);
    if (!model) return;

    if (_stricmp(cmd, "flags") == 0)        dump_flags(model);
    else if (_stricmp(cmd, "setflag") == 0) cmd_setflag(combatModule, model, a, b);
    else if (_stricmp(cmd, "action") == 0)  cmd_action(combatModule, actor, a, b, c,
                                                       (got >= 6) ? d : -1);
    else logf("CW-WATCH: unknown command \"%s\"", cmd);
}

} // namespace

void write_watch() {
    char path[MAX_PATH]{};
    if (!config_path(path, sizeof(path))) return;

    char text[256]{};
    FILE* f = nullptr;
    if (fopen_s(&f, path, "r") == 0 && f) {
        const size_t n = std::fread(text, 1, sizeof(text) - 1, f);
        text[n] = 0;
        std::fclose(f);
    }
    static char lastSeen[256]{};
    static bool haveLast = false;
    if (haveLast && std::strcmp(text, lastSeen) == 0) return;  // ONE-SHOT: fires only on a change
    strncpy_s(lastSeen, text, _TRUNCATE);
    haveLast = true;
    if (text[0] == 0) { logf("CW-WATCH: kcdmp-combatwrite.txt cleared/absent -- idle"); return; }
    logf("CW-WATCH: firing once for \"%s\"", text);
    run(text);
}

} // namespace kcdmp::combatwrite
