#pragma once
// WO-68 -- the native script-context surface (ghost civic isolation, crime half).
//
// WO-65 proved live that this build has NO Lua-reachable script-context setter:
// `Contexts` is nil, every candidate setter name on soul/human/AI/Game/System
// is nil, and `SetEntityScriptContext` is not a console command. Reading works
// (`soul:HasScriptContext(name)`), writing does not. WO-68 recovers the write
// side by disassembly instead.
//
// EVERY ADDRESS AND OFFSET BELOW IS CODE-VERIFIED against the installed
// Modding Tools binaries this session -- see docs/WO-68-findings.md, which
// cites the decompiled function for each one. Nothing here is borrowed from a
// vendor header (WO-67's standing lesson: vendor offsets key to the retail
// monolith and drift from our split-DLL build).
//
// The chain, all of it read out of `wh::rpgmodule::C_ScriptBindSoul::HasScriptContext`
// (RPGModule 0x5EEEC0) and the shipped unit test
// `game\whgame\Tests\ScriptCallbackTests.cpp` (WHGame 0x71C90):
//
//   gi   = wh::GetGameIface()                        (exported, already used
//                                                     by combat_construct.cpp)
//   db   = (*(gi+0x168))->vtbl[0x138]()              ScriptContext database
//   node = db->vtbl[0xC8](db, const CryString&)      name -> node, null = the
//                                                     database has no such row
//   mgr  = ((*(gi+0x18))->vtbl[0x118]())->vtbl[0x38]()   C_ScriptContextManager
//   mgr->vtbl[0x38](wuid, node) -> bool              HasEntityContext
//   mgr->vtbl[0x10](value, wuid, node)               SetEntityContext
//   wuid = *(uint64*)(soul+0x40)                     the exact value the
//                                                     scriptbind readback uses
//
// So `soul:HasScriptContext(name)` in Lua reads the very store these calls
// write, through the same vtable slot -- which is what makes the Lua readback
// a real independent verifier here rather than a proxy for one.

#include <cstdint>

namespace kcdmp::sctx {

// Phase 1 probe. Opt-in: no-op unless `kcdmp-contexts.txt` sits beside the DLL
// (the kcdmp-combat.txt / kcdmp-playanim.txt convention).
//
//   line 1: "player", or "guid:<32 hex chars>" (a soul Guid, resolved through
//           rttr's SoulsByGuid -- the same identity pipe 0x04 already uses)
//   line 2: "read" (default -- pure reads, nothing mutated) or "write"
//           (read, then set ONE context, verify, then unset it again)
//   line 3: optional context name; defaults to "crime_disableReport"
//
// Must run on the game's main thread: SetEntityContext has no lock, only a
// re-entrancy busy flag (WHGame 0x6AF60).
void probe_contexts();

// Re-read the config file each tick and re-run the probe when its content
// changes, so a soul guid can be dropped in while the game is running.
void probe_contexts_watch();

} // namespace kcdmp::sctx
