"""WO-118 Phase 5 regression gate: four traced runs through a local relay.
  1 walker, native on           -> 0 frozen frames (render == written)
  2 seated, native on + detach  -> <= 1 mm at render, no moving frames
  3 walker, native off          -> the stair-step returns (>= 40 % frozen)
  4 seated, native + detach off -> the sawtooth returns (>= 20 mm, most frames moving)
usage: python phase5_gate.py [outfile]
Needs: the relay on 7778, the agent connected as the JOINER (see README), the
throwaway save's Troskowitz NPCs (plans/plan.walk.txt, plans/plan.seat.txt).
Restores mp_npc_native_write on and mp_npc_detach on at the end."""
import os, sys, time, csv, math, statistics
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import live, peer_trace

out = open(sys.argv[1] if len(sys.argv) > 1 else os.path.join(live.LOGS, 'phase5_gate.txt'), 'w')
def say(s):
    print(s); out.write(s + '\n'); out.flush()

WALK = os.path.join(live.HERE, 'plans', 'plan.walk.txt')   # ttkc_man_2, 8 m ping-pong at 1.4 m/s
SEAT = os.path.join(live.HERE, 'plans', 'plan.seat.txt')   # ttkc_man_22 held 3 m off his seat
X0, Y0, UX, UY, L = 2329.063, 2047.871, -0.9239, 0.3827, 8.0
SEAT_PT = (2312.293, 2080.328)


def rows_of(f):
    return [{k: float(v) if v not in ('', 'nan') else float('nan') for k, v in r.items()} for r in csv.DictReader(open(f))]


def walker(f, label):
    rows = rows_of(f)
    st, sp, dts = [], [], []
    for a, b in zip(rows, rows[1:]):
        if b['frame'] != a['frame'] + 1: continue
        sa = (a['render_x'] - X0) * UX + (a['render_y'] - Y0) * UY
        sb = (b['render_x'] - X0) * UX + (b['render_y'] - Y0) * UY
        if not (1 < sa < L - 1 and 1 < sb < L - 1): continue
        dt = b['t_ms'] - a['t_ms']
        s = abs(sb - sa) * 100
        st.append(s); sp.append(s / 100 / (dt / 1000)); dts.append(dt)
    frozen = sum(1 for s in st if s < 0.1)
    w = [abs(r['render_x'] - r['written_x']) + abs(r['render_y'] - r['written_y']) for r in rows if r['wrote'] == 1 and not math.isnan(r['render_x'])]
    fl = [r['flying'] for r in rows if r['flying'] >= 0]
    say('%-16s frames=%d scored=%d frozen=%d (%.1f %%) step mean %.2f cm sd %.2f  speed sd %.3f m/s  frame %.1f ms  render-written max %.3f mm  flying %d/%d' % (
        label, len(rows), len(st), frozen, 100.0 * frozen / max(1, len(st)), statistics.mean(st), statistics.pstdev(st),
        statistics.pstdev(sp), statistics.mean(dts), (max(w) * 1000) if w else float('nan'), sum(1 for x in fl if x == 1), len(fl)))
    return frozen, len(st)


def seated(f, label):
    rows = rows_of(f)
    off = [math.dist((r['render_x'], r['render_y']), SEAT_PT) * 1000 for r in rows if not math.isnan(r['render_x'])]
    base = statistics.median(off)
    dev = max(abs(o - base) for o in off)
    moving = sum(1 for a, b in zip(rows, rows[1:]) if math.dist((a['render_x'], a['render_y']), (b['render_x'], b['render_y'])) > 0.001)
    fl = [r['flying'] for r in rows if r['flying'] >= 0]
    say('%-16s frames=%d offset from the hold point: median %.1f mm, max deviation %.1f mm; moving frames %d; flying %d/%d' % (
        label, len(rows), base, dev, moving, sum(1 for x in fl if x == 1), len(fl)))
    return dev, moving


def state_of(npc):
    live.lua("local e=System.GetEntityByName('%s'); local s='?'; pcall(function() s=tostring(e.actor:GetCurrentAnimationState()) end); System.LogAlways('[WO118GATE] %s state='..s)" % (npc, npc))
    time.sleep(1.0)
    l = live.tail(live.KLOG, 50, r'\[WO118GATE\] %s state=' % npc)
    return l[-1].split('state=', 1)[1].strip() if l else '?'


def wait_seated(npc, timeout=90):
    # A released puppet walks back to its activity on its own (5-20 s).
    t0 = time.time()
    while time.time() - t0 < timeout:
        s = state_of(npc)
        if 'Sit' in s: return s
        time.sleep(5)
    return state_of(npc)


def run(tag, plan, npc):
    return peer_trace.run(tag, plan, npc, 8, 12, ['--sender-clock', 'qpc'])


verdict = []
live.lua("KCD2MP_SetNpcNativeWrite('on') KCD2MP_SetNpcDetach('on')")
time.sleep(2)
f = run('gate1', WALK, 'ttkc_man_2')
fz, n = walker(f, '1 walker/native') if f else (None, 0)
verdict.append(('1 walker native: 0 frozen frames', f is not None and fz == 0))
time.sleep(10)
say('   ttkc_man_22 before step 2: ' + wait_seated('ttkc_man_22'))
f = run('gate2', SEAT, 'ttkc_man_22')
dev, mv = seated(f, '2 seat/native') if f else (None, None)
verdict.append(('2 seated native+detach: <= 1 mm, no moving frames', f is not None and dev <= 1.0 and mv == 0))
time.sleep(10)
live.lua("KCD2MP_SetNpcNativeWrite('off')")
time.sleep(2)
f = run('gate3', WALK, 'ttkc_man_2')
fz, n = walker(f, '3 walker/legacy') if f else (None, 0)
verdict.append(('3 walker legacy: the stair-step returns (>= 40 % frozen)', f is not None and n and fz / n >= 0.40))
time.sleep(10)
live.lua("KCD2MP_SetNpcDetach('off')")
say('   ttkc_man_22 before step 4: ' + wait_seated('ttkc_man_22'))
f = run('gate4', SEAT, 'ttkc_man_22')
dev, mv = seated(f, '4 seat/legacy') if f else (None, None)
verdict.append(('4 seated legacy: the sawtooth returns (>= 20 mm, most frames moving)', f is not None and dev >= 20 and mv >= 100))
live.lua("KCD2MP_SetNpcNativeWrite('on') KCD2MP_SetNpcDetach('on')")
say('')
for name, ok in verdict:
    say('%-4s %s' % ('PASS' if ok else 'FAIL', name))
say('GATE %s' % ('GREEN' if all(ok for _, ok in verdict) else 'RED'))
