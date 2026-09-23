#pragma once
// WO-113 Phase 1: the native buff manager (RPGModule C_BuffManager).
//
// Reached exactly the way C_ScriptBindSoul::AddBuff reaches it (decompiled):
//   mgr = rpgModule->vtbl[0xE0](rpgModule)                 -> C_BuffManager*
//   inst = mgr->vtbl[0x00](mgr, soul, &buffGuid, 0, &perkGuid)   AddBuff
//   n    = mgr->vtbl[0x28](mgr, soul, &guid)                 RemoveAllBuffsByGuid
//   def  = mgr->vtbl[0x38](mgr, &guid)                       definition lookup
// and a soul's live instances are the vector the manager itself pushes to and
// removes from (soul+0x5B8 .. soul+0x5C0), each instance's definition GUID at
// inst->vtbl[0x58](inst).
//
// Anchors (resolve()): C_RPGModule and C_BuffManager by RTTI on the live
// objects; the AddBuff and RemoveAllBuffsByGuid scriptbinds by their own
// __FUNCTION__ strings, each containing "call [rax+0xE0]" followed by the slot
// load it makes (mov r10,[rcx] / mov r9,[rcx+0x28]); slot 0 calling the slot
// that owns "cannot find buff %s for soul '%s'"; slot 0 containing the
// soul+0x5B8/+0x5C0 instructions. Any miss = the feature does not arm.
//
// Main thread only.

#include <cstdint>

namespace kcdmp::buffs {

using Guid = unsigned char[16];

bool resolve();
bool ready();

// "6f706644-e28a-41a9-9674-5f19dea03bf1" -> in-memory CryGUID bytes.
bool parse_guid(const char* text, unsigned char out[16]);

// A soul pointer as the manager expects it (C_Soul*, checked by RTTI); null
// when `soul` is not one.
void* as_c_soul(void* soul);

// AddBuff. `instWuid` (optional) receives the instance WUID (+8 of the
// returned instance). False when the manager returned null.
bool add(void* soul, const unsigned char guid[16], uint64_t* instWuid = nullptr);

// RemoveAllBuffsByGuid: the number removed, -1 on failure.
int remove_all(void* soul, const unsigned char guid[16]);

// 1 present, 0 absent, -1 unreadable.
int has(void* soul, const unsigned char guid[16]);

// Is there a buff definition (table row) for this GUID on this build?
// 1 yes, 0 no, -1 unreadable.
int definition_exists(const unsigned char guid[16]);

} // namespace kcdmp::buffs
