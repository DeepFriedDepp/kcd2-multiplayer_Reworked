#pragma once
// WO-97: the ConceptModule read path -- the first native reach into the quest
// concept tree.
//
// WO-92 s5.2 named the surface, WO-96 s3.1 decompiled it and handed off a live
// call that was never possible, because nothing in this DLL had ever
// implemented one (WO-97 s2.1). This is that implementation, read-only:
//
//   wh::GetGameIface()                      (Shared.dll export)
//     +0x128  -> C_ConceptModule*
//     +0x18   -> C_ConceptManager*          (== C_ConceptModule::GetConceptManager)
//     +0x48 .. +0x50 -> the root module vector; each module's name is the
//                       char* at module+0x10
//   ConceptModule.dll + 0x16530 -> C_ConceptManager::FindNode
//
// FindNode's shape, from the mangled prototype and the decompile (WO-97 s2.3):
//
//   _smart_ptr<C_Node> __cdecl FindNode(const CryStringT<char>&) const
//
// MSVC x64 puts `this` in RCX and the hidden return-buffer pointer in RDX for
// member functions (its documented deviation from "return buffer first"), so
// the real register layout is RCX=this, RDX=_smart_ptr<C_Node>*, R8=string.
//
// Two traps this deliberately avoids:
//   * the exported I_Port::Read (0x2B1CF0) is the empty BASE virtual and
//     returns an empty rttr::variant -- a call to it succeeds and reads
//     nothing, presenting as "works, objective is none" (WO-96 s7). Nothing
//     here calls it. C_PortRef::Read (0x34E500) is the concrete one.
//   * FindNode RELEASES the string it is handed. A CryStringT<char> whose
//     refCount is negative is immortal to the engine -- every AddRef/Release
//     is guarded by `if (refCount >= 0)` and the copy constructor deep-copies
//     instead of sharing (code-verified). Ours is built that way, so the
//     engine can neither free our buffer nor retain a pointer into it.
//
// NOTHING HERE WRITES. No port is triggered, no state is set. C_PortRef::Trigger
// is mapped in WO-97 s3 and is not called from this file.

#include <cstddef>

namespace kcdmp::conceptread {

/// Enumerate the concept manager's root modules and, when `path` is non-empty,
/// resolve it with FindNode and report whether a node came back.
///
/// MUST run on the game's main thread -- the concept tree is live game state.
/// Every step is logged to the native log; a fault at any step is caught,
/// logged and turned into `false` rather than taking the process down.
///
/// `path` is a dot-separated concept path ('.' is the tokenizer's separator,
/// code-verified in WO-97 s2.2), whose FIRST segment is matched against the
/// root module names this same call prints. Pass nullptr or "" to enumerate
/// the roots only, which touches no engine code at all.
bool probe(const char* path);

// --- WO-99.5: the port surface ---------------------------------------------
/// Resolve <path> to a node, then <portName> to an I_Port, and report what is
/// actually there: the vtable, every slot resolved against ConceptModule's
/// exported symbols, the direction, the name and IsEmpty.
///
/// `actionCode`: 0 = probe (read-only), 1 = read the port's value through the
/// concrete slot-16 Read, 2 = fire the port through slot 15.
///
/// A trigger is REFUSED unless `confirmed` is true AND slot 15 is
/// C_ActiveTriggerPort::Trigger AND the vptr matches C_ActiveTriggerPort's
/// vftable AND the direction is not Out. The empty base virtuals return void
/// having done nothing, so an unchecked fire is unfalsifiable (WO-97 s3.5);
/// this refuses rather than producing a story.
///
/// MUST run on the game's main thread.
bool port_op(const char* path, const char* portName, int actionCode, bool confirmed);

/// Live-reload driver: re-reads kcdmp-concept.txt (game working directory
/// first, then beside the DLL) and runs port_op when its content changes.
/// One line: "<probe|read|trigger> <node.path> <portName> [FIRE]".
void port_watch();

} // namespace kcdmp::conceptread
