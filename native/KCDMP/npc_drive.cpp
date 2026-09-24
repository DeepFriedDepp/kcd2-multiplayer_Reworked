#include "npc_drive.h"
#include "anchors.h"
#include "engine.h"
#include "log.h"
#include "main_thread.h"
#include "npc_trace.h"
#include "respawn_actions.h"

#include <windows.h>
#include <atomic>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace kcdmp::npcdrive {

namespace {

// ---------------------------------------------------------------------------
// Anchors (docs/WO-118-findings.md s0). Every slot below was read out of this
// build's binaries with a disassembler and is re-checked at install by the
// bytes its function must contain -- the RVA is never used.
//
// IEntity (CryEntitySystem CEntity, RTTI .?AVCEntity@@):
//   0x0D8 GetParent        m_hierarchy(+0x98) -> pParent(+0x18)
//   0x160 GetScale         lea rax,[this+0x4C]
//   0x168 SetPosRotScale   (pos*, rot*, scale*, uint32 flags): compares
//                          +0x30/+0x3C/+0x4C, InvalidateTM(flags|2|4|8) only
//                          on a change (an identical write is free)
//   0x278 GetPhysics       GetProxy(1)->vtbl[0xB0](), rope proxy (12) fallback
// IPhysicalEntity (CryPhysics CLivingEntity, RTTI .?AVCLivingEntity@@):
//   0x20  SetParams(pe_params*, int bThreadSafe) -- tests
//         bRecalcBounds(+0x3C) & 0x20 before releasing the ground collider
//   0x30  GetStatus(pe_status*) -- pe_status_living (type 2): bFlying at +4
// pe_params_pos (type 0): pos +0x04, q +0x10 (x,y,z,w), scale +0x20,
//   pMtx3x4 +0x28, pMtx3x3 +0x30, iSimClass +0x38, bRecalcBounds +0x3C,
//   bEntGridUseOBB +0x40 -- read out of CPhysicalEntity::SetParams.
// ---------------------------------------------------------------------------
constexpr size_t kEntGetParent      = 0x0D8;
constexpr size_t kEntGetScale       = 0x160;
constexpr size_t kEntSetPosRotScale = 0x168;
constexpr size_t kEntGetPhysics     = 0x278;
constexpr size_t kPhysSetParams     = 0x20;
constexpr size_t kPhysGetStatus     = 0x30;
constexpr size_t kOffWorldX = 0x64, kOffWorldY = 0x74, kOffWorldZ = 0x84;   // CEntity world matrix translation

constexpr int      kPePosType       = 0;
constexpr int      kPeStatusLiving  = 2;
constexpr uint32_t kRecalcKeepGround = 0x21;         // bit 1 (recalc bounds) | bit 32 (no real-move response)
constexpr uint32_t kUnusedFloat     = 0xFFBFFFFFu;   // the physics "unused" float marker
constexpr uint32_t kUnusedInt       = 0x80000000u;

constexpr double kSilenceS      = 4.0;    // Lua releases a puppet at 3 s; the DLL stops a hair later on its own
constexpr double kStreamForgetS = 15.0;   // an unbound stream entry is forgotten after this much silence
constexpr int    kRingDepth     = 8;      // Lua keeps 3 (enough at 100 ms samples); a faster stream (a ghost, ~30 Hz) needs delay/period + 2
constexpr double kClockResetS   = 5.0;    // a source silent this long gets a fresh offset estimate (a reconnect reuses relay ids)
constexpr double kSeqRestartS   = 2.0;    // a stream silent this long may restart its sequence (a sender restart)
constexpr float  kSnapM2        = 25.0f;  // mp_npc_ring_push: an XY step over 5 m is a teleport
constexpr size_t kMaxBound      = 160;    // puppets written per frame, at most
constexpr size_t kMaxStreams    = 512;
constexpr size_t kMaxInbox      = 8192;
constexpr double kPullWindowS   = 10.0;
constexpr float  kPullFloorCm   = 0.1f;   // a frame counts as "moved" above 1 mm

std::atomic<bool> g_armed{false};
std::atomic<bool> g_nativeOn{true};       // mp_npc_native_write (default on, WO-118)
std::atomic<bool> g_senderClock{true};    // mp_npc_senderclock mirror
std::atomic<bool> g_dropAll{false};
std::atomic<DropFn> g_dropFn{nullptr};

void* const* g_vftEntity = nullptr;
void* const* g_vftLiving = nullptr;
double       g_qpcPeriod = 0;

// status counters (read from the pipe thread)
std::atomic<uint16_t> g_statBound{0};
std::atomic<uint16_t> g_statWriting{0};
std::atomic<uint32_t> g_statFrames{0};
std::atomic<uint32_t> g_statWrites{0};
std::atomic<uint32_t> g_statDrops{0};
std::atomic<uint32_t> g_statSamples{0};

// ---- SEH-isolated engine calls (no destructible locals, MSVC C2712) ----------
bool rd_ptr(const void* base, size_t off, void** out) {
    __try { *out = *reinterpret_cast<void* const*>(static_cast<const char*>(base) + off); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool rd_f(const void* base, size_t off, float* out) {
    __try { *out = *reinterpret_cast<const float*>(static_cast<const char*>(base) + off); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
void* vslot(void* obj, size_t off) {
    void* vt = nullptr; void* fn = nullptr;
    if (!obj || !rd_ptr(obj, 0, &vt) || !vt || !rd_ptr(vt, off, &fn)) return nullptr;
    return fn;
}
bool is_a(void* obj, void* const* vft) {
    void* vp = nullptr;
    return obj && vft && rd_ptr(obj, 0, &vp) && vp == static_cast<const void*>(vft);
}
bool call_ptr0(void* fn, void* self, void** out) {
    __try { *out = reinterpret_cast<void* (*)(void*)>(fn)(self); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_int2(void* fn, void* self, void* arg, int arg2, int* out) {
    __try { *out = reinterpret_cast<int (*)(void*, void*, int)>(fn)(self, arg, arg2); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_int1(void* fn, void* self, void* arg, int* out) {
    __try { *out = reinterpret_cast<int (*)(void*, void*)>(fn)(self, arg); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_prs(void* fn, void* self, const float* pos, const float* q, const float* scale) {
    __try { reinterpret_cast<void (*)(void*, const float*, const float*, const float*, uint32_t)>(fn)(self, pos, q, scale, 0u); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool copy_name(const char* s, char* out, size_t n) {
    __try {
        size_t i = 0;
        for (; i + 1 < n && s[i]; ++i) out[i] = s[i];
        out[i] = 0;
        return i > 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) { if (n) out[0] = 0; return false; }
}

// ---- engine helpers built on the above ----------------------------------------
void* get_physics(void* e) {
    void* fn = vslot(e, kEntGetPhysics); void* p = nullptr;
    return (fn && call_ptr0(fn, e, &p)) ? p : nullptr;
}
bool get_parent(void* e, void** out) {
    void* fn = vslot(e, kEntGetParent);
    return fn && call_ptr0(fn, e, out);
}
bool get_scale(void* e, float out[3]) {
    void* fn = vslot(e, kEntGetScale); void* p = nullptr;
    if (!fn || !call_ptr0(fn, e, &p) || !p) return false;
    return rd_f(p, 0, &out[0]) && rd_f(p, 4, &out[1]) && rd_f(p, 8, &out[2]);
}
bool read_pos(void* e, float out[3]) {
    return rd_f(e, kOffWorldX, &out[0]) && rd_f(e, kOffWorldY, &out[1]) && rd_f(e, kOffWorldZ, &out[2]) &&
           std::isfinite(out[0]) && std::isfinite(out[1]) && std::isfinite(out[2]);
}
bool get_status_flying(void* phys, int* flying) {
    alignas(16) uint8_t st[0x100]{};
    std::memcpy(st, &kPeStatusLiving, 4);
    void* fn = vslot(phys, kPhysGetStatus);
    int r = 0;
    if (!fn || !call_int1(fn, phys, st, &r) || r == 0) return false;
    int f = 0; std::memcpy(&f, st + 4, 4);
    *flying = f;
    return f == 0 || f == 1;
}

std::string lower(const char* s) {
    std::string o(s);
    for (auto& c : o) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return o;
}

// ---- the inbox (pipe thread -> main thread) -----------------------------------
struct InSample {
    uint8_t  src = 0;
    char     name[64]{};
    float    x = 0, y = 0, z = 0, rot = 0;
    uint8_t  flags = 0;
    uint16_t seq = 0;
    uint32_t senderMs = 0;
    int64_t  arrivalQpc = 0;
};
struct InHold { char name[64]{}; uint16_t ms = 0; };

std::mutex            g_inboxMutex;
std::vector<InSample> g_inSamples;
std::vector<InHold>   g_inHolds;

// ---- main-thread state --------------------------------------------------------
struct RingSample { float x, y, z, rot; double at; };
struct Stream {
    std::string name;             // as received (for logs)
    RingSample  ring[kRingDepth]{};
    int         n = 0;
    bool        haveSeq = false;
    uint16_t    lastSeq = 0;
    uint8_t     flags = 0;
    uint8_t     src = 0;
    double      lastSampleAt = 0;   // local clock of the last sample (accepted or not)
    double      lastAcceptedAt = 0; // local clock of the last sample that entered the ring
};
struct SenderClock { double curMin = 1e300, curStart = 0, prevMin = 1e300, lastSeen = 0; bool havePrev = false; bool init = false; };

struct Puppet {
    std::string key, name;
    uint32_t eid = 0;
    void*    ent = nullptr;
    uint64_t wuid = 0;
    float    anchor[3]{};
    double   delay = 0.12;
    double   holdUntil = 0;
    bool     haveLast = false;
    float    last[3]{};
    bool     havePrev = false;      // the write before `last`
    float    prev[3]{};
    float    lastRot = 0;
    uint64_t writes = 0;
    uint32_t frameNo = 0;
    // MP-NPCPULL window
    double   winStart = 0;
    uint32_t winFrames = 0, winMoved = 0, winFlyChecks = 0, winFlying = 0, cosN = 0, winLag = 0;
    double   sumCm = 0, maxCm = 0, sumDzCm = 0, cosSum = 0;
};

std::unordered_map<std::string, Stream> g_streams;
std::unordered_map<std::string, Puppet> g_bound;
SenderClock g_clocks[256];
double      g_lastPrune = 0;
bool        g_announcedFault = false;

double qpc_to_s(int64_t q) { return static_cast<double>(q) * g_qpcPeriod; }

void notify_drop(uint8_t reason, const std::string& name) {
    g_statDrops.fetch_add(1, std::memory_order_relaxed);
    if (DropFn fn = g_dropFn.load()) fn(reason, name.c_str());
}

void drop(std::unordered_map<std::string, Puppet>::iterator it, uint8_t reason, bool tell) {
    logf("MP-NPCWRITE npc=%s event=drop reason=%s eid=0x%X writes=%llu", it->second.name.c_str(), reason_name(reason),
         it->second.eid, static_cast<unsigned long long>(it->second.writes));
    if (tell) notify_drop(reason, it->second.name);
    g_bound.erase(it);
}

// WO-110 R6, ported from kdcmp.lua mp_sender_stamp: the per-source offset
// (receiver clock minus sender seconds) as a rolling two-window minimum, so
// arrival jitter never moves a sample on the timeline, only when it is seen.
double sender_stamp(uint8_t src, uint32_t senderMs, double nowPkt) {
    if (!g_senderClock.load(std::memory_order_relaxed) || senderMs == 0) return nowPkt;
    const double senderS = senderMs / 1000.0;
    SenderClock& sc = g_clocks[src];
    // A source silent for kClockResetS starts over: the relay hands a
    // reconnecting peer the same id, and the old minimum (possibly from a
    // faster link, or another clock epoch) would shrink the render buffer for
    // up to a minute. Observed solo, WO-118 s6 (the first noise runs).
    if (!sc.init || nowPkt - sc.lastSeen > kClockResetS) { sc = SenderClock{}; sc.init = true; sc.curStart = nowPkt; }
    sc.lastSeen = nowPkt;
    const double off = nowPkt - senderS;
    if (off < sc.curMin) sc.curMin = off;
    if (nowPkt - sc.curStart > 30.0) { sc.prevMin = sc.curMin; sc.havePrev = true; sc.curMin = off; sc.curStart = nowPkt; }
    double eff = sc.curMin;
    if (sc.havePrev && sc.prevMin < eff) eff = sc.prevMin;
    double at = senderS + eff;
    if (at > nowPkt) at = nowPkt;
    if (at < nowPkt - 30.0) at = nowPkt;
    return at;
}

void push_sample(const InSample& in, double now) {
    const std::string key = lower(in.name);
    auto it = g_streams.find(key);
    if (it == g_streams.end()) {
        if (g_streams.size() >= kMaxStreams) return;
        it = g_streams.emplace(key, Stream{}).first;
        it->second.name = in.name;
    }
    Stream& s = it->second;
    // WO-110 R6 sequence accounting: a duplicate or an older sample (two
    // flushes reordered) proves the stream alive but never re-enters the ring.
    // A stream silent for kSeqRestartS is a restarted sender (its per-NPC seq
    // starts over): without this a stream back inside the 15 s forget window
    // was rejected as "older" until its seq passed the old one -- a bound,
    // frozen puppet (observed solo, WO-118: writes=1 after a peer restart).
    if (s.haveSeq && now - s.lastAcceptedAt > kSeqRestartS) s.haveSeq = false;
    bool seqOk = true;
    if (s.haveSeq) {
        const uint16_t d = static_cast<uint16_t>(in.seq - s.lastSeq);
        if (d == 0 || d > 32768) seqOk = false;
    }
    s.lastSampleAt = now;
    s.src = in.src;
    if (!seqOk) return;
    s.haveSeq = true; s.lastSeq = in.seq; s.lastAcceptedAt = now;
    s.flags = in.flags;
    double nowPkt = now;
    if (in.arrivalQpc > 0) {
        const double a = qpc_to_s(in.arrivalQpc);
        if (a <= now && a > now - 5.0) nowPkt = a;   // the agent's own arrival stamp, same QPC
    }
    const double at = sender_stamp(in.src, in.senderMs, nowPkt);
    RingSample r{ in.x, in.y, in.z, in.rot, at };
    if (s.n > 0) {
        const RingSample& lastS = s.ring[s.n - 1];
        const float dx = in.x - lastS.x, dy = in.y - lastS.y;
        if (dx * dx + dy * dy > kSnapM2) s.n = 0;   // a teleport is never smoothed (mp_npc_ring_push)
    }
    if (s.n == kRingDepth) { for (int i = 1; i < kRingDepth; ++i) s.ring[i - 1] = s.ring[i]; s.n = kRingDepth - 1; }
    s.ring[s.n++] = r;
}

float lerp_angle(float a, float b, float t) {
    const double twopi = 6.283185307179586;
    double diff = static_cast<double>(b) - a;
    diff = diff - std::floor((diff + 3.141592653589793) / twopi) * twopi;
    return static_cast<float>(a + diff * t);
}

// kdcmp.lua mp_npc_smooth_render, position/yaw half (the anim speed stays in Lua).
bool render(const Stream& s, double renderAt, double delay, float out[4]) {
    const int n = s.n;
    if (n == 0) return false;
    const RingSample* a = nullptr; const RingSample* b = nullptr;
    if (renderAt >= s.ring[n - 1].at) { a = b = &s.ring[n - 1]; }          // past the newest: hold, never extrapolate
    else if (renderAt <= s.ring[0].at) { a = b = &s.ring[0]; }             // before the oldest: hold at oldest
    else {
        for (int i = n - 1; i >= 1; --i)
            if (s.ring[i - 1].at <= renderAt) { a = &s.ring[i - 1]; b = &s.ring[i]; break; }
        if (!a) { a = b = &s.ring[0]; }
    }
    if (a == b) { out[0] = a->x; out[1] = a->y; out[2] = a->z; out[3] = a->rot; return true; }
    double aAt = a->at;
    if (b->at - aAt > delay) aAt = b->at - delay;                          // clip a moved-gated silence to one delay
    double segDur = b->at - aAt;
    if (segDur < 0.05) segDur = 0.05;
    double t = (renderAt - aAt) / segDur;
    if (t < 0) t = 0; else if (t > 1) t = 1;
    const float tf = static_cast<float>(t);
    out[0] = a->x + (b->x - a->x) * tf;
    out[1] = a->y + (b->y - a->y) * tf;
    out[2] = a->z + (b->z - a->z) * tf;                                    // WO-110 R14: Z on the same segment
    out[3] = lerp_angle(a->rot, b->rot, tf);
    return true;
}

// The seed at bind: the body's current pose stamped one delay in the past, so
// the first write continues from where Lua left the body (WO-77's seed).
void seed(Stream& s, const float pos[3], float rot, double at) {
    int keep = 0;
    RingSample tmp[kRingDepth];
    for (int i = 0; i < s.n; ++i) if (s.ring[i].at > at) tmp[keep++] = s.ring[i];
    s.n = 0;
    s.ring[s.n++] = RingSample{ pos[0], pos[1], pos[2], rot, at };
    for (int i = 0; i < keep && s.n < kRingDepth; ++i) s.ring[s.n++] = tmp[i];
}

float yaw_of(void* e) {
    // Rotation from the world matrix: atan2(m10, m00) (npc_scan.cpp's read).
    float m00 = 1, m10 = 0;
    rd_f(e, 0x58 + 0x00, &m00);
    rd_f(e, 0x58 + 0x10, &m10);
    const float y = std::atan2(m10, m00);
    return std::isfinite(y) ? y : 0.0f;
}

void pull_flush(Puppet& p, double now) {
    if (p.winFrames > 0 && p.maxCm >= kPullFloorCm) {
        const float ax = p.anchor[0] - p.last[0], ay = p.anchor[1] - p.last[1];
        logf("MP-NPCPULL npc=%s mean_cm=%.2f max_cm=%.2f frames=%u moved_frames=%u toward_anchor_cos=%.2f anchor_m=%.1f "
             "dz_mean_cm=%.2f lag_frames=%u flying=%u/%u window_s=%.0f",
             p.name.c_str(), p.sumCm / p.winFrames, p.maxCm, p.winFrames, p.winMoved,
             p.cosN ? p.cosSum / p.cosN : 0.0, std::sqrt(ax * ax + ay * ay),
             p.sumDzCm / p.winFrames, p.winLag, p.winFlying, p.winFlyChecks, now - p.winStart);
    }
    p.winStart = now; p.winFrames = p.winMoved = p.winFlyChecks = p.winFlying = p.cosN = p.winLag = 0;
    p.sumCm = p.maxCm = p.sumDzCm = p.cosSum = 0;
}

// One puppet, one frame. Returns false on an engine fault (the caller disarms).
bool write_one(Puppet& p, void* e, const float pose[4], bool* wrote) {
    *wrote = false;
    float cur[3]{};
    const bool haveCur = read_pos(e, cur);

    // Phase 4: how far did the ENGINE move the body since our last write?
    // One case is not a pull: the physics body lags a write that was queued
    // while physics stepped, and its write-back restores the write BEFORE the
    // last one exactly (observed: hook(n) == written(n-2) to 0.00 cm on every
    // such frame of a walker). Counted as lag_frames, kept out of the pull.
    bool lag = false;
    if (p.haveLast && p.havePrev && haveCur) {
        const float lx = cur[0] - p.prev[0], ly = cur[1] - p.prev[1], lz = cur[2] - p.prev[2];
        const float mx = cur[0] - p.last[0], my = cur[1] - p.last[1], mz = cur[2] - p.last[2];
        lag = (lx * lx + ly * ly + lz * lz) < 0.002f * 0.002f && (mx * mx + my * my + mz * mz) > 0.001f * 0.001f;
    }
    if (lag) {
        ++p.winFrames;
        ++p.winLag;
    } else if (p.haveLast && haveCur) {
        const float dx = cur[0] - p.last[0], dy = cur[1] - p.last[1], dz = cur[2] - p.last[2];
        const double cm = std::sqrt(static_cast<double>(dx) * dx + static_cast<double>(dy) * dy + static_cast<double>(dz) * dz) * 100.0;
        ++p.winFrames;
        p.sumCm += cm;
        p.sumDzCm += dz * 100.0;
        if (cm > p.maxCm) p.maxCm = cm;
        if (cm > kPullFloorCm) {
            ++p.winMoved;
            const float ax = p.anchor[0] - p.last[0], ay = p.anchor[1] - p.last[1];
            const float al = std::sqrt(ax * ax + ay * ay), dl = std::sqrt(dx * dx + dy * dy);
            if (al > 0.5f && dl > 0.001f) { p.cosSum += (dx * ax + dy * ay) / (al * dl); ++p.cosN; }
        }
    }

    // Nothing to do: the pose is the one we wrote and nothing moved the body.
    if (p.haveLast && haveCur && pose[0] == p.last[0] && pose[1] == p.last[1] && pose[2] == p.last[2] &&
        pose[3] == p.lastRot && cur[0] == p.last[0] && cur[1] == p.last[1] && cur[2] == p.last[2])
        return true;

    const float half = pose[3] * 0.5f;
    const float q[4] = { 0.0f, 0.0f, std::sin(half), std::cos(half) };   // CryEngine Quat memory order: x, y, z, w
    float scale[3] = { 1, 1, 1 };
    get_scale(e, scale);

    // 1. The living body, keeping its ground collider (bit 32).
    void* phys = get_physics(e);
    if (phys && is_a(phys, g_vftLiving)) {
        alignas(16) uint8_t pp[0x80]{};
        std::memcpy(pp + 0x00, &kPePosType, 4);
        std::memcpy(pp + 0x04, pose, 12);
        std::memcpy(pp + 0x10, q, 16);
        std::memcpy(pp + 0x20, &kUnusedFloat, 4);
        std::memcpy(pp + 0x38, &kUnusedInt, 4);
        std::memcpy(pp + 0x3C, &kRecalcKeepGround, 4);
        void* fn = vslot(phys, kPhysSetParams);
        int r = 0;
        if (!fn || !call_int2(fn, phys, pp, 0, &r)) return false;
    }
    // 2. The entity (the render, the animated character's teleport re-base,
    //    and the proxy's follow-up physics move, now zero-length).
    void* prs = vslot(e, kEntSetPosRotScale);
    if (!prs || !call_prs(prs, e, pose, q, scale)) return false;

    if (p.haveLast) { p.prev[0] = p.last[0]; p.prev[1] = p.last[1]; p.prev[2] = p.last[2]; p.havePrev = true; }
    p.last[0] = pose[0]; p.last[1] = pose[1]; p.last[2] = pose[2]; p.lastRot = pose[3];
    p.haveLast = true;
    ++p.writes;
    *wrote = true;

    if ((++p.frameNo % 5) == 0 && phys && is_a(phys, g_vftLiving)) {
        int fly = 0;
        if (get_status_flying(phys, &fly)) { ++p.winFlyChecks; if (fly) ++p.winFlying; }
    }
    return true;
}

void disarm(const char* why) {
    if (!g_armed.exchange(false)) return;
    logf("MP-NPCWRITE DISARMED -- %s; every bound puppet dropped, Lua writes them again", why);
    for (auto it = g_bound.begin(); it != g_bound.end();) {
        notify_drop(kFault, it->second.name);
        it = g_bound.erase(it);
    }
    g_statBound.store(0);
}

} // namespace

const char* reason_name(uint8_t r) {
    switch (r) {
        case kOk: return "ok";
        case kDisarmed: return "disarmed";
        case kToggleOff: return "toggle-off";
        case kNoEntity: return "no-entity";
        case kNameMismatch: return "name-mismatch";
        case kWuidMismatch: return "wuid-mismatch";
        case kNotLiving: return "not-living";
        case kParented: return "parented";
        case kBadRequest: return "bad-request";
        case kEntityGone: return "entity-gone";
        case kSilence: return "silence";
        case kFault: return "fault";
        case kUnbound: return "unbound";
        case kTableFull: return "table-full";
        case kPipeClosed: return "pipe-closed";
        default: return "?";
    }
}

double now_s() {
    LARGE_INTEGER q; QueryPerformanceCounter(&q);
    return qpc_to_s(q.QuadPart);
}

bool entity_pos(void* e, float out[3]) { return e && read_pos(e, out); }

namespace {
struct FindCtx { const char* name; void* found; };
bool find_visit(void* e, void* ctx) {
    auto* c = static_cast<FindCtx*>(ctx);
    const char* n = engine::entity_name(e);
    char buf[64];
    if (!n || !copy_name(n, buf, sizeof(buf))) return false;
    if (_stricmp(buf, c->name) == 0) { c->found = e; return true; }
    return false;
}
} // namespace

void* entity_by_name(const char* name) {
    FindCtx c{ name, nullptr };
    engine::for_each_entity(&find_visit, &c);
    return c.found;
}

bool living_flying(void* e, int* flying) {
    void* phys = get_physics(e);
    return phys && is_a(phys, g_vftLiving) && get_status_flying(phys, flying);
}

void install() {
    LARGE_INTEGER f; QueryPerformanceFrequency(&f);
    g_qpcPeriod = 1.0 / static_cast<double>(f.QuadPart);
    // Posted whatever the anchors say: the trace (mp_npc_trace) must run on
    // the legacy Lua path too -- that is the A/B the WO-118 gate asks for.
    main_thread::post_repeating(&tick);

    auto fail = [](const char* why) {
        logf("WO118-NATIVE native_write=DISARMED reason=\"%s\" -- Lua keeps writing every puppet (the 50 ms path)", why);
    };
    if (!engine::resolve()) { fail("engine services (gEnv / entity system) did not resolve"); return; }
    HMODULE es = GetModuleHandleA("CryEntitySystem.dll");
    HMODULE ph = GetModuleHandleA("CryPhysics.dll");
    if (!es || !ph) { fail("CryEntitySystem.dll or CryPhysics.dll not loaded"); return; }
    g_vftEntity = anchor::find_vftable(es, ".?AVCEntity@@", 0);
    g_vftLiving = anchor::find_vftable(ph, ".?AVCLivingEntity@@", 0);
    if (!g_vftEntity || !g_vftLiving) { fail("RTTI CEntity / CLivingEntity vftable not unique"); return; }

    struct Check { HMODULE mod; void* const* vft; size_t slot; const char* what; std::vector<std::vector<uint8_t>> pats; };
    const Check checks[] = {
        { es, g_vftEntity, kEntSetPosRotScale, "IEntity::SetPosRotScale (0x168)",
          { {0x41, 0xF6, 0xC3, 0x20}, {0x41, 0x0F, 0xBA, 0xE3, 0x0D}, {0x0F, 0x11, 0x47, 0x3C} } },
        { es, g_vftEntity, kEntGetScale, "IEntity::GetScale (0x160)", { {0x48, 0x8D, 0x43, 0x4C} } },
        { es, g_vftEntity, kEntGetParent, "IEntity::GetParent (0xD8)",
          { {0x48, 0x8B, 0x83, 0x98, 0x00, 0x00, 0x00}, {0x48, 0x8B, 0x40, 0x18} } },
        { es, g_vftEntity, kEntGetPhysics, "IEntity::GetPhysics (0x278)",
          { {0xBA, 0x01, 0x00, 0x00, 0x00}, {0xFF, 0x92, 0xB0, 0x00, 0x00, 0x00}, {0xBA, 0x0C, 0x00, 0x00, 0x00} } },
        { ph, g_vftLiving, kPhysSetParams, "CLivingEntity::SetParams (0x20, bRecalcBounds & 32 test)",
          { {0xF6, 0x46, 0x3C, 0x20} } },
    };
    for (const auto& c : checks) {
        const void* fn = c.vft[c.slot / 8];
        for (const auto& pat : c.pats) {
            if (!anchor::function_has_bytes(c.mod, fn, pat.data(), pat.size())) {
                char d[128]{}; anchor::describe(fn, d, sizeof(d));
                char why[256]; std::snprintf(why, sizeof(why), "%s at %s lacks its expected instruction bytes", c.what, d);
                fail(why);
                return;
            }
        }
    }
    char dPrs[96]{}, dSp[96]{};
    anchor::describe(g_vftEntity[kEntSetPosRotScale / 8], dPrs, sizeof(dPrs));
    anchor::describe(g_vftLiving[kPhysSetParams / 8], dSp, sizeof(dSp));
    g_armed = true;
    logf("WO118-NATIVE native_write=armed on=%s senderclock=%s setposrotscale=%s living_setparams=%s recalc=0x%X "
         "-- per-frame write at the frame hook, ground collider kept (bit 32), MP-NPCPULL per puppet",
         g_nativeOn ? "on" : "off", g_senderClock ? "on" : "off", dPrs, dSp, kRecalcKeepGround);
}

bool armed() { return g_armed.load(); }

void set_drop_callback(DropFn fn) { g_dropFn.store(fn); }

// ---- pipe thread --------------------------------------------------------------
uint8_t on_samples(const uint8_t* body, size_t len) {
    if (len < 1) return kBadRequest;
    const int count = body[0];
    size_t o = 1;
    std::vector<InSample> batch;
    batch.reserve(count);
    for (int i = 0; i < count; ++i) {
        if (o + 2 > len) return kBadRequest;
        InSample s{};
        s.src = body[o];
        const uint8_t nl = body[o + 1];
        o += 2;
        if (nl == 0 || nl > 63 || o + nl + 16 + 1 + 2 + 4 + 8 > len) return kBadRequest;
        std::memcpy(s.name, body + o, nl); s.name[nl] = 0; o += nl;
        std::memcpy(&s.x, body + o, 4); std::memcpy(&s.y, body + o + 4, 4);
        std::memcpy(&s.z, body + o + 8, 4); std::memcpy(&s.rot, body + o + 12, 4); o += 16;
        s.flags = body[o]; o += 1;
        std::memcpy(&s.seq, body + o, 2); o += 2;
        std::memcpy(&s.senderMs, body + o, 4); o += 4;
        std::memcpy(&s.arrivalQpc, body + o, 8); o += 8;
        if (!std::isfinite(s.x) || !std::isfinite(s.y) || !std::isfinite(s.z) || !std::isfinite(s.rot)) continue;
        batch.push_back(s);
    }
    if (o != len) return kBadRequest;
    {
        std::lock_guard<std::mutex> lock(g_inboxMutex);
        if (g_inSamples.size() + batch.size() > kMaxInbox) g_inSamples.clear();   // a wedged frame loop: keep only the newest
        g_inSamples.insert(g_inSamples.end(), batch.begin(), batch.end());
    }
    g_statSamples.fetch_add(static_cast<uint32_t>(batch.size()), std::memory_order_relaxed);
    return kOk;
}

uint8_t on_hold(const uint8_t* body, size_t len) {
    if (len < 4) return kBadRequest;
    InHold h{};
    std::memcpy(&h.ms, body, 2);
    const uint8_t nl = body[2];
    if (nl == 0 || nl > 63 || static_cast<size_t>(3 + nl) != len) return kBadRequest;
    std::memcpy(h.name, body + 3, nl); h.name[nl] = 0;
    std::lock_guard<std::mutex> lock(g_inboxMutex);
    if (g_inHolds.size() < 1024) g_inHolds.push_back(h);
    return kOk;
}

uint8_t on_config(const uint8_t* body, size_t len) {
    if (len != 2) return kBadRequest;
    const bool on = body[0] != 0, sc = body[1] != 0;
    const bool wasOn = g_nativeOn.exchange(on), wasSc = g_senderClock.exchange(sc);
    if (on != wasOn || sc != wasSc)
        logf("MP-NPCWRITE config native_write=%s senderclock=%s (was %s/%s)", on ? "on" : "off", sc ? "on" : "off",
             wasOn ? "on" : "off", wasSc ? "on" : "off");
    return kOk;
}

void on_pipe_closed() { g_dropAll = true; }

bool parse_bind(const uint8_t* body, size_t len, BindRequest* out) {
    // [on:1][eid:4][wuid:8][ax:4f][ay:4f][az:4f][delayMs:2][nameLen:1][name]
    if (len < 1 + 4 + 8 + 12 + 2 + 1 + 1) return false;
    BindRequest r{};
    r.on = body[0] != 0;
    std::memcpy(&r.eid, body + 1, 4);
    std::memcpy(&r.wuid, body + 5, 8);
    std::memcpy(r.anchor, body + 13, 12);
    std::memcpy(&r.delayMs, body + 25, 2);
    const uint8_t nl = body[27];
    if (nl == 0 || nl > 63 || static_cast<size_t>(28 + nl) != len) return false;
    std::memcpy(r.name, body + 28, nl); r.name[nl] = 0;
    if (!std::isfinite(r.anchor[0]) || !std::isfinite(r.anchor[1]) || !std::isfinite(r.anchor[2])) return false;
    *out = r;
    return true;
}

// ---- main thread --------------------------------------------------------------
uint8_t bind_main(const BindRequest& req) {
    const std::string key = lower(req.name);
    if (!req.on) {
        auto it = g_bound.find(key);
        if (it != g_bound.end()) {
            pull_flush(it->second, now_s());
            drop(it, kUnbound, false);
        }
        g_statBound.store(static_cast<uint16_t>(g_bound.size()));
        return kOk;
    }
    auto refuse = [&](uint8_t why, const char* detail) {
        logf("MP-NPCBIND npc=%s result=refused reason=%s eid=0x%X lua_wuid=%016llX %s", req.name, reason_name(why), req.eid,
             static_cast<unsigned long long>(req.wuid), detail ? detail : "");
        return why;
    };
    if (!g_armed) return refuse(kDisarmed, "");
    if (!g_nativeOn) return refuse(kToggleOff, "");
    void* e = engine::entity_by_id(req.eid);
    if (!e || !is_a(e, g_vftEntity)) return refuse(kNoEntity, "");
    char nm[64]{};
    const char* n = engine::entity_name(e);
    if (!n || !copy_name(n, nm, sizeof(nm)) || _stricmp(nm, req.name) != 0) {
        char d[96]; std::snprintf(d, sizeof(d), "entity_name=%s", nm[0] ? nm : "?");
        return refuse(kNameMismatch, d);
    }
    const uint64_t nativeWuid = actions::entity_wuid(e);
    if (req.wuid != 0 && nativeWuid != 0 && req.wuid != nativeWuid) {
        char d[96]; std::snprintf(d, sizeof(d), "native_wuid=%016llX", static_cast<unsigned long long>(nativeWuid));
        return refuse(kWuidMismatch, d);
    }
    void* parent = nullptr;
    if (!get_parent(e, &parent)) return refuse(kFault, "GetParent faulted");
    if (parent) return refuse(kParented, "");
    void* phys = get_physics(e);
    if (!phys || !is_a(phys, g_vftLiving)) return refuse(kNotLiving, phys ? "physics is not a living entity" : "no physics");
    if (g_bound.find(key) == g_bound.end() && g_bound.size() >= kMaxBound) return refuse(kTableFull, "");

    const double now = now_s();
    Puppet& p = g_bound[key];
    const bool rebind = p.eid != 0;
    p = Puppet{};
    p.key = key; p.name = req.name; p.eid = req.eid; p.ent = e; p.wuid = nativeWuid ? nativeWuid : req.wuid;
    std::memcpy(p.anchor, req.anchor, sizeof(p.anchor));
    p.delay = (req.delayMs >= 20 && req.delayMs <= 2000) ? req.delayMs / 1000.0 : 0.12;
    p.winStart = now;
    float cur[3]{};
    if (read_pos(e, cur)) {
        Stream& s = g_streams[key];
        if (s.name.empty()) s.name = req.name;
        s.haveSeq = false;   // a bind is a fresh puppet on the Lua side too (its seq accounting starts over)
        seed(s, cur, yaw_of(e), now - p.delay);
        s.lastSampleAt = s.lastSampleAt > 0 ? s.lastSampleAt : now;
    }
    g_statBound.store(static_cast<uint16_t>(g_bound.size()));
    logf("MP-NPCBIND npc=%s result=ok%s eid=0x%X wuid=%016llX lua_wuid=%016llX anchor=(%.2f,%.2f,%.2f) delay_ms=%u bound=%zu",
         req.name, rebind ? " rebind=1" : "", req.eid, static_cast<unsigned long long>(nativeWuid),
         static_cast<unsigned long long>(req.wuid), req.anchor[0], req.anchor[1], req.anchor[2], req.delayMs, g_bound.size());
    return kOk;
}

Status status() {
    Status s{};
    s.armed = g_armed ? 1 : 0;
    s.nativeOn = g_nativeOn ? 1 : 0;
    s.bound = g_statBound.load();
    s.writing = g_statWriting.load();
    s.framesWritten = g_statFrames.load();
    s.writes = g_statWrites.load();
    s.drops = g_statDrops.load();
    s.samples = g_statSamples.load();
    return s;
}

void tick() {
    const double now = now_s();
    // Trace: the traced entity's position before any write of ours.
    npctrace::frame_begin(now);

    if (!g_armed.load(std::memory_order_relaxed)) { npctrace::frame_end(); return; }

    std::vector<InSample> samples;
    std::vector<InHold> holds;
    {
        std::lock_guard<std::mutex> lock(g_inboxMutex);
        samples.swap(g_inSamples);
        holds.swap(g_inHolds);
    }
    for (const auto& s : samples) push_sample(s, now);
    for (const auto& h : holds) {
        auto it = g_bound.find(lower(h.name));
        if (it != g_bound.end()) {
            it->second.holdUntil = now + h.ms / 1000.0;
            it->second.haveLast = false;
            it->second.havePrev = false;
        }
    }
    if (g_dropAll.exchange(false)) {
        for (auto it = g_bound.begin(); it != g_bound.end();) {
            logf("MP-NPCWRITE npc=%s event=drop reason=pipe-closed writes=%llu", it->second.name.c_str(),
                 static_cast<unsigned long long>(it->second.writes));
            it = g_bound.erase(it);
        }
    }
    if (!g_nativeOn.load(std::memory_order_relaxed) && !g_bound.empty()) {
        for (auto it = g_bound.begin(); it != g_bound.end();) {
            auto cur = it++;
            drop(cur, kToggleOff, true);
        }
    }

    uint16_t writing = 0;
    for (auto it = g_bound.begin(); it != g_bound.end();) {
        Puppet& p = it->second;
        auto sIt = g_streams.find(p.key);
        if (sIt == g_streams.end() || now - sIt->second.lastSampleAt > kSilenceS) {
            auto cur = it++;
            pull_flush(cur->second, now);
            drop(cur, kSilence, true);
            continue;
        }
        void* e = engine::entity_by_id(p.eid);
        if (e != p.ent || !is_a(e, g_vftEntity)) {
            auto cur = it++;
            drop(cur, kEntityGone, true);
            continue;
        }
        const Stream& s = sIt->second;
        // A body that became parented after the bind (a rider mounting, a body
        // picked up) has LOCAL coordinates: never written until it is free.
        void* parent = nullptr;
        const bool parented = get_parent(e, &parent) && parent != nullptr;
        if ((s.flags & (0x01 | 0x02 | 0x10)) != 0 || now < p.holdUntil || parented) {
            // Dead / unconscious / carried stay on Lua's own behaviour; a swing
            // one-shot owns the body for its hold. Neither is a pull.
            p.haveLast = false;
            p.havePrev = false;
            ++it;
            continue;
        }
        float pose[4];
        if (!render(s, now - p.delay, p.delay, pose)) { ++it; continue; }
        bool wrote = false;
        if (!write_one(p, e, pose, &wrote)) {
            if (!g_announcedFault) { g_announcedFault = true; logf("MP-NPCWRITE npc=%s engine call FAULTED", p.name.c_str()); }
            disarm("an engine call faulted inside the per-frame write");
            npctrace::frame_end();
            return;
        }
        if (wrote) { ++writing; g_statWrites.fetch_add(1, std::memory_order_relaxed); npctrace::note_write(e, pose); }
        if (now - p.winStart >= kPullWindowS) pull_flush(p, now);
        ++it;
    }
    g_statWriting.store(writing);
    g_statBound.store(static_cast<uint16_t>(g_bound.size()));
    if (writing) g_statFrames.fetch_add(1, std::memory_order_relaxed);

    if (now - g_lastPrune > 5.0) {
        g_lastPrune = now;
        for (auto it = g_streams.begin(); it != g_streams.end();) {
            if (g_bound.find(it->first) == g_bound.end() && now - it->second.lastSampleAt > kStreamForgetS) it = g_streams.erase(it);
            else ++it;
        }
    }
    npctrace::frame_end();
}

} // namespace kcdmp::npcdrive
