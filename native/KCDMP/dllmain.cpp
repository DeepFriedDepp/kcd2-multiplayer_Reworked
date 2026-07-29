// KCDMP.dll -- the injected native plugin.
//
// Loaded by KCDMP_LauncherInjector.exe via CreateRemoteThread(LoadLibraryA),
// which is what KCDMP_launcher's LaunchGame already expects.

#include "dice_hook.h"
#include "log.h"
#include "main_thread.h"
#include "pipe_server.h"

#include <windows.h>

namespace kcdmp { bool probe_rttr(); }
namespace kcdmp::rttr {
bool validate();
void walk_to_soul();
void probe_invoke();
void probe_take_damage();
void probe_attribution();
void probe_faction();
void probe_method_wrapper();
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

    // The walk caches SoulList/RPGModule pointers that everything else needs,
    // so it has to happen before the pipe starts accepting commands.
    const bool ran = kcdmp::main_thread::run_sync([] {
        kcdmp::rttr::walk_to_soul();
        kcdmp::rttr::probe_method_wrapper();
    });
    if (!ran) {
        kcdmp::logf("MAIN: walk timed out waiting for a frame; not starting the pipe");
        return 0;
    }

    // WO-6 R2 research hook: read-only, see dice_hook.cpp for the evidence
    // behind the patch site. Not gated on pipe/rttr success -- independent
    // of everything else this DLL does.
    if (kcdmp::dice::install_pause_hook()) {
        kcdmp::main_thread::post_repeating(&kcdmp::dice::sample_instance_if_changed);
    }

    kcdmp::pipe::start();
    return 0;
}

} // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
        CloseHandle(CreateThread(nullptr, 0, plugin_main, nullptr, 0, nullptr));
    } else if (reason == DLL_PROCESS_DETACH) {
        kcdmp::pipe::stop();
        kcdmp::main_thread::uninstall();
    }
    return TRUE;
}
