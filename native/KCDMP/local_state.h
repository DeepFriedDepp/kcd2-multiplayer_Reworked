#pragma once
// WO-102 Phase 1 -- the local player's position, yaw, riding state and body
// state, read natively from ONE frame. Read-only. Replaces the [KCD2-MP-DATA]
// log line as the position source when the agent has mp_pos_native on; the
// log line stays the fallback and the known-answer oracle.
//
// What is read, and how it was established (docs/WO-102-findings.md S1):
//
//   * C_Actor is a CGameObjectExtensionHelper<C_Actor, IActor> over IComponent
//     (MSVC RTTI in EntityModule.dll, code-verified). The engine's IEntity*
//     is the extension's m_pEntity member. Its offset is NOT hard-coded: the
//     read scans the candidate slots and accepts the one whose pointee's
//     vptr is CEntity::vftable (CryEntitySystem.dll + 0x14FA18, RTTI-confirmed)
//     -- the WO-100 gate-3 discipline. No match = refuse, never guess.
//   * CScriptBind_Entity::GetWorldPos (CryEntitySystem, decompiled) reads the
//     position straight out of CEntity's world matrix: x at +0x64, y at
//     +0x74, z at +0x84 (Matrix34 at +0x58, row-major). GetWorldAngles reads
//     the same matrix and yaw is atan2(m10, m00) = atan2(+0x68, +0x58) with
//     CryEngine's Ang3::GetAnglesXYZ gimbal branch. This is byte-for-byte
//     what the mod's player:GetWorldPos()/GetWorldAngles() read, so the log
//     line and this read agree by construction, modulo frame timing.
//   * Riding = the Mannequin Stance group reads "horse" (WO-100 S10.1,
//     live-verified against a real mount).
//   * The body state is WO-100.5's read_body_state, in the same call.
#include <cstdint>
#include "mannequin_read.h"

namespace kcdmp::localstate {

// Mirrored by number in dotnet/KcdMp.Client/LocalStateCodec.cs (LocalStateRefuse). Append-only.
enum Refuse : uint8_t {
    kOk               = 0,
    kModuleMissing    = 1,   // EntityModule / CryEntitySystem not loaded
    kNoPlayerActor    = 2,   // GetPlayerActor returned null (no world yet)
    kEntityHopUnmapped= 3,   // no candidate slot on C_Actor points at a CEntity -- refuse, do not guess
    kReadFaulted      = 4,   // SEH fault on a read or virtual call
    kNonFinite        = 5,   // the matrix held a NaN/Inf
    kVtableMismatch   = 6,   // CryEntitySystem loaded but CEntity::vftable RVA does not read as a vtable (build drift)
};

struct LocalState {
    uint64_t frame  = 0;      // main_thread::frame_count() at the read
    float    x = 0, y = 0, z = 0, rotZ = 0;
    uint8_t  flags  = 0;      // bit 0: riding
    bool     haveBody = false;
    kcdmp::mannequin::BodyState body{};
    uint8_t  refuse = kOk;
};

// Runs on the game's main thread (the pipe marshals it). Returns false and
// sets out->refuse on any gate; touches nothing in the game.
bool read_local_state(LocalState* out);

} // namespace kcdmp::localstate
