#include "pipe_server.h"
#include "main_thread.h"
#include "rttr_abi.h"
#include "log.h"

#include <windows.h>
#include <atomic>
#include <cstring>
#include <thread>

namespace kcdmp::pipe {

namespace {

constexpr const char* kPipeName = R"(\\.\pipe\kcdmp)";

std::atomic<bool>   g_running{false};
std::atomic<bool>   g_connected{false};
HANDLE              g_pipe = INVALID_HANDLE_VALUE;
std::thread         g_thread;
uint8_t             g_seq = 0;

bool write_all(HANDLE h, const void* data, DWORD len) {
    const auto* p = static_cast<const BYTE*>(data);
    DWORD done = 0;
    while (done < len) {
        DWORD n = 0;
        if (!WriteFile(h, p + done, len - done, &n, nullptr) || n == 0) return false;
        done += n;
    }
    return true;
}

bool read_all(HANDLE h, void* data, DWORD len) {
    auto* p = static_cast<BYTE*>(data);
    DWORD done = 0;
    while (done < len) {
        DWORD n = 0;
        if (!ReadFile(h, p + done, len - done, &n, nullptr) || n == 0) return false;
        done += n;
    }
    return true;
}

void send_frame(HANDLE h, uint8_t type, const void* payload, uint16_t len) {
    BYTE head[3] = { type, static_cast<BYTE>(len & 0xFF), static_cast<BYTE>((len >> 8) & 0xFF) };
    if (!write_all(h, head, 3)) return;
    if (len) write_all(h, payload, len);
}

// Outbound hits are pushed from the game thread while the serve loop may be
// blocked in ReadFile, so writes need their own lock.
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
    unsigned char body[16 + 4 + 4];
    std::memcpy(body, guid, 16);
    const float stamina = 0.0f;
    std::memcpy(body + 16, &stamina, 4);
    std::memcpy(body + 20, &health_delta, 4);
    EnterCriticalSection(&g_write_lock);
    send_frame(g_pipe, kLocalHit, body, sizeof(body));
    LeaveCriticalSection(&g_write_lock);
}

void send_result(HANDLE h, bool ok, uint8_t seq) {
    BYTE body[2] = { static_cast<BYTE>(ok ? 1 : 0), seq };
    EnterCriticalSection(&g_write_lock);
    send_frame(h, kResult, body, 2);
    LeaveCriticalSection(&g_write_lock);
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
                unsigned char guid[16];
                std::memcpy(guid, body, 16);
                float stamina, health;
                std::memcpy(&stamina, body + 16, 4);
                std::memcpy(&health,  body + 20, 4);
                const bool suppress = (body[24] & kFlagSuppressHitReaction) != 0;

                // Onto the game's thread, and wait so the agent gets a truthful
                // result rather than an optimistic one.
                bool ok = false;
                const bool ran = main_thread::run_sync([&] {
                    ok = rttr::apply_damage(guid, stamina, health, suppress);
                    if (ok) rttr::note_remote_damage(guid, health);
                });
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
                unsigned char guid[16];
                std::memcpy(guid, body, 16);
                bool ok = false;
                const bool ran = main_thread::run_sync([&] {
                    ok = rttr::apply_death(guid);
                });
                logf("PIPE: ApplyDeath -> %s", ok ? "dead" : "soul not loaded / failed");
                send_result(h, ran && ok, seq);
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
            PIPE_ACCESS_DUPLEX,
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

        // Blocks until an agent connects, or until stop() breaks it by
        // connecting to its own pipe.
        const BOOL ok = ConnectNamedPipe(h, nullptr)
                        ? TRUE
                        : (GetLastError() == ERROR_PIPE_CONNECTED);
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

    g_thread = std::thread(listen_loop);
    logf("PIPE: listening on %s", kPipeName);
    return true;
}

void stop() {
    if (!g_running.exchange(false)) return;
    // Unblock ConnectNamedPipe by connecting to it once.
    HANDLE poke = CreateFileA(kPipeName, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                              OPEN_EXISTING, 0, nullptr);
    if (poke != INVALID_HANDLE_VALUE) CloseHandle(poke);
    if (g_thread.joinable()) g_thread.join();
}

bool connected() { return g_connected; }

} // namespace kcdmp::pipe
