"""WO-118 trace analysis (kcdmp-trace-<npc>-<hhmmss>.csv from mp_npc_trace).

usage: python jitter118.py <csv> [line x0 y0 ux uy len] [hold x y]
Row = one frame: position at the DLL frame hook BEFORE our write, what the
native writer wrote (wrote=1), position at CSystem::Render entry, bFlying.

line: along-track analysis of a straight ping-pong path (frames with the body
      between 1 m and len-1 m along the path are scored -- the turnarounds are
      excluded, as in WO-116 s14).
hold: offset of the rendered body from the held point, per frame.
"""
import csv, math, statistics, sys

def f(v):
    try: return float(v)
    except ValueError: return float('nan')

path = sys.argv[1]
rows = [{k: f(v) for k, v in r.items()} for r in csv.DictReader(open(path))]
rows = [r for r in rows if not math.isnan(r['render_x'])]
mode = sys.argv[2] if len(sys.argv) > 2 else ''
print('== %s  rows=%d' % (path.split('\\')[-1].split('/')[-1], len(rows)))
dts = [b['t_ms'] - a['t_ms'] for a, b in zip(rows, rows[1:]) if b['frame'] == a['frame'] + 1]
if dts: print('   frame time mean %.1f ms (%.0f fps)' % (statistics.mean(dts), 1000 / statistics.mean(dts)))
wrote = sum(1 for r in rows if r['wrote'] == 1)
fl = [r['flying'] for r in rows if r['flying'] >= 0]
print('   frames written natively: %d / %d; bFlying frames: %d / %d readable' % (wrote, len(rows), sum(1 for x in fl if x == 1), len(fl)))

if mode == 'line':
    x0, y0, ux, uy, L = map(float, sys.argv[3:8])
    def s_of(x, y): return (x - x0) * ux + (y - y0) * uy
    def c_of(x, y): return -(x - x0) * uy + (y - y0) * ux
    for r in rows:
        r['s'] = s_of(r['render_x'], r['render_y']); r['c'] = c_of(r['render_x'], r['render_y'])
    steps, speeds, frozen, back, big = [], [], 0, 0, 0
    for a, b in zip(rows, rows[1:]):
        if b['frame'] != a['frame'] + 1: continue
        if not (1.0 < a['s'] < L - 1.0 and 1.0 < b['s'] < L - 1.0): continue
        ds = abs(b['s'] - a['s']); dt = (b['t_ms'] - a['t_ms']) / 1000.0
        steps.append(ds); speeds.append(ds / dt if dt > 0 else 0)
        if ds < 0.001: frozen += 1
    if steps:
        m = statistics.mean(steps)
        big = sum(1 for d in steps if d > 3 * m)
        print('   along-track frames scored %d' % len(steps))
        print('   per-frame step at render: mean %.2f cm  sd %.2f cm  min %.2f  max %.2f cm' % (100 * m, 100 * statistics.pstdev(steps), 100 * min(steps), 100 * max(steps)))
        print('   FROZEN frames (<1 mm): %d of %d (%.1f %%)   steps > 3x mean: %d' % (frozen, len(steps), 100.0 * frozen / len(steps), big))
        print('   per-frame speed: mean %.2f m/s  sd %.2f m/s' % (statistics.mean(speeds), statistics.pstdev(speeds)))
        print('   lateral sd %.3f m' % statistics.pstdev([r['c'] for r in rows]))
        strip = [round(1000 * d) for d in steps[20:52]]
        print('   step strip (mm): ' + ' '.join(str(x) for x in strip))
elif mode == 'hold':
    hx, hy = float(sys.argv[3]), float(sys.argv[4])
    off = [math.hypot(r['render_x'] - hx, r['render_y'] - hy) for r in rows]
    offz = [r['render_z'] for r in rows]
    moving = sum(1 for a, b in zip(rows, rows[1:]) if math.hypot(b['render_x'] - a['render_x'], b['render_y'] - a['render_y']) > 0.001)
    print('   rendered offset from the held point: mean %.1f mm  max %.1f mm; frames that move at render: %d / %d' % (1000 * statistics.mean(off), 1000 * max(off), moving, len(rows) - 1))
    print('   render z: min %.3f max %.3f' % (min(offz), max(offz)))

# engine motion: between render(n-1) and hook(n) (before our write), and hook->render inside a frame
between = [math.dist((b['hook_x'], b['hook_y'], b['hook_z']), (a['render_x'], a['render_y'], a['render_z']))
           for a, b in zip(rows, rows[1:]) if b['frame'] == a['frame'] + 1]
wrote_rows = [r for r in rows if r['wrote'] == 1]
dev = [math.dist((r['render_x'], r['render_y'], r['render_z']), (r['written_x'], r['written_y'], r['written_z'])) for r in wrote_rows]
if between: print('   engine moved the body between render(n-1) and hook(n): mean %.2f cm  max %.2f cm' % (100 * statistics.mean(between), 100 * max(between)))
if dev: print('   render minus what we wrote (same frame): mean %.3f mm  max %.3f mm' % (1000 * statistics.mean(dev), 1000 * max(dev)))
