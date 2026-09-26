"""WO-123 live smoke orchestrator: one synthetic-joiner scenario against the running
game's agent (the host), with drift samples during the pause.

usage: python run123.py <tag> [--drift SECONDS] [--capture] -- [synthpeer --join options...]

Starts `SynthPeer --join` (its log: logs/join123.<tag>.log), waits for the mod's
`MP-JOIN pause`, samples every actor near the host (drift123) right after it and
again SECONDS later (default: none), optionally captures the game window only,
then waits for the joiner to exit and prints the MP-JOIN lines of both sides.
"""
import os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import live, drift123, join123

args = sys.argv[1:]
tag = args[0]
sep = args.index('--') if '--' in args else len(args)
mine, peer = args[1:sep], args[sep + 1:]
drift = float(mine[mine.index('--drift') + 1]) if '--drift' in mine else 0
capture = '--capture' in mine
SCR = os.environ.get('WO123_SCRATCH', '')

log = os.path.join(live.LOGS, 'join123.%s.log' % tag)
k0 = os.path.getsize(live.KLOG)
a0 = os.path.getsize(os.path.join(live.LOGS, 'agent123.log'))
t0 = time.time()
p = subprocess.Popen([live.dotnet(), join123.PEER, '--join', '--port', '7778', '--name', 'synth-joiner'] + peer,
                     stdout=open(log, 'w'), stderr=subprocess.STDOUT)


def klog_since():
    with open(live.KLOG, 'rb') as f:
        f.seek(k0)
        return f.read().decode('utf-8', 'replace')


def cap(name):
    if capture and SCR:
        subprocess.run(['powershell', '-NoProfile', '-File', os.path.join(SCR, 'win.ps1'), '-ProcId', str(live_pid()), '-Action', 'capture',
                        '-Out', os.path.join(SCR, 'cap.%s.%s.png' % (tag, name))], capture_output=True)


def live_pid():
    r = subprocess.run(['powershell', '-NoProfile', '-Command', "(Get-Process KingdomCome).Id"], capture_output=True, text=True)
    return int(r.stdout.split()[0])


paused_at = None
while p.poll() is None:
    if paused_at is None and 'MP-JOIN pause join=' in klog_since():
        paused_at = time.time()
        print('pause seen %.1f s after start' % (paused_at - t0))
        if drift:
            drift123.snap(tag + '_p0'); cap('p0')
    if paused_at and drift and time.time() - paused_at >= drift:
        drift123.snap(tag + '_p1'); cap('p1')
        drift = 0
    time.sleep(0.5)
print('joiner exited rc=%s after %.1f s' % (p.returncode, time.time() - t0))
time.sleep(2)
print(open(log).read())
for l in klog_since().splitlines():
    if 'MP-JOIN' in l or 'WO123' in l and 'DRIFT' not in l:
        print('kcd  ', l[:400])
with open(os.path.join(live.LOGS, 'agent123.log'), 'rb') as f:
    f.seek(a0)
    for l in f.read().decode('utf-8', 'replace').splitlines():
        if 'MP-JOIN' in l or 'MP-WORLDSAVE' in l:
            print('agent', l[:400])
