#include "engine.h"
#include "anchors.h"
#include "log.h"

#include <windows.h>
#include <cmath>
#include <cstring>

namespace kcdmp::engine {

namespace {

constexpr const char* kGenvAnchor = "Unable to find HangoverSpotsHub from sa_land (via link '%s')";   // PlayerModule
constexpr const char* kGetGameIface = "?GetGameIface@wh@@YAPEBVC_GameInterface@shared@1@XZ";

constexpr size_t kEnvEntitySystem = 0xA0;
constexpr size_t kEnvConsole      = 0xA8;

constexpr size_t kEsClassRegistry = 0x58;
constexpr size_t kEsSpawn         = 0x60;
constexpr size_t kEsGetEntity     = 0x70;
constexpr size_t kEsByGuid        = 0x78;
constexpr size_t kEsRemove        = 0x98;
constexpr size_t kEsIterator      = 0xB0;
constexpr size_t kRegFindClass    = 0x18;
constexpr size_t kItAddRef = 0x08, kItRelease = 0x10, kItNext = 0x20, kItMoveFirst = 0x30;

constexpr size_t kEntGetId        = 0x08;
constexpr size_t kEntGetGuid      = 0x10;
constexpr size_t kEntAddFlags     = 0x38;
constexpr size_t kEntGetName      = 0x90;
constexpr size_t kEntSetPos       = 0x138;
constexpr size_t kEntGetWorldPos  = 0x170;
constexpr size_t kEntLoadGeometry = 0x360;

constexpr size_t kConGetCVar      = 0xB8;
constexpr size_t kCVarGetIVal     = 0x10;
constexpr size_t kCVarSetInt      = 0x38;
constexpr size_t kCVarGetType     = 0x70;

bool          g_ready = false;
bool          g_failed = false;
void**        g_genvSlot = nullptr;
void*         g_getGameIface = nullptr;
void* const*  g_vftEntitySystem = nullptr;
void* const*  g_vftConsole = nullptr;
void* const*  g_vftEntity = nullptr;

bool rd(const void* base, size_t off, void** out) {
    __try { *out = *reinterpret_cast<void* const*>(static_cast<const char*>(base) + off); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
void* vslot(void* obj, size_t off) {
    void* vt = nullptr; void* fn = nullptr;
    if (!obj || !rd(obj, 0, &vt) || !vt || !rd(vt, off, &fn)) return nullptr;
    return fn;
}
bool is_a(void* obj, void* const* vft) {
    void* vp = nullptr;
    return obj && vft && rd(obj, 0, &vp) && vp == static_cast<const void*>(vft);
}

template <typename R, typename... A>
bool vcall(void* obj, size_t off, R* out, A... a) {
    void* fn = vslot(obj, off);
    if (!fn) return false;
    __try { *out = reinterpret_cast<R (*)(void*, A...)>(fn)(obj, a...); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
template <typename... A>
bool vcall_void(void* obj, size_t off, A... a) {
    void* fn = vslot(obj, off);
    if (!fn) return false;
    __try { reinterpret_cast<void (*)(void*, A...)>(fn)(obj, a...); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool call_gi(void* fn, void** out) {
    __try { *out = reinterpret_cast<void* (*)()>(fn)(); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool copy_str(const char* s, char* out, size_t n) {
    __try {
        size_t i = 0;
        for (; i + 1 < n && s[i]; ++i) out[i] = s[i];
        out[i] = 0;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { if (n) out[0] = 0; return false; }
}

} // namespace

bool ready() { return g_ready; }

bool resolve() {
    if (g_ready) return true;
    if (g_failed) return false;
    char d[256]{};
    HMODULE pm = GetModuleHandleA("PlayerModule.dll");
    HMODULE es = GetModuleHandleA("CryEntitySystem.dll");
    HMODULE sys = GetModuleHandleA("CrySystem.dll");
    HMODULE shared = GetModuleHandleA("Shared.dll");
    if (!pm || !es || !sys || !shared) return false;   // not loaded yet: retry later

    auto fail = [&](const char* why) {
        logf("ENGINE: ANCHOR FAILED -- %s; engine services OFF", why);
        g_failed = true;
        return false;
    };

    const uint8_t* fn = anchor::function_by_string(pm, kGenvAnchor);
    if (!fn) return fail("gEnv anchor function (ValidateAlcoTeleportPoints) not found by its string");
    static const uint8_t kMovRaxRip[] = {0x48, 0x8B, 0x05};
    static const uint8_t kMovRcxRaxA0[] = {0x48, 0x8B, 0x88, 0xA0, 0x00, 0x00, 0x00};
    // "mov rax,[rip+X]; lea rdx,[r9+8]; mov rcx,[rax+0xA0]" -- the second
    // instruction sits between, so the window spans it.
    const uint8_t* m = anchor::function_find_sequence(pm, fn, kMovRaxRip, sizeof(kMovRaxRip),
                                                      kMovRcxRaxA0, sizeof(kMovRcxRaxA0), 16);
    void** slotp = m ? const_cast<void**>(static_cast<void* const*>(anchor::rip_target(m))) : nullptr;
    anchor::Range data{};
    if (!slotp || !anchor::section(pm, ".data", &data) || !data.contains(slotp))
        return fail("gEnv slot not lifted from the anchor function");
    g_genvSlot = slotp;

    g_getGameIface = GetProcAddress(shared, kGetGameIface);
    if (!g_getGameIface) return fail("Shared.dll GetGameIface export missing");

    g_vftEntitySystem = anchor::find_vftable(es, ".?AVCEntitySystem@@", 0);
    g_vftEntity = anchor::find_vftable(es, ".?AVCEntity@@", 0);
    g_vftConsole = anchor::find_vftable(sys, ".?AVCXConsole@@", 0);
    if (!g_vftEntitySystem || !g_vftEntity || !g_vftConsole)
        return fail("RTTI CEntitySystem / CEntity / CXConsole vftable not unique");

    const char* sSpawn = anchor::find_cstring(es, "CEntitySystem::SpawnEntity");
    const char* sRemove = anchor::find_cstring(es, "CEntitySystem::RemoveEntity %s %s 0x%x");
    if (!sSpawn || !anchor::function_refs(es, g_vftEntitySystem[kEsSpawn / 8], sSpawn))
        return fail("IEntitySystem slot 0x60 is not SpawnEntity");
    if (!sRemove || !anchor::function_refs(es, g_vftEntitySystem[kEsRemove / 8], sRemove))
        return fail("IEntitySystem slot 0x98 is not RemoveEntity");

    void* env = genv();
    void* ents = nullptr; void* con = nullptr;
    if (!env || !rd(env, kEnvEntitySystem, &ents) || !is_a(ents, g_vftEntitySystem))
        return fail("gEnv+0xA0 is not the CEntitySystem");
    if (!rd(env, kEnvConsole, &con) || !is_a(con, g_vftConsole))
        return fail("gEnv+0xA8 is not the CXConsole");

    anchor::describe(slotp, d, sizeof(d));
    logf("ENGINE: gEnv slot %s (lifted from ValidateAlcoTeleportPoints); CEntitySystem/CXConsole verified by RTTI; "
         "SpawnEntity/RemoveEntity verified by name", d);
    g_ready = true;
    return true;
}

void* genv() {
    void* env = nullptr;
    return (g_genvSlot && rd(g_genvSlot, 0, &env)) ? env : nullptr;
}

void* game_iface() {
    void* gi = nullptr;
    return (g_getGameIface && call_gi(g_getGameIface, &gi)) ? gi : nullptr;
}

void* entity_system() {
    void* env = genv(); void* es = nullptr;
    return (env && rd(env, kEnvEntitySystem, &es) && is_a(es, g_vftEntitySystem)) ? es : nullptr;
}

void* console() {
    void* env = genv(); void* con = nullptr;
    return (env && rd(env, kEnvConsole, &con) && is_a(con, g_vftConsole)) ? con : nullptr;
}

void* entity_by_id(uint32_t id) {
    void* es = entity_system(); void* e = nullptr;
    if (!es || !id || !vcall(es, kEsGetEntity, &e, id)) return nullptr;
    return is_a(e, g_vftEntity) ? e : nullptr;
}

void* entity_by_guid(uint64_t guid) {
    void* es = entity_system(); void* e = nullptr;
    if (!es || !guid || !vcall(es, kEsByGuid, &e, static_cast<const uint64_t*>(&guid))) return nullptr;
    return is_a(e, g_vftEntity) ? e : nullptr;
}

uint32_t entity_id(void* e) {
    uint32_t id = 0;
    return (is_a(e, g_vftEntity) && vcall(e, kEntGetId, &id)) ? id : 0;
}

uint64_t entity_guid(void* e) {
    uint64_t g = 0;
    return (is_a(e, g_vftEntity) && vcall(e, kEntGetGuid, &g)) ? g : 0;
}

const char* entity_name(void* e) {
    const char* n = nullptr;
    return (is_a(e, g_vftEntity) && vcall(e, kEntGetName, &n)) ? n : nullptr;
}

bool entity_world_pos(void* e, float out[3]) {
    if (!is_a(e, g_vftEntity)) return false;
    float buf[4]{};
    void* ret = nullptr;
    if (!vcall(e, kEntGetWorldPos, &ret, static_cast<float*>(buf))) return false;
    out[0] = buf[0]; out[1] = buf[1]; out[2] = buf[2];
    return std::isfinite(out[0]) && std::isfinite(out[1]) && std::isfinite(out[2]);
}

bool entity_set_pos(void* e, const float pos[3]) {
    if (!is_a(e, g_vftEntity)) return false;
    return vcall_void(e, kEntSetPos, pos, 0, false, false);
}

bool entity_add_flags(void* e, uint32_t flags) {
    return is_a(e, g_vftEntity) && vcall_void(e, kEntAddFlags, flags);
}

int entity_load_geometry(void* e, int slot, const char* file, int flags) {
    int r = -1;
    if (!is_a(e, g_vftEntity) || !vcall(e, kEntLoadGeometry, &r, slot, file, static_cast<const char*>(nullptr), flags))
        return -1;
    return r;
}

void* spawn(const char* className, const char* name, const float pos[3], uint32_t flags, uint64_t guid) {
    void* es = entity_system();
    if (!es) return nullptr;
    void* reg = nullptr; void* cls = nullptr;
    if (!vcall(es, kEsClassRegistry, &reg) || !reg) return nullptr;
    if (!vcall(reg, kRegFindClass, &cls, className) || !cls) {
        logf("ENGINE: spawn: no entity class '%s'", className);
        return nullptr;
    }
    alignas(16) uint8_t p[0x100]{};
    std::memcpy(p + 0x08, &guid, 8);
    std::memcpy(p + 0x18, &cls, 8);
    static const char* kEmpty = "";
    std::memcpy(p + 0x28, &kEmpty, 8);
    std::memcpy(p + 0x40, &name, 8);
    const uint32_t f = flags | kFlagSpawned;
    const uint32_t fx = 0x400000;   // the Lua bind sets this Warhorse bit on every spawn
    std::memcpy(p + 0x48, &f, 4);
    std::memcpy(p + 0x4C, &fx, 4);
    std::memcpy(p + 0x58, pos, 12);
    const float q[4] = {0, 0, 0, 1};
    const float s[3] = {1, 1, 1};
    std::memcpy(p + 0x64, q, 16);
    std::memcpy(p + 0x74, s, 12);
    void* e = nullptr;
    if (!vcall(es, kEsSpawn, &e, static_cast<void*>(p), true) || !e) return nullptr;
    return is_a(e, g_vftEntity) ? e : nullptr;
}

bool remove(uint32_t entityId) {
    void* es = entity_system();
    return es && entityId && vcall_void(es, kEsRemove, entityId, false, 0);
}

int for_each_entity(bool (*visit)(void* e, void* ctx), void* ctx) {
    void* es = entity_system();
    if (!es || !visit) return 0;
    void* it = nullptr;
    if (!vcall(es, kEsIterator, &it) || !it) return 0;
    void* dummy = nullptr;
    vcall(it, kItAddRef, &dummy);
    vcall(it, kItMoveFirst, &dummy);
    int n = 0;
    for (int guard = 0; guard < 200000; ++guard) {
        void* e = nullptr;
        if (!vcall(it, kItNext, &e) || !e) break;
        if (!is_a(e, g_vftEntity)) continue;
        ++n;
        if (visit(e, ctx)) break;
    }
    vcall(it, kItRelease, &dummy);
    return n;
}

bool cvar_set_int(const char* name, int value, int* previous) {
    void* con = console();
    void* cv = nullptr;
    if (!con || !vcall(con, kConGetCVar, &cv, name) || !cv) return false;
    int type = 0;
    if (!vcall(cv, kCVarGetType, &type) || type != 1) return false;
    int old = 0;
    if (previous) { if (vcall(cv, kCVarGetIVal, &old)) *previous = old; }
    return vcall_void(cv, kCVarSetInt, value);
}

} // namespace kcdmp::engine
