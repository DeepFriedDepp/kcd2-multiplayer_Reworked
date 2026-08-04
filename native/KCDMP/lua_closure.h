#pragma once
// WO-20 Phase 2 -- recover a Lua scriptbind's real native address and name
// instead of guessing its call signature.
//
// The technique is Jefferson25625's (kcd2-exports, used with permission,
// docs/WO-18-findings.md P4): `tostring(luaFn)` in Lua yields the closure's
// own address as text ("function: 0x<addr>"); the closure holds a pointer to
// a descriptor at +0x28, whose own +0x28 is the real native callback address
// and whose +0x40 is claimed to be a name string. Those offsets are THEIRS,
// unverified by this project until resolve()'s own corroborating checks
// (module + RVA, name plausibility) confirm them against a known-good
// closure -- see docs/WO-20-aggro-findings.md. Treat a single "looks right"
// result as inconclusive, the same standing rule this project applies to
// every other reflected/reversed surface.

#include <cstdint>
#include <string>

namespace kcdmp::luaintrospect {

struct ClosureInfo {
    bool ok = false;
    uint64_t descriptor = 0;
    uint64_t nativeAddr = 0;
    std::string moduleName;   // empty if nativeAddr didn't resolve to a loaded module
    uint32_t rva = 0;         // nativeAddr - moduleBase, meaningful only if moduleName is set
    std::string name;         // best-effort string read near descriptor+0x40
    std::string prologueHex;  // first 48 bytes at nativeAddr, hex-encoded
};

// Pure reads, SEH-guarded throughout -- never writes to game memory. Must be
// called on the game's main thread (same rule as every rttr:: call) because
// the closure is a live Lua GC object.
ClosureInfo resolve(uint64_t closure_addr);

} // namespace kcdmp::luaintrospect
