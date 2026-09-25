#pragma once
// WO-121 Phases 5 and 6 -- hits that carry an attacker (NPCs fight back) and
// friendly fire.
//
// The chokepoint (WO-119 s2.3, corrected live in WO-121 session 1): every
// melee hit passes C_CombatSoul vtable slot 0x150 (missiles: 0x158), called on
// the ATTACKER's combat soul with S_CombatHitData: +0x00 attacker WUID, +0x08
// attacker entity id, +0x10 victim WUID, +0x18 victim entity id, +0x40 the hit
// position. Both slots are vtable-patched here (RTTI C_CombatSoul, RPGModule).
//
//   * victim = a peer's avatar (registered by motion.cpp): the original runs
//     -- skipping it returns an empty cause and CRASHED the game 0.6 s later
//     (observed, session 1) -- and its health/stamina are read before and
//     after and put straight back, so the local hit never lands on the
//     avatar. With friendly fire on, the difference goes to the peer (pipe
//     frame 0x97 -> PlayerHit 0x44). Belt and braces: every avatar also holds
//     kcdmp_avatar_guard (imm+upr), so it can never die or be knocked out here.
//   * attacker = the local player, victim anything else: the victim is
//     remembered for ~1.5 s, so the WO-40 LocalHit report for it carries
//     "the local player dealt this" (NpcDamage flag ATTRIBUTED).
//   * everything else: the original, untouched.
//
// On the NPC's authority (pipe 0x19), an attributed peer hit is applied with
// the peer's avatar as the attacker: TakeDamage(attacker), the combat-history
// writer (RPGModule, the one slot 0x150 itself calls), and once per engagement
// AddSoulToSkirmish(victim, avatar, override 1). The brain message
// (hitReaction) is the agent's, through the engine's own debug-command shape.
//
// A partner's friendly-fire hit on OUR Henry (pipe 0x1A) is plain TakeDamage
// with no attacker -- naming one is what starts fights -- and an unarmed flag
// that tells the death guard's classifier a fist floored him (a knockdown).

#include <cstddef>
#include <cstdint>

namespace kcdmp::hits {

void install();   // main thread, after motion::install(); logs WO121-HITS

// 0x18: [friendlyFire][attribution][pvpHook]
uint8_t on_config(const uint8_t* body, size_t len);

// Avatars, from motion.cpp (main thread): the soul the hook restores.
void note_avatar(uint32_t eid, void* soul, bool on);

struct AttribResult { bool ok = false; uint8_t steps = 0; uint8_t reason = 0; uint64_t attackerWuid = 0, victimWuid = 0; };
// 0x19, main thread: [guid:16][st:4f][hp:4f][flags:1][attackerEid:4][nameLen:1][name]
AttribResult apply_attributed(const uint8_t* body, size_t len);

// 0x1A, main thread: [st:4f][hp:4f][flags:1][attackerGhost:1]
bool apply_pvp_hit(const uint8_t* body, size_t len);

// For the pipe's LocalHit (main thread): did the local player hit this soul
// in the last `withinS` seconds?
bool hit_by_player(void* soul, double withinS);

// A local-player hit on an avatar, for the agent (pipe frame 0x97).
using PvpFn = void (*)(uint32_t victimEid, float stamina, float health, uint8_t flags, uint8_t material);
void set_pvp_callback(PvpFn fn);

void tick();   // main thread: drain the hook's queue, resolve victims
int status_text(char* out, int n);

} // namespace kcdmp::hits
