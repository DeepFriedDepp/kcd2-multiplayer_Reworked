#pragma once
// WO-113 Phase 5 (C2): the Game Over safety net.
//
// Every Game Over in KCD2 enters through I_GameOver slot 1 -- C_GameOver::Start
// (PlayerModule), which has no static callers and is not exported (WO-111
// s3.3). The slot is one aligned pointer in PlayerModule's .rdata; this swaps
// it for a guard, atomically, the same shape as the IAT swap main_thread.cpp
// already relies on.
//
// Anchors, all checked before the write (fail closed, loud):
//   * the vftable is found by RTTI: ".?AVC_GameOver@playermodule@wh@@"
//   * slot 1's function references "Game over is already started" (its own
//     refusal string) and "wh::playermodule::C_GameOver::Start" (__FUNCTION__)
//
// Start's signature, code-verified (decompiled): void Start(C_GameOver*, int id)
// -- id is a game_over.xml row (0-8 deaths, 26 DiedWhileUnconscious, 44 crime
// execution, 39+ plot failures).
//
// The policy lives in respawn.cpp; this file only asks it. Every call is
// logged, swallowed or passed.

namespace kcdmp::gameover {

// Decides one Game Over. Called on whatever thread called Start (the game's
// main thread in every path observed); must be quick and must not block.
// Return true to SWALLOW (Start is not called; the policy has taken over).
using Policy = bool (*)(int id);

void set_policy(Policy p);

// Resolve, verify and swap. Idempotent. False (with the reason logged) when
// any anchor does not verify -- nothing is written in that case.
bool install();

bool installed();

// Pass a Game Over straight to the original Start, bypassing the policy.
// For a policy that decides, after all, to let one through.
void call_original(void* self, int id);

} // namespace kcdmp::gameover
