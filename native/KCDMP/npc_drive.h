#pragma once
// WO-118: the native per-frame puppet write -- the jitter fix.
//
// WO-116 s14 measured the reported jitter as the RATE and MOMENT of the Lua
// write (a 50 ms Lua timer leaves three of four rendered frames unwritten, and
// a write early in the frame is undone on alternate frames). The same write
// made every frame from this DLL's frame hook (C_ModulesManager::Update,
// main thread, after the engine's per-NPC movement, before the animation sync
// and render) held the body exactly. This module is that write, fed by the
// real network stream:
//
//   agent -> pipe 0x10  every inbound NPC sample (name, x/y/z, yaw, flags,
//                       seq, the sender's ms stamp, the agent's arrival QPC)
//   agent -> pipe 0x11  bind / unbind one puppet (Lua decides: policy stays
//                       in Lua, WO-118's rule) -- verified here before any
//                       write: entity id resolves, name matches, WUID matches
//                       the one Lua logs on MP-PAUSE, not parented, the body
//                       is a CryPhysics living entity
//   agent -> pipe 0x12  hold one puppet for N ms (a swing one-shot owns it)
//   agent -> pipe 0x13  config: mp_npc_native_write, mp_npc_senderclock
//   frame hook          per bound, living, unheld puppet: interpolation-behind
//                       at (now - delay) on the SENDER clock (WO-77 + WO-110
//                       R6, Z on the segment -- R14), then
//                         1. IPhysicalEntity::SetParams(pe_params_pos,
//                            bRecalcBounds = 1|32): the living body moves and
//                            KEEPS its ground collider (WO-105 s4.4)
//                         2. IEntity::SetPosRotScale(pos, rot, scale, 0): the
//                            entity moves; the physics proxy's follow-up
//                            position change is then zero-length, so it cannot
//                            release the ground either
//                       and, before the write, how far the ENGINE moved the
//                       body since our last write (MP-NPCPULL, the honest
//                       fight metric -- WO-118 Phase 4)
//
// Every engine address is re-found by anchor at install (RTTI + structural
// byte checks; docs/WO-118-findings.md s0). Any anchor that does not verify
// leaves the whole writer disarmed, logged loudly, and Lua keeps writing as
// today (it only stops for a puppet this module has ACKNOWLEDGED).
//
// Threads: the on_* entry points run on the pipe thread and only parse and
// queue; bind_main() and tick() run on the game's main thread.

#include <cstddef>
#include <cstdint>

namespace kcdmp::npcdrive {

// Result byte 2 of a bind/hold reply and the reason of an unsolicited drop.
// Mirrored by number in dotnet/KcdMp.Client (NativeNpcReason). Append-only.
enum Reason : uint8_t {
    kOk           = 0,
    kDisarmed     = 1,    // an anchor did not verify at install, or a fault disarmed the writer
    kToggleOff    = 2,    // mp_npc_native_write off
    kNoEntity     = 3,    // the entity id resolves to nothing
    kNameMismatch = 4,    // the entity at that id has a different name
    kWuidMismatch = 5,    // native WUID != the one Lua resolved for the name
    kNotLiving    = 6,    // no physics, or not a CryPhysics living entity
    kParented     = 7,    // attached to a parent (a rider, a carried body): local != world
    kBadRequest   = 8,    // malformed frame
    kEntityGone   = 9,    // the bound entity vanished or was re-created (a load)
    kSilence      = 10,   // no sample for the name for kSilenceS
    kFault        = 11,   // an engine call faulted; the writer disarmed itself
    kUnbound      = 12,   // unbound by Lua (reported only in logs)
    kTableFull    = 13,   // more bound puppets than kMaxBound
    kPipeClosed   = 14,   // the agent went away
};
const char* reason_name(uint8_t r);

// Resolve every anchor and register the per-frame tick. Main thread, once,
// after engine::resolve() is possible. Logs one WO118-NATIVE line either way.
void install();
bool armed();

// ---- pipe thread: parse + queue, no engine access ----------------------------
// 0x10: [count:1]{[src:1][nameLen:1][name][x:4f][y:4f][z:4f][rot:4f][flags:1]
//                  [seq:2][senderMs:4][arrivalQpc:8]}*count
uint8_t on_samples(const uint8_t* body, size_t len);
// 0x12: [ms:2][nameLen:1][name]
uint8_t on_hold(const uint8_t* body, size_t len);
// 0x13: [nativeOn:1][senderClockOn:1]
uint8_t on_config(const uint8_t* body, size_t len);
// The agent disconnected: every binding is dropped (no stream will follow).
void on_pipe_closed();

// ---- 0x11 bind, main thread (the pipe marshals it) ---------------------------
// [on:1][eid:4][wuid:8][ax:4f][ay:4f][az:4f][delayMs:2][nameLen:1][name]
struct BindRequest {
    bool     on = false;
    uint32_t eid = 0;
    uint64_t wuid = 0;          // 0 = Lua could not read one
    float    anchor[3]{};       // the pause spot (MP-NPCPULL's anchor)
    uint16_t delayMs = 120;     // interpolation delay (1.2 x emit period)
    char     name[64]{};
};
bool parse_bind(const uint8_t* body, size_t len, BindRequest* out);
uint8_t bind_main(const BindRequest& req);

// ---- status (pipe thread, atomics) -------------------------------------------
struct Status {
    uint8_t  armed = 0;
    uint8_t  nativeOn = 0;
    uint16_t bound = 0;          // bound puppets
    uint16_t writing = 0;        // written in the last frame
    uint32_t framesWritten = 0;  // frames with at least one write, since install
    uint32_t writes = 0;         // total entity writes, since install
    uint32_t drops = 0;          // unsolicited drops, since install
    uint32_t samples = 0;        // samples accepted, since install
};
Status status();

// Unsolicited "the DLL stopped writing this puppet on its own" (reason, name).
using DropFn = void (*)(uint8_t reason, const char* name);
void set_drop_callback(DropFn fn);

// Per-frame work (posted as a repeating main-thread task by install()).
void tick();

// ---- shared helpers for npc_trace.cpp (main thread) --------------------------
double now_s();                                    // QPC seconds
bool   entity_pos(void* e, float out[3]);          // world translation, SEH-guarded
void*  entity_by_name(const char* name);           // one full walk; null when absent
bool   living_flying(void* e, int* flying);        // pe_status_living.bFlying, when readable

// WO-127 (leash recorder), main thread, read-only.
struct PhysicsStatus {
    uint8_t present = 0;      // the entity has a physical entity
    uint8_t awakeKnown = 0, awake = 0;   // pe_status_awake answered, and its answer
    uint8_t living = 0;       // a CryPhysics living entity
    uint8_t flying = 0;       // pe_status_living.bFlying
    uint8_t speedKnown = 0;
    float   speed = 0;        // |pe_status_living.vel|, m/s
};
bool physics_status(void* e, PhysicsStatus* out);
// The native stream for an authored name (joiner: the host's NPC samples):
// seconds since the last accepted sample (-1 none), and whether it drives a body.
bool stream_info(const char* name, double* ageS, bool* bound);

} // namespace kcdmp::npcdrive
