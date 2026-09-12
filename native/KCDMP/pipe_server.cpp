#include "pipe_server.h"
#include "main_thread.h"
#include "rttr_abi.h"
#include "combat_swing.h"
#include "lua_closure.h"
#include "script_context.h"
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

void send_result(HANDLE h, bool ok, uint8_t seq) {
    BYTE body[2] = { static_cast<BYTE>(ok ? 1 : 0), seq };
    EnterCriticalSection(&g_write_lock);
    send_frame(h, kResult, body, 2);
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
    T value{};
};

constexpr unsigned kPipeSyncTimeoutMs = 5000;

// `work` must capture everything it needs BY VALUE: it can end up running
// well after this function has returned to its caller. Returns run_sync's
// own result (false = the frame never picked the task up) through outValue
// and the return value; a false return with no "timed out" log from the
// caller's usual pattern means THIS wait gave up, not run_sync's -- see the
// distinct log line below.
template <typename T>
bool run_sync_bounded(const std::function<void(T&)>& work, const char* what, T& outValue) {
    auto state = std::make_shared<PipeSyncState<T>>();
    std::thread([state, work] {
        const bool ran = main_thread::run_sync([&] { work(state->value); });
        std::lock_guard<std::mutex> lock(state->mutex);
        state->ran = ran;
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
    outValue = state->value;
    return state->ran;
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
                const bool ran = run_sync_bounded<bool>(
                    [guid, stamina, health, suppress](bool& result) {
                        result = rttr::apply_damage(guid.data(), stamina, health, suppress);
                        if (result) rttr::note_remote_damage(guid.data(), health);
                    }, "ApplyDamage", ok);
                if (!ran) logf("PIPE: ApplyDamage timed out waiting for a frame");
                logf("PIPE: ApplyDamage stamina=%.2f health=%.2f -> %s",
                     stamina, health, ok ? "applied" : "soul not loaded / failed");
                send_result(h, ran && ok, seq);
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
                const bool ran = run_sync_bounded<bool>(
                    [guid](bool& result) { result = rttr::apply_death(guid.data()); },
                    "ApplyDeath", ok);
                if (!ran) logf("PIPE: ApplyDeath timed out waiting for a frame");
                logf("PIPE: ApplyDeath -> %s", ok ? "dead" : "soul not loaded / failed");
                send_result(h, ran && ok, seq);
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
                const bool ran = run_sync_bounded<bool>(
                    [guid, hostile](bool& result) { result = rttr::set_ghost_faction_hostile(guid.data(), hostile); },
                    "SetFactionHostile", ok);
                if (!ran) logf("PIPE: SetFactionHostile timed out waiting for a frame");
                logf("PIPE: SetFactionHostile hostile=%s -> %s",
                     hostile ? "true" : "false", ok ? "applied" : "ghost not loaded / failed");
                send_result(h, ran && ok, seq);
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

                bool ok = false;
                const bool ran = run_sync_bounded<bool>(
                    [entityId, spec](bool& result) { result = rttr::ghost_swing(entityId, spec.c_str()); },
                    "GhostSwing", ok);
                if (!ran) logf("PIPE: GhostSwing timed out waiting for a frame");
                send_result(h, ran && ok, seq);
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
                const bool ran = run_sync_bounded<bool>(
                    [guid, on](bool& result) { result = sctx::apply_isolation(guid.data(), on); },
                    "GhostIsolate", ok);
                if (!ran) logf("PIPE: GhostIsolate timed out waiting for a frame");
                logf("PIPE: GhostIsolate on=%s -> %s", on ? "true" : "false",
                     ok ? "all contexts in state" : "not fully applied (see SCTX lines)");
                send_result(h, ran && ok, seq);
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
                logf("PIPE: unknown frame type 0x%02X (%u bytes)", type, len);
                break;
        }
    }

    g_connected = false;
    logf("PIPE: agent disconnected");
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
