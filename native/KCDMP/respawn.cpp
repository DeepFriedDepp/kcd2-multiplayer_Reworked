#include "respawn.h"
#include "respawn_actions.h"
#include "engine.h"
#include "buffs.h"
#include "gameover_hook.h"
#include "hangover.h"
#include "main_thread.h"
#include "punishment.h"
#include "rttr_abi.h"
#include "script_context.h"
#include "log.h"

#include <windows.h>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>

namespace kcdmp::respawn {

namespace {

// --- the guard buff -----------------------------------------------------------
// Mod-owned row, shipped in kdcmp.pak as Libs/Tables/rpg/buff__kcdmp.xml (the
// table-extension convention the game's own buff__dlc2_beds.xml uses): a copy
// of death_protection_cutscene -- imm=1, upr=1, class 15, IdExclusive, no UI,
// NOT persistent (never written into a save, cannot outlive an uninstall).
constexpr const char* kGuardGuidText    = "4b43444d-7113-4d67-b1a5-9e2f6d8c0a13";   // kcdmp_death_guard
// Fallback when the mod row is not loaded: the shipped row no script touches.
constexpr const char* kFallbackGuidText = "6f706644-e28a-41a9-9674-5f19dea03bf1";   // death_protection_cutscene

// --- the knockdown ----------------------------------------------------------------
// Two ways to end the fight, chosen by g_knockMode:
//  * Disengage (shipped): fade out, restore, the game's own StopFight for the
//    player's skirmish (what quests use to end a fight), a short targeting
//    exclusion, wake where the player fell. No unconsciousness, so none of
//    the vanilla knockout's aftermath (robbery, arrest, time skip) -- the
//    WO's rule. Observed without StopFight: the NPC stayed hostile after the
//    wake and drew an axe.
//  * GameKnockout (fallback, test command `knockmode knockout`): the game's
//    own knockout. The guard's upr=1 is unconsciousness protection (the
//    shipped unconsciousness_protection rows carry upr=1 and nothing else),
//    so this swaps to an immortal-only guard and applies the non-persistent
//    unconscious buff. Observed: the skirmish ends the vanilla way -- and the
//    NPC's own aftermath (a pay-to-make-it-right dialogue) follows.
constexpr const char* kKoGuardGuidText  = "4b43444d-7113-4d67-b1a5-9e2f6d8c0a14";   // kcdmp_knockout_guard (imm=1)
constexpr const char* kKoGuardFallback  = "89739dbc-fb20-4a28-8b70-986ab9b5f79a";   // player_immortalityOnly_nonPersistent
constexpr const char* kUnconsciousNp    = "f8d60fe4-e2c1-420a-946a-213e1cd09265";   // unconscious_nonpersistend (Cpp:Unconscious)
// What the fist-fight quests set so nobody robs the knocked-out player.
constexpr const char* kNoShenanigans    = "crime_suppressUnconsciousPlayerShenanigans";

// Other immortality buffs. One of these on the player at the floor means a
// quest or scene owns the moment (a brawl's player_immortality_nonpersistent,
// a battle's death_protection_nonpersistent): the detector stands down and the
// quest's own ending runs, exactly as vanilla.
constexpr const char* kQuestImmortality[] = {
    "44e1ccc9-9252-48a9-922d-2ae4523c69a3",   // player_immortality_nonpersistent (brawls)
    "0f6bc79a-fc67-4aab-a797-4a9d4e4c2dc5",   // death_protection_nonpersistent (battles, hostages, duels)
    "c7c79394-cd16-4d86-a029-f8a5f6623f9d",   // death_protection
    "98d2764a-bdbf-473f-903a-1209813d2e15",   // player_immortality
    "730503bf-735a-4f47-baae-c2d84ee77524",   // immortality_nonpersistent
    "89739dbc-fb20-4a28-8b70-986ab9b5f79a",   // player_immortalityOnly_nonPersistent
    "85aca9c5-ec41-400d-a563-53df7b2399e8",   // immortality
    "52e578c8-608f-44e5-b6c0-e79673cfd4a0",   // immortality_fast_heal_nonpersistent
    "6cf0aa39-e09c-42fa-bf67-10f2d03991b7",   // immortality_fast_heal
};

// Cleared on every respawn and knockdown wake-up.
constexpr const char* kClearOnWake[] = {
    "b0247507-ca18-4277-a037-ee3a9274e625",   // test_bleeding
    "8544ebca-1e30-400c-b31c-2a1839f1cab8",   // deadly_poison
    "04218e40-e756-476b-914e-03d67a24e733",   // food_poison
    "aeef8e78-896a-4106-ab2f-62bec1d98378",   // food_poisoning
    "f8d60fe4-e2c1-420a-946a-213e1cd09264",   // unconscious
    "f8d60fe4-e2c1-420a-946a-213e1cd09265",   // unconscious_nonpersistend
    "7f0e2530-abc9-4800-8ae1-5db8a9aa86b1",   // unconscious_alcohol
};
// Added on every respawn: the game's own cleaners (vanilla bandage/mercy/
// punishment use remove_injuries; 72 scripts use remove_unconsciousness).
constexpr const char* kAddOnWake[] = {
    "46683e3b-e261-412f-b402-99ee17dda62a",   // remove_injuries
    "bd22f98a-e61f-4d83-b39c-79d1d85b6b91",   // remove_unconsciousness
    "de68e56a-a74c-4447-874b-487b03c3fc6e",   // remove_all_posions (Cpp:Instant)
};
// Poison on the player at the floor is always a death.
constexpr const char* kPoisons[] = {
    "8544ebca-1e30-400c-b31c-2a1839f1cab8",   // deadly_poison
    "04218e40-e756-476b-914e-03d67a24e733",   // food_poison
    "aeef8e78-896a-4106-ab2f-62bec1d98378",   // food_poisoning
};

// --- tuning -------------------------------------------------------------------
constexpr float kFloor            = 1.0f;     // ImmortalHealthMin (params+0x3A0, default 1.0; WO-111)
constexpr float kFloorEpsilon     = 0.01f;
constexpr DWORD kSampleMs         = 100;
constexpr int   kFloorConfirm     = 2;        // consecutive floor samples
// A load strips the non-persistent guard while the soul keeps its address
// (observed): presence is checked this often, not on a slow re-assert.
constexpr DWORD kReassertMs       = 250;
constexpr DWORD kMaintainMs       = 5000;
constexpr float kHostileRadius    = 10.0f;    // m
constexpr float kRecentHitS       = 3.0f;     // the flooring hit
constexpr float kFightS           = 30.0f;    // "a hostile in this fight"
constexpr float kKnockdownHealth  = 30.0f;    // hp after a knockdown wake-up
constexpr float kFullHealth       = 1000.0f;  // clamped to max by SetSoulState
constexpr float kFullStamina      = 1000.0f;
constexpr float kMinHunger        = 70.0f;
constexpr float kFadeOutS         = 0.8f;
constexpr float kFadeInS          = 1.2f;
constexpr DWORD kFadeTimeoutMs    = 2500;
constexpr DWORD kSettleMs         = 700;
// The screen stays black this long after the act (grave, teleport, restore)
// before the fade-in: the maintainer found an instant wake jarring and asked
// for a 5-10 s hold, for deaths and knockdowns alike.
constexpr DWORD kBlackHoldMs      = 6000;
constexpr DWORD kKnockdownImmuneMs = 8000;    // targeting exclusion after a knockdown
constexpr float kExecutionMinDist = 450.0f;   // m from the execution spot, when the area test cannot answer
// A death respawn skips every spot this close to where the player died
// (observed: the nearest spot was 10 m from the killer, who killed the player
// again on arrival). The maintainer's call: 100 m, nearest otherwise.
constexpr float kDeathMinDist     = 100.0f;
// A floor within this long of a completed respawn is the same downing's tail
// (a wake-spot hazard, a late wound): restore again, no second grave, no
// second teleport -- a grave-and-teleport loop is worse than one extra heal.
constexpr DWORD kGraceMs          = 10000;
constexpr DWORD kFallHoldMs       = 3000;    // fall damage stays off this long after the wake
constexpr DWORD kKnockoutMs       = 10000;   // the fist-fight library's own knockout length (delka_knockoutu)
constexpr DWORD kKnockoutMinMs    = 2000;    // an earlier wake by the game counts only after this
constexpr DWORD kKnockoutTakeMs   = 1500;    // the unconscious state must show up within this

// --- state ----------------------------------------------------------------------
std::atomic<bool> g_session{false};
std::atomic<bool> g_enabled{true};
std::atomic<bool> g_busy{false};              // an executor sequence is running
std::atomic<int>  g_pendingGameOver{-1};      // a swallowed Game Over waiting for the tick

Events g_ev{};
bool   g_installed = false;
bool   g_armed = false;                       // buff anchors verified
unsigned char g_guardGuid[16]{};
unsigned char g_modGuid[16]{};
unsigned char g_fallbackGuid[16]{};
bool   g_usingFallback = false;
bool   g_applied = false;
void*  g_appliedSoul = nullptr;
DWORD  g_lastAssert = 0;
DWORD  g_lastSample = 0;
DWORD  g_lastMaintain = 0;
int    g_floorHits = 0;
bool   g_standDownLogged = false;
bool   g_deadLogged = false;
unsigned char g_koGuid[16]{};                 // the knockdown guard in use
unsigned char g_koFallbackGuid[16]{};
unsigned char g_unconsciousGuid[16]{};
bool   g_koContextSet = false;                // we set kNoShenanigans (only then do we clear it)
enum class KnockMode { Disengage, GameKnockout };
KnockMode g_knockMode = KnockMode::Disengage;

enum class Phase { Idle, FadeOut, Act, Settle, Hold, FadeIn, KnockedOut };
struct Exec {
    Phase phase = Phase::Idle;
    Kind  kind = Kind::Death;
    int   gameOverId = -1;
    DWORD t0 = 0;
    float deathPos[3]{};
    float wakePos[3]{};
    bool  haveWake = false;
    bool  fallbackDone = false;   // the goto-shaped teleport after ExecuteTeleportImpl did not move us
    DWORD immuneUntil = 0;
    bool  koSeen = false;         // IsUnconscious read true at least once during the knockout
    DWORD actAt = 0;              // when the act ran (the black hold counts from here)
} g_x;

// Execution rule: the nearest spot NOT inside any settlement / crime district.
bool outside_settlement(const hangover::Spot& s, void*) {
    const float p[3] = {s.nx, s.ny, s.nz};
    bool inside = true;
    if (!actions::in_settlement(p, &inside)) return false;
    return !inside;
}
DWORD g_immuneUntil = 0;
DWORD g_lastDoneAt = 0;       // when the last sequence finished (the grace window)
DWORD g_seqStartedAt = 0;
DWORD g_fallHeldUntil = 0;    // fall damage held off until then (0 = not scheduled)

const char* kind_name(Kind k) {
    switch (k) {
        case Kind::Death: return "death";
        case Kind::Knockdown: return "knockdown";
        case Kind::Execution: return "execution";
    }
    return "?";
}

bool want_guard() { return g_session.load() && g_enabled.load() && g_armed; }

// --- guard ------------------------------------------------------------------------
bool apply_guard(void* soul) {
    const int present = buffs::has(soul, g_guardGuid);
    if (present == 1) return true;
    uint64_t wuid = 0;
    if (buffs::add(soul, g_guardGuid, &wuid) && buffs::has(soul, g_guardGuid) != 0) {
        logf("MP-RESPAWN guard applied %s inst=0x%016llX", g_usingFallback ? "(fallback death_protection_cutscene)" : "(kcdmp_death_guard)",
             static_cast<unsigned long long>(wuid));
        return true;
    }
    if (!g_usingFallback) {
        const int def = buffs::definition_exists(g_modGuid);
        logf("MP-RESPAWN guard: the mod buff row did not apply (definition %s) -- FALLING BACK to death_protection_cutscene",
             def == 1 ? "present" : def == 0 ? "MISSING from the tables (pak row not loaded?)" : "unreadable");
        g_usingFallback = true;
        std::memcpy(g_guardGuid, g_fallbackGuid, 16);
        if (buffs::add(soul, g_guardGuid, &wuid) && buffs::has(soul, g_guardGuid) != 0) {
            logf("MP-RESPAWN guard applied (fallback) inst=0x%016llX", static_cast<unsigned long long>(wuid));
            return true;
        }
    }
    return false;
}

void remove_guard(void* soul, const char* why) {
    int n = soul ? buffs::remove_all(soul, g_guardGuid) : 0;
    // Both GUIDs: a fallback switch mid-session must not leave the other one on.
    if (soul) {
        const int m = buffs::remove_all(soul, g_usingFallback ? g_modGuid : g_fallbackGuid);
        if (m > 0) n += m;
    }
    logf("MP-RESPAWN guard removed (%s) removed=%d", why, n);
}

void update_guard(void* soul, DWORD now) {
    if (g_busy.load()) return;   // never strip protection mid-sequence
    if (!want_guard()) {
        if (g_applied) {
            // A soul that changed since the apply took its non-persistent buff
            // with it (a load); only the live soul needs the removal.
            remove_guard(soul, !g_session.load() ? "session off" : !g_enabled.load() ? "mp_respawn off" : "disarmed");
            g_applied = false;
            g_appliedSoul = nullptr;
        }
        return;
    }
    if (!soul) return;
    if (!g_applied || soul != g_appliedSoul) {
        if (g_applied && soul != g_appliedSoul)
            logf("MP-RESPAWN player soul changed %p -> %p (load) -- re-applying the guard", g_appliedSoul, soul);
        if (apply_guard(soul)) {
            g_applied = true;
            g_appliedSoul = soul;
            g_lastAssert = now;
        }
        return;
    }
    if (now - g_lastAssert >= kReassertMs) {
        g_lastAssert = now;
        const int present = buffs::has(soul, g_guardGuid);
        if (present == 0) {
            // A load (the usual cause: non-persistent buffs do not survive
            // one) or a script removing it. Graves are re-found by the world
            // sentinel in tick(), which also sees loads outside a session.
            logf("MP-RESPAWN guard missing (a load, or a script removed it) -- re-applying");
            apply_guard(soul);
        } else if (present < 0) {
            logf("MP-RESPAWN guard presence unreadable -- re-applying by remove+add");
            buffs::remove_all(soul, g_guardGuid);
            apply_guard(soul);
        }
    }
}

bool any_buff(void* soul, const char* const* list, size_t n, const char** which) {
    for (size_t i = 0; i < n; ++i) {
        unsigned char g[16];
        if (!buffs::parse_guid(list[i], g)) continue;
        if (buffs::has(soul, g) == 1) { if (which) *which = list[i]; return true; }
    }
    return false;
}

// --- classification -----------------------------------------------------------------
// "A weapon in hand": CombatSoul.HasMeleeWeapon || HasMissileWeapon. Observed
// on the player: sheathed -> both false (IsUnarmed true); sword drawn ->
// HasMeleeWeapon true (IsUnarmed false). Fists count as no weapon.
bool weapon_in_hand(void* soul, bool* armed) {
    bool melee = false, missile = false;
    if (!rttr::combat_bool(soul, "HasMeleeWeapon", &melee)) return false;
    if (!rttr::combat_bool(soul, "HasMissileWeapon", &missile)) return false;
    *armed = melee || missile;
    return true;
}

struct Scan {
    void* player = nullptr;
    float pos[3]{};
    int   recent = 0, hostiles = 0, armedHostiles = 0, unreadable = 0;
};

bool visit_soul(void* soul, void* ctx) {
    Scan* s = static_cast<Scan*>(ctx);
    if (soul == s->player) return false;
    float p[3];
    if (!rttr::soul_position(soul, p)) return false;
    if (p[0] == 0 && p[1] == 0 && p[2] == 0) return false;   // in the SoulList, not in the world
    const float dx = p[0] - s->pos[0], dy = p[1] - s->pos[1], dz = p[2] - s->pos[2];
    if (dx * dx + dy * dy + dz * dz > kHostileRadius * kHostileRadius) return false;
    bool recent = false, fight = false;
    if (!rttr::combat_history(s->player, soul, kRecentHitS, &recent) ||
        !rttr::combat_history(s->player, soul, kFightS, &fight)) { ++s->unreadable; return false; }
    if (!fight && !recent) return false;
    ++s->hostiles;
    if (recent) ++s->recent;
    bool armed = true;   // unreadable counts as armed: the conservative outcome is death
    if (!weapon_in_hand(soul, &armed)) { ++s->unreadable; armed = true; }
    if (armed) ++s->armedHostiles;
    return false;
}

double now_s() { LARGE_INTEGER q, f; QueryPerformanceCounter(&q); QueryPerformanceFrequency(&f); return double(q.QuadPart) / double(f.QuadPart); }
// WO-121: the last friendly-fire hit on the player (main thread).
double   g_pvpAt = -1e9;
bool     g_pvpUnarmed = false;
uint8_t  g_pvpFrom = 0;
constexpr double kPvpRecentS = 3.0;

Kind classify(void* soul, const float pos[3]) {
    Scan s{};
    s.player = soul;
    std::memcpy(s.pos, pos, sizeof(s.pos));
    rttr::for_each_soul(&visit_soul, &s);

    bool bleeding = false, starving = false, playerArmed = true;
    const bool rb = rttr::soul_bool(soul, "IsBleeding", &bleeding);
    const bool rs = rttr::soul_bool(soul, "IsStarving", &starving);
    const bool ra = weapon_in_hand(soul, &playerArmed);
    const char* poison = nullptr;
    const bool poisoned = any_buff(soul, kPoisons, sizeof(kPoisons) / sizeof(kPoisons[0]), &poison);

    const bool knockdown = s.recent > 0 && s.armedHostiles == 0 && ra && !playerArmed &&
                           rb && !bleeding && rs && !starving && !poisoned;
    // WO-121: a partner's fist floored him. The PvP hit carries no attacker
    // (so no combat history), so the recent-attacker clause can never hold for
    // it; the unarmed flag stands in for it. Bleeding/poison/starvation still
    // mean a real death.
    const double sincePvp = now_s() - g_pvpAt;
    const bool pvpFist = g_pvpUnarmed && sincePvp >= 0 && sincePvp <= kPvpRecentS && rb && !bleeding && rs && !starving && !poisoned;
    if (pvpFist && !knockdown) {
        logf("MP-RESPAWN classify -> knockdown: a friendly-fire FIST hit from ghost %u %.1f s ago (WO-121; no attacker is attached to PvP hits)",
             g_pvpFrom, sincePvp);
        return Kind::Knockdown;
    }
    logf("MP-RESPAWN classify -> %s: recent_attackers=%d hostiles=%d armed_hostiles=%d player_armed=%s "
         "bleeding=%s starving=%s poison=%s unreadable=%d (rule: knockdown only when a recent attacker exists, "
         "no hostile within %.0f m and not the player has a weapon in hand, and no bleeding/poison/starvation)",
         knockdown ? "knockdown" : "death", s.recent, s.hostiles, s.armedHostiles,
         ra ? (playerArmed ? "yes" : "no") : "unreadable",
         rb ? (bleeding ? "yes" : "no") : "unreadable",
         rs ? (starving ? "yes" : "no") : "unreadable",
         poisoned ? poison : "no", s.unreadable, kHostileRadius);
    return knockdown ? Kind::Knockdown : Kind::Death;
}

// --- executor ---------------------------------------------------------------------------
void clear_and_restore(void* soul, Kind k) {
    int cleared = 0;
    for (const char* t : kClearOnWake) {
        unsigned char g[16];
        if (!buffs::parse_guid(t, g)) continue;
        const int n = buffs::remove_all(soul, g);
        if (n > 0) cleared += n;
    }
    int added = 0;
    char notAdded[160]{};
    for (const char* t : kAddOnWake) {
        unsigned char g[16];
        if (buffs::parse_guid(t, g) && buffs::add(soul, g)) { ++added; continue; }
        // Instant/zero-duration cleaners may run and be gone before AddBuff
        // returns an instance; named so the log says which.
        strncat_s(notAdded, sizeof(notAdded), t, 8);
        strncat_s(notAdded, sizeof(notAdded), " ", 1);
    }
    if (notAdded[0]) logf("MP-RESPAWN cleaner buff(s) returned no instance (instant ones do): %s", notAdded);
    // Wound bleeding is not a buff: the game's own HealBleeding for every part.
    // Observed without it: the wound from the fatal hit kept bleeding after the
    // respawn and floored the player again.
    const bool healed = actions::heal_bleeding(soul);
    bool stillBleeding = false;
    const bool rb = rttr::soul_bool(soul, "IsBleeding", &stillBleeding);
    logf("MP-RESPAWN bleeding cure %s; IsBleeding now %s", healed ? "applied (parts 1-6)" : "UNAVAILABLE",
         rb ? (stillBleeding ? "YES" : "no") : "unreadable");
    const float hp = (k == Kind::Knockdown) ? kKnockdownHealth : kFullHealth;
    const bool okH = rttr::soul_set_state(soul, "health", hp);
    const bool okS = rttr::soul_set_state(soul, "stamina", kFullStamina);
    float hunger = 0;
    bool okF = true;
    if (rttr::soul_state(soul, "hunger", &hunger) && hunger < kMinHunger)
        okF = rttr::soul_set_state(soul, "hunger", kMinHunger);
    float h2 = 0, s2 = 0;
    rttr::soul_state(soul, "health", &h2);
    rttr::soul_state(soul, "stamina", &s2);
    logf("MP-RESPAWN restore kind=%s cleared_buffs=%d cleaners_added=%d/%zu health=%.1f(set %s) stamina=%.1f(set %s) hunger=%s",
         kind_name(k), cleared, added, sizeof(kAddOnWake) / sizeof(kAddOnWake[0]),
         h2, okH ? "ok" : "FAILED", s2, okS ? "ok" : "FAILED", okF ? "ok" : "set FAILED");
}

void start(Kind k, int gameOverId) {
    if (g_busy.exchange(true)) return;
    g_seqStartedAt = GetTickCount();
    g_x = Exec{};
    g_x.kind = k;
    g_x.gameOverId = gameOverId;
    g_x.t0 = GetTickCount();
    actions::player_position(g_x.deathPos);
    logf("MP-RESPAWN downed kind=%s at (%.1f, %.1f, %.1f)%s", kind_name(k),
         g_x.deathPos[0], g_x.deathPos[1], g_x.deathPos[2],
         gameOverId >= 0 ? " (from a swallowed Game Over)" : "");
    if (g_ev.downed) g_ev.downed(true, k);
    if (k == Kind::Knockdown && g_knockMode == KnockMode::GameKnockout) {
        // No fade of ours: the game's knockout presents itself, and while any
        // fader is up the game puts perk_player_fader_protection (upr=1) on
        // the player, which would refuse the knockout.
        g_x.phase = Phase::Act;
        return;
    }
    const bool faded = actions::fade_out(kFadeOutS);
    if (!faded) logf("MP-RESPAWN fade-out unavailable -- continuing without it");
    g_x.phase = Phase::FadeOut;
}

// --- the knockdown: the game's own knockout, then a wake where they fell ----------------
bool add_ko_guard(void* soul) {
    uint64_t w = 0;
    if (buffs::add(soul, g_koGuid, &w) && buffs::has(soul, g_koGuid) == 1) return true;
    if (std::memcmp(g_koGuid, g_koFallbackGuid, 16) != 0) {
        logf("MP-RESPAWN knockout guard: the mod row (kcdmp_knockout_guard) did not apply -- falling back to "
             "player_immortalityOnly_nonPersistent");
        std::memcpy(g_koGuid, g_koFallbackGuid, 16);
        if (buffs::add(soul, g_koGuid, &w) && buffs::has(soul, g_koGuid) == 1) return true;
    }
    return false;
}

void wake_up(void* soul, const char* why) {
    const DWORD now = GetTickCount();
    if (soul) {
        clear_and_restore(soul, Kind::Knockdown);        // unconscious off, remove_unconsciousness, 30 hp
        // The full guard back on before the knockdown guard comes off: never a
        // moment unprotected.
        const bool back = apply_guard(soul);
        const int off = buffs::remove_all(soul, g_koGuid);
        if (g_koContextSet) {
            const int c = sctx::set_soul_context(soul, kNoShenanigans, false);
            logf("MP-RESPAWN knockdown: %s cleared %s", kNoShenanigans, c == 1 ? "(verified)" : "(FAILED -- still set)");
            g_koContextSet = false;
        }
        bool unc = false;
        const bool ru = rttr::soul_bool(soul, "IsUnconscious", &unc);
        logf("MP-RESPAWN knockdown: woke where they fell after %lu ms (%s); death guard %s, knockout guard removed=%d, "
             "IsUnconscious now %s", static_cast<unsigned long>(now - g_x.t0), why, back ? "back" : "NOT back", off,
             ru ? (unc ? "YES" : "no") : "unreadable");
    }
    // The game resolved the fight while the player was down; the exclusion is
    // a short second net for NPCs that come back to it.
    const bool ex = actions::exclude_from_targeting(true);
    g_immuneUntil = now + kKnockdownImmuneMs;
    logf("MP-RESPAWN knockdown: targeting exclusion %s for %lu ms", ex ? "ON" : "UNAVAILABLE",
         static_cast<unsigned long>(kKnockdownImmuneMs));
    g_x.haveWake = false;
    g_x.phase = Phase::FadeIn;                            // "done": events, no fade to undo
}

void knock_out(void* soul) {
    const DWORD now = GetTickCount();
    g_x.t0 = now;
    g_x.koSeen = false;
    // 1. Immortal-only guard on, full guard (upr=1) off.
    if (!add_ko_guard(soul)) {
        logf("MP-RESPAWN knockdown: no immortal-only guard applied -- NO knockout, waking in place (the fight may go on)");
        wake_up(soul, "no knockout guard");
        return;
    }
    const int dropped = buffs::remove_all(soul, g_guardGuid);
    // 2. Nobody robs the knocked-out player (what the fist-fight quests set).
    const int ctx = sctx::set_soul_context(soul, kNoShenanigans, true);
    g_koContextSet = (ctx == 1);
    // 3. The game's own knockout.
    uint64_t w = 0;
    const bool ko = buffs::add(soul, g_unconsciousGuid, &w);
    logf("MP-RESPAWN knockdown: death guard off (%d), knockout guard on, %s %s, unconscious_nonpersistend %s -- "
         "holding up to %lu ms", dropped, kNoShenanigans,
         ctx == 1 ? "set" : ctx == 0 ? "already set" : "NOT available", ko ? "added" : "NOT added",
         static_cast<unsigned long>(kKnockoutMs));
    actions::hud_message("You were knocked out.");
    g_x.phase = Phase::KnockedOut;
}

// The shipped knockdown: restore, end the fight with the game's own
// StopFight, a short targeting exclusion, and wake where the player fell.
void disengage(void* soul) {
    clear_and_restore(soul, Kind::Knockdown);
    const bool stopped = actions::stop_fight(buffs::as_c_soul(soul));
    const bool ex = actions::exclude_from_targeting(true);
    g_immuneUntil = GetTickCount() + kKnockdownImmuneMs;
    logf("MP-RESPAWN knockdown: wake in place; StopFight %s; targeting exclusion %s for %lu ms",
         stopped ? "sent to the player's skirmish" : (actions::stop_fight_available() ? "FAULTED" : "NOT armed"),
         ex ? "ON" : "UNAVAILABLE", static_cast<unsigned long>(kKnockdownImmuneMs));
    actions::hud_message("You were knocked out.");
    g_x.haveWake = false;
    g_x.phase = Phase::Settle;
    g_x.t0 = GetTickCount();
    g_x.actAt = g_x.t0;
}

void step_knocked_out(DWORD now) {
    void* soul = rttr::read_player_soul();
    bool unc = false;
    const bool r = soul && rttr::soul_bool(soul, "IsUnconscious", &unc);
    if (r && unc && !g_x.koSeen) {
        g_x.koSeen = true;
        logf("MP-RESPAWN knockdown: the player is unconscious (%lu ms after the knockout)",
             static_cast<unsigned long>(now - g_x.t0));
    }
    const DWORD t = now - g_x.t0;
    if (t >= kKnockoutMs) { wake_up(soul, "knockout time"); return; }
    if (g_x.koSeen && r && !unc && t >= kKnockoutMinMs) { wake_up(soul, "the game woke the player"); return; }
    if (!g_x.koSeen && t >= kKnockoutTakeMs) { wake_up(soul, "the unconscious state never showed -- fallback"); return; }
}

void step_act() {
    void* soul = rttr::read_player_soul();
    if (!soul) { logf("MP-RESPAWN act: player soul unreadable -- abandoning the sequence"); g_x.phase = Phase::FadeIn; return; }
    const Kind k = g_x.kind;
    if (k == Kind::Knockdown) {
        if (g_knockMode == KnockMode::GameKnockout) { knock_out(soul); return; }
        disengage(soul);
        return;
    }

    bool graveMade = false;
    if (k == Kind::Death || k == Kind::Execution) {
        const actions::GraveReport gr = actions::make_grave(soul, g_x.deathPos[0], g_x.deathPos[1], g_x.deathPos[2]);
        graveMade = gr.ok;
        if (gr.ok) {
            logf("MP-RESPAWN grave id=0x%016llX at (%.1f, %.1f, %.1f) moved=%d quest_kept=%d refused=%d money=%s model=%s marker=%s",
                 static_cast<unsigned long long>(gr.id), gr.x, gr.y, gr.z, gr.moved, gr.keptQuest, gr.failed,
                 gr.money ? "yes" : "no", gr.model ? "yes" : "no", gr.marker ? "yes" : "no");
            if (g_ev.grave_add) g_ev.grave_add(gr.id, gr.x, gr.y, gr.z);
        } else if (gr.nothingToBury) {
            logf("MP-RESPAWN no grave: the player carried nothing to bury");
        } else {
            logf("MP-RESPAWN grave NOT made (grave piece not armed or spawn failed) -- the player keeps their items");
        }
    }

    if (k == Kind::Execution) {
        const bool rec = actions::reconcile_with_public_friends(soul);
        logf("MP-RESPAWN execution: ReconcileWithPublicFriends %s", rec ? "ran" : "NOT available -- the crime stands");
        // The punishment gameplay never reaches its own punishmentdone after an
        // execution (vanilla reloads instead): end it the way it ends itself.
        bool was = false;
        const bool ended = punishment::reset(&was);
        logf("MP-RESPAWN execution: punishment gameplay %s",
             !punishment::available() ? "reset NOT armed -- disabledEvents left as it is"
             : !ended                 ? "reset FAILED -- see MP-PUNISH"
             : was                    ? "ended (disabledEvents true -> false)"
                                      : "was not running (disabledEvents already false)");
    }

    clear_and_restore(soul, k);

    {
        const float* d = g_x.deathPos;
        const hangover::Spot* spot = nullptr;
        const char* rule = "nearest";
        if (k == Kind::Execution) {
            // "Respawn outside that settlement": the nearest spot the game's
            // own area-label test puts outside every settlement/crime district;
            // failing that, the nearest one kExecutionMinDist away.
            spot = hangover::nearest_where(d[0], d[1], d[2], &outside_settlement, nullptr);
            rule = "nearest outside a settlement (area labels)";
            if (!spot) {
                spot = hangover::nearest(d[0], d[1], d[2], kExecutionMinDist, d[0], d[1]);
                rule = "nearest beyond the execution-distance fallback";
            }
        }
        if (!spot && k == Kind::Death) {
            spot = hangover::nearest(d[0], d[1], d[2], kDeathMinDist, d[0], d[1]);
            if (spot) rule = "nearest at least 100 m from the death";
        }
        if (!spot) spot = hangover::nearest(d[0], d[1], d[2]);
        if (spot) {
            g_x.wakePos[0] = spot->nx; g_x.wakePos[1] = spot->ny; g_x.wakePos[2] = spot->nz;
            g_x.haveWake = true;
            const float dx = spot->nx - d[0], dy = spot->ny - d[1];
            // Observed: after a hit, a teleport to a lower spot landed as a
            // fatal fall (19 m drop -> floored 0.8 s later); with the game's
            // own fall-damage switch held it did not. Held until kFallHoldMs
            // after the wake, then the previous value is given back.
            const bool fall = actions::suppress_fall_damage(true);
            g_fallHeldUntil = 0;
            logf("MP-RESPAWN fall damage %s for the wake teleport (drop %.1f m)",
                 fall ? "held off" : "switch UNAVAILABLE", d[2] - spot->nz);
            const bool tp = actions::teleport_to_spot(spot->wuid);
            logf("MP-RESPAWN wake spot \"%s\" (%s) at (%.1f, %.1f, %.1f) %.0f m away -- ExecuteTeleportImpl %s",
                 spot->name, rule, spot->nx, spot->ny, spot->nz, std::sqrt(dx * dx + dy * dy),
                 tp ? "requested" : "UNAVAILABLE (the goto-shaped fallback follows)");
        } else {
            logf("MP-RESPAWN NO usable hangoverSpot found -- waking at the death spot (fallback, loud)");
        }
    }
    if (graveMade) actions::hud_message(k == Kind::Execution ? "You were executed. Your belongings lie in your grave."
                                                                  : "You died. Your belongings lie in your grave.");
    else actions::hud_message(k == Kind::Execution ? "You were executed." : "You died.");
    g_x.phase = Phase::Settle;
    g_x.t0 = GetTickCount();
    g_x.actAt = g_x.t0;
}

void step_executor(DWORD now) {
    switch (g_x.phase) {
        case Phase::Idle: return;
        case Phase::FadeOut:
            if (actions::fade_is_black() || now - g_x.t0 > kFadeTimeoutMs) {
                g_x.phase = Phase::Act;
                step_act();
            }
            return;
        case Phase::Act:
            step_act();
            return;
        case Phase::KnockedOut:
            step_knocked_out(now);
            return;
        case Phase::Settle:
            if (now - g_x.t0 >= kSettleMs) {
                // Did the spot's own teleport land? If not (the game declined
                // it, e.g. a quest context disabling blackout teleports), move
                // the player the goto way once and settle again.
                if (g_x.haveWake && !g_x.fallbackDone) {
                    float p[3]{};
                    const bool have = actions::player_position(p);
                    const float dx = p[0] - g_x.wakePos[0], dy = p[1] - g_x.wakePos[1];
                    const float off = std::sqrt(dx * dx + dy * dy);
                    if (!have || off > 5.0f) {
                        g_x.fallbackDone = true;
                        const bool ok = actions::teleport_player(g_x.wakePos[0], g_x.wakePos[1], g_x.wakePos[2]);
                        logf("MP-RESPAWN the spot teleport left the player %.1f m off the spot -- goto-shaped fallback %s",
                             have ? off : -1.0f, ok ? "applied" : "FAILED (the player stays where they are)");
                        g_x.t0 = now;
                        return;
                    }
                    logf("MP-RESPAWN at the wake spot (%.1f m off) -- ground re-snap %s", off,
                         actions::resnap_player() ? "ran" : "unavailable");
                }
                g_x.phase = Phase::Hold;
            }
            return;
        case Phase::Hold:
            if (now - g_x.actAt >= kBlackHoldMs) {
                actions::fade_in(kFadeInS);
                g_x.phase = Phase::FadeIn;
                g_x.t0 = now;
            }
            return;
        case Phase::FadeIn: {
            float p[3]{};
            if (!actions::player_position(p)) std::memcpy(p, g_x.haveWake ? g_x.wakePos : g_x.deathPos, sizeof(p));
            logf("MP-RESPAWN done kind=%s now at (%.1f, %.1f, %.1f) after %lu ms", kind_name(g_x.kind),
                 p[0], p[1], p[2], static_cast<unsigned long>(now - g_seqStartedAt));
            if (g_ev.downed) g_ev.downed(false, g_x.kind);
            if (g_ev.respawned) g_ev.respawned(p[0], p[1], p[2], g_x.kind);
            {
                // The killer may still be near and still angry (NPCs do not
                // forget a fight): a short window to walk away, counted from
                // the wake -- not from the act, which the black hold follows.
                const bool ex = actions::exclude_from_targeting(true);
                g_immuneUntil = now + kKnockdownImmuneMs;
                logf("MP-RESPAWN targeting exclusion %s for %lu ms after the wake", ex ? "ON" : "UNAVAILABLE",
                     static_cast<unsigned long>(kKnockdownImmuneMs));
            }
            g_x.phase = Phase::Idle;
            g_floorHits = 0;
            // The grace covers a respawn's tail (a wake-spot hazard, a late
            // wound). A knockdown that floors again is a new knockdown.
            if (g_x.kind != Kind::Knockdown) g_lastDoneAt = now;
            if (g_x.haveWake) g_fallHeldUntil = now + kFallHoldMs;
            g_busy.store(false);
            return;
        }
    }
}

// --- the Game Over policy (C2) -------------------------------------------------------------
bool player_alive_now() {
    void* soul = rttr::read_player_soul();
    if (!soul) return false;
    bool dead = true;
    if (!rttr::soul_bool(soul, "IsDead", &dead)) return false;   // unreadable: treat as not alive -> pass through
    return !dead;
}

bool policy(int id) {
    if (!(g_session.load() && g_enabled.load())) return false;
    const bool deathShaped = (id >= 0 && id <= 8) || id == 26;
    const bool execution = (id == 44);
    if (!deathShaped && !execution) return false;
    if (deathShaped && !player_alive_now()) return false;   // a real death: vanilla (revive is refused anyway)
    if (g_busy.load()) return true;                          // already handling this downing
    g_pendingGameOver.store(id);
    return true;
}

// --- opt-in test trigger ---------------------------------------------------------------------
// kcdmp-respawn-test.txt in the game's working directory (the WO-68/WO-99.5
// probe convention: the coding shell can write there). Re-read once a second;
// a command runs once per content change. Absent file = idle.
//   gameover <id>   call I_GameOver::Start(id) through its vtable -- i.e. through
//                   the C2 guard, exactly as the game's own death path would
//   spots           re-walk the hangoverSpots and log the nearest three
//   hud <text>      one HUD game-log line
char  g_testLast[256]{};
DWORD g_testCheckedAt = 0;

void run_test_command(const char* line) {
    int id = -1;
    char text[200]{};
    float sx = 0, sy = 0, sz = 0;
    if (std::sscanf(line, "gameover %d", &id) == 1) {
        void* gi = engine::game_iface(); void* pm = nullptr; void* go = nullptr;
        void* vt = nullptr; void* start = nullptr;
        bool ok = false;
        __try {
            pm = gi ? *reinterpret_cast<void**>(static_cast<char*>(gi) + 0x130) : nullptr;
            if (pm) go = reinterpret_cast<void* (*)(void*)>((*reinterpret_cast<void***>(pm))[0xA8 / 8])(pm);
            if (go) { vt = *reinterpret_cast<void**>(go); start = reinterpret_cast<void**>(vt)[1]; }
            if (start) { reinterpret_cast<void (*)(void*, int)>(start)(go, id); ok = true; }
        } __except (EXCEPTION_EXECUTE_HANDLER) { ok = false; }
        logf("MP-RESPAWN-TEST gameover %d -> I_GameOver %p slot1 %p (%s) %s", id, go, start,
             gameover::installed() ? "guarded" : "UNGUARDED", ok ? "called" : "NOT called (fault or unresolved)");
    } else if (std::strncmp(line, "spots", 5) == 0) {
        const hangover::Spot* list = nullptr;
        const int n = hangover::spots(&list, true);
        float p[3]{};
        actions::player_position(p);
        const hangover::Spot* s = hangover::nearest(p[0], p[1], p[2]);
        logf("MP-RESPAWN-TEST spots=%d nearest=%s at (%.1f, %.1f, %.1f) from (%.1f, %.1f, %.1f)", n,
             s ? s->name : "none", s ? s->nx : 0, s ? s->ny : 0, s ? s->nz : 0, p[0], p[1], p[2]);
    } else if (std::sscanf(line, "hud %199[^\r\n]", text) == 1) {
        logf("MP-RESPAWN-TEST hud \"%s\" -> %s", text, actions::hud_message(text) ? "logged" : "NOT available");
    } else if (std::sscanf(line, "gravemodel %199s", text) == 1) {
        actions::set_grave_model(text);
    } else if (std::sscanf(line, "snaptest %f %f %f", &sx, &sy, &sz) == 3) {
        const float in[3] = {sx, sy, sz};
        float out[3]{};
        const bool ok = hangover::snap_to_ground(in, out);
        logf("MP-RESPAWN-TEST snaptest (%.2f, %.2f, %.2f) -> %s (%.2f, %.2f, %.2f)", sx, sy, sz,
             ok ? "ground" : "NO ground", out[0], out[1], out[2]);
    } else if (std::strncmp(line, "knockmode ", 10) == 0) {
        const char* m = line + 10;
        if (std::strncmp(m, "knockout", 8) == 0) g_knockMode = KnockMode::GameKnockout;
        else if (std::strncmp(m, "disengage", 9) == 0) g_knockMode = KnockMode::Disengage;
        logf("MP-RESPAWN-TEST knockmode -> %s", g_knockMode == KnockMode::Disengage ? "disengage (StopFight)" : "game knockout");
    } else if (std::strncmp(line, "mapdump", 7) == 0) {
        actions::map_dump();
    } else if (std::sscanf(line, "marktype %i", &id) == 1) {
        actions::set_mark_type(id);
        actions::map_dump();
    } else if (std::strncmp(line, "classprobe ", 11) == 0) {
        // Which entity classes a runtime spawn gives a WUID and an AI
        // linkable object (what a map mark needs): spawn, report, remove.
        char cls[64]{};
        const char* p = line + 11;
        while (*p) {
            while (*p == ' ') ++p;
            size_t n = 0;
            while (p[n] && p[n] != ' ' && n + 1 < sizeof(cls)) { cls[n] = p[n]; ++n; }
            cls[n] = 0;
            if (!n) break;
            actions::class_probe(cls);
            p += n;
        }
    } else if (std::strncmp(line, "punish ", 7) == 0) {
        // Synthetic stand-in for a running punishment: `punish set` fires the
        // State's SetTrue (what triggersequence15.C does), `punish reset` runs
        // the production reset, `punish read` reads the State.
        const char* arg = line + 7;
        bool v = false;
        if (std::strncmp(arg, "set", 3) == 0)
            logf("MP-RESPAWN-TEST punish set -> %s", punishment::test_set_true() ? "State true" : "FAILED");
        else if (std::strncmp(arg, "reset", 5) == 0)
            logf("MP-RESPAWN-TEST punish reset -> %s", punishment::reset(&v) ? (v ? "ended (was true)" : "nothing to end") : "FAILED");
        else if (std::strncmp(arg, "read", 4) == 0)
            logf("MP-RESPAWN-TEST punish read -> %s", punishment::in_punishment(&v) ? (v ? "true" : "false") : "UNREADABLE");
        else
            logf("MP-RESPAWN-TEST punish: expected set | reset | read");
    } else {
        logf("MP-RESPAWN-TEST unknown command \"%s\" (gameover <id> | spots | hud <text> | punish set|reset|read)", line);
    }
}

void test_watch(DWORD now) {
    if (now - g_testCheckedAt < 1000) return;
    g_testCheckedAt = now;
    char cwd[MAX_PATH]{}, path[MAX_PATH]{};
    if (!GetCurrentDirectoryA(MAX_PATH, cwd) || !cwd[0]) return;
    _snprintf_s(path, sizeof(path), _TRUNCATE, "%s%skcdmp-respawn-test.txt", cwd,
                (cwd[std::strlen(cwd) - 1] == '\\') ? "" : "\\");
    char text[256]{};
    FILE* f = nullptr;
    if (fopen_s(&f, path, "r") == 0 && f) {
        const size_t n = std::fread(text, 1, sizeof(text) - 1, f);
        text[n] = 0;
        std::fclose(f);
    }
    if (std::strcmp(text, g_testLast) == 0) return;
    std::strcpy(g_testLast, text);
    if (!text[0]) return;
    char* nl = std::strpbrk(text, "\r\n");
    if (nl) *nl = 0;
    run_test_command(text);
}

} // namespace

void set_events(const Events& e) { g_ev = e; }

void set_session(bool on, const char* why) {
    const bool was = g_session.exchange(on);
    if (was != on) logf("MP-RESPAWN session %s (%s)", on ? "ON" : "OFF", why ? why : "");
}
bool session_active() { return g_session.load(); }

void set_enabled(bool on, const char* why) {
    const bool was = g_enabled.exchange(on);
    logf("MP-RESPAWN mp_respawn %s (was %s) via %s", on ? "on" : "off", was ? "on" : "off", why ? why : "?");
}
bool enabled() { return g_enabled.load(); }
bool guard_applied() { return g_applied; }

void install() {
    if (g_installed) return;
    g_installed = true;
    buffs::parse_guid(kGuardGuidText, g_modGuid);
    buffs::parse_guid(kFallbackGuidText, g_fallbackGuid);
    buffs::parse_guid(kKoGuardGuidText, g_koGuid);
    buffs::parse_guid(kKoGuardFallback, g_koFallbackGuid);
    buffs::parse_guid(kUnconsciousNp, g_unconsciousGuid);
    std::memcpy(g_guardGuid, g_modGuid, 16);

    g_armed = buffs::resolve();
    const bool c2 = gameover::install();
    gameover::set_policy(&policy);
    const bool spots = hangover::resolve();
    actions::resolve();
    const bool punish = punishment::resolve();
    logf("WO113-BUILD respawn=%s guard=%s c2=%s spots=%s fade=%s teleport=%s graves=%s reconcile=%s settlement_test=%s "
         "punishment_reset=%s knockdown=%s stop_fight=%s floor=%.1f knockdown_hp=%.0f "
         "hostile_radius_m=%.0f recent_hit_s=%.0f expiry_game_days=3 -- guard only in a session",
         g_enabled.load() ? "on" : "off", g_armed ? "armed" : "NOT-ARMED", c2 ? "installed" : "NOT-INSTALLED",
         spots ? "on" : "OFF", actions::fade_available() ? "on" : "OFF", actions::teleport_available() ? "on" : "OFF",
         actions::graves_available() ? "on" : "OFF", actions::reconcile_available() ? "on" : "OFF",
         actions::area_available() ? "on" : "OFF", punish ? "on" : "OFF",
         g_knockMode == KnockMode::Disengage ? "disengage" : "game-knockout",
         actions::stop_fight_available() ? "on" : "OFF",
         kFloor, kKnockdownHealth, kHostileRadius, kRecentHitS);
}

void tick() {
    if (!g_installed) return;
    const DWORD now = GetTickCount();
    test_watch(now);

    // A Game Over the guard swallowed: start its respawn on this (main) thread.
    const int go = g_pendingGameOver.exchange(-1);
    if (go >= 0 && !g_busy.load()) start(go == 44 ? Kind::Execution : Kind::Death, go);

    if (g_busy.load()) { step_executor(now); return; }

    if (g_immuneUntil && now >= g_immuneUntil) {
        g_immuneUntil = 0;
        actions::exclude_from_targeting(false);
        logf("MP-RESPAWN targeting exclusion OFF");
    }
    if (g_fallHeldUntil && now >= g_fallHeldUntil) {
        g_fallHeldUntil = 0;
        logf("MP-RESPAWN fall damage given back (%s)", actions::suppress_fall_damage(false) ? "previous value restored" : "restore FAILED");
    }

    if (now - g_lastSample < kSampleMs) return;
    g_lastSample = now;

    // A load or level change replaces the world: this player's graves are
    // re-found by name and their markers re-added, session or not (observed:
    // with the session off nothing else noticed a load). Graves the new world
    // no longer holds are dropped at the peers too.
    {
        uint64_t gone[16];
        int nGone = 0;
        actions::world_check(gone, 16, &nGone);
        for (int i = 0; i < nGone; ++i) if (g_ev.grave_remove) g_ev.grave_remove(gone[i]);
    }

    void* soul = rttr::read_player_soul();
    update_guard(soul, now);

    // Graves are this player's own objects: kept up whether or not a session
    // is live (looted empty -> removed; past 3 game days -> removed).
    if (soul && now - g_lastMaintain >= kMaintainMs) {
        g_lastMaintain = now;
        uint64_t removed[16];
        const int n = actions::graves_maintain(removed, 16);
        for (int i = 0; i < n; ++i) if (g_ev.grave_remove) g_ev.grave_remove(removed[i]);
    }

    if (!g_applied || !soul) { g_floorHits = 0; return; }

    float hp = 0;
    if (!rttr::soul_state(soul, "health", &hp)) return;
    bool dead = false;
    if (rttr::soul_bool(soul, "IsDead", &dead) && dead) {
        if (!g_deadLogged) {
            g_deadLogged = true;
            logf("MP-RESPAWN the player is DEAD with the guard applied -- the guard did not hold; vanilla death follows");
        }
        return;
    }
    g_deadLogged = false;
    if (hp > kFloor + kFloorEpsilon) { g_floorHits = 0; g_standDownLogged = false; return; }
    if (++g_floorHits < kFloorConfirm) return;

    const char* questBuff = nullptr;
    if (any_buff(soul, kQuestImmortality, sizeof(kQuestImmortality) / sizeof(kQuestImmortality[0]), &questBuff)) {
        if (!g_standDownLogged) {
            g_standDownLogged = true;
            logf("MP-RESPAWN at the floor but a quest immortality buff %s is on the player -- standing down (the quest owns this)",
                 questBuff);
        }
        return;
    }

    if (g_lastDoneAt && now - g_lastDoneAt < kGraceMs) {
        logf("MP-RESPAWN floored again %lu ms after a respawn (inside the %lu ms grace) -- restoring only, no grave, no teleport",
             static_cast<unsigned long>(now - g_lastDoneAt), static_cast<unsigned long>(kGraceMs));
        clear_and_restore(soul, Kind::Death);
        g_floorHits = 0;
        // Not re-armed: the grace is 10 s from the completed respawn, so a
        // hazard cannot make the player permanently unkillable.
        return;
    }

    float pos[3]{};
    actions::player_position(pos);
    start(classify(soul, pos), -1);
}

void note_pvp_hit(bool unarmed, uint8_t attackerGhost) {
    g_pvpAt = now_s();
    g_pvpUnarmed = unarmed;
    g_pvpFrom = attackerGhost;
}

} // namespace kcdmp::respawn
