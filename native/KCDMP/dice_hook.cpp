// WO-6 R2: inline hook on wh::playermodule::C_Dice::SetPauseWorldTime(bool),
// the only known route to a live C_Dice* instance.
//
// Evidence this hook site is safe, all gathered before writing a byte:
//
//   - Exported by name from PlayerModule.dll:
//       ?SetPauseWorldTime@C_Dice@playermodule@wh@@QEAAX_N@Z
//     (dumpbin /exports, RVA 0x372D40 against the build this was probed
//     against -- resolved by name at runtime below, never hardcoded, so a
//     patch that moves the RVA does not silently break this).
//
//   - Disassembly (dumpbin /disasm) of the first 13 bytes at that address is
//     four complete, self-contained instructions, no internal jumps, no
//     RIP-relative operands, ending exactly on an instruction boundary:
//
//       +0x00  48 89 5C 24 08   mov  qword ptr [rsp+8],rbx      5
//       +0x05  57               push rdi                        1
//       +0x06  48 83 EC 20      sub  rsp,20h                     4
//       +0x0A  48 8B D9         mov  rbx,rcx                     3   <- rbx = this
//       +0x0D  ...next instruction begins here (movzx edi,dl)
//
//     Stealing exactly these 13 bytes for the trampoline needs no address
//     fixup, because nothing in them references an address relative to
//     where they are stored.
//
//   - A few instructions later the function does
//       mov byte ptr [rbx+0x650], dil
//     i.e. writes the bool parameter straight into the object at a fixed
//     offset -- independent confirmation this is a plain, non-virtual data
//     write on a real, sizeable C++ object, not a thin wrapper.
//
// What this hook does NOT do: change game behaviour. The stolen bytes are
// replayed exactly through the trampoline every time; this only observes
// `this` on the way past.
//
// Accepted risk, not shared with the IAT-hook technique used elsewhere in
// this plugin: IAT hooking swaps one aligned pointer atomically. This
// patches code bytes at the function's own address, so if the game's main
// thread were executing inside this exact function at the instant of the
// patch, the outcome is undefined. SetPauseWorldTime is judged, not proven,
// to be called rarely (game-start/end of a dice interaction) rather than
// every frame, which makes that window small. Installed once, from the
// injection thread, before any dice interaction has been triggered.

#include "dice_hook.h"
#include "log.h"

#include <windows.h>
#include <atomic>
#include <cstring>

namespace kcdmp::dice {

namespace {

constexpr const char* kProvider = "PlayerModule.dll";
constexpr const char* kSymbol   = "?SetPauseWorldTime@C_Dice@playermodule@wh@@QEAAX_N@Z";

constexpr size_t kStolenBytes = 13;
constexpr size_t kPatchBytes  = 12;   // mov rax,imm64 (10) + jmp rax (2), fits within kStolenBytes

using SetPauseFn = void (*)(void* self, bool pause);

std::atomic<void*> g_instance{nullptr};
SetPauseFn         g_trampoline = nullptr;
bool               g_installed  = false;

void hooked_set_pause(void* self, bool pause) {
    void* prev = g_instance.exchange(self);
    if (prev != self) {
        logf("DICE: C_Dice instance captured at %p (pause=%d)", self, pause ? 1 : 0);
    }
    if (g_trampoline) g_trampoline(self, pause);
}

} // namespace

bool install_pause_hook() {
    if (g_installed) return true;

    HMODULE mod = GetModuleHandleA(kProvider);
    if (!mod) { logf("DICE: %s not loaded", kProvider); return false; }

    void* target = reinterpret_cast<void*>(GetProcAddress(mod, kSymbol));
    if (!target) { logf("DICE: export not found: %s", kSymbol); return false; }

    void* tramp = VirtualAlloc(nullptr, 64, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!tramp) { logf("DICE: VirtualAlloc for trampoline failed, gle=%lu", GetLastError()); return false; }

    auto* t = reinterpret_cast<unsigned char*>(tramp);

    // Copy the bytes we are about to overwrite, then append a jump back to
    // the original code right after them.
    std::memcpy(t, target, kStolenBytes);
    const uintptr_t resume = reinterpret_cast<uintptr_t>(target) + kStolenBytes;
    t[kStolenBytes + 0] = 0x48; t[kStolenBytes + 1] = 0xB8;              // mov rax, imm64
    std::memcpy(t + kStolenBytes + 2, &resume, 8);
    t[kStolenBytes + 10] = 0xFF; t[kStolenBytes + 11] = 0xE0;            // jmp rax
    g_trampoline = reinterpret_cast<SetPauseFn>(tramp);

    DWORD old_protect = 0;
    if (!VirtualProtect(target, kPatchBytes, PAGE_EXECUTE_READWRITE, &old_protect)) {
        logf("DICE: VirtualProtect (unlock) failed, gle=%lu", GetLastError());
        return false;
    }

    unsigned char patch[kPatchBytes];
    const uintptr_t hook_addr = reinterpret_cast<uintptr_t>(&hooked_set_pause);
    patch[0] = 0x48; patch[1] = 0xB8;                                    // mov rax, imm64
    std::memcpy(patch + 2, &hook_addr, 8);
    patch[10] = 0xFF; patch[11] = 0xE0;                                  // jmp rax
    std::memcpy(target, patch, kPatchBytes);

    DWORD ignored;
    VirtualProtect(target, kPatchBytes, old_protect, &ignored);
    FlushInstructionCache(GetCurrentProcess(), target, kPatchBytes);

    g_installed = true;
    logf("DICE: hook installed at %p (%s+0x%llX), trampoline at %p",
         target, kProvider,
         static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(target) -
                                          reinterpret_cast<uintptr_t>(mod)),
         tramp);
    return true;
}

void* instance() { return g_instance.load(); }

namespace {
// Diff-logged memory sampler, the same discipline as the combat sampler:
// read-only, SEH-guarded, only logs what changed. Window sized to cover the
// one known field (+0x650) plus headroom -- unproven past that, and an
// over-read that crosses into unmapped memory is caught by SEH and disables
// the sampler rather than crashing the game.
constexpr size_t kWindowBytes = 0x700;
unsigned char g_last[kWindowBytes]{};
bool          g_have_last = false;
bool          g_disabled  = false;
}

void sample_instance_if_changed() {
    if (g_disabled) return;
    void* inst = g_instance.load();
    if (!inst) return;

    unsigned char buf[kWindowBytes];
    __try {
        std::memcpy(buf, inst, kWindowBytes);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        logf("DICE: SEH fault reading instance memory at %p -- sampler disabled", inst);
        g_disabled = true;
        return;
    }

    if (!g_have_last) {
        std::memcpy(g_last, buf, kWindowBytes);
        g_have_last = true;
        logf("DICE: sampler primed, window=0x%zX bytes at %p", kWindowBytes, inst);
        return;
    }

    // Log changed 4-byte words compactly: offset, old value (as both int32
    // and float, since we don't yet know which dice fields are which), new.
    bool any = false;
    for (size_t off = 0; off + 4 <= kWindowBytes; off += 4) {
        uint32_t a, b;
        std::memcpy(&a, g_last + off, 4);
        std::memcpy(&b, buf + off, 4);
        if (a == b) continue;
        any = true;
        float fa, fb;
        std::memcpy(&fa, &a, 4);
        std::memcpy(&fb, &b, 4);
        logf("DICE: +0x%03zX  i32 %d -> %d   f32 %.3f -> %.3f   raw %08X -> %08X",
             off, static_cast<int32_t>(a), static_cast<int32_t>(b), fa, fb, a, b);
    }
    if (any) std::memcpy(g_last, buf, kWindowBytes);
}

} // namespace kcdmp::dice
