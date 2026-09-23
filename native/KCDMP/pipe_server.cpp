#include "pipe_server.h"
#include "mannequin_read.h"
#include "local_state.h"
#include "npc_scan.h"
#include "main_thread.h"
#include "rttr_abi.h"
#include "combat_swing.h"
#include "lua_closure.h"
#include "script_context.h"
#include "concept_read.h"
#include "respawn.h"
#include "respawn_actions.h"
#include "log.h"

#include <windows.h>
#include <array>
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace kcdmp::pipe {

namespace {

constexpr const char* kPipeName = R"(\\.\pipe\kcdmp)";

std::atomic<bool>   g_running{false};
std::atomic<bool>   g_connected{false};
HANDLE              g_pipe = INVALID_HANDLE_VALUE;
uint8_t             g_seq = 0;

// The pipe is duplex and both directions are in use at once: the serve loop
// parks in a read while the game thread pushes hits out. On a *synchronous*
// handle the I/O manager serialises every request against the file object, so
// that write would queue behind the parked read and never issue -- the read is
// waiting on the agent, which is waiting on the write. That deadlock is what
// silently swallowed every outbound LocalHit. Hence FILE_FLAG_OVERLAPPED on the
// handle and an explicit OVERLAPPED per operation here; a lock is still needed,
// but only to keep two writers from interleaving their frames.
struct Op {
    OVERLAPPED ov{};
    Op()  { ov.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr); }
    ~Op() { if (ov.hEvent) CloseHandle(ov.hEvent); }
    Op(const Op&) = delete;
    Op& operator=(const Op&) = delete;
};

bool write_all(HANDLE h, const void* data, DWORD len) {
    const auto* p = static_cast<const BYTE*>(data);
    Op op;
    if (!op.ov.hEvent) return false;
    DWORD done = 0;
    while (done < len) {
        DWORD n = 0;
        ResetEvent(op.ov.hEvent);
        if (!WriteFile(h, p + done, len - done, &n, &op.ov)) {
            if (GetLastError() != ERROR_IO_PENDING) return false;
            if (!GetOverlappedResult(h, &op.ov, &n, TRUE)) return false;
        }
        if (n == 0) return false;
        done += n;
    }
    return true;
}

bool read_all(HANDLE h, void* data, DWORD len) {
    auto* p = static_cast<BYTE*>(data);
    Op op;
    if (!op.ov.hEvent) return false;
    DWORD done = 0;
    while (done < len) {
        DWORD n = 0;
        ResetEvent(op.ov.hEvent);
        if (!ReadFile(h, p + done, len - done, &n, &op.ov)) {
            if (GetLastError() != ERROR_IO_PENDING) return false;
            if (!GetOverlappedResult(h, &op.ov, &n, TRUE)) return false;
        }
        if (n == 0) return false;
        done += n;
    }
    return true;
}

// Head and body go out as one write so a frame cannot be split across two I/O
// operations. Byte-mode pipes do not require it, but it removes the question.
bool send_frame(HANDLE h, uint8_t type, const void* payload, uint16_t len) {
    BYTE frame[3 + 1024];
    if (len > sizeof(frame) - 3) return false;
    frame[0] = type;
    frame[1] = static_cast<BYTE>(len & 0xFF);
    frame[2] = static_cast<BYTE>((len >> 8) & 0xFF);
    if (len) std::memcpy(frame + 3, payload, len);
    return write_all(h, frame, 3u + len);
}

// Two threads write to this pipe -- the serve loop's replies and the game
// thread's hits -- so the lock keeps their frames from interleaving. It does
// nothing about read/write concurrency; see the note on Op above for that.
CRITICAL_SECTION g_write_lock;
bool             g_write_lock_ready = false;

void send_local_hit(const unsigned char guid[16], float health_delta, bool died) {
    // Log the detection before the connectivity check, so a missing agent looks
    // different from a missed hit.
    logf("PIPE: LocalHit %.2f%s guid=%02X%02X%02X%02X-...%s",
         health_delta, died ? " (fatal)" : "",
         guid[3], guid[2], guid[1], guid[0],
         g_connected ? "" : "  [no agent attached, not sent]");
    if (!g_connected || g_pipe == INVALID_HANDLE_VALUE) return;
    // WO-86: the `died` bit the sampler has computed since WO-4 used to stop
    // right here -- the frame carried guid+stamina+health and nothing else, so
    // the agent could never tell a killing blow from a chip and no client ever
    // put an NPC death on the wire. Appended as a trailing byte: an agent that
    // predates it reads the first 24 bytes exactly as before.
    unsigned char body[16 + 4 + 4 + 1];
    std::memcpy(body, guid, 16);
    const float stamina = 0.0f;
    std::memcpy(body + 16, &stamina, 4);
    std::memcpy(body + 20, &health_delta, 4);
    body[24] = died ? 1 : 0;
    EnterCriticalSection(&g_write_lock);
    const bool sent = send_frame(g_pipe, kLocalHit, body, sizeof(body));
    const DWORD err = sent ? 0 : GetLastError();
    LeaveCriticalSection(&g_write_lock);
    // A failed write used to be indistinguishable from a delivered one, which is
    // how a deadlocked send looked like a working one for so long.
    if (!sent) logf("PIPE: LocalHit write failed: %lu", err);
}

// WO-113: unsolicited respawn frames, written from the game thread under the
// same write lock as LocalHit. A missing agent is logged by respawn.cpp's own
// lines; here only a failed write is.
void send_unsolicited(uint8_t type, const void* body, uint16_t len, const char* what) {
    if (!g_connected || g_pipe == INVALID_HANDLE_VALUE) return;
    EnterCriticalSection(&g_write_lock);
    const bool sent = send_frame(g_pipe, type, body, len);
    const DWORD err = sent ? 0 : GetLastError();
    LeaveCriticalSection(&g_write_lock);
    if (!sent) logf("PIPE: %s write failed: %lu", what, err);
}

void send_local_downed(bool on, respawn::Kind kind) {
    const BYTE body[2] = { static_cast<BYTE>(on ? 1 : 0), static_cast<BYTE>(kind) };
    logf("PIPE: LocalDowned on=%d kind=%u%s", on ? 1 : 0, static_cast<unsigned>(kind),
         g_connected ? "" : "  [no agent attached, not sent]");
    send_unsolicited(kLocalDowned, body, sizeof(body), "LocalDowned");
}

void send_local_respawned(float x, float y, float z, respawn::Kind reason) {
    BYTE body[13]{};
    std::memcpy(body + 0, &x, 4);
    std::memcpy(body + 4, &y, 4);
    std::memcpy(body + 8, &z, 4);
    body[12] = static_cast<BYTE>(reason);
    logf("PIPE: LocalRespawned (%.1f, %.1f, %.1f) reason=%u%s", x, y, z, static_cast<unsigned>(reason),
         g_connected ? "" : "  [no agent attached, not sent]");
    send_unsolicited(kLocalRespawned, body, sizeof(body), "LocalRespawned");
}

void send_local_grave(bool add, uint64_t id, float x, float y, float z) {
    BYTE body[21]{};
    body[0] = add ? 1 : 0;
    std::memcpy(body + 1, &id, 8);
    std::memcpy(body + 9, &x, 4);
    std::memcpy(body + 13, &y, 4);
    std::memcpy(body + 17, &z, 4);
    logf("PIPE: LocalGrave %s id=0x%016llX%s", add ? "add" : "remove", static_cast<unsigned long long>(id),
         g_connected ? "" : "  [no agent attached, not sent]");
    send_unsolicited(kLocalGrave, body, sizeof(body), "LocalGrave");
}

void on_grave_add(uint64_t id, float x, float y, float z) { send_local_grave(true, id, x, y, z); }
void on_grave_remove(uint64_t id) { send_local_grave(false, id, 0, 0, 0); }

void send_grave_list(HANDLE h, bool ok, uint8_t seq, const actions::GraveInfo* g, int n) {
    BYTE body[3 + kMaxGraveList * 20]{};
    body[0] = ok ? 1 : 0;
    body[1] = seq;
    if (n < 0) n = 0;
    if (n > kMaxGraveList) n = kMaxGraveList;
    body[2] = static_cast<BYTE>(n);
    for (int i = 0; i < n; ++i) {
        BYTE* p = body + 3 + i * 20;
        std::memcpy(p + 0, &g[i].id, 8);
        std::memcpy(p + 8, &g[i].x, 4);
        std::memcpy(p + 12, &g[i].y, 4);
        std::memcpy(p + 16, &g[i].z, 4);
    }
    EnterCriticalSection(&g_write_lock);
    send_frame(h, kGraveList, body, static_cast<uint16_t>(3 + n * 20));
    LeaveCriticalSection(&g_write_lock);
}

// WO-20 Phase 2 diagnostic reply. Not on the write-lock'd send path used by
// the async LocalHit thread -- this only ever runs from inside serve()'s own
// synchronous request/reply loop, same as send_result below.
void send_closure_info(HANDLE h, const kcdmp::luaintrospect::ClosureInfo& info) {
    BYTE body[1024];
    size_t o = 0;
    body[o++] = info.ok ? 1 : 0;
    std::memcpy(body + o, &info.nativeAddr, 8); o += 8;
    std::memcpy(body + o, &info.rva, 4); o += 4;

    auto put_str = [&](const std::string& s) {
        const uint8_t n = static_cast<uint8_t>(s.size() > 255 ? 255 : s.size());
        body[o++] = n;
        std::memcpy(body + o, s.data(), n); o += n;
    };
    put_str(info.moduleName);
    put_str(info.name);
    put_str(info.prologueHex);

    EnterCriticalSection(&g_write_lock);
    send_frame(h, kClosureInfo, body, static_cast<uint16_t>(o));
    LeaveCriticalSection(&g_write_lock);
}

// WO-100 Phase 4 item 3: the Result frame grows a third byte, a specific
// reason code (0 on success). Additive -- a pre-WO-100 agent reads body[0]
// and body[1] and never looks at body[2].
// WO-100.5 Phase 2. seq goes at body[1], exactly where the Result frame
// carries it, so the agent's sequence matching needs no special case.
void send_body_state(HANDLE h, bool ok, uint8_t seq,
                     const kcdmp::mannequin::BodyState& b) {
    // WO-100.5 Phase 3 appends the accepted-input block. Additive: an agent
    // that only knows the 8-byte form reads the first eight bytes and stops.
    BYTE body[13] = {
        static_cast<BYTE>(ok ? 1 : 0), seq,
        b.pace, b.dir, b.stance,
        static_cast<BYTE>(b.animSpeedCenti & 0xFF),
        static_cast<BYTE>((b.animSpeedCenti >> 8) & 0xFF),
        b.unknownTags,
        static_cast<BYTE>(b.haveCombat ? 1 : 0),
        static_cast<BYTE>(b.reqInputClass),
        static_cast<BYTE>(b.reqAtkZone),
        static_cast<BYTE>(b.atkType),
        b.reqPrepared,
    };
    EnterCriticalSection(&g_write_lock);
    send_frame(h, kBodyState, body, sizeof(body));
    LeaveCriticalSection(&g_write_lock);
}

// WO-102 Phase 1. Fixed 40 bytes whatever the verdict; seq at body[1] as
// every reply frame carries it. The body block reuses 0x85's byte order.
void send_local_state(HANDLE h, bool ok, uint8_t seq, const kcdmp::localstate::LocalState& s) {
    BYTE body[kLocalStateLen]{};
    body[0] = ok ? 1 : 0;
    body[1] = seq;
    body[2] = s.refuse;
    std::memcpy(body + 3, &s.frame, 8);
    std::memcpy(body + 11, &s.x, 4);
    std::memcpy(body + 15, &s.y, 4);
    std::memcpy(body + 19, &s.z, 4);
    std::memcpy(body + 23, &s.rotZ, 4);
    body[27] = s.flags;
    body[28] = s.haveBody ? 1 : 0;
    const kcdmp::mannequin::BodyState& b = s.body;
    body[29] = b.pace; body[30] = b.dir; body[31] = b.stance;
    body[32] = static_cast<BYTE>(b.animSpeedCenti & 0xFF);
    body[33] = static_cast<BYTE>((b.animSpeedCenti >> 8) & 0xFF);
    body[34] = b.unknownTags;
    body[35] = b.haveCombat ? 1 : 0;
    body[36] = static_cast<BYTE>(b.reqInputClass);
    body[37] = static_cast<BYTE>(b.reqAtkZone);
    body[38] = static_cast<BYTE>(b.atkType);
    body[39] = b.reqPrepared;
    EnterCriticalSection(&g_write_lock);
    send_frame(h, kLocalState, body, sizeof(body));
    LeaveCriticalSection(&g_write_lock);
}

// WO-102.5 Phase 2. Variable length, so this does NOT go through
// send_frame's fixed 1024-byte stack buffer -- a scan reply can run past
// that (npc_scan.h's kMaxReplyBytes budget is 8000). Built directly and
// written under the same write lock every other send_* uses.
void send_npc_scan_result(HANDLE h, bool ok, uint8_t seq, const kcdmp::npcscan::ScanResult& r) {
    std::vector<BYTE> frame;
    frame.reserve(3 + 18 + (ok ? r.entries.size() * 80 : 0));
    frame.resize(3);   // header filled in below once the payload length is known
    auto put = [&](const void* p, size_t n) {
        const BYTE* b = static_cast<const BYTE*>(p);
        frame.insert(frame.end(), b, b + n);
    };
    BYTE okB = ok ? 1 : 0, truncB = r.truncated ? 1 : 0;
    put(&okB, 1); put(&seq, 1); put(&r.refuse, 1); put(&truncB, 1);
    put(&r.totalWalked, 4); put(&r.nameRejects, 4);
    put(&r.droppedCount, 4);   // WO-103 Phase 1: how many more matched past the truncation point
    const uint16_t count = static_cast<uint16_t>(r.entries.size());
    put(&count, 2);
    for (const auto& e : r.entries) {
        const BYTE nameLen = static_cast<BYTE>(std::strlen(e.name));
        put(&nameLen, 1);
        put(e.name, nameLen);
        put(&e.x, 4); put(&e.y, 4); put(&e.z, 4); put(&e.yaw, 4);
        put(&e.isHorse, 1);
    }
    const size_t payloadLen = frame.size() - 3;
    frame[0] = kNpcScanResult;
    frame[1] = static_cast<BYTE>(payloadLen & 0xFF);
    frame[2] = static_cast<BYTE>((payloadLen >> 8) & 0xFF);
    EnterCriticalSection(&g_write_lock);
    write_all(h, frame.data(), static_cast<DWORD>(frame.size()));
    LeaveCriticalSection(&g_write_lock);
}

void send_result(HANDLE h, bool ok, uint8_t seq, uint8_t reason = 0) {
    BYTE body[3] = { static_cast<BYTE>(ok ? 1 : 0), seq, reason };
    EnterCriticalSection(&g_write_lock);
    send_frame(h, kResult, body, 3);
    LeaveCriticalSection(&g_write_lock);
}

// WO-76 (docs/WO-75-audit-findings.md s1/s2; PR #1 merge message): run_sync
// deliberately waits UNBOUNDED once a queued task has started -- returning
// early there would invalidate references the caller's own lambda captured,
// the exact use-after-free PR #1 already fixed for run_sync's internal
// state. That is the right call for run_sync itself, but it means one hung
// frame (the game's main thread wedged) freezes this pipe's entire serve()
// loop forever: no timeout, no log line, the next request never read.
//
// Fixed here instead, one level up, with the identical shape PR #1 used --
// state with process lifetime behind a shared_ptr, so giving up on it can
// never dangle anything. The actual run_sync call moves to a detached helper
// thread; serve() waits on ITS OWN bounded timeout against the shared state.
// If that elapses, serve() logs it, replies failure, and goes back to
// reading the pipe; the helper thread and run_sync's own wait are left to
// finish whenever (or if) the game recovers -- harmlessly, since nothing on
// the pipe thread still references them by then.
template <typename T>
struct PipeSyncState {
    std::mutex mutex;
    std::condition_variable cv;
    bool done = false;
    bool ran = false;
    bool faulted = false;   // WO-110 R12: the task ran and faulted; `value` is default-constructed garbage
    T value{};
};

// WO-110 R12: SHORTER than the agent's 5 s reply deadline (CombatPipe.cs
// ReplyDeadline). Both were 5 s, so when the game thread stalled the agent
// timed out first and the DLL's late failure reply then sat in the pipe as
// the answer to the NEXT command. Now the DLL gives up first and the agent
// receives an explicit Timeout/failure inside its own window.
constexpr unsigned kPipeSyncTimeoutMs = 3500;
constexpr uint8_t  kReasonTaskFaulted    = 17;   // mirrors PipeReason.TaskFaulted
constexpr uint8_t  kReasonUnknownCommand = 18;   // mirrors PipeReason.UnknownCommand

// `work` must capture everything it needs BY VALUE: it can end up running
// well after this function has returned to its caller. Returns run_sync's
// own result (false = the frame never picked the task up) through outValue
// and the return value; a false return with no "timed out" log from the
// caller's usual pattern means THIS wait gave up, not run_sync's -- see the
// distinct log line below.
// `faultedOut` (WO-110 R12): set when the task ran but raised; the caller must
// then reply failure with kReasonTaskFaulted instead of `outValue`'s defaults
// -- an empty ScanResult with refuse=kOk would make the agent untrack every
// NPC, a default BodyState would report a body at rest.
template <typename T>
bool run_sync_bounded(const std::function<void(T&)>& work, const char* what, T& outValue, bool* faultedOut = nullptr) {
    auto state = std::make_shared<PipeSyncState<T>>();
    std::thread([state, work] {
        bool faulted = false;
        const bool ran = main_thread::run_sync([&] { work(state->value); }, 5000, &faulted);
        std::lock_guard<std::mutex> lock(state->mutex);
        state->ran = ran;
        state->faulted = faulted;
        state->done = true;
        state->cv.notify_all();
    }).detach();

    std::unique_lock<std::mutex> lock(state->mutex);
    if (!state->cv.wait_for(lock, std::chrono::milliseconds(kPipeSyncTimeoutMs),
                             [&] { return state->done; })) {
        logf("PIPE: %s is still waiting on the main thread past %ums -- the frame loop "
             "may be hung. Replying failure now; the call will still land if a frame resumes.",
             what, kPipeSyncTimeoutMs);
        return false;
    }
    if (faultedOut) *faultedOut = state->faulted;
    if (state->faulted) logf("PIPE: %s FAULTED on the main thread -- replying failure, result discarded", what);
    outValue = state->value;
    return state->ran && !state->faulted;
}

// One connected agent, until it disconnects.
void serve(HANDLE h) {
    g_connected = true;
    logf("PIPE: agent connected");

    while (g_running) {
        BYTE head[3];
        if (!read_all(h, head, 3)) break;
        const uint8_t  type = head[0];
        const uint16_t len  = static_cast<uint16_t>(head[1] | (head[2] << 8));

        // Bound the payload before allocating: the pipe is local, but a
        // malformed length should not turn into a huge allocation.
        if (len > 1024) {
            logf("PIPE: payload of %u bytes is out of range; dropping the connection", len);
            break;
        }
        BYTE body[1024];
        if (len && !read_all(h, body, len)) break;

        const uint8_t seq = g_seq++;

        switch (type) {
            case kPing:
                send_frame(h, kPong, nullptr, 0);
                break;

            case kApplyDamage: {
                if (len != kApplyDamageLen) {
                    logf("PIPE: ApplyDamage wrong length %u", len);
                    send_result(h, false, seq);
                    break;
                }
                std::array<unsigned char, 16> guid;
                std::memcpy(guid.data(), body, 16);
                float stamina, health;
                std::memcpy(&stamina, body + 16, 4);
                std::memcpy(&health,  body + 20, 4);
                const bool suppress = (body[24] & kFlagSuppressHitReaction) != 0;

                // Onto the game's thread, and wait so the agent gets a truthful
                // result rather than an optimistic one.
                bool ok = false;
                bool faultedFlag = false;
                const bool ran = run_sync_bounded<bool>(
                    [guid, stamina, health, suppress](bool& result) {
                        result = rttr::apply_damage(guid.data(), stamina, health, suppress);
                        if (result) rttr::note_remote_damage(guid.data(), health);
                    }, "ApplyDamage", ok, &faultedFlag);
                if (!ran) logf("PIPE: ApplyDamage timed out waiting for a frame");
                logf("PIPE: ApplyDamage stamina=%.2f health=%.2f -> %s",
                     stamina, health, ok ? "applied" : "soul not loaded / failed");
                send_result(h, ran && ok, seq, (ran && ok) ? 0 : (faultedFlag ? kReasonTaskFaulted : 0));
                break;
            }

            case kApplyDeath: {
                if (len != kApplyDeathLen) {
                    logf("PIPE: ApplyDeath wrong length %u", len);
                    send_result(h, false, seq);
                    break;
                }
                std::array<unsigned char, 16> guid;
                std::memcpy(guid.data(), body, 16);
                bool ok = false;
                bool faultedFlag = false;
                const bool ran = run_sync_bounded<bool>(
                    [guid](bool& result) { result = rttr::apply_death(guid.data()); },
                    "ApplyDeath", ok, &faultedFlag);
                if (!ran) logf("PIPE: ApplyDeath timed out waiting for a frame");
                logf("PIPE: ApplyDeath -> %s", ok ? "dead" : "soul not loaded / failed");
                send_result(h, ran && ok, seq, (ran && ok) ? 0 : (faultedFlag ? kReasonTaskFaulted : 0));
                break;
            }

            case kSetFactionHostile: {
                if (len != kSetFactionHostileLen) {
                    logf("PIPE: SetFactionHostile wrong length %u", len);
                    send_result(h, false, seq);
                    break;
                }
                std::array<unsigned char, 16> guid;
                std::memcpy(guid.data(), body, 16);
                const bool hostile = body[16] != 0;
                bool ok = false;
                bool faultedFlag = false;
                const bool ran = run_sync_bounded<bool>(
                    [guid, hostile](bool& result) { result = rttr::set_ghost_faction_hostile(guid.data(), hostile); },
                    "SetFactionHostile", ok, &faultedFlag);
                if (!ran) logf("PIPE: SetFactionHostile timed out waiting for a frame");
                logf("PIPE: SetFactionHostile hostile=%s -> %s",
                     hostile ? "true" : "false", ok ? "applied" : "ghost not loaded / failed");
                send_result(h, ran && ok, seq, (ran && ok) ? 0 : (faultedFlag ? kReasonTaskFaulted : 0));
                break;
            }

            case kGhostSwing: {
                if (len < kGhostSwingMinLen || len > kGhostSwingMaxLen) {
                    logf("PIPE: GhostSwing wrong length %u", len);
                    send_result(h, false, seq);
                    break;
                }
                uint32_t entityId = 0;
                std::memcpy(&entityId, body, 4);
                const size_t specLen = len - 4;
                std::string spec(reinterpret_cast<const char*>(body + 4), specLen);

                rttr::SwingResult res = rttr::SwingResult::Ok;
                const bool ran = run_sync_bounded<rttr::SwingResult>(
                    [entityId, spec](rttr::SwingResult& result) { result = rttr::ghost_swing(entityId, spec.c_str()); },
                    "GhostSwing", res);
                // A task that never ran is NOT the same failure as one that
                // ran and was refused -- WO-100 Phase 4 item 3. Report it as
                // its own code rather than folding it into the last one.
                if (!ran) {
                    logf("PIPE: GhostSwing timed out waiting for a frame");
                    res = rttr::SwingResult::Timeout;
                }
                const bool ok = (res == rttr::SwingResult::Ok);
                if (!ok) logf("PIPE: GhostSwing entity=%u -> %s", entityId, rttr::swing_result_name(res));
                send_result(h, ok, seq, static_cast<uint8_t>(res));
                break;
            }

            case kGhostIsolate: {
                if (len != kGhostIsolateLen) {
                    logf("PIPE: GhostIsolate wrong length %u", len);
                    send_result(h, false, seq);
                    break;
                }
                std::array<unsigned char, 16> guid;
                std::memcpy(guid.data(), body, 16);
                const bool on = body[16] != 0;
                bool ok = false;
                bool faultedFlag = false;
                const bool ran = run_sync_bounded<bool>(
                    [guid, on](bool& result) { result = sctx::apply_isolation(guid.data(), on); },
                    "GhostIsolate", ok, &faultedFlag);
                if (!ran) logf("PIPE: GhostIsolate timed out waiting for a frame");
                logf("PIPE: GhostIsolate on=%s -> %s", on ? "true" : "false",
                     ok ? "all contexts in state" : "not fully applied (see SCTX lines)");
                send_result(h, ran && ok, seq, (ran && ok) ? 0 : (faultedFlag ? kReasonTaskFaulted : 0));
                break;
            }

            // WO-97: read-only probe of the quest concept tree. Runs on the
            // game's main thread like every other engine touch here, and
            // reports only through the native log -- the payload that matters
            // (root module names, node vs null) is many lines of text, not a
            // wire field. Result byte says whether the probe ran, not what it
            // found.
            // WO-100.5 Phase 2: the continuous body-state read. Read-only,
            // and deliberately silent -- the agent calls this at the position
            // stream's cadence, so a log line per sample would be a flood.
            // The ok byte carries every refusal; the agent counts them.
            case kReadBodyState: {
                kcdmp::mannequin::BodyState bs{};
                if (len != kReadBodyStateLen) {
                    logf("PIPE: ReadBodyState wrong length %u", len);
                    send_body_state(h, false, seq, bs);
                    break;
                }
                uint32_t entityId = 0;
                std::memcpy(&entityId, body, 4);
                const bool wantPlayer = (entityId == 0);
                // WO-110 R12: the lambda used to capture the stack `bs` by
                // reference; after a bounded-wait timeout it could run later and
                // write into a dead frame. The result now lives in the shared
                // state (process lifetime), captured by value only.
                struct BodyStateOut { bool ok = false; kcdmp::mannequin::BodyState bs{}; };
                BodyStateOut r{};
                bool faulted = false;
                const bool ran = run_sync_bounded<BodyStateOut>(
                    [wantPlayer, entityId](BodyStateOut& out) {
                        out.ok = kcdmp::mannequin::read_body_state(wantPlayer, entityId, &out.bs);
                    }, "ReadBodyState", r, &faulted);
                if (faulted) r.bs = kcdmp::mannequin::BodyState{};
                send_body_state(h, ran && r.ok, seq, r.bs);
                break;
            }

            // WO-102 Phase 1: position + yaw + riding + body state from one
            // frame. Read-only and quiet, like 0x09: the refuse byte carries
            // every gate, the native log gets one line per verdict change.
            case kReadLocalState: {
                kcdmp::localstate::LocalState ls{};
                if (len != kReadLocalStateLen) {
                    logf("PIPE: ReadLocalState wrong length %u", len);
                    ls.refuse = kcdmp::localstate::kModuleMissing;
                    send_local_state(h, false, seq, ls);
                    break;
                }
                uint32_t entityId = 0;
                std::memcpy(&entityId, body, 4);
                if (entityId != 0) {
                    logf("PIPE: ReadLocalState entityId=%u refused -- only the player (0) is supported", entityId);
                    ls.refuse = kcdmp::localstate::kNoPlayerActor;
                    send_local_state(h, false, seq, ls);
                    break;
                }
                // WO-110 R12: by-value capture; result in the shared state (see ReadBodyState).
                struct LocalStateOut { bool ok = false; kcdmp::localstate::LocalState ls{}; };
                LocalStateOut r{};
                bool faulted = false;
                const bool ran = run_sync_bounded<LocalStateOut>(
                    [](LocalStateOut& out) { out.ok = kcdmp::localstate::read_local_state(&out.ls); },
                    "ReadLocalState", r, &faulted);
                if (faulted) { r.ls = kcdmp::localstate::LocalState{}; r.ls.refuse = kcdmp::localstate::kReadFaulted; }
                send_local_state(h, ran && r.ok, seq, r.ls);
                break;
            }

            // WO-102.5 Phase 2: the batched native NPC scan (npc_scan.h).
            // Read-only and quiet like 0x0A: the reply's refuse/truncated
            // bytes carry every gate, one native log line per verdict change.
            case kScanNpcs: {
                kcdmp::npcscan::ScanResult sr{};
                if (len < kScanNpcsMinLen || len > kScanNpcsMaxLen) {
                    logf("PIPE: ScanNpcs wrong length %u", len);
                    sr.refuse = kcdmp::npcscan::kModuleMissing;
                    send_npc_scan_result(h, false, seq, sr);
                    break;
                }
                const uint8_t anchorCount = body[0];
                if (anchorCount < 1 || anchorCount > kScanNpcsAnchorMax ||
                    static_cast<int>(len) != 1 + 4 + anchorCount * 12) {
                    logf("PIPE: ScanNpcs anchorCount=%u inconsistent with len=%u", anchorCount, len);
                    sr.refuse = kcdmp::npcscan::kModuleMissing;
                    send_npc_scan_result(h, false, seq, sr);
                    break;
                }
                float radius = 0;
                std::memcpy(&radius, body + 1, 4);
                std::vector<kcdmp::npcscan::Anchor> anchors(anchorCount);
                for (int i = 0; i < anchorCount; ++i) {
                    std::memcpy(&anchors[i], body + 5 + i * 12, 12);
                }
                bool ok = false;
                bool faulted = false;
                const bool ran = run_sync_bounded<kcdmp::npcscan::ScanResult>(
                    [anchors, radius](kcdmp::npcscan::ScanResult& result) {
                        kcdmp::npcscan::scan(anchors.data(), static_cast<int>(anchors.size()), radius, &result);
                    }, "ScanNpcs", sr, &faulted);
                // WO-110 R12: a faulted or never-run scan must not reply an
                // empty result with refuse=kOk -- the agent would push an empty
                // set and the owner's rescan would untrack every NPC.
                if (faulted || !ran) {
                    sr = kcdmp::npcscan::ScanResult{};
                    sr.refuse = kcdmp::npcscan::kReadFaulted;
                }
                ok = ran && !faulted && sr.refuse == kcdmp::npcscan::kOk;
                if (!ran) logf("PIPE: ScanNpcs timed out waiting for a frame");
                send_npc_scan_result(h, ok, seq, sr);
                break;
            }

            // WO-113: session state and the respawn toggle. Atomic setters, so
            // no main-thread hop is needed; the tick picks them up.
            case kSetSession:
            case kSetRespawn: {
                if (len != 1) {
                    logf("PIPE: %s wrong length %u", type == kSetSession ? "SetSession" : "SetRespawn", len);
                    send_result(h, false, seq);
                    break;
                }
                const bool on = body[0] != 0;
                if (type == kSetSession) respawn::set_session(on, "agent");
                else respawn::set_enabled(on, "agent");
                send_result(h, true, seq);
                break;
            }

            case kMirrorGrave: {
                if (len != kMirrorGraveLen) {
                    logf("PIPE: MirrorGrave wrong length %u", len);
                    send_result(h, false, seq);
                    break;
                }
                const uint8_t op = body[0], owner = body[1];
                uint64_t id = 0;
                float x = 0, y = 0, z = 0;
                std::memcpy(&id, body + 2, 8);
                std::memcpy(&x, body + 10, 4);
                std::memcpy(&y, body + 14, 4);
                std::memcpy(&z, body + 18, 4);
                bool ok = false;
                bool faultedFlag = false;
                const bool ran = run_sync_bounded<bool>(
                    [op, owner, id, x, y, z](bool& result) {
                        if (op == 1) result = actions::mirror_add(owner, id, x, y, z);
                        else if (op == 0) result = actions::mirror_remove(owner, id);
                        else { actions::mirror_clear(owner); result = true; }
                    }, "MirrorGrave", ok, &faultedFlag);
                logf("PIPE: MirrorGrave op=%u owner=%u id=0x%016llX -> %s", op, owner,
                     static_cast<unsigned long long>(id), (ran && ok) ? "applied" : "refused");
                send_result(h, ran && ok, seq, (ran && ok) ? 0 : (faultedFlag ? kReasonTaskFaulted : 0));
                break;
            }

            case kListGraves: {
                struct ListOut { int n = 0; actions::GraveInfo g[kMaxGraveList]{}; };
                ListOut r{};
                bool faulted = false;
                const bool ran = run_sync_bounded<ListOut>(
                    [](ListOut& out) { out.n = actions::graves_list(out.g, kMaxGraveList); },
                    "ListGraves", r, &faulted);
                send_grave_list(h, ran && !faulted, seq, r.g, (ran && !faulted) ? r.n : 0);
                break;
            }

            case kConceptProbe: {
                if (len > kConceptProbeMaxLen) {
                    logf("PIPE: ConceptProbe path too long (%u > %d)", len, kConceptProbeMaxLen);
                    send_result(h, false, seq);
                    break;
                }
                std::string path(reinterpret_cast<const char*>(body), len);
                bool ok = false;
                bool faultedFlag = false;
                const bool ran = run_sync_bounded<bool>(
                    [path](bool& result) { result = conceptread::probe(path.c_str()); },
                    "ConceptProbe", ok, &faultedFlag);
                if (!ran) logf("PIPE: ConceptProbe timed out waiting for a frame");
                logf("PIPE: ConceptProbe(\"%s\") -> %s", path.c_str(),
                     ok ? "ran" : "failed (see CONCEPT lines)");
                send_result(h, ran && ok, seq, (ran && ok) ? 0 : (faultedFlag ? kReasonTaskFaulted : 0));
                break;
            }

            case kResolveLuaClosure: {
                if (len != kResolveLuaClosureLen) {
                    logf("PIPE: ResolveLuaClosure wrong length %u", len);
                    kcdmp::luaintrospect::ClosureInfo empty;
                    send_closure_info(h, empty);
                    break;
                }
                uint64_t closureAddr = 0;
                std::memcpy(&closureAddr, body, 8);
                kcdmp::luaintrospect::ClosureInfo info;
                const bool ran = run_sync_bounded<kcdmp::luaintrospect::ClosureInfo>(
                    [closureAddr](kcdmp::luaintrospect::ClosureInfo& result) {
                        result = kcdmp::luaintrospect::resolve(closureAddr);
                    }, "ResolveLuaClosure", info);
                if (!ran) logf("PIPE: ResolveLuaClosure timed out waiting for a frame");
                send_closure_info(h, ran ? info : kcdmp::luaintrospect::ClosureInfo{});
                break;
            }

            default:
                // WO-110 R12: answered, not ignored -- an agent newer than this
                // DLL used to wait out its whole deadline for nothing.
                logf("PIPE: unknown frame type 0x%02X (%u bytes) -- replying failure/unknown-command", type, len);
                send_result(h, false, seq, kReasonUnknownCommand);
                break;
        }
    }

    g_connected = false;
    logf("PIPE: agent disconnected");
    // WO-113: no agent, no session -- the death guard stands down (vanilla).
    respawn::set_session(false, "pipe closed");
}

void listen_loop() {
    while (g_running) {
        HANDLE h = CreateNamedPipeA(
            kPipeName,
            PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
            1,               // one agent per game
            64 * 1024, 64 * 1024,
            0, nullptr);
        if (h == INVALID_HANDLE_VALUE) {
            logf("PIPE: CreateNamedPipe failed: %lu", GetLastError());
            Sleep(1000);
            continue;
        }
        g_pipe = h;

        // Waits until an agent connects, or until stop() breaks it by connecting
        // to its own pipe. Overlapped now, so the wait is on the event rather
        // than inside the call.
        Op conn;
        BOOL ok = FALSE;
        if (conn.ov.hEvent) {
            if (ConnectNamedPipe(h, &conn.ov)) {
                ok = TRUE;
            } else {
                const DWORD err = GetLastError();
                if (err == ERROR_PIPE_CONNECTED) {
                    ok = TRUE;
                } else if (err == ERROR_IO_PENDING) {
                    DWORD ignored = 0;
                    ok = GetOverlappedResult(h, &conn.ov, &ignored, TRUE);
                } else {
                    logf("PIPE: ConnectNamedPipe failed: %lu", err);
                }
            }
        }
        if (ok && g_running) {
            serve(h);
        }

        DisconnectNamedPipe(h);
        CloseHandle(h);
        g_pipe = INVALID_HANDLE_VALUE;
    }
    logf("PIPE: listener stopped");
}

} // namespace

bool start() {
    if (!g_write_lock_ready) { InitializeCriticalSection(&g_write_lock); g_write_lock_ready = true; }
    if (g_running.exchange(true)) return true;

    // Outbound detection runs on the game thread every frame; the sampler
    // rate-limits itself. Posting a self-requeueing task keeps it going without
    // a second timer.
    main_thread::post_repeating([] {
        rttr::sample_health(&send_local_hit);
    });

    // WO-113: the respawn module's outbound events become pipe frames.
    respawn::Events ev{};
    ev.downed = &send_local_downed;
    ev.respawned = &send_local_respawned;
    ev.grave_add = &on_grave_add;
    ev.grave_remove = &on_grave_remove;
    respawn::set_events(ev);

    // The injected plugin has process lifetime. Detaching keeps DLL teardown
    // free of a blocking join under the Windows loader lock.
    std::thread(listen_loop).detach();
    logf("PIPE: listening on %s", kPipeName);
    return true;
}

void stop() {
    if (!g_running.exchange(false)) return;
    // Unblock ConnectNamedPipe by connecting to it once.
    HANDLE poke = CreateFileA(kPipeName, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                              OPEN_EXISTING, 0, nullptr);
    if (poke != INVALID_HANDLE_VALUE) CloseHandle(poke);
}

bool connected() { return g_connected; }

} // namespace kcdmp::pipe
