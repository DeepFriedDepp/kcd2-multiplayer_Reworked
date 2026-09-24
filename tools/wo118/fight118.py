"""WO-118 Phase 2 sinking check in a fight: a circling puppet with the combat flag and a swing cue every 2.5 s.
usage: python fight118.py <trace.csv> <floor_z> <cz>
Holds (the DLL leaves the body to the swing for ~900 ms) show as runs of wrote=0 frames."""
import csv, math, statistics, sys
rows = [{k: float(v) if v not in ('', 'nan') else float('nan') for k, v in r.items()} for r in csv.DictReader(open(sys.argv[1]))]
floor, cz = float(sys.argv[2]), float(sys.argv[3])
print('== %s rows=%d  floor=%.3f stream z=%.3f' % (sys.argv[1].replace('\\', '/').split('/')[-1], len(rows), floor, cz))
dts = [b['t_ms'] - a['t_ms'] for a, b in zip(rows, rows[1:])]
print('   frame time mean %.1f ms' % statistics.mean(dts))
w = [r for r in rows if r['wrote'] == 1]
h = [r for r in rows if r['wrote'] == 0]
print('   frames written %d, held/unwritten %d' % (len(w), len(h)))
rz = [(r['render_z'] - floor) * 100 for r in rows if not math.isnan(r['render_z'])]
print('   render Z minus floor, all frames: mean %+.2f cm  min %+.2f  max %+.2f' % (statistics.mean(rz), min(rz), max(rz)))
if h:
    hz = [(r['render_z'] - floor) * 100 for r in h if not math.isnan(r['render_z'])]
    print('   ... on held frames only:       mean %+.2f cm  min %+.2f  max %+.2f' % (statistics.mean(hz), min(hz), max(hz)))
fl = [r['flying'] for r in rows if r['flying'] >= 0]
print('   bFlying frames: %d / %d readable' % (sum(1 for x in fl if x == 1), len(fl)))
# hold boundaries: first written frame after a run of unwritten frames
runs, i = [], 0
while i < len(rows):
    if rows[i]['wrote'] == 0:
        j = i
        while j < len(rows) and rows[j]['wrote'] == 0: j += 1
        if j < len(rows) and i > 0:
            a, b = rows[i - 1], rows[j]
            # how far the engine carried the body during the hold, and the step back onto the stream at resume
            drift = math.dist((a['written_x'], a['written_y']), (b['hook_x'], b['hook_y'])) * 100
            snap = math.dist((b['hook_x'], b['hook_y']), (b['written_x'], b['written_y'])) * 100
            dzs = (b['written_z'] - b['hook_z']) * 100
            runs.append((j - i, (rows[j]['t_ms'] - rows[i]['t_ms']), drift, snap, dzs))
        i = j
    else:
        i += 1
for n, ms, drift, snap, dzs in runs:
    print('   hold: %3d frames %4.0f ms  engine carried the body %.1f cm; resume step %.1f cm (dz %+.1f cm)' % (n, ms, drift, snap, dzs))
