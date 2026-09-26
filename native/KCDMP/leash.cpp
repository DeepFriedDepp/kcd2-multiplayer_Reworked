#include "leash.h"
#include "log.h"
#include "main_thread.h"
#include "npc_drive.h"
#include "npc_scan.h"
#include "respawn_actions.h"

#include <windows.h>
#include <cmath>
#include <cstring>
#include <mutex>

namespace kcdmp::leash {
namespace {

// CryScriptSystem.dll's private gEnv slot (the one npc_scan.cpp reads, RVA
// 0x8E560); IsPointIndoors reads the same slot. gEnv+0x08 = p3DEngine.
constexpr uintptr_t kRvaCryScriptSystemGEnvPtr = 0x8E560;
constexpr size_t    kOffGEnv3DEngine           = 0x08;
constexpr size_t    kVtbl3DEngineGetVisAreaFromPos = 0x528;
constexpr size_t    kOffEntityFlags            = 0x08;   // CEntity: bit 0 active, bit 4 hidden

std::mutex g_lock;
Result     g_last;
bool       g_have = false;
bool       g_announced = false;

bool rd_ptr(const void* base, size_t off, void** out) {
    __try { *out = *reinterpret_cast<void* const*>(static_cast<const char*>(base) + off); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool rd_u32(const void* base, size_t off, uint32_t* out) {
    __try { *out = *reinterpret_cast<const uint32_t*>(static_cast<const char*>(base) + off); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_visarea(void* fn, void* self, const float* pos, void** out) {
    __try { *out = reinterpret_cast<void* (*)(void*, const float*)>(fn)(self, pos); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool in_module(const void* p, const char* moduleName) {
    HMODULE m = GetModuleHandleA(moduleName);
    MEMORY_BASIC_INFORMATION mbi{};
    if (!m || !p || VirtualQuery(p, &mbi, sizeof(mbi)) != sizeof(mbi)) return false;
    return mbi.AllocationBase == static_cast<void*>(m);   // every section of an image shares its base
}

// 1 indoors, 0 outdoors, -1 unknown. The 3D engine's vtable must sit in
// Cry3DEngine.dll before anything is called on it.
int interior_at(const float pos[3]) {
    HMODULE ss = GetModuleHandleA("CryScriptSystem.dll");
    void* genv = nullptr; void* eng = nullptr; void* vt = nullptr; void* fn = nullptr;
    if (!ss || !rd_ptr(reinterpret_cast<const char*>(ss) + kRvaCryScriptSystemGEnvPtr, 0, &genv) || !genv) return -1;
    if (!rd_ptr(genv, kOffGEnv3DEngine, &eng) || !eng || !rd_ptr(eng, 0, &vt) || !vt) return -1;
    if (!in_module(vt, "Cry3DEngine.dll")) return -1;
    if (!rd_ptr(vt, kVtbl3DEngineGetVisAreaFromPos, &fn) || !fn || !in_module(fn, "Cry3DEngine.dll")) return -1;
    void* area = nullptr;
    if (!call_visarea(fn, eng, pos, &area)) return -1;
    return area ? 1 : 0;
}

void visit(void* e, const char* name, float x, float y, float z, bool isHorse, void* ctx) {
    auto* out = static_cast<Result*>(ctx);
    if (std::strncmp(name, "kcd2mp_", 7) == 0) return;   // our own avatars of the peers, not NPCs
    Entry en{};
    en.x = x; en.y = y; en.z = z;
    std::strncpy(en.name, name, sizeof(en.name) - 1);
    uint16_t f = isHorse ? kHorse : 0;

    uint32_t ef = 0;
    if (rd_u32(e, kOffEntityFlags, &ef)) {
        f |= kEntFlagsKnown;
        if (ef & 0x10) f |= kHidden;
        if (ef & 0x01) f |= kActive;
    }

    npcdrive::PhysicsStatus ps{};
    npcdrive::physics_status(e, &ps);
    if (ps.present) f |= kPhysPresent;
    if (ps.awakeKnown) { f |= kAwakeKnown; if (ps.awake) f |= kAwake; }
    if (ps.living) f |= kLiving;
    if (ps.flying) f |= kFlying;
    if (ps.activeKnown) { f |= kSimKnown; if (ps.active) f |= kSimActive; }
    if (ps.speedKnown) en.speedCms = static_cast<uint16_t>(std::fmin(65534.f, std::fmax(0.f, ps.speed * 100.f)));

    int st = -1, mk = -1;
    uint64_t wuid = 0;
    if (actions::brain_state(e, &wuid, &st, &mk)) {
        f |= kBrainKnown;
        en.brainState = static_cast<int8_t>(st);
        en.brainMask = static_cast<uint8_t>(mk);
    }
    en.wuid = wuid;

    double age = -1; bool bound = false;
    npcdrive::stream_info(name, &age, &bound);
    if (bound) f |= kDriven;
    if (age >= 0) en.streamAgeMs = static_cast<uint16_t>(std::fmin(65534.0, age * 1000.0));

    en.flags = f;
    out->entries.push_back(en);
}

} // namespace

size_t entry_bytes(const Entry& e) {
    return 8 + 12 + 2 + 1 + 1 + 2 + 2 + 1 + std::strlen(e.name);
}

bool sample(const Anchor* anchors, int n, float radius, Result* out) {
    *out = Result{};
    if (!anchors || n < 1 || n > kMaxAnchors) return false;
    const double t0 = npcdrive::now_s();
    out->anchors = n;
    out->frames = static_cast<uint32_t>(main_thread::frame_count());
    npcscan::Anchor sa[kMaxAnchors];
    for (int i = 0; i < n; ++i) {
        sa[i].x = anchors[i].x; sa[i].y = anchors[i].y; sa[i].z = anchors[i].z;
        const float p[3] = {anchors[i].x, anchors[i].y, anchors[i].z};
        bool inside = false;
        if (actions::in_settlement(p, &inside)) out->town[i] = inside ? 1 : 0;
        out->interior[i] = static_cast<int8_t>(interior_at(p));
    }
    const bool ok = npcscan::for_each_in_radius(sa, n, radius, &visit, out, &out->walked, &out->refuse);
    out->sampleUs = static_cast<uint32_t>((npcdrive::now_s() - t0) * 1e6);
    if (!g_announced && ok) {
        g_announced = true;
        size_t brain = 0, ents = 0;
        for (const auto& e : out->entries) { if (e.flags & kBrainKnown) ++brain; if (e.flags & kEntFlagsKnown) ++ents; }
        logf("MP-LEASH first sample: walked=%u matched=%zu brain_known=%zu flags_known=%zu town0=%d interior0=%d sample_us=%u",
             out->walked, out->entries.size(), brain, ents, out->town[0], out->interior[0], out->sampleUs);
    }
    std::lock_guard<std::mutex> lk(g_lock);
    g_last = *out;
    g_have = ok;
    return ok;
}

bool page(uint16_t offset, size_t budgetBytes, Result* out, uint16_t* total) {
    std::lock_guard<std::mutex> lk(g_lock);
    if (!g_have) return false;
    *out = g_last;
    out->entries.clear();
    *total = static_cast<uint16_t>(g_last.entries.size() > 0xFFFF ? 0xFFFF : g_last.entries.size());
    size_t used = 0;
    for (size_t i = offset; i < g_last.entries.size(); ++i) {
        const size_t b = entry_bytes(g_last.entries[i]);
        if (used + b > budgetBytes) break;
        used += b;
        out->entries.push_back(g_last.entries[i]);
    }
    return true;
}

} // namespace kcdmp::leash
