#pragma once
// WO-118 Phase 5: mp_npc_trace <name> [seconds] -- WO-116 s14's per-frame
// probe as shipped debug tooling, off by default.
//
// For one named entity (an NPC puppet, a ghost, anything with a name), every
// frame: its world position at the DLL's frame hook BEFORE any write of ours,
// what (if anything) the native writer wrote, and its position at the entry of
// CSystem::Render -- "what the renderer gets". Written to a CSV in the game's
// working directory (beside kcd.log and kcdmp-native.mirror.log) when the
// recording ends.
//
// The render-side sample needs an entry hook on CSystem::Render (CrySystem).
// It is installed on the FIRST trace only, never at startup: the function is
// found by the one function that references its "CSystem::Render" profiler
// label, and its first 14 bytes must match this build exactly or the hook is
// refused (the trace then records the frame-hook columns only and says so).

#include <cstdint>

namespace kcdmp::npctrace {

// Pipe thread. seconds == 0 stops a running trace (the CSV is written).
// Returns 0 ok, 1 no such entity, 2 bad request. The render hook's outcome is
// logged; a refused hook does not fail the trace.
uint8_t request(const char* name, uint16_t seconds);

// Main thread, from npcdrive::tick().
void frame_begin(double now);
void note_write(void* e, const float pose[4]);
void frame_end();

// Unsolicited "trace written" (rows, csv path) -> the agent.
using DoneFn = void (*)(uint32_t rows, const char* path);
void set_done_callback(DoneFn fn);

} // namespace kcdmp::npctrace
