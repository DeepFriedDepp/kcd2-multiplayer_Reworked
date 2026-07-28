// KCDMP.dll -- the injected native plugin.
//
// Loaded by KCDMP_LauncherInjector.exe via CreateRemoteThread(LoadLibraryA),
// which is what KCDMP_launcher's LaunchGame already expects.

#include "log.h"
#include "main_thread.h"

#include <windows.h>

namespace kcdmp { bool probe_rttr(); }
namespace kcdmp::rttr {
bool validate();
void walk_to_soul();
void probe_invoke();
void probe_take_damage();
void probe_attribution();
}

namespace {

DWORD WINAPI plugin_main(LPVOID) {
    // DllMain runs under the loader lock, so all real work happens here.
    kcdmp::logf("KCDMP.dll attached, pid=%lu", GetCurrentProcessId());

    char exe[MAX_PATH]{};
    GetModuleFileNameA(nullptr, exe, MAX_PATH);
    kcdmp::logf("host = %s", exe);

    // If we are injected at process start the engine modules are not loaded
    // yet. Wait for CrySystem rather than failing on a race.
    // GUESS, unverified: 60 s is generous for a cold start off an SSD.
    const DWORD deadline = GetTickCount() + 60'000;
    while (!GetModuleHandleA("CrySystem.dll") && GetTickCount() < deadline) {
        Sleep(250);
    }

    if (!kcdmp::probe_rttr() || !kcdmp::rttr::validate()) return 0;

    if (!kcdmp::main_thread::install()) {
        kcdmp::logf("MAIN: no tick -- refusing to touch game state from this thread");
        return 0;
    }

    // Confirm the hook is on a live path before trusting it. A hook that never
    // fires is indistinguishable from a queue that never drains, and work
    // posted to it would sit there forever looking like a hang.
    Sleep(1000);
    const auto frames = kcdmp::main_thread::frame_count();
    kcdmp::logf("MAIN: %llu frames in ~1s", frames);
    if (frames == 0) {
        kcdmp::logf("MAIN: tick is not firing -- aborting before any game-state access");
        return 0;
    }

    // Everything below touches game state, so it runs on the game's thread.
    const bool ran = kcdmp::main_thread::run_sync([] {
        kcdmp::rttr::walk_to_soul();
        kcdmp::rttr::probe_invoke();
        kcdmp::rttr::probe_attribution();
    });
    kcdmp::logf(ran ? "MAIN: probes completed on the main thread"
                    : "MAIN: probes timed out waiting for a frame");
    return 0;
}

} // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
        CloseHandle(CreateThread(nullptr, 0, plugin_main, nullptr, 0, nullptr));
    } else if (reason == DLL_PROCESS_DETACH) {
        kcdmp::main_thread::uninstall();
    }
    return TRUE;
}
