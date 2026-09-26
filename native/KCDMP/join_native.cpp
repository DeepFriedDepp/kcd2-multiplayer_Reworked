#include "join_native.h"
#include "hangover.h"
#include "respawn_actions.h"
#include "log.h"

#include <windows.h>
#include <cmath>
#include <cstring>

namespace kcdmp::joinnative {

namespace {
bool  g_fallHeld = false;
DWORD g_fallUntil = 0;
} // namespace

PlaceReport place(float hx, float hy, float hz, float dist) {
    PlaceReport r{};
    float g[3]{};
    for (int k = 0; k < 8 && !r.snapped; ++k) {
        const float a = 0.785398f * static_cast<float>(k);
        const float in[3] = {hx + dist * std::cos(a), hy + dist * std::sin(a), hz};
        ++r.tried;
        if (hangover::snap_to_ground(in, g) && std::fabs(g[2] - hz) < 3.0f) r.snapped = true;
    }
    actions::player_position(r.before);
    if (!r.snapped) {
        logf("MP-JOINPLACE host=(%.2f, %.2f, %.2f) dist=%.1f: no ground in %d directions -- NOT placed (the joiner keeps the spliced spot)",
             hx, hy, hz, dist, r.tried);
        std::memcpy(r.after, r.before, sizeof(r.after));
        return r;
    }
    std::memcpy(r.target, g, sizeof(g));
    // A lower landing after a hit arms the fall tracker (WO-113 s5.4): hold it.
    r.fallHeld = actions::suppress_fall_damage(true);
    if (r.fallHeld) { g_fallHeld = true; g_fallUntil = GetTickCount() + 3000; }
    const bool ran = actions::teleport_player(g[0], g[1], g[2]);
    actions::player_position(r.after);
    const float dx = r.after[0] - g[0], dy = r.after[1] - g[1];
    r.residual = std::sqrt(dx * dx + dy * dy);
    r.ok = ran && r.residual < 1.5f;
    logf("MP-JOINPLACE host=(%.2f, %.2f, %.2f) target=(%.2f, %.2f, %.2f) tried=%d fall_held=%d before=(%.2f, %.2f, %.2f) "
         "after=(%.2f, %.2f, %.2f) residual_m=%.2f teleport=%s -> %s", hx, hy, hz, g[0], g[1], g[2], r.tried, r.fallHeld ? 1 : 0,
         r.before[0], r.before[1], r.before[2], r.after[0], r.after[1], r.after[2], r.residual,
         ran ? "ran" : "FAILED", r.ok ? "placed" : "NOT placed");
    return r;
}

void tick() {
    if (g_fallHeld && static_cast<int>(GetTickCount() - g_fallUntil) >= 0) {
        g_fallHeld = false;
        logf("MP-JOINPLACE fall damage given back (%s)", actions::suppress_fall_damage(false) ? "previous value restored" : "restore FAILED");
    }
}

} // namespace kcdmp::joinnative
