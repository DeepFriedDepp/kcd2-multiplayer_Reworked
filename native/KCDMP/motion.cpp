// WO-121 -- movement and combat on native-written bodies. See motion.h.
#include "motion.h"

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
#include "gait_logic.h"
#include "inline_hook.h"
#include "log.h"
#include "hits.h"
#include "pe_exports.h"
#include "script_context.h"

namespace kcdmp::motion {
namespace {

// ---- layout (WO-119 s7, re-verified by anchor at install) ----------------------
constexpr size_t kActorSetPseudoSpeed = 0x448;   // C_Actor vftable slot (body: mov rax,[rbx+0x7E8] .. movss [rax+0x18],xmm6)
constexpr size_t kActorGetSoul        = 0x6E0;
constexpr size_t kActorExpHolder      = 0x980;   // returns actor+0x308, the state-expansion holder
constexpr size_t kActorCombatActor    = 0x970;   // GetOrCreateCombatActor (what every combat test command calls)
constexpr size_t kActorPseudoComp     = 0x7E8;   // AI-animation component; pseudo-speed at +0x18
constexpr size_t kActorReqVel         = 0x574;   // requested velocity x,y,z (FinalizeMovementRequest caches it)
constexpr size_t kActorCombatField    = 0x300;   // m_pCombatActor (mannequin_read.cpp)
constexpr size_t kHolderGetExt        = 0x70;    // holder->vtbl[0x70](holder, 1) = the extension
constexpr size_t kExpSetCrouch        = 0xE8;
constexpr size_t kExpGetCrouch        = 0xF0;
constexpr size_t kExpRequestJump      = 0x100;
constexpr size_t kCaTryStartCombat    = 0x360;
constexpr size_t kCaModel             = 0x2F0;
constexpr size_t kCaOwnerEntity       = 0x2D8;
constexpr size_t kModelFlags          = 0xEE8;   // the guard-request flag set; SetFlag(this, index, value)
constexpr size_t kModelOpponent       = 0x1118;
constexpr size_t kModelBlockMax       = 0x865;   // max over the five per-scope block-mode bytes
constexpr int    kGuardRequestScope   = 4;
constexpr size_t kActionEnterImpl     = 0x1C8;
constexpr size_t kActionDescriptor    = 0x60;
constexpr size_t kActionCombatActor   = 0x78;    // C_CombatActorActionAttack ctor: mov [rbx+0x78], rbp (rbp = ca)
constexpr size_t kDescRowGuid         = 0x84;    // live, WO-121 session 1: mn_fragment_guid, Windows byte order

// WO-129 -- the gait at the engine's own tag update (docs/WO-129-findings.md s1).
// C_ActorMovementController::Update (EntityModule 0xB18D0) calls SetPseudoSpeed
// with its movement request's value on every actor every frame, AFTER our write
// at the frame hook and BEFORE C_Actor::UpdateMannequinTags reads it (observed:
// 0.00 at every tag update of a written avatar). With no movement request the
// requested velocity is 0 too, so neither a pace nor a direction tag was ever
// set: the body slid. Our inputs are re-applied at UpdateMannequinTags' entry.
constexpr size_t kActorUpdateTags     = 0xC98;   // C_Actor vftable slot: C_Actor::UpdateMannequinTags
constexpr size_t kActorMoveVec        = 0x614;   // Vec2 the tag update prefers for the direction tag
constexpr size_t kActorSpeedType      = 0x860;   // stance manager (actor+0x850) +0x10: the logical-speed table kind
constexpr size_t kGiSpeedHolder       = 0x138;   // GetGameIface()+0x138 -> vtbl[0x100]() = the logical-speed manager
constexpr size_t kHolderGetSpeedMgr   = 0x100;
constexpr size_t kSpeedMgrCount       = 0x08;    // count(soul, kind): how many logical speeds this body has
constexpr size_t kSpeedMgrMap         = 0x78;    // id = (int)(pseudo + 0.5) - 1 (checked by bytes at install)
const uint8_t kTagsPrologue[18] = {0x48, 0x89, 0x54, 0x24, 0x10, 0x53, 0x57, 0x41, 0x55, 0x41, 0x57, 0x48, 0x81, 0xEC, 0xA8, 0x00, 0x00, 0x00};

// Combat-model properties, each names itself at +0x30 (WO-119 s7); value at +8.
struct Prop { size_t off; const char* name; };
constexpr Prop kPropCombatMode{0x000, "CombatMode"};
constexpr Prop kPropGuardStance{0x100, "GuardStance"};
constexpr Prop kPropGuardZone{0x140, "GuardZone"};
constexpr Prop kPropReqAtkZone{0x200, "RequestedAtkZone"};
constexpr Prop kPropAttackType{0x2C0, "AttackType"};
constexpr Prop kPropReqInputClass{0x300, "RequestedInputClass"};

// ---- SEH-isolated primitives (no destructible locals) --------------------------
template <class T> bool rd(const void* base, size_t off, T* out) {
    __try { *out = *reinterpret_cast<const T*>(static_cast<const char*>(base) + off); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
void* vslot(void* obj, size_t off) {
    void* vt = nullptr; void* fn = nullptr;
    if (!obj || !rd(obj, 0, &vt) || !vt || !rd(vt, off, &fn)) return nullptr;
    return fn;
}
bool is_a(void* obj, void* const* vft) { void* vp = nullptr; return obj && vft && rd(obj, 0, &vp) && vp == static_cast<const void*>(vft); }
bool call_p0(void* fn, void* self, void** out) {
    __try { *out = reinterpret_cast<void* (__fastcall*)(void*)>(fn)(self); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_p1u(void* fn, void* self, uint32_t a, void** out) {
    __try { *out = reinterpret_cast<void* (__fastcall*)(void*, uint32_t)>(fn)(self, a); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_p1b(void* fn, void* self, bool a, void** out) {
    __try { *out = reinterpret_cast<void* (__fastcall*)(void*, bool)>(fn)(self, a); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_f(void* fn, void* self, float v) {
    __try { reinterpret_cast<void (__fastcall*)(void*, float)>(fn)(self, v); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_bb(void* fn, void* self, bool a, bool b) {
    __try { reinterpret_cast<void (__fastcall*)(void*, bool, bool)>(fn)(self, a, b); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_ret_b(void* fn, void* self, bool* out) {
    __try { *out = reinterpret_cast<bool (__fastcall*)(void*)>(fn)(self); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_jump(bool (__fastcall* fn)(void*), void* self, bool* out) {
    __try { *out = fn(self); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_ret_u8(void* fn, void* self, uint8_t* out) {
    __try { *out = reinterpret_cast<uint8_t (__fastcall*)(void*)>(fn)(self); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_count(void* fn, void* mgr, void* soul, int32_t kind, uint64_t* out) {
    __try { *out = reinterpret_cast<uint64_t (__fastcall*)(void*, void*, int32_t)>(fn)(mgr, soul, kind); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_trystart(void* fn, void* ca, uint64_t* out) {
    struct { uint8_t has; uint8_t pad[3]; int32_t v; } opt{};   // optional<int>{has=false}
    __try { *out = reinterpret_cast<uint64_t (__fastcall*)(void*, void*)>(fn)(ca, &opt); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_auto(void* fn, void* cmd, void* ca, bool enable) {
    __try { reinterpret_cast<void (__fastcall*)(void*, void*, char)>(fn)(cmd, ca, enable ? 1 : 0); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_setflag(void* fn, void* flags, int index, uint8_t value) {
    __try { reinterpret_cast<void (__fastcall*)(void*, int, uint8_t)>(fn)(flags, index, value); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_setguardzone(void* fn, void* ca, int zone, int stance) {
    __try { reinterpret_cast<char (__fastcall*)(void*, int, int, char)>(fn)(ca, zone, stance, 0); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_setatkzone(void* fn, void* ca, int zone) {
    __try { reinterpret_cast<void (__fastcall*)(void*, int)>(fn)(ca, zone); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_setblock(void* fn, void* ca, bool on, unsigned scope) {
    __try { reinterpret_cast<void (__fastcall*)(void*, char, unsigned)>(fn)(ca, on ? 1 : 0, scope); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool copy_cstr(const void* p, char* out, size_t n) {
    __try {
        const char* s = static_cast<const char*>(p);
        size_t i = 0;
        for (; i + 1 < n && s[i]; ++i) out[i] = s[i];
        out[i] = 0;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { out[0] = 0; return false; }
}

// ---- anchors -------------------------------------------------------------------
struct Anchors {
    void* const* vftActor = nullptr;
    void* const* vftExp = nullptr;
    void* const* vftCa = nullptr;
    void* const* vftCa8 = nullptr;   // WO-129: C_CombatActor's secondary base (+8): an interface pointer to it carries this vptr
    void* fnSetPseudo = nullptr, *fnSetCrouch = nullptr, *fnGetCrouch = nullptr, *fnRequestJump = nullptr;
    void* fnTryStart = nullptr, *fnAuto = nullptr, *fnSetFlag = nullptr;
    void* fnSetGuardZone = nullptr, *fnSetAtkZone = nullptr, *fnSetBlock = nullptr;
    void* const* vftAttack = nullptr, *const* vftDodge = nullptr, *const* vftPerfect = nullptr, *const* vftBlock = nullptr;
    bool actorLookup = false;   // gi+0x188 -> vtbl[0x18](eid): the engine's own route (the test commands)
};
Anchors A;
std::atomic<bool> g_gait{false}, g_moves{false}, g_combat{false}, g_capture{false};
std::string g_whyGait = "not installed", g_whyMoves = "not installed", g_whyCombat = "not installed", g_whyCapture = "not installed";

// ---- config (agent) --------------------------------------------------------------
std::atomic<bool> g_cfgAvatarGait{true}, g_cfgNpcGait{true}, g_cfgMoves{true}, g_cfgCombat{true}, g_cfgNpcRows{true};
std::atomic<bool> g_cfgChanged{false};

// ---- per-body state (main thread) ------------------------------------------------
struct Body {
    uint32_t eid = 0;
    void* ent = nullptr;
    void* actor = nullptr;
    void* ca = nullptr;
    void* exp = nullptr;
    bool avatar = false;
    std::string key;
    // gait
    float speedEma = 0;
    bool gaitWritten = false;
    float velX = 0, velY = 0;     // WO-129: smoothed rendered planar velocity (world), the direction tag's input
    float cls = 0;                // WO-129: the logical speed class written (0 still, 1 walk, 2 run, 3 sprint)
    int   range = -1;             // WO-129: the body's own class count (engine), -1 unknown
    double rangeAt = -1;
    int   slot = -1;              // WO-129: index into g_gaitTable, -1 none
    // moves
    bool crouchApplied = false;
    // combat
    bool automationOff = false, combatHeld = false, blockApplied = false;
    int appliedGz = -2, appliedGs = -2, appliedAz = -2;
    double lastCombatAssert = 0, lastBuffCheck = 0, lastGaitLog = 0;
    uint32_t combatStarts = 0;
    bool ctxApplied = false;      // the WO-121 avatar contexts (kAvatarContexts) are set on its soul
};
std::unordered_map<uint32_t, Body> g_bodies;

// ---- WO-129: the gait table (main thread writes, any thread reads) --------------
// UpdateMannequinTags runs on the main thread and on job workers, so the hook
// reads gait::Table (fixed, open-addressed atomics); only the main thread
// inserts and removes. A slot older than kGaitStaleTicks frames is ignored.
constexpr uint32_t kGaitStaleTicks = 30;
gait::Table<256> g_gaitTable;
std::atomic<uint32_t> g_gaitTick{0};
std::atomic<bool> g_tags{false};
std::string g_whyTags = "not installed";
std::atomic<uint32_t> c_tagApplied{0};
void* g_fnSpeedMap = nullptr;          // the manager's vtbl[0x78] body, byte-checked (the round(x)-1 mapper)

bool write_tag_inputs(void* actor, float cls, float vx, float vy) {
    __try {
        void* comp = *reinterpret_cast<void**>(static_cast<char*>(actor) + kActorPseudoComp);
        if (comp) *reinterpret_cast<float*>(static_cast<char*>(comp) + 0x18) = cls;
        float* rv = reinterpret_cast<float*>(static_cast<char*>(actor) + kActorReqVel);
        rv[0] = vx; rv[1] = vy; rv[2] = 0.0f;
        float* mv = reinterpret_cast<float*>(static_cast<char*>(actor) + kActorMoveVec);
        mv[0] = vx; mv[1] = vy;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// UpdateMannequinTags entry (any thread). Cheap when nothing is driven.
void on_update_tags(void* actor) {
    if (g_gaitTable.live() <= 0 || !g_tags.load(std::memory_order_relaxed)) return;
    float cls, vx, vy;
    if (!g_gaitTable.read(actor, g_gaitTick.load(std::memory_order_relaxed), kGaitStaleTicks, &cls, &vx, &vy)) return;
    if (write_tag_inputs(actor, cls, vx, vy)) c_tagApplied.fetch_add(1, std::memory_order_relaxed);
}

// The engine reads pseudo-speed as a logical speed CLASS, not m/s: the manager's
// mapper is id = (int)(pseudo + 0.5) - 1, and this body's table holds `range`
// classes (3 on the avatars seen: walk, run, sprint). Streams are in m/s (the
// sender's requested velocity), so they are classed (gait::speed_class).

// Pending avatar events (pipe thread -> main thread).
struct PendingEvent { uint8_t kind; uint32_t eid; };
std::mutex g_evMutex;
std::vector<PendingEvent> g_events;

// ---- captured actions (any thread -> main thread) --------------------------------
struct Captured {
    uint8_t kind, flags; int8_t ic, zone, type; uint8_t guid[16]; uint32_t eid; char name[64];
};
std::mutex g_capMutex;
std::vector<Captured> g_captured;
std::atomic<void*> g_playerCa{nullptr};
std::atomic<void*> g_playerExp{nullptr};
std::atomic<ActionFn> g_actionFn{nullptr};

// Counters for the status reply.
std::atomic<uint32_t> c_gaitWrites{0}, c_crouch{0}, c_jumps{0}, c_jumpFail{0}, c_combatStarts{0}, c_autoOff{0},
    c_guardZone{0}, c_atkZone{0}, c_block{0}, c_capAttack{0}, c_capNpc{0}, c_capJump{0}, c_capOther{0}, c_capDropped{0},
    c_faults{0},
    // WO-129: why a capture was dropped (the first two-player session: cap_dropped 5 / 11, cap_attack 0)
    c_dropNotCa{0}, c_dropNoDesc{0}, c_dropNoGuid{0}, c_dropNoOwner{0}, c_capViaBase8{0}, c_capOurs{0};

void* g_autoCmd = nullptr;   // a zeroed stand-in for the test command the automation function reads (+0x79..+0x7B)
void* g_autoCmdOn = nullptr; // the same with every enable byte set

bool prop_named(void* model, const Prop& p) {
    void* s = nullptr;
    char buf[32]{};
    return rd(model, p.off + 0x30, &s) && s && copy_cstr(s, buf, sizeof(buf)) && std::strcmp(buf, p.name) == 0;
}
template <class T> bool prop_value(void* model, const Prop& p, T* out) {
    return prop_named(model, p) && rd(model, p.off + 8, out);
}

void* actor_by_eid(uint32_t eid) {
    if (!A.actorLookup) return nullptr;
    void* gi = engine::game_iface();
    void* am = nullptr;
    if (!gi || !rd(gi, 0x188, &am) || !am) return nullptr;
    void* fn = vslot(am, 0x18);
    void* actor = nullptr;
    if (!fn || !call_p1u(fn, am, eid, &actor)) return nullptr;
    return actor;
}

void* expansion_of(void* actor) {
    void* holderFn = vslot(actor, kActorExpHolder);
    void* holder = nullptr;
    if (!holderFn || !call_p0(holderFn, actor, &holder) || !holder) return nullptr;
    void* getExt = vslot(holder, kHolderGetExt);
    void* ext = nullptr;
    if (!getExt || !call_p1b(getExt, holder, true, &ext) || !ext) return nullptr;
    return is_a(ext, A.vftExp) ? ext : nullptr;   // the extension IS a C_ActorStateExpansion, or nothing
}

// WO-129: a combat-actor pointer as the engine hands it out, normalised to the
// object's start. C_CombatActor has a secondary base at +8 (RTTI: vftables at
// offsets 0 and 8), so a pointer typed as that base is the object + 8 and
// carries the +8 vptr; comparing it to the primary vftable (the WO-121 code)
// rejects it. Nothing else is accepted.
void* as_combat_actor(void* p) {
    if (!p) return nullptr;
    if (is_a(p, A.vftCa)) return p;
    if (A.vftCa8) {
        void* base = static_cast<char*>(p) - 8;
        if (is_a(p, A.vftCa8) && is_a(base, A.vftCa)) return base;
    }
    return nullptr;
}

void* combat_actor_of(void* actor, bool create) {
    void* ca = nullptr;
    if (!create) { if (!rd(actor, kActorCombatField, &ca)) return nullptr; }
    else {
        void* fn = vslot(actor, kActorCombatActor);
        if (!fn || !call_p0(fn, actor, &ca)) return nullptr;
    }
    return as_combat_actor(ca);
}

void* player_actor() {
    static void* s_inst = nullptr; static void* s_fn = nullptr;
    if (!s_fn) {
        HMODULE em = GetModuleHandleA("EntityModule.dll");
        if (!em) return nullptr;
        auto exps = module_exports(em);
        s_inst = find_export(exps, "?m_Instance@C_EntityModule@entitymodule@wh@@");
        s_fn = find_export(exps, "?GetPlayerActor@C_EntityModule@entitymodule@wh@@");
        if (!s_inst || !s_fn) { s_fn = nullptr; return nullptr; }
    }
    void* inst = nullptr;
    if (!rd(s_inst, 0, &inst) || !inst) return nullptr;
    void* actor = nullptr;
    if (!call_p0(s_fn, inst, &actor)) return nullptr;
    return actor;
}

// ---- the capture hooks -----------------------------------------------------------
enum Cls : uint8_t { kClsAttack = 0, kClsDodge = 1, kClsPerfect = 2, kClsBlock = 3, kClsCount = 4 };
void* g_origEnter[kClsCount]{};
uint8_t* g_thunks = nullptr;

// WO-129: one line for the first drops of each reason (then counters only).
void note_drop(std::atomic<uint32_t>& counter, const char* why, uint8_t cls, const void* raw) {
    c_capDropped.fetch_add(1);
    if (counter.fetch_add(1) >= 2) return;
    void* vp = nullptr; rd(raw, 0, &vp);
    char d[64]{}; anchor::describe(vp, d, sizeof d);
    logf("WO129-CAPTURE drop reason=%s class=%u owner_ptr_vptr=%s (C_CombatActor primary/+8 expected)", why, cls, d);
}

void capture(uint8_t cls, void* action) {
    void* raw = nullptr;
    if (!rd(action, kActionCombatActor, &raw) || !raw) return;
    void* ca = as_combat_actor(raw);
    void* playerCa = g_playerCa.load(std::memory_order_relaxed);
    const bool isPlayer = ca && ca == playerCa;
    if (!isPlayer && !(cls == kClsAttack && g_cfgNpcRows.load(std::memory_order_relaxed))) return;
    if (!ca) { note_drop(c_dropNotCa, "owner-not-a-combat-actor", cls, raw); return; }
    if (ca != raw) c_capViaBase8.fetch_add(1);
    void* desc = nullptr;
    Captured c{};
    if (!rd(action, kActionDescriptor, &desc) || !desc) { note_drop(c_dropNoDesc, "no-descriptor", cls, raw); return; }
    uint64_t g0 = 0, g1 = 0;
    if (!rd(desc, kDescRowGuid, &g0) || !rd(desc, kDescRowGuid + 8, &g1) || (g0 == 0 && g1 == 0)) { note_drop(c_dropNoGuid, "no-row-guid", cls, raw); return; }
    std::memcpy(c.guid, &g0, 8); std::memcpy(c.guid + 8, &g1, 8);
    c.kind = cls == kClsAttack ? 1 : cls == kClsDodge ? 7 : 6;
    c.flags = cls == kClsPerfect ? 0x01 : 0;
    c.ic = -1; c.zone = -1; c.type = -1;
    void* model = nullptr;
    if (rd(ca, kCaModel, &model) && model) {
        int32_t v = -1;
        if (prop_value(model, kPropReqInputClass, &v)) c.ic = static_cast<int8_t>(v);
        if (prop_value(model, kPropReqAtkZone, &v)) c.zone = static_cast<int8_t>(v);
        if (prop_value(model, kPropAttackType, &v)) c.type = static_cast<int8_t>(v);
    }
    if (isPlayer) {
        c.eid = 0;
        (cls == kClsAttack ? c_capAttack : c_capOther).fetch_add(1);
    } else {
        void* ent = nullptr;
        if (!rd(ca, kCaOwnerEntity, &ent) || !ent) { note_drop(c_dropNoOwner, "no-owner-entity", cls, raw); return; }
        const char* n = engine::entity_name(ent);
        if (!n || !copy_cstr(n, c.name, sizeof(c.name)) || !c.name[0]) { note_drop(c_dropNoOwner, "no-owner-name", cls, raw); return; }
        if (_strnicmp(c.name, "kcd2mp_", 7) == 0 || _strnicmp(c.name, "DialogTwin_", 11) == 0) { c_capOurs.fetch_add(1); return; }   // never ours
        c.eid = engine::entity_id(ent);
        c_capNpc.fetch_add(1);
    }
    std::lock_guard<std::mutex> lock(g_capMutex);
    if (g_captured.size() < 256) g_captured.push_back(c); else c_capDropped.fetch_add(1);
}

extern "C" void __cdecl wo121_enter_pre(uint64_t cls, void* action) {
    // SEH is not allowed around code with destructible locals; capture() has
    // none on the hot path except the lock_guard at the end, which is fine
    // because every read above it is SEH-isolated in rd().
    capture(static_cast<uint8_t>(cls), action);
}

// Register-preserving pre-call thunk (the WO-116 pattern): saves the four
// argument registers and xmm0-3, calls wo121_enter_pre(cls, rcx), restores,
// jumps to the original. Nothing about the original call changes.
void* make_thunk(uint8_t* p, uint64_t cls, void* orig) {
    uint8_t* s = p;
    auto emit = [&](std::initializer_list<uint8_t> b) { for (auto x : b) *p++ = x; };
    auto emit64 = [&](uint64_t v) { std::memcpy(p, &v, 8); p += 8; };
    emit({0x51, 0x52, 0x41, 0x50, 0x41, 0x51});                 // push rcx, rdx, r8, r9
    emit({0x48, 0x83, 0xEC, 0x68});                             // sub rsp, 0x68
    emit({0xF3, 0x0F, 0x7F, 0x44, 0x24, 0x20});                 // movdqu [rsp+0x20], xmm0
    emit({0xF3, 0x0F, 0x7F, 0x4C, 0x24, 0x30});
    emit({0xF3, 0x0F, 0x7F, 0x54, 0x24, 0x40});
    emit({0xF3, 0x0F, 0x7F, 0x5C, 0x24, 0x50});
    emit({0x48, 0x8B, 0xD1});                                   // mov rdx, rcx (the action)
    emit({0x48, 0xB9}); emit64(cls);                            // mov rcx, cls
    emit({0x48, 0xB8}); emit64(reinterpret_cast<uint64_t>(&wo121_enter_pre));
    emit({0xFF, 0xD0});                                         // call rax
    emit({0xF3, 0x0F, 0x6F, 0x44, 0x24, 0x20});
    emit({0xF3, 0x0F, 0x6F, 0x4C, 0x24, 0x30});
    emit({0xF3, 0x0F, 0x6F, 0x54, 0x24, 0x40});
    emit({0xF3, 0x0F, 0x6F, 0x5C, 0x24, 0x50});
    emit({0x48, 0x83, 0xC4, 0x68});
    emit({0x41, 0x59, 0x41, 0x58, 0x5A, 0x59});                 // pop r9, r8, rdx, rcx
    emit({0xFF, 0x25, 0, 0, 0, 0}); emit64(reinterpret_cast<uint64_t>(orig));   // jmp [rip+0] -> orig
    return s;
}

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

using RequestJumpFn = bool (__fastcall*)(void*);
RequestJumpFn g_origJump = nullptr;
bool __fastcall hk_request_jump(void* self) {
    const bool r = g_origJump(self);
    if (r && self == g_playerExp.load(std::memory_order_relaxed)) {
        Captured c{};
        c.kind = 2; c.ic = c.zone = c.type = -1;
        c_capJump.fetch_add(1);
        std::lock_guard<std::mutex> lock(g_capMutex);
        if (g_captured.size() < 256) g_captured.push_back(c);
    }
    return r;
}

// ---- install helpers -------------------------------------------------------------
void* slot_fn(void* const* vft, size_t off) { return vft ? vft[off / 8] : nullptr; }

bool has(HMODULE m, const void* fn, std::initializer_list<uint8_t> pat) {
    std::vector<uint8_t> v(pat);
    return anchor::function_has_bytes(m, fn, v.data(), v.size());
}

// The one call target an anchored test command's Execute makes that no other
// test command's Execute also makes (the shared helpers drop out).
const uint8_t* unique_target(HMODULE m, const void* exec, const std::vector<const void*>& others) {
    const uint8_t* mine[64]{};
    int n = anchor::function_call_targets(m, exec, mine, 64);
    const uint8_t* pick = nullptr; int picks = 0;
    for (int i = 0; i < n; ++i) {
        bool shared = false;
        for (const void* o : others) if (o != exec && anchor::function_calls(m, o, mine[i])) { shared = true; break; }
        if (!shared) { pick = mine[i]; ++picks; }
    }
    return picks == 1 ? pick : nullptr;
}

void log_piece(const char* name, bool armed, const std::string& why) {
    logf("WO121-MOTION piece=%s %s%s%s", name, armed ? "armed" : "NOT armed", why.empty() ? "" : " -- ", why.c_str());
}

// ---- appliers (main thread) --------------------------------------------------------
void apply_gait(Body& b, float speed) {
    void* fn = vslot(b.actor, kActorSetPseudoSpeed);
    if (fn != A.fnSetPseudo) return;   // the body's own vtable must dispatch to the anchored function
    if (!call_f(fn, b.actor, speed)) { c_faults.fetch_add(1); g_gait = false; g_whyGait = "SetPseudoSpeed faulted"; logf("WO121-MOTION gait DISARMED -- SetPseudoSpeed faulted on %s", b.key.c_str()); return; }
    b.gaitWritten = true;
    c_gaitWrites.fetch_add(1, std::memory_order_relaxed);
}

void unpublish_gait(Body& b);

void release_gait(Body& b) {
    unpublish_gait(b);   // WO-129: the tag update is the engine's own again from the next frame
    if (!b.gaitWritten || !b.actor) return;
    void* fn = vslot(b.actor, kActorSetPseudoSpeed);
    if (fn == A.fnSetPseudo) call_f(fn, b.actor, 0.0f);
    b.gaitWritten = false;
}

void apply_crouch(Body& b, bool want) {
    if (!b.exp) b.exp = expansion_of(b.actor);
    if (!b.exp) return;
    void* fn = vslot(b.exp, kExpSetCrouch);
    if (fn != A.fnSetCrouch) return;
    if (!call_bb(fn, b.exp, want, false)) { c_faults.fetch_add(1); g_moves = false; g_whyMoves = "SetCrouch faulted"; return; }
    b.crouchApplied = want;
    c_crouch.fetch_add(1);
    logf("WO121-MOTION body=%s crouch=%d", b.key.c_str(), want ? 1 : 0);
}

void set_guard_flag(Body& b, uint8_t v) {
    void* model = nullptr;
    if (!rd(b.ca, kCaModel, &model) || !model) return;
    call_setflag(A.fnSetFlag, static_cast<char*>(model) + kModelFlags, kGuardRequestScope, v);
}

void apply_combat(Body& b, const State2* st, double now) {
    const bool want = st && (st->bits & kBitCombat);
    if (!b.ca) b.ca = combat_actor_of(b.actor, true);
    if (!b.ca) return;
    void* model = nullptr;
    if (!rd(b.ca, kCaModel, &model) || !model || !prop_named(model, kPropCombatMode)) return;
    if (want) {
        if (!b.automationOff) {
            if (!call_auto(A.fnAuto, g_autoCmd, b.ca, false)) { c_faults.fetch_add(1); g_combat = false; g_whyCombat = "automation call faulted"; return; }
            b.automationOff = true;
            c_autoOff.fetch_add(1);
            logf("WO121-MOTION body=%s combat automation OFF (combat_EnableAutomation path)", b.key.c_str());
        }
        uint8_t mode = 0;
        rd(model, kPropCombatMode.off + 8, &mode);
        if (!mode && now - b.lastCombatAssert > 0.25) {
            b.lastCombatAssert = now;
            uint64_t r = 0;
            if (!call_trystart(A.fnTryStart, b.ca, &r)) { c_faults.fetch_add(1); g_combat = false; g_whyCombat = "TryStartCombatMode faulted"; return; }
            set_guard_flag(b, 1);
            ++b.combatStarts;
            c_combatStarts.fetch_add(1);
            if (b.combatStarts <= 3 || (b.combatStarts % 50) == 0)
                logf("WO121-MOTION body=%s combat mode start #%u -> %llu (guard-request flag scope %d set)", b.key.c_str(), b.combatStarts,
                     static_cast<unsigned long long>(r & 0xFF), kGuardRequestScope);
        }
        b.combatHeld = true;
        const int gz = static_cast<int>(st->guardZone) - 1, gs = static_cast<int>(st->guardStance) - 1, az = static_cast<int>(st->atkZone) - 1;
        if (gz >= 0 && (gz != b.appliedGz || gs != b.appliedGs)) {
            if (call_setguardzone(A.fnSetGuardZone, b.ca, gz, gs)) { b.appliedGz = gz; b.appliedGs = gs; c_guardZone.fetch_add(1); }
        }
        if (az >= 0 && az != b.appliedAz) {
            if (call_setatkzone(A.fnSetAtkZone, b.ca, az)) { b.appliedAz = az; c_atkZone.fetch_add(1); }
        }
        const bool block = (st->bits & kBitBlock) != 0;
        if (block != b.blockApplied) {
            if (call_setblock(A.fnSetBlock, b.ca, block, 0)) { b.blockApplied = block; c_block.fetch_add(1); }
            logf("WO121-MOTION body=%s block=%d", b.key.c_str(), block ? 1 : 0);
        }
    } else if (b.combatHeld) {
        if (b.blockApplied) { call_setblock(A.fnSetBlock, b.ca, false, 0); b.blockApplied = false; }
        set_guard_flag(b, 0);   // the engine's own PostUpdate then ends combat when nothing else holds it
        b.combatHeld = false;
        b.appliedGz = b.appliedGs = b.appliedAz = -2;
        logf("WO121-MOTION body=%s combat mode released", b.key.c_str());
    }
}

void set_avatar_contexts(Body& b, bool on);

void release_body(Body& b, const char* why) {
    release_gait(b);
    if (b.ctxApplied) set_avatar_contexts(b, false);
    if (b.crouchApplied && b.exp && vslot(b.exp, kExpSetCrouch) == A.fnSetCrouch) { call_bb(A.fnSetCrouch, b.exp, false, false); b.crouchApplied = false; }
    if (b.ca && is_a(b.ca, A.vftCa)) {
        if (b.blockApplied) call_setblock(A.fnSetBlock, b.ca, false, 0);
        if (b.combatHeld) set_guard_flag(b, 0);
        if (b.automationOff && A.fnAuto && g_autoCmdOn) call_auto(A.fnAuto, g_autoCmdOn, b.ca, true);
    }
    if (b.automationOff || b.combatHeld || b.crouchApplied)
        logf("WO121-MOTION body=%s released (%s) -- automation back on, flag cleared", b.key.c_str(), why);
    b.automationOff = b.combatHeld = b.blockApplied = false;
}

bool is_avatar_key(const char* key) {
    if (_strnicmp(key, "kcd2mp_", 7) != 0) return false;
    const char* d = key + 7;
    if (!*d) return false;
    for (; *d; ++d) if (*d < '0' || *d > '9') return false;
    return true;
}

// WO-121 Phase 6: the avatar is a puppet of another player, so its own brain
// must not react to THIS player. Tables.pak :: Libs/Tables/ai/ScriptContext.xml,
// all Class="Entity" rows on this build. Session 3 (observed): Henry drew a
// sword near the avatar -> it barked crime_reaction_barks.vytazena_zbran
// ("feels threatened by the player") and changed weapon on its own.
// Set only while the avatar's combat is ours (mp_avatar_combat on), so the
// legacy preset keeps the 0.28.x reactive ghost.
constexpr const char* kAvatarContexts[] = {
    "crime_ignorePlayersDrawnWeapon",       // the drawn-weapon bark and threat reaction
    "crime_disableHitFromPlayerReaction",   // a hit from the player starts no reaction
    "crime_suppressBehavioralReaction",     // new information starts no behaviour
    "crime_suppressFightStartBark",
    "combat_disableAllSkirmishBarks",
    // NOT combat_suppressFriendlyFire: with it set, a player's sword hit on
    // the avatar did no damage at all (session 5, unarmoured, buff off) --
    // nothing to measure, so nothing for friendly fire to forward.
};
std::atomic<uint32_t> c_ctxSet{0}, c_ctxFail{0};

void* body_soul(const Body& b) {
    void* soul = nullptr;
    void* fn = b.actor ? vslot(b.actor, kActorGetSoul) : nullptr;
    return fn && call_p0(fn, b.actor, &soul) ? soul : nullptr;
}

void set_avatar_contexts(Body& b, bool on) {
    void* soul = body_soul(b);
    if (!soul) return;
    int ok = 0, bad = 0;
    for (const char* n : kAvatarContexts) (kcdmp::sctx::set_soul_context(soul, n, on) >= 0 ? ok : bad)++;
    b.ctxApplied = on;
    c_ctxSet.fetch_add(ok); c_ctxFail.fetch_add(bad);
    logf("WO121-MOTION body=%s avatar contexts %s: %d ok, %d failed", b.key.c_str(), on ? "set" : "cleared", ok, bad);
}

// kcdmp_avatar_guard (buff__kcdmp.xml): imm=1 upr=1, non-persistent -- an
// avatar can never die or be knocked out in this world, whatever hits it.
unsigned char g_avatarGuard[16]{};
bool g_avatarGuardOk = false;
std::atomic<uint32_t> c_buffAdds{0};

void ensure_avatar_guard(Body& b, double now) {
    if (now - b.lastBuffCheck < 5.0) return;
    b.lastBuffCheck = now;
    const bool wantCtx = g_combat && g_cfgCombat;
    if (wantCtx != b.ctxApplied) set_avatar_contexts(b, wantCtx);
    if (!g_avatarGuardOk) return;
    void* soul = nullptr;
    void* fn = vslot(b.actor, kActorGetSoul);
    if (!fn || !call_p0(fn, b.actor, &soul) || !soul) return;
    if (buffs::has(soul, g_avatarGuard) > 0) return;
    if (buffs::add(soul, g_avatarGuard)) { c_buffAdds.fetch_add(1); logf("WO121-MOTION body=%s avatar guard applied (imm+upr)", b.key.c_str()); }
}

// WO-129: the body's own class count from the engine's logical-speed manager
// (GetGameIface()+0x138 -> vtbl[0x100]; count = vtbl[0x08](soul, kind)), re-read
// every 0.5 s because the kind (actor+0x860) follows the body's state. The
// manager's mapper (vtbl[0x78]) is byte-checked as the round(x)-1 function
// before anything is trusted. -1 = unreadable (the caller then clamps to 3).
int body_range(Body& b, double now) {
    if (b.rangeAt >= 0 && now - b.rangeAt < 0.5) return b.range;
    b.rangeAt = now;
    b.range = -1;
    void* gi = engine::game_iface();
    void* holder = nullptr;
    if (!gi || !rd(gi, kGiSpeedHolder, &holder) || !holder) return -1;
    void* getMgr = vslot(holder, kHolderGetSpeedMgr);
    void* mgr = nullptr;
    if (!getMgr || !call_p0(getMgr, holder, &mgr) || !mgr) return -1;
    void* map = vslot(mgr, kSpeedMgrMap);
    if (!map) return -1;
    if (map != g_fnSpeedMap) {
        HMODULE rpg = GetModuleHandleA("RPGModule.dll");
        if (!rpg || !has(rpg, map, {0xF3, 0x0F, 0x2C, 0xC6}) || !has(rpg, map, {0xFF, 0xC8})) return -1;
        g_fnSpeedMap = map;
    }
    void* cnt = vslot(mgr, kSpeedMgrCount);
    void* soul = body_soul(b);
    int32_t kind = -1;
    uint64_t n = 0;
    if (!cnt || !soul || !rd(b.actor, kActorSpeedType, &kind) || !call_count(cnt, mgr, soul, kind, &n) || n > 16) return -1;
    b.range = static_cast<int>(n);
    return b.range;
}

// WO-129: publish this frame's gait inputs for the tag-update hook.
void publish_gait(Body& b, float cls) {
    if (!g_gaitTable.holds(b.slot, b.actor)) b.slot = g_gaitTable.insert(b.actor, g_gaitTick.load(std::memory_order_relaxed));
    if (b.slot < 0) return;
    g_gaitTable.publish(b.slot, cls, b.velX, b.velY, g_gaitTick.load(std::memory_order_relaxed));
}

void unpublish_gait(Body& b) {
    if (g_gaitTable.holds(b.slot, b.actor)) g_gaitTable.remove(b.slot);
    b.slot = -1;
}

} // namespace

// ================================================================================
void install() {
    HMODULE em = GetModuleHandleA("EntityModule.dll");
    HMODULE cm = GetModuleHandleA("CombatModule.dll");
    if (!em || !cm) { logf("WO121-MOTION DISARMED -- EntityModule/CombatModule not loaded"); return; }

    // ---- gait: C_Actor vftable slot 0x448 -------------------------------------
    A.vftActor = anchor::find_vftable(em, ".?AVC_Actor@entitymodule@wh@@", 0);
    A.fnSetPseudo = slot_fn(A.vftActor, kActorSetPseudoSpeed);
    if (!A.fnSetPseudo) g_whyGait = "RTTI C_Actor vftable not unique";
    else if (!has(em, A.fnSetPseudo, {0x48, 0x8B, 0x83, 0xE8, 0x07, 0x00, 0x00}) || !has(em, A.fnSetPseudo, {0xF3, 0x0F, 0x11, 0x70, 0x18}))
        g_whyGait = "C_Actor slot 0x448 lacks the pseudo-speed write (actor+0x7E8 -> +0x18)";
    else { g_gait = true; g_whyGait.clear(); }

    // ---- crouch / jump: C_ActorStateExpansion ----------------------------------
    A.vftExp = anchor::find_vftable(em, ".?AVC_ActorStateExpansion@entitymodule@wh@@", 0);
    A.fnSetCrouch = slot_fn(A.vftExp, kExpSetCrouch);
    A.fnGetCrouch = slot_fn(A.vftExp, kExpGetCrouch);
    A.fnRequestJump = slot_fn(A.vftExp, kExpRequestJump);
    void* holderFn = slot_fn(A.vftActor, kActorExpHolder);
    if (!A.fnSetCrouch || !A.fnGetCrouch || !A.fnRequestJump) g_whyMoves = "RTTI C_ActorStateExpansion vftable not unique";
    else if (!has(em, A.fnSetCrouch, {0x40, 0x88, 0x7B, 0x18}) || !has(em, A.fnGetCrouch, {0x0F, 0xB6, 0x43, 0x18}))
        g_whyMoves = "SetCrouch/GetCrouch lack the crouch-desire byte (+0x18)";
    else if (!has(em, A.fnRequestJump, {0xFF, 0x90, 0xF8, 0x0A, 0x00, 0x00}))
        g_whyMoves = "RequestJump lacks its crouch check (actor vtbl 0xAF8)";
    else if (!holderFn || !has(em, holderFn, {0x48, 0x8B, 0x83, 0x08, 0x03, 0x00, 0x00}))
        g_whyMoves = "actor slot 0x980 does not return the expansion holder (actor+0x308)";
    else { g_moves = true; g_whyMoves.clear(); }

    // ---- combat: C_CombatActor + the shipped test commands' Execute ------------
    A.vftCa = anchor::find_vftable(cm, ".?AVC_CombatActor@combatmodule@wh@@", 0);
    A.vftCa8 = anchor::find_vftable(cm, ".?AVC_CombatActor@combatmodule@wh@@", 8);
    A.fnTryStart = slot_fn(A.vftCa, kCaTryStartCombat);
    auto exec_of = [&](const char* rtti) -> const void* {
        void* const* v = anchor::find_vftable(cm, rtti, 0);
        return v ? v[0xE0 / 8] : nullptr;
    };
    const void* exZone = exec_of(".?AVC_SetRequestedAttackZone@combattests@combatmodule@wh@@");
    const void* exGuard = exec_of(".?AVC_SetGuardZone@combattests@combatmodule@wh@@");
    const void* exBlock = exec_of(".?AVC_SetBlockMode@combatmodule@wh@@");
    const void* exAuto = exec_of(".?AVC_EnableAutomation@combatmodule@wh@@");
    const void* exSetGuard = exec_of(".?AVC_SetGuard@combattests@combatmodule@wh@@");
    const std::vector<const void*> execs{exZone, exGuard, exBlock, exAuto};
    std::string why;
    if (!A.vftCa || !A.fnTryStart) why = "RTTI C_CombatActor vftable not unique";
    else if (!has(cm, A.fnTryStart, {0xFF, 0x90, 0xD0, 0x06, 0x00, 0x00})) why = "slot 0x360 does not call StartCombatMode (+0x6D0)";
    else if (!exZone || !exGuard || !exBlock || !exAuto || !exSetGuard) why = "a combat test command's RTTI vftable is missing";
    else {
        A.fnSetAtkZone = const_cast<uint8_t*>(unique_target(cm, exZone, execs));
        A.fnSetGuardZone = const_cast<uint8_t*>(unique_target(cm, exGuard, execs));
        A.fnSetBlock = const_cast<uint8_t*>(unique_target(cm, exBlock, execs));
        // EnableAutomation's own target: the one that fetches the automation manager (ca vtbl 0x2C8).
        const uint8_t* at[64]{}; int nat = anchor::function_call_targets(cm, exAuto, at, 64);
        for (int i = 0; i < nat; ++i)
            if (has(cm, at[i], {0xFF, 0x92, 0xC8, 0x02, 0x00, 0x00}) || has(cm, at[i], {0xFF, 0x90, 0xC8, 0x02, 0x00, 0x00})) { A.fnAuto = const_cast<uint8_t*>(at[i]); break; }
        // SetFlag: called by C_SetGuard::Execute AND by the string-anchored ClearStandardGuard.
        const uint8_t* clear = anchor::function_by_string(cm, "Player standard guard request cleared");
        const uint8_t* sg[64]{}; int nsg = anchor::function_call_targets(cm, exSetGuard, sg, 64);
        for (int i = 0; clear && i < nsg; ++i)
            if (anchor::function_calls(cm, clear, sg[i]) && has(cm, sg[i], {0x48, 0x63, 0xEA})) { A.fnSetFlag = const_cast<uint8_t*>(sg[i]); break; }
        // Actor lookup: the Execute bodies resolve gi+0x188 -> vtbl[0x18](eid) -> vtbl[0x970].
        A.actorLookup = has(cm, exGuard, {0x48, 0x8B, 0x88, 0x88, 0x01, 0x00, 0x00}) && has(cm, exGuard, {0xFF, 0x50, 0x18})
                     && has(cm, exGuard, {0x48, 0x8B, 0x91, 0x70, 0x09, 0x00, 0x00});
        if (!A.fnSetAtkZone || !A.fnSetGuardZone || !A.fnSetBlock) why = "a setter is not the unique call of its test command";
        else if (!A.fnAuto) why = "no EnableAutomation target fetches the automation manager (ca vtbl 0x2C8)";
        else if (!A.fnSetFlag) why = "SetFlag is not the common call of C_SetGuard::Execute and ClearStandardGuard";
        else if (!A.actorLookup) why = "the test command's actor lookup (gi+0x188 -> 0x18 -> 0x970) did not verify";
    }
    if (why.empty()) {
        g_autoCmd = VirtualAlloc(nullptr, 0x100, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        g_autoCmdOn = VirtualAlloc(nullptr, 0x100, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        if (g_autoCmdOn) { auto* c = static_cast<uint8_t*>(g_autoCmdOn); c[0x79] = c[0x7A] = c[0x7B] = 1; }
        if (!g_autoCmd || !g_autoCmdOn) why = "no memory for the automation stand-in";
    }
    if (why.empty()) { g_combat = true; g_whyCombat.clear(); } else g_whyCombat = why;
    if (!A.actorLookup) { g_gait = false; if (g_whyGait.empty()) g_whyGait = "actor lookup did not verify"; g_moves = false; if (g_whyMoves.empty()) g_whyMoves = "actor lookup did not verify"; }

    // ---- WO-129: the tag-update hook (C_Actor vftable slot 0xC98) --------------
    // Without it a written body slides whatever SetPseudoSpeed we call (observed),
    // so the gait piece is armed only with it: otherwise the Lua clip walk stays.
    {
        const void* tags = slot_fn(A.vftActor, kActorUpdateTags);
        std::string whyT;
        if (!tags) whyT = "RTTI C_Actor vftable has no slot 0xC98";
        else if (!has(em, tags, {0x48, 0x8B, 0x91, 0x50, 0x04, 0x00, 0x00}))          // mov rdx,[rcx+0x450] (GetPseudoSpeed)
            whyT = "slot 0xC98 does not read GetPseudoSpeed (+0x450)";
        else if (!has(em, tags, {0xF3, 0x0F, 0x10, 0x8F, 0x74, 0x05, 0x00, 0x00}))     // movss xmm1,[rdi+0x574] (requested velocity)
            whyT = "slot 0xC98 does not read the requested velocity (+0x574)";
        else if (!has(em, tags, {0xF2, 0x44, 0x0F, 0x10, 0x87, 0x14, 0x06, 0x00, 0x00})) // movsd xmm8,[rdi+0x614] (move vector)
            whyT = "slot 0xC98 does not read the move vector (+0x614)";
        else if (!has(em, tags, {0x48, 0x8D, 0x8F, 0x50, 0x08, 0x00, 0x00}))          // lea rcx,[rdi+0x850] (stance manager)
            whyT = "slot 0xC98 does not reach the stance manager (+0x850)";
        else {
            const char* why = nullptr;
            if (inlinehook::install_this(const_cast<void*>(tags), kTagsPrologue, sizeof(kTagsPrologue), &on_update_tags, &why)) g_tags = true;
            else whyT = std::string("hook refused: ") + (why ? why : "?");
        }
        g_whyTags = g_tags ? "" : whyT;
        char dt[64]{}; anchor::describe(tags, dt, sizeof dt);
        logf("WO129-GAIT tag hook %s at %s%s%s", g_tags ? "installed" : "NOT installed", dt, whyT.empty() ? "" : " -- ", whyT.c_str());
        if (!g_tags && g_gait) { g_gait = false; g_whyGait = "no tag-update hook (" + whyT + ")"; }
    }

    // ---- capture: EnterImpl on the four action classes, RequestJump ------------
    A.vftAttack = anchor::find_vftable(cm, ".?AVC_CombatActorActionAttack@combatmodule@wh@@", 0);
    A.vftDodge = anchor::find_vftable(cm, ".?AVC_CombatActorActionDodge@combatmodule@wh@@", 0);
    A.vftPerfect = anchor::find_vftable(cm, ".?AVC_CombatActorActionPerfectBlock@combatmodule@wh@@", 0);
    A.vftBlock = anchor::find_vftable(cm, ".?AVC_CombatActorActionBlock@combatmodule@wh@@", 0);
    void* const* vfts[kClsCount] = {A.vftAttack, A.vftDodge, A.vftPerfect, A.vftBlock};
    std::string whyCap;
    if (!A.vftAttack || !A.vftCa) whyCap = "RTTI C_CombatActorActionAttack / C_CombatActor vftable missing";
    else {
        // The attack ctor stores the combat actor at +0x78: the one fact the
        // owner check rests on, verified in the class's own constructor.
        const uint8_t* ctor = nullptr;
        // (the ctor is the function that writes this vftable; find it by the vftable reference + the store)
        static const uint8_t kStore[] = {0x48, 0x89, 0x6B, 0x78};   // mov [rbx+0x78], rbp
        HMODULE m = cm;
        const uint8_t* cands[1]{};
        (void)cands; (void)ctor;
        bool ctorOk = false;
        // Search .text for the one function that references the vftable and holds the store.
        anchor::Range text{};
        if (anchor::section(m, ".text", &text)) {
            const auto* vft = reinterpret_cast<const uint8_t*>(A.vftAttack);
            for (const uint8_t* q = text.begin; q + 7 <= text.end && !ctorOk; ++q) {
                if ((q[0] & 0xF8) != 0x48 || q[1] != 0x8D || (q[2] & 0xC7) != 0x05) continue;
                int32_t d; std::memcpy(&d, q + 3, 4);
                if (q + 7 + d != vft) continue;
                if (anchor::function_has_bytes(m, q, kStore, sizeof(kStore))) ctorOk = true;
            }
        }
        if (!ctorOk) whyCap = "no C_CombatActorActionAttack constructor stores the combat actor at +0x78";
    }
    if (whyCap.empty()) {
        g_thunks = static_cast<uint8_t*>(VirtualAlloc(nullptr, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE));
        if (!g_thunks) whyCap = "no memory for the capture thunks";
    }
    int patched = 0;
    if (whyCap.empty()) {
        for (int c = 0; c < kClsCount; ++c) {
            if (!vfts[c]) continue;
            void* cur = vfts[c][kActionEnterImpl / 8];
            if (!cur) continue;
            uint8_t* th = g_thunks + c * 128;
            make_thunk(th, static_cast<uint64_t>(c), cur);
            FlushInstructionCache(GetCurrentProcess(), th, 128);
            void* orig = nullptr;
            if (patch_slot(vfts[c], kActionEnterImpl, th, &orig)) { g_origEnter[c] = orig; ++patched; }
        }
        if (!g_origEnter[kClsAttack]) whyCap = "the attack EnterImpl slot could not be patched";
    }
    if (whyCap.empty() && g_moves) {
        void* orig = nullptr;
        if (patch_slot(A.vftExp, kExpRequestJump, reinterpret_cast<void*>(&hk_request_jump), &orig)) g_origJump = reinterpret_cast<RequestJumpFn>(orig);
    }
    if (whyCap.empty()) { g_capture = true; g_whyCapture.clear(); } else g_whyCapture = whyCap;

    g_avatarGuardOk = buffs::parse_guid("4b43444d-7121-4d67-b1a5-9e2f6d8c0a15", g_avatarGuard) && buffs::ready();

    char dp[64]{}, dc[64]{}, dj[64]{}, dt[64]{}, da[64]{}, df[64]{}, dg[64]{}, dz[64]{}, db[64]{};
    anchor::describe(A.fnSetPseudo, dp, sizeof dp); anchor::describe(A.fnSetCrouch, dc, sizeof dc); anchor::describe(A.fnRequestJump, dj, sizeof dj);
    anchor::describe(A.fnTryStart, dt, sizeof dt); anchor::describe(A.fnAuto, da, sizeof da); anchor::describe(A.fnSetFlag, df, sizeof df);
    anchor::describe(A.fnSetGuardZone, dg, sizeof dg); anchor::describe(A.fnSetAtkZone, dz, sizeof dz); anchor::describe(A.fnSetBlock, db, sizeof db);
    log_piece("gait", g_gait, g_whyGait);
    log_piece("crouch_jump", g_moves, g_whyMoves);
    log_piece("combat", g_combat, g_whyCombat);
    log_piece("capture", g_capture, g_whyCapture);
    logf("WO121-MOTION gait=%s moves=%s combat=%s capture=%s(enter_patched=%d jump_hook=%s) avatar_guard=%s "
         "set_pseudo=%s set_crouch=%s request_jump=%s try_start=%s automation=%s set_flag=%s set_guard_zone=%s set_atk_zone=%s set_block=%s",
         g_gait ? "armed" : "off", g_moves ? "armed" : "off", g_combat ? "armed" : "off", g_capture ? "armed" : "off", patched,
         g_origJump ? "on" : "off", g_avatarGuardOk ? "ready" : "unavailable", dp, dc, dj, dt, da, df, dg, dz, db);
}

uint8_t on_config(const uint8_t* body, size_t len) {
    if (len != 5) return 8;
    g_cfgAvatarGait = body[0] != 0; g_cfgNpcGait = body[1] != 0; g_cfgMoves = body[2] != 0;
    g_cfgCombat = body[3] != 0; g_cfgNpcRows = body[4] != 0;
    g_cfgChanged = true;
    logf("WO121-MOTION config avatar_gait=%d npc_gait=%d avatar_moves=%d avatar_combat=%d npc_rows=%d",
         body[0] != 0, body[1] != 0, body[2] != 0, body[3] != 0, body[4] != 0);
    return 0;
}

uint8_t on_avatar_event(const uint8_t* body, size_t len) {
    if (len != 5) return 8;
    PendingEvent e{ body[0], 0 };
    std::memcpy(&e.eid, body + 1, 4);
    std::lock_guard<std::mutex> lock(g_evMutex);
    if (g_events.size() < 64) g_events.push_back(e);
    return 0;
}

void body_frame(const char* key, void* ent, uint32_t eid, float renderSpeedMps, float renderVx, float renderVy,
                const State2* st, double stAgeS, double now) {
    Body& b = g_bodies[eid];
    if (b.ent != ent || b.eid != eid) {
        unpublish_gait(b);   // WO-129: never leave a slot naming a body we no longer drive
        b = Body{};
        b.eid = eid; b.ent = ent; b.key = key; b.avatar = is_avatar_key(key);
        b.actor = actor_by_eid(eid);
        if (b.actor && b.avatar) b.ca = combat_actor_of(b.actor, true);
        if (b.actor) b.exp = expansion_of(b.actor);
        logf("WO121-MOTION body=%s eid=0x%X attach avatar=%d actor=%s ca=%s exp=%s", key, eid, b.avatar ? 1 : 0,
             b.actor ? "yes" : "NO", b.ca ? "yes" : "no", b.exp ? "yes" : "no");
        if (b.avatar && b.actor) {
            void* soul = nullptr;
            void* fn = vslot(b.actor, kActorGetSoul);
            if (fn && call_p0(fn, b.actor, &soul) && soul) hits::note_avatar(eid, soul, true);
        }
    }
    if (!b.actor) return;
    const bool fresh = st && stAgeS < 1.5;
    // gait
    const bool gaitOn = g_gait && (b.avatar ? g_cfgAvatarGait.load() : g_cfgNpcGait.load());
    if (gaitOn) {
        float s = (b.avatar && fresh) ? st->speedCm / 100.0f : renderSpeedMps;
        // A render step faster than any gait (> 9 m/s) is a snap or a teleport,
        // never a pace: it keeps the previous speed instead of a sprint burst.
        const bool snap = !(renderVx * renderVx + renderVy * renderVy < 81.0f);
        if (!(b.avatar && fresh) && s > 9.0f) s = b.speedEma;
        if (!(b.avatar && fresh)) {
            // The rendered speed is per-frame noisy at 60+ fps: smooth it (tau ~0.15 s).
            b.speedEma += (s - b.speedEma) * 0.2f;
            s = b.speedEma < 0.05f ? 0.0f : b.speedEma;
        }
        // WO-129: the direction tag's input, the rendered velocity (tau ~0.12 s).
        if (!snap) { b.velX += (renderVx - b.velX) * 0.25f; b.velY += (renderVy - b.velY) * 0.25f; }
        // WO-129: pseudo-speed is a logical speed CLASS; clamp it to this body's own range.
        const int range = body_range(b, now);
        const float cls = gait::clamp_class(gait::speed_class(s), range);
        b.cls = cls;
        apply_gait(b, cls);
        publish_gait(b, cls);
        if (b.avatar && now - b.lastGaitLog >= 2.0) {
            b.lastGaitLog = now;
            void* comp = nullptr; float back = -1.0f;
            if (rd(b.actor, kActorPseudoComp, &comp) && comp) rd(comp, 0x18, &back);
            logf("WO121-GAIT body=%s state=%s age_s=%.2f stream_cm_s=%u render_mps=%.2f speed_mps=%.2f class=%.0f range=%d readback=%.2f tags_applied=%u",
                 b.key.c_str(), st ? (fresh ? "fresh" : "stale") : "none", st ? stAgeS : -1.0, st ? st->speedCm : 0,
                 renderSpeedMps, s, cls, range, back, c_tagApplied.load(std::memory_order_relaxed));
        }
    } else if (b.gaitWritten || b.slot >= 0) release_gait(b);
    if (!b.avatar) return;
    ensure_avatar_guard(b, now);
    // crouch
    if (g_moves && g_cfgMoves) {
        const bool want = fresh && (st->bits & kBitCrouch);
        if (want != b.crouchApplied) apply_crouch(b, want);
    } else if (b.crouchApplied) apply_crouch(b, false);
    // combat
    if (g_combat && g_cfgCombat) apply_combat(b, fresh ? st : nullptr, now);
    else if (b.automationOff || b.combatHeld) release_body(b, "toggle off");
}

void body_released(const char* key, uint32_t eid) {
    auto it = g_bodies.find(eid);
    if (it == g_bodies.end()) return;
    if (it->second.avatar) hits::note_avatar(eid, nullptr, false);
    unpublish_gait(it->second);   // WO-129: even when the entity is already gone
    if (it->second.actor && engine::entity_by_id(eid) == it->second.ent) release_body(it->second, key);
    g_bodies.erase(it);
}

bool read_local_state2(State2* out, float facingYaw) {
    *out = State2{};
    void* actor = player_actor();
    if (!actor) return false;
    float v[3]{};
    if (!rd(actor, kActorReqVel, &v[0]) || !rd(actor, kActorReqVel + 4, &v[1])) return false;
    const float speed = std::sqrt(v[0] * v[0] + v[1] * v[1]);
    if (!std::isfinite(speed)) return false;
    out->speedCm = static_cast<uint16_t>(speed * 100.0f > 65535.0f ? 65535 : speed * 100.0f + 0.5f);
    // Facing is the yaw local_state read from the entity matrix in the same
    // call; heading is the requested velocity's, in the same convention
    // (forward = (-sin yaw, cos yaw)).
    if (speed > 0.05f && std::isfinite(facingYaw)) {
        const float facing = facingYaw;
        const float heading = std::atan2(-v[0], v[1]);
        float d = heading - facing;
        while (d > 3.14159265f) d -= 6.2831853f;
        while (d <= -3.14159265f) d += 6.2831853f;
        int q = static_cast<int>(std::lround(d * 128.0f / 3.14159265f));
        if (q > 127) q -= 256;
        out->moveDir = static_cast<int8_t>(q);
    }
    void* ca = combat_actor_of(actor, false);
    g_playerCa = ca;
    if (A.vftExp) {
        void* exp = expansion_of(actor);
        g_playerExp = exp;
        uint8_t cr = 0;
        if (exp && vslot(exp, kExpGetCrouch) == A.fnGetCrouch && call_ret_u8(A.fnGetCrouch, exp, &cr) && cr) out->bits |= kBitCrouch;
    }
    if (ca) {
        void* model = nullptr;
        if (rd(ca, kCaModel, &model) && model) {
            uint8_t cm = 0; int32_t gz = -1, gs = -1, az = -1; uint8_t blk = 0; void* opp = nullptr;
            if (prop_value(model, kPropCombatMode, &cm) && cm) out->bits |= kBitCombat;
            if (prop_value(model, kPropGuardZone, &gz)) out->guardZone = static_cast<uint8_t>(gz + 1 < 0 ? 0 : gz + 1);
            if (prop_value(model, kPropGuardStance, &gs)) out->guardStance = static_cast<uint8_t>(gs + 1 < 0 ? 0 : gs + 1);
            if (prop_value(model, kPropReqAtkZone, &az)) out->atkZone = static_cast<uint8_t>(az + 1 < 0 ? 0 : az + 1);
            if (rd(model, kModelBlockMax, &blk) && blk) out->bits |= kBitBlock;
            if (rd(model, kModelOpponent, &opp) && opp) out->bits |= kBitLocked;
        }
    }
    return true;
}

void tick() {
    g_gaitTick.fetch_add(1, std::memory_order_relaxed);   // WO-129: the gait table's freshness clock
    // Keep the player's combat actor / expansion fresh for the capture hooks
    // (a load replaces them). Cheap: two virtual calls a frame.
    if (void* actor = player_actor()) {
        g_playerCa = combat_actor_of(actor, false);
        if (A.vftExp) g_playerExp = expansion_of(actor);
    }
    std::vector<PendingEvent> evs;
    { std::lock_guard<std::mutex> lock(g_evMutex); evs.swap(g_events); }
    for (const auto& e : evs) {
        if (e.kind != 1) continue;
        if (!g_moves || !g_cfgMoves) continue;
        auto it = g_bodies.find(e.eid);
        void* actor = it != g_bodies.end() ? it->second.actor : actor_by_eid(e.eid);
        void* exp = it != g_bodies.end() && it->second.exp ? it->second.exp : (actor ? expansion_of(actor) : nullptr);
        bool ok = false;
        if (exp && vslot(exp, kExpRequestJump) == reinterpret_cast<void*>(&hk_request_jump) && g_origJump) {
            if (!call_jump(g_origJump, exp, &ok)) { ok = false; c_faults.fetch_add(1); }
        } else if (exp && vslot(exp, kExpRequestJump) == A.fnRequestJump) {
            call_ret_b(A.fnRequestJump, exp, &ok);
        }
        (ok ? c_jumps : c_jumpFail).fetch_add(1);
        logf("WO121-MOTION eid=0x%X jump -> %s", e.eid, ok ? "accepted" : "refused");
    }
    std::vector<Captured> caps;
    { std::lock_guard<std::mutex> lock(g_capMutex); caps.swap(g_captured); }
    if (ActionFn fn = g_actionFn.load())
        for (const auto& c : caps) fn(c.kind, 1, c.ic, c.zone, c.type, c.flags, c.guid, c.eid, c.name);
    if (g_cfgChanged.exchange(false) && !(g_cfgCombat && g_cfgAvatarGait && g_cfgMoves)) {
        for (auto& kv : g_bodies) {
            Body& b = kv.second;
            if (!b.avatar) continue;
            if (!g_cfgCombat && (b.automationOff || b.combatHeld)) release_body(b, "toggle off");
            if (!g_cfgAvatarGait && b.gaitWritten) release_gait(b);
            if (!g_cfgMoves && b.crouchApplied) apply_crouch(b, false);
        }
    }
}

void set_action_callback(ActionFn fn) { g_actionFn.store(fn); }

int status_text(char* out, int n) {
    return std::snprintf(out, n,
        "gait=%s moves=%s combat=%s attack_capture=%s cfg=%d%d%d%d%d bodies=%zu gait_writes=%u crouch=%u jumps=%u/%u "
        "combat_starts=%u automation_off=%u guard_zone=%u atk_zone=%u block=%u cap_attack=%u cap_npc=%u cap_jump=%u cap_other=%u "
        "cap_dropped=%u buff_adds=%u ctx_set=%u ctx_fail=%u faults=%u tags=%s tags_applied=%u gait_slots=%d "
        "cap_drop_notca=%u cap_drop_nodesc=%u cap_drop_noguid=%u cap_drop_noowner=%u cap_via_base8=%u cap_ours=%u",
        g_gait ? "armed" : "off", g_moves ? "armed" : "off", g_combat ? "armed" : "off", g_capture ? "armed" : "off",
        g_cfgAvatarGait.load(), g_cfgNpcGait.load(), g_cfgMoves.load(), g_cfgCombat.load(), g_cfgNpcRows.load(), g_bodies.size(),
        c_gaitWrites.load(), c_crouch.load(), c_jumps.load(), c_jumpFail.load(), c_combatStarts.load(), c_autoOff.load(),
        c_guardZone.load(), c_atkZone.load(), c_block.load(), c_capAttack.load(), c_capNpc.load(), c_capJump.load(), c_capOther.load(),
        c_capDropped.load(), c_buffAdds.load(), c_ctxSet.load(), c_ctxFail.load(), c_faults.load(),
        g_tags ? "armed" : "off", c_tagApplied.load(), g_gaitTable.live(),
        c_dropNotCa.load(), c_dropNoDesc.load(), c_dropNoGuid.load(), c_dropNoOwner.load(), c_capViaBase8.load(), c_capOurs.load());
}

bool is_avatar_eid(uint32_t eid) {
    auto it = g_bodies.find(eid);
    return it != g_bodies.end() && it->second.avatar;
}

void* player_combat_actor() { return g_playerCa.load(); }

} // namespace kcdmp::motion
