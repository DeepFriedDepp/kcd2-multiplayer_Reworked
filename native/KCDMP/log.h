#pragma once
// Deliberately not using the engine's logger. At the point this DLL loads we
// have not resolved anything yet, and a logger that depends on the thing we are
// diagnosing is useless. Plain file, flushed every line, next to the DLL.

#include <windows.h>
#include <share.h>
#include <cstdio>
#include <cstdarg>
#include <mutex>
#include <string>

namespace kcdmp {

inline std::mutex& log_mutex() { static std::mutex m; return m; }

inline std::string log_path() {
    char buf[MAX_PATH]{};
    HMODULE self = nullptr;
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                       GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCSTR>(&log_mutex), &self);
    GetModuleFileNameA(self, buf, MAX_PATH);
    std::string p(buf);
    const size_t slash = p.find_last_of("\\/");
    if (slash != std::string::npos) p.resize(slash + 1);
    return p + "kcdmp-native.log";
}

// WO-45: a second copy of every line, written into the game process's working
// directory (where the game writes kcd.log). The primary log sits beside the
// DLL under %LocalAppData%\KCDMP, and reads of that path from the coding shell
// return silently stale snapshots (the sandbox redirection WO-43 §7 hit) --
// the game's own directory does not have that problem. The DLL runs inside
// the game process, so it can write there directly.
inline std::string mirror_log_path() {
    char cwd[MAX_PATH]{};
    if (!GetCurrentDirectoryA(MAX_PATH, cwd) || !cwd[0]) return {};
    std::string p(cwd);
    if (p.back() != '\\') p += '\\';
    return p + "kcdmp-native.mirror.log";
}

inline void logf(const char* fmt, ...) {
    std::lock_guard<std::mutex> lock(log_mutex());
    static FILE* f = nullptr;
    static FILE* mirror = nullptr;
    static bool  opened = false;
    if (!opened) {
        opened = true;
        // _fsopen with _SH_DENYWR, not fopen: the game holds this handle for its
        // whole run, and fopen's default share mode makes the log unreadable
        // from outside until the process exits -- which defeats the point of
        // having a log at all.
        f = _fsopen(log_path().c_str(), "w", _SH_DENYWR);
        const std::string mp = mirror_log_path();
        if (!mp.empty()) mirror = _fsopen(mp.c_str(), "w", _SH_DENYWR);
    }
    if (!f && !mirror) return;
    SYSTEMTIME st{};
    GetLocalTime(&st);
    va_list args;
    for (FILE* dst : { f, mirror }) {
        if (!dst) continue;
        fprintf(dst, "[%02d:%02d:%02d.%03d] ", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
        va_start(args, fmt);
        vfprintf(dst, fmt, args);
        va_end(args);
        fputc('\n', dst);
        fflush(dst);
    }
}

} // namespace kcdmp
