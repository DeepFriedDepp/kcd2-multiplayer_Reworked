// KCDMP_LauncherInjector.exe -- loads KCDMP.dll into a running game process.
//
// Command line is fixed by KCDMP_launcher, which already invokes it as:
//     KCDMP_LauncherInjector.exe --pid <pid> --dll "<absolute path>"
// See KCDMP_launcher/Pages/Home.razor.cs. Do not change the argument shape
// without changing the launcher.
//
// Classic CreateRemoteThread(LoadLibraryA) injection. That is sufficient here
// because KCD2 has no anti-cheat: no EAC, BattlEye, Denuvo or packer in either
// build (see docs/NATIVE-PLUGIN-findings.md). Nothing exotic is warranted.

#include <windows.h>
#include <tlhelp32.h>

#include <cstdio>
#include <cstring>
#include <string>

namespace {

int fail(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
    fputc('\n', stderr);
    return 1;
}

// LoadLibraryA lives in kernel32, which is mapped at the same base in every
// process on a given boot, so our own address is valid in the target. This is
// the standard assumption and holds for same-architecture, same-session
// injection; it would not hold across a WOW64 boundary, and both sides here are
// x64.
bool is_wow64(HANDLE process) {
    BOOL wow = FALSE;
    IsWow64Process(process, &wow);
    return wow == TRUE;
}

} // namespace

int main(int argc, char** argv) {
    DWORD       pid = 0;
    std::string dll;

    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--pid") == 0 && i + 1 < argc) {
            pid = static_cast<DWORD>(std::strtoul(argv[++i], nullptr, 10));
        } else if (std::strcmp(argv[i], "--dll") == 0 && i + 1 < argc) {
            dll = argv[++i];
        }
    }

    if (pid == 0 || dll.empty()) {
        return fail("usage: KCDMP_LauncherInjector.exe --pid <pid> --dll <path>");
    }

    // Resolve to an absolute path here rather than in the target: the game's
    // working directory is its own Bin folder, so a relative path would be
    // resolved against the wrong root and LoadLibrary would fail with a
    // misleading "module not found".
    char full[MAX_PATH]{};
    if (!GetFullPathNameA(dll.c_str(), MAX_PATH, full, nullptr)) {
        return fail("cannot resolve path: %s", dll.c_str());
    }
    if (GetFileAttributesA(full) == INVALID_FILE_ATTRIBUTES) {
        return fail("DLL not found: %s", full);
    }

    HANDLE process = OpenProcess(PROCESS_CREATE_THREAD | PROCESS_QUERY_INFORMATION |
                                 PROCESS_VM_OPERATION | PROCESS_VM_WRITE | PROCESS_VM_READ,
                                 FALSE, pid);
    if (!process) {
        return fail("OpenProcess(%lu) failed: %lu (run as the same user as the game)", pid, GetLastError());
    }

    if (is_wow64(process)) {
        CloseHandle(process);
        return fail("target is 32-bit; KCDMP.dll is x64");
    }

    const SIZE_T bytes = std::strlen(full) + 1;
    void* remote = VirtualAllocEx(process, nullptr, bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!remote) {
        CloseHandle(process);
        return fail("VirtualAllocEx failed: %lu", GetLastError());
    }

    if (!WriteProcessMemory(process, remote, full, bytes, nullptr)) {
        VirtualFreeEx(process, remote, 0, MEM_RELEASE);
        CloseHandle(process);
        return fail("WriteProcessMemory failed: %lu", GetLastError());
    }

    auto loader = reinterpret_cast<LPTHREAD_START_ROUTINE>(
        GetProcAddress(GetModuleHandleA("kernel32.dll"), "LoadLibraryA"));

    HANDLE thread = CreateRemoteThread(process, nullptr, 0, loader, remote, 0, nullptr);
    if (!thread) {
        VirtualFreeEx(process, remote, 0, MEM_RELEASE);
        CloseHandle(process);
        return fail("CreateRemoteThread failed: %lu", GetLastError());
    }

    WaitForSingleObject(thread, 15'000);

    // The remote thread returns LoadLibraryA's HMODULE truncated to 32 bits.
    // Zero means the load failed inside the target; non-zero only means the
    // module mapped, not that the plugin is healthy -- check kcdmp-native.log
    // next to the DLL for that.
    DWORD result = 0;
    GetExitCodeThread(thread, &result);

    CloseHandle(thread);
    VirtualFreeEx(process, remote, 0, MEM_RELEASE);
    CloseHandle(process);

    if (result == 0) {
        return fail("LoadLibrary failed inside pid %lu (missing dependency, or wrong architecture)", pid);
    }

    printf("injected %s into pid %lu\n", full, pid);
    return 0;
}
