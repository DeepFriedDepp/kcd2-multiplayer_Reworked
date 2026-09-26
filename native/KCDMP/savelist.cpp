#include "savelist.h"
#include "anchors.h"
#include "log.h"

#include <windows.h>
#include <cstdio>
#include <cstring>

namespace kcdmp::savelist {

namespace {

constexpr const char* kGetGameIface   = "?GetGameIface@wh@@YAPEBVC_GameInterface@shared@1@XZ";
constexpr const char* kAddScriptLock  = "?AddScriptSaveLock@C_PlayerProfileWHManager@framework@wh@@QEAA_NPEBD0@Z";
constexpr const char* kUpdate         = "?UpdateSaveGameDescriptions@C_PlayerProfileWHManager@framework@wh@@QEAAXXZ";
constexpr const char* kCount          = "?GetSaveGameDescriptionCount@C_PlayerProfileWHManager@framework@wh@@QEBAHH@Z";
constexpr const char* kDesc           = "?GetSaveGameDescription@C_PlayerProfileWHManager@framework@wh@@QEBAPEBVC_SaveGameDescription@23@HH@Z";
constexpr const char* kCurrent        = "?GetCurrentPlaylineIdx@C_PlayerProfileWHManager@framework@wh@@QEBAHXZ";
constexpr const char* kNewestIn       = "?GetNewestSavedGameFromPlayline@C_PlayerProfileWHManager@framework@wh@@QEBA_NHAEAH@Z";
constexpr const char* kFilePath       = "?GetFilePath@C_SaveGameDescription@framework@wh@@QEBA?AV?$CryStringT@D@@H@Z";

using GiFn      = void* (*)();
using UpdateFn  = void (*)(void*);
using CountFn   = int (*)(void*, int);
using DescFn    = const void* (*)(void*, int, int);
using CurrentFn = int (*)(void*);
using NewestFn  = bool (*)(void*, int, int*);

bool        g_resolved = false;
bool        g_ok = false;
const char* g_why = "not resolved";
GiFn        g_gi = nullptr;
UpdateFn    g_update = nullptr;
CountFn     g_count = nullptr;
DescFn      g_desc = nullptr;
CurrentFn   g_current = nullptr;
NewestFn    g_newest = nullptr;
size_t      g_mgrOff = 0;     // GetGameIface()->[g_mgrOff] = C_PlayerProfileWHManager*
size_t      g_nameOff = 0;    // C_SaveGameDescription+g_nameOff = CryString base name

// --- SEH islands (no C++ objects needing unwinding in these) -------------------

bool seh_read_ptr(const void* p, void** out) {
    __try { *out = *static_cast<void* const*>(p); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool seh_gi(void** out) {
    __try { *out = g_gi(); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool seh_update(void* mgr) {
    __try { g_update(mgr); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool seh_count(void* mgr, int pl, int* out) {
    __try { *out = g_count(mgr, pl); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool seh_desc(void* mgr, int pl, int i, const void** out) {
    __try { *out = g_desc(mgr, pl, i); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool seh_current(void* mgr, int* out) {
    __try { *out = g_current(mgr); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool seh_newest(void* mgr, int pl, int* idx, bool* out) {
    __try { *out = g_newest(mgr, pl, idx); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
// The CryString's characters, copied out (printable ASCII, <128). Its exact
// shape (bare name, name.whs, or a path) is reduced by base_name() below.
bool seh_raw(const void* desc, char* out, size_t n) {
    out[0] = 0;
    __try {
        const char* s = *reinterpret_cast<const char* const*>(static_cast<const char*>(desc) + g_nameOff);
        if (!s) return false;
        size_t i = 0;
        for (; i + 1 < n; ++i) {
            const char c = s[i];
            if (!c) break;
            if (c < 0x20 || c > 0x7E) { out[0] = 0; return false; }
            out[i] = c;
        }
        if (s[i] != 0 || i == 0) { out[0] = 0; return false; }
        out[i] = 0;
        return true;
    }
    __except (EXCEPTION_EXECUTE_HANDLER) { out[0] = 0; return false; }
}

// "save021", "save021.whs" or ".../playline2/save021.whs" -> "save021";
// false unless the result is [A-Za-z0-9_]+ (the scanner lists only names
// without a space, WO-112 s3.5).
bool base_name(const char* raw, char* out, size_t n) {
    const char* b = raw;
    for (const char* p = raw; *p; ++p) if (*p == '/' || *p == 0x5C) b = p + 1;
    size_t len = std::strlen(b);
    if (len > 4 && _stricmp(b + len - 4, ".whs") == 0) len -= 4;
    if (len == 0 || len + 1 > n) return false;
    for (size_t i = 0; i < len; ++i) {
        const char c = b[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')) return false;
        out[i] = c;
    }
    out[len] = 0;
    return true;
}

bool seh_name(const void* desc, char* out, size_t n) {
    char raw[160];
    out[0] = 0;
    return seh_raw(desc, raw, sizeof(raw)) && base_name(raw, out, n);
}

// The manager's offset off the game interface, lifted from WHGame's own
// Game.AddSaveLock bind: call [GetGameIface] ; <=16 B ; mov rcx,[rax+imm] ;
// <=16 B ; call [AddScriptSaveLock]. The IAT slots are recognised by what they
// hold at runtime (the resolved export), not by an RVA.
bool lift_manager_offset(void* giExport, void* lockExport, size_t* off) {
    HMODULE wh = GetModuleHandleA("WHGame.dll");
    anchor::Range text{};
    if (!wh || !anchor::section(wh, ".text", &text)) return false;
    int found = 0;
    size_t lifted = 0;
    __try {
        for (const uint8_t* p = text.begin; p + 48 < text.end; ++p) {
            if (p[0] != 0xFF || p[1] != 0x15) continue;
            const int32_t d = *reinterpret_cast<const int32_t*>(p + 2);
            void* const* slot = reinterpret_cast<void* const*>(p + 6 + d);
            void* v = nullptr;
            if (!seh_read_ptr(slot, &v) || v != giExport) continue;
            // mov rcx,[rax+imm8] = 48 8B 48 ib ; mov rcx,[rax+imm32] = 48 8B 88 id
            for (const uint8_t* q = p + 6; q < p + 22; ++q) {
                size_t o = 0; const uint8_t* after = nullptr;
                if (q[0] == 0x48 && q[1] == 0x8B && q[2] == 0x48) { o = q[3]; after = q + 4; }
                else if (q[0] == 0x48 && q[1] == 0x8B && q[2] == 0x88) { o = *reinterpret_cast<const uint32_t*>(q + 3); after = q + 7; }
                if (!after) continue;
                for (const uint8_t* r = after; r < after + 16; ++r) {
                    if (r[0] != 0xFF || r[1] != 0x15) continue;
                    const int32_t d2 = *reinterpret_cast<const int32_t*>(r + 2);
                    void* v2 = nullptr;
                    if (seh_read_ptr(reinterpret_cast<void* const*>(r + 6 + d2), &v2) && v2 == lockExport) {
                        if (found && o != lifted) return false;   // two binds disagree: not trusted
                        lifted = o; ++found;
                    }
                    break;
                }
                break;
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
    if (!found || lifted == 0 || lifted > 0x1000) return false;
    *off = lifted;
    return true;
}

// GetFilePath's first read off `this` (rdi): 48 8B 87 id = mov rax,[rdi+imm32],
// followed by the CryString header read 44 8B 48 F4 = mov r9d,[rax-0xC].
bool lift_name_offset(const void* filePath, size_t* off) {
    __try {
        const uint8_t* p = static_cast<const uint8_t*>(filePath);
        for (int i = 0; i < 64; ++i) {
            if (p[i] == 0x48 && p[i + 1] == 0x8B && p[i + 2] == 0x87) {
                const uint32_t o = *reinterpret_cast<const uint32_t*>(p + i + 3);
                const uint8_t* n = p + i + 7;
                if (n[0] == 0x44 && n[1] == 0x8B && n[2] == 0x48 && n[3] == 0xF4 && o > 0 && o < 0x400) {
                    *off = o;
                    return true;
                }
                return false;
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {}
    return false;
}

void* manager() {
    void* gi = nullptr; void* mgr = nullptr;
    if (!seh_gi(&gi) || !gi) return nullptr;
    if (!seh_read_ptr(static_cast<char*>(gi) + g_mgrOff, &mgr)) return nullptr;
    return mgr;
}

} // namespace

bool resolve() {
    if (g_resolved) return g_ok;
    g_resolved = true;
    HMODULE fw = GetModuleHandleA("Framework.dll");
    HMODULE sh = GetModuleHandleA("Shared.dll");
    if (!fw || !sh) { g_why = "Framework.dll or Shared.dll not loaded"; logf("MP-SAVELIST NOT armed: %s", g_why); return false; }
    g_gi      = reinterpret_cast<GiFn>(GetProcAddress(sh, kGetGameIface));
    void* lk  = reinterpret_cast<void*>(GetProcAddress(fw, kAddScriptLock));
    g_update  = reinterpret_cast<UpdateFn>(GetProcAddress(fw, kUpdate));
    g_count   = reinterpret_cast<CountFn>(GetProcAddress(fw, kCount));
    g_desc    = reinterpret_cast<DescFn>(GetProcAddress(fw, kDesc));
    g_current = reinterpret_cast<CurrentFn>(GetProcAddress(fw, kCurrent));
    g_newest  = reinterpret_cast<NewestFn>(GetProcAddress(fw, kNewestIn));
    void* fp  = reinterpret_cast<void*>(GetProcAddress(fw, kFilePath));
    if (!g_gi || !lk || !g_update || !g_count || !g_desc || !g_current || !g_newest || !fp) {
        g_why = "a Framework/Shared export is missing";
        logf("MP-SAVELIST NOT armed: %s (gi=%p lock=%p update=%p count=%p desc=%p current=%p newest=%p filepath=%p)",
             g_why, reinterpret_cast<void*>(g_gi), lk, reinterpret_cast<void*>(g_update), reinterpret_cast<void*>(g_count),
             reinterpret_cast<void*>(g_desc), reinterpret_cast<void*>(g_current), reinterpret_cast<void*>(g_newest), fp);
        return false;
    }
    if (!lift_manager_offset(reinterpret_cast<void*>(g_gi), lk, &g_mgrOff)) {
        g_why = "the manager offset could not be lifted from WHGame's AddSaveLock bind";
        logf("MP-SAVELIST NOT armed: %s", g_why);
        return false;
    }
    if (!lift_name_offset(fp, &g_nameOff)) {
        g_why = "the file-name offset could not be lifted from C_SaveGameDescription::GetFilePath";
        logf("MP-SAVELIST NOT armed: %s", g_why);
        return false;
    }
    g_ok = true;
    g_why = "";
    char d[96]{};
    anchor::describe(reinterpret_cast<void*>(g_update), d, sizeof(d));
    logf("MP-SAVELIST armed: UpdateSaveGameDescriptions=%s manager=GetGameIface()+0x%zX (lifted from Game.AddSaveLock) "
         "name=desc+0x%zX (lifted from GetFilePath)", d, g_mgrOff, g_nameOff);
    return true;
}

bool ready() { return g_ok; }
const char* why_not() { return g_why; }

Report query(bool rescan, int playline, const char* name) {
    Report r{};
    if (!resolve()) return r;
    void* mgr = manager();
    if (!mgr) { logf("MP-SAVELIST query: no manager (GetGameIface()->+0x%zX null)", g_mgrOff); return r; }
    if (rescan && !seh_update(mgr)) { logf("MP-SAVELIST UpdateSaveGameDescriptions FAULTED"); return r; }
    if (!seh_current(mgr, &r.current)) return r;
    if (playline >= 0) {
        if (!seh_count(mgr, playline, &r.count) || r.count < 0 || r.count > 4096) return r;
        for (int i = 0; i < r.count && name && name[0]; ++i) {
            const void* d = nullptr; char nm[64];
            if (!seh_desc(mgr, playline, i, &d) || !d) continue;
            if (seh_name(d, nm, sizeof(nm)) && _stricmp(nm, name) == 0) { r.listed = true; r.idx = i; break; }
        }
    }
    bool have = false; int ci = -1;
    if (r.current >= 0 && seh_newest(mgr, r.current, &ci, &have) && have) {
        const void* d = nullptr;
        r.contPlayline = r.current;
        r.contIdx = ci;
        if (seh_desc(mgr, r.current, ci, &d) && d) seh_name(d, r.contName, sizeof(r.contName));
    }
    r.ok = true;
    return r;
}

void test_watch() {
    static DWORD checkedAt = 0;
    static char last[160]{};
    const DWORD now = GetTickCount();
    if (now - checkedAt < 1000) return;
    checkedAt = now;
    char cwd[MAX_PATH]{}, path[MAX_PATH]{};
    if (!GetCurrentDirectoryA(MAX_PATH, cwd) || !cwd[0]) return;
    _snprintf_s(path, sizeof(path), _TRUNCATE, "%s%skcdmp-savelist-test.txt", cwd,
                (cwd[std::strlen(cwd) - 1] == '\\') ? "" : "\\");
    char text[160]{};
    FILE* f = nullptr;
    if (fopen_s(&f, path, "r") != 0 || !f) { last[0] = 0; return; }
    const size_t n = std::fread(text, 1, sizeof(text) - 1, f);
    text[n] = 0;
    std::fclose(f);
    if (std::strcmp(text, last) == 0) return;
    std::strcpy(last, text);
    char* nl = std::strpbrk(text, "\r\n");
    if (nl) *nl = 0;
    if (!text[0]) return;
    int pl = -1; char nm[64]{};
    if (std::sscanf(text, "list %d", &pl) == 1) {
        if (!resolve()) { logf("MP-SAVELIST-TEST not armed: %s", g_why); return; }
        void* mgr = manager();
        int cnt = -1;
        if (!mgr || !seh_update(mgr) || !seh_count(mgr, pl, &cnt)) { logf("MP-SAVELIST-TEST list %d: unreadable", pl); return; }
        logf("MP-SAVELIST-TEST list playline%d count=%d", pl, cnt);
        for (int i = 0; i < cnt && i < 400; ++i) {
            const void* d = nullptr; char raw[160], s[64];
            const bool okRaw = seh_desc(mgr, pl, i, &d) && d && seh_raw(d, raw, sizeof(raw));
            if (okRaw && base_name(raw, s, sizeof(s))) logf("MP-SAVELIST-TEST   [%d] %s", i, s);
            else logf("MP-SAVELIST-TEST   [%d] <unreadable%s%s>", i, okRaw ? ": " : "", okRaw ? raw : "");
        }
    } else if (std::sscanf(text, "find %d %63s", &pl, nm) == 2) {
        const Report r = query(true, pl, nm);
        logf("MP-SAVELIST-TEST find playline%d/%s -> ok=%d listed=%d idx=%d count=%d current=%d continue=playline%d/%s",
             pl, nm, r.ok, r.listed, r.idx, r.count, r.current, r.contPlayline, r.contName[0] ? r.contName : "-");
    } else if (std::strncmp(text, "continue", 8) == 0) {
        const Report r = query(true, -1, nullptr);
        logf("MP-SAVELIST-TEST continue -> ok=%d current=%d continue=playline%d/%s (idx %d)",
             r.ok, r.current, r.contPlayline, r.contName[0] ? r.contName : "-", r.contIdx);
    } else {
        logf("MP-SAVELIST-TEST unknown \"%s\" (list <pl> | find <pl> <name> | continue)", text);
    }
}

} // namespace kcdmp::savelist
