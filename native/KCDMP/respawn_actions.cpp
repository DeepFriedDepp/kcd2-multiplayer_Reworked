#include "respawn_actions.h"
#include "anchors.h"
#include "engine.h"
#include "hangover.h"
#include "local_state.h"
#include "pe_exports.h"
#include "log.h"

#include <windows.h>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

namespace kcdmp::actions {

namespace {

// ---------------------------------------------------------------------------
// SEH-isolated call helpers (no destructible locals in any __try frame).
// ---------------------------------------------------------------------------
bool rd(const void* base, size_t off, void** out) {
    __try { *out = *reinterpret_cast<void* const*>(static_cast<const char*>(base) + off); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool rd64(const void* base, size_t off, uint64_t* out) {
    __try { *out = *reinterpret_cast<const uint64_t*>(static_cast<const char*>(base) + off); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool rd8(const void* base, size_t off, uint8_t* out) {
    __try { *out = *(static_cast<const uint8_t*>(base) + off); return true; }
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
template <typename R, typename... A>
bool fcall(void* fn, R* out, A... a) {
    if (!fn) return false;
    __try { *out = reinterpret_cast<R (*)(A...)>(fn)(a...); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
template <typename... A>
bool fcall_void(void* fn, A... a) {
    if (!fn) return false;
    __try { reinterpret_cast<void (*)(A...)>(fn)(a...); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool ilock_add(void* p, long delta, long* after) {
    __try { *after = InterlockedAdd(static_cast<volatile long*>(p), delta); return true; }
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

// A CryStringT<char> the engine may retain: header {refcount, len, cap} at
// data-12. The refcount must be a LARGE POSITIVE sentinel -- a negative one is
// silently swapped for "" by the engine's copy path (WO-97's trap). Static
// storage: a retained pointer stays valid.
struct CryStr {
    int32_t ref, len, cap;
    char    data[96];
    bool set(const char* s) {
        const size_t n = std::strlen(s);
        if (n + 1 > sizeof(data)) return false;
        ref = 0x40000000; len = cap = static_cast<int32_t>(n);
        std::memcpy(data, s, n + 1);
        return true;
    }
    const char* ptr() const { return data; }
};

uint32_t float_bits(float f) { uint32_t u; std::memcpy(&u, &f, 4); return u; }

bool g_resolved = false;

// ---------------------------------------------------------------------------
// Fader (GUIModule C_FaderController; the dice / digging / fast-travel pattern)
// ---------------------------------------------------------------------------
struct BasicFader { void* vptr; void* ctrl; const char* name; void* describer; };
static_assert(sizeof(BasicFader) == 0x20, "C_BasicFader is 0x20 bytes");

constexpr size_t kGiGui         = 0xF0;
constexpr size_t kGuiGetFader   = 0x38;
constexpr size_t kFadeIsOut     = 0x28;
constexpr size_t kFadeOut       = 0x48;
constexpr size_t kFadeIn        = 0x58;

bool          g_fadeArmed = false;
void* const*  g_vftGui = nullptr;
void* const*  g_vftFaderCtrl = nullptr;
void* const*  g_vftBasicFader = nullptr;
BasicFader    g_fader{};
CryStr        g_faderName{};
bool          g_fadeActive = false;

void* fader_ctrl() {
    void* gi = engine::game_iface();
    void* gui = nullptr; void* ctrl = nullptr;
    if (!gi || !rd(gi, kGiGui, &gui) || !is_a(gui, g_vftGui)) return nullptr;
    if (!vcall(gui, kGuiGetFader, &ctrl) || !is_a(ctrl, g_vftFaderCtrl)) return nullptr;
    return ctrl;
}

void resolve_fader() {
    HMODULE gm = GetModuleHandleA("GUIModule.dll");
    if (!gm) { logf("ACTIONS: fade NOT armed -- GUIModule.dll not loaded"); return; }
    g_vftGui = anchor::find_vftable(gm, ".?AVC_GUIModule@guimodule@wh@@", 0);
    g_vftFaderCtrl = anchor::find_vftable(gm, ".?AVC_FaderController@guimodule@wh@@", 0);
    g_vftBasicFader = anchor::find_vftable(gm, ".?AV?$C_BasicFader@VC_FaderController@guimodule@wh@@@guimodule@wh@@", 0);
    if (!g_vftGui || !g_vftFaderCtrl || !g_vftBasicFader) {
        logf("ACTIONS: fade NOT armed -- RTTI C_GUIModule / C_FaderController / C_BasicFader not unique");
        return;
    }
    void* ctrl = fader_ctrl();
    bool out = true;
    if (!ctrl || !vcall(ctrl, kFadeIsOut, &out)) {
        logf("ACTIONS: fade NOT armed -- GameInterface+0xF0 -> vtbl[0x38] is not the C_FaderController");
        return;
    }
    g_faderName.set("KCDMP_respawn");
    g_fadeArmed = true;
    logf("ACTIONS: fade armed (C_FaderController by RTTI; faded-out now=%d)", out ? 1 : 0);
}

// ---------------------------------------------------------------------------
// Player: C_Player, teleport, ground re-snap, inventory
// ---------------------------------------------------------------------------
constexpr size_t kPlayerTeleportToWuid = 0xEE0;   // -> jmp C_Player::ExecuteTeleportImpl
constexpr size_t kActorResnap          = 0x3B8;   // C_Actor ground re-snap ("NPC:Update:CorrectZOffset")
constexpr size_t kActorGetSoul         = 0x6E0;
constexpr size_t kSoulGetInventory     = 0x430;

bool          g_teleArmed = false;
bool          g_resnapArmed = false;
void* const*  g_vftPlayer = nullptr;
void*         g_emInstanceSlot = nullptr;
void*         g_getPlayerActor = nullptr;
void*         g_getItemManager = nullptr;

void* entity_module() {
    void* em = nullptr;
    return (g_emInstanceSlot && rd(g_emInstanceSlot, 0, &em)) ? em : nullptr;
}
void* player_actor() {
    void* em = entity_module(); void* a = nullptr;
    return (em && fcall(g_getPlayerActor, &a, em)) ? a : nullptr;
}
void* c_player() {
    void* a = player_actor();
    return is_a(a, g_vftPlayer) ? a : nullptr;
}

void resolve_player() {
    HMODULE em = GetModuleHandleA("EntityModule.dll");
    if (!em) { logf("ACTIONS: teleport NOT armed -- EntityModule.dll not loaded"); return; }
    const auto ex = module_exports(em);
    g_emInstanceSlot = find_export(ex, "?m_Instance@C_EntityModule@entitymodule@wh@@");
    g_getPlayerActor = find_export(ex, "?GetPlayerActor@C_EntityModule@entitymodule@wh@@");
    g_getItemManager = find_export(ex, "?GetItemManager@C_EntityModule@entitymodule@wh@@");
    g_vftPlayer = anchor::find_vftable(em, ".?AVC_Player@entitymodule@wh@@", 0);
    if (!g_emInstanceSlot || !g_getPlayerActor || !g_vftPlayer) {
        logf("ACTIONS: teleport NOT armed -- C_EntityModule exports or RTTI C_Player missing");
        return;
    }
    // Slot 0xEE0 is a thin wrapper that tail-jumps into ExecuteTeleportImpl.
    const uint8_t* impl = anchor::function_by_string(em, "wh::entitymodule::C_Player::ExecuteTeleportImpl");
    const void* wrapper = g_vftPlayer[kPlayerTeleportToWuid / 8];
    uint8_t jmp[5]{};
    bool tail = false;
    if (impl && wrapper) {
        // search the wrapper's first 64 bytes for an E9 rel32 to impl
        for (int i = 0; i < 64 && !tail; ++i) {
            uint8_t b = 0;
            if (!rd8(wrapper, i, &b)) break;
            if (b != 0xE9) continue;
            int32_t rel = 0;
            for (int k = 0; k < 4; ++k) { uint8_t x = 0; rd8(wrapper, i + 1 + k, &x); reinterpret_cast<uint8_t*>(&rel)[k] = x; }
            tail = (static_cast<const uint8_t*>(wrapper) + i + 5 + rel) == impl;
            (void)jmp;
        }
    }
    const bool calls = impl && wrapper && (tail || anchor::function_calls(em, wrapper, impl));
    if (!calls) {
        logf("ACTIONS: teleport NOT armed -- C_Player slot 0xEE0 does not reach C_Player::ExecuteTeleportImpl");
    } else {
        g_teleArmed = true;
    }
    const uint8_t* correctZ = anchor::function_by_string(em, "NPC:Update:CorrectZOffset");
    const void* resnap = g_vftPlayer[kActorResnap / 8];
    g_resnapArmed = correctZ && resnap && anchor::function_calls(em, resnap, correctZ);
    logf("ACTIONS: teleport %s (C_Player RTTI; slot 0xEE0 -> ExecuteTeleportImpl), ground re-snap %s (slot 0x3B8 -> CorrectZOffset)",
         g_teleArmed ? "armed" : "NOT armed", g_resnapArmed ? "armed" : "NOT armed");
}

// ---------------------------------------------------------------------------
// Inventory and items (EntityModule; agent-B recipe, docs/WO-113-findings.md s4)
// ---------------------------------------------------------------------------
constexpr size_t kInvPresentBegin = 0x08;
constexpr size_t kInvPresentEnd   = 0x10;
constexpr size_t kInvTakeItem     = 0x10;    // C_ItemHolder::TakeItem (what the AddItem scriptbind calls)
constexpr size_t kInvPresentCount = 0x118;
constexpr size_t kInvRemoveAll    = 0x128;
constexpr size_t kImGetItem       = 0x48;
constexpr size_t kItemWuid        = 0x30;
constexpr size_t kItemHolder      = 0x90;
constexpr size_t kItemBorrower    = 0x98;
constexpr size_t kItemGetClass    = 0x20;
constexpr size_t kItemGetFlags    = 0x168;
constexpr size_t kItemIsCategory  = 0x1F8;
constexpr size_t kItemDespawn     = 0x260;
constexpr size_t kClassIsCategory = 0x20;
constexpr size_t kClassPlayerData = 0xE8;
constexpr size_t kPlayerDataQuest = 0xB0;
constexpr uint64_t kItemFlagQuest = 0x2;
constexpr int    kCatMoney = 6, kCatKeyring = 18, kCatPlayerItem = 25;
constexpr size_t kMaxItems = 2048;

bool          g_invArmed = false;
void* const*  g_vftInventory = nullptr;
void* const*  g_vftItem = nullptr;
void* const*  g_vftItemMgr = nullptr;
void*         g_stashFind = nullptr;
void*         g_stashGetInventory = nullptr;

void* item_manager() {
    void* em = entity_module(); void* im = nullptr;
    if (!em || !fcall(g_getItemManager, &im, em)) return nullptr;
    return is_a(im, g_vftItemMgr) ? im : nullptr;
}

void* player_inventory() {
    void* a = player_actor(); void* soul = nullptr; void* inv = nullptr;
    if (!a || !vcall(a, kActorGetSoul, &soul) || !soul) return nullptr;
    if (!vcall(soul, kSoulGetInventory, &inv)) return nullptr;
    return is_a(inv, g_vftInventory) ? inv : nullptr;
}

void* stash_inventory(uint32_t entityId) {
    void* stash = nullptr; void* inv = nullptr;
    if (!fcall(g_stashFind, &stash, entityId) || !stash) return nullptr;
    if (!fcall(g_stashGetInventory, &inv, stash)) return nullptr;
    return is_a(inv, g_vftInventory) ? inv : nullptr;
}

int present_count(void* inv) {
    uint64_t n = 0;
    if (!is_a(inv, g_vftInventory) || !vcall(inv, kInvPresentCount, &n)) return -1;
    return static_cast<int>(n & 0x7FFFFFFF);
}

void resolve_inventory() {
    HMODULE em = GetModuleHandleA("EntityModule.dll");
    if (!em) return;
    const auto ex = module_exports(em);
    g_vftInventory = anchor::find_vftable(em, ".?AVC_Inventory@entitymodule@wh@@", 0);
    g_vftItem = anchor::find_vftable(em, ".?AVC_Item@entitymodule@wh@@", 0);
    g_vftItemMgr = anchor::find_vftable(em, ".?AVC_ItemManager@entitymodule@wh@@", 0);
    g_stashFind = find_export(ex, "?FindInstance@C_Stash@entitymodule@wh@@");
    g_stashGetInventory = find_export(ex, "?GetInventory@C_Stash@entitymodule@wh@@");
    void* takeExport = find_export(ex, "?TakeItem@C_ItemHolder@entitymodule@wh@@");
    if (!g_vftInventory || !g_vftItem || !g_vftItemMgr || !g_stashFind || !g_stashGetInventory || !takeExport ||
        !g_getItemManager) {
        logf("ACTIONS: graves NOT armed -- an inventory/item RTTI or C_Stash/TakeItem export is missing");
        return;
    }
    void* inv = player_inventory();
    void* im = item_manager();
    const bool takeIsExport = g_vftInventory[kInvTakeItem / 8] == takeExport;
    logf("ACTIONS: inventory: player inventory %s, item manager %s, C_Inventory slot 0x10 %s the exported C_ItemHolder::TakeItem",
         inv ? "found (RTTI C_Inventory)" : "not there yet (checked again at every use)", im ? "found (RTTI C_ItemManager)" : "not there yet",
         takeIsExport ? "IS" : "is NOT (an override; the slot is what AddItem calls)");
    // WO-129: armed on the static anchors alone. Every joiner injects at the
    // main menu, where no player inventory exists yet: the first two-player
    // session's joiner logged "graves NOT armed" at startup and made no grave
    // at its death. make_grave() and move_everything() fetch the player
    // inventory and the item manager at use and refuse cleanly without them.
    g_invArmed = true;
}

struct MoveStats { int moved = 0, quest = 0, keyring = 0, borrowed = 0, failed = 0, movable = 0; bool money = false; };

// Pass 1 (and the only pass when `ginv` is null): which of the player's items
// would go into a grave. Everything except quest items (the runtime flag 0x2
// OR the table's IsQuestItem marker, both checked), the keyring (it carries
// every key), and items the player merely borrows.
MoveStats move_everything(void* pinv, void* ginv) {
    MoveStats st{};
    void* im = item_manager();
    void* b = nullptr; void* e = nullptr;
    if (!im || !rd(pinv, kInvPresentBegin, &b) || !rd(pinv, kInvPresentEnd, &e) || !b || e < b) { st.failed = -1; return st; }
    size_t n = (static_cast<char*>(e) - static_cast<char*>(b)) / 8;
    if (n > kMaxItems) n = kMaxItems;
    // WUID snapshot first: the vectors change under every move.
    std::vector<uint64_t> wuids;
    wuids.reserve(n);
    for (size_t i = 0; i < n; ++i) {
        void* item = nullptr; uint64_t w = 0;
        if (rd(b, i * 8, &item) && is_a(item, g_vftItem) && rd64(item, kItemWuid, &w) && w) wuids.push_back(w);
    }
    for (uint64_t w : wuids) {
        void* item = nullptr;
        if (!vcall(im, kImGetItem, &item, w) || !is_a(item, g_vftItem)) { ++st.failed; continue; }
        uint64_t flags = 0;
        vcall(item, kItemGetFlags, &flags);
        if (flags & kItemFlagQuest) { ++st.quest; continue; }
        void* cls = nullptr;
        if (vcall(item, kItemGetClass, &cls) && cls) {
            bool playerItem = false;
            if (vcall(cls, kClassIsCategory, &playerItem, kCatPlayerItem) && playerItem) {
                void* pd = nullptr; uint8_t q = 0;
                if (vcall(cls, kClassPlayerData, &pd, false) && pd && rd8(pd, kPlayerDataQuest, &q) && q) { ++st.quest; continue; }
            }
        }
        bool keyring = false;
        if (vcall(item, kItemIsCategory, &keyring, kCatKeyring) && keyring) { ++st.keyring; continue; }
        void* holder = nullptr; void* borrower = nullptr;
        if (!rd(item, kItemHolder, &holder) || holder != pinv || !rd(item, kItemBorrower, &borrower) || borrower) {
            ++st.borrowed;
            continue;
        }
        bool money = false;
        vcall(item, kItemIsCategory, &money, kCatMoney);
        ++st.movable;
        if (!ginv) { if (money) st.money = true; continue; }   // counting pass
        vcall_void(item, kItemDespawn);
        void* moved = nullptr;
        if (vcall(ginv, kInvTakeItem, &moved, item, 0u, 0u) && moved) {
            ++st.moved;
            if (money) st.money = true;
        } else {
            ++st.failed;
        }
    }
    return st;
}

// ---------------------------------------------------------------------------
// World clock (RPGModule C_Calendar, world ms at +0x68)
// ---------------------------------------------------------------------------
constexpr size_t kGiCalendar = 0x1B0;
constexpr size_t kCalWorldMs = 0x68;
bool         g_clockArmed = false;
void* const* g_vftCalendar = nullptr;

void resolve_clock() {
    HMODULE rpg = GetModuleHandleA("RPGModule.dll");
    HMODULE shared = GetModuleHandleA("Shared.dll");
    if (!rpg || !shared) return;
    g_vftCalendar = anchor::find_vftable(rpg, ".?AVC_Calendar@rpgmodule@wh@@", 0);
    void* setCal = GetProcAddress(shared, "?SetCalendar@C_GameInterface@shared@wh@@QEAAXPEAVC_Calendar@rpgmodule@3@@Z");
    static const uint8_t kStore1B0[] = {0x48, 0x89, 0xBB, 0xB0, 0x01, 0x00, 0x00};   // mov [rbx+0x1B0],rdi
    static const uint8_t kLoad68[]  = {0x48, 0x8B, 0x73, 0x68};                      // mov rsi,[rbx+0x68]
    static const uint8_t kStore68[] = {0x48, 0x89, 0x7B, 0x68};                      // mov [rbx+0x68],rdi
    const bool setOk = setCal && anchor::function_has_bytes(shared, setCal, kStore1B0, sizeof(kStore1B0));
    const void* setWorldTime = g_vftCalendar ? g_vftCalendar[0x58 / 8] : nullptr;
    const char* swName = anchor::find_cstring(rpg, "wh::rpgmodule::C_Calendar::SetWorldTime");
    const bool swOk = setWorldTime && swName && anchor::function_refs(rpg, setWorldTime, swName) &&
                      anchor::function_has_bytes(rpg, setWorldTime, kLoad68, sizeof(kLoad68)) &&
                      anchor::function_has_bytes(rpg, setWorldTime, kStore68, sizeof(kStore68));
    double t = 0;
    g_clockArmed = g_vftCalendar && setOk && swOk;
    const bool readOk = g_clockArmed && world_time(&t);
    logf("ACTIONS: clock %s (C_Calendar RTTI; SetCalendar writes gi+0x1B0: %s; SetWorldTime owns +0x68: %s) now=%.0f s",
         (g_clockArmed && readOk) ? "armed" : "NOT armed", setOk ? "yes" : "NO", swOk ? "yes" : "NO", readOk ? t : -1.0);
    g_clockArmed = g_clockArmed && readOk;
}

bool world_ms(int64_t* out) {
    void* gi = engine::game_iface(); void* cal = nullptr; uint64_t ms = 0;
    if (!gi || !rd(gi, kGiCalendar, &cal) || !is_a(cal, g_vftCalendar) || !rd64(cal, kCalWorldMs, &ms)) return false;
    *out = static_cast<int64_t>(ms);
    return true;
}

// ---------------------------------------------------------------------------
// Map marker (GUIModule C_UIMap entity marks, icon 0x2B "Grave"). Not saved by
// the game: re-added after every load by the grave rescan.
// ---------------------------------------------------------------------------
constexpr size_t kGuiElemsBegin = 0x40;
constexpr size_t kGuiElemsEnd   = 0x48;
constexpr size_t kApseGetMap    = 0x50;
constexpr size_t kMapCreate     = 0x50;
constexpr size_t kMapAdd        = 0x58;
constexpr size_t kMapRemove     = 0x60;
constexpr size_t kGiXGen        = 0x168;
constexpr size_t kXGenGuidSvc   = 0x88;
constexpr size_t kSvcGuidToWuid = 0x08;
constexpr size_t kAimgrByWuid   = 0x20;
// C_UIMap mark types are RPGModule MapMarkTypes.h's POI enum (GUIModule's own
// type->name switch at 0x24200, code-verified): 0 Checkpoint (the player's
// single waypoint), 1-3 Main/Side/Micro quests, 0x2B Grave, 0x2D ConcCross,
// 0x30 GeneralPoi, ... The map draws a mark only when its category byte at
// map+0x648 is set (0x55D10); the type in use is g_markType.
constexpr int    kMarkGrave     = 0x2B;
constexpr int    kMarkSource    = 2;

struct SharedPtr { void* p; void* ctrl; };

bool          g_markArmed = false;
void* const*  g_vftApse = nullptr;
void* const*  g_vftMap = nullptr;
void*         g_aiObjectManager = nullptr;
void*         g_aiCastLinkable = nullptr;
void*         g_aiCastIntelligent = nullptr;   // WO-127: C_AIObject* -> C_IntelligentObject* (null when not one)

void* g_apseGetter = nullptr;
int   g_markType = kMarkGrave;   // lifted from C_ShowMapMarker's execute: "mov rcx,[rax+0xF0]; call <getter>"

void* ui_map() {
    void* gi = engine::game_iface(); void* gui = nullptr;
    if (!gi || !rd(gi, kGiGui, &gui) || !is_a(gui, g_vftGui)) return nullptr;
    // The game's own route first -- exactly what the quest map-marker node does.
    void* apse = nullptr; void* map = nullptr;
    if (g_apseGetter && fcall(g_apseGetter, &apse, gui) && is_a(apse, g_vftApse) &&
        vcall(apse, kApseGetMap, &map) && is_a(map, g_vftMap))
        return map;
    void* b = nullptr; void* e = nullptr;
    if (!rd(gui, kGuiElemsBegin, &b) || !rd(gui, kGuiElemsEnd, &e) || !b || e < b) return nullptr;
    const size_t n = (static_cast<char*>(e) - static_cast<char*>(b)) / 16;
    for (size_t i = 0; i < n && i < 512; ++i) {
        void* el = nullptr;
        if (!rd(b, i * 16, &el) || !is_a(el, g_vftApse)) continue;
        void* map = nullptr;
        if (vcall(el, kApseGetMap, &map) && is_a(map, g_vftMap)) return map;
    }
    return nullptr;
}

uint64_t wuid_of_entity(void* ent) {
    void* gi = engine::game_iface(); void* xgen = nullptr; void* svc = nullptr; void* wp = nullptr;
    const uint64_t guid = engine::entity_guid(ent);
    uint64_t w = 0;
    if (!gi || !guid || !rd(gi, kGiXGen, &xgen) || !xgen || !vcall(xgen, kXGenGuidSvc, &svc) || !svc) return 0;
    if (!vcall(svc, kSvcGuidToWuid, &wp, guid) || !wp || !rd64(wp, 0, &w)) return 0;
    return w;
}

void* linkable_of(void* ent, uint64_t* wuidOut) {
    const uint64_t w = wuid_of_entity(ent);
    if (wuidOut) *wuidOut = w;
    void* mgr = nullptr; void* ai = nullptr; void* lo = nullptr;
    if (!w || !fcall(g_aiObjectManager, &mgr) || !mgr) return nullptr;
    if (!vcall(mgr, kAimgrByWuid, &ai, static_cast<const uint64_t*>(&w)) || !ai) return nullptr;
    if (!fcall(g_aiCastLinkable, &lo, ai)) return nullptr;
    return lo;
}

bool sp_addref(const SharedPtr& sp) { long after = 0; return sp.ctrl && ilock_add(static_cast<char*>(sp.ctrl) + 8, 1, &after); }
void sp_release(SharedPtr& sp) {
    if (!sp.ctrl) return;
    long uses = 0;
    if (ilock_add(static_cast<char*>(sp.ctrl) + 8, -1, &uses) && uses == 0) {
        vcall_void(sp.ctrl, 0x00);   // _Destroy
        long weaks = 0;
        if (ilock_add(static_cast<char*>(sp.ctrl) + 0xC, -1, &weaks) && weaks == 0) vcall_void(sp.ctrl, 0x08);   // _Delete_this
    }
    sp = SharedPtr{};
}

bool mark_add(void* ent, SharedPtr* out) {
    if (!g_markArmed) return false;
    void* map = ui_map();
    if (!map) { logf("MP-GRAVE marker: the C_UIMap was not found (UI not built yet?)"); return false; }
    uint64_t w = 0;
    void* lo = linkable_of(ent, &w);
    if (!lo) {
        logf("MP-GRAVE marker: no AI linkable object for entity wuid=0x%016llX (this entity class gets none) -- no marker",
             static_cast<unsigned long long>(w));
        return false;
    }
    SharedPtr sp{};
    void* ret = nullptr;
    if (!vcall(map, kMapCreate, &ret, &sp, g_markType, lo, kMarkSource) || !sp.p || !sp.ctrl) {
        logf("MP-GRAVE marker: C_UIMap create refused");
        return false;
    }
    SharedPtr arg = sp;
    if (!sp_addref(arg) || !vcall_void(map, kMapAdd, &arg)) {
        logf("MP-GRAVE marker: C_UIMap add FAULTED");
        sp_release(sp);
        return false;
    }
    *out = sp;
    return true;
}

// C_UIMap slot 0x60 (GUIModule 0x5A870, code-verified): decrements the mark's
// add count (+0x18) or erases its UI element (keyed by mark id, +0x5E8) and
// its vector entry (+0x5D0) -- it never reads the mark's linkable, so it is
// safe on a mark whose entity is already gone. Leaving such a mark in the map
// is NOT: the mark holds a RAW C_LinkableObject* (+0x10, slot 0x50 at 0x5A550)
// and the map screen reads it (observed: the full map crashed the game after
// two reloads had destroyed three marked entities). The map lives inside the
// APSE UI object and only its destructor (0x4C9E0) frees the vector, so a
// same-level load does not clear marks.
// How many marks the map holds (its vector at +0x5D0, 16-byte shared_ptrs);
// -1 when the map is not found. A read, for the logs.
constexpr size_t kMapMarksBegin = 0x5D0;
constexpr size_t kMapMarksEnd   = 0x5D8;
int map_mark_count() {
    void* map = g_markArmed ? ui_map() : nullptr;
    void* b = nullptr; void* e = nullptr;
    if (!map || !rd(map, kMapMarksBegin, &b) || !rd(map, kMapMarksEnd, &e) || e < b) return -1;
    return static_cast<int>((static_cast<char*>(e) - static_cast<char*>(b)) / 16);
}

void mark_remove(SharedPtr* sp) {
    if (!sp || !sp->ctrl) return;
    void* map = ui_map();
    if (map) {
        SharedPtr arg = *sp;
        if (sp_addref(arg)) vcall_void(map, kMapRemove, &arg);
    }
    sp_release(*sp);
}

void resolve_marker() {
    HMODULE gm = GetModuleHandleA("GUIModule.dll");
    HMODULE xg = GetModuleHandleA("XGenAIModule.dll");
    if (!gm || !xg || !g_vftGui) { logf("ACTIONS: marker NOT armed -- GUIModule/XGenAIModule/C_GUIModule missing"); return; }
    g_vftApse = anchor::find_vftable(gm, ".?AVC_UIApse@guimodule@wh@@", 0);
    g_vftMap = anchor::find_vftable(gm, ".?AVC_UIMap@guimodule@wh@@", 0);
    // C_ShowMapMarker's execute (found by its "no marker object on input"
    // string) gets the map owner with "mov rcx,[rax+0xF0]; call <getter>".
    if (const uint8_t* smm = anchor::function_by_string(gm, "no marker object on input")) {
        static const uint8_t kMovRcxGui[] = {0x48, 0x8B, 0x88, 0xF0, 0x00, 0x00, 0x00};
        static const uint8_t kCall[] = {0xE8};
        if (const uint8_t* m = anchor::function_find_sequence(gm, smm, kMovRcxGui, sizeof(kMovRcxGui), kCall, 1, 1))
            g_apseGetter = const_cast<void*>(anchor::rip_target(m + sizeof(kMovRcxGui), 1, 5));
    }
    const auto ex = module_exports(xg);
    g_aiObjectManager = find_export(ex, "?AIObjectManager@C_AISingletons@xgenaimodule@wh@@");
    g_aiCastLinkable = find_export(ex, "??$ai_cast_impl@PEAVC_LinkableObject@xgenaimodule@wh@@PEAVC_AIObject@23@@ai_cast_private@xgenaimodule@wh@@");
    g_aiCastIntelligent = find_export(ex, "??$ai_cast_impl@PEAVC_IntelligentObject@xgenaimodule@wh@@PEAVC_AIObject@23@@ai_cast_private@xgenaimodule@wh@@");
    logf("MP-LEASH brain read %s (ai_cast<C_IntelligentObject> export)", g_aiCastIntelligent && g_aiObjectManager ? "armed" : "MISSING");
    g_markArmed = g_vftApse && g_vftMap && g_aiObjectManager && g_aiCastLinkable;
    logf("ACTIONS: marker %s (C_UIApse/C_UIMap RTTI %s, XGenAI AIObjectManager/ai_cast exports %s; map now %s)",
         g_markArmed ? "armed" : "NOT armed", (g_vftApse && g_vftMap) ? "ok" : "MISSING",
         (g_aiObjectManager && g_aiCastLinkable) ? "ok" : "MISSING", g_markArmed && ui_map() ? "found" : "not found yet");
}

// ---------------------------------------------------------------------------
// Graves
// ---------------------------------------------------------------------------
constexpr const char* kGraveClass  = "StashCorpse";
constexpr const char* kGravePrefix = "kcdmp_grave_";
// The gravestone: a stone conciliation cross from the world's own roadside
// crosses (IPL_Objects structures/theological/conciliation_crosses/), authored
// upright with its pivot at the base and shipped with its own material. Chosen
// live by the maintainer out of 21 textured candidates. Rejected on the way
// (observed): task_specific_props/religious/cross_makeshift_a.cgf, a hand-held
// prop that lay on its side; graves/grave_makeshift_a_wb.cgf, a whitebox
// blockout whose material is whitebox.mtl. Slot 1: the StashCorpse keeps slot 0
// for its invisible loot volume.
constexpr const char* kGraveModel  = "Objects/manmade/structures/theological/conciliation_crosses/conciliation_cross_d.cgf";
char g_graveModel[160] = "Objects/manmade/structures/theological/conciliation_crosses/conciliation_cross_d.cgf";
// A peer's gravestone needs a map mark, which needs a WUID and an AI linkable
// object. Observed (classprobe, runtime NO_SAVE spawns): TagPoint, SmartObject,
// AnimObject, GeomEntity, RigidBodyEx and BasicEntity get neither;
// SmartObjectHolder and StashCorpse get both. StashCorpse is a two-way stash
// (a peer could store items in a NO_SAVE entity and lose them), so
// SmartObjectHolder: no player actions, no physics, the "Default" smart-entity
// template and no helpers. BasicEntity would also load a default pyramid and
// physicalize it as a pushable rigid body. Slot 0 gets the gravestone.
constexpr const char* kMirrorClass = "SmartObjectHolder";
constexpr const char* kMirrorPrefix = "kcdmp_mirror_";
constexpr int64_t     kExpiryMs    = 3LL * 86400000LL;   // 3 in-game days
constexpr float       kGraveSinkM  = 0.20f;              // below the navmesh height (see make_grave)
constexpr size_t      kMaxGraves   = 64;

struct Grave {
    uint64_t  id = 0;
    uint32_t  eid = 0;
    uint32_t  markEid = 0;   // the entity instance the map mark was made on
    float     x = 0, y = 0, z = 0;
    int64_t   createdMs = 0;
    SharedPtr mark{};
};
struct Mirror {
    uint8_t   owner = 0;
    uint64_t  id = 0;
    uint32_t  eid = 0;
    SharedPtr mark{};
};

bool                g_graveArmed = false;
std::vector<Grave>  g_graves;
std::vector<Mirror> g_mirrors;
bool                g_scanned = false;
uint64_t            g_idCounter = 0;

bool parse_grave_name(const char* name, uint64_t* id, int64_t* ms) {
    unsigned long long a = 0; long long b = 0;
    if (!name || std::strncmp(name, kGravePrefix, std::strlen(kGravePrefix)) != 0) return false;
    if (std::sscanf(name + std::strlen(kGravePrefix), "%16llx_%lld", &a, &b) != 2) return false;
    *id = a; *ms = b;
    return true;
}

struct ScanCtx { int found = 0; };
bool scan_visit(void* e, void* vctx) {
    ScanCtx* ctx = static_cast<ScanCtx*>(vctx);
    char name[96]{};
    const char* n = engine::entity_name(e);
    if (!n || !copy_str(n, name, sizeof(name))) return false;
    uint64_t id = 0; int64_t ms = 0;
    if (parse_grave_name(name, &id, &ms)) {
        for (const Grave& g : g_graves) if (g.id == id) return false;
        if (g_graves.size() >= kMaxGraves) return false;
        Grave g{};
        g.id = id; g.eid = engine::entity_id(e); g.createdMs = ms;
        float p[3]{};
        if (engine::entity_world_pos(e, p)) { g.x = p[0]; g.y = p[1]; g.z = p[2]; }
        // A load drops the model's render slot? Re-apply it; loading the same
        // geometry into the same slot is idempotent.
        engine::entity_load_geometry(e, 1, g_graveModel, 0);
        if (mark_add(e, &g.mark)) g.markEid = g.eid;
        g_graves.push_back(g);
        ++ctx->found;
    }
    return false;
}

void rescan() {
    // Out of the map first: the entities under these marks may be gone.
    for (Grave& g : g_graves) mark_remove(&g.mark);
    g_graves.clear();
    ScanCtx ctx{};
    const int n = engine::for_each_entity(&scan_visit, &ctx);
    g_scanned = true;
    logf("MP-GRAVE rescan: %d entities walked, %d graves of this player found", n, ctx.found);
    for (const Grave& g : g_graves)
        logf("MP-GRAVE   grave id=0x%016llX entity=%u at (%.1f, %.1f, %.1f) created_world_s=%lld marker=%s",
             static_cast<unsigned long long>(g.id), g.eid, g.x, g.y, g.z,
             static_cast<long long>(g.createdMs / 1000), g.mark.ctrl ? "yes" : "no");
}

void* grave_entity(Grave& g) {
    void* e = engine::entity_by_id(g.eid);
    char name[96]{};
    const char* n = e ? engine::entity_name(e) : nullptr;
    uint64_t id = 0; int64_t ms = 0;
    if (n && copy_str(n, name, sizeof(name)) && parse_grave_name(name, &id, &ms) && id == g.id) return e;
    e = engine::entity_by_guid(g.id);
    if (e) g.eid = engine::entity_id(e);
    return e;
}

void resolve_graves() {
    g_graveArmed = engine::ready() && g_invArmed;
    logf("ACTIONS: graves %s (StashCorpse spawn natively; items by C_ItemHolder::TakeItem; model %s; expiry 3 game days %s)",
         g_graveArmed ? "armed" : "NOT armed", kGraveModel, g_clockArmed ? "on" : "OFF (clock not armed)");
}

// ---------------------------------------------------------------------------
// Reconcile (RPGModule C_RPGUtils::ReconcileWithPublicFriends)
// ---------------------------------------------------------------------------
constexpr size_t kGiRpg       = 0x138;
constexpr size_t kRpgUtils    = 0xB0;
constexpr size_t kUtilsReconcile = 0x1E8;
bool         g_reconcileArmed = false;
void* const* g_vftRpgUtils = nullptr;

// Masked scan over .text for the RTTR global's own body (gi->[+0x138]->
// vtbl[0xB0]()->vtbl[0x1E8]()), proving the three offsets appear together.
bool text_has_masked(HMODULE mod, const uint8_t* pat, const char* mask, size_t n) {
    anchor::Range t{};
    if (!anchor::section(mod, ".text", &t) || t.size() < n) return false;
    for (const uint8_t* p = t.begin; p + n <= t.end; ++p) {
        size_t i = 0;
        for (; i < n; ++i) if (mask[i] == 'x' && p[i] != pat[i]) break;
        if (i == n) return true;
    }
    return false;
}

void resolve_reconcile() {
    HMODULE rpg = GetModuleHandleA("RPGModule.dll");
    if (!rpg) return;
    g_vftRpgUtils = anchor::find_vftable(rpg, ".?AVC_RPGUtils@rpgmodule@wh@@", 0);
    static const uint8_t kBody[] = {0xFF, 0x15, 0, 0, 0, 0, 0x48, 0x8B, 0x88, 0x38, 0x01, 0x00, 0x00, 0x48, 0x8B, 0x01,
                                    0xFF, 0x90, 0xB0, 0x00, 0x00, 0x00, 0x48, 0x8B, 0x08, 0x48, 0x8B, 0x91, 0xE8, 0x01, 0x00, 0x00};
    static const char kMask[] = "xx????xxxxxxxxxxxxxxxxxxxxxxxxxx";
    const bool body = text_has_masked(rpg, kBody, kMask, sizeof(kBody));
    const bool name = anchor::find_cstring(rpg, "wh::rpgmodule::ReconcileWithPublicFriends") != nullptr;
    g_reconcileArmed = g_vftRpgUtils && body && name;
    logf("ACTIONS: reconcile %s (C_RPGUtils RTTI %s; ReconcileWithPublicFriends body gi+0x138->0xB0->0x1E8 %s)",
         g_reconcileArmed ? "armed" : "NOT armed", g_vftRpgUtils ? "ok" : "MISSING", body ? "found" : "NOT found");
}

// ---------------------------------------------------------------------------
// Area labels (XGenAIModule IsPointInAreaWithLabel core): "settlement",
// "crimeDistrict". Used by the execution respawn ("outside that settlement").
// ---------------------------------------------------------------------------
bool  g_areaArmed = false;
void* g_areaCore = nullptr;
CryStr g_labelSettlement{}, g_labelDistrict{};

void resolve_area() {
    HMODULE xg = GetModuleHandleA("XGenAIModule.dll");
    if (!xg) return;
    const uint8_t* sb = anchor::function_by_string(xg, "wh::xgenaimodule::C_ScriptBindXGenAIModule::IsPointInAreaWithLabelWUID");
    static const uint8_t kCallSite[] = {0x48, 0x8B, 0xCE, 0xFF, 0x50, 0x50, 0x48, 0x8B, 0xD0, 0x4C, 0x8D, 0x45, 0xD0, 0xE8};
    static const uint8_t kAny[] = {0xE8};
    const uint8_t* m = sb ? anchor::function_find_sequence(xg, sb, kCallSite, sizeof(kCallSite) - 1, kAny, 1, 1) : nullptr;
    void* core = m ? const_cast<void*>(anchor::rip_target(m + sizeof(kCallSite) - 1, 1, 5)) : nullptr;
    static const uint8_t kPrologue[] = {0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x74, 0x24, 0x18, 0x57, 0x48, 0x81, 0xEC, 0xA0, 0x00, 0x00, 0x00};
    bool pro = false;
    if (core) {
        __try { pro = std::memcmp(core, kPrologue, sizeof(kPrologue)) == 0; }
        __except (EXCEPTION_EXECUTE_HANDLER) { pro = false; }
    }
    g_areaCore = pro ? core : nullptr;
    g_labelSettlement.set("settlement");
    g_labelDistrict.set("crimeDistrict");
    g_areaArmed = g_areaCore != nullptr;
    logf("ACTIONS: area-label test %s (IsPointInAreaWithLabelWUID scriptbind -> core, prologue %s)",
         g_areaArmed ? "armed" : "NOT armed", pro ? "matches" : "MISMATCH");
}

// ---------------------------------------------------------------------------
// Wound bleeding (RPGModule C_ScriptBindSoul::HealBleeding's own body):
//   runner = rpg->vtbl[0xD8](); runner->vtbl[8](); create(soul.wuid, &effect,
//   &wuid); runner->vtbl[8](); configure(0.5f, effect, wuid, part, &amount);
//   runner->vtbl[0](effect); effect->vtbl[0x20]()
// The two helpers are unexported; lifted from the scriptbind (found by its
// __FUNCTION__ string) at their exact call sites.
// ---------------------------------------------------------------------------
constexpr size_t kRpgEffectRunner = 0xD8;
bool  g_bleedArmed = false;
void* g_effectCreate = nullptr;
void* g_effectHealBleeding = nullptr;

void resolve_bleeding() {
    HMODULE rpg = GetModuleHandleA("RPGModule.dll");
    if (!rpg) return;
    const uint8_t* sb = anchor::function_by_string(rpg, "wh::rpgmodule::C_ScriptBindSoul::HealBleeding");
    static const uint8_t kRunner[] = {0xFF, 0x90, 0xD8, 0x00, 0x00, 0x00};                          // call [rax+0xD8]
    static const uint8_t kSiteA[] = {0x48, 0x8B, 0x4B, 0x40, 0x4C, 0x8D, 0x44, 0x24, 0x30,
                                     0x48, 0x8D, 0x54, 0x24, 0x38, 0x48, 0x89, 0x4C, 0x24, 0x30};    // rcx=soul.wuid; r8/rdx
    static const uint8_t kSiteB[] = {0x48, 0x8D, 0x44, 0x24, 0x30, 0x48, 0x89, 0x44, 0x24, 0x20};  // [rsp+0x20] = &amount
    static const uint8_t kCall[] = {0xE8};
    const uint8_t* a = sb ? anchor::function_find_sequence(rpg, sb, kSiteA, sizeof(kSiteA), kCall, 1, 1) : nullptr;
    const uint8_t* b = sb ? anchor::function_find_sequence(rpg, sb, kSiteB, sizeof(kSiteB), kCall, 1, 1) : nullptr;
    const bool runner = sb && anchor::function_has_bytes(rpg, sb, kRunner, sizeof(kRunner));
    g_effectCreate = a ? const_cast<void*>(anchor::rip_target(a + sizeof(kSiteA), 1, 5)) : nullptr;
    g_effectHealBleeding = b ? const_cast<void*>(anchor::rip_target(b + sizeof(kSiteB), 1, 5)) : nullptr;
    anchor::Range text{};
    const bool inText = anchor::section(rpg, ".text", &text) && g_effectCreate && g_effectHealBleeding &&
                        text.contains(g_effectCreate) && text.contains(g_effectHealBleeding);
    g_bleedArmed = runner && inText;
    logf("ACTIONS: bleeding cure %s (HealBleeding scriptbind body: runner %s, create %s, configure %s)",
         g_bleedArmed ? "armed" : "NOT armed", runner ? "ok" : "MISSING", a ? "ok" : "MISSING", b ? "ok" : "MISSING");
}

// ---------------------------------------------------------------------------
// HUD line (Framework C_TextEvent + C_GameEventLog::Log = Game.LogGameEvent)
// ---------------------------------------------------------------------------
bool  g_hudArmed = false;
void* g_textEventCtor = nullptr;
void* g_gameEventLog = nullptr;
constexpr size_t kGiEventLog = 0x58;

void resolve_hud() {
    HMODULE fw = GetModuleHandleA("Framework.dll");
    if (!fw) return;
    const auto ex = module_exports(fw);
    g_textEventCtor = find_export(ex, "??0C_TextEvent@framework@wh@@QEAA@IIW4E_GameEventLevel@12@AEBV?$CryStringT@D@@@Z");
    g_gameEventLog = find_export(ex, "?Log@C_GameEventLog@framework@wh@@QEAAXAEBVI_GameEvent@23@@Z");
    g_hudArmed = g_textEventCtor && g_gameEventLog;
}

} // namespace

// ===========================================================================
// public
// ===========================================================================

namespace { void resolve_stopfight(); }   // defined with the StopFight piece below

void resolve() {
    if (g_resolved) return;
    g_resolved = true;
    engine::resolve();
    resolve_fader();
    resolve_player();
    resolve_inventory();
    resolve_clock();
    resolve_marker();
    resolve_graves();
    resolve_reconcile();
    resolve_area();
    resolve_bleeding();
    resolve_stopfight();
    resolve_hud();
}

bool fade_available() { return g_fadeArmed; }

bool fade_out(float seconds) {
    if (!g_fadeArmed) return false;
    void* ctrl = fader_ctrl();
    if (!ctrl) return false;
    g_fader = BasicFader{ const_cast<void*>(static_cast<const void*>(g_vftBasicFader)), ctrl, g_faderName.ptr(), nullptr };
    alignas(16) uint8_t fn[0x40]{};   // an empty std::function<void()>: the callee destroys it, a no-op
    if (!vcall_void(ctrl, kFadeOut, static_cast<void*>(&g_fader), float_bits(seconds), static_cast<void*>(fn))) {
        logf("MP-RESPAWN fade-out FAULTED -- fader disarmed");
        g_fadeArmed = false;
        return false;
    }
    g_fadeActive = true;
    return true;
}

bool fade_is_black() {
    if (!g_fadeArmed || !g_fadeActive) return true;
    void* ctrl = fader_ctrl();
    bool out = true;
    if (!ctrl || !vcall(ctrl, kFadeIsOut, &out)) return true;
    return out;
}

bool fade_in(float seconds) {
    if (!g_fadeArmed || !g_fadeActive) return false;
    g_fadeActive = false;
    void* ctrl = fader_ctrl();
    if (!ctrl) return false;
    return vcall_void(ctrl, kFadeIn, static_cast<void*>(&g_fader), float_bits(seconds));
}

bool player_position(float out[3]) {
    localstate::LocalState s{};
    if (!localstate::read_local_state(&s)) return false;
    out[0] = s.x; out[1] = s.y; out[2] = s.z;
    return true;
}

bool teleport_available() { return g_teleArmed; }

bool teleport_to_spot(uint64_t linkId) {
    void* p = c_player();
    if (!g_teleArmed || !p) return false;
    // The hub's link id is the spot ENTITY's GUID (what ValidateAlcoTeleport-
    // Points resolves with GetEntityByGuid); ExecuteTeleportImpl looks the
    // place up by its XGenAI WUID. Observed: handing it the raw link id logs
    // "Place for player teleport wuid [<invalid>-...] not found." Convert the
    // way XGenAI's own GetMyWUID does (GUID -> WUID service).
    void* ent = engine::entity_by_guid(linkId);
    const uint64_t wuid = ent ? wuid_of_entity(ent) : 0;
    if (!wuid) {
        logf("MP-RESPAWN spot link 0x%016llX -> entity %p -> no WUID; the spot teleport cannot be asked",
             static_cast<unsigned long long>(linkId), ent);
        return false;
    }
    if (!vcall_void(p, kPlayerTeleportToWuid, wuid)) {
        logf("MP-RESPAWN ExecuteTeleportImpl FAULTED -- teleport disarmed");
        g_teleArmed = false;
        return false;
    }
    logf("MP-RESPAWN ExecuteTeleportImpl(wuid 0x%016llX) called for spot entity %u",
         static_cast<unsigned long long>(wuid), engine::entity_id(ent));
    return true;
}

// XGenAI's own actor teleport (C_Player slot 0xB88 -> the player's XGenAI
// object, slot 0x3A8 Teleport(const QuatT*, bool)): the call ExecuteTeleportImpl
// itself makes, including the physics reset -- a bare SetPos leaves the
// fall-damage state behind (observed: a 19 m "fall" after a 358 m SetPos).
constexpr size_t kPlayerXGenObject = 0xB88;
constexpr size_t kXGenTeleport     = 0x3A8;

bool teleport_xgen(float x, float y, float z) {
    void* p = c_player(); void* npc = nullptr;
    if (!p || !vcall(p, kPlayerXGenObject, &npc) || !npc) return false;
    void* fn = vslot(npc, kXGenTeleport);
    HMODULE xg = GetModuleHandleA("XGenAIModule.dll");
    anchor::Range text{};
    if (!fn || !xg || !anchor::section(xg, ".text", &text) || !text.contains(fn)) return false;
    struct QuatT { float q[4]; float t[3]; } tm = { {0, 0, 0, 1}, {x, y, z} };
    return vcall_void(npc, kXGenTeleport, static_cast<const void*>(&tm), false);
}

bool teleport_player(float x, float y, float z) {
    if (teleport_xgen(x, y, z)) { resnap_player(); return true; }
    // Last resort, the `goto` shape (Framework wh::framework::TeleportPlayer):
    // the player entity's SetPos with why 0, then the ground re-snap. The
    // player entity is the fixed id 0x7777 (reserved for the Player classes).
    void* ent = engine::entity_by_id(0x7777);
    if (!ent) return false;
    const float pos[3] = {x, y, z};
    if (!engine::entity_set_pos(ent, pos)) return false;
    resnap_player();
    return true;
}

bool heal_bleeding(void* soul) {
    if (!g_bleedArmed || !soul) return false;
    void* rpg = nullptr;
    void* gi = engine::game_iface();
    if (!gi || !rd(gi, kGiRpg, &rpg) || !rpg) return false;
    void* runner = nullptr;
    if (!vcall(rpg, kRpgEffectRunner, &runner) || !runner) return false;
    uint64_t wuid = 0;
    if (!rd64(soul, 0x40, &wuid) || !wuid) return false;
    int applied = 0;
    // The game's own full heal (Quests/Debug/Haste/rpg.xml): HealBleeding(1, i)
    // for body parts 1..6; amount 1.0 = 32768 in the effect's fixed point.
    for (int part = 1; part <= 6; ++part) {
        void* dummy = nullptr;
        vcall(runner, 0x08, &dummy);
        void* effect = nullptr;
        uint64_t wcopy = wuid;
        if (!fcall_void(g_effectCreate, wuid, static_cast<void**>(&effect), static_cast<uint64_t*>(&wcopy)) || !effect) continue;
        vcall(runner, 0x08, &dummy);
        int amount = 32768;
        const bool ok = fcall_void(g_effectHealBleeding, 0.5f, effect, wuid, part, static_cast<int*>(&amount)) &&
                        vcall_void(runner, 0x00, effect);
        vcall_void(effect, 0x20);
        if (ok) ++applied;
    }
    return applied == 6;
}

bool resnap_player() {
    void* p = c_player();
    if (!g_resnapArmed || !p) return false;
    return vcall_void(p, kActorResnap, false, true);
}

namespace {
// A game CVar held at a value for a while and then given back. The value from
// before the first hold is the one restored, so a second hold (a knockdown
// inside a knockdown) cannot make the held value permanent, and a release
// without a hold touches nothing.
struct HeldCVar {
    const char* name;
    int  prev;
    bool held;
};
HeldCVar g_targeting{"wh_rpg_ExcludePlayerFromTargeting", 0, false};
HeldCVar g_fallDamage{"wh_rpg_DisablePlayerFallDamage", 0, false};

bool hold_cvar(HeldCVar& h, bool on, int value) {
    if (on) {
        int prev = 0;
        if (!engine::cvar_set_int(h.name, value, &prev)) return false;
        if (!h.held) { h.prev = prev; h.held = true; }
        return true;
    }
    if (!h.held) return true;
    h.held = false;
    return engine::cvar_set_int(h.name, h.prev, nullptr);
}
} // namespace

bool exclude_from_targeting(bool on) { return hold_cvar(g_targeting, on, 1); }
bool suppress_fall_damage(bool on) { return hold_cvar(g_fallDamage, on, 1); }

bool world_time(double* out) {
    int64_t ms = 0;
    if (!world_ms(&ms)) return false;
    *out = static_cast<double>(ms) / 1000.0;
    return true;
}

bool graves_available() { return g_graveArmed; }

GraveReport make_grave(void* playerSoul, float x, float y, float z) {
    (void)playerSoul;
    GraveReport r{};
    if (!g_graveArmed) return r;
    if (!g_scanned) rescan();
    if (g_graves.size() >= kMaxGraves) { logf("MP-GRAVE %zu graves already -- no new grave", g_graves.size()); return r; }
    void* pinv = player_inventory();
    if (!pinv) { logf("MP-GRAVE the player inventory was not found -- no grave"); return r; }
    const MoveStats pre = move_everything(pinv, nullptr);
    if (pre.movable <= 0) {
        logf("MP-GRAVE nothing to bury (movable=0 quest_kept=%d keyring_kept=%d) -- no grave", pre.quest, pre.keyring);
        r.nothingToBury = true;
        return r;
    }

    int64_t now = 0;
    const bool haveTime = g_clockArmed && world_ms(&now);
    LARGE_INTEGER qpc{};
    QueryPerformanceCounter(&qpc);
    const uint64_t id = (static_cast<uint64_t>(qpc.QuadPart) * 0x9E3779B97F4A7C15ull) ^ (++g_idCounter << 48) ^ 0x4B43444D00000000ull;
    char name[96]{};
    _snprintf_s(name, sizeof(name), _TRUNCATE, "%s%016llX_%lld", kGravePrefix,
                static_cast<unsigned long long>(id), static_cast<long long>(haveTime ? now : 0));
    // On the ground: the position the downing was sampled at can be off it
    // (observed: 0.76 m up -- the grave floated). The navmesh is the ground a
    // player walks on; no navmesh there keeps the sampled position.
    {
        const float in[3] = {x, y, z};
        float g3[3]{};
        if (hangover::snap_to_ground(in, g3)) {
            // The navmesh can sit above the rendered terrain (observed: 91.01
            // vs a terrain height of 90.83 at the test grave, and the cross
            // read as floating): the stone is set into the ground a little.
            g3[2] -= kGraveSinkM;
            logf("MP-GRAVE snapped to the ground: (%.2f, %.2f, %.2f) -> (%.2f, %.2f, %.2f) (navmesh %.2f m, set in %.2f m)",
                 x, y, z, g3[0], g3[1], g3[2], g3[2] + kGraveSinkM, kGraveSinkM);
            x = g3[0]; y = g3[1]; z = g3[2];
        } else {
            logf("MP-GRAVE no navmesh under (%.1f, %.1f, %.1f) -- the grave keeps the sampled height", x, y, z);
        }
    }
    const float pos[3] = {x, y, z};
    void* e = engine::spawn(kGraveClass, name, pos, engine::kFlagCastShadow, id);
    if (!e) { logf("MP-GRAVE StashCorpse spawn FAILED at (%.1f, %.1f, %.1f)", x, y, z); return r; }
    const uint32_t eid = engine::entity_id(e);
    void* ginv = stash_inventory(eid);
    if (!ginv) {
        logf("MP-GRAVE the spawned StashCorpse %u has no stash inventory -- removing it, no grave", eid);
        engine::remove(eid);
        return r;
    }
    const int slot = engine::entity_load_geometry(e, 1, g_graveModel, 0);
    const MoveStats st = move_everything(pinv, ginv);

    Grave g{};
    g.id = id; g.eid = eid; g.x = x; g.y = y; g.z = z; g.createdMs = haveTime ? now : 0;
    const bool marked = mark_add(e, &g.mark);
    if (marked) g.markEid = eid;
    g_graves.push_back(g);

    r.ok = true; r.id = id; r.x = x; r.y = y; r.z = z;
    r.moved = st.moved; r.keptQuest = st.quest; r.failed = st.failed; r.money = st.money;
    r.model = slot >= 0; r.marker = marked;
    logf("MP-GRAVE made \"%s\" entity=%u guid=0x%016llX inventory items=%d (moved=%d quest_kept=%d keyring_kept=%d borrowed=%d refused=%d) player_left=%d",
         name, eid, static_cast<unsigned long long>(engine::entity_guid(e)), present_count(ginv), st.moved, st.quest,
         st.keyring, st.borrowed, st.failed, present_count(pinv));
    return r;
}

int graves_maintain(uint64_t* removed, int max) {
    if (!g_graveArmed) return 0;
    // WO-129: say once when the live objects the graves need first exist.
    static bool s_liveLogged = false;
    if (!s_liveLogged && player_inventory() && item_manager()) {
        s_liveLogged = true;
        logf("ACTIONS: graves live (player inventory and item manager found)");
    }
    if (!g_scanned) rescan();
    int64_t now = 0;
    const bool haveTime = g_clockArmed && world_ms(&now);
    int n = 0;
    for (size_t i = 0; i < g_graves.size();) {
        Grave& g = g_graves[i];
        void* e = grave_entity(g);
        const char* why = nullptr;
        void* ginv = e ? stash_inventory(g.eid) : nullptr;
        const int items = ginv ? present_count(ginv) : -1;
        if (!e) why = "entity gone";
        else if (items == 0) why = "looted empty";
        else if (haveTime && g.createdMs > 0 && now >= g.createdMs && now - g.createdMs >= kExpiryMs) why = "expired (3 game days)";
        if (!why) { ++i; continue; }
        mark_remove(&g.mark);
        if (e) {
            if (items > 0 && ginv) vcall_void(ginv, kInvRemoveAll);
            engine::remove(g.eid);
        }
        logf("MP-GRAVE removed id=0x%016llX entity=%u -- %s (items left %d)", static_cast<unsigned long long>(g.id), g.eid, why, items);
        if (n < max && removed) removed[n] = g.id;
        ++n;
        g_graves.erase(g_graves.begin() + static_cast<long long>(i));
    }
    return n;
}

namespace {
// `vanished` receives the ids of graves known before that the new world does
// not hold (an unsaved grave, a load of an older save): peers must drop their
// mirrors of those, or a stone and marker stay where nothing is.
int world_changed(const char* why, uint64_t* vanished, int max) {
    if (!g_graveArmed) return 0;
    logf("MP-GRAVE world changed (%s) -- rescanning graves and re-adding markers (map holds %d marks; ours %zu graves + %zu mirrors)",
         why, map_mark_count(), g_graves.size(), g_mirrors.size());
    std::vector<uint64_t> before;
    for (const Grave& g : g_graves) before.push_back(g.id);
    rescan();
    int n = 0;
    for (uint64_t id : before) {
        bool still = false;
        for (const Grave& g : g_graves) if (g.id == id) { still = true; break; }
        if (still) continue;
        logf("MP-GRAVE grave 0x%016llX is not in the new world (unsaved, or an older save) -- peers drop it",
             static_cast<unsigned long long>(id));
        if (vanished && n < max) vanished[n++] = id;
    }
    // Mirrors are NO_SAVE: a load removed them (observed). Their marks leave
    // the map now (see mark_remove); the owner's heartbeat re-announces
    // within 30 s.
    for (Mirror& m : g_mirrors) mark_remove(&m.mark);
    g_mirrors.clear();
    logf("MP-GRAVE after the rescan the map holds %d marks", map_mark_count());
    return n;
}

// Every sample: a marked entity that is gone for any other reason (the game
// deleting it, a level unload) takes its mark with it within 100 ms, before
// the map screen can read the dangling linkable. The grave record itself is
// left to graves_maintain (removal event, bookkeeping).
// The check is on the exact instance the mark was made on (id + name), not on
// "a grave with this GUID exists": after a load the save re-creates the grave
// as a NEW instance with the same GUID while the old mark still points at the
// destroyed one.
bool marked_grave_alive(const Grave& g) {
    void* e = engine::entity_by_id(g.markEid);
    const char* n = e ? engine::entity_name(e) : nullptr;
    char name[96]{};
    uint64_t id = 0; int64_t ms = 0;
    return n && copy_str(n, name, sizeof(name)) && parse_grave_name(name, &id, &ms) && id == g.id;
}

bool marked_mirror_alive(const Mirror& m) {
    void* e = engine::entity_by_id(m.eid);
    const char* n = e ? engine::entity_name(e) : nullptr;
    char name[96]{}, want[96]{};
    _snprintf_s(want, sizeof(want), _TRUNCATE, "%s%u_%016llX", kMirrorPrefix, static_cast<unsigned>(m.owner),
                static_cast<unsigned long long>(m.id));
    return n && copy_str(n, name, sizeof(name)) && std::strcmp(name, want) == 0;
}

void marks_guard() {
    for (Grave& g : g_graves) {
        if (!g.mark.ctrl || marked_grave_alive(g)) continue;
        mark_remove(&g.mark);
        logf("MP-GRAVE grave 0x%016llX entity gone -- its map mark removed", static_cast<unsigned long long>(g.id));
    }
    for (Mirror& m : g_mirrors) {
        if (!m.mark.ctrl || marked_mirror_alive(m)) continue;
        mark_remove(&m.mark);
        logf("MP-GRAVE mirror owner=%u 0x%016llX entity gone -- its map mark removed", static_cast<unsigned>(m.owner),
             static_cast<unsigned long long>(m.id));
    }
}

// A TagPoint: no model, no physics, no script behaviour -- nothing for the
// player or the world to touch. NO_SAVE, so every load purges it.
constexpr const char* kSentinelClass = "TagPoint";
constexpr const char* kSentinelName  = "kcdmp_world_sentinel";
uint32_t g_sentinelEid = 0;
bool     g_sentinelOff = false;

bool sentinel_alive() {
    if (!g_sentinelEid) return false;
    void* e = engine::entity_by_id(g_sentinelEid);
    const char* n = e ? engine::entity_name(e) : nullptr;
    char name[64]{};
    return n && copy_str(n, name, sizeof(name)) && std::strcmp(name, kSentinelName) == 0;
}
} // namespace

void on_world_changed() { world_changed("a load", nullptr, 0); }

namespace {
// The sentinel half of world_check: true when the world was replaced.
bool sentinel_check(uint64_t* vanished, int max, int* nVanished) {
    if (g_sentinelOff || sentinel_alive()) return false;
    const bool first = (g_sentinelEid == 0);
    float pos[3]{};
    if (!player_position(pos)) return false;       // no player yet (menu, loading)
    pos[2] -= 50.0f;
    void* e = engine::spawn(kSentinelClass, kSentinelName, pos, engine::kFlagNoSave, 0);
    g_sentinelEid = e ? engine::entity_id(e) : 0;
    if (!e || !sentinel_alive()) {
        // Never respawn in a loop: one failure turns the sentinel off.
        if (e) engine::remove(g_sentinelEid);
        g_sentinelEid = 0;
        g_sentinelOff = true;
        logf("MP-GRAVE world sentinel %s -- OFF; loads outside a session will not re-find graves",
             e ? "spawned but not found again by id+name" : "spawn FAILED");
        return false;
    }
    const int n = world_changed(first ? "first look after install" : "a load or level change: the NO_SAVE sentinel was purged",
                                vanished, max);
    if (nVanished) *nVanished = n;
    return !first;
}
} // namespace

bool world_check(uint64_t* vanished, int max, int* nVanished) {
    if (nVanished) *nVanished = 0;
    if (!engine::ready()) return false;
    const bool changed = sentinel_check(vanished, max, nVanished);
    marks_guard();
    return changed;
}

void map_dump() {
    void* map = g_markArmed ? ui_map() : nullptr;
    if (!map) { logf("MP-MAPDUMP no map"); return; }
    char on[512]{};
    size_t len = 0;
    int enabled = 0;
    for (int i = 0; i <= 0x60; ++i) {
        uint8_t b = 0;
        if (!rd8(map, 0x648 + static_cast<size_t>(i), &b)) break;
        if (!b) continue;
        ++enabled;
        len += static_cast<size_t>(_snprintf_s(on + len, sizeof(on) - len, _TRUNCATE, "%s0x%X", enabled > 1 ? "," : "", i));
        if (len >= sizeof(on) - 8) break;
    }
    logf("MP-MAPDUMP categories enabled (%d): %s -- our mark type 0x%X is %s", enabled, on, static_cast<unsigned>(g_markType),
         [&]() { uint8_t b = 0; return rd8(map, 0x648 + static_cast<size_t>(g_markType), &b) && b ? "ENABLED" : "disabled"; }());
    void* b = nullptr; void* e = nullptr;
    if (!rd(map, kMapMarksBegin, &b) || !rd(map, kMapMarksEnd, &e) || !b || e < b) return;
    const size_t n = (static_cast<char*>(e) - static_cast<char*>(b)) / 16;
    for (size_t i = 0; i < n && i < 64; ++i) {
        void* mark = nullptr;
        if (!rd(b, i * 16, &mark) || !mark) continue;
        uint64_t idType = 0, srcCnt = 0, link = 0, cnt = 0;
        rd64(mark, 0x00, &idType); rd64(mark, 0x08, &srcCnt); rd64(mark, 0x10, &link); rd64(mark, 0x18, &cnt);
        bool ours = false;
        for (const Grave& g : g_graves) if (g.mark.p == mark) ours = true;
        for (const Mirror& m : g_mirrors) if (m.mark.p == mark) ours = true;
        logf("MP-MAPDUMP mark[%zu] id=%u type=0x%X source=%u linkable=%p addcount=%u%s", i,
             static_cast<unsigned>(idType & 0xFFFFFFFF), static_cast<unsigned>(idType >> 32),
             static_cast<unsigned>(srcCnt & 0xFFFFFFFF), reinterpret_cast<void*>(link),
             static_cast<unsigned>(cnt & 0xFFFFFFFF), ours ? "  <- OURS" : "");
    }
}

void set_grave_model(const char* path) {
    if (!path || !*path) return;
    strncpy_s(g_graveModel, path, _TRUNCATE);
    int ok = 0, bad = 0;
    for (Grave& g : g_graves) {
        void* e = grave_entity(g);
        if (e && engine::entity_load_geometry(e, 1, g_graveModel, 0) >= 0) ++ok; else ++bad;
    }
    for (Mirror& m : g_mirrors) {
        void* e = engine::entity_by_id(m.eid);
        if (e && engine::entity_load_geometry(e, 0, g_graveModel, 0) >= 0) ++ok; else ++bad;
    }
    logf("MP-GRAVE model now \"%s\": %d re-loaded, %d failed", g_graveModel, ok, bad);
}

void set_mark_type(int type) {
    g_markType = type;
    int n = 0;
    for (Grave& g : g_graves) {
        mark_remove(&g.mark);
        void* e = grave_entity(g);
        if (e && mark_add(e, &g.mark)) { g.markEid = g.eid; ++n; }
    }
    for (Mirror& m : g_mirrors) {
        mark_remove(&m.mark);
        void* e = engine::entity_by_id(m.eid);
        if (e && mark_add(e, &m.mark)) ++n;
    }
    logf("MP-MAPDUMP mark type now 0x%X; %d marks re-made", static_cast<unsigned>(type), n);
}

void class_probe(const char* cls) {
    float pos[3]{};
    if (!engine::ready() || !player_position(pos)) { logf("MP-CLASSPROBE %s: no engine/player", cls); return; }
    pos[0] += 3.0f;
    void* e = engine::spawn(cls, "kcdmp_classprobe", pos, engine::kFlagNoSave, 0);
    if (!e) { logf("MP-CLASSPROBE %s: spawn FAILED (no such class?)", cls); return; }
    uint64_t w = 0;
    void* lo = linkable_of(e, &w);
    logf("MP-CLASSPROBE %s: entity=%u guid=0x%016llX wuid=0x%016llX linkable=%s", cls, engine::entity_id(e),
         static_cast<unsigned long long>(engine::entity_guid(e)), static_cast<unsigned long long>(w), lo ? "YES" : "no");
    engine::remove(engine::entity_id(e));
}

int graves_list(GraveInfo* out, int max) {
    if (!g_graveArmed) return 0;
    if (!g_scanned) rescan();
    int n = 0;
    for (const Grave& g : g_graves) {
        if (n >= max) break;
        out[n++] = GraveInfo{ g.id, g.x, g.y, g.z };
    }
    return n;
}

bool mirror_add(uint8_t owner, uint64_t id, float x, float y, float z) {
    if (!engine::ready()) return false;
    for (Mirror& m : g_mirrors)
        if (m.owner == owner && m.id == id && engine::entity_by_id(m.eid)) return true;   // already shown
    char name[96]{};
    _snprintf_s(name, sizeof(name), _TRUNCATE, "%s%u_%016llX", kMirrorPrefix, static_cast<unsigned>(owner),
                static_cast<unsigned long long>(id));
    const float pos[3] = {x, y, z};
    void* e = engine::spawn(kMirrorClass, name, pos, engine::kFlagNoSave | engine::kFlagCastShadow, 0);
    if (!e) { logf("MP-GRAVE mirror spawn FAILED (%s)", name); return false; }
    const int slot = engine::entity_load_geometry(e, 0, g_graveModel, 0);
    Mirror m{};
    m.owner = owner; m.id = id; m.eid = engine::entity_id(e);
    const bool marked = mark_add(e, &m.mark);
    g_mirrors.push_back(m);
    logf("MP-GRAVE mirror shown \"%s\" entity=%u model=%s marker=%s", name, m.eid, slot >= 0 ? "yes" : "NO", marked ? "yes" : "no");
    return true;
}

bool mirror_remove(uint8_t owner, uint64_t id) {
    for (size_t i = 0; i < g_mirrors.size(); ++i) {
        Mirror& m = g_mirrors[i];
        if (m.owner != owner || m.id != id) continue;
        mark_remove(&m.mark);
        engine::remove(m.eid);
        logf("MP-GRAVE mirror removed owner=%u id=0x%016llX", static_cast<unsigned>(owner), static_cast<unsigned long long>(id));
        g_mirrors.erase(g_mirrors.begin() + static_cast<long long>(i));
        return true;
    }
    return false;
}

int mirror_clear(uint8_t owner) {
    int n = 0;
    for (size_t i = 0; i < g_mirrors.size();) {
        Mirror& m = g_mirrors[i];
        if (owner != 0xFF && m.owner != owner) { ++i; continue; }
        mark_remove(&m.mark);
        engine::remove(m.eid);
        g_mirrors.erase(g_mirrors.begin() + static_cast<long long>(i));
        ++n;
    }
    if (n) logf("MP-GRAVE %d mirror(s) of owner %u cleared", n, static_cast<unsigned>(owner));
    return n;
}

// ---------------------------------------------------------------------------
// StopFight: wh::rpgmodule::StopFight(const Souls&), the concept function the
// quests use to end a fight -- "Sends StopFight message to all souls from all
// skirmishes that are identified by input souls." (RPGModule, code-verified:
// for each element it takes the skirmish manager, the soul id from the
// element's vtbl[0] -- C_Soul's returns this+0x40 -- and the soul's skirmish,
// then messages every soul of every skirmish found). Found through its RTTR
// registration, the one function referencing the name string: the name is
// stored with `mov [rbp-0x80],rax` and the next `lea rax,[rip+fn]` is the
// function. Accepted only when that function takes the skirmish's iteration
// lock (`lock inc dword [rdi+0xDC]`), as the disassembled one does.
// ---------------------------------------------------------------------------
namespace {
using StopFightFn = void (*)(const void* souls);
void* g_stopFight = nullptr;

bool call_stop_fight(void* fn, const void* souls) {
    __try { reinterpret_cast<StopFightFn>(fn)(souls); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

void resolve_stopfight() {
    HMODULE rpg = GetModuleHandleA("RPGModule.dll");
    const char* why = nullptr;
    const uint8_t* reg = rpg ? anchor::function_by_string(rpg, "wh::rpgmodule::StopFight") : nullptr;
    if (!reg) why = "the RTTR registration of wh::rpgmodule::StopFight was not found (or not unique)";
    const uint8_t* fn = nullptr;
    if (!why) {
        static const uint8_t kStoreName[] = {0x48, 0x89, 0x45, 0x80};   // mov [rbp-0x80], rax
        static const uint8_t kLeaRax[] = {0x48, 0x8D, 0x05};           // lea rax, [rip+disp32]
        const uint8_t* m = anchor::function_find_sequence(rpg, reg, kStoreName, sizeof(kStoreName), kLeaRax, sizeof(kLeaRax), 3);
        if (m) fn = static_cast<const uint8_t*>(anchor::rip_target(m + sizeof(kStoreName), 3, 7));
        if (!fn) why = "the function pointer next to the name was not found";
    }
    if (!why) {
        anchor::Range r{};
        static const uint8_t kSkirmishLock[] = {0xF0, 0xFF, 0x87, 0xDC, 0x00, 0x00, 0x00};   // lock inc dword [rdi+0xDC]
        if (!anchor::function_range(rpg, fn, &r) || r.begin != fn)
            why = "the lifted pointer is not the start of a function";
        else if (!anchor::function_has_bytes(rpg, fn, kSkirmishLock, sizeof(kSkirmishLock)))
            why = "the lifted function does not take a skirmish lock (not the disassembled StopFight)";
    }
    if (why) { logf("ACTIONS: stop-fight NOT armed -- %s", why); return; }
    g_stopFight = const_cast<uint8_t*>(fn);
    char d[96];
    anchor::describe(fn, d, sizeof(d));
    logf("ACTIONS: stop-fight armed (wh::rpgmodule::StopFight = %s, by its RTTR registration)", d);
}
} // namespace

bool stop_fight_available() { return g_stopFight != nullptr; }
const void* stop_fight_fn() { return g_stopFight; }

bool stop_fight(void* playerSoul) {
    if (!g_stopFight || !playerSoul) return false;
    // A Souls collection is read as {begin, end}: one element, the C_Soul
    // primary (whose vtbl[0] is the soul id the skirmish manager is keyed by).
    void* arr[1] = { playerSoul };
    void* vec[3] = { &arr[0], &arr[1], &arr[1] };
    return call_stop_fight(g_stopFight, vec);
}

bool reconcile_available() { return g_reconcileArmed; }

bool reconcile_with_public_friends(void* playerSoul) {
    (void)playerSoul;
    if (!g_reconcileArmed) return false;
    void* gi = engine::game_iface(); void* rpg = nullptr; void* utils = nullptr;
    if (!gi || !rd(gi, kGiRpg, &rpg) || !rpg || !vcall(rpg, kRpgUtils, &utils) || !is_a(utils, g_vftRpgUtils)) return false;
    return vcall_void(utils, kUtilsReconcile);
}

bool area_available() { return g_areaArmed; }

bool in_settlement(const float pos[3], bool* inside) {
    if (!g_areaArmed || !inside) return false;
    const char* s1 = g_labelSettlement.ptr();
    const char* s2 = g_labelDistrict.ptr();
    bool a = false, b = false;
    // bool core(void* unused, const Vec3* pos, const CryStringT<char>* label): the
    // label argument is the address of the string's char pointer.
    if (!fcall(g_areaCore, &a, static_cast<void*>(nullptr), pos, static_cast<const void*>(&s1))) return false;
    if (!fcall(g_areaCore, &b, static_cast<void*>(nullptr), pos, static_cast<const void*>(&s2))) return false;
    *inside = a || b;
    return true;
}

bool hud_message(const char* text) {
    if (!g_hudArmed || !text) return false;
    void* gi = engine::game_iface(); void* log = nullptr;
    if (!gi || !rd(gi, kGiEventLog, &log) || !log) return false;
    static CryStr s{};
    if (!s.set(text)) return false;
    const char* sp = s.ptr();
    alignas(16) uint8_t ev[0x40]{};
    void* ret = nullptr;
    if (!fcall(g_textEventCtor, &ret, static_cast<void*>(ev), 0x20u, 1u, 2, static_cast<const void*>(&sp))) return false;
    return fcall_void(g_gameEventLog, log, static_cast<const void*>(ev));
}

uint64_t entity_wuid(void* ent) { return ent ? wuid_of_entity(ent) : 0; }

// WO-127: the brain's suspension, as C_IntelligentObject::Suspend keeps it
// (WO-107 s3.2, code-verified): state enum at +0x128 (0 running, 1/2
// suspended), suspend-reason bitmask at +0x129 (one bit per requesting
// context; our wh_ai_PauseNPC is one of them). Reached through the game's own
// exported ai_cast, which answers null for anything that is not an
// intelligent object -- never a blind offset read.
bool brain_state(void* ent, uint64_t* wuidOut, int* state, int* mask) {
    *state = -1; *mask = -1;
    const uint64_t w = ent ? wuid_of_entity(ent) : 0;
    if (wuidOut) *wuidOut = w;
    void* mgr = nullptr; void* ai = nullptr; void* io = nullptr;
    if (!w || !g_aiCastIntelligent || !fcall(g_aiObjectManager, &mgr) || !mgr) return false;
    if (!vcall(mgr, kAimgrByWuid, &ai, static_cast<const uint64_t*>(&w)) || !ai) return false;
    if (!fcall(g_aiCastIntelligent, &io, ai) || !io) return false;
    uint8_t st = 0, mk = 0;
    if (!rd8(io, 0x128, &st) || !rd8(io, 0x129, &mk)) return false;
    *state = st; *mask = mk;
    return true;
}

} // namespace kcdmp::actions
