#pragma once
// WO-129 -- the engine-free half of the gait fix (motion.cpp), kept apart so
// native/tests can check it without a game:
//   * speed_class / clamp_class: m/s on the wire -> the engine's logical speed
//     CLASS (pseudo-speed is read as round(x)-1 into the body's table)
//   * Table: the lock-free actor -> (class, velocity) table the tag-update
//     hook reads from any thread while the main thread writes it

#include <atomic>
#include <cstdint>
#include <cstring>

namespace kcdmp::gait {

// Bands from the player's own speeds on the wire (first two-player session:
// walk 1.67-2.00, run 3.02-3.06, sprint 4.66-5.28 m/s) and the engine's own
// speed classes (WO-116: walk 1.4, run 2.94, sprint 5.19).
inline float speed_class(float mps) {
    if (!(mps >= 0.1f)) return 0.0f;   // also NaN
    if (mps < 2.4f) return 1.0f;
    if (mps < 4.0f) return 2.0f;
    return 3.0f;
}

// The body's own class count caps the class (engine: count(soul, kind));
// unknown (<= 0) caps at the 3 classes every avatar showed.
inline float clamp_class(float cls, int range) {
    const float top = range > 0 ? static_cast<float>(range) : 3.0f;
    return cls > top ? top : cls;
}

// What the engine's mapper makes of a pseudo-speed (RPGModule manager
// vtbl[0x78]: (int)(x + 0.5) - 1 for x > 0), for the tests.
inline int engine_logical_id(float pseudo) {
    return pseudo >= 0.0f ? static_cast<int>(pseudo + 0.5f) - 1 : static_cast<int>(pseudo - 0.5f) - 1;
}

struct Slot {
    std::atomic<void*> actor{nullptr};
    std::atomic<uint32_t> cls{0};     // float bits
    std::atomic<uint64_t> vel{0};     // two float bits: x low, y high
    std::atomic<uint32_t> tick{0};
};

// Open addressing over a fixed array. Only one thread (the game's main
// thread) inserts and removes; any thread finds. A removed slot becomes a
// tombstone (actor == 1) so a probe chain past it still resolves.
template <int N, int Probe = 32>
class Table {
    static_assert((N & (N - 1)) == 0, "N must be a power of two");
public:
    static void* tomb() { return reinterpret_cast<void*>(1); }

    int find_index(const void* actor) const {
        const int h = hash(actor);
        for (int k = 0; k < Probe; ++k) {
            const int i = (h + k) & (N - 1);
            void* a = slots_[i].actor.load(std::memory_order_acquire);
            if (a == actor) return i;
            if (!a) return -1;
        }
        return -1;
    }
    const Slot* find(const void* actor) const { const int i = find_index(actor); return i < 0 ? nullptr : &slots_[i]; }

    int insert(void* actor, uint32_t tickNow) {
        const int h = hash(actor);
        int free = -1;
        for (int k = 0; k < Probe; ++k) {
            const int i = (h + k) & (N - 1);
            void* a = slots_[i].actor.load(std::memory_order_relaxed);
            if (a == actor) return i;
            if (a == tomb() && free < 0) free = i;
            if (!a) { if (free < 0) free = i; break; }
        }
        if (free < 0) return -1;
        Slot& s = slots_[free];
        s.cls.store(0); s.vel.store(0); s.tick.store(tickNow);
        s.actor.store(actor, std::memory_order_release);
        live_.fetch_add(1);
        return free;
    }

    void remove(int i) {
        if (i < 0 || i >= N) return;
        if (slots_[i].actor.exchange(tomb()) > tomb()) live_.fetch_sub(1);
    }

    bool holds(int i, const void* actor) const { return i >= 0 && i < N && slots_[i].actor.load(std::memory_order_relaxed) == actor; }

    void publish(int i, float cls, float vx, float vy, uint32_t tickNow) {
        uint32_t cb, lo, hi;
        std::memcpy(&cb, &cls, 4); std::memcpy(&lo, &vx, 4); std::memcpy(&hi, &vy, 4);
        Slot& s = slots_[i];
        s.cls.store(cb, std::memory_order_relaxed);
        s.vel.store(static_cast<uint64_t>(lo) | (static_cast<uint64_t>(hi) << 32), std::memory_order_relaxed);
        s.tick.store(tickNow, std::memory_order_release);
    }

    // The values for `actor`, when present and published within staleTicks.
    bool read(const void* actor, uint32_t tickNow, uint32_t staleTicks, float* cls, float* vx, float* vy) const {
        const Slot* s = find(actor);
        if (!s) return false;
        if (tickNow - s->tick.load(std::memory_order_acquire) > staleTicks) return false;
        const uint32_t cb = s->cls.load(std::memory_order_relaxed);
        const uint64_t vb = s->vel.load(std::memory_order_relaxed);
        const uint32_t lo = static_cast<uint32_t>(vb), hi = static_cast<uint32_t>(vb >> 32);
        std::memcpy(cls, &cb, 4); std::memcpy(vx, &lo, 4); std::memcpy(vy, &hi, 4);
        return true;
    }

    int live() const { return live_.load(std::memory_order_relaxed); }

private:
    static int hash(const void* p) { return static_cast<int>((reinterpret_cast<uintptr_t>(p) >> 4) * 2654435761u & (N - 1)); }
    Slot slots_[N];
    std::atomic<int> live_{0};
};

} // namespace kcdmp::gait
