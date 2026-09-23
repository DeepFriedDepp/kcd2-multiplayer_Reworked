#pragma once
// Runtime anchors: re-finding engine code by what it IS, not by where it was.
//
// WO-113 Phase 0's rule: every address the death/respawn feature touches is
// re-found on the running build by an anchor -- an RTTI class name, a string
// literal the function references, an export -- and never trusted from an RVA
// alone. A patch that moves code keeps working; a patch that changes the thing
// itself fails the anchor and the piece that depends on it does not install.
//
// Everything here is a read of the loaded image. Nothing is written.
//
//   * find_vftable      RTTI type descriptor -> Complete Object Locator -> vftable
//   * find_cstring      an exact NUL-terminated string in the image's data
//   * function_range    the primary function [begin,end) holding an address,
//                       via the exception directory (.pdata), chained unwind
//                       info followed back to the primary entry
//   * function_refs     does a function (every fragment chained to it) hold a
//                       RIP-relative reference to an address
//   * function_by_string the one function that references a string
//   * function_has_bytes / function_calls  cheap structural consistency checks
//
// All scans are SEH-guarded: a wrong assumption about the image reads as "not
// found", never as a fault inside the game.

#include <windows.h>
#include <cstddef>
#include <cstdint>

namespace kcdmp::anchor {

struct Range {
    const uint8_t* begin = nullptr;
    const uint8_t* end   = nullptr;
    bool contains(const void* p) const {
        auto b = static_cast<const uint8_t*>(p);
        return b >= begin && b < end;
    }
    size_t size() const { return static_cast<size_t>(end - begin); }
};

// A named section of a loaded module (".text", ".rdata", ".data").
bool section(HMODULE mod, const char* name, Range* out);

// The address of an exact NUL-terminated string (preceded by a NUL or the start
// of a section) in .rdata or .data; null when absent. `count` (optional) is the
// number of exact copies found -- more than one is legal for strings, the first
// is returned.
const char* find_cstring(HMODULE mod, const char* s, int* count = nullptr);

// The vftable of the class whose RTTI decorated name is `decorated` (e.g.
// ".?AVC_GameOver@playermodule@wh@@"), for the subobject at `colOffset` (0 for
// the primary vftable). Null when the type, its locator or its vftable cannot
// be found, or when more than one vftable matches (ambiguous = not trusted).
void* const* find_vftable(HMODULE mod, const char* decorated, uint32_t colOffset = 0);

// The primary function range holding `addr`, following UNW_FLAG_CHAININFO back
// to the root entry. False when `addr` is not inside any function of `mod`.
bool function_range(HMODULE mod, const void* addr, Range* out);

// Does the function whose primary entry holds `fn` -- including every
// fragment whose unwind chain leads to it -- contain a RIP-relative disp32
// referencing `target`?
bool function_refs(HMODULE mod, const void* fn, const void* target);

// The primary entry of the one function that references the exact string `s`.
// Null when no function or more than one distinct function references it.
// `count` (optional): distinct referencing functions found.
const uint8_t* function_by_string(HMODULE mod, const char* s, int* count = nullptr);

// Does the function (all fragments) contain this byte pattern?
bool function_has_bytes(HMODULE mod, const void* fn, const uint8_t* pat, size_t n);

// Does the function (all fragments) contain `first`, followed within `window`
// bytes by `second`? (e.g. "call [rax+0xE0]" then "mov r9,[rcx+0x28]")
bool function_has_sequence(HMODULE mod, const void* fn,
                           const uint8_t* first, size_t n1,
                           const uint8_t* second, size_t n2, size_t window);

// Does the function (all fragments) contain a direct `call rel32` (E8) or a
// tail `jmp rel32` (E9) to `target`?
bool function_calls(HMODULE mod, const void* fn, const void* target);

// The address of the first `first` that is followed within `window` bytes by
// `second`, in any fragment of the function; null when absent. Used to lift a
// RIP-relative operand out of an anchored function (e.g. the module's own gEnv
// slot read just before "mov rcx,[rax+0xA0]") instead of hard-coding its RVA.
const uint8_t* function_find_sequence(HMODULE mod, const void* fn,
                                      const uint8_t* first, size_t n1,
                                      const uint8_t* second, size_t n2, size_t window);

// For a match returned above that starts with a 3-byte REX+opcode+ModRM of a
// [rip+disp32] operand (e.g. 48 8B 05), the absolute address the operand names.
const void* rip_target(const uint8_t* insn, size_t dispOffset = 3, size_t insnLen = 7);

// module+0xRVA for logs.
void describe(const void* p, char* out, size_t n);

} // namespace kcdmp::anchor
