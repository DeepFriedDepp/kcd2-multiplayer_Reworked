"""WO-124 live harness: the running game's agent as the JOINER, a synthetic HOST
(synthpeer --join-host) serving a copy of a real host save through a real
local relay.

usage:
  python join124.py relay <KcdMpServer.dll>                 relay on 7778 (if free)
  python join124.py host <tag> [synthpeer --join-host options...]   the synthetic host, in the background,
                                                            connected FIRST (id 0 = the host); log logs/join124.host.<tag>.log
  python join124.py agent <tag> <KcdMpClient.dll> [ENV=VAL ...]     the agent (the joiner); log logs/join124.agent.<tag>.log
  python join124.py stop host|agent|all                     stop what `host` / `agent` / `relay` started
  python join124.py lines [n]                               the last MP-JOIN / WO124 lines of kcd.log and the agent log

The agent's data folder (staging) is KCDMP_DATA_DIR (default: logs/../data124, git-ignored).
Save names in these logs are playlineN/file (the agent and the synthetic host never print paths).
"""
import os, socket, subprocess, sys, time, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import live

PEER = os.environ.get('SYNTHPEER') or os.path.join(live.HERE, 'synthpeer', 'bin', 'Release', 'net8.0', 'SynthPeer.dll')
STATE = os.path.join(live.LOGS, 'join124.state.json')
DATA = os.path.join(live.HERE, 'data124')
DETACHED = 0x00000008 | 0x00000200


def launch(path):
    return [path] if path.lower().endswith('.exe') else [live.dotnet(), path]


def listening(port):
    s = socket.socket(); s.settimeout(0.5)
    try:
        return s.connect_ex(('127.0.0.1', port)) == 0
    finally:
        s.close()


def load():
    return json.load(open(STATE)) if os.path.exists(STATE) else {}


def save(st):
    json.dump(st, open(STATE, 'w'))


def relay(dll):
    st = load()
    if listening(7778):
        print('7778 already listening'); return
    r = subprocess.Popen(launch(os.path.abspath(dll)) + ['--port', '7778'], cwd=os.path.dirname(os.path.abspath(dll)),
                         stdout=open(os.path.join(live.LOGS, 'relay124.log'), 'a'), stderr=subprocess.STDOUT, creationflags=DETACHED)
    for _ in range(40):
        if listening(7778): break
        time.sleep(0.25)
    st['relay'] = r.pid; save(st)
    print('relay pid', r.pid)


def host(tag, opts):
    st = load()
    log = os.path.join(live.LOGS, 'join124.host.%s.log' % tag)
    h = subprocess.Popen([live.dotnet(), PEER, '--port', '7778', '--name', 'synth-host'] + opts,
                         stdout=open(log, 'w'), stderr=subprocess.STDOUT, creationflags=DETACHED)
    st['host'] = h.pid; save(st)
    time.sleep(2)
    print('host pid', h.pid, '->', log)
    print(open(log).read())


def agent(tag, dll, envs):
    st = load()
    env = dict(os.environ)
    os.makedirs(DATA, exist_ok=True)
    env.setdefault('KCDMP_DATA_DIR', DATA)
    for kv in envs:
        k, v = kv.split('=', 1)
        env[k] = v
    log = os.path.join(live.LOGS, 'join124.agent.%s.log' % tag)
    a = subprocess.Popen(launch(os.path.abspath(dll)) + ['--host', '127.0.0.1', '--port', '7778', '--name', 'wo124-joiner', '--no-voice', '--no-discord'],
                         cwd=os.path.dirname(os.path.abspath(dll)), stdout=open(log, 'w'), stderr=subprocess.STDOUT,
                         creationflags=DETACHED, env=env)
    st['agent'] = a.pid; st['agentlog'] = log; save(st)
    print('agent pid', a.pid, '->', log)


def stop(what):
    st = load()
    for k in (['host', 'agent', 'relay'] if what == 'all' else [what]):
        if k in st:
            subprocess.run(['taskkill', '/PID', str(st[k]), '/F'], capture_output=True)
            print('stopped', k, st.pop(k))
    save(st)


def lines(n):
    for l in live.tail(live.KLOG, n, r'MP-JOIN|WO124|MP-SAVELOCK'):
        print('kcd  ', l[:300])
    st = load()
    if 'agentlog' in st:
        for l in live.tail(st['agentlog'], n, r'MP-JOIN|MP-SAVELOCK'):
            print('agent', l[:400])


if __name__ == '__main__':
    v = sys.argv[1]
    if v == 'relay': relay(sys.argv[2])
    elif v == 'host': host(sys.argv[2], sys.argv[3:])
    elif v == 'agent': agent(sys.argv[2], sys.argv[3], sys.argv[4:])
    elif v == 'stop': stop(sys.argv[2])
    elif v == 'lines': lines(int(sys.argv[2]) if len(sys.argv) > 2 else 40)
