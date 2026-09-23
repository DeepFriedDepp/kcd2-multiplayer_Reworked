#include "buffs.h"
#include "anchors.h"
#include "log.h"
#include "rttr_abi.h"

#include <windows.h>
#include <cstdio>
#include <cstring>

namespace kcdmp::buffs {

namespace {

constexpr const char* kModule = "RPGModule.dll";
constexpr const char* kRttiRpg   = ".?AVC_RPGModule@rpgmodule@wh@@";
constexpr const char* kRttiMgr   = ".?AVC_BuffManager@rpgmodule@wh@@";
constexpr const char* kRttiSoul  = ".?AVC_Soul@rpgmodule@wh@@";
constexpr const char* kSbAddBuff = "wh::rpgmodule::C_ScriptBindSoul::AddBuff";
constexpr const char* kSbRemove  = "wh::rpgmodule::C_ScriptBindSoul::RemoveAllBuffsByGuid";
constexpr const char* kSbHasDbg  = "wh::rpgmodule::C_ScriptBindSoul::HasBuffDebug";
constexpr const char* kAddOwned  = "wh::rpgmodule::C_BuffManager::AddBuffOwned";

constexpr size_t kRpgGetBuffMgr   = 0xE0;
constexpr size_t kMgrAdd          = 0x00;
constexpr size_t kMgrAddOwned     = 0x10;   // slot 2, called by slot 0
constexpr size_t kMgrRemoveAll    = 0x28;
constexpr size_t kMgrFindDef      = 0x38;
constexpr size_t kSoulInstBegin   = 0x5B8;
constexpr size_t kSoulInstEnd     = 0x5C0;
constexpr size_t kInstDefGuid     = 0x58;
constexpr size_t kInstWuid        = 0x08;
constexpr size_t kMaxInstances    = 512;

const uint8_t kCallE0[]      = {0xFF, 0x90, 0xE0, 0x00, 0x00, 0x00};   // call [rax+0xE0]
const uint8_t kMovR10Rcx[]   = {0x4C, 0x8B, 0x11};                     // mov r10,[rcx]      (slot 0)
const uint8_t kMovR9Rcx28[]  = {0x4C, 0x8B, 0x49, 0x28};               // mov r9,[rcx+0x28]  (slot 5)
const uint8_t kLeaRbp5B8[]   = {0x48, 0x8D, 0x8D, 0xB8, 0x05, 0x00, 0x00};  // lea rcx,[rbp+0x5B8]
const uint8_t kMovRbp5C0[]   = {0x48, 0x8B, 0x85, 0xC0, 0x05, 0x00, 0x00};  // mov rax,[rbp+0x5C0]
const uint8_t kCall58[]      = {0xFF, 0x50, 0x58};                     // call [rax+0x58]

bool          g_ready = false;
bool          g_failed = false;
void* const*  g_vftRpg = nullptr;
void* const*  g_vftMgr = nullptr;
void* const*  g_vftSoul = nullptr;
void* const*  g_vftSoul8 = nullptr;   // the secondary base at +8, should a caller hold that

using AddFn     = void* (*)(void* mgr, void* soul, const void* guid, void* p4, const void* perkGuid);
using RemoveFn  = uint32_t (*)(void* mgr, void* soul, const void* guid);
using FindDefFn = void* (*)(void* mgr, const void* guid);
using PtrFn     = void* (*)(void* self);

bool rd(const void* base, size_t off, void** out) {
    __try { *out = *reinterpret_cast<void* const*>(static_cast<const char*>(base) + off); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
void* vslot(void* obj, size_t off) {
    void* vt = nullptr; void* fn = nullptr;
    if (!obj || !rd(obj, 0, &vt) || !vt || !rd(vt, off, &fn)) return nullptr;
    return fn;
}
bool call_ptr(void* fn, void* self, void** out) {
    __try { *out = reinterpret_cast<PtrFn>(fn)(self); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_add(void* fn, void* mgr, void* soul, const void* guid, const void* perk, void** out) {
    __try { *out = reinterpret_cast<AddFn>(fn)(mgr, soul, guid, nullptr, perk); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_remove(void* fn, void* mgr, void* soul, const void* guid, uint32_t* out) {
    __try { *out = reinterpret_cast<RemoveFn>(fn)(mgr, soul, guid); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_find(void* fn, void* mgr, const void* guid, void** out) {
    __try { *out = reinterpret_cast<FindDefFn>(fn)(mgr, guid); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool guid_eq(const void* a, const unsigned char b[16]) {
    __try { return a && std::memcmp(a, b, 16) == 0; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

void* manager_checked() {
    void* rpg = rttr::rpg_module();
    if (!rpg) return nullptr;
    void* vp = nullptr;
    if (!rd(rpg, 0, &vp) || vp != static_cast<const void*>(g_vftRpg)) return nullptr;
    void* fn = vslot(rpg, kRpgGetBuffMgr);
    void* mgr = nullptr;
    if (!fn || !call_ptr(fn, rpg, &mgr) || !mgr) return nullptr;
    if (!rd(mgr, 0, &vp) || vp != static_cast<const void*>(g_vftMgr)) return nullptr;
    return mgr;
}

} // namespace

bool parse_guid(const char* s, unsigned char out[16]) {
    unsigned int b[16]{};
    if (!s || std::sscanf(s, "%2x%2x%2x%2x-%2x%2x-%2x%2x-%2x%2x-%2x%2x%2x%2x%2x%2x",
                          &b[0], &b[1], &b[2], &b[3], &b[4], &b[5], &b[6], &b[7],
                          &b[8], &b[9], &b[10], &b[11], &b[12], &b[13], &b[14], &b[15]) != 16)
        return false;
    // Text is field order; memory is {u32 LE, u16 LE, u16 LE, 8 bytes} (the
    // engine's own parser, "%8x-%4hx-%4hx-%2hhx%2hhx-...", fills that struct).
    out[0] = (unsigned char)b[3]; out[1] = (unsigned char)b[2];
    out[2] = (unsigned char)b[1]; out[3] = (unsigned char)b[0];
    out[4] = (unsigned char)b[5]; out[5] = (unsigned char)b[4];
    out[6] = (unsigned char)b[7]; out[7] = (unsigned char)b[6];
    for (int i = 8; i < 16; ++i) out[i] = (unsigned char)b[i];
    return true;
}

bool ready() { return g_ready; }

bool resolve() {
    if (g_ready) return true;
    if (g_failed) return false;
    char d[256]{};
    HMODULE mod = GetModuleHandleA(kModule);
    if (!mod) return false;

    auto fail = [&](const char* why) {
        logf("BUFFS: ANCHOR FAILED -- %s; the death guard will NOT arm", why);
        g_failed = true;
        return false;
    };

    g_vftRpg  = anchor::find_vftable(mod, kRttiRpg, 0);
    g_vftMgr  = anchor::find_vftable(mod, kRttiMgr, 0);
    g_vftSoul = anchor::find_vftable(mod, kRttiSoul, 0);
    if (!g_vftRpg)  return fail("RTTI C_RPGModule vftable not unique");
    if (!g_vftMgr)  return fail("RTTI C_BuffManager vftable not unique");
    if (!g_vftSoul) return fail("RTTI C_Soul vftable not unique");
    g_vftSoul8 = anchor::find_vftable(mod, kRttiSoul, 8);   // optional

    const uint8_t* sbAdd = anchor::function_by_string(mod, kSbAddBuff);
    const uint8_t* sbRem = anchor::function_by_string(mod, kSbRemove);
    const uint8_t* sbHas = anchor::function_by_string(mod, kSbHasDbg);
    if (!sbAdd || !sbRem || !sbHas) return fail("a C_ScriptBindSoul buff scriptbind was not found by its name");
    if (!anchor::function_has_sequence(mod, sbAdd, kCallE0, sizeof(kCallE0), kMovR10Rcx, sizeof(kMovR10Rcx), 48))
        return fail("AddBuff scriptbind no longer calls rpg->vtbl[0xE0] then mgr slot 0");
    if (!anchor::function_has_sequence(mod, sbRem, kCallE0, sizeof(kCallE0), kMovR9Rcx28, sizeof(kMovR9Rcx28), 32))
        return fail("RemoveAllBuffsByGuid scriptbind no longer calls rpg->vtbl[0xE0] then mgr slot 0x28");
    if (!anchor::function_has_bytes(mod, sbHas, kCall58, sizeof(kCall58)))
        return fail("HasBuffDebug no longer reads the instance GUID through vtbl[0x58]");

    void* const add = g_vftMgr[kMgrAdd / 8];
    void* const owned = g_vftMgr[kMgrAddOwned / 8];
    const char* ownedName = anchor::find_cstring(mod, kAddOwned);
    if (!ownedName || !anchor::function_refs(mod, owned, ownedName))
        return fail("manager slot 2 is not C_BuffManager::AddBuffOwned");
    if (!anchor::function_calls(mod, add, owned))
        return fail("manager slot 0 does not call AddBuffOwned");
    if (!anchor::function_has_bytes(mod, add, kLeaRbp5B8, sizeof(kLeaRbp5B8)) ||
        !anchor::function_has_bytes(mod, add, kMovRbp5C0, sizeof(kMovRbp5C0)))
        return fail("AddBuff no longer pushes to soul+0x5B8/+0x5C0");

    anchor::describe(g_vftMgr, d, sizeof(d));
    logf("BUFFS: C_BuffManager vftable %s; AddBuff/RemoveAll/HasBuff/instance-list anchors all verified", d);
    g_ready = true;
    return true;
}

void* as_c_soul(void* soul) {
    if (!soul) return nullptr;
    void* vp = nullptr;
    if (!rd(soul, 0, &vp)) return nullptr;
    if (vp == static_cast<const void*>(g_vftSoul)) return soul;
    // A pointer to the +8 subobject names the same soul 8 bytes on.
    if (g_vftSoul8 && vp == static_cast<const void*>(g_vftSoul8)) return static_cast<char*>(soul) - 8;
    return nullptr;
}

bool add(void* soul, const unsigned char guid[16], uint64_t* instWuid) {
    soul = as_c_soul(soul);
    if (!g_ready || !soul) return false;
    void* mgr = manager_checked();
    if (!mgr) return false;
    static const unsigned char kNoPerk[16]{};
    void* inst = nullptr;
    if (!call_add(vslot(mgr, kMgrAdd), mgr, soul, guid, kNoPerk, &inst) || !inst) return false;
    if (instWuid) {
        void* w = nullptr;
        *instWuid = rd(inst, kInstWuid, &w) ? reinterpret_cast<uint64_t>(w) : 0;
    }
    return true;
}

int remove_all(void* soul, const unsigned char guid[16]) {
    soul = as_c_soul(soul);
    if (!g_ready || !soul) return -1;
    void* mgr = manager_checked();
    if (!mgr) return -1;
    uint32_t n = 0;
    if (!call_remove(vslot(mgr, kMgrRemoveAll), mgr, soul, guid, &n)) return -1;
    return static_cast<int>(n);
}

int has(void* soul, const unsigned char guid[16]) {
    soul = as_c_soul(soul);
    if (!g_ready || !soul) return -1;
    void* b = nullptr; void* e = nullptr;
    if (!rd(soul, kSoulInstBegin, &b) || !rd(soul, kSoulInstEnd, &e)) return -1;
    if (b == e) return 0;
    if (!b || !e || e < b) return -1;
    const size_t n = (static_cast<char*>(e) - static_cast<char*>(b)) / 8;
    if (n > kMaxInstances) return -1;
    for (size_t i = 0; i < n; ++i) {
        void* inst = nullptr;
        if (!rd(b, i * 8, &inst) || !inst) continue;
        void* fn = vslot(inst, kInstDefGuid);
        void* g = nullptr;
        if (!fn || !call_ptr(fn, inst, &g) || !g) continue;
        if (guid_eq(g, guid)) return 1;
    }
    return 0;
}

int definition_exists(const unsigned char guid[16]) {
    if (!g_ready) return -1;
    void* mgr = manager_checked();
    if (!mgr) return -1;
    void* def = nullptr;
    if (!call_find(vslot(mgr, kMgrFindDef), mgr, guid, &def)) return -1;
    return def ? 1 : 0;
}

} // namespace kcdmp::buffs
