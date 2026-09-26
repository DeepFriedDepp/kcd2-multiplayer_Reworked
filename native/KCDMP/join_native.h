#pragma once
// WO-124: the joiner's placement beside the host (docs/WO-124-findings.md).
//
// place(): put the player `dist` metres beside the host, on the ground. Eight
// directions around the host are tried in turn (east first, then round) until
// the navmesh snap WO-113 uses for its wake spots finds ground there within
// 3 m of the host's height; then WO-113's player teleport (XGenAI teleport
// with a physics reset, the `goto` shape as fallback) with the fall damage
// held for the landing and given back 3 s later. No ground anywhere: no
// teleport at all (fail closed -- the joiner keeps the host Henry's spot).
// Main thread only; the pipe marshals it (0x1C -> 0x8C).

#include <cstdint>

namespace kcdmp::joinnative {

struct PlaceReport {
    bool  ok = false;          // the teleport ran and the player stands at the target
    bool  snapped = false;     // a target on the ground was found
    int   tried = 0;           // directions tried
    bool  fallHeld = false;    // fall damage suppressed for the landing
    float target[3]{};         // where it aimed (after the snap)
    float before[3]{};
    float after[3]{};
    float residual = -1.f;     // |after - target| in the horizontal plane
};

PlaceReport place(float hostX, float hostY, float hostZ, float dist);

// Per-frame: gives the fall damage back 3 s after a place().
void tick();

} // namespace kcdmp::joinnative
