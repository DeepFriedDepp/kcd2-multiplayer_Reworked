// KCDMP.dll -- the injected native plugin.
//
// Loaded by KCDMP_LauncherInjector.exe via CreateRemoteThread(LoadLibraryA),
// which is what KCDMP_launcher's LaunchGame already expects.

#include "motion.h"
#include "hits.h"
#include "concept_read.h"
#include "dice_hook.h"
#include "log.h"
#include "main_thread.h"
#include "mannequin_read.h"
#include "npc_drive.h"
#include "combat_write.h"
#include "pipe_server.h"
#include "respawn.h"
#include "script_context.h"

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
void probe_dice_class();
void probe_play_anim();
void probe_play_anim_watch();
void probe_combat_construct();
void probe_combat_construct_watch();
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
    //
    // WO-10: a single 1s sample-and-abort was wrong for automatic injection
    // and reliably fired there. WHGame.dll is a static import, so it is
    // present in the process almost instantly -- but the game's actual
    // per-frame C_ModulesManager::Update tick does not start until well
    // past the splash/menu screens, into an actually-loaded save. Injecting
    // the moment the module is merely loadable hooks the import correctly
    // but checks for ticks far too soon, and a one-shot check with no retry
    // aborted permanently before the pipe or sampler ever started. Verified
    // (docs/VERIFICATION-REPORT.md): the identical DLL, injected into the
    // same still-running process minutes later once a save was actually
    // loaded, ticked immediately ("25 frames in ~1s") -- this isolates the
    // defect to timing, not the hook/rttr mechanism. Manual injection into
    // an already-loaded game was never affected, since the tick is already
    // live by the time the DLL attaches.
    //
    // Fix: poll instead of sampling once. This runs on its own background
    // thread (see DllMain below), so waiting costs nothing but time -- it
    // does not block the game or the loader. The ceiling is generous, not
    // measured: a player may sit at the main menu for a while before
    // loading a save, and there is no cost to waiting longer for a real
    // player, only a benefit over giving up on one that just hasn't loaded
    // yet.
    constexpr DWORD kFrameCheckIntervalMs = 1000;
    constexpr DWORD kFrameCheckCeilingMs  = 300'000; // 5 minutes
    constexpr DWORD kFrameCheckLogEveryMs = 30'000;  // progress line, so a long wait doesn't look hung in the log

    unsigned long long frames = 0;
    DWORD waited = 0;
    while (waited < kFrameCheckCeilingMs) {
        Sleep(kFrameCheckIntervalMs);
        waited += kFrameCheckIntervalMs;
        frames = kcdmp::main_thread::frame_count();
        if (frames > 0) {
            kcdmp::logf("MAIN: %llu frames after ~%u ms -- tick is live", frames, waited);
            break;
        }
        if (waited % kFrameCheckLogEveryMs == 0) {
            kcdmp::logf("MAIN: still waiting for the tick to start (%u ms elapsed, 0 frames so far)", waited);
        }
    }
    if (frames == 0) {
        kcdmp::logf("MAIN: tick never fired after %u ms -- aborting before any game-state access", waited);
        return 0;
    }

    // The walk caches SoulList/RPGModule pointers that everything else needs,
    // so it has to happen before the pipe starts accepting commands.
    const bool ran = kcdmp::main_thread::run_sync([] {
        kcdmp::rttr::walk_to_soul();
        kcdmp::rttr::probe_method_wrapper();
        kcdmp::rttr::probe_dice_class();
        // WO-15: re-enabled with the ownership fix (see rttr_abi.cpp). No-ops
        // unless kcdmp-faction.txt exists beside the DLL -- opt-in, human
        // writes the ghost/donor GUIDs deliberately before injecting.
        kcdmp::rttr::probe_faction();
        // WO-43 Phase 1: no-op unless kcdmp-playanim.txt exists beside the
        // DLL -- opt-in, same convention as probe_faction above.
        kcdmp::rttr::probe_play_anim();
        // WO-44 direction-B precondition probe: no-op unless kcdmp-combat.txt
        // exists beside the DLL -- opt-in, same convention. Read-only (or one
        // idempotent GetOrCreateCombatActor call in mode=create); constructs
        // and queues nothing.
        kcdmp::rttr::probe_combat_construct();
        // WO-68 Phase 1: no-op unless kcdmp-contexts.txt exists beside the
        // DLL -- same opt-in convention. Read-only unless its line 2 says
        // "write", and even then it undoes its own write.
        kcdmp::sctx::probe_contexts();
        // WO-113: death without Game Over. Resolves every anchor (fail
        // closed per piece), installs the I_GameOver::Start guard, logs
        // WO113-BUILD. The guard itself only arms in a session.
        kcdmp::respawn::install();
        // WO-118: the native per-frame puppet write. Anchors fail closed
        // (WO118-NATIVE native_write=DISARMED): Lua then writes as before.
        kcdmp::npcdrive::install();
        // WO-121: movement and combat on the writer's bodies, the committed-
        // action capture, and the combat-hit chokepoint. Each piece fails
        // closed on its own (WO121-MOTION / WO121-HITS lines).
        kcdmp::motion::install();
        kcdmp::hits::install();
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

    // WO-44 follow-up: entity ids are assigned fresh every launch, so testing
    // the direction-B probe against a ghost (as opposed to the player) needs
    // the id known only after the game is already running. Re-check
    // kcdmp-combat.txt on a timer instead of only once at attach, so a human
    // can spawn a ghost, read its id live, and drop it into the file without
    // a relaunch. No-ops whenever the file's content is unchanged.
    kcdmp::main_thread::post_repeating(&kcdmp::rttr::probe_combat_construct_watch);
    // Same live-reload treatment for WO-43's original PlayAnim diagnostic --
    // needed to pin down a live discrepancy found while re-testing WO-44's
    // ghost class-dispatch finding against a validated ghost.
    kcdmp::main_thread::post_repeating(&kcdmp::rttr::probe_play_anim_watch);
    // WO-68: same live-reload treatment, so a soul guid can be dropped into
    // kcdmp-contexts.txt after a ghost is already standing in the world.
    kcdmp::main_thread::post_repeating(&kcdmp::sctx::probe_contexts_watch);
    // WO-99.5: the quest-port probe. Same live-reload treatment, and the same
    // reason -- a node path is chosen after looking at what the running game
    // actually has. File-watched rather than pipe-driven on purpose: the pipe
    // has nMaxInstances = 1, so a pipe command would mean disconnecting the
    // client first (WO-97 s4.4's precondition), and this needs to run while a
    // session is live.
    kcdmp::main_thread::post_repeating(&kcdmp::conceptread::port_watch);
    // WO-100 Phase 0: the Mannequin tag-state read. Same file-watched,
    // opt-in convention and the same reason -- it has to run during a live
    // session while the maintainer walks, jogs, sprints and crouches, and the
    // pipe (nMaxInstances = 1) is occupied by the agent for the whole session.
    kcdmp::main_thread::post_repeating(&kcdmp::mannequin::tag_watch);
    // WO-100.5 Phase 1: the first combat WRITE. Same file-watched shape, but
    // ONE-SHOT rather than periodic -- a write that repeats at the tick rate
    // is a hook, not a probe. Idle until kcdmp-combatwrite.txt names a command.
    kcdmp::main_thread::post_repeating(&kcdmp::combatwrite::write_watch);
    // WO-113: the death guard's per-frame tick (rate-limits itself).
    kcdmp::main_thread::post_repeating(&kcdmp::respawn::tick);
    // WO-121: drain the capture / friendly-fire queues, avatar jumps.
    kcdmp::main_thread::post_repeating(&kcdmp::motion::tick);
    kcdmp::main_thread::post_repeating(&kcdmp::hits::tick);

    kcdmp::pipe::start();
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
