#pragma once
// Import Address Table hooking.
//
// Chosen over an inline detour deliberately. An inline hook has to decode and
// relocate the instructions it overwrites, and a mistake there corrupts the
// game in a way that surfaces far from the cause. An IAT patch is a single
// aligned pointer store into a table the loader already writes to: no
// instruction decoding, no trampoline, trivially reversible.
//
// It works here because WHGame.dll imports
// ?Update@C_ModulesManager@framework@wh@@QEAAXM@Z from Framework.dll, so the
// call goes through WHGame's IAT rather than staying inside Framework.

#include <windows.h>
#include <cstring>

namespace kcdmp {

// Replaces `importer`'s IAT entry for `symbol` imported from `from_module`.
// Returns the previous target, or null if the entry was not found.
inline void* hook_iat(HMODULE importer, const char* from_module,
                      const char* symbol, void* replacement) {
    if (!importer) return nullptr;

    auto* base = reinterpret_cast<BYTE*>(importer);
    auto* dos  = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return nullptr;
    auto* nt = reinterpret_cast<IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return nullptr;

    const auto& dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (dir.VirtualAddress == 0) return nullptr;

    auto* desc = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(base + dir.VirtualAddress);
    for (; desc->Name; ++desc) {
        const char* dll = reinterpret_cast<const char*>(base + desc->Name);
        if (_stricmp(dll, from_module) != 0) continue;

        // OriginalFirstThunk keeps the names; FirstThunk is the live table the
        // loader bound to real addresses. Walk them in step.
        auto* orig = reinterpret_cast<IMAGE_THUNK_DATA64*>(
            base + (desc->OriginalFirstThunk ? desc->OriginalFirstThunk : desc->FirstThunk));
        auto* live = reinterpret_cast<IMAGE_THUNK_DATA64*>(base + desc->FirstThunk);

        for (; orig->u1.AddressOfData; ++orig, ++live) {
            if (orig->u1.Ordinal & IMAGE_ORDINAL_FLAG64) continue;  // imported by ordinal
            auto* by_name = reinterpret_cast<IMAGE_IMPORT_BY_NAME*>(base + orig->u1.AddressOfData);
            if (std::strcmp(by_name->Name, symbol) != 0) continue;

            void*  previous = reinterpret_cast<void*>(live->u1.Function);
            DWORD  old_protect = 0;
            if (!VirtualProtect(&live->u1.Function, sizeof(void*), PAGE_READWRITE, &old_protect)) {
                return nullptr;
            }
            live->u1.Function = reinterpret_cast<ULONGLONG>(replacement);
            VirtualProtect(&live->u1.Function, sizeof(void*), old_protect, &old_protect);
            return previous;
        }
    }
    return nullptr;
}

} // namespace kcdmp
