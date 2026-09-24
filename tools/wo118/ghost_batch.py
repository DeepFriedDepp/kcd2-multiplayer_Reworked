"""WO-118 Phase 2b/6: the peer's ghost (kcd2mp_0) on the native writer, clean and
with network jitter. The ghost stream runs at the real pos-native cadence (~30 ms).
usage: python ghost_batch.py [outfile]"""
import os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import live, peer_trace

PLAN = os.path.join(live.HERE, 'plans', 'plan.ghost.txt')
RUNS = [('g0', []), ('g1', ['--delay-ms', '20', '--jitter-ms', '20']), ('g2', ['--delay-ms', '40', '--jitter-ms', '60'])]
out = open(sys.argv[1] if len(sys.argv) > 1 else os.path.join(live.LOGS, 'ghost_batch.txt'), 'w')
for i, (tag, synth) in enumerate(RUNS):
    out.write('#### %s synth=%s\n' % (tag, ' '.join(synth))); out.flush()
    # 14 s: the ghost has to spawn (first position frame) and bind before the trace.
    f = peer_trace.run(tag, PLAN, 'kcd2mp_0', 8, 14, ['--seed', str(i + 1)] + synth)
    if f:
        a = subprocess.run([sys.executable, os.path.join(live.HERE, 'jitter118.py'), f, 'line', '2326.14', '2050.21', '1.0', '0.0', '10.0'],
                           capture_output=True, text=True)
        out.write(a.stdout + a.stderr + '\n')
    else:
        out.write('NO TRACE\n')
    out.flush()
    time.sleep(12)
out.write('DONE\n')
out.close()
print(open(out.name).read())
