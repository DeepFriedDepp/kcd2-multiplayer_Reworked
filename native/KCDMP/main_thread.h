#pragma once
// Marshalling onto the game's main thread.
//
// Everything that touches game state must run here. Calling into the combat or
// entity systems from the injected thread is a data race against the game's own
// update, and the failure mode is corruption that surfaces nowhere near the
// cause. The earlier one-shot probes did exactly that knowingly; this replaces
// it.
//
// The tick also happens to be what the plugin needs anyway: a per-frame point
// to apply inbound network state and sample outbound state.

#include <functional>

namespace kcdmp::main_thread {

// Patch WHGame.dll's IAT entry for C_ModulesManager::Update. Safe to call
// twice; the second call is a no-op.
bool install();

// Restore the original IAT entry. Called on unload.
void uninstall();

// Queue work for the next frame. Thread-safe, returns immediately.
void post(std::function<void()> work);

// Run work on every tick, for the lifetime of the process. Used by the
// outbound sampler, which needs a per-frame heartbeat rather than a one-shot.
void post_repeating(std::function<void()> work);

// Queue work and block until it has run, up to timeout_ms. Returns false on
// timeout -- which means the tick is not running, not that the work failed.
bool run_sync(std::function<void()> work, unsigned timeout_ms = 5000);

// Frames observed since install. Zero after a second or two means the hook is
// not on a live path, and everything queued will sit there forever.
unsigned long long frame_count();

} // namespace kcdmp::main_thread
