"""WO-123 live smoke: the running game's agent as the HOST, the synthetic joiner
(synthpeer --join) through a real local relay.

usage:
  python join123.py up <KcdMpClient.dll> <KcdMpServer.dll>   relay on 7778 (if free) + the agent, connected FIRST (id 0 = host)
  python join123.py join <tag> [synthpeer --join options...]  one synthetic joiner run; its log: logs/join123.<tag>.log
  python join123.py lines [n]                                 the last n MP-JOIN lines of kcd.log and the agent log
  python join123.py down                                      stop the agent and the relay started by `up`

The game must be up (Modding Tools build, a throwaway save, KCDMP.dll injected)
and mp_shared_world on (`python live.py cmd "mp_shared_world on"`). The joiner's
staging folder is its own temp folder, deleted at exit: a received world is a
real save and never goes in a log or the repo (logs/ is git-ignored).
"""
import os, socket, subprocess, sys, time, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import live

PEER = os.path.join(live.HERE, 'synthpeer', 'bin', 'Release', 'net8.0', 'SynthPeer.dll')
STATE = os.path.join(live.LOGS, 'join123.state.json')
DETACHED = 0x00000008 | 0x00000200


def launch(path):
    return [path] if path.lower().endswith('.exe') else [live.dotnet(), path]


def listening(port):
    s = socket.socket(); s.settimeout(0.5)
    try:
        return s.connect_ex(('127.0.0.1', port)) == 0
    finally:
        s.close()


def agents_running():
    # Two agents under one identity fight over every toggle (and the relay gives them
    # ids 0 and 1): `up` refuses to start a second one (found live, WO-123).
    r = subprocess.run(['powershell', '-NoProfile', '-Command',
                        "Get-CimInstance Win32_Process -Filter \"Name='dotnet.exe' or Name='KcdMpClient.exe'\" | "
                        "Where-Object { $_.CommandLine -match 'KcdMpClient' } | ForEach-Object { $_.ProcessId }"],
                       capture_output=True, text=True)
    return [int(x) for x in r.stdout.split() if x.strip().isdigit()]


def up(agent, relay):
    running = agents_running()
    if running:
        sys.exit('an agent is already running (pid %s) -- `down` first; two agents would fight' % ', '.join(map(str, running)))
    st = {}
    if not listening(7778):
        r = subprocess.Popen(launch(os.path.abspath(relay)) + ['--port', '7778'], cwd=os.path.dirname(os.path.abspath(relay)),
                             stdout=open(os.path.join(live.LOGS, 'relay123.log'), 'w'), stderr=subprocess.STDOUT, creationflags=DETACHED)
        st['relay'] = r.pid
        for _ in range(40):
            if listening(7778): break
            time.sleep(0.25)
    a = subprocess.Popen(launch(os.path.abspath(agent)) + ['--host', '127.0.0.1', '--port', '7778', '--name', 'wo123-host', '--no-voice', '--no-discord'],
                         cwd=os.path.dirname(os.path.abspath(agent)), stdout=open(os.path.join(live.LOGS, 'agent123.log'), 'w'),
                         stderr=subprocess.STDOUT, creationflags=DETACHED)
    st['agent'] = a.pid
    json.dump(st, open(STATE, 'w'))
    print('relay pid %s, agent pid %d (logs/agent123.log)' % (st.get('relay', 'already up'), a.pid))


def down():
    st = json.load(open(STATE)) if os.path.exists(STATE) else {}
    for k in ('agent', 'relay'):
        if k in st:
            subprocess.run(['taskkill', '/PID', str(st[k]), '/F'], capture_output=True)
            print('stopped', k, st[k])


def join(tag, opts):
    log = os.path.join(live.LOGS, 'join123.%s.log' % tag)
    t0 = time.time()
    with open(log, 'w') as f:
        subprocess.run([live.dotnet(), PEER, '--join', '--port', '7778', '--name', 'synth-joiner'] + opts, stdout=f, stderr=subprocess.STDOUT)
    print(open(log).read())
    print('wall_s=%.1f' % (time.time() - t0))


def lines(n):
    for l in live.tail(live.KLOG, n, r'MP-JOIN|WO123'):
        print('kcd  ', l[:300])
    for l in live.tail(os.path.join(live.LOGS, 'agent123.log'), n, r'MP-JOIN|MP-WORLDSAVE'):
        print('agent', l[:300])


if __name__ == '__main__':
    v = sys.argv[1]
    if v == 'up': up(sys.argv[2], sys.argv[3])
    elif v == 'down': down()
    elif v == 'join': join(sys.argv[2], sys.argv[3:])
    elif v == 'lines': lines(int(sys.argv[2]) if len(sys.argv) > 2 else 30)
