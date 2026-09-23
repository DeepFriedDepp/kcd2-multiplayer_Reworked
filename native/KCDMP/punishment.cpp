#include "punishment.h"
#include "anchors.h"
#include "pe_exports.h"
#include "rttr_abi.h"
#include "log.h"

#include <windows.h>
#include <cstdint>
#include <cstring>

namespace kcdmp::punishment {

namespace {

constexpr const char* kNodePath = "Barbora.open_world.nextnextgenpunishment.disabledEvents";

// ConceptModule exports. FindNode and GetPort are non-virtual (QEBA): the
// exported address is the implementation. Trigger/Read are the EMPTY base
// virtuals -- comparands only, never called.
constexpr const char* kExpFindNode    = "?FindNode@C_ConceptManager@conceptmodule@wh@@";
constexpr const char* kExpGetPort     = "?GetPort@C_Node@conceptmodule@wh@@";
constexpr const char* kExpGetDir      = "?GetDirection@I_Port@conceptmodule@wh@@";
constexpr const char* kExpExecute     = "?Execute@C_Node@conceptmodule@wh@@";
constexpr const char* kExpBaseTrigger = "?Trigger@I_Port@conceptmodule@wh@@";
constexpr const char* kExpBaseRead    = "?Read@I_Port@conceptmodule@wh@@";
constexpr const char* kGetGameIface   = "?GetGameIface@wh@@YAPEBVC_GameInterface@shared@1@XZ";
// CrySystem: the policy function of an rttr::variant holding a bool.
constexpr const char* kBoolPolicy =
    "?invoke@?$variant_data_base_policy@_NU?$variant_data_policy_arithmetic@_N@";

constexpr const char* kRttiConceptModule  = ".?AVC_ConceptModule@conceptmodule@wh@@";
constexpr const char* kRttiConceptManager = ".?AVC_ConceptManager@conceptmodule@wh@@";

constexpr size_t kOffGiConceptModule = 0x128;   // C_GameInterface -> C_ConceptModule*
constexpr size_t kOffModuleManager   = 0x18;    // C_ConceptModule -> C_ConceptManager*
constexpr size_t kSlotTrigger        = 15;
constexpr size_t kSlotRead           = 16;
constexpr int    kDirIn              = 1;

using GetGameIfaceFn = const void* (*)();
using FindNodeFn     = void* (*)(void* self, void* retSmartPtr, const void* cryStrRef);
using GetPortFn      = void* (*)(void* self, void* retSmartPtr, const void* cryStrRef);
using GetDirFn       = int (*)(const void* self);
using TriggerFn      = void (*)(void* self);
using ReadFn         = void* (*)(void* self, rttr::Variant* ret);

struct Api {
    bool           ok = false;
    HMODULE        cm = nullptr;
    GetGameIfaceFn gameIface = nullptr;
    FindNodeFn     findNode = nullptr;
    GetPortFn      getPort = nullptr;
    GetDirFn       getDir = nullptr;
    const void*    execute = nullptr;
    const void*    baseTrigger = nullptr;
    const void*    baseRead = nullptr;
    const void*    boolPolicy = nullptr;
    void* const*   moduleVft = nullptr;
    void* const*   managerVft = nullptr;
};
Api  g_api;
bool g_resolved = false;

// --- SEH-isolated primitives (no destructible locals in a __try frame) -------
bool rd(const void* base, size_t off, void** out) {
    __try { *out = *reinterpret_cast<void* const*>(static_cast<const char*>(base) + off); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_gi(GetGameIfaceFn fn, const void** out) {
    __try { *out = fn(); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_lookup(FindNodeFn fn, void* self, const void* str, void** out) {
    void* sp = nullptr;
    __try { fn(self, &sp, str); *out = sp; return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_dir(GetDirFn fn, const void* port, int* out) {
    __try { *out = fn(port); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_trigger(TriggerFn fn, void* port) {
    __try { fn(port); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_read(ReadFn fn, void* port, rttr::Variant* v) {
    __try { fn(port, v); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// A CryStringT<char> the engine reads but can never free: header
// {refCount, length, capacity} at data-12 with a large POSITIVE refcount (a
// negative one makes the engine substitute "" -- WO-97). Static storage so a
// reference retained past the call stays valid.
struct CryStr {
    alignas(8) char storage[12 + 128]{};
    char* data = nullptr;
    bool init(const char* s) {
        const size_t n = strnlen(s, 127);
        if (!n) return false;
        const int32_t hdr[3] = {0x40000000, static_cast<int32_t>(n), static_cast<int32_t>(n)};
        std::memcpy(storage, hdr, sizeof(hdr));
        std::memcpy(storage + 12, s, n);
        storage[12 + n] = 0;
        data = storage + 12;
        return true;
    }
    const void* ref() const { return &data; }
};

// The C_ConceptManager, its module and itself checked by RTTI.
void* manager() {
    const void* gi = nullptr;
    void* cmod = nullptr;
    void* mgr = nullptr;
    void* vp = nullptr;
    if (!call_gi(g_api.gameIface, &gi) || !gi) return nullptr;
    if (!rd(gi, kOffGiConceptModule, &cmod) || !cmod) return nullptr;
    if (!rd(cmod, 0, &vp) || vp != static_cast<const void*>(g_api.moduleVft)) return nullptr;
    if (!rd(cmod, kOffModuleManager, &mgr) || !mgr) return nullptr;
    if (!rd(mgr, 0, &vp) || vp != static_cast<const void*>(g_api.managerVft)) return nullptr;
    return mgr;
}

// The node, then one of its ports. The returned smart pointers keep the +1
// reference they arrive with, as concept_read.cpp does: a node is owned by its
// module tree and outlives this, so one extra count is inert, whereas a wrong
// Release frees a live node. Bounded: this runs once per execution.
void* port_of(const char* portName) {
    void* mgr = manager();
    if (!mgr) return nullptr;
    static CryStr path;
    static CryStr name;
    if (!path.init(kNodePath) || !name.init(portName)) return nullptr;
    void* node = nullptr;
    if (!call_lookup(g_api.findNode, mgr, path.ref(), &node) || !node) return nullptr;
    void* port = nullptr;
    if (!call_lookup(reinterpret_cast<FindNodeFn>(g_api.getPort), node, name.ref(), &port)) return nullptr;
    return port;
}

bool read_state(bool* out) {
    void* port = port_of("State");
    void* fn = nullptr;
    void* vt = nullptr;
    if (!port || !rd(port, 0, &vt) || !vt || !rd(vt, kSlotRead * 8, &fn) || !fn) return false;
    if (fn == g_api.baseRead) return false;      // the empty base reads nothing
    rttr::Variant v{};
    if (!call_read(reinterpret_cast<ReadFn>(fn), port, &v)) return false;
    // A bool variant is stored inline: nothing to destroy, nothing leaked.
    if (v.policy != g_api.boolPolicy) return false;
    *out = v.data[0] != 0;
    return true;
}

// Fire an In port of the State node. The port class is accepted only when its
// slot 15 is a real trigger: not the empty base, and a function that calls the
// exported C_Node::Execute (ConceptModule 0xCC580 on this build: CanTrigger,
// then Execute(owner node, {this port}) -- code-verified).
bool fire(const char* portName) {
    void* port = port_of(portName);
    if (!port) { logf("MP-PUNISH %s: port not found", portName); return false; }
    int dir = -1;
    if (!call_dir(g_api.getDir, port, &dir) || dir != kDirIn) {
        logf("MP-PUNISH %s: direction %d is not In -- not fired", portName, dir);
        return false;
    }
    void* vt = nullptr;
    void* fn = nullptr;
    if (!rd(port, 0, &vt) || !vt || !rd(vt, kSlotTrigger * 8, &fn) || !fn) return false;
    if (fn == g_api.baseTrigger) {
        logf("MP-PUNISH %s: slot 15 is the empty base I_Port::Trigger -- not fired", portName);
        return false;
    }
    if (!anchor::function_calls(g_api.cm, fn, g_api.execute)) {
        char d[96];
        anchor::describe(fn, d, sizeof(d));
        logf("MP-PUNISH %s: slot 15 (%s) does not call C_Node::Execute -- unclassified, not fired", portName, d);
        return false;
    }
    return call_trigger(reinterpret_cast<TriggerFn>(fn), port);
}

} // namespace

bool resolve() {
    if (g_resolved) return g_api.ok;
    g_resolved = true;
    Api a;
    const char* why = nullptr;
    a.cm = GetModuleHandleA("ConceptModule.dll");
    HMODULE shared = GetModuleHandleA("Shared.dll");
    HMODULE crySys = GetModuleHandleA("CrySystem.dll");
    if (!a.cm || !shared || !crySys) why = "ConceptModule/Shared/CrySystem not loaded";
    if (!why) {
        const auto ex = module_exports(a.cm);
        a.findNode    = reinterpret_cast<FindNodeFn>(find_export(ex, kExpFindNode));
        a.getPort     = reinterpret_cast<GetPortFn>(find_export(ex, kExpGetPort));
        a.getDir      = reinterpret_cast<GetDirFn>(find_export(ex, kExpGetDir));
        a.execute     = find_export(ex, kExpExecute);
        a.baseTrigger = find_export(ex, kExpBaseTrigger);
        a.baseRead    = find_export(ex, kExpBaseRead);
        if (!a.findNode || !a.getPort || !a.getDir || !a.execute || !a.baseTrigger || !a.baseRead)
            why = "a ConceptModule export (FindNode/GetPort/GetDirection/Execute/Trigger/Read) is missing or ambiguous";
    }
    if (!why) {
        a.gameIface = reinterpret_cast<GetGameIfaceFn>(GetProcAddress(shared, kGetGameIface));
        a.boolPolicy = find_export(module_exports(crySys), kBoolPolicy);
        if (!a.gameIface || !a.boolPolicy) why = "GetGameIface or the rttr bool variant policy export is missing";
    }
    if (!why) {
        a.moduleVft  = anchor::find_vftable(a.cm, kRttiConceptModule);
        a.managerVft = anchor::find_vftable(a.cm, kRttiConceptManager);
        if (!a.moduleVft || !a.managerVft) why = "C_ConceptModule/C_ConceptManager RTTI not found";
    }
    if (why) {
        logf("PUNISH: NOT armed -- %s; an execution respawn leaves the punishment gameplay as it is", why);
        return false;
    }
    a.ok = true;
    g_api = a;
    bool state = false;
    const bool readable = read_state(&state);
    logf("PUNISH: armed (FindNode/GetPort/Execute by export, manager by RTTI); %s.State %s",
         kNodePath, readable ? (state ? "= true (a punishment is running)" : "= false") : "UNREADABLE now");
    return true;
}

bool available() { return g_api.ok; }

bool in_punishment(bool* out) {
    if (!g_api.ok) return false;
    return read_state(out);
}

bool reset(bool* was) {
    if (!g_api.ok) return false;
    bool before = false;
    if (!read_state(&before)) { logf("MP-PUNISH reset: State unreadable -- nothing fired"); return false; }
    if (was) *was = before;
    if (!before) return true;
    const bool fired = fire("SetFalse");
    bool after = true;
    const bool rb = read_state(&after);
    logf("MP-PUNISH reset: disabledEvents was true; SetFalse %s; read back %s",
         fired ? "fired" : "NOT fired", rb ? (after ? "STILL TRUE" : "false") : "unreadable");
    return fired && rb && !after;
}

bool test_set_true() {
    if (!g_api.ok) return false;
    const bool fired = fire("SetTrue");
    bool after = false;
    const bool rb = read_state(&after);
    logf("MP-PUNISH test: SetTrue %s; read back %s", fired ? "fired" : "NOT fired",
         rb ? (after ? "true" : "false") : "unreadable");
    return fired && rb && after;
}

} // namespace kcdmp::punishment
