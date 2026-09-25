#pragma once
// WO-113: death without Game Over, natively (WO-111's C1 + C2).
//
//   guard      a non-persistent, mod-owned death-protection buff (imm=1,upr=1)
//              on the player while a multiplayer session is live and
//              `mp_respawn` is on; C_Soul::SetSoulState then floors every
//              health loss at ImmortalHealthMin (1.0) before a death can be
//              decided (WO-111 s3.2)
//   detector   player health at the floor, debounced -> DOWNED
//   classifier knockdown (a fistfight loss: no grave, wake in place) or death
//              (grave + respawn at the nearest blackout wake-up spot)
//   executor   fade out, act, fade in -- one main-thread state machine
//   C2         the I_GameOver::Start guard (gameover_hook.h) asks policy()
//
// Off (toggle off, or no session) is vanilla, exactly: the buff is removed and
// the Game Over guard passes every call through unchanged.
//
// Main thread for everything except policy() (whatever thread starts a Game
// Over) and the setters (atomic).

#include <cstdint>

namespace kcdmp::respawn {

enum class Kind : uint8_t { Death = 0, Knockdown = 1, Execution = 2 };

// Outbound events, wired to pipe frames by pipe_server.cpp.
struct Events {
    void (*downed)(bool on, Kind kind) = nullptr;
    void (*respawned)(float x, float y, float z, Kind reason) = nullptr;
    void (*grave_add)(uint64_t id, float x, float y, float z) = nullptr;
    void (*grave_remove)(uint64_t id) = nullptr;
};
void set_events(const Events& e);

// After the RTTR walk, on the main thread: resolve anchors, install the Game
// Over guard, register the console command, log WO113-BUILD.
void install();

// Every frame (main thread). Rate-limits itself.
void tick();

// The agent says whether a multiplayer session is live (relay connected).
// The pipe dropping clears it.
void set_session(bool on, const char* why);
bool session_active();

// mp_respawn on/off. Default on.
void set_enabled(bool on, const char* why);
bool enabled();

// Is the guard (buff) currently applied to the player?
bool guard_applied();

// WO-121: a partner's friendly-fire hit just landed on the player (main
// thread). `unarmed`: it was a fist. A downing within kPvpRecentS of an
// unarmed PvP hit is a KNOCKDOWN even with no attacker attached (the PvP hit
// deliberately carries none -- naming one is what starts fights), unless the
// player is bleeding, poisoned or starving.
void note_pvp_hit(bool unarmed, uint8_t attackerGhost);

} // namespace kcdmp::respawn
