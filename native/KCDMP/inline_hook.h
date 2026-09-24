#pragma once
// WO-118: an entry hook that calls back and then runs the original function,
// for debug tooling only (mp_npc_trace's render-side sample).
//
// The recipe is the WO-116 research probe's, which hooked 24 engine functions
// live without a fault (docs/WO-116-progress.md s4):
//   * the patch overwrites `len` bytes of the function's first instructions
//     with an absolute `jmp [rip+0]` (14 bytes); the caller picks `len` on an
//     instruction boundary with no RIP-relative operand and no branch inside,
//     and passes the exact bytes it expects there -- any difference refuses
//   * a register-preserving thunk (rcx, rdx, r8, r9, xmm0-3) calls `cb`, then
//     jumps to a trampoline (the copied bytes + a jump back)
//   * the write happens with every other thread of the process suspended, and
//     is retried while any suspended thread's RIP is inside the patched range
//
// Nothing is ever unpatched: the callback is expected to be cheap and to
// check its own on/off state.

#include <cstddef>
#include <cstdint>

namespace kcdmp::inlinehook {

using Callback = void (*)();

// Patch `target` (which must start with exactly `expect[0..len)`, 14 <= len
// <= 32). Returns false, with the reason in *why, when the bytes differ, an
// allocation or protection change fails, or the patch could not be placed
// safely. Call from a thread that is NOT the one that runs `target` (the
// patch suspends every other thread).
bool install(void* target, const uint8_t* expect, size_t len, Callback cb, const char** why);

} // namespace kcdmp::inlinehook
