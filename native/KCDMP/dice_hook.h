#pragma once
// WO-6 R2: locate a live wh::playermodule::C_Dice instance.
//
// No exported accessor reaches one, and nothing that was checked imports
// SetPauseWorldTime via its own IAT, so the already-proven IAT-hook technique
// (see main_thread.cpp) has no attachment point. This is a genuine inline
// detour instead -- more invasive than anything else in this plugin -- kept
// as small and reversible as the site allows. See dice_hook.cpp for the
// disassembly evidence behind the stolen-byte count.

namespace kcdmp::dice {

// Patch wh::playermodule::C_Dice::SetPauseWorldTime(bool) to capture `this`
// on every call. Read-only with respect to game behaviour: the original
// instruction sequence still runs, unmodified, via the trampoline -- this
// only ever observes, never changes what the game does.
bool install_pause_hook();

// The most recently captured C_Dice*, or null if the hook has not fired yet.
void* instance();

// Read-only, SEH-guarded. Diffs a fixed window of the captured instance's
// own memory against the last sample and logs only what changed. No-op
// until install_pause_hook() has captured an instance. Call from the main
// thread each tick (main_thread::post_repeating), same discipline as the
// combat health sampler.
void sample_instance_if_changed();

} // namespace kcdmp::dice
