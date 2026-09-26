#pragma once
// WO-127 Phase 3: the leash recorder's native half. Read-only.
//
// Once a second, while mp_leash_trace is on, the agent asks for one sample
// (pipe 0x1F -> 0x8F): every NPC/NPC_Female/Horse within `radius` of any
// anchor (the host and the joiner's avatar), with every simulation signal the
// engine exposes cheaply, plus a town/interior verdict per anchor. Nothing
// runs when the trace is off (no request, no per-frame work at all).
//
// Signals and where each comes from (all SEH-guarded, all reads):
//   hidden / active  CEntity +0x08 bit 4 / bit 0 -- what CScriptBind_Entity's
//                    IsHidden / IsActive read inline (CryEntitySystem.dll,
//                    disassembled this WO: `(dword[e+8] >> 4) & 1`, `byte[e+8] & 1`)
//   physics          IEntity::GetPhysics -> pe_status_awake (awake) and, for a
//                    living entity, pe_status_living (flying, |vel|)
//   brain            WUID -> AIObjectManager -> the game's exported
//                    ai_cast<C_IntelligentObject>, then C_IntelligentObject's
//                    suspend state (+0x128) and reason mask (+0x129) (WO-107)
//   stream / driven  npc_drive's per-name stream (age of the last accepted
//                    sample) and whether it drives the body (joiner)
//   town             actions::in_settlement (the game's area labels)
//   interior         I3DEngine::GetVisAreaFromPos != null -- the call
//                    CScriptBind_System::IsPointIndoors makes (CryScriptSystem.dll,
//                    disassembled this WO: gEnv+0x08, vtable +0x528)
// Not found cheaply this WO (recorded as unknown by the agent): character
// animation LOD, a separate AI-proxy update flag.

#include <cstdint>
#include <vector>

namespace kcdmp::leash {

struct Anchor { float x = 0, y = 0, z = 0; };

enum EntryFlags : uint16_t {
    kHorse        = 1 << 0,
    kHidden       = 1 << 1,
    kActive       = 1 << 2,
    kPhysPresent  = 1 << 3,
    kAwakeKnown   = 1 << 4,
    kAwake        = 1 << 5,
    kLiving       = 1 << 6,
    kFlying       = 1 << 7,
    kDriven       = 1 << 8,    // npc_drive binds this body (a joiner's puppet)
    kBrainKnown   = 1 << 9,
    kEntFlagsKnown= 1 << 10,
};

struct Entry {
    uint64_t wuid = 0;
    float    x = 0, y = 0, z = 0;
    uint16_t flags = 0;
    int8_t   brainState = -1;     // 0 running, 1/2 suspended, -1 unknown
    uint8_t  brainMask = 0xFF;    // suspend-reason bits; 0xFF unknown
    uint16_t speedCms = 0xFFFF;   // |vel| in cm/s; 0xFFFF unknown
    uint16_t streamAgeMs = 0xFFFF;// age of the last accepted stream sample; 0xFFFF none
    char     name[48] = {};
};

constexpr int kMaxAnchors = 4;

struct Result {
    uint8_t  refuse = 0;          // npcscan::Refuse
    uint32_t walked = 0;          // entities the iterator produced
    uint32_t frames = 0;          // main_thread::frame_count() at the sample (fps = delta / seconds)
    uint32_t sampleUs = 0;        // main-thread time of this sample
    int8_t   town[kMaxAnchors] = {-1, -1, -1, -1};      // 1/0, -1 unknown
    int8_t   interior[kMaxAnchors] = {-1, -1, -1, -1};
    int      anchors = 0;
    std::vector<Entry> entries;
};

// Main thread. Takes a fresh sample and keeps it for paging (page()).
bool sample(const Anchor* anchors, int n, float radius, Result* out);

// Any thread: entries [offset, offset + max) of the last sample into `out`
// (header fields copied too). False when there is no sample.
bool page(uint16_t offset, size_t budgetBytes, Result* out, uint16_t* total);

// The wire size of one entry (for the pipe's page budget).
size_t entry_bytes(const Entry& e);

} // namespace kcdmp::leash
