#pragma once
// WO-113: the stock CryEngine services the respawn needs, reached by anchor.
//
//   gEnv            lifted out of PlayerModule's C_PlayerModule::ValidateAlcoTeleportPoints
//                   (found by its "Unable to find HangoverSpotsHub..." string): the
//                   "mov rax,[rip+X]" read just before "mov rcx,[rax+0xA0]" names
//                   the module's own gEnv slot -- no RVA
//   IEntitySystem   gEnv+0xA0, vptr == RTTI .?AVCEntitySystem@@; SpawnEntity (0x60)
//                   and RemoveEntity (0x98) checked by their own __FUNCTION__ strings
//   IConsole        gEnv+0xA8, vptr == RTTI .?AVCXConsole@@
//   GameInterface   Shared.dll export wh::GetGameIface
//
// Offsets on IEntity / IConsole / ICVar are the ones agent research read out of
// this build's binds (docs/WO-113-findings.md s1); each call is SEH-guarded.
// Main thread only.

#include <cstdint>

namespace kcdmp::engine {

bool resolve();
bool ready();

void* game_iface();
void* genv();
void* entity_system();
void* console();

// IEntity helpers (null / false when unavailable).
void*       entity_by_id(uint32_t id);
void*       entity_by_guid(uint64_t guid);
uint32_t    entity_id(void* e);
uint64_t    entity_guid(void* e);
const char* entity_name(void* e);
bool        entity_world_pos(void* e, float out[3]);
bool        entity_set_pos(void* e, const float pos[3]);
bool        entity_add_flags(void* e, uint32_t flags);
// LoadGeometry(slot, file, geomName=null, flags). Returns the slot or -1.
int         entity_load_geometry(void* e, int slot, const char* file, int flags);

constexpr uint32_t kFlagCastShadow = 0x2;
constexpr uint32_t kFlagNoSave     = 0x8000;
constexpr uint32_t kFlagSpawned    = 0x1000000;

// SpawnEntity with a zeroed SEntitySpawnParams laid out as the Lua bind fills
// it; `guid` 0 lets the engine mint one (SPAWNED is always set).
void* spawn(const char* className, const char* name, const float pos[3], uint32_t flags, uint64_t guid);
bool  remove(uint32_t entityId);

// Walk every entity; `visit` returns true to stop.
int for_each_entity(bool (*visit)(void* e, void* ctx), void* ctx);

// Console: set an int CVar, reporting the previous value. False when the CVar
// does not exist or is not an int.
bool cvar_set_int(const char* name, int value, int* previous);

} // namespace kcdmp::engine
