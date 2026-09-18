#include "npc_scan.h"
#include "log.h"

#include <windows.h>
#include <cmath>
#include <cstring>
#include <cctype>

namespace kcdmp::npcscan {
namespace {

// ---- CEntity layout (see local_state.cpp WO-102 S1.2; re-derived, not shared) --
constexpr uintptr_t kRvaCEntityVftable = 0x14FA18;   // CryEntitySystem.dll: CEntity::vftable
constexpr size_t kOffWorldTM = 0x58;
constexpr size_t kOffM00 = kOffWorldTM + 0x00, kOffM10 = kOffWorldTM + 0x10;
constexpr size_t kOffM01 = kOffWorldTM + 0x04, kOffM11 = kOffWorldTM + 0x14;
constexpr size_t kOffM20 = kOffWorldTM + 0x20;
constexpr size_t kOffPosX = kOffWorldTM + 0x0C, kOffPosY = kOffWorldTM + 0x1C, kOffPosZ = kOffWorldTM + 0x2C;
constexpr size_t kOffName = 0xE0;   // CScriptBind_Entity::GetName: plVar2[0x1c] = entity + 0xE0

// ---- vtable slots, all decompiled this session (see npc_scan.h header) --------
constexpr size_t kVtblEntityGetClass               = 0x18;   // IEntity
constexpr size_t kVtblEntitySystemGetClassRegistry = 0x58;   // IEntitySystem
constexpr size_t kVtblEntitySystemGetEntityIterator= 0xB0;   // IEntitySystem
constexpr size_t kVtblClassRegistryFindClass       = 0x18;   // IEntityClassRegistry
constexpr size_t kVtblIterAddRef    = 0x08, kVtblIterRelease = 0x10;
constexpr size_t kVtblIterNext      = 0x20, kVtblIterMoveFirst = 0x30;

// CryScriptSystem.dll's own private gEnv pointer, imageBase + this RVA
// (decompiled as DAT_18008e560 with imageBase 0x180000000 this session).
// +0xA0 off that is pEntitySystem -- both read by
// CScriptBind_System::GetEntitiesInSphere / GetEntitiesInSphereByClass.
constexpr uintptr_t kRvaCryScriptSystemGEnvPtr = 0x8E560;
constexpr size_t    kOffGEnvEntitySystem       = 0xA0;

constexpr int kMaxNameLen = 59;

// --- SEH-isolated primitives (no destructible locals; MSVC C2712) -----------
using PtrFn0 = void* (*)(void*);
using PtrFn1 = void* (*)(void*, const void*);
using VecFn  = void* (*)(void*, void*);   // hidden-return getter, e.g. GetWorldPos(this, &out)

bool call0(PtrFn0 fn, void* self, void** out) {
    __try { *out = fn(self); return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call1(PtrFn1 fn, void* self, const void* arg, void** out) {
    __try { *out = fn(self, arg); return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_vec(VecFn fn, void* self, void* outBuf) {
    __try { fn(self, outBuf); return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool read_ptr(const void* base, size_t off, void** out) {
    __try { *out = *reinterpret_cast<void* const*>(static_cast<const char*>(base) + off); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool read_f32(const void* base, size_t off, float* out) {
    __try { *out = *reinterpret_cast<const float*>(static_cast<const char*>(base) + off); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_vtbl(size_t slot, void* self, void** out) {
    void* vtbl = nullptr;
    if (!read_ptr(self, 0, &vtbl) || !vtbl) return false;
    void* fnPtr = nullptr;
    if (!read_ptr(vtbl, slot, &fnPtr) || !fnPtr) return false;
    return call0(reinterpret_cast<PtrFn0>(fnPtr), self, out);
}
bool call_vtbl1(size_t slot, void* self, const void* arg, void** out) {
    void* vtbl = nullptr;
    if (!read_ptr(self, 0, &vtbl) || !vtbl) return false;
    void* fnPtr = nullptr;
    if (!read_ptr(vtbl, slot, &fnPtr) || !fnPtr) return false;
    return call1(reinterpret_cast<PtrFn1>(fnPtr), self, arg, out);
}

// Copies a candidate name pointer defensively: bounded length, must be
// printable ASCII, must NUL-terminate inside the bound. Anything else is a
// failed read, not a guess (WO-97's negative-refCount CryString trap).
bool read_name_safe(const void* entity, char* outBuf, size_t outBufLen) {
    void* strPtr = nullptr;
    if (!read_ptr(entity, kOffName, &strPtr) || !strPtr) return false;
    __try {
        const char* s = static_cast<const char*>(strPtr);
        size_t i = 0;
        for (; i < outBufLen - 1 && i < static_cast<size_t>(kMaxNameLen); ++i) {
            char c = s[i];
            if (c == '\0') break;
            if (static_cast<unsigned char>(c) < 0x20 || static_cast<unsigned char>(c) > 0x7E) return false;
            outBuf[i] = c;
        }
        if (s[i] != '\0' && i >= static_cast<size_t>(kMaxNameLen)) return false;   // did not terminate in bound
        outBuf[i] = '\0';
        return i > 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool read_pos_yaw(const void* entity, float* x, float* y, float* z, float* yaw) {
    float m00, m10, m01, m11, m20;
    if (!read_f32(entity, kOffM00, &m00) || !read_f32(entity, kOffM10, &m10) ||
        !read_f32(entity, kOffM01, &m01) || !read_f32(entity, kOffM11, &m11) ||
        !read_f32(entity, kOffM20, &m20) ||
        !read_f32(entity, kOffPosX, x) || !read_f32(entity, kOffPosY, y) || !read_f32(entity, kOffPosZ, z))
        return false;
    if (!std::isfinite(*x) || !std::isfinite(*y) || !std::isfinite(*z) ||
        !std::isfinite(m00) || !std::isfinite(m10) || !std::isfinite(m20))
        return false;
    float sy = -m20; if (sy < -1.f) sy = -1.f; if (sy > 1.f) sy = 1.f;
    const float pitch = std::asin(sy);
    if (std::fabs(std::fabs(pitch) - 1.5707964f) >= 0.01f) *yaw = std::atan2(m10, m00);
    else *yaw = std::atan2(-m01, m11);
    return std::isfinite(*yaw);
}

// Process-lifetime cache: IEntityClass instances are load-time singletons,
// not per-world state (WO-99.5 S1.3's "do not cache engine pointers" is
// about actor/entity instances, which this file does NOT cache).
void* g_classNpc = nullptr;
void* g_classNpcFemale = nullptr;
void* g_classHorse = nullptr;
bool  g_classesResolved = false;
bool  g_announced = false;
uint8_t g_lastRefuse = 0xFF;

bool resolve_classes(void* entitySystem) {
    if (g_classesResolved) return true;
    void* registry = nullptr;
    if (!call_vtbl(kVtblEntitySystemGetClassRegistry, entitySystem, &registry) || !registry) return false;
    const char* npc = "NPC", *npcF = "NPC_Female", *horse = "Horse";
    void* cNpc = nullptr, *cNpcF = nullptr, *cHorse = nullptr;
    if (!call_vtbl1(kVtblClassRegistryFindClass, registry, npc, &cNpc) || !cNpc) return false;
    if (!call_vtbl1(kVtblClassRegistryFindClass, registry, npcF, &cNpcF) || !cNpcF) return false;
    if (!call_vtbl1(kVtblClassRegistryFindClass, registry, horse, &cHorse) || !cHorse) return false;
    g_classNpc = cNpc; g_classNpcFemale = cNpcF; g_classHorse = cHorse;
    g_classesResolved = true;
    logf("NPCSCAN: class registry resolved NPC=%p NPC_Female=%p Horse=%p", cNpc, cNpcF, cHorse);
    return true;
}

} // namespace

bool scan(const Anchor* anchors, int anchorCount, float radius, ScanResult* out) {
    if (!out || !anchors || anchorCount < 1) return false;
    *out = ScanResult{};

    auto fail = [&](uint8_t why) {
        out->refuse = why;
        if (why != g_lastRefuse) {
            logf("NPCSCAN: refusing (reason %u)", why);
            g_lastRefuse = why;
        }
        return false;
    };

    HMODULE entSysMod = GetModuleHandleA("CryEntitySystem.dll");
    HMODULE scriptSysMod = GetModuleHandleA("CryScriptSystem.dll");
    if (!entSysMod || !scriptSysMod) return fail(kModuleMissing);

    const void* cEntityVftable = reinterpret_cast<const char*>(entSysMod) + kRvaCEntityVftable;
    void* slot0 = nullptr;
    if (!read_ptr(cEntityVftable, 0, &slot0)) return fail(kGEnvUnmapped);
    {
        auto base = reinterpret_cast<uintptr_t>(entSysMod);
        auto p = reinterpret_cast<uintptr_t>(slot0);
        if (p < base || p >= base + 0x1C8000) return fail(kGEnvUnmapped);   // same image-bound gate as local_state.cpp
    }

    void* gEnvPtr = nullptr;
    if (!read_ptr(reinterpret_cast<const char*>(scriptSysMod) + kRvaCryScriptSystemGEnvPtr, 0, &gEnvPtr) || !gEnvPtr)
        return fail(kGEnvUnmapped);
    void* entitySystem = nullptr;
    if (!read_ptr(gEnvPtr, kOffGEnvEntitySystem, &entitySystem) || !entitySystem)
        return fail(kGEnvUnmapped);

    if (!resolve_classes(entitySystem)) return fail(kClassRegistryUnmapped);

    void* iter = nullptr;
    if (!call_vtbl(kVtblEntitySystemGetEntityIterator, entitySystem, &iter) || !iter)
        return fail(kGEnvUnmapped);
    { void* dummy = nullptr; call_vtbl(kVtblIterAddRef, iter, &dummy); }   // matches the decompiled AddRef-after-factory pattern

    auto release_iter = [&] { void* dummy = nullptr; call_vtbl(kVtblIterRelease, iter, &dummy); };

    { void* dummy = nullptr;
      if (!call_vtbl(kVtblIterMoveFirst, iter, &dummy)) { release_iter(); return fail(kReadFaulted); } }

    uint32_t total = 0, vptrOk = 0, vptrBad = 0, nameRejects = 0;
    size_t budget = kMaxReplyBytes;
    bool truncated = false;
    bool trustDecided = false;

    for (;;) {
        void* entity = nullptr;
        if (!call_vtbl(kVtblIterNext, iter, &entity) || !entity) break;
        ++total;

        void* vptr = nullptr;
        if (!read_ptr(entity, 0, &vptr) || vptr != cEntityVftable) {
            ++vptrBad;
            if (!trustDecided && total >= 5 && vptrOk == 0) { release_iter(); return fail(kGEnvUnmapped); }
            continue;
        }
        ++vptrOk;
        trustDecided = true;

        void* cls = nullptr;
        if (!call_vtbl(kVtblEntityGetClass, entity, &cls) || !cls) continue;
        const bool isHorse = (cls == g_classHorse);
        const bool isHuman = (cls == g_classNpc || cls == g_classNpcFemale);
        if (!isHorse && !isHuman) continue;

        float x, y, z, yaw;
        if (!read_pos_yaw(entity, &x, &y, &z, &yaw)) continue;

        bool inRange = false;
        for (int i = 0; i < anchorCount; ++i) {
            const float dx = x - anchors[i].x, dy = y - anchors[i].y;
            if (dx * dx + dy * dy <= radius * radius) { inRange = true; break; }
        }
        if (!inRange) continue;

        char name[60]{};
        if (!read_name_safe(entity, name, sizeof(name))) { ++nameRejects; continue; }

        const size_t entryBytes = 1 /*nameLen*/ + std::strlen(name) + 16 /*x,y,z,yaw*/ + 1 /*isHorse*/;
        if (entryBytes > budget) { truncated = true; break; }
        budget -= entryBytes;

        NpcEntry e{};
        std::strncpy(e.name, name, sizeof(e.name) - 1);
        e.x = x; e.y = y; e.z = z; e.yaw = yaw;
        e.isHorse = isHorse ? 1 : 0;
        out->entries.push_back(e);
    }

    release_iter();

    if (!trustDecided) return fail(kGEnvUnmapped);   // iterator produced nothing at all -- cannot validate, refuse rather than report an empty world as truth

    out->refuse = kOk;
    out->truncated = truncated;
    out->totalWalked = total;
    out->nameRejects = nameRejects;
    g_lastRefuse = kOk;

    if (!g_announced) {
        g_announced = true;
        logf("NPCSCAN: first scan OK total=%u vptrOk=%u vptrBad=%u matched=%zu nameRejects=%u truncated=%d",
             total, vptrOk, vptrBad, out->entries.size(), nameRejects, truncated ? 1 : 0);
    }
    return true;
}

} // namespace kcdmp::npcscan
