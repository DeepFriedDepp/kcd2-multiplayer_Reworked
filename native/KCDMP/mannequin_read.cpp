// WO-100 Phase 0 -- read the live Mannequin tag state for one actor.
//
// STRICTLY READ-ONLY. Nothing here writes engine memory, installs a hook, or
// queues an action. The only engine calls are three virtual getters the game
// itself calls every frame (GetAnimatedActor / GetActionController /
// GetContext), each SEH-isolated; everything after that is plain memory reads.
//
// ---------------------------------------------------------------------------
// Why these offsets, and what corroborates each one
// ---------------------------------------------------------------------------
// The chain is not inferred from stock CryEngine. It is read out of TWO
// independent shipped call sites in this exact build, which agree:
//
//   A) wh::animationmodule::C_AnimationController::QueueAction
//      (AnimationModule RVA 0x20410 -- identified by its own __FUNCTION__
//      string, WO-42's rule). Decompiled:
//
//          ctrl = animActor->vtbl[0x130]()          // GetActionController
//          ctx  = ctrl->vtbl[0xB0](ctrl)            // GetContext
//          defs = *(void**)(*(void**)ctx + 0x10)    // SControllerDef + 0x10
//          FlagsToTagList(out, (char*)ctx + 0x10, defs)   // TagState bytes
//          ctrl->vtbl[0x98](ctrl, action, layer)    // Queue
//
//   B) wh::entitymodule::C_Player::PlayAnim (EntityModule RVA 0xAE17A0, the
//      function WO-44 decompiled). Decompiled again this session:
//
//          animActor = actor->vtbl[0x2D0](actor)    // GetAnimatedActor
//          ctrl      = animActor->vtbl[0x130]()     // GetActionController
//          ctx       = ctrl->vtbl[0xB8](ctrl)       // GetContext (const)
//          fragDefs  = *(void**)(*(void**)ctx + 0x18)   // SControllerDef + 0x18
//
// A third, independent check: CActionController::vftable (CryAction RVA
// 0x483D98) has the SAME function at slots 22 (+0xB0) and 23 (+0xB8) --
// the const/non-const GetContext overload pair -- and that function is
// literally `return *(this + 0x28);`. So +0xB0 and +0xB8 are the same getter,
// which is why call sites A and B can use different ones.
//
// WO-44 reached +0x2D0 and +0x98 independently; WO-45 exercised the same
// 0x2D0 -> 0x130 chain live on real ghosts (the first native swings). So the
// chain has field mileage, not just a decompile.
//
// Layouts, all code-verified this session:
//
//   SAnimationContext  +0x00  const SControllerDef&
//                      +0x08  const CTagDefinition&   (the CTagState's m_defs)
//                      +0x10  TagState, 20 bytes
//   SControllerDef     +0x10  const CTagDefinition&   (global tags)
//                      +0x18  const CTagDefinition&   (fragment ids)
//   CTagDefinition     +0x08  tag array, count at [-4], stride 0x20,
//                             +0x04 = groupID (int, -1 = ungrouped),
//                             +0x18 = const char* name
//                      +0x18  per-tag   (byteIndex, mask) pairs, stride 2
//                      +0x20  per-group (byteIndex, mask) pairs, stride 2
//
// The membership test is copied from CTagDefinition::FlagsToTagList
// (AnimationModule RVA 0x2AA30), not reimplemented from first principles:
//
//   mask = tagBits[i].mask;  if (!mask) skip
//   gid  = tags[i].groupID
//   v    = (gid < 0) ? state[tagBits[i].byte] & mask
//                    : state[grpBits[gid].byte] & grpBits[gid].mask
//   set  = (v == mask)
//
// That means the bit layout lives in the live CTagDefinition as DATA. We never
// replicate AssignBits, so a tag XML change between builds cannot silently
// shift our decode -- it shifts the engine's table and we read the new table.
//
// SAnimationContext carries TWO routes to the tag definition (+0x08 directly,
// and +0x00 -> +0x10 through the controller def). The probe reads both and
// REFUSES if they disagree, rather than picking the convenient one -- the
// WO-96 §7 / WO-99.5 §2.5 discipline.
//
// Pseudo-speed: wh::entitymodule::C_Actor::GetPseudoSpeed (EntityModule RVA
// 0x97970) is `return *(float*)(*(void**)(this + 0x7E8) + 0x18);` with a
// trace line "Getting pseudospeed from actor without an AI Animation
// component" on the null path (code-verified). This is the animation-side
// speed scalar, NOT the physics-settled velocity. It is read as a field, so a
// subclass override would be bypassed -- stated here rather than hidden, and
// the known-answer check is whether it tracks what is on screen.

#include "mannequin_read.h"
#include "pe_exports.h"
#include "log.h"

#include <windows.h>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <vector>

namespace kcdmp::mannequin {

namespace {

// ---- offsets (see the header comment for the evidence behind each) ---------
constexpr size_t kVtblGetAnimatedActor     = 0x2D0;  // on C_Actor
constexpr size_t kVtblGetActionController  = 0x130;  // on the animated actor
constexpr size_t kVtblGetContext           = 0xB0;   // on IActionController
constexpr size_t kOffCtxControllerDef      = 0x00;
constexpr size_t kOffCtxTagDefs            = 0x08;
constexpr size_t kOffCtxTagState           = 0x10;
constexpr size_t kOffCtrlDefTagDefs        = 0x10;
constexpr size_t kOffTagDefTags            = 0x08;
constexpr size_t kOffTagDefTagBits         = 0x18;
constexpr size_t kOffTagDefGroupBits        = 0x20;
constexpr size_t kTagStride                = 0x20;
constexpr size_t kTagGroupIdOff            = 0x04;
constexpr size_t kTagNameOff               = 0x18;
constexpr size_t kTagStateBytes            = 20;
constexpr size_t kOffActorAiAnim           = 0x7E8;  // C_Actor -> AI animation component
constexpr size_t kOffAiAnimPseudoSpeed     = 0x18;

// --- WO-100 Phase 1: the combat model ---------------------------------------
//
// C_Actor + 0x300 is m_pCombatActor (WO-42 s9.5, already used by
// combat_construct.cpp). I_CombatActor + 0x2F0 is the combat MODEL -- WO-42
// recorded that offset under the vaguer name "combat state block", and the
// shipped assertion
//   "m_ZoneId == DATA_INVALID_ID || combatActor->GetModel().RequestedAtkZoneId.Get() == m_ZoneId"
// walks exactly `*(*(actor_combat + 0x2F0) + 0x200)` then calls vtbl[1] on it
// (code-verified, CombatModule 0x49FAF0).
//
// One function -- CombatModule 0xD8E50 -- registers every named property, and
// decompiling it gives the layout. Each property is 0x40 bytes:
//     base + 0x00  vptr
//     base + 0x08  the value (int/enum/bool)
//     base + 0x10  owner back-pointer, assigned from *(model + 0x1100)
//     base + 0x30  the registered debug NAME (a CryString data pointer)
//
// The name at +0x30 is what makes this a known-answer check rather than a
// plausible number: the probe reads the name back and reports whether the
// property at the offset we believe is RequestedInputClass calls ITSELF
// "RequestedInputClass". An offset that does not name-match is reported as a
// MISMATCH and its value is not trusted.
constexpr size_t kOffActorCombatActor      = 0x300;   // C_Actor::m_pCombatActor
constexpr size_t kOffCombatActorModel      = 0x2F0;   // I_CombatActor -> the model
constexpr size_t kOffModelOwnerSelf        = 0x1100;  // the value every property's owner is set from
constexpr size_t kPropValue                = 0x08;
constexpr size_t kPropOwner                = 0x10;
constexpr size_t kPropName                 = 0x30;

// CActionController::vftable, CryAction RVA -- the class-identity comparand.
constexpr uintptr_t kRvaCActionControllerVtbl = 0x483D98;

// EntityModule RVA, the entity-id -> C_Actor* resolver (WO-44 §9.6, reused by
// combat_construct.cpp under the same name).
constexpr uintptr_t kRvaResolveActorById = 0xB3C2D0;

// Sanity bounds. A CTagDefinition with more tags than this, or a byte index
// past the state, means we are not looking at a CTagDefinition -- refuse
// rather than print a plausible-looking decode.
constexpr int kMaxTags   = 4096;
constexpr int kMaxGroups = 512;

using PtrFn         = void* (*)(const void*);
using ResolveByIdFn = void* (*)(void* scriptBindHuman, uint32_t entityId);

// --- SEH-isolated primitives (no destructible locals; MSVC C2712) -----------

bool call_ptr_fn(PtrFn fn, const void* arg, void** out) {
    __try { *out = fn(arg); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool call_resolve_by_id(ResolveByIdFn fn, void* bind, uint32_t id, void** out) {
    __try { *out = fn(bind, id); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool call_vtbl_ptr(void* obj, size_t vtblByteOffset, void** out) {
    __try {
        auto* vtbl = *reinterpret_cast<void***>(obj);
        auto fn = reinterpret_cast<void* (*)(void*)>(vtbl[vtblByteOffset / 8]);
        *out = fn(obj);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool read_ptr(const void* base, size_t off, void** out) {
    __try { *out = *reinterpret_cast<void* const*>(static_cast<const char*>(base) + off); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool read_i32(const void* base, ptrdiff_t off, int32_t* out) {
    __try { *out = *reinterpret_cast<const int32_t*>(static_cast<const char*>(base) + off); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool read_f32(const void* base, size_t off, float* out) {
    __try { *out = *reinterpret_cast<const float*>(static_cast<const char*>(base) + off); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool read_u8(const void* base, size_t off, uint8_t* out) {
    __try { *out = *reinterpret_cast<const uint8_t*>(static_cast<const char*>(base) + off); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool copy_bytes(const void* src, void* dst, size_t n) {
    __try { std::memcpy(dst, src, n); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// Copy a C string out of engine memory with a hard bound, so a bad pointer
// cannot walk off the end of a page in the log formatter.
bool copy_cstr(const char* src, char* dst, size_t n) {
    __try {
        size_t i = 0;
        for (; i + 1 < n && src[i]; ++i) dst[i] = src[i];
        dst[i] = 0;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { dst[0] = 0; return false; }
}

// ---- config ---------------------------------------------------------------

struct Request {
    bool     wantPlayer = false;
    uint32_t entityId   = 0;
    unsigned periodMs   = 500;
    bool     dumpDefs   = false;   // one full tag-definition dump
    bool     combat     = false;   // WO-100 Phase 1: also read the combat model
};

// Game working directory first, then beside the DLL. Same reasoning as
// concept_read.cpp: %LocalAppData% is sandbox-redirected for the coding shell,
// the game root is not.
bool config_path(char* path, size_t n) {
    char cwd[MAX_PATH]{};
    if (GetCurrentDirectoryA(MAX_PATH, cwd) && cwd[0]) {
        char candidate[MAX_PATH]{};
        _snprintf_s(candidate, sizeof(candidate), _TRUNCATE, "%s%skcdmp-mannequin.txt",
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
    std::strcpy(slash + 1, "kcdmp-mannequin.txt");
    return true;
}

// "<player|entityId> [periodMs] [defs]"
bool parse_request(const char* text, Request* out) {
    char who[64]{}, a[32]{}, b[32]{}, c[32]{};
    const int got = std::sscanf(text, "%63s %31s %31s %31s", who, a, b, c);
    if (got < 1) return false;
    if (_stricmp(who, "player") == 0) { out->wantPlayer = true; }
    else if (std::sscanf(who, "%u", &out->entityId) != 1) return false;

    for (const char* tok : { a, b, c }) {
        if (!tok[0]) continue;
        if (_stricmp(tok, "defs") == 0)   { out->dumpDefs = true; continue; }
        if (_stricmp(tok, "combat") == 0) { out->combat   = true; continue; }
        unsigned v = 0;
        if (std::sscanf(tok, "%u", &v) == 1 && v >= 50 && v <= 60000) out->periodMs = v;
    }
    return true;
}

// ---- actor resolution (the combat_construct.cpp route, unchanged) ----------

void* resolve_actor(HMODULE entityModule, const std::vector<ExportEntry>& exports,
                    bool wantPlayer, uint32_t entityId) {
    void* instanceSlot = find_export(exports, "?m_Instance@C_EntityModule@entitymodule@wh@@");
    if (!instanceSlot) { logf("MANN: m_Instance export not found"); return nullptr; }
    void* inst = *reinterpret_cast<void**>(instanceSlot);
    if (!inst) { logf("MANN: C_EntityModule singleton is null"); return nullptr; }

    void* actor = nullptr;
    if (wantPlayer) {
        void* fn = find_export(exports, "?GetPlayerActor@C_EntityModule@entitymodule@wh@@");
        if (!fn) { logf("MANN: GetPlayerActor export not found"); return nullptr; }
        if (!call_ptr_fn(reinterpret_cast<PtrFn>(fn), inst, &actor)) {
            logf("MANN: GetPlayerActor faulted"); return nullptr;
        }
    } else {
        void* bindFn = find_export(exports, "?GetScriptBindHuman@C_EntityModule@entitymodule@wh@@");
        if (!bindFn) { logf("MANN: GetScriptBindHuman not found -- cannot take the entity-id route"); return nullptr; }
        void* bind = nullptr;
        if (!call_ptr_fn(reinterpret_cast<PtrFn>(bindFn), inst, &bind) || !bind) {
            logf("MANN: GetScriptBindHuman faulted/null"); return nullptr;
        }
        auto resolve = reinterpret_cast<ResolveByIdFn>(
            reinterpret_cast<char*>(entityModule) + kRvaResolveActorById);
        if (!call_resolve_by_id(resolve, bind, entityId, &actor)) {
            logf("MANN: entity-id resolve faulted (entityId=%u)", entityId);
            return nullptr;
        }
    }
    return actor;
}

// ---- the decode -----------------------------------------------------------

struct TagDefs {
    const void* obj      = nullptr;
    const char* tags     = nullptr;   // stride 0x20
    const uint8_t* tagBits   = nullptr;  // stride 2
    const uint8_t* groupBits = nullptr;  // stride 2
    int32_t     tagCount = 0;
};

bool load_tag_defs(const void* defsObj, TagDefs* out) {
    void* tags = nullptr; void* tagBits = nullptr; void* grpBits = nullptr;
    if (!read_ptr(defsObj, kOffTagDefTags, &tags) || !tags) return false;
    if (!read_ptr(defsObj, kOffTagDefTagBits, &tagBits) || !tagBits) return false;
    if (!read_ptr(defsObj, kOffTagDefGroupBits, &grpBits) || !grpBits) return false;
    int32_t n = 0;
    if (!read_i32(tags, -4, &n)) return false;
    if (n <= 0 || n > kMaxTags) return false;
    out->obj = defsObj;
    out->tags      = static_cast<const char*>(tags);
    out->tagBits   = static_cast<const uint8_t*>(tagBits);
    out->groupBits = static_cast<const uint8_t*>(grpBits);
    out->tagCount  = n;
    return true;
}

struct TagInfo {
    int32_t groupId = -1;
    uint8_t byteIdx = 0;
    uint8_t mask    = 0;
    char    name[64]{};
};

bool load_tag(const TagDefs& d, int i, TagInfo* out) {
    if (!read_i32(d.tags + static_cast<size_t>(i) * kTagStride, kTagGroupIdOff, &out->groupId)) return false;
    void* namePtr = nullptr;
    if (read_ptr(d.tags + static_cast<size_t>(i) * kTagStride, kTagNameOff, &namePtr) && namePtr)
        copy_cstr(static_cast<const char*>(namePtr), out->name, sizeof(out->name));
    else
        _snprintf_s(out->name, sizeof(out->name), _TRUNCATE, "<tag%d>", i);
    if (!read_u8(d.tagBits, static_cast<size_t>(i) * 2,     &out->byteIdx)) return false;
    if (!read_u8(d.tagBits, static_cast<size_t>(i) * 2 + 1, &out->mask))    return false;
    return true;
}

// The membership test, transcribed from CTagDefinition::FlagsToTagList.
// Returns -1 unknown, 0 clear, 1 set.
int tag_is_set(const TagDefs& d, const TagInfo& t, const uint8_t* state) {
    if (t.mask == 0) return 0;
    uint8_t byteIdx = t.byteIdx, mask = t.mask;
    if (t.groupId >= 0) {
        if (t.groupId > kMaxGroups) return -1;
        uint8_t gb = 0, gm = 0;
        if (!read_u8(d.groupBits, static_cast<size_t>(t.groupId) * 2,     &gb)) return -1;
        if (!read_u8(d.groupBits, static_cast<size_t>(t.groupId) * 2 + 1, &gm)) return -1;
        byteIdx = gb; mask = gm;
    }
    if (byteIdx >= kTagStateBytes) return -1;
    return ((state[byteIdx] & mask) == t.mask) ? 1 : 0;
}

void hex_state(const uint8_t* p, char* out /* >= 64 */) {
    static const char* kHex = "0123456789ABCDEF";
    for (size_t i = 0; i < kTagStateBytes; ++i) {
        out[i * 3]     = kHex[p[i] >> 4];
        out[i * 3 + 1] = kHex[p[i] & 0xF];
        out[i * 3 + 2] = ' ';
    }
    out[kTagStateBytes * 3 - 1] = 0;
}

// Names the probe reports as dedicated fields. These are read off
// Animations/Mannequin/ADB/kcd_male_tags.xml (shipped data, code-verified) --
// but the probe never assumes they exist: each one is reported as "-" if no
// tag of that name is set, so a build whose tag XML differs degrades to the
// full tag list rather than to a wrong answer.
const char* const kPace[]   = { "walk", "run", "sprint", "dash", "steps" };
const char* const kDir[]    = { "forward", "backward", "left", "right" };
const char* const kStance[] = { "stealth", "sitting", "sittingGround", "sittingNoTable",
                                "sittingOnTable", "lying", "lyingGround", "leaning",
                                "horse", "bath", "surrender", "wagon", "cart" };

bool in_list(const char* name, const char* const* list, size_t n) {
    for (size_t i = 0; i < n; ++i) if (std::strcmp(name, list[i]) == 0) return true;
    return false;
}

// ---- WO-100 Phase 1: the combat model --------------------------------------

// The value at base+8 is NOT always an int32. Live capture (2026-09-17) settled
// each of these by watching the bits move:
//   * AttackStrength read 1064546718 / 1059833454 -- nonsense as ints, and
//     0.952 / 0.671 as floats, which is exactly what a charge level looks like.
//   * CombatMode and PerfectBlockState changed by EXACTLY 1 in the low byte
//     when combat/blocking began, with three constant high bytes -- so they are
//     one-byte bools and a 4-byte read was spanning into the neighbouring
//     field. Reading them as int32 printed 925523968 and 1156810496: numbers
//     that look like data and are not.
// Reading the wrong width does not fail, it lies, so the width is part of the
// table rather than an assumption.
enum class PropType { I32, F32, Bool8 };
struct ModelProp { const char* name; size_t base; const char* what; PropType type; };

// Offsets read out of CombatModule 0xD8E50's decompilation. `name` is the
// string the engine itself registered at base + 0x30, so every row is
// self-checking.
const ModelProp kModelProps[] = {
    // the ACCEPTED INPUT -- upstream of the animation, which is the whole point
    { "RequestedInputClass",       0x300, "input",    PropType::I32   },
    { "RequestedAtkZone",          0x200, "input",    PropType::I32   },
    { "RequestedGuardZone",        0x180, "input",    PropType::I32   },
    { "RequestedPreparedToAttack", 0x380, "input",    PropType::Bool8 },
    { "ReqEndGuardType",           0x0C0, "input",    PropType::I32   },
    // the RESOLVED half, for comparison
    { "InputClass",                0x340, "resolved", PropType::I32   },
    { "AttackZone",                0x1C0, "resolved", PropType::I32   },
    { "AttackType",                0x2C0, "resolved", PropType::I32   },
    { "AttackStrength",            0x280, "resolved", PropType::F32   },
    { "AttackHandSlot",            0x240, "resolved", PropType::I32   },
    { "PreparedToAttack",          0x3C0, "resolved", PropType::Bool8 },
    { "GuardZone",                 0x140, "resolved", PropType::I32   },
    { "GuardType",                 0x080, "resolved", PropType::I32   },
    { "GuardStance",               0x100, "resolved", PropType::I32   },
    { "State",                     0x040, "resolved", PropType::I32   },  // a BITMASK: 1,2,4,8,16,64,128,256 observed
    { "ComboState",                0x480, "resolved", PropType::I32   },
    { "RiposteState",              0x4C0, "resolved", PropType::I32   },
    { "BlockZoneId",               0x7C0, "resolved", PropType::I32   },
    { "PerfectBlockState",         0x8A8, "resolved", PropType::Bool8 },
    { "CombatMode",                0x000, "resolved", PropType::Bool8 },
};

// Names from the shipped tables, so the log reads in the game's own words
// rather than in integers. Unknown ids print as the number -- never as a
// guessed name.
const char* input_class_name(int32_t v) {
    switch (v) {
        case -1: return "none";       case 0: return "attack_light";
        case 1:  return "attack_heavy"; case 2: return "attack_special";
        case 3:  return "move_left";  case 4: return "move_right";
        case 5:  return "move_back";  case 6: return "move_forward";
        case 7:  return "block";
    }
    return nullptr;
}
const char* zone_name(int32_t v) {
    switch (v) {
        case -1: return "undefined";  case 0: return "head";
        case 1:  return "upper_left"; case 2: return "upper_right";
        case 3:  return "lower_left"; case 4: return "lower_right";
        case 5:  return "lower";
    }
    return nullptr;
}
const char* attack_type_name(int32_t v) {
    switch (v) {
        case -1: return "none";  case 0: return "stab";  case 1: return "slash";
        case 2:  return "smash"; case 3: return "throw"; case 4: return "kick";
        case 5:  return "punch"; case 6: return "hook";  case 7: return "direct";
        case 8:  return "bite";  case 9: return "backoff";
    }
    return nullptr;
}

struct ModelSample { char line[900]; bool ok; int mismatches; };

// Read the whole model, name-checking every offset. Returns false only when the
// model itself is unreachable; a per-property mismatch is reported, not fatal.
bool sample_combat_model(void* actor, ModelSample* out, bool verbose) {
    out->line[0] = 0; out->ok = false; out->mismatches = 0;

    void* combatActor = nullptr;
    if (!read_ptr(actor, kOffActorCombatActor, &combatActor)) {
        _snprintf_s(out->line, sizeof(out->line), _TRUNCATE,
                    "MANN-COMBAT: actor+0x300 read faulted");
        return false;
    }
    if (!combatActor) {
        // Deliberately NOT calling GetOrCreateCombatActor: that creates state.
        // This probe is read-only, so "not in combat yet" is the honest answer.
        _snprintf_s(out->line, sizeof(out->line), _TRUNCATE,
                    "MANN-COMBAT: no combat actor on this body yet "
                    "(not created until combat begins) -- nothing to read, not an error");
        return false;
    }
    void* model = nullptr;
    if (!read_ptr(combatActor, kOffCombatActorModel, &model) || !model) {
        _snprintf_s(out->line, sizeof(out->line), _TRUNCATE,
                    "MANN-COMBAT: combatActor+0x2F0 (the model) unreadable/null -- REFUSING");
        return false;
    }
    // Self-check: every property's owner field was assigned from *(model+0x1100).
    void* ownerSelf = nullptr;
    if (!read_ptr(model, kOffModelOwnerSelf, &ownerSelf)) {
        _snprintf_s(out->line, sizeof(out->line), _TRUNCATE,
                    "MANN-COMBAT: model+0x1100 unreadable -- REFUSING");
        return false;
    }

    size_t used = 0;
    auto put = [&](const char* fmt, auto... args) {
        if (used + 2 >= sizeof(out->line)) return;
        int n = _snprintf_s(out->line + used, sizeof(out->line) - used, _TRUNCATE, fmt, args...);
        if (n > 0) used += static_cast<size_t>(n);
    };
    put("MANN-COMBAT:");

    for (const auto& p : kModelProps) {
        void* base = static_cast<char*>(model) + p.base;
        int32_t v = 0; float fv = 0.0f; uint8_t bv = 0;
        void* owner = nullptr; void* namePtr = nullptr;
        char nameBuf[64]{};
        bool nameOk = false, ownerOk = false, valueOk = false;
        switch (p.type) {
            case PropType::I32:   valueOk = read_i32(base, kPropValue, &v); break;
            case PropType::F32:   valueOk = read_f32(base, kPropValue, &fv); break;
            case PropType::Bool8: valueOk = read_u8 (base, kPropValue, &bv); break;
        }
        if (valueOk &&
            read_ptr(base, kPropOwner, &owner) &&
            read_ptr(base, kPropName, &namePtr) && namePtr &&
            copy_cstr(static_cast<const char*>(namePtr), nameBuf, sizeof(nameBuf))) {
            nameOk  = (std::strcmp(nameBuf, p.name) == 0);
            ownerOk = (owner == ownerSelf);
        }
        if (!nameOk) {
            ++out->mismatches;
            if (verbose)
                logf("MANN-COMBAT: MISMATCH model+0x%03zX expected \"%s\" but it names itself \"%s\" "
                     "-- offset NOT trusted", p.base, p.name, nameBuf[0] ? nameBuf : "<unreadable>");
            put(" %s=?", p.name);
            continue;
        }
        if (!ownerOk && verbose)
            logf("MANN-COMBAT: note model+0x%03zX (%s) owner=%p != model+0x1100=%p",
                 p.base, p.name, owner, ownerSelf);

        if (p.type == PropType::F32)   { put(" %s=%.3f", p.name, fv); continue; }
        if (p.type == PropType::Bool8) { put(" %s=%u", p.name, bv);   continue; }
        const char* sym = nullptr;
        if (std::strstr(p.name, "InputClass"))      sym = input_class_name(v);
        else if (std::strstr(p.name, "Zone"))       sym = zone_name(v);
        else if (std::strstr(p.name, "AttackType")) sym = attack_type_name(v);
        if (sym) put(" %s=%s", p.name, sym);
        else     put(" %s=%d", p.name, v);
    }
    out->ok = true;
    return true;
}

// ---- the sample ------------------------------------------------------------

struct Session {
    Request  req{};
    bool     armed       = false;
    bool     dumpedDefs  = false;
    bool     combatFirst = true;    // first combat pass logs mismatches verbosely
    char     lastCombat[900]{};
    unsigned combatRepeats = 0;
    DWORD    lastSample  = 0;
    char     lastLine[512]{};
    unsigned repeats     = 0;
};

Session g;

void dump_defs(const TagDefs& d) {
    logf("MANN: tag definition at %p -- %d tags", d.obj, d.tagCount);
    for (int i = 0; i < d.tagCount; ++i) {
        TagInfo t{};
        if (!load_tag(d, i, &t)) { logf("MANN:   [%d] unreadable", i); continue; }
        if (t.groupId >= 0) {
            uint8_t gb = 0, gm = 0;
            read_u8(d.groupBits, static_cast<size_t>(t.groupId) * 2,     &gb);
            read_u8(d.groupBits, static_cast<size_t>(t.groupId) * 2 + 1, &gm);
            logf("MANN:   [%3d] %-32s group=%-3d groupByte=%u groupMask=0x%02X value=0x%02X",
                 i, t.name, t.groupId, gb, gm, t.mask);
        } else {
            logf("MANN:   [%3d] %-32s ungrouped byte=%u mask=0x%02X",
                 i, t.name, t.byteIdx, t.mask);
        }
    }
}

void sample() {
    HMODULE entityModule = GetModuleHandleA("EntityModule.dll");
    HMODULE cryAction    = GetModuleHandleA("CryAction.dll");
    if (!entityModule) { logf("MANN: EntityModule.dll not loaded"); g.armed = false; return; }

    const std::vector<ExportEntry> exports = module_exports(entityModule);
    if (exports.empty()) {
        logf("MANN: could not read EntityModule exports"); g.armed = false; return;
    }

    void* actor = resolve_actor(entityModule, exports, g.req.wantPlayer, g.req.entityId);
    if (!actor) { logf("MANN: target actor did not resolve -- idling"); g.armed = false; return; }

    void* animActor = nullptr;
    if (!call_vtbl_ptr(actor, kVtblGetAnimatedActor, &animActor) || !animActor) {
        logf("MANN: actor->vtbl[0x2D0]() (GetAnimatedActor) faulted/null -- REFUSING");
        g.armed = false; return;
    }
    void* ctrl = nullptr;
    if (!call_vtbl_ptr(animActor, kVtblGetActionController, &ctrl) || !ctrl) {
        logf("MANN: animActor->vtbl[0x130]() (GetActionController) faulted/null -- REFUSING");
        g.armed = false; return;
    }

    // Class identity, the WO-99.5 step-0 discipline: do not trust an offset on
    // an object whose class we have not established.
    void* vptr = nullptr;
    if (!read_ptr(ctrl, 0, &vptr)) { logf("MANN: controller vptr unreadable -- REFUSING"); g.armed = false; return; }
    const void* expect = cryAction
        ? reinterpret_cast<const char*>(cryAction) + kRvaCActionControllerVtbl : nullptr;
    if (!expect) {
        logf("MANN: CryAction.dll not loaded -- cannot verify the controller class, REFUSING");
        g.armed = false; return;
    }
    if (vptr != expect) {
        logf("MANN: controller vptr %p != CActionController::vftable %p -- REFUSING. "
             "The GetContext offset is only established for CActionController; on an "
             "unknown class +0xB0 would return something else and print a plausible lie.",
             vptr, expect);
        g.armed = false; return;
    }

    void* ctx = nullptr;
    if (!call_vtbl_ptr(ctrl, kVtblGetContext, &ctx) || !ctx) {
        logf("MANN: ctrl->vtbl[0xB0]() (GetContext) faulted/null -- REFUSING");
        g.armed = false; return;
    }

    // Two routes to the tag definition. They must agree.
    void* ctrlDef = nullptr, *defsViaCtrlDef = nullptr, *defsViaCtx = nullptr;
    if (!read_ptr(ctx, kOffCtxControllerDef, &ctrlDef) || !ctrlDef ||
        !read_ptr(ctrlDef, kOffCtrlDefTagDefs, &defsViaCtrlDef) ||
        !read_ptr(ctx, kOffCtxTagDefs, &defsViaCtx)) {
        logf("MANN: could not read both tag-definition routes -- REFUSING");
        g.armed = false; return;
    }
    if (defsViaCtrlDef != defsViaCtx) {
        logf("MANN: tag-definition routes DISAGREE -- ctx+0x08=%p, controllerDef+0x10=%p. "
             "The layout premise is wrong on this build; refusing rather than guessing.",
             defsViaCtx, defsViaCtrlDef);
        g.armed = false; return;
    }

    TagDefs defs{};
    if (!load_tag_defs(defsViaCtx, &defs)) {
        logf("MANN: %p does not read as a CTagDefinition (bad arrays or count) -- REFUSING", defsViaCtx);
        g.armed = false; return;
    }

    if (g.req.dumpDefs && !g.dumpedDefs) { dump_defs(defs); g.dumpedDefs = true; }

    uint8_t state[kTagStateBytes]{};
    if (!copy_bytes(static_cast<const char*>(ctx) + kOffCtxTagState, state, sizeof(state))) {
        logf("MANN: TagState bytes unreadable -- REFUSING"); g.armed = false; return;
    }

    char all[400]{}; size_t used = 0;
    char pace[64] = "-", dir[64] = "-", stance[64] = "upright";
    int unknown = 0;
    for (int i = 0; i < defs.tagCount; ++i) {
        TagInfo t{};
        if (!load_tag(defs, i, &t)) { ++unknown; continue; }
        const int set = tag_is_set(defs, t, state);
        if (set < 0) { ++unknown; continue; }
        if (!set) continue;
        if (in_list(t.name, kPace,   _countof(kPace)))   strncpy_s(pace,   t.name, _TRUNCATE);
        if (in_list(t.name, kDir,    _countof(kDir)))    strncpy_s(dir,    t.name, _TRUNCATE);
        if (in_list(t.name, kStance, _countof(kStance))) strncpy_s(stance, t.name, _TRUNCATE);
        const size_t need = std::strlen(t.name) + 1;
        if (used + need + 1 < sizeof(all)) {
            if (used) all[used++] = '+';
            std::memcpy(all + used, t.name, need - 1);
            used += need - 1;
            all[used] = 0;
        }
    }

    // Animation-side speed scalar. Field read -- see the header comment.
    // Live 2026-09-17: reads 0.000 and tracks movement on an NPC body, but the
    // PLAYER always reads the sentinel -- C_Player overrides GetPseudoSpeed and
    // does not use this field, exactly as the base implementation's own trace
    // line ("Forgot to override GetPseudoSpeed?") implies. So a sentinel here
    // means "this actor overrides it", not "the offset is wrong".
    float pseudo = -1.0f;
    void* aiAnim = nullptr;
    if (read_ptr(actor, kOffActorAiAnim, &aiAnim) && aiAnim)
        read_f32(aiAnim, kOffAiAnimPseudoSpeed, &pseudo);

    char hex[64]{}; hex_state(state, hex);
    char line[512]{};
    _snprintf_s(line, sizeof(line), _TRUNCATE,
                "MANN: pace=%s dir=%s stance=%s pseudoSpeed=%.3f unknownTags=%d tags=%s",
                pace, dir, stance, pseudo, unknown, all[0] ? all : "<none>");

    // Collapse identical consecutive lines so a stationary player does not
    // flood the log, but never silently: the repeat count is printed when the
    // line finally changes, so "nothing happened" and "the probe stopped" stay
    // distinguishable (the WO-99.5 §1.5 lesson).
    if (std::strcmp(line, g.lastLine) == 0) { ++g.repeats; return; }
    if (g.repeats) { logf("MANN: (previous line repeated %u times)", g.repeats); g.repeats = 0; }
    strncpy_s(g.lastLine, line, _TRUNCATE);
    logf("%s", line);
    logf("MANN:   state=%s ctx=%p defs=%p", hex, ctx, defs.obj);
}

// WO-100 Phase 1. Separate from sample() because the two answer different
// questions and one can be reachable while the other is not: the tag state
// exists the moment the body does, the combat model only once combat has
// begun.
void sample_combat() {
    HMODULE entityModule = GetModuleHandleA("EntityModule.dll");
    if (!entityModule) return;
    const std::vector<ExportEntry> exports = module_exports(entityModule);
    if (exports.empty()) return;
    void* actor = resolve_actor(entityModule, exports, g.req.wantPlayer, g.req.entityId);
    if (!actor) return;

    ModelSample ms{};
    const bool got = sample_combat_model(actor, &ms, g.combatFirst);
    if (g.combatFirst) {
        g.combatFirst = false;
        if (got) logf("MANN-COMBAT: %d of %zu offsets failed their own name check",
                      ms.mismatches, sizeof(kModelProps) / sizeof(kModelProps[0]));
    }
    if (std::strcmp(ms.line, g.lastCombat) == 0) { ++g.combatRepeats; return; }
    if (g.combatRepeats) {
        logf("MANN-COMBAT: (previous line repeated %u times)", g.combatRepeats);
        g.combatRepeats = 0;
    }
    strncpy_s(g.lastCombat, ms.line, _TRUNCATE);
    logf("%s", ms.line);
}


// ---------------------------------------------------------------------------
// WO-100.5 Phase 2 -- the quiet, per-tick reduction used by the wire.
//
// Same chain, same five gates as sample(), minus every log line: this runs at
// the position stream's cadence and a probe that logs per sample is a flood.
// It refuses by returning false rather than by printing, and the CALLER counts
// refusals (MP-ANIM read=refused) so a silent failure is still visible once.
//
// WO-100 S10.2 settled the sampling question live: MoveSpeed/MoveDir are
// stable continuous state (6.3 s of unbroken run+forward at 50 ms), so there
// is no debouncing, smoothing or hold-and-confirm here and there should not
// be. The earlier "flicker" was 300 ms sampling over tapped keys.
//
// stopLegLeft / stopLegRight are deliberately NOT reduced into anything. They
// alternate at footfall rate (~370 ms at a jog) and the receiver's own
// animation system generates its own footfalls.
// ---------------------------------------------------------------------------

const char* const kStanceStealthNames[] = { "stealth" };
const char* const kStanceSittingNames[] = { "sitting", "sittingGround", "sittingNoTable", "sittingOnTable" };
const char* const kStanceLyingNames[]   = { "lying", "lyingGround" };
const char* const kStanceHorseNames[]   = { "horse" };
const char* const kStanceLeaningNames[] = { "leaning" };

uint8_t pace_ordinal(const char* n) {
    if (std::strcmp(n, "walk")   == 0) return kPaceWalk;
    if (std::strcmp(n, "run")    == 0) return kPaceRun;
    if (std::strcmp(n, "sprint") == 0) return kPaceSprint;
    if (std::strcmp(n, "dash")   == 0) return kPaceDash;
    if (std::strcmp(n, "steps")  == 0) return kPaceSteps;
    return kPaceNone;
}
uint8_t dir_ordinal(const char* n) {
    if (std::strcmp(n, "forward")  == 0) return kDirForward;
    if (std::strcmp(n, "backward") == 0) return kDirBackward;
    if (std::strcmp(n, "left")     == 0) return kDirLeft;
    if (std::strcmp(n, "right")    == 0) return kDirRight;
    return kDirNone;
}

} // namespace

bool read_body_state(bool wantPlayer, uint32_t entityId, BodyState* out) {
    if (!out) return false;
    *out = BodyState{};

    HMODULE entityModule = GetModuleHandleA("EntityModule.dll");
    HMODULE cryAction    = GetModuleHandleA("CryAction.dll");
    if (!entityModule || !cryAction) return false;
    const std::vector<ExportEntry> exports = module_exports(entityModule);
    if (exports.empty()) return false;

    void* actor = resolve_actor(entityModule, exports, wantPlayer, entityId);
    if (!actor) return false;

    void* animActor = nullptr;
    if (!call_vtbl_ptr(actor, kVtblGetAnimatedActor, &animActor) || !animActor) return false;
    void* ctrl = nullptr;
    if (!call_vtbl_ptr(animActor, kVtblGetActionController, &ctrl) || !ctrl) return false;

    // Gate 3: class identity. On any class other than CActionController the
    // +0xB0 hop returns something else and would decode a plausible lie.
    void* vptr = nullptr;
    if (!read_ptr(ctrl, 0, &vptr)) return false;
    if (vptr != reinterpret_cast<char*>(cryAction) + kRvaCActionControllerVtbl) return false;

    void* ctx = nullptr;
    if (!call_vtbl_ptr(ctrl, kVtblGetContext, &ctx) || !ctx) return false;

    // Gate 4: the two independent routes to the tag definition must agree.
    void* ctrlDef = nullptr, *viaCtrlDef = nullptr, *viaCtx = nullptr;
    if (!read_ptr(ctx, kOffCtxControllerDef, &ctrlDef) || !ctrlDef ||
        !read_ptr(ctrlDef, kOffCtrlDefTagDefs, &viaCtrlDef) ||
        !read_ptr(ctx, kOffCtxTagDefs, &viaCtx)) return false;
    if (viaCtrlDef != viaCtx) return false;

    TagDefs defs{};
    if (!load_tag_defs(viaCtx, &defs)) return false;

    uint8_t state[kTagStateBytes]{};
    if (!copy_bytes(static_cast<const char*>(ctx) + kOffCtxTagState, state, sizeof(state))) return false;

    int unknown = 0;
    bool sawStance = false;
    for (int i = 0; i < defs.tagCount; ++i) {
        TagInfo t{};
        if (!load_tag(defs, i, &t)) { ++unknown; continue; }
        const int set = tag_is_set(defs, t, state);
        if (set < 0) { ++unknown; continue; }
        if (!set) continue;

        if (const uint8_t p = pace_ordinal(t.name)) out->pace = p;
        if (const uint8_t d = dir_ordinal(t.name))  out->dir  = d;

        if (in_list(t.name, kStanceStealthNames, _countof(kStanceStealthNames))) { out->stance = kStanceStealth; sawStance = true; }
        else if (in_list(t.name, kStanceSittingNames, _countof(kStanceSittingNames))) { out->stance = kStanceSitting; sawStance = true; }
        else if (in_list(t.name, kStanceLyingNames,   _countof(kStanceLyingNames)))   { out->stance = kStanceLying;   sawStance = true; }
        else if (in_list(t.name, kStanceHorseNames,   _countof(kStanceHorseNames)))   { out->stance = kStanceHorse;   sawStance = true; }
        else if (in_list(t.name, kStanceLeaningNames, _countof(kStanceLeaningNames))) { out->stance = kStanceLeaning; sawStance = true; }
        else if (!sawStance && in_list(t.name, kStance, _countof(kStance))) {
            // A Stance-group tag we do not replicate. Report it as "other"
            // rather than as upright, and name it once so a field log says
            // WHICH one rather than leaving a silent downgrade.
            out->stance = kStanceOther;
            static char lastOther[64]{};
            if (std::strcmp(lastOther, t.name) != 0) {
                strncpy_s(lastOther, t.name, _TRUNCATE);
                logf("MANN-BODY: unreplicated stance tag \"%s\" -> stance=other", t.name);
            }
        }
    }

    // Animation-side speed. WO-100 S10.3 proved both halves of the caveat:
    // this field is populated on an ordinary actor and the PLAYER always reads
    // the -1.0 sentinel, because C_Player overrides GetPseudoSpeed.
    //
    // DECISION (WO-100.5 Phase 2 item 4): leave the vtable override alone and
    // send 0 for the sentinel. Pace and direction come from the tags, which
    // are the authoritative locomotion signal, so the channel costs nothing
    // without it -- and reaching through a vtable override to recover a
    // redundant scalar is a native call added for no behaviour. The field
    // stays on the wire because it is free and it is real on NPC bodies, which
    // is where the puppet path will want it.
    float pseudo = -1.0f;
    void* aiAnim = nullptr;
    if (read_ptr(actor, kOffActorAiAnim, &aiAnim) && aiAnim)
        read_f32(aiAnim, kOffAiAnimPseudoSpeed, &pseudo);
    if (pseudo > 0.0f) {
        const float centi = pseudo * 100.0f;
        out->animSpeedCenti = (centi >= 65535.0f) ? 65535u : static_cast<uint16_t>(centi);
    }

    out->unknownTags = (unknown > 255) ? 255 : static_cast<uint8_t>(unknown);
    return true;
}

namespace {

} // namespace

void tag_watch() {
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
    if (!haveLast || std::strcmp(text, lastSeen) != 0) {
        strncpy_s(lastSeen, text, _TRUNCATE);
        haveLast = true;
        g = Session{};
        if (text[0] == 0) { logf("MANN-WATCH: kcdmp-mannequin.txt cleared/absent -- idle"); return; }
        if (!parse_request(text, &g.req)) {
            logf("MANN-WATCH: unparsable -- expected \"<player|entityId> [periodMs] [defs] [combat]\"");
            return;
        }
        g.armed = true;
        logf("MANN-WATCH: armed target=%s%u period=%ums%s%s",
             g.req.wantPlayer ? "player" : "entity ",
             g.req.wantPlayer ? 0u : g.req.entityId, g.req.periodMs,
             g.req.dumpDefs ? " +defs" : "",
             g.req.combat ? " +combat" : "");
    }
    if (!g.armed) return;

    const DWORD now = GetTickCount();
    if (g.lastSample && (now - g.lastSample) < g.req.periodMs) return;
    g.lastSample = now;
    sample();
    if (g.req.combat) sample_combat();
}

} // namespace kcdmp::mannequin
