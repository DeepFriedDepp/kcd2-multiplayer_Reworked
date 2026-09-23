#pragma once
// WO-113 Phase 3.1: the game's own blackout wake-up spots ("hangoverSpot").
//
// The drunk-blackout wake-up (BT player_sleepWalkingTeleport) finds its
// destinations in the Warhorse link graph: the level's land node links to a
// hub (tag 'hangoverSpotsHub'), the hub links to every spot (tag
// 'hangoverSpot', the 35 % joke variants 'hangoverSpot_joke', and a spot can be
// excluded by an extra 'ignoredHangoverSpot' link). PlayerModule's
// C_PlayerModule::ValidateAlcoTeleportPoints walks exactly that graph natively
// and checks every spot against the navmesh; this file replicates that walk
// call for call (docs/WO-113-findings.md s3.1 has the recipe).
//
// Anchor: the function containing "Unable to find HangoverSpotsHub from
// sa_land (via link '%s')" (PlayerModule). Every vtable offset used here is
// verified to appear, as the same instruction bytes, inside that function
// before anything is called -- a patch that moves the offsets fails closed.
//
// Result: spots with the joke and ignored ones removed, positions snapped to
// the navmesh when the navmesh query agrees. Cached per land node; the cache
// drops on a level change.

#include <cstdint>

namespace kcdmp::hangover {

struct Spot {
    float    x = 0, y = 0, z = 0;   // the spot entity's world position
    float    nx = 0, ny = 0, nz = 0; // navmesh point (== x,y,z when the query gave none)
    bool     onNavmesh = false;
    uint64_t wuid = 0;
    char     name[48]{};
};

constexpr int kMaxSpots = 256;

// Verify the anchor and its instruction bytes. Idempotent; false = the whole
// feature is off on this build (logged once, loudly).
bool resolve();

// The cached list for the current level, re-walked when the level changed or
// `force` is set. Main thread only. Returns the count (0 = none found: the
// caller falls back to the death spot and says so).
int spots(const Spot** out, bool force = false);

// The nearest usable spot to (x,y,z), optionally at least `minDist` metres away
// from (ax,ay) -- the execution rule "outside that settlement". Null when none.
const Spot* nearest(float x, float y, float z, float minDist = 0.0f, float ax = 0, float ay = 0);

// Project a point onto the navmesh -- the ground a player stands on -- with
// the anchor function's own query and the spots' acceptance rule (a real point
// within 3 m). False when there is no navmesh there or it is unreadable.
bool snap_to_ground(const float in[3], float out[3]);

// The nearest usable spot `accept` agrees to (e.g. "not inside a settlement").
const Spot* nearest_where(float x, float y, float z, bool (*accept)(const Spot& s, void* ctx), void* ctx);

} // namespace kcdmp::hangover
