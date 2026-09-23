#include "hangover.h"
#include "anchors.h"
#include "engine.h"
#include "log.h"

#include <windows.h>
#include <cmath>
#include <cstring>

namespace kcdmp::hangover {

namespace {

constexpr const char* kModule = "PlayerModule.dll";
constexpr const char* kAnchor = "Unable to find HangoverSpotsHub from sa_land (via link '%s')";
constexpr const char* kGetGameIface = "?GetGameIface@wh@@YAPEBVC_GameInterface@shared@1@XZ";

constexpr const char* kTagHub     = "hangoverSpotsHub";
constexpr const char* kTagSpot    = "hangoverSpot";
constexpr const char* kTagJoke    = "hangoverSpot_joke";
constexpr const char* kTagIgnored = "ignoredHangoverSpot";

// The instruction bytes of every offset this file uses, as they appear in the
// anchor function (PlayerModule C_PlayerModule::ValidateAlcoTeleportPoints,
// disassembled for WO-113). All must be present or nothing is called.
struct Pat { const char* what; uint8_t b[8]; size_t n; };
const Pat kPats[] = {
    { "mov rbx,[rax+0x168]  (gi->XGenAI)",   {0x48,0x8B,0x98,0x68,0x01,0x00,0x00}, 7 },
    { "call [rax+0xB8]      (->world)",      {0xFF,0x90,0xB8,0x00,0x00,0x00}, 6 },
    { "call [rdx+0x90]      (->land holder)",{0xFF,0x92,0x90,0x00,0x00,0x00}, 6 },
    { "mov rdx,[rcx+0x160]  (->tag table)",  {0x48,0x8B,0x91,0x60,0x01,0x00,0x00}, 7 },
    { "mov edx,0x5D         (hub tag id)",   {0xBA,0x5D,0x00,0x00,0x00}, 5 },
    { "mov edx,0x5E         (spot tag id)",  {0xBA,0x5E,0x00,0x00,0x00}, 5 },
    { "mov edx,0x5F         (joke tag id)",  {0xBA,0x5F,0x00,0x00,0x00}, 5 },
    { "mov r8,[rcx+0x18]    (tag by id)",    {0x4C,0x8B,0x41,0x18}, 4 },
    { "mov rdx,[rcx+0xF8]   (->link mgr)",   {0x48,0x8B,0x91,0xF8,0x00,0x00,0x00}, 7 },
    { "mov rcx,[rax+0xA0]   (gEnv->ents)",   {0x48,0x8B,0x88,0xA0,0x00,0x00,0x00}, 7 },
    { "call [rax+0x78]      (ents by wuid)", {0xFF,0x50,0x78}, 3 },
    { "call [rbx+0x1C0]     (nav agent)",    {0xFF,0x93,0xC0,0x01,0x00,0x00}, 6 },
    { "call [rbx+0x228]     (nav query)",    {0xFF,0x93,0x28,0x02,0x00,0x00}, 6 },
    { "mov rdx,[rcx+0x100]  (nav range a)",  {0x48,0x8B,0x91,0x00,0x01,0x00,0x00}, 7 },
    { "mov rdx,[rcx+0x140]  (entity pos)",   {0x48,0x8B,0x91,0x40,0x01,0x00,0x00}, 7 },
};

// Offsets (byte) -- the same numbers the patterns above prove.
constexpr size_t kGiXGen       = 0x168;
constexpr size_t kXWorld       = 0xB8;
constexpr size_t kXLandHolder  = 0x90;
constexpr size_t kHolderLand   = 0x40;
constexpr size_t kLandNodeObj  = 0x40;   // field, not a slot: *(land+0x40)
constexpr size_t kObjNext      = 0x10;
constexpr size_t kWorldTags    = 0x160;
constexpr size_t kTagsById     = 0x18;
constexpr size_t kWorldLinks   = 0xF8;
constexpr size_t kLinksMgr     = 0x50;
constexpr size_t kMgrGetLinks  = 0x10;
constexpr size_t kEnvEntities  = 0xA0;
constexpr size_t kEntsByWuid   = 0x78;
constexpr size_t kEntNodeId    = 0x10;
constexpr size_t kEntWorldPos  = 0x140;
constexpr size_t kEntName      = 0x90;
constexpr size_t kWorldNav     = 0x50;
constexpr size_t kNavAgent     = 0x1C0;
constexpr size_t kNavQuery     = 0x228;
constexpr size_t kWorldCfg     = 0x10;
constexpr size_t kCfgRangeA    = 0x100;
constexpr size_t kCfgRangeB    = 0xF8;
constexpr int    kTagIdHub = 0x5D, kTagIdSpot = 0x5E, kTagIdJoke = 0x5F;

// One link: {?, WUID, CryString tag} -- 0x18 bytes, stride and fields as the
// anchor function walks them.
struct LinkEntry { uint64_t unknown; uint64_t wuid; const char* tag; };
static_assert(sizeof(LinkEntry) == 0x18, "link entry stride");
// std::vector<LinkEntry> as the callee fills it (begin, end, capacity). The
// game allocates the buffer; it is never freed here (a few KB per level walk,
// bounded by the per-level cache) -- freeing it with this DLL's CRT would be
// a cross-heap free.
struct LinkVec { LinkEntry* begin; LinkEntry* end; LinkEntry* cap; };

bool   g_resolved = false;
bool   g_failed   = false;
void*  g_getGameIface = nullptr;

Spot   g_spots[kMaxSpots];
int    g_count = 0;
void*  g_cacheLand = nullptr;
DWORD  g_cacheAt = 0;

// --- SEH-isolated calls ---------------------------------------------------
using Fn0  = void* (*)(void*);
using FnI  = void* (*)(void*, int);
using FnP  = void* (*)(void*, const void*);
using FnU  = void* (*)(void*, uint32_t);
using FnF  = float (*)(void*);
using FnLinks = void (*)(void*, void*, LinkVec*);
using FnNav = bool (*)(void*, const float*, float, float, float*, void*);

bool rd(const void* base, size_t off, void** out) {
    __try { *out = *reinterpret_cast<void* const*>(static_cast<const char*>(base) + off); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
void* slot(void* obj, size_t off) {
    void* vt = nullptr; void* fn = nullptr;
    if (!obj || !rd(obj, 0, &vt) || !vt || !rd(vt, off, &fn)) return nullptr;
    return fn;
}
bool v0(void* obj, size_t off, void** out) {
    void* fn = slot(obj, off); if (!fn) return false;
    __try { *out = reinterpret_cast<Fn0>(fn)(obj); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool vI(void* obj, size_t off, int a, void** out) {
    void* fn = slot(obj, off); if (!fn) return false;
    __try { *out = reinterpret_cast<FnI>(fn)(obj, a); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool vP(void* obj, size_t off, const void* a, void** out) {
    void* fn = slot(obj, off); if (!fn) return false;
    __try { *out = reinterpret_cast<FnP>(fn)(obj, a); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool vU(void* obj, size_t off, uint32_t a, void** out) {
    void* fn = slot(obj, off); if (!fn) return false;
    __try { *out = reinterpret_cast<FnU>(fn)(obj, a); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool vF(void* obj, size_t off, float* out) {
    void* fn = slot(obj, off); if (!fn) return false;
    __try { *out = reinterpret_cast<FnF>(fn)(obj); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool links(void* mgr, void* node, LinkVec* out) {
    void* fn = slot(mgr, kMgrGetLinks); if (!fn) return false;
    __try { reinterpret_cast<FnLinks>(fn)(mgr, node, out); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool nav_check(void* q, const float* pos, float a, float b, float* out, bool* ok) {
    void* fn = slot(q, 0); if (!fn) return false;
    __try { *ok = reinterpret_cast<FnNav>(fn)(q, pos, a, b, out, nullptr); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool copy_str(const char* s, char* out, size_t n) {
    __try {
        size_t i = 0;
        for (; i + 1 < n && s[i]; ++i) out[i] = s[i];
        out[i] = 0;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { out[0] = 0; return false; }
}
bool str_eq(const char* a, const char* b) {
    __try { return a && b && std::strcmp(a, b) == 0; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool read_u32(const void* p, uint32_t* out) {
    __try { *out = *static_cast<const uint32_t*>(p); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool read_vec(const float* p, float out[3]) {
    __try { out[0] = p[0]; out[1] = p[1]; out[2] = p[2]; return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_gi(void* fn, void** out) {
    __try { *out = reinterpret_cast<void* (*)()>(fn)(); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// The tag object: +8 holds the name's char*.
const char* tag_name(void* tagObj) {
    void* s = nullptr;
    return (tagObj && rd(tagObj, 8, &s)) ? static_cast<const char*>(s) : nullptr;
}

size_t entry_count(const LinkVec& v) {
    if (!v.begin || !v.end || v.end < v.begin) return 0;
    const size_t n = static_cast<size_t>(v.end - v.begin);
    return n > 4096 ? 0 : n;   // a length past this is not a vector we understand
}

struct World { void* A = nullptr; void* land = nullptr; void* ents = nullptr; void* lm = nullptr; };

bool world(World* w) {
    void* gi = nullptr;
    if (!call_gi(g_getGameIface, &gi) || !gi) return false;
    void* X = nullptr;
    if (!rd(gi, kGiXGen, &X) || !X) return false;
    if (!v0(X, kXWorld, &w->A) || !w->A) return false;
    void* holder = nullptr;
    if (!v0(X, kXLandHolder, &holder) || !holder) return false;
    if (!v0(holder, kHolderLand, &w->land)) return false;
    void* env = engine::genv();
    if (!env || !rd(env, kEnvEntities, &w->ents) || !w->ents) return false;
    void* linksHolder = nullptr;
    if (!v0(w->A, kWorldLinks, &linksHolder) || !linksHolder) return false;
    if (!v0(linksHolder, kLinksMgr, &w->lm) || !w->lm) return false;
    return true;
}

bool node_of_land(void* land, void** node) {
    void* o = nullptr; void* p = nullptr;
    if (!rd(land, kLandNodeObj, &o) || !o) return false;
    if (!v0(o, kObjNext, &p) || !p) return false;
    return v0(p, kObjNext, node);
}

// The navmesh query, exactly as the anchor function builds it: the agent type
// from nav->vtbl[0x1C0], its query from vtbl[0x228], the two search ranges
// from the world config.
bool nav_query(void* A, void** q, float* rangeA, float* rangeB) {
    void* nav = nullptr; void* cfg = nullptr;
    if (!A || !v0(A, kWorldNav, &nav) || !nav) return false;
    // vtbl[0x1C0](nav, &out) returns a pointer to the agent-type id (the
    // anchor function then reads one dword from it). The out buffer is
    // oversized on purpose.
    alignas(16) uint8_t tmp[32]{}; void* at = nullptr;
    uint32_t agent = 0;
    if (!vP(nav, kNavAgent, tmp, &at) || !at || !read_u32(at, &agent)) return false;
    return vU(nav, kNavQuery, agent, q) && *q && v0(A, kWorldCfg, &cfg) && cfg &&
           vF(cfg, kCfgRangeA, rangeA) && vF(cfg, kCfgRangeB, rangeB);
}

// Project onto the navmesh; accepted under the rule the spots use (a real
// point within 3 m).
bool nav_project(void* q, float rangeA, float rangeB, const float in[3], float out[3]) {
    float o[3]{};
    bool ok = false;
    if (!nav_check(q, in, rangeA, rangeB, o, &ok) || !ok) return false;
    const float dx = o[0] - in[0], dy = o[1] - in[1], dz = o[2] - in[2];
    if (!std::isfinite(o[0]) || !std::isfinite(o[1]) || !std::isfinite(o[2])) return false;
    if (dx * dx + dy * dy + dz * dz >= 9.0f || (o[0] == 0 && o[1] == 0 && o[2] == 0)) return false;
    out[0] = o[0]; out[1] = o[1]; out[2] = o[2];
    return true;
}

int walk() {
    World w{};
    if (!world(&w)) { logf("HANGOVER: world objects unreadable -- no spots"); return 0; }
    if (!w.land) { logf("HANGOVER: no land node (not in a level?) -- no spots"); return 0; }

    // Cross-check the three tag names the anchor function uses by id.
    void* tags = nullptr;
    const char* hubName = kTagHub; const char* spotName = kTagSpot; const char* jokeName = kTagJoke;
    if (v0(w.A, kWorldTags, &tags) && tags) {
        void* t5d = nullptr; void* t5e = nullptr; void* t5f = nullptr;
        vI(tags, kTagsById, kTagIdHub, &t5d);
        vI(tags, kTagsById, kTagIdSpot, &t5e);
        vI(tags, kTagsById, kTagIdJoke, &t5f);
        char a[48]{}, b[48]{}, c[48]{};
        if (tag_name(t5d)) copy_str(tag_name(t5d), a, sizeof(a));
        if (tag_name(t5e)) copy_str(tag_name(t5e), b, sizeof(b));
        if (tag_name(t5f)) copy_str(tag_name(t5f), c, sizeof(c));
        const bool match = !std::strcmp(a, kTagHub) && !std::strcmp(b, kTagSpot) && !std::strcmp(c, kTagJoke);
        logf("HANGOVER: tag ids 0x5D/0x5E/0x5F = \"%s\" / \"%s\" / \"%s\" %s", a, b, c,
             match ? "(match)" : "(DIFFER from the expected names -- matching by literal name)");
    }

    void* landNode = nullptr;
    if (!node_of_land(w.land, &landNode)) { logf("HANGOVER: land node id unreadable -- no spots"); return 0; }
    LinkVec lv{};
    if (!links(w.lm, landNode, &lv)) { logf("HANGOVER: land links FAULTED -- no spots"); return 0; }
    uint64_t hubWuid = 0;
    for (size_t i = 0, n = entry_count(lv); i < n; ++i)
        if (str_eq(lv.begin[i].tag, hubName)) { hubWuid = lv.begin[i].wuid; break; }
    if (!hubWuid) { logf("HANGOVER: land has no '%s' link (%zu links) -- no spots", hubName, entry_count(lv)); return 0; }

    void* hub = nullptr;
    if (!vP(w.ents, kEntsByWuid, &hubWuid, &hub) || !hub) {
        logf("HANGOVER: hub wuid 0x%016llX resolves to no entity -- no spots", static_cast<unsigned long long>(hubWuid));
        return 0;
    }
    void* hubNode = nullptr;
    if (!v0(hub, kEntNodeId, &hubNode)) { logf("HANGOVER: hub node id unreadable -- no spots"); return 0; }
    LinkVec hv{};
    if (!links(w.lm, hubNode, &hv)) { logf("HANGOVER: hub links FAULTED -- no spots"); return 0; }
    const size_t hn = entry_count(hv);

    void* q = nullptr;
    float rangeA = 0, rangeB = 0;
    const bool haveNav = nav_query(w.A, &q, &rangeA, &rangeB);

    int total = 0, jokes = 0, ignored = 0, unresolved = 0, offNav = 0;
    g_count = 0;
    for (size_t i = 0; i < hn && g_count < kMaxSpots; ++i) {
        const LinkEntry& e = hv.begin[i];
        if (str_eq(e.tag, jokeName)) { ++jokes; continue; }
        if (!str_eq(e.tag, spotName)) continue;
        ++total;
        bool isIgnored = false;
        for (size_t k = 0; k < hn; ++k)
            if (hv.begin[k].wuid == e.wuid && str_eq(hv.begin[k].tag, kTagIgnored)) { isIgnored = true; break; }
        if (isIgnored) { ++ignored; continue; }

        uint64_t wuid = e.wuid;
        void* ent = nullptr;
        if (!vP(w.ents, kEntsByWuid, &wuid, &ent) || !ent) { ++unresolved; continue; }
        void* posp = nullptr;
        float pos[3]{};
        if (!v0(ent, kEntWorldPos, &posp) || !posp || !read_vec(static_cast<const float*>(posp), pos) ||
            !std::isfinite(pos[0]) || !std::isfinite(pos[1]) || !std::isfinite(pos[2])) { ++unresolved; continue; }

        Spot& s = g_spots[g_count];
        s = Spot{};
        s.x = pos[0]; s.y = pos[1]; s.z = pos[2];
        s.nx = pos[0]; s.ny = pos[1]; s.nz = pos[2];
        s.wuid = wuid;
        void* nm = nullptr;
        if (v0(ent, kEntName, &nm) && nm) copy_str(static_cast<const char*>(nm), s.name, sizeof(s.name));
        if (haveNav) {
            float out[3]{};
            bool ok = false;
            if (nav_check(q, pos, rangeA, rangeB, out, &ok)) {
                s.onNavmesh = ok;
                float snapped[3]{};
                if (ok && nav_project(q, rangeA, rangeB, pos, snapped)) {
                    s.nx = snapped[0]; s.ny = snapped[1]; s.nz = snapped[2];
                }
            }
            if (!s.onNavmesh) ++offNav;
        }
        ++g_count;
    }
    logf("HANGOVER: hub 0x%016llX links=%zu spots=%d usable=%d joke=%d ignored=%d unresolved=%d off_navmesh=%d nav=%s",
         static_cast<unsigned long long>(hubWuid), hn, total, g_count, jokes, ignored, unresolved, offNav,
         haveNav ? "yes" : "NO (positions unsnapped)");
    for (int i = 0; i < g_count && i < 3; ++i)
        logf("HANGOVER:   e.g. \"%s\" at (%.1f, %.1f, %.1f) nav=(%.1f, %.1f, %.1f) on_navmesh=%d",
             g_spots[i].name, g_spots[i].x, g_spots[i].y, g_spots[i].z,
             g_spots[i].nx, g_spots[i].ny, g_spots[i].nz, g_spots[i].onNavmesh ? 1 : 0);
    g_cacheLand = w.land;
    return g_count;
}

} // namespace

bool snap_to_ground(const float in[3], float out[3]) {
    if (!g_resolved) return false;
    void* gi = nullptr; void* X = nullptr; void* A = nullptr;
    if (!call_gi(g_getGameIface, &gi) || !gi || !rd(gi, kGiXGen, &X) || !X || !v0(X, kXWorld, &A) || !A) return false;
    void* q = nullptr;
    float a = 0, b = 0;
    if (!nav_query(A, &q, &a, &b)) return false;
    if (nav_project(q, a, b, in, out)) return true;
    // Observed: a death sampled a little off the mesh (a knock-back, a slope)
    // found nothing within the world config's own ranges. One wider search;
    // the 3 m acceptance rule still holds.
    const bool wide = nav_project(q, a * 4.0f, b * 4.0f, in, out);
    logf("HANGOVER: ground snap at (%.1f, %.1f, %.1f): nothing within ranges %.2f/%.2f; 4x ranges %s",
         in[0], in[1], in[2], a, b, wide ? "found the ground" : "found nothing either");
    return wide;
}

bool resolve() {
    if (g_resolved) return true;
    if (g_failed) return false;
    char d[256]{};
    HMODULE mod = GetModuleHandleA(kModule);
    if (!mod) { logf("HANGOVER: %s not loaded", kModule); return false; }   // retry later
    int n = 0;
    const uint8_t* fn = anchor::function_by_string(mod, kAnchor, &n);
    if (!fn) {
        logf("HANGOVER: ANCHOR FAILED -- \"%s\" referenced by %d functions (want 1); spots OFF", kAnchor, n);
        g_failed = true;
        return false;
    }
    anchor::describe(fn, d, sizeof(d));
    logf("HANGOVER: anchor function = %s (C_PlayerModule::ValidateAlcoTeleportPoints)", d);
    for (const Pat& p : kPats) {
        if (!anchor::function_has_bytes(mod, fn, p.b, p.n)) {
            logf("HANGOVER: ANCHOR FAILED -- anchor function lacks %s; offsets differ on this build; spots OFF", p.what);
            g_failed = true;
            return false;
        }
    }
    // gEnv comes from the same anchor function (engine.cpp lifts it).
    if (!engine::resolve()) {
        logf("HANGOVER: engine services not resolved (see ENGINE lines); spots OFF");
        g_failed = true;
        return false;
    }
    if (HMODULE shared = GetModuleHandleA("Shared.dll")) g_getGameIface = GetProcAddress(shared, kGetGameIface);
    if (!g_getGameIface) { logf("HANGOVER: Shared.dll GetGameIface export missing; spots OFF"); g_failed = true; return false; }
    logf("HANGOVER: all %zu instruction anchors present -- spots ON", sizeof(kPats) / sizeof(kPats[0]));
    g_resolved = true;
    return true;
}

int spots(const Spot** out, bool force) {
    if (out) *out = g_spots;
    if (!resolve()) return 0;
    World w{};
    const bool haveWorld = world(&w);
    const bool levelChanged = haveWorld && w.land != g_cacheLand;
    if (force || levelChanged || g_count == 0) {
        // A world with no spots is re-walked at most every 30 s, not per call.
        if (force || levelChanged || GetTickCount() - g_cacheAt > 30000) {
            g_cacheAt = GetTickCount();
            walk();
        }
    }
    return g_count;
}

const Spot* nearest(float x, float y, float z, float minDist, float ax, float ay) {
    const Spot* list = nullptr;
    const int n = spots(&list);
    const Spot* best = nullptr;
    float bestD = 1e30f;
    for (int i = 0; i < n; ++i) {
        const Spot& s = list[i];
        if (!s.onNavmesh) continue;   // the anchor function's own validity rule
        if (minDist > 0) {
            const float ex = s.nx - ax, ey = s.ny - ay;
            if (ex * ex + ey * ey < minDist * minDist) continue;
        }
        const float dx = s.nx - x, dy = s.ny - y, dz = s.nz - z;
        const float d2 = dx * dx + dy * dy + dz * dz;
        if (d2 < bestD) { bestD = d2; best = &s; }
    }
    return best;
}

const Spot* nearest_where(float x, float y, float z, bool (*accept)(const Spot& s, void* ctx), void* ctx) {
    const Spot* list = nullptr;
    const int n = spots(&list);
    const Spot* best = nullptr;
    float bestD = 1e30f;
    for (int i = 0; i < n; ++i) {
        const Spot& s = list[i];
        if (!s.onNavmesh) continue;
        const float dx = s.nx - x, dy = s.ny - y, dz = s.nz - z;
        const float d2 = dx * dx + dy * dy + dz * dz;
        if (d2 >= bestD) continue;
        if (accept && !accept(s, ctx)) continue;
        bestD = d2;
        best = &s;
    }
    return best;
}

} // namespace kcdmp::hangover
