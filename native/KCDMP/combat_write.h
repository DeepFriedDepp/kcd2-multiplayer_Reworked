#pragma once

// WO-100.5 Phase 1 -- the first combat WRITE, file-triggered and one-shot.
namespace kcdmp::combatwrite {

// Polled on the main thread. Does nothing at all until kcdmp-combatwrite.txt
// exists and names a command; each distinct command fires exactly once.
void write_watch();

} // namespace kcdmp::combatwrite
