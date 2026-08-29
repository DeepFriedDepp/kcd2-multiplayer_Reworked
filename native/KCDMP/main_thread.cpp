#include "main_thread.h"
#include "iat_hook.h"
#include "log.h"

#include <windows.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <vector>

namespace kcdmp::main_thread {

namespace {

// C_ModulesManager::Update(float) -- a non-static member, so the real
// signature is (this, dt). Declared explicitly rather than as a method pointer
// so the calling convention is unambiguous.
using UpdateFn = void (*)(void* self, float dt);

UpdateFn  g_original = nullptr;
HMODULE   g_importer = nullptr;
bool      g_installed = false;

std::mutex                          g_mutex;
std::vector<std::function<void()>>  g_queue;
std::vector<std::function<void()>>  g_repeating;
std::condition_variable             g_drained;
std::atomic<unsigned long long>     g_frames{0};
DWORD                               g_main_thread_id = 0;

constexpr const char* kImporter = "WHGame.dll";
constexpr const char* kProvider = "Framework.dll";
constexpr const char* kSymbol   = "?Update@C_ModulesManager@framework@wh@@QEAAXM@Z";
enum class SyncPhase { pending, running, done, cancelled };

// Separate function because __try/__except cannot share a frame with objects
// that need unwinding (C2712), and the drain loop below owns a vector of
// std::function.
void run_guarded(std::function<void()>* work) {
    __try {
        (*work)();
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        // A fault here is on the game's own thread. Swallow it so one bad task
        // cannot take the process down mid-frame.
        logf("MAIN: task raised a structured exception -- swallowed");
    }
}

void hooked_update(void* self, float dt) {
    // Original first: queued work should observe the state the frame produced,
    // and if our work throws the game has still updated.
    if (g_original) g_original(self, dt);

    ++g_frames;
    if (g_main_thread_id == 0) g_main_thread_id = GetCurrentThreadId();

    // Swap under the lock and run outside it: queued work may post more work,
    // and holding the lock across a call into the game invites a deadlock.
    std::vector<std::function<void()>> batch;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!g_queue.empty()) batch.swap(g_queue);
    }
    // Copy under the lock, run outside it. Running them while holding g_mutex
    // would block every post() for the duration of a call into the game, which
    // is exactly the deadlock the comment above warns about.
    std::vector<std::function<void()>> repeating;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        repeating = g_repeating;
    }
    for (auto& r : repeating) run_guarded(&r);

    if (batch.empty()) return;

    for (auto& work : batch) {
        run_guarded(&work);
    }
    g_drained.notify_all();
}

} // namespace

bool install() {
    if (g_installed) return true;

    g_importer = GetModuleHandleA(kImporter);
    if (!g_importer) {
        logf("MAIN: %s not loaded", kImporter);
        return false;
    }

    void* previous = hook_iat(g_importer, kProvider, kSymbol,
                              reinterpret_cast<void*>(&hooked_update));
    if (!previous) {
        logf("MAIN: IAT entry for %s not found in %s", kSymbol, kImporter);
        return false;
    }

    g_original  = reinterpret_cast<UpdateFn>(previous);
    g_installed = true;
    logf("MAIN: hooked %s!IAT[%s] original=%p", kImporter, "C_ModulesManager::Update", previous);
    return true;
}

void uninstall() {
    if (!g_installed) return;
    hook_iat(g_importer, kProvider, kSymbol, reinterpret_cast<void*>(g_original));
    g_installed = false;
    logf("MAIN: unhooked");
}

void post_repeating(std::function<void()> work) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_repeating.push_back(std::move(work));
}

void post(std::function<void()> work) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_queue.push_back(std::move(work));
}

bool run_sync(std::function<void()> work, unsigned timeout_ms) {
    // Already on the main thread: run inline. Queueing here would deadlock,
    // because the drain that would run it is the frame we are inside.
    if (g_main_thread_id != 0 && GetCurrentThreadId() == g_main_thread_id) {
        work();
        return true;
    }

    struct State {
        std::mutex mutex;
        std::condition_variable cv;
        std::function<void()> work;
        SyncPhase phase = SyncPhase::pending;
    };

    auto state = std::make_shared<State>();
    state->work = std::move(work);

    post([state] {
        {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (state->phase != SyncPhase::pending) return;
            state->phase = SyncPhase::running;
        }

        // Guard here as well as in hooked_update so an SEH fault cannot skip
        // the completion signal and leave the waiting pipe thread blocked.
        try {
            run_guarded(&state->work);
        } catch (...) {
            logf("MAIN: task raised a C++ exception -- swallowed");
        }

        {
            std::lock_guard<std::mutex> lock(state->mutex);
            state->work = {};
            state->phase = SyncPhase::done;
        }
        state->cv.notify_all();
    });

    std::unique_lock<std::mutex> lock(state->mutex);
    if (state->cv.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&] {
            return state->phase == SyncPhase::done;
        })) {
        return true;
    }

    if (state->phase == SyncPhase::pending) {
        // The frame never picked the task up. Cancel it while its captured
        // caller state is still alive; the queued wrapper becomes a no-op.
        state->phase = SyncPhase::cancelled;
        state->work = {};
        return false;
    }

    // Once execution has started, returning would invalidate references held
    // by the caller's lambda. Finish safely even if that crosses the timeout.
    state->cv.wait(lock, [&] { return state->phase == SyncPhase::done; });
    return true;
}

unsigned long long frame_count() { return g_frames.load(std::memory_order_relaxed); }

} // namespace kcdmp::main_thread
