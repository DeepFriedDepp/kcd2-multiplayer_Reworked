#include "npc_trace.h"
#include "anchors.h"
#include "engine.h"
#include "inline_hook.h"
#include "log.h"
#include "npc_drive.h"

#include <windows.h>
#include <atomic>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

namespace kcdmp::npctrace {

namespace {

// CSystem::Render's first instructions on this build (docs/WO-118-findings.md
// s0): push rsi; push r14; sub rsp,0xD8; mov rsi,rcx -- 14 bytes, no
// RIP-relative operand, no branch. Anything else refuses the hook.
constexpr uint8_t kRenderPrologue[14] = {0x40, 0x56, 0x41, 0x56, 0x48, 0x81, 0xEC, 0xD8, 0x00, 0x00, 0x00, 0x48, 0x8B, 0xF1};

struct Row {
    uint64_t frame;
    double   tms;
    float    hx, hy, hz;      // at the frame hook, before any write
    float    wx, wy, wz;      // what the native writer wrote (wrote == 1)
    float    rx, ry, rz;      // at CSystem::Render entry (NaN without the hook)
    uint8_t  wrote;
    int8_t   flying;          // pe_status_living.bFlying, -1 unreadable
};

std::mutex         g_reqMutex;
bool               g_reqPending = false;
std::string        g_reqName;
uint16_t           g_reqSeconds = 0;

std::atomic<bool>  g_hookTried{false};
std::atomic<bool>  g_hookOk{false};
std::atomic<DoneFn> g_done{nullptr};

// main thread only
bool             g_rec = false;
std::string      g_name;
uint32_t         g_eid = 0;
void*            g_ent = nullptr;
double           g_endAt = 0;
uint64_t         g_frame = 0;
Row              g_cur{};
bool             g_rowPending = false;
std::vector<Row> g_rows;

std::string game_dir() {
    char cwd[MAX_PATH]{};
    if (!GetCurrentDirectoryA(MAX_PATH, cwd) || !cwd[0]) return {};
    std::string p(cwd);
    if (p.back() != '\\') p += '\\';
    return p;
}

void finish(const char* why) {
    if (!g_rec) return;
    g_rec = false;
    g_rowPending = false;
    SYSTEMTIME st{}; GetLocalTime(&st);
    char file[160];
    std::string safe = g_name;
    for (auto& c : safe) if (!(isalnum(static_cast<unsigned char>(c)) || c == '_' || c == '-')) c = '_';
    std::snprintf(file, sizeof(file), "kcdmp-trace-%s-%02d%02d%02d.csv", safe.c_str(), st.wHour, st.wMinute, st.wSecond);
    const std::string path = game_dir() + file;
    FILE* f = std::fopen(path.c_str(), "w");
    if (!f) {
        logf("MP-NPCTRACE npc=%s result=csv-write-failed rows=%zu path=%s", g_name.c_str(), g_rows.size(), path.c_str());
        if (DoneFn fn = g_done.load()) fn(0, "");
        g_rows.clear();
        return;
    }
    std::fprintf(f, "frame,t_ms,hook_x,hook_y,hook_z,wrote,written_x,written_y,written_z,render_x,render_y,render_z,flying\n");
    for (const Row& r : g_rows)
        std::fprintf(f, "%llu,%.3f,%.4f,%.4f,%.4f,%u,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%d\n",
                     static_cast<unsigned long long>(r.frame), r.tms, r.hx, r.hy, r.hz, r.wrote, r.wx, r.wy, r.wz,
                     r.rx, r.ry, r.rz, r.flying);
    std::fclose(f);
    logf("MP-NPCTRACE npc=%s result=written rows=%zu render_hook=%s why=%s path=%s", g_name.c_str(), g_rows.size(),
         g_hookOk ? "on" : "OFF (hook columns only)", why, path.c_str());
    if (DoneFn fn = g_done.load()) fn(static_cast<uint32_t>(g_rows.size()), path.c_str());
    g_rows.clear();
    g_rows.shrink_to_fit();
}

void push_row(bool haveRender) {
    if (!g_rowPending) return;
    g_rowPending = false;
    if (haveRender && g_ent) {
        float p[3];
        if (npcdrive::entity_pos(g_ent, p)) { g_cur.rx = p[0]; g_cur.ry = p[1]; g_cur.rz = p[2]; }
    }
    if (g_rows.size() < 200000) g_rows.push_back(g_cur);
}

// CSystem::Render entry, main thread.
void on_render() {
    if (!g_rec || !g_rowPending) return;
    push_row(true);
    if (npcdrive::now_s() >= g_endAt) finish("duration");
}

void ensure_render_hook() {
    if (g_hookTried.exchange(true)) return;
    HMODULE sys = GetModuleHandleA("CrySystem.dll");
    int n = 0;
    const uint8_t* fn = sys ? anchor::function_by_string(sys, "CSystem::Render", &n) : nullptr;
    if (!fn) {
        logf("MP-NPCTRACE render hook REFUSED -- no single function references \"CSystem::Render\" (found %d); "
             "traces carry the frame-hook columns only", n);
        return;
    }
    const char* why = nullptr;
    const bool ok = inlinehook::install(const_cast<uint8_t*>(fn), kRenderPrologue, sizeof(kRenderPrologue), &on_render, &why);
    char d[96]{}; anchor::describe(fn, d, sizeof(d));
    g_hookOk = ok;
    logf("MP-NPCTRACE render hook %s at %s (%s)", ok ? "installed" : "REFUSED", d, why ? why : "?");
}

} // namespace

void set_done_callback(DoneFn fn) { g_done.store(fn); }

uint8_t request(const char* name, uint16_t seconds) {
    if (!name || !name[0] || std::strlen(name) > 63) return 2;
    if (seconds > 600) seconds = 600;
    if (seconds > 0) ensure_render_hook();   // pipe thread: the patch suspends every other thread, main included
    std::lock_guard<std::mutex> lock(g_reqMutex);
    g_reqPending = true;
    g_reqName = name;
    g_reqSeconds = seconds;
    return 0;
}

void frame_begin(double now) {
    bool have = false; std::string name; uint16_t secs = 0;
    {
        std::lock_guard<std::mutex> lock(g_reqMutex);
        if (g_reqPending) { have = true; name = g_reqName; secs = g_reqSeconds; g_reqPending = false; }
    }
    if (have) {
        if (g_rec) finish(secs == 0 ? "stopped" : "restarted");
        if (secs > 0) {
            void* e = npcdrive::entity_by_name(name.c_str());
            if (!e) {
                logf("MP-NPCTRACE npc=%s result=no-entity", name.c_str());
                if (DoneFn fn = g_done.load()) fn(0, "");
            } else {
                g_rec = true; g_name = name; g_ent = e; g_eid = engine::entity_id(e);
                g_endAt = now + secs; g_frame = 0; g_rows.clear(); g_rows.reserve(static_cast<size_t>(secs) * 120);
                logf("MP-NPCTRACE npc=%s result=recording seconds=%u eid=0x%X render_hook=%s", name.c_str(), secs, g_eid,
                     g_hookOk ? "on" : "OFF");
            }
        }
    }
    if (!g_rec) return;
    if (engine::entity_by_id(g_eid) != g_ent) { finish("entity-gone"); return; }
    // A frame whose render never came (a loading screen, no hook): keep it.
    if (g_rowPending) push_row(false);
    g_cur = Row{};
    g_cur.frame = ++g_frame;
    g_cur.tms = now * 1000.0;
    g_cur.rx = g_cur.ry = g_cur.rz = NAN;
    float p[3];
    if (npcdrive::entity_pos(g_ent, p)) { g_cur.hx = p[0]; g_cur.hy = p[1]; g_cur.hz = p[2]; }
    int fly = 0;
    g_cur.flying = npcdrive::living_flying(g_ent, &fly) ? static_cast<int8_t>(fly) : static_cast<int8_t>(-1);
    g_rowPending = true;
    if (!g_hookOk && now >= g_endAt) { push_row(false); finish("duration"); }
}

void note_write(void* e, const float pose[4]) {
    if (!g_rec || !g_rowPending || e != g_ent) return;
    g_cur.wrote = 1;
    g_cur.wx = pose[0]; g_cur.wy = pose[1]; g_cur.wz = pose[2];
}

void frame_end() {
    if (!g_rec || !g_rowPending || g_hookOk) return;
    push_row(false);
}

} // namespace kcdmp::npctrace
