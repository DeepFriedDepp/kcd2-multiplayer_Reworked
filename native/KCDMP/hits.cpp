// WO-121 Phases 5 and 6 -- see hits.h.
#include "hits.h"

#include <windows.h>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "anchors.h"
#include "buffs.h"
#include "engine.h"
#include "log.h"
#include "motion.h"
#include "npc_drive.h"
#include "respawn.h"
#include "respawn_actions.h"
#include "rttr_abi.h"

namespace kcdmp::hits {
namespace {

constexpr size_t kSlotMelee   = 0x150;
constexpr size_t kSlotMissile = 0x158;
constexpr size_t kSmAddSoul   = 0x10;    // I_SkirmishManager::AddSoulToSkirmish(soul, reference, override)
constexpr size_t kActorGetSoul = 0x6E0;
constexpr size_t kSoulCombat  = 0x108;   // C_CombatSoul from the actor's soul (WO-119 s2.1, observed)
constexpr double kEngagementS = 30.0;    // one skirmish add per (victim, avatar) per this

template <class T> bool rd(const void* base, size_t off, T* out) {
    __try { *out = *reinterpret_cast<const T*>(static_cast<const char*>(base) + off); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
void* vslot(void* obj, size_t off) {
    void* vt = nullptr; void* fn = nullptr;
    if (!obj || !rd(obj, 0, &vt) || !vt || !rd(vt, off, &fn)) return nullptr;
    return fn;
}
bool call_p0(void* fn, void* self, void** out) {
    __try { *out = reinterpret_cast<void* (__fastcall*)(void*)>(fn)(self); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_p1u(void* fn, void* self, uint32_t a, void** out) {
    __try { *out = reinterpret_cast<void* (__fastcall*)(void*, uint32_t)>(fn)(self, a); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_history(void* fn, void* victimCs, void* data) {
    __try { reinterpret_cast<void (__fastcall*)(void*, void*)>(fn)(victimCs, data); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_getter(void* fn, void** out) {
    __try { *out = reinterpret_cast<void* (__fastcall*)(void*)>(fn)(nullptr); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_add_soul(void* fn, void* mgr, void* soul, void* ref, uint8_t ovr, uint64_t* out) {
    __try { *out = reinterpret_cast<uint64_t (__fastcall*)(void*, void*, void*, uint8_t)>(fn)(mgr, soul, ref, ovr); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool is_a(void* obj, void* const* vft) { void* vp = nullptr; return obj && vft && rd(obj, 0, &vp) && vp == static_cast<const void*>(vft); }
bool bytes_eq(const void* p, const uint8_t* pat, size_t n) {
    __try { return std::memcmp(p, pat, n) == 0; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// ---- anchors ---------------------------------------------------------------------
void* const* g_vftCombatSoul = nullptr;
void* const* g_vftSkirmish = nullptr;
void* g_fnHistory = nullptr, *g_fnSkirmishGetter = nullptr;
std::atomic<bool> g_hookArmed{false};
bool g_attribArmed = false;
std::string g_whyHook = "not installed", g_whyAttrib = "not installed";

using HitFn = void* (__fastcall*)(void* self, void* out, const uint8_t* data);
HitFn g_origMelee = nullptr, g_origMissile = nullptr;

// ---- config ----------------------------------------------------------------------
std::atomic<bool> g_ff{true}, g_attribution{true}, g_pvpHook{true};

// ---- avatars (main thread writes, any thread reads) --------------------------------
struct AvatarSlot { std::atomic<uint32_t> eid{0}; std::atomic<void*> soul{nullptr}; };
AvatarSlot g_avatars[16];

void* avatar_soul(uint32_t eid) {
    if (!eid) return nullptr;
    for (auto& a : g_avatars) if (a.eid.load(std::memory_order_relaxed) == eid) return a.soul.load(std::memory_order_relaxed);
    return nullptr;
}

// ---- the hook's queue (any thread -> main thread) -----------------------------------
struct PvpHit { uint32_t victimEid; float st, hp; uint8_t flags, material; };
struct PlayerHitMark { uint32_t victimEid; double at; };
std::mutex g_qMutex;
std::vector<PvpHit> g_pvp;
std::vector<PlayerHitMark> g_marks;
std::atomic<uint64_t> g_playerWuid{0};
std::atomic<PvpFn> g_pvpFn{nullptr};

// Recently-hit souls (main thread only).
std::unordered_map<void*, double> g_hitSouls;
// Engagements (victim eid << 32 | avatar eid) -> last skirmish add time.
std::unordered_map<uint64_t, double> g_engaged;
// NPC name -> entity id (one walk per name, verified by name on use).
std::unordered_map<std::string, uint32_t> g_nameEids;

std::atomic<uint32_t> c_melee{0}, c_missile{0}, c_avatarHits{0}, c_restored{0}, c_ffQueued{0}, c_marks{0},
    c_attrib{0}, c_attribHistory{0}, c_skirmish{0}, c_pvpIn{0}, c_faults{0};

double now_s() { LARGE_INTEGER q, f; QueryPerformanceCounter(&q); QueryPerformanceFrequency(&f); return double(q.QuadPart) / double(f.QuadPart); }

bool read_hit(const uint8_t* data, uint64_t* aw, uint32_t* aeid, uint64_t* vw, uint32_t* veid, uint8_t* material) {
    return rd(data, 0x00, aw) && rd(data, 0x08, aeid) && rd(data, 0x10, vw) && rd(data, 0x18, veid) && rd(data, 0x4C, material);
}

void* hit_common(bool missile, HitFn orig, void* self, void* out, const uint8_t* data) {
    (missile ? c_missile : c_melee).fetch_add(1, std::memory_order_relaxed);
    uint64_t aw = 0, vw = 0; uint32_t aeid = 0, veid = 0; uint8_t mat = 0;
    if (!g_pvpHook.load(std::memory_order_relaxed) || !read_hit(data, &aw, &aeid, &vw, &veid, &mat)) return orig(self, out, data);
    void* vsoul = avatar_soul(veid);
    if (vsoul) {
        // A hit on a peer's avatar. NEVER skipped: the caller expects a cause
        // back (session 1: an empty one crashed the game). Measured and put back.
        c_avatarHits.fetch_add(1, std::memory_order_relaxed);
        float hp0 = 0, st0 = 0, hp1 = 0, st1 = 0;
        const bool r0 = rttr::soul_state(vsoul, "health", &hp0) && rttr::soul_state(vsoul, "stamina", &st0);
        void* res = orig(self, out, data);
        if (r0 && rttr::soul_state(vsoul, "health", &hp1) && rttr::soul_state(vsoul, "stamina", &st1)) {
            const float dh = hp0 - hp1, ds = st0 - st1;
            if (dh > 0.0f) rttr::soul_set_state(vsoul, "health", hp0);
            if (ds > 0.0f) rttr::soul_set_state(vsoul, "stamina", st0);
            if (dh > 0.0f || ds > 0.0f) c_restored.fetch_add(1, std::memory_order_relaxed);
            const bool byPlayer = aw != 0 && aw == g_playerWuid.load(std::memory_order_relaxed);
            if (byPlayer && (dh > 0.0f || ds > 0.0f)) {
                std::lock_guard<std::mutex> lock(g_qMutex);
                if (g_pvp.size() < 64) g_pvp.push_back({veid, ds > 0 ? ds : 0.0f, dh > 0 ? dh : 0.0f,
                                                        static_cast<uint8_t>(missile ? 0x02 : 0), mat});
            }
        }
        return res;
    }
    if (aw != 0 && aw == g_playerWuid.load(std::memory_order_relaxed) && veid) {
        std::lock_guard<std::mutex> lock(g_qMutex);
        if (g_marks.size() < 128) g_marks.push_back({veid, 0});
    }
    return orig(self, out, data);
}

void* __fastcall hk_melee(void* self, void* out, const uint8_t* data) { return hit_common(false, g_origMelee, self, out, data); }
void* __fastcall hk_missile(void* self, void* out, const uint8_t* data) { return hit_common(true, g_origMissile, self, out, data); }

bool patch_slot(void* const* vft, size_t slot, void* fn, void** orig) {
    void** at = const_cast<void**>(vft) + slot / 8;
    void* cur = nullptr;
    if (!rd(at, 0, &cur) || !cur) return false;
    DWORD old = 0;
    if (!VirtualProtect(at, 8, PAGE_READWRITE, &old)) return false;
    *orig = cur;
    InterlockedExchangePointer(at, fn);
    VirtualProtect(at, 8, old, &old);
    return true;
}

void* actor_by_eid(uint32_t eid) {
    void* gi = engine::game_iface();
    void* am = nullptr;
    if (!gi || !rd(gi, 0x188, &am) || !am) return nullptr;
    void* fn = vslot(am, 0x18);
    void* actor = nullptr;
    if (!fn || !call_p1u(fn, am, eid, &actor)) return nullptr;
    return actor;
}
void* soul_of_actor(void* actor) {
    void* fn = actor ? vslot(actor, kActorGetSoul) : nullptr;
    void* soul = nullptr;
    return fn && call_p0(fn, actor, &soul) ? soul : nullptr;
}

struct FindName { const char* name; uint32_t eid; };
bool find_name_visit(void* e, void* ctx) {
    auto* f = static_cast<FindName*>(ctx);
    const char* n = engine::entity_name(e);
    char buf[64]{};
    if (!n) return false;
    size_t i = 0;
    __try { for (; i + 1 < sizeof(buf) && n[i]; ++i) buf[i] = n[i]; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
    buf[i] = 0;
    if (_stricmp(buf, f->name) == 0) { f->eid = engine::entity_id(e); return true; }
    return false;
}

uint32_t eid_by_name(const std::string& name) {
    auto it = g_nameEids.find(name);
    if (it != g_nameEids.end()) {
        void* e = engine::entity_by_id(it->second);
        const char* n = e ? engine::entity_name(e) : nullptr;
        if (n && _stricmp(n, name.c_str()) == 0) return it->second;
        g_nameEids.erase(it);
    }
    FindName f{ name.c_str(), 0 };
    engine::for_each_entity(&find_name_visit, &f);
    if (f.eid) g_nameEids[name] = f.eid;
    return f.eid;
}

} // namespace

// ==================================================================================
void install() {
    HMODULE rpg = GetModuleHandleA("RPGModule.dll");
    if (!rpg) { logf("WO121-HITS DISARMED -- RPGModule not loaded"); return; }
    g_vftCombatSoul = anchor::find_vftable(rpg, ".?AVC_CombatSoul@rpgmodule@wh@@", 0);
    g_vftSkirmish = anchor::find_vftable(rpg, ".?AVC_SkirmishManager@rpgmodule@wh@@", 0);
    void* melee = g_vftCombatSoul ? g_vftCombatSoul[kSlotMelee / 8] : nullptr;
    void* missile = g_vftCombatSoul ? g_vftCombatSoul[kSlotMissile / 8] : nullptr;

    // History writer: the call slot 0x150 makes that slot 0x158 does not, with
    // the disassembled prologue (push rbx/rdi/r13/r14/r15; sub rsp,0x70).
    static const uint8_t kHistPro[] = {0x40, 0x53, 0x57, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57, 0x48, 0x83, 0xEC, 0x70};
    if (melee && missile) {
        const uint8_t* t[64]{};
        int n = anchor::function_call_targets(rpg, melee, t, 64);
        for (int i = 0; i < n; ++i) {
            if (anchor::function_calls(rpg, missile, t[i])) continue;
            if (bytes_eq(t[i], kHistPro, sizeof(kHistPro))) { g_fnHistory = const_cast<uint8_t*>(t[i]); break; }
        }
    }
    // Skirmish manager getter: StopFight's call with the disassembled prologue;
    // its result's vptr is checked against RTTI C_SkirmishManager at every use.
    static const uint8_t kGetterPro[] = {0x48, 0x89, 0x4C, 0x24, 0x08, 0x53, 0x48, 0x83, 0xEC, 0x20};
    if (const void* sf = actions::stop_fight_fn()) {
        const uint8_t* t[64]{};
        int n = anchor::function_call_targets(rpg, sf, t, 64);
        int picks = 0;
        for (int i = 0; i < n; ++i) {
            if (bytes_eq(t[i], kGetterPro, sizeof(kGetterPro))) { g_fnSkirmishGetter = const_cast<uint8_t*>(t[i]); ++picks; }
        }
        if (picks != 1) g_fnSkirmishGetter = nullptr;
    }

    if (!g_vftCombatSoul || !melee || !missile) g_whyHook = "RTTI C_CombatSoul vftable not unique";
    else if (!g_fnHistory) g_whyHook = "slot 0x150 does not call the combat-history writer (not the disassembled CombatHit)";
    else {
        void* o1 = nullptr, *o2 = nullptr;
        if (!patch_slot(g_vftCombatSoul, kSlotMelee, reinterpret_cast<void*>(&hk_melee), &o1)) g_whyHook = "slot 0x150 could not be patched";
        else {
            g_origMelee = reinterpret_cast<HitFn>(o1);
            if (patch_slot(g_vftCombatSoul, kSlotMissile, reinterpret_cast<void*>(&hk_missile), &o2)) g_origMissile = reinterpret_cast<HitFn>(o2);
            if (!g_origMissile) { g_whyHook = "slot 0x158 could not be patched"; }
            else { g_hookArmed = true; g_whyHook.clear(); }
        }
    }
    if (!g_fnHistory) g_whyAttrib = "combat-history writer not anchored";
    else if (!g_fnSkirmishGetter || !g_vftSkirmish) g_whyAttrib = "skirmish manager not anchored (StopFight / RTTI C_SkirmishManager)";
    else { g_attribArmed = true; g_whyAttrib.clear(); }

    char dm[64]{}, dh[64]{}, dg[64]{};
    anchor::describe(melee, dm, sizeof dm); anchor::describe(g_fnHistory, dh, sizeof dh); anchor::describe(g_fnSkirmishGetter, dg, sizeof dg);
    logf("WO121-HITS piece=hit_slot %s%s%s", g_hookArmed ? "armed" : "NOT armed", g_whyHook.empty() ? "" : " -- ", g_whyHook.c_str());
    logf("WO121-HITS piece=attribution %s%s%s", g_attribArmed ? "armed" : "NOT armed", g_whyAttrib.empty() ? "" : " -- ", g_whyAttrib.c_str());
    logf("WO121-HITS hit_slot=%s attribution=%s combat_hit=%s history=%s skirmish_getter=%s -- local hits on an avatar are measured and put back, never skipped",
         g_hookArmed ? "armed" : "off", g_attribArmed ? "armed" : "off", dm, dh, dg);
}

uint8_t on_config(const uint8_t* body, size_t len) {
    if (len != 3) return 8;
    g_ff = body[0] != 0; g_attribution = body[1] != 0; g_pvpHook = body[2] != 0;
    logf("WO121-HITS config friendly_fire=%d attribution=%d pvp_hook=%d", body[0] != 0, body[1] != 0, body[2] != 0);
    return 0;
}

void note_avatar(uint32_t eid, void* soul, bool on) {
    if (on) {
        for (auto& a : g_avatars) if (a.eid.load() == eid) { a.soul = soul; return; }
        for (auto& a : g_avatars) if (a.eid.load() == 0) { a.soul = soul; a.eid = eid; return; }
    } else {
        for (auto& a : g_avatars) if (a.eid.load() == eid) { a.eid = 0; a.soul = nullptr; }
    }
}

AttribResult apply_attributed(const uint8_t* body, size_t len) {
    AttribResult r{};
    if (len < 16 + 4 + 4 + 1 + 4 + 1 || len != static_cast<size_t>(30 + body[29])) { r.reason = 8; return r; }
    float st = 0, hp = 0; uint32_t avatarEid = 0;
    std::memcpy(&st, body + 16, 4); std::memcpy(&hp, body + 20, 4); std::memcpy(&avatarEid, body + 25, 4);
    std::string name(reinterpret_cast<const char*>(body + 30), body[29]);
    if (!std::isfinite(st) || !std::isfinite(hp)) { r.reason = 8; return r; }
    void* victimSoulR = rttr::find_soul_by_guid(body);   // the RTTR Soul (TakeDamage)
    void* avatarActor = actor_by_eid(avatarEid);
    void* avatarSoul = soul_of_actor(avatarActor);
    if (!victimSoulR) { r.reason = 3; return r; }
    if (!avatarSoul) { r.reason = 4; return r; }
    void* avatarEnt = engine::entity_by_id(avatarEid);
    r.attackerWuid = avatarEnt ? actions::entity_wuid(avatarEnt) : 0;
    // 1. damage with the avatar as the attacker
    if (rttr::apply_damage_soul(victimSoulR, st, hp, buffs::as_c_soul(avatarSoul) ? buffs::as_c_soul(avatarSoul) : avatarSoul)) r.steps |= 1;
    c_attrib.fetch_add(1);
    if (!g_attribArmed) { r.ok = (r.steps & 1) != 0; r.reason = 5; return r; }
    // The victim's own actor/soul (the path the probe proved for the history
    // writer and the skirmish), by name -- one walk per NPC, cached.
    const uint32_t veid = name.empty() ? 0 : eid_by_name(name);
    void* victimEnt = veid ? engine::entity_by_id(veid) : nullptr;
    void* victimActor = veid ? actor_by_eid(veid) : nullptr;
    void* victimSoulA = soul_of_actor(victimActor);
    r.victimWuid = victimEnt ? actions::entity_wuid(victimEnt) : 0;
    // 2. combat history: {+0x00 attacker WUID, +0x10 victim WUID}
    if (victimSoulA && r.attackerWuid && r.victimWuid) {
        void* vcs = static_cast<char*>(victimSoulA) + kSoulCombat;
        if (is_a(vcs, g_vftCombatSoul)) {
            alignas(16) uint8_t d[0x90]{};
            std::memcpy(d + 0x00, &r.attackerWuid, 8);
            std::memcpy(d + 0x10, &r.victimWuid, 8);
            if (call_history(g_fnHistory, vcs, d)) { r.steps |= 2; c_attribHistory.fetch_add(1); }
            else c_faults.fetch_add(1);
        }
    }
    // 3. skirmish, once per engagement
    if (victimSoulA && veid) {
        const uint64_t key = (static_cast<uint64_t>(veid) << 32) | avatarEid;
        const double now = now_s();
        auto it = g_engaged.find(key);
        if (it == g_engaged.end() || now - it->second > kEngagementS) {
            void* mgr = nullptr;
            if (call_getter(g_fnSkirmishGetter, &mgr) && is_a(mgr, g_vftSkirmish)) {
                uint64_t rv = 0;
                if (call_add_soul(g_vftSkirmish[kSmAddSoul / 8], mgr, victimSoulA, avatarSoul, 1, &rv)) {
                    r.steps |= 4; c_skirmish.fetch_add(1);
                    logf("WO121-HITS attributed npc=%s avatar_eid=0x%X skirmish add (override 1) -> 0x%llX", name.c_str(), avatarEid,
                         static_cast<unsigned long long>(rv));
                } else c_faults.fetch_add(1);
            }
            g_engaged[key] = now;
        } else {
            it->second = now;   // a running engagement stays one engagement
            r.steps |= 4;
        }
    }
    r.ok = (r.steps & 1) != 0;
    return r;
}

bool apply_pvp_hit(const uint8_t* body, size_t len) {
    if (len != 10) return false;
    float st = 0, hp = 0;
    std::memcpy(&st, body, 4); std::memcpy(&hp, body + 4, 4);
    const uint8_t flags = body[8], attacker = body[9];
    if (!std::isfinite(st) || !std::isfinite(hp) || st < 0 || hp < 0) return false;
    void* player = rttr::read_player_soul();
    if (!player) return false;
    // The unarmed hint goes in FIRST: the damage below may be the one that
    // floors Henry, and the classifier runs off the next sample.
    respawn::note_pvp_hit((flags & 0x01) != 0, attacker);
    const bool ok = rttr::apply_damage_soul(player, st, hp, nullptr);   // no attacker: naming one starts fights
    c_pvpIn.fetch_add(1);
    logf("WO121-HITS friendly-fire hit on the player: hp -%.2f st -%.2f unarmed=%d from ghost %u -> %s", hp, st, (flags & 1) ? 1 : 0,
         attacker, ok ? "applied" : "FAILED");
    return ok;
}

bool hit_by_player(void* soul, double withinS) {
    auto it = g_hitSouls.find(soul);
    return it != g_hitSouls.end() && now_s() - it->second <= withinS;
}

void set_pvp_callback(PvpFn fn) { g_pvpFn.store(fn); }

void tick() {
    // The player's WUID for the hook (a load changes the entity, not the id,
    // but it is cheap to keep fresh).
    static double s_lastWuid = 0;
    const double now = now_s();
    if (now - s_lastWuid > 1.0) {
        s_lastWuid = now;
        if (void* e = engine::entity_by_id(0x7777)) g_playerWuid = actions::entity_wuid(e);
    }
    std::vector<PvpHit> pvp;
    std::vector<PlayerHitMark> marks;
    {
        std::lock_guard<std::mutex> lock(g_qMutex);
        pvp.swap(g_pvp);
        marks.swap(g_marks);
    }
    for (const auto& m : marks) {
        if (void* soul = soul_of_actor(actor_by_eid(m.victimEid))) {
            // The pipe's LocalHit looks its soul up by guid (the RTTR Soul);
            // remember both the actor's soul and its C_Soul primary.
            g_hitSouls[soul] = now;
            if (void* c = buffs::as_c_soul(soul)) g_hitSouls[c] = now;
            c_marks.fetch_add(1);
        }
    }
    if (g_hitSouls.size() > 256)
        for (auto it = g_hitSouls.begin(); it != g_hitSouls.end();) it = (now - it->second > 5.0) ? g_hitSouls.erase(it) : ++it;
    if (PvpFn fn = g_pvpFn.load()) {
        for (auto& h : pvp) {
            // Unarmed = the local player had no weapon in hand when the hit landed.
            bool armed = true;
            if (void* ps = rttr::read_player_soul()) {
                bool inHand = true;
                if (rttr::combat_bool(ps, "HasWeaponInHand", &inHand)) armed = inHand;
            }
            if (!armed) h.flags |= 0x01;
            if (g_ff.load()) { fn(h.victimEid, h.st, h.hp, h.flags, h.material); c_ffQueued.fetch_add(1); }
        }
    }
}

int status_text(char* out, int n) {
    return std::snprintf(out, n,
        "hit_slot=%s attribution=%s ff=%d attrib_cfg=%d melee=%u missile=%u avatar_hits=%u restored=%u ff_sent=%u player_marks=%u "
        "attributed=%u history=%u skirmish=%u pvp_in=%u hit_faults=%u",
        g_hookArmed ? "armed" : "off", g_attribArmed ? "armed" : "off", g_ff.load() ? 1 : 0, g_attribution.load() ? 1 : 0,
        c_melee.load(), c_missile.load(), c_avatarHits.load(), c_restored.load(), c_ffQueued.load(), c_marks.load(),
        c_attrib.load(), c_attribHistory.load(), c_skirmish.load(), c_pvpIn.load(), c_faults.load());
}

} // namespace kcdmp::hits
