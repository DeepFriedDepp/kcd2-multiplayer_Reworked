#pragma once
// WO-46: the production entry point for the WO-45-verified rung-2 combat
// swing -- construct a real C_CombatAnimAction with the game's own ctor and
// queue it through the target actor's own C_CombatAnimActionManager.
//
// Called from the pipe server (kGhostSwing) on the game thread via
// main_thread::run_sync. The research twin with verbose per-step logging is
// combat_construct.cpp's rung2 trigger-file mode; this one logs a single
// line per swing and, unlike the research path, does NOT retain a safety
// reference -- the action controller's own reference owns the action's
// lifetime, so repeated swings do not leak (WO-45 findings §4 records the
// research path's deliberate 0x1A8-per-invocation leak; live evidence there
// showed the controller takes its own reference, which is what makes the
// no-retain lifecycle sound).

#include <cstdint>

namespace kcdmp::rttr {

/// Queue one combat-swing animation on the actor with this CryEngine entity
/// id. fragSpec is "FragmentId, tag1+tag2+..." -- a real shipped row from
/// Tables.pak, resolved against the actor's own animation database by the
/// engine's own parser. Returns false (with a logged reason) if any input
/// fails to resolve; a visually inert success (weapon sheathed) still
/// returns true, matching WO-45's live observation.
bool ghost_swing(uint32_t entityId, const char* fragSpec);

} // namespace kcdmp::rttr
