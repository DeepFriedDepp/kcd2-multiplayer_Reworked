// WO-129: engine-free checks of the gait fix's pure half (native/KCDMP/gait_logic.h).
// Exit code 0 = all passed. Run by tools\Build-Installer.ps1.
//
// The regression this guards: WO-121 wrote the stream's m/s straight into the
// engine's pseudo-speed, which the engine reads as a logical speed CLASS
// (id = (int)(x + 0.5) - 1 into a 3-entry table on the avatars). 1.4 m/s read
// as walk by luck, 3.05 m/s (a jog) as sprint, and every sprint the player
// streams (4.66-5.28 m/s) as id 3-4: out of range, no pace tag, a slide
// ("requested logical speed id 4 is out of range 3" in both field logs).
#include <cmath>
#include <cstdio>
#include <thread>
#include <vector>

#include "gait_logic.h"

using namespace kcdmp::gait;

static int g_fail = 0, g_pass = 0;
#define CHECK(cond, ...) do { if (cond) ++g_pass; else { ++g_fail; std::printf("FAIL  %s:%d  ", __FILE__, __LINE__); std::printf(__VA_ARGS__); std::printf("\n"); } } while (0)

int main() {
    // ---- the class bands -------------------------------------------------
    CHECK(speed_class(0.0f) == 0.0f, "standing is class 0");
    CHECK(speed_class(0.09f) == 0.0f, "below 0.1 m/s is standing");
    CHECK(speed_class(NAN) == 0.0f, "NaN is standing");
    CHECK(speed_class(-1.0f) == 0.0f, "negative is standing");
    CHECK(speed_class(1.0f) == 1.0f && speed_class(1.4f) == 1.0f && speed_class(1.67f) == 1.0f && speed_class(2.0f) == 1.0f, "walk band");
    CHECK(speed_class(3.02f) == 2.0f && speed_class(3.05f) == 2.0f && speed_class(3.5f) == 2.0f, "run band");
    CHECK(speed_class(4.66f) == 3.0f && speed_class(5.28f) == 3.0f && speed_class(8.9f) == 3.0f, "sprint band");

    // ---- what the engine makes of it (round(x)-1), and the clamp -----------
    const int range = 3;   // the avatars' table (the field warnings: "out of range 3")
    for (float mps : {0.2f, 1.4f, 1.67f, 2.0f, 3.05f, 4.66f, 4.71f, 5.28f, 7.0f}) {
        const float cls = clamp_class(speed_class(mps), range);
        const int id = engine_logical_id(cls);
        CHECK(id >= 0 && id < range, "%.2f m/s -> class %.0f -> engine id %d, inside the %d-entry table", mps, cls, id, range);
    }
    // the WO-121 behaviour, for the record: m/s written raw
    CHECK(engine_logical_id(4.71f) == 4 && engine_logical_id(4.71f) >= range, "raw 4.71 m/s was id 4 (the field warning)");
    CHECK(engine_logical_id(3.05f) == 2, "raw 3.05 m/s read as id 2 (sprint) -- a jog shown as a sprint");
    CHECK(engine_logical_id(clamp_class(speed_class(3.05f), range)) == 1, "3.05 m/s now reads as id 1 (run)");
    CHECK(clamp_class(3.0f, 2) == 2.0f, "a 2-class body clamps a sprint to its top class");
    CHECK(clamp_class(3.0f, 0) == 3.0f && clamp_class(3.0f, -1) == 3.0f, "unknown range caps at 3");
    CHECK(clamp_class(1.0f, 1) == 1.0f, "a 1-class body keeps walk");

    // ---- the table ---------------------------------------------------------
    {
        static Table<16, 8> t;
        int dummy[64];
        void* a = &dummy[0]; void* b = &dummy[16];
        CHECK(t.find(a) == nullptr && t.live() == 0, "empty table");
        const int ia = t.insert(a, 100);
        CHECK(ia >= 0 && t.holds(ia, a) && t.live() == 1, "insert a");
        CHECK(t.insert(a, 100) == ia && t.live() == 1, "a second insert finds the same slot");
        t.publish(ia, 2.0f, 1.5f, -0.5f, 100);
        float c = 0, x = 0, y = 0;
        CHECK(t.read(a, 110, 30, &c, &x, &y) && c == 2.0f && x == 1.5f && y == -0.5f, "read back");
        CHECK(!t.read(a, 131, 30, &c, &x, &y), "older than the stale window: ignored");
        CHECK(!t.read(b, 100, 30, &c, &x, &y), "an unknown actor: nothing");
        const int ib = t.insert(b, 100);
        t.remove(ia);
        CHECK(t.find(a) == nullptr && t.live() == 1, "remove a");
        CHECK(t.find(b) != nullptr, "b still found past a's tombstone");
        CHECK(t.insert(a, 200) >= 0 && t.live() == 2 && t.find(ib >= 0 ? b : a) != nullptr, "a tombstone is reused");
        // fill up: a full probe window refuses, never corrupts
        int refused = 0;
        for (int i = 0; i < 40; ++i) if (t.insert(&dummy[i + 1], 1) < 0) ++refused;
        CHECK(refused > 0 && t.live() <= 16, "a full table refuses inserts (%d refused, %d live)", refused, t.live());
    }

    // ---- concurrent readers while the main thread publishes ------------------
    {
        static Table<256> t;
        static int bodies[40];
        std::vector<int> idx;
        for (int i = 0; i < 40; ++i) idx.push_back(t.insert(&bodies[i], 0));
        std::atomic<bool> stop{false};
        std::atomic<long> reads{0}, torn{0};
        std::vector<std::thread> workers;
        for (int w = 0; w < 4; ++w)
            workers.emplace_back([&] {
                while (!stop.load()) {
                    for (int i = 0; i < 40; ++i) {
                        float c, x, y;
                        if (t.read(&bodies[i], 0, 1u << 30, &c, &x, &y)) {
                            ++reads;
                            if (!(c == 0.0f || c == 1.0f || c == 2.0f || c == 3.0f)) ++torn;
                        }
                    }
                }
            });
        // publish until the readers have really raced it (not just started)
        for (int frame = 0; frame < 20000 || reads.load() < 200000; ++frame) {
            for (int i = 0; i < 40; ++i) t.publish(idx[i], static_cast<float>(frame % 4), 1.0f, 2.0f, 0);
            if (frame > 50000000) break;
        }
        stop = true;
        for (auto& th : workers) th.join();
        CHECK(reads.load() > 0 && torn.load() == 0, "%ld concurrent reads, %ld torn classes", reads.load(), torn.load());
    }

    std::printf("%d passed, %d failed\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
