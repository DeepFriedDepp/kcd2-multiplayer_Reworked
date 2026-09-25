#pragma once
// WO-121 -- movement and combat on the bodies the native writer drives.
//
// The rule (the maintainer's): sync the INPUTS that cause animations, never
// "play animation X". Each native-written body -- a peer's avatar
// (kcd2mp_<id>) or an NPC copy -- gets, at the frame hook, right after the
// WO-118 position write:
//
//   gait    C_Actor::SetPseudoSpeed (C_Actor vftable slot 0x448) from the
//           streamed speed (the avatar's v8 state block) or the rendered
//           speed (NPC copies). The engine then picks walk/run, direction and
//           footfalls itself (WO-119 s3.3, observed). Toggles mp_avatar_gait /
//           mp_npc_gait; off, the mod's Lua clip loops come back.
//   crouch  C_ActorStateExpansion::SetCrouch (slot 0xE8) from the state bit.
//   jump    C_ActorStateExpansion::RequestJump (slot 0x100) on the Jump event.
//           (mp_avatar_moves)
//   combat  the avatar's combat automation off (the shipped
//           combat_EnableAutomation path, CombatModule), then combat mode held
//           from the stream (TryStartCombatMode, combat-actor slot 0x360, plus
//           the guard-request flag, SetFlag(model+0xEE8, 4, 1) -- without it the
//           engine ends combat the next frame), guard zone/stance, requested
//           attack zone, held block. (mp_avatar_combat)
//
// And on the SENDER side: the local player's v8 state block (read for the
// 0x86 local-state reply), and the committed-action capture -- a vtable patch
// on EnterImpl (slot 0x1C8) of C_CombatActorActionAttack / Dodge /
// PerfectBlock / Block that reads the row's mn_fragment_guid from the
// descriptor (action+0x60 -> +0x84, WO-121 session 1), and on
// C_ActorStateExpansion::RequestJump for the player's jump.
//
// Every address is re-found by anchor at install (RTTI vftables, the shipped
// combat test commands' Execute slots, string-anchored functions, structural
// byte checks); a piece whose anchor does not verify does not install, says so
// in WO121-MOTION, and the rest still does. A fault inside a call disarms that
// piece. Threads: on_* run on the pipe thread and only queue; body_frame,
// tick and read_local_state2 run on the game's main thread; the EnterImpl /
// RequestJump hooks run on whatever thread the engine calls them on and only
// queue.

#include <cstddef>
#include <cstdint>

namespace kcdmp::motion {

// The v8 state block, byte-for-byte the wire's (KcdMp.Wire.BodyState2).
#pragma pack(push, 1)
struct State2 {
    uint16_t speedCm = 0;
    int8_t   moveDir = 0;      // 1/256 turn, heading of the requested velocity minus facing
    uint8_t  bits = 0;         // kBit*
    uint8_t  guardZone = 0;    // wire zone: table id + 1 (0 = undefined)
    uint8_t  guardStance = 0;  // wire stance: table id + 1 (0 = none)
    uint8_t  atkZone = 0;
    uint8_t  charge = 0;
    int16_t  aimYaw = 0, aimPitch = 0;
};
#pragma pack(pop)
static_assert(sizeof(State2) == 12, "State2 is the 12-byte wire block");

constexpr uint8_t kBitCombat = 0x01, kBitBlock = 0x02, kBitCrouch = 0x04, kBitRanged = 0x08, kBitLocked = 0x10;

// Resolve anchors, install the capture hooks. Main thread, once, after
// npcdrive::install(). Logs one WO121-MOTION line.
void install();

// ---- pipe thread: parse + queue ------------------------------------------------
// 0x16 MotionConfig: [avatarGait][npcGait][avatarMoves][avatarCombat][npcRows]
uint8_t on_config(const uint8_t* body, size_t len);
// 0x17 AvatarEvent: [kind:1][eid:4]; kind 1 = jump
uint8_t on_avatar_event(const uint8_t* body, size_t len);

// ---- main thread ---------------------------------------------------------------
// npc_drive calls this for every body it wrote this frame. `st` is the newest
// state block from the stream (null when the stream never carried one) and
// `stAgeS` its age in seconds.
void body_frame(const char* key, void* ent, uint32_t eid, float renderSpeedMps,
                const State2* st, double stAgeS, double now);
// The writer stopped driving this body (unbind, drop, disarm): give it back.
void body_released(const char* key, uint32_t eid);
// The local player's state block (main thread; the 0x86 read). facingYaw is
// the yaw local_state read from the entity matrix in the same call.
bool read_local_state2(State2* out, float facingYaw);
// Per-frame: drain the capture queue to the callback, heartbeat checks.
void tick();

// One committed action on this machine, for the agent (pipe frame 0x96).
// kind: ActionKind (1 attack, 2 jump, 6 block impulse, 7 dodge). eid 0 = the
// local player; otherwise an NPC by its entity name.
using ActionFn = void (*)(uint8_t kind, uint8_t phase, int8_t inputClass, int8_t zoneTableId, int8_t attackType,
                          uint8_t flags, const uint8_t guid[16], uint32_t eid, const char* name);
void set_action_callback(ActionFn fn);

// Human-readable armed/off state and counters for the 0x1B status reply.
int status_text(char* out, int n);

// For hits.cpp: is this entity id a native-written avatar, and its soul.
bool is_avatar_eid(uint32_t eid);
// The local player's combat actor (main-thread cache; 0 when unknown).
void* player_combat_actor();

} // namespace kcdmp::motion
