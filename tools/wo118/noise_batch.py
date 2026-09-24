"""WO-118 Phase 6 network noise: one walking puppet through the local relay, the
synthetic peer injecting delay/jitter/spikes AFTER its sender stamp.
Runs are spaced GAP s apart so the DLL's per-source clock (5 s) and sequence (2 s)
resets always see a silent stream between runs.
usage: python noise_batch.py [outfile] [run tags...]      (default: all runs)"""
import os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import live, peer_trace

GAP = 12
WALK = os.path.join(live.HERE, 'plans', 'plan.walk.txt')
LINE = ['line', '2329.063', '2047.871', '-0.9239', '0.3827', '8.0']
NOISE = ['--delay-ms', '40', '--jitter-ms', '60']
SPIKE = NOISE + ['--spike-pct', '3', '--spike-ms', '250']
RUNS = {
    # tag: (sender clock on the receiver, SynthPeer args)
    'P0': ('on', ['--seed', '1', '--sender-clock', 'qpc']),
    'P1': ('on', ['--seed', '2', '--sender-clock', 'qpc'] + NOISE),
    'P2': ('on', ['--seed', '3', '--sender-clock', 'qpc'] + SPIKE),
    'P3': ('on', ['--seed', '3', '--sender-clock', 'tick'] + SPIKE),
    'P4': ('off', ['--seed', '3', '--sender-clock', 'qpc'] + SPIKE),
    'P5': ('off', ['--seed', '1', '--sender-clock', 'qpc']),
}
out = open(sys.argv[1] if len(sys.argv) > 1 else os.path.join(live.LOGS, 'noise_batch.txt'), 'w')
tags = sys.argv[2:] or list(RUNS)
for i, tag in enumerate(tags):
    sc, synth = RUNS[tag]
    live.lua("KCD2MP_SetNpcSenderClock('%s')" % sc)
    time.sleep(1.0)
    out.write('#### %s  senderclock=%s  synth=%s\n' % (tag, sc, ' '.join(synth))); out.flush()
    f = peer_trace.run(tag, WALK, 'ttkc_man_2', 8, 7, synth)
    if f:
        a = subprocess.run([sys.executable, os.path.join(live.HERE, 'jitter118.py'), f] + LINE, capture_output=True, text=True)
        out.write(a.stdout + a.stderr + '\n')
    else:
        out.write('NO TRACE\n')
    out.flush()
    if i + 1 < len(tags): time.sleep(GAP)
live.lua("KCD2MP_SetNpcSenderClock('on')")
out.write('DONE\n')
out.close()
print(open(out.name).read())
