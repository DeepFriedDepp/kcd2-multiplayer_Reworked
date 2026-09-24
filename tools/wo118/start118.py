"""WO-118 follow-up: what the renderer showed while a puppet started (pause, detach, bind).
usage: python start118.py <trace.csv> [thresh_cm]
Meant for a `hold` plan at the NPC's own spot, traced from before the peer starts:
the stream does not move, so every rendered movement is a start-up artifact.
Per frame:
  step  = |render(n) - render(n-1)|                 what the viewer sees move
  eng   = |hook(n) - written(last write before n)|  the engine moved the body between our writes
  after = |render(n) - written(n)|                  the engine moved it after our write, before render
"""
import csv, math, sys

rows = [{k: float(v) if v not in ('', 'nan') else float('nan') for k, v in r.items()} for r in csv.DictReader(open(sys.argv[1]))]
th = float(sys.argv[2]) if len(sys.argv) > 2 else 0.5
rows = [r for r in rows if not math.isnan(r['render_x'])]
t0 = rows[0]['t_ms']


def d(a, b):
    return math.dist(a, b) * 100.0


last_written = None
first_write = None
steps, flagged = [], []
for i, r in enumerate(rows):
    rp = (r['render_x'], r['render_y'], r['render_z'])
    hp = (r['hook_x'], r['hook_y'], r['hook_z'])
    step = d(rp, (rows[i - 1]['render_x'], rows[i - 1]['render_y'], rows[i - 1]['render_z'])) if i else 0.0
    eng = d(hp, last_written) if last_written else float('nan')
    after = float('nan')
    if r['wrote'] == 1:
        wp = (r['written_x'], r['written_y'], r['written_z'])
        after = d(rp, wp)
        if first_write is None: first_write = i
    if i: steps.append((step, i))
    if step > th or (not math.isnan(eng) and eng > th) or (not math.isnan(after) and after > th):
        flagged.append('  f%-4d t=%7.0f ms wrote=%d step=%6.2f cm eng=%6.2f cm after=%6.2f cm  render=(%.3f,%.3f,%.3f)' % (
            i, r['t_ms'] - t0, int(r['wrote']), step, eng, after, *rp))
    if r['wrote'] == 1:
        last_written = (r['written_x'], r['written_y'], r['written_z'])

print('== %s  frames=%d  first native write at frame %s' % (sys.argv[1].replace('\\', '/').split('/')[-1], len(rows), first_write))
big = sorted(steps, reverse=True)[:5]
print('   largest render steps: ' + ', '.join('%.2f cm @f%d' % s for s in big))
print('   frames with a render step > %.1f cm: %d' % (th, sum(1 for s, _ in steps if s > th)))
for l in flagged[:40]: print(l)
if len(flagged) > 40: print('  ... %d more' % (len(flagged) - 40))
