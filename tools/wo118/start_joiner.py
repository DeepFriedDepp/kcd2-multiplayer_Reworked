"""Start the local relay (if 7778 is free) and connect the agent as the JOINER.

usage: python start_joiner.py <KcdMpClient.dll|.exe> [KcdMpServer.dll|.exe]
(a release payload is self-contained: pass its .exe files)
Relay rule 2 makes the LOWEST ready id the authority when two loopback clients
are connected, so a short-lived synthetic peer takes id 0 first and the agent
gets id 1; every later test peer reclaims id 0 and is the authority. Check the
agent log for `MP-AUTHORITY-OWNER self_id=1 authority=peer` (then `self` again
when the placeholder leaves -- the next test peer takes it back)."""
import os, socket, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import live

PEER = os.path.join(live.HERE, 'synthpeer', 'bin', 'Release', 'net8.0', 'SynthPeer.dll')
agent = os.path.abspath(sys.argv[1])
relay = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else None
DETACHED = 0x00000008 | 0x00000200   # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP


def launch(path):
    return [path] if path.lower().endswith('.exe') else [live.dotnet(), path]


def listening(port):
    s = socket.socket()
    s.settimeout(0.5)
    try:
        return s.connect_ex(('127.0.0.1', port)) == 0
    finally:
        s.close()


if not listening(7778):
    if not relay: sys.exit('nothing listens on 7778: pass KcdMpServer.dll as the second argument')
    subprocess.Popen(launch(relay) + ['--port', '7778'], cwd=os.path.dirname(relay),
                     stdout=open(os.path.join(live.LOGS, 'relay.log'), 'w'), stderr=subprocess.STDOUT, creationflags=DETACHED)
    for _ in range(40):
        if listening(7778): break
        time.sleep(0.25)
placeholder = subprocess.Popen([live.dotnet(), PEER, '--plan', os.path.join(live.HERE, 'plans', 'plan.walk.txt'), '--duration', '10'],
                               stdout=open(os.path.join(live.LOGS, 'peer.placeholder.log'), 'w'), stderr=subprocess.STDOUT)
time.sleep(2.5)
a = subprocess.Popen(launch(agent) + ['--host', '127.0.0.1', '--port', '7778', '--name', 'wo118-joiner', '--no-voice', '--no-discord'],
                     cwd=os.path.dirname(agent), stdout=open(os.path.join(live.LOGS, 'agent.log'), 'w'),
                     stderr=subprocess.STDOUT, creationflags=DETACHED)
print('agent pid %d (log: %s)' % (a.pid, os.path.join(live.LOGS, 'agent.log')))
