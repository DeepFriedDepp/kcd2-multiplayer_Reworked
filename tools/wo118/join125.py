"""WO-125 live harness: the running game's agent as the JOINER, a synthetic WO-125 HOST
(synthpeer --join-host125) serving COPIES of real host saves through a real local relay,
driven through a control file (save / reload / world / mode / leave).

usage:
  python join125.py relay <KcdMpServer.dll>                  relay on 7778 (if free)
  python join125.py host <tag> <world copy> [synthpeer options...]   the synthetic host, connected FIRST (id 0);
                                                             its control file: logs/join125.ctl.<tag>
  python join125.py ctl <tag> <line>                         append one command to that host's control file
  python join125.py agent <tag> <KcdMpClient.dll> [ENV=VAL ...]   the agent (the joiner); KCDMP_DATA_DIR = data125
  python join125.py stop host|agent|all
  python join125.py lines [n]                                the last MP-HENRY / MP-JOIN lines of kcd.log, the agent and the host
  python join125.py choose bring|fresh                       what the launcher's buttons send (/join-choice)

The agent's data folder (Henry store, staging, host branch) is KCDMP_DATA_DIR (default: data125, git-ignored).
Save names in these logs are playlineN/file; the seed is only ever printed as its tag.
"""
import os, socket, subprocess, sys, time, json, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import live

PEER = os.environ.get('SYNTHPEER') or os.path.join(live.HERE, 'synthpeer', 'bin', 'Release', 'net8.0', 'SynthPeer.dll')
STATE = os.path.join(live.LOGS, 'join125.state.json')
DATA = os.path.join(live.HERE, 'data125')
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
                         stdout=open(os.path.join(live.LOGS, 'relay125.log'), 'a'), stderr=subprocess.STDOUT, creationflags=DETACHED)
    for _ in range(40):
        if listening(7778): break
        time.sleep(0.25)
    st['relay'] = r.pid; save(st)
    print('relay pid', r.pid)


def ctlpath(tag):
    return os.path.join(live.LOGS, 'join125.ctl.%s' % tag)


def host(tag, world, opts):
    st = load()
    log = os.path.join(live.LOGS, 'join125.host.%s.log' % tag)
    open(ctlpath(tag), 'w').close()
    h = subprocess.Popen([live.dotnet(), PEER, '--port', '7778', '--name', 'synth-host', '--join-host125', world, '--ctl', ctlpath(tag)] + opts,
                         stdout=open(log, 'w'), stderr=subprocess.STDOUT, creationflags=DETACHED)
    st['host'] = h.pid; st['hostlog'] = log; st['hosttag'] = tag; save(st)
    time.sleep(2.5)
    print('host pid', h.pid, '->', log)
    print(open(log).read())


def ctl(tag, line):
    with open(ctlpath(tag), 'a') as f:
        f.write(line + '\n')
    print('ctl', tag, '<-', line)


def agent(tag, dll, envs):
    st = load()
    env = dict(os.environ)
    os.makedirs(DATA, exist_ok=True)
    env.setdefault('KCDMP_DATA_DIR', DATA)
    for kv in envs:
        k, v = kv.split('=', 1)
        env[k] = v
    log = os.path.join(live.LOGS, 'join125.agent.%s.log' % tag)
    a = subprocess.Popen(launch(os.path.abspath(dll)) + ['--host', '127.0.0.1', '--port', '7778', '--name', 'wo125-joiner', '--no-voice', '--no-discord'],
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
    for l in live.tail(live.KLOG, n, r'MP-JOIN|WO12[45]|MP-SAVELOCK'):
        print('kcd  ', l[:300])
    st = load()
    if 'hostlog' in st:
        for l in live.tail(st['hostlog'], n, r'SYNTH125'):
            print('host ', l[:300])
    if 'agentlog' in st:
        for l in live.tail(st['agentlog'], n, r'MP-JOIN|MP-SAVELOCK|MP-HENRY'):
            print('agent', l[:400])


def choose(c, port=int(os.environ.get('KCDMP_VERSION_IPC_PORT', '0') or 0)):
    if not port:
        # the agent's version/join-status listener: ClientConfig's default
        port = 5902
    r = urllib.request.urlopen(urllib.request.Request('http://localhost:%d/join-choice?c=%s' % (port, c), method='POST'), timeout=5)
    print(r.status, r.read().decode())


if __name__ == '__main__':
    v = sys.argv[1]
    if v == 'relay': relay(sys.argv[2])
    elif v == 'host': host(sys.argv[2], sys.argv[3], sys.argv[4:])
    elif v == 'ctl': ctl(sys.argv[2], ' '.join(sys.argv[3:]))
    elif v == 'agent': agent(sys.argv[2], sys.argv[3], sys.argv[4:])
    elif v == 'stop': stop(sys.argv[2])
    elif v == 'lines': lines(int(sys.argv[2]) if len(sys.argv) > 2 else 40)
    elif v == 'choose': choose(sys.argv[2])
