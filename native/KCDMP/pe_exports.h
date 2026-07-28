#pragma once
// Resolve exports by walking a module's PE export directory.
//
// Matching is by PREFIX rather than by full mangled name. A 200-character
// mangled signature transcribed by hand is a silent-failure machine, and a
// prefix survives a signature change across a game patch instead of quietly
// resolving to null.

#include <windows.h>
#include <cstring>
#include <vector>

namespace kcdmp {

struct ExportEntry {
    const char* name;
    void*       addr;
};

inline std::vector<ExportEntry> module_exports(HMODULE mod) {
    std::vector<ExportEntry> out;
    if (!mod) return out;

    auto* base = reinterpret_cast<BYTE*>(mod);
    auto* dos  = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return out;

    auto* nt = reinterpret_cast<IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return out;

    const auto& dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
    if (dir.VirtualAddress == 0) return out;

    auto* exp   = reinterpret_cast<IMAGE_EXPORT_DIRECTORY*>(base + dir.VirtualAddress);
    auto* names = reinterpret_cast<DWORD*>(base + exp->AddressOfNames);
    auto* ords  = reinterpret_cast<WORD*>(base + exp->AddressOfNameOrdinals);
    auto* funcs = reinterpret_cast<DWORD*>(base + exp->AddressOfFunctions);

    out.reserve(exp->NumberOfNames);
    for (DWORD i = 0; i < exp->NumberOfNames; ++i) {
        out.push_back(ExportEntry{ reinterpret_cast<const char*>(base + names[i]),
                                   base + funcs[ords[i]] });
    }
    return out;
}

// `exclude` disambiguates overloads: type::get_method has both a
// string_view form and a string_view + vector<type> form, and only the first
// is wanted. Returns null if the match is not unique, because picking an
// arbitrary overload is exactly the kind of quiet wrong answer that costs a
// day.
inline void* find_export(const std::vector<ExportEntry>& exports,
                         const char* prefix,
                         const char* exclude = nullptr,
                         int* match_count = nullptr) {
    void* found = nullptr;
    int   n     = 0;
    const size_t len = std::strlen(prefix);
    for (const auto& e : exports) {
        if (std::strncmp(e.name, prefix, len) != 0) continue;
        if (exclude && std::strstr(e.name, exclude)) continue;
        if (!found) found = e.addr;
        ++n;
    }
    if (match_count) *match_count = n;
    return (n == 1) ? found : nullptr;
}

// Exact-suffix form, for picking one arity out of an overload set.
// method::invoke has seven overloads differing only in trailing argument
// repeats (...Vargument@2@@Z, ...Vargument@2@1@Z, ...11@Z), so a prefix cannot
// separate them and a full mangled name is too error-prone to type.
inline void* find_export_suffix(const std::vector<ExportEntry>& exports,
                                const char* prefix,
                                const char* suffix) {
    void* found = nullptr;
    int   n     = 0;
    const size_t plen = std::strlen(prefix);
    const size_t slen = std::strlen(suffix);
    for (const auto& e : exports) {
        const size_t elen = std::strlen(e.name);
        if (elen < plen || elen < slen) continue;
        if (std::strncmp(e.name, prefix, plen) != 0) continue;
        if (std::strcmp(e.name + elen - slen, suffix) != 0) continue;
        if (!found) found = e.addr;
        ++n;
    }
    return (n == 1) ? found : nullptr;
}

} // namespace kcdmp
