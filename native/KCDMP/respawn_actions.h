#pragma once
// WO-113: the engine actions the respawn executor needs, each resolved by
// anchor and each failing closed on its own. respawn.cpp owns the policy; this
// owns the calls.
//
// Every function is main-thread only and returns false (never faults) when its
// piece did not resolve on this build; the executor logs that and carries on
// with the rest (a respawn without a fade is still a respawn).

#include <cstdint>

namespace kcdmp::actions {

// Resolve every piece once (idempotent). Logs one line per piece:
// armed / NOT armed and why.
void resolve();

// --- presentation -----------------------------------------------------------
bool fade_available();
bool fade_out(float seconds);
bool fade_in(float seconds);
// True once the screen is fully black (or when no fader is available, so the
// executor never waits on a fade that cannot happen).
bool fade_is_black();

// --- player -----------------------------------------------------------------
bool player_position(float out[3]);
bool teleport_available();
// The game's own blackout wake-up teleport to a hangoverSpot (C_Player
// slot 0xEE0 -> ExecuteTeleportImpl: XGenAI teleport with a physics reset, the
// spot's authored transform). The caller checks the player actually moved.
bool teleport_to_spot(uint64_t spotWuid);
// Fallback: the `goto` shape (entity SetPos, why 0) plus the ground re-snap.
bool teleport_player(float x, float y, float z);
// C_Actor ground re-snap (+-1.75 m ray correction).
bool resnap_player();

// wh_rpg_ExcludePlayerFromTargeting for the knockdown wake-up.
bool exclude_from_targeting(bool on);

// The game's own StopFight for the skirmish the player is in (what quests
// use to end a fight): every soul of that skirmish is told to stop.
bool stop_fight_available();
// WO-121: the anchored wh::rpgmodule::StopFight itself (hits.cpp reads its
// skirmish-manager getter out of it); null when not armed.
const void* stop_fight_fn();
bool stop_fight(void* playerSoul);

// wh_rpg_DisablePlayerFallDamage while the wake teleport lands. Observed: a
// hit reaction arms the fall tracker, and a teleport to a lower spot then
// lands as a fatal fall ~0.8 s later. Off gives back the value from before.
bool suppress_fall_damage(bool on);

// Stop wound bleeding: the game's own HealBleeding(1, part) for parts 1..6.
bool heal_bleeding(void* playerSoul);

// --- world clock --------------------------------------------------------------
// Game-world seconds (Calendar world time). False when unreadable.
bool world_time(double* out);

// --- graves -------------------------------------------------------------------
bool graves_available();

struct GraveReport {
    bool     ok = false;
    uint64_t id = 0;
    float    x = 0, y = 0, z = 0;
    int      moved = 0;         // item stacks moved into the grave
    int      keptQuest = 0;     // quest items left with the player
    int      failed = 0;        // items the move refused
    bool     money = false;     // money moved
    bool     model = false;     // gravestone model attached
    bool     marker = false;    // map marker placed
    bool     nothingToBury = false;   // not made: the player carried nothing movable
};

// Spawn a grave at (x,y,z) and move everything except quest items into it.
GraveReport make_grave(void* playerSoul, float x, float y, float z);

// Periodic: graves emptied by looting are removed, graves past their expiry
// (3 in-game days) are removed with their contents. `removed` receives the ids
// removed this call (up to `max`); returns how many.
int graves_maintain(uint64_t* removed, int max);

// Every grave this player still owns (for the on-connect re-announce).
struct GraveInfo { uint64_t id; float x, y, z; };
int graves_list(GraveInfo* out, int max);

// A save was loaded: re-find this player's graves by name, re-add their map
// markers (the game does not save entity marks), forget NO_SAVE mirrors.
void on_world_changed();

// Every sample, session or not: a NO_SAVE sentinel entity is purged by any
// load or level change (observed for a NO_SAVE mirror). When it is gone,
// on_world_changed() runs and a new sentinel is spawned. True on a change.
// `vanished` receives the ids of graves the new world no longer holds (for
// GraveRemove to peers); `*nVanished` their count.
bool world_check(uint64_t* vanished, int max, int* nVanished);

// Test only: spawn one NO_SAVE entity of `cls` beside the player, log whether
// it got a WUID and an AI linkable object (what a map mark needs), remove it.
void class_probe(const char* cls);

// Test only: log the map's enabled mark categories and every mark in it; and
// re-make this player's grave/mirror marks with another mark type.
void map_dump();
void set_mark_type(int type);
// Test only: the gravestone model for new graves, re-loaded on every current
// grave and mirror.
void set_grave_model(const char* path);

// Peer mirrors: a gravestone + marker only, never lootable, never saved.
bool mirror_add(uint8_t owner, uint64_t id, float x, float y, float z);
bool mirror_remove(uint8_t owner, uint64_t id);
int  mirror_clear(uint8_t owner);   // 0xFF = every owner

// --- crime (execution) ----------------------------------------------------------
bool reconcile_available();
// What a completed vanilla punishment runs: the player is reconciled with the
// town (branded, not wanted).
bool reconcile_with_public_friends(void* playerSoul);

// Is `pos` inside an area labelled "settlement" or "crimeDistrict" (the
// game's own area-label test)? False when the test is not armed.
bool area_available();
bool in_settlement(const float pos[3], bool* inside);

// One line in the HUD game log (what Lua Game.LogGameEvent does).
bool hud_message(const char* text);

// WO-118: an entity's XGenAI WUID (GUID -> WUID service, the way XGenAI's own
// GetMyWUID resolves it -- the grave marker's route). 0 when unavailable.
uint64_t entity_wuid(void* ent);

} // namespace kcdmp::actions
