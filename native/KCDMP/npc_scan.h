#pragma once
// WO-102.5 Phase 2 -- the native NPC scan. Read-only.
//
// Replaces the enumerate+read half of Lua's mp_npc_rescan (kdcmp.lua): given
// the same anchor list and radius the Lua scan already computes, walk the
// entity system once and return every NPC/NPC_Female/Horse within radius of
// ANY anchor, with its authored name, position and yaw. Policy -- ranking,
// the per-anchor cap, KCD2MP.npcTracked bookkeeping, acquire/release
// logging -- stays in Lua (docs/WO-102.5-findings.md Phase 2). This function
// only replaces the walk.
//
// What is read, and how it was established this session (docs/WO-102.5-findings.md S2):
//
//   * CScriptBind_System::GetEntitiesInSphere (CryScriptSystem.dll,
//     decompiled) is the Lua binding behind System.GetEntitiesInSphere: it
//     walks gEnv->pEntitySystem's FULL entity iterator every call (not a
//     radius-scoped query) and filters by squared distance itself. So the
//     Lua scan's real cost is this walk, repeated once per anchor, plus a
//     script-table construction for every entity that matches -- both of
//     which this function avoids.
//   * gEnv is not exported by name in this build (checked; CrySystem.dll,
//     CryEntitySystem.dll and CryScriptSystem.dll all searched). Each
//     CryEngine DLL keeps its own private static SSystemGlobalEnvironment*
//     -- KCDMP.dll has none, so this reads CryScriptSystem.dll's own copy
//     out of its data section at a fixed RVA (see kRvaCryScriptSystemGEnvPtr
//     in the .cpp). A DATA rva, weaker evidence than a decompiled function,
//     so it is never trusted on the read alone -- see the gate below.
//   * IEntitySystem::GetClassRegistry() = vtbl+0x58, GetEntityIterator() =
//     vtbl+0xB0; IEntityClassRegistry::FindClass(const char*) = vtbl+0x18;
//     IEntity::GetClass() = vtbl+0x18 (a different vtable, same slot number
//     by coincidence). All four read out of the SAME decompiled function,
//     CScriptBind_System::GetEntitiesInSphereByClass -- two independent
//     call sites on gEnv->pEntitySystem (GetClassRegistry, GetEntityIterator)
//     agreeing with IEntitySystem's known interface shape is the
//     cross-validation this build offers without a live process to call it.
//   * IEntityItPtr: vtbl+0x08 AddRef, +0x10 Release, +0x20 Next() ->
//     IEntity*, +0x30 MoveFirst(). Decompiled from
//     CScriptBind_System::GetEntitiesInSphere.
//   * Position/yaw: the SAME CEntity::m_worldTM offsets local_state.cpp
//     established (WO-102 S1.2) -- re-derived here rather than shared
//     across a header, since it is six constants, not a function.
//   * IEntity::GetName(): CScriptBind_Entity::GetName (CryEntitySystem.dll,
//     decompiled this session) reads entity+0xE0 directly (no vtable call)
//     and hands it to the string-wrapping helper as a `const char*` --
//     i.e. a CryStringT's exposed data pointer sits there. WO-97's
//     negative-refCount trap means this is read defensively: length-capped,
//     printable-gated, never trusted blind.
//
// THE GATE: on every scan, the resolved gEnv/pEntitySystem candidate is
// trusted only after the entities it hands back start passing the SAME
// vptr == CEntity::vftable check local_state.cpp uses for its actor->entity
// hop (WO-100 gate-3 discipline). Zero matches among the first entities
// examined refuses the whole scan (kGEnvUnmapped) rather than returning a
// plausible-looking wrong answer. The class registry resolution (NPC /
// NPC_Female / Horse) is cached for the process lifetime once it succeeds
// once -- IEntityClass instances are load-time singletons, not per-world
// state (unlike WO-99.5 S1.3's caution about cached entity/actor pointers,
// which this scan does NOT cache across calls).
#include <cstdint>
#include <vector>

namespace kcdmp::npcscan {

// Mirrored by number in dotnet/KcdMp.Client (append-only).
enum Refuse : uint8_t {
    kOk                    = 0,
    kModuleMissing         = 1,   // CryScriptSystem.dll / CryEntitySystem.dll not loaded
    kGEnvUnmapped          = 2,   // gEnv/pEntitySystem candidate failed the iterator+vptr gate
    kClassRegistryUnmapped = 3,   // GetClassRegistry/FindClass did not resolve NPC/NPC_Female/Horse
    kReadFaulted           = 4,   // SEH fault mid-scan
};

struct Anchor { float x = 0, y = 0, z = 0; };

struct NpcEntry {
    char    name[60] = {};   // authored name, NUL-terminated, <=59 bytes (WO-100.5's NpcRequestPayload cap)
    float   x = 0, y = 0, z = 0, yaw = 0;
    uint8_t isHorse = 0;     // 0 = NPC/NPC_Female (human), 1 = Horse
};

struct ScanResult {
    uint8_t  refuse     = kOk;
    bool     truncated  = false;   // byte budget hit; some in-radius NPCs were not returned
    uint32_t totalWalked = 0;      // entities the iterator produced, for MP-NPCSCAN telemetry
    uint32_t nameRejects = 0;      // entities matched class+radius but failed the name-read gate
    std::vector<NpcEntry> entries;
};

constexpr size_t kMaxReplyBytes = 8000;   // well under the pipe's uint16 payload length; budget, not a hard cap on the wire

// Runs on the game's main thread (the pipe marshals it). Read-only; touches
// nothing. anchorCount must be >= 1 and is not bounds-checked beyond that --
// callers control it (the pipe caps it, see pipe_server.h).
bool scan(const Anchor* anchors, int anchorCount, float radius, ScanResult* out);

} // namespace kcdmp::npcscan
