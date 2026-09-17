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

// WO-100 Phase 4 item 3 -- a specific failure vocabulary.
//
// Every failure path below already logged a precise reason into the NATIVE
// log, but the pipe collapsed all of them into one bool, so the AGENT log --
// the one a field session actually reads -- showed only `ok=0`. Field
// diagnosis has repeatedly stalled on exactly that. These codes travel on the
// pipe's Result frame as a third byte (additive; a pre-WO-100 agent reads
// only body[0] and is unaffected).
//
// THIS IS A PROTOCOL. Codes are append-only -- never renumber one, because a
// mismatched agent/DLL pair would then misreport rather than say "unknown".
enum class SwingResult : uint8_t {
    Ok                = 0,
    BadSpec           = 1,   // missing or oversized fragment spec
    ModuleMissing     = 2,   // a required game module is not loaded
    BuildMismatch     = 3,   // RVA prologue check failed -- native swings disabled
    NoExports         = 4,   // EntityModule has no export table
    ActorNotResolved  = 5,   // TARGET MISSING: despawned, or a stale entity id
    CombatActorFailed = 6,   // BODY IN THE WRONG STATE: no combat actor, and one could not be made
    ManagerMissing    = 7,   // the actor's anim-action manager is null
    AllocatorMissing  = 8,
    GameIfaceMissing  = 9,
    AnimDbChainBroke  = 10,
    ParseFaulted      = 11,
    FragmentUnknown   = 12,  // ROW NOT PRESENT ON THIS BUILD -- the build-mismatch case that matters
    AllocFailed       = 13,
    CtorFailed        = 14,
    QueueFaulted      = 15,  // ENGINE REFUSED THE ACTION
    Timeout           = 16,  // synthesised by the pipe when the game thread never took the task
};

/// Human-readable name for a code, for the native log. Never used for
/// dispatch -- the agent keys on the number.
const char* swing_result_name(SwingResult r);

/// Queue one combat-swing animation on the actor with this CryEngine entity
/// id. fragSpec is "FragmentId, tag1+tag2+..." -- a real shipped row from
/// Tables.pak, resolved against the actor's own animation database by the
/// engine's own parser. Returns false (with a logged reason) if any input
/// fails to resolve; a visually inert success (weapon sheathed) still
/// returns Ok, matching WO-45's live observation.
SwingResult ghost_swing(uint32_t entityId, const char* fragSpec);

} // namespace kcdmp::rttr
