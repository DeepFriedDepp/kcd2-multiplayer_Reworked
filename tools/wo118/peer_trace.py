"""Synthetic authority peer with a plan -> wait -> mp_npc_trace of one entity -> peer stopped.
Prints the path of the trace copied into traces/.
usage: python peer_trace.py <tag> <plan> <entity> <trace_s> <wait_s> [-- <SynthPeer args...>]
The trace is armed in Lua (Script.SetTimer) BEFORE the peer starts: under a heavy
puppet load the game's REST server drops outside commands."""
import os, subprocess, sys, time, glob, shutil
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import live

PEER = os.path.join(live.HERE, 'synthpeer', 'bin', 'Release', 'net8.0', 'SynthPeer.dll')


def run(tag, plan, npc, ts, ws, synth):
    live.focus()
    pat = os.path.join(live.ROOT, 'kcdmp-trace-%s-*.csv' % npc)
    before = set(glob.glob(pat))
    live.lua("Script.SetTimer(%d, function() KCD2MP_NpcTrace('%s %d') end)" % (int(ws * 1000), npc, int(ts)))
    log = open(os.path.join(live.LOGS, 'peer.%s.log' % tag), 'w')
    p = subprocess.Popen([live.dotnet(), PEER, '--plan', plan, '--duration', str(int(ws + ts + 10))] + synth,
                         stdout=log, stderr=subprocess.STDOUT)
    new, t0 = set(), time.time()
    while time.time() - t0 < ws + ts + 25:
        time.sleep(0.5)
        new = set(glob.glob(pat)) - before
        if new: break
    time.sleep(0.5)
    p.kill()
    if not new:
        return None
    f = sorted(new)[-1]
    dst = os.path.join(live.TRACES, '%s-%s' % (tag, os.path.basename(f)))
    shutil.copy(f, dst)
    return dst


if __name__ == '__main__':
    a = sys.argv
    synth = a[a.index('--') + 1:] if '--' in a else []
    out = run(a[1], a[2], a[3], float(a[4]), float(a[5]), synth)
    print(out or 'NO TRACE')
    sys.exit(0 if out else 1)
