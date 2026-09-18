#include "local_state.h"
#include "main_thread.h"
#include "pe_exports.h"
#include "log.h"

#include <windows.h>
#include <cmath>
#include <cstring>
#include <vector>

namespace kcdmp::localstate {
namespace {

// ---- constants (all code-verified in docs/WO-102-findings.md S1) ----------
constexpr uintptr_t kRvaCEntityVftable = 0x14FA18;   // CryEntitySystem.dll: CEntity::vftable (RTTI COL confirms class CEntity)
constexpr size_t    kOffWorldTM        = 0x58;       // CEntity: Matrix34 m_worldTM (row-major 3x4)
constexpr size_t    kOffM00 = kOffWorldTM + 0x00, kOffM10 = kOffWorldTM + 0x10, kOffM20 = kOffWorldTM + 0x20;
constexpr size_t    kOffM01 = kOffWorldTM + 0x04, kOffM11 = kOffWorldTM + 0x14;   // the gimbal branch's inputs
constexpr size_t    kOffPosX = kOffWorldTM + 0x0C, kOffPosY = kOffWorldTM + 0x1C, kOffPosZ = kOffWorldTM + 0x2C;   // 0x64, 0x74, 0x84

// Candidate slots for IGameObjectExtension::m_pEntity on this build's
// C_Actor. IComponent = vptr + std::enable_shared_from_this (weak_ptr, 16
// bytes) -> the extension's own members start at 0x18: m_pGameObject,
// m_entityId (4 + pad), m_pEntity -> 0x28 is the textbook answer, the others
// are the neighbours in case IActor carries a member. The vftable gate below
// is what decides; the order only sets which is tried first.
constexpr size_t kEntityHopCandidates[] = { 0x28, 0x30, 0x38, 0x18, 0x20 };

using PtrFn = void* (*)(const void*);

// --- SEH-isolated primitives (no destructible locals; MSVC C2712) -----------
bool call_ptr_fn(PtrFn fn, const void* arg, void** out) {
    __try { *out = fn(arg); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool read_ptr(const void* base, size_t off, void** out) {
    __try { *out = *reinterpret_cast<void* const*>(static_cast<const char*>(base) + off); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool read_f32(const void* base, size_t off, float* out) {
    __try { *out = *reinterpret_cast<const float*>(static_cast<const char*>(base) + off); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

void* resolve_player_actor(uint8_t* refuse) {
    HMODULE entityModule = GetModuleHandleA("EntityModule.dll");
    if (!entityModule) { *refuse = kModuleMissing; return nullptr; }
    const std::vector<ExportEntry> exports = module_exports(entityModule);
    void* instanceSlot = find_export(exports, "?m_Instance@C_EntityModule@entitymodule@wh@@");
    void* fn = find_export(exports, "?GetPlayerActor@C_EntityModule@entitymodule@wh@@");
    if (!instanceSlot || !fn) { *refuse = kModuleMissing; return nullptr; }
    void* inst = *reinterpret_cast<void**>(instanceSlot);
    if (!inst) { *refuse = kNoPlayerActor; return nullptr; }
    void* actor = nullptr;
    if (!call_ptr_fn(reinterpret_cast<PtrFn>(fn), inst, &actor)) { *refuse = kReadFaulted; return nullptr; }
    if (!actor) { *refuse = kNoPlayerActor; return nullptr; }
    return actor;
}

// The one piece of state kept across calls: WHICH slot held the entity last
// time. It is re-validated on every read (the vptr gate runs each time), so a
// world change that moves things cannot make it lie -- WO-99.5 S1.3: no
// cached engine pointer, only a cached offset behind a per-call check.
size_t g_hopOffset = 0;
bool   g_announced = false;
uint8_t g_lastRefuse = 0xFF;

void* resolve_entity(void* actor, const void* cEntityVftable, uint8_t* refuse) {
    auto try_slot = [&](size_t off) -> void* {
        void* ent = nullptr; void* vptr = nullptr;
        if (!read_ptr(actor, off, &ent) || !ent) return nullptr;
        if (!read_ptr(ent, 0, &vptr)) return nullptr;
        return vptr == cEntityVftable ? ent : nullptr;
    };
    if (g_hopOffset) {
        if (void* e = try_slot(g_hopOffset)) return e;
        logf("LOCALSTATE: entity hop actor+0x%zX no longer reads as a CEntity -- re-scanning", g_hopOffset);
        g_hopOffset = 0;
    }
    for (size_t off : kEntityHopCandidates) {
        if (void* e = try_slot(off)) {
            g_hopOffset = off;
            logf("LOCALSTATE: entity hop = actor+0x%zX (pointee vptr == CEntity::vftable)", off);
            return e;
        }
    }
    *refuse = kEntityHopUnmapped;
    return nullptr;
}

} // namespace

bool read_local_state(LocalState* out) {
    if (!out) return false;
    *out = LocalState{};
    out->frame = main_thread::frame_count();

    auto fail = [&](uint8_t why) {
        out->refuse = why;
        if (why != g_lastRefuse) {   // one line per verdict change, not per sample
            logf("LOCALSTATE: refusing (reason %u)", why);
            g_lastRefuse = why;
        }
        return false;
    };

    HMODULE entSys = GetModuleHandleA("CryEntitySystem.dll");
    if (!entSys) return fail(kModuleMissing);
    const void* cEntityVftable = reinterpret_cast<const char*>(entSys) + kRvaCEntityVftable;
    // Gate: the RVA must at least read as a vtable -- a pointer into
    // CryEntitySystem's own image. Build drift shows up here, not as a
    // plausible position.
    void* slot0 = nullptr;
    if (!read_ptr(cEntityVftable, 0, &slot0)) return fail(kVtableMismatch);
    {
        auto base = reinterpret_cast<uintptr_t>(entSys);
        auto p = reinterpret_cast<uintptr_t>(slot0);
        // 0x1C8000 = CryEntitySystem.dll's SizeOfImage on this build (PE header, code-verified);
        // a real vtable slot lands inside the image, a stray read does not.
        if (p < base || p >= base + 0x1C8000) return fail(kVtableMismatch);
    }

    uint8_t why = kOk;
    void* actor = resolve_player_actor(&why);
    if (!actor) return fail(why);
    void* ent = resolve_entity(actor, cEntityVftable, &why);
    if (!ent) return fail(why);

    float m00, m10, m20, m01, m11, px, py, pz;
    if (!read_f32(ent, kOffM00, &m00) || !read_f32(ent, kOffM10, &m10) || !read_f32(ent, kOffM20, &m20) ||
        !read_f32(ent, kOffM01, &m01) || !read_f32(ent, kOffM11, &m11) ||
        !read_f32(ent, kOffPosX, &px) || !read_f32(ent, kOffPosY, &py) || !read_f32(ent, kOffPosZ, &pz))
        return fail(kReadFaulted);
    if (!std::isfinite(px) || !std::isfinite(py) || !std::isfinite(pz) ||
        !std::isfinite(m00) || !std::isfinite(m10) || !std::isfinite(m20))
        return fail(kNonFinite);

    // Ang3::GetAnglesXYZ, exactly as CScriptBind_Entity::GetWorldAngles does it
    // (decompiled): yaw = atan2(m10, m00) unless pitched to +-90 deg.
    float sy = -m20; if (sy < -1.f) sy = -1.f; if (sy > 1.f) sy = 1.f;
    const float pitch = std::asin(sy);
    float yaw;
    if (std::fabs(std::fabs(pitch) - 1.5707964f) >= 0.01f) yaw = std::atan2(m10, m00);
    else yaw = std::atan2(-m01, m11);   // the handler's degenerate branch: atan2(-m01, m11)
    if (!std::isfinite(yaw)) return fail(kNonFinite);

    out->x = px; out->y = py; out->z = pz; out->rotZ = yaw;

    // Body state in the same frame. Its refusal is not this read's refusal:
    // position is still valid without it, the agent just sends the 17-byte
    // packet -- exactly the log path's behaviour when 0x09 refuses.
    kcdmp::mannequin::BodyState bs{};
    if (kcdmp::mannequin::read_body_state(true, 0, &bs)) {
        out->haveBody = true;
        out->body = bs;
        if (bs.stance == kcdmp::mannequin::kStanceHorse) out->flags |= 0x01;
    }

    if (!g_announced) {
        g_announced = true;
        logf("LOCALSTATE: first read OK frame=%llu pos=(%.2f, %.2f, %.2f) yaw=%.3f body=%d riding=%d actor=%p entity=%p",
             static_cast<unsigned long long>(out->frame), px, py, pz, yaw, out->haveBody ? 1 : 0, out->flags & 1, actor, ent);
    }
    g_lastRefuse = kOk;
    out->refuse = kOk;
    return true;
}

} // namespace kcdmp::localstate
