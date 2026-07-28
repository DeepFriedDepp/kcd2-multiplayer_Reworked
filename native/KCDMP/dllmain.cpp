// KCDMP.dll -- the injected native plugin.
//
// Loaded by KCDMP_LauncherInjector.exe via CreateRemoteThread(LoadLibraryA),
// which is what KCDMP_launcher's LaunchGame already expects. Nothing here
// touches game state yet; milestone 1 is only to establish that the reflection
// ABI is reachable from in-process.

#include "log.h"

#include <windows.h>

namespace kcdmp { bool probe_rttr(); }
namespace kcdmp::rttr { bool validate(); void walk_to_soul(); }

namespace {

DWORD WINAPI plugin_main(LPVOID) {
    // DllMain runs under the loader lock, so all real work happens here.
    kcdmp::logf("KCDMP.dll attached, pid=%lu", GetCurrentProcessId());

    char exe[MAX_PATH]{};
    GetModuleFileNameA(nullptr, exe, MAX_PATH);
    kcdmp::logf("host = %s", exe);

    // If we are injected at process start, the engine modules are not loaded
    // yet. Wait for CrySystem rather than failing on a race.
    // GUESS, unverified: 60 s is generous for a cold start off an SSD. If this
    // ever times out on a real launch the number is wrong, not the approach.
    const DWORD deadline = GetTickCount() + 60'000;
    while (!GetModuleHandleA("CrySystem.dll") && GetTickCount() < deadline) {
        Sleep(250);
    }

    if (kcdmp::probe_rttr() && kcdmp::rttr::validate()) {
        kcdmp::rttr::walk_to_soul();
    }
    return 0;
}

} // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
        CloseHandle(CreateThread(nullptr, 0, plugin_main, nullptr, 0, nullptr));
    }
    return TRUE;
}
