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

inline void logf(const char* fmt, ...) {
    std::lock_guard<std::mutex> lock(log_mutex());
    static FILE* f = nullptr;
    if (!f) {
        // _fsopen with _SH_DENYWR, not fopen: the game holds this handle for its
        // whole run, and fopen's default share mode makes the log unreadable
        // from outside until the process exits -- which defeats the point of
        // having a log at all.
        f = _fsopen(log_path().c_str(), "w", _SH_DENYWR);
        if (!f) return;
    }
    SYSTEMTIME st{};
    GetLocalTime(&st);
    fprintf(f, "[%02d:%02d:%02d.%03d] ", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
    va_list args;
    va_start(args, fmt);
    vfprintf(f, fmt, args);
    va_end(args);
    fputc('\n', f);
    fflush(f);
}

} // namespace kcdmp
