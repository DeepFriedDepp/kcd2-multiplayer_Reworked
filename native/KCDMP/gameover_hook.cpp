#include "gameover_hook.h"
#include "anchors.h"
#include "log.h"

#include <windows.h>
#include <atomic>

namespace kcdmp::gameover {

namespace {

using StartFn = void (*)(void* self, int id);

constexpr const char* kModule       = "PlayerModule.dll";
constexpr const char* kRtti         = ".?AVC_GameOver@playermodule@wh@@";
constexpr const char* kRefusalStr   = "Game over is already started";
constexpr const char* kFunctionStr  = "wh::playermodule::C_GameOver::Start";
constexpr int         kSlotStart    = 1;

std::atomic<StartFn> g_original{nullptr};
std::atomic<Policy>  g_policy{nullptr};
void* const*         g_vftable = nullptr;
bool                 g_installed = false;

void hooked_start(void* self, int id) {
    const Policy p = g_policy.load();
    bool swallow = false;
    if (p) {
        // The policy runs game-thread reads; a fault there must not become a
        // Game Over that silently never happens -- pass through instead.
        __try { swallow = p(id); }
        __except (EXCEPTION_EXECUTE_HANDLER) {
            logf("MP-GAMEOVER id=%d policy FAULTED -- passing through to the original", id);
            swallow = false;
        }
    }
    if (swallow) {
        logf("MP-GAMEOVER id=%d decision=swallow (handed to the respawn)", id);
        return;
    }
    logf("MP-GAMEOVER id=%d decision=pass", id);
    if (StartFn o = g_original.load()) o(self, id);
}

} // namespace

void set_policy(Policy p) { g_policy.store(p); }

bool installed() { return g_installed; }

void call_original(void* self, int id) {
    if (StartFn o = g_original.load()) o(self, id);
}

bool install() {
    if (g_installed) return true;
    char d[256]{};

    HMODULE mod = GetModuleHandleA(kModule);
    if (!mod) { logf("MP-GAMEOVER: %s not loaded -- guard NOT installed", kModule); return false; }

    void* const* vft = anchor::find_vftable(mod, kRtti, 0);
    if (!vft) {
        logf("MP-GAMEOVER: ANCHOR FAILED -- RTTI %s has no unique vftable; guard NOT installed", kRtti);
        return false;
    }
    anchor::describe(vft, d, sizeof(d));
    logf("MP-GAMEOVER: C_GameOver vftable = %p (%s) [anchor: RTTI %s]", vft, d, kRtti);

    void* start = vft[kSlotStart];
    const char* refusal  = anchor::find_cstring(mod, kRefusalStr);
    const char* fnName   = anchor::find_cstring(mod, kFunctionStr);
    const bool refsRefusal = refusal && anchor::function_refs(mod, start, refusal);
    const bool refsName    = fnName && anchor::function_refs(mod, start, fnName);
    anchor::describe(start, d, sizeof(d));
    logf("MP-GAMEOVER: slot %d = %p (%s) refs \"%s\"=%s refs \"%s\"=%s", kSlotStart, start, d,
         kRefusalStr, refsRefusal ? "yes" : "NO", kFunctionStr, refsName ? "yes" : "NO");
    if (!refsRefusal || !refsName) {
        logf("MP-GAMEOVER: ANCHOR FAILED -- slot %d is not C_GameOver::Start on this build; guard NOT installed",
             kSlotStart);
        return false;
    }

    // The vftable lives in .rdata: open the one page, swap one aligned pointer
    // atomically, restore the protection. A reader racing the swap sees either
    // the old or the new pointer, never half of one.
    void** slot = const_cast<void**>(&vft[kSlotStart]);
    DWORD oldProt = 0;
    if (!VirtualProtect(slot, sizeof(void*), PAGE_READWRITE, &oldProt)) {
        logf("MP-GAMEOVER: VirtualProtect failed (%lu) -- guard NOT installed", GetLastError());
        return false;
    }
    g_original.store(reinterpret_cast<StartFn>(start));
    void* prev = InterlockedExchangePointer(slot, reinterpret_cast<void*>(&hooked_start));
    DWORD ignored = 0;
    VirtualProtect(slot, sizeof(void*), oldProt, &ignored);
    if (prev != start) {
        // Someone else changed the slot between our read and our write. Put
        // theirs back rather than chaining onto an unknown hook.
        logf("MP-GAMEOVER: slot changed under us (%p != %p) -- restoring, guard NOT installed", prev, start);
        if (VirtualProtect(slot, sizeof(void*), PAGE_READWRITE, &oldProt)) {
            InterlockedExchangePointer(slot, prev);
            VirtualProtect(slot, sizeof(void*), oldProt, &ignored);
        }
        g_original.store(nullptr);
        return false;
    }
    g_vftable = vft;
    g_installed = true;
    logf("MP-GAMEOVER: guard INSTALLED on C_GameOver::Start (original %p)", start);
    return true;
}

} // namespace kcdmp::gameover
