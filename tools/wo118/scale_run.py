"""WO-118 Phase 6 scale: N walking puppets, frame time with the native writer on / off / on.
usage: python scale_run.py <tag> <N> [radius_m]      (N=0: baseline trace, no peer)
Environment: EMIT_MS (default 100) -- the peer's per-NPC emit period. At 100 ms the
agent's ingress caps the useful N (~64 at 75 fps, ~25 in the background; findings 3.7).
Under a heavy puppet load the game's REST server drops outside commands, so the whole
on/off/on schedule is armed in Lua (Script.SetTimer) BEFORE the peer starts.
Frame time: the trace CSVs' hook timestamps; the writer's own cost: MP-NPCWRITE-COST."""
import os, subprocess, sys, time, glob, shutil, csv, statistics
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import live

PEER = os.path.join(live.HERE, 'synthpeer', 'bin', 'Release', 'net8.0', 'SynthPeer.dll')
tag, N = sys.argv[1], int(sys.argv[2])
R = int(sys.argv[3]) if len(sys.argv) > 3 else 250
out = open(os.path.join(live.LOGS, 'scale.%s.txt' % tag), 'w')
def say(s):
    print(s); out.write(s + '\n'); out.flush()


def analyse(f, label):
    dst = os.path.join(live.TRACES, 'scale-%s-%s-%s' % (tag, label, os.path.basename(f)))
    shutil.copy(f, dst)
    rows = list(csv.DictReader(open(dst)))
    dts = sorted(float(b['t_ms']) - float(a['t_ms']) for a, b in zip(rows, rows[1:]) if int(b['frame']) == int(a['frame']) + 1)
    wrote = sum(1 for r in rows if r['wrote'] == '1')
    q = lambda p: dts[min(len(dts) - 1, int(p * len(dts)))]
    say('%-8s frames=%d wrote=%d  dt mean=%.2f sd=%.2f p50=%.2f p95=%.2f p99=%.2f max=%.2f ms  (%.0f fps)' % (
        label, len(rows), wrote, statistics.mean(dts), statistics.pstdev(dts), q(0.5), q(0.95), q(0.99), dts[-1], 1000 / statistics.mean(dts)))


live.focus()
live.lua("WO118_PlanMany(%d, %d, 4.0, 1.2)" % (R, max(N, 1)))
time.sleep(1.5)
tail = live.tail(live.KLOG, 3000)
k = max(i for i, l in enumerate(tail) if '[WO118MANY] n=' in l)
lines = [l.split('[WO118MANY] ', 1)[1].strip() for l in tail[:k] if '[WO118MANY] line' in l][-max(N, 1):]
npc = lines[0].split()[1]
pat = os.path.join(live.ROOT, 'kcdmp-trace-%s-*.csv' % npc)
if N == 0:
    before = set(glob.glob(pat))
    live.cmd('mp_npc_trace %s 8' % npc)
    time.sleep(10)
    analyse(sorted(set(glob.glob(pat)) - before)[-1], 'base')
    sys.exit(0)
say(tail[k].split('] ', 1)[1].strip())
pf = os.path.join(live.LOGS, 'plan.scale.%s.txt' % tag)
open(pf, 'w').write('\n'.join(lines) + '\n')
say('plan %d movers, traced npc=%s, emit %s ms' % (len(lines), npc, os.environ.get('EMIT_MS', '100')))
sched = ("KCD2MP_SetNpcNativeWrite('on') "
         "Script.SetTimer(16000, function() KCD2MP_NpcTrace('%s 8') end) "
         "Script.SetTimer(27000, function() KCD2MP_SetNpcNativeWrite('off') end) "
         "Script.SetTimer(34000, function() KCD2MP_NpcTrace('%s 8') end) "
         "Script.SetTimer(45000, function() KCD2MP_SetNpcNativeWrite('on') end) "
         "Script.SetTimer(54000, function() KCD2MP_NpcTrace('%s 8') end)") % (npc, npc, npc)
before = set(glob.glob(pat))
nbefore = len(live.tail(live.NLOG, 1_000_000))
live.lua(sched)
log = open(os.path.join(live.LOGS, 'peer.scale.%s.log' % tag), 'w')
p = subprocess.Popen([live.dotnet(), PEER, '--plan', pf, '--duration', '75', '--sender-clock', 'qpc', '--emit-ms', os.environ.get('EMIT_MS', '100')],
                     stdout=log, stderr=subprocess.STDOUT)
time.sleep(66)
p.kill()
new = sorted(set(glob.glob(pat)) - before)
for f, label in zip(new, ['on-1', 'off', 'on-2']):
    analyse(f, label)
if len(new) < 3: say('only %d traces' % len(new))
for l in live.tail(live.NLOG, 1_000_000)[nbefore:]:
    if 'MP-NPCWRITE-COST' in l or 'config native_write' in l or 'DISARM' in l:
        say('  ' + l.strip()[:200])
say('done')
