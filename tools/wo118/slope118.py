"""WO-118 Phase 2 sinking check on a slope: rendered Z against the floor under it.
usage: python slope118.py <trace.csv> <slope.geo file>
The geo file holds the [WO118SLOPE] geo and prof lines (floor Z sampled every L/(4n) along the path)."""
import csv, math, statistics, sys

rows = [{k: float(v) if v not in ('', 'nan') else float('nan') for k, v in r.items()} for r in csv.DictReader(open(sys.argv[1]))]
geo = prof = None
for line in open(sys.argv[2]):
    if '[WO118SLOPE] geo' in line:
        geo = dict(kv.split('=') for kv in line.split('geo ', 1)[1].split())
    if '[WO118SLOPE] prof' in line:
        prof = [float(v) for v in line.split('prof ', 1)[1].strip().split(',')]
x0, y0, ux, uy, L = (float(geo[k]) for k in ('x0', 'y0', 'ux', 'uy', 'L'))
step = L / (len(prof) - 1)

def floor_at(s):
    i = max(0, min(len(prof) - 2, int(s / step)))
    u = (s - i * step) / step
    return prof[i] + (prof[i + 1] - prof[i]) * u

def dz_of(r, kx, ky, kz):
    if math.isnan(r[kx]): return None
    s = (r[kx] - x0) * ux + (r[ky] - y0) * uy
    lat = -(r[kx] - x0) * uy + (r[ky] - y0) * ux
    if not (0.5 < s < L - 0.5) or abs(lat) > 0.5: return None
    return (r[kz] - floor_at(s)) * 100.0, s

print('== %s  rows=%d  L=%.1f m  rise=%s m' % (sys.argv[1].replace('\\', '/').split('/')[-1], len(rows), L, geo.get('rise')))
for label, k in (('render', ('render_x', 'render_y', 'render_z')), ('hook', ('hook_x', 'hook_y', 'hook_z'))):
    v = [dz_of(r, *k) for r in rows]
    v = [x for x in v if x]
    if not v:
        print('   %s: no frames on the path' % label); continue
    d = [x[0] for x in v]
    print('   %-6s frames on path=%d  Z minus floor: mean %+.2f cm  sd %.2f  min %+.2f  max %+.2f cm' % (label, len(d), statistics.mean(d), statistics.pstdev(d), min(d), max(d)))
fl = [r['flying'] for r in rows if r['flying'] >= 0]
print('   bFlying frames: %d / %d readable' % (sum(1 for x in fl if x == 1), len(fl)))
w = [(r['render_z'] - r['written_z']) * 1000 for r in rows if r['wrote'] == 1 and not math.isnan(r['render_z'])]
if w: print('   render minus written Z (same frame): mean %.3f mm  max |%.3f| mm' % (statistics.mean(w), max(abs(x) for x in w)))
# the engine's own Z correction between our write and the next hook
zc = [(b['hook_z'] - a['written_z']) * 100 for a, b in zip(rows, rows[1:]) if a['wrote'] == 1 and b['frame'] == a['frame'] + 1]
if zc: print('   hook(n+1) minus written(n) Z: mean %+.3f cm  max |%.3f| cm' % (statistics.mean(zc), max(abs(x) for x in zc)))
