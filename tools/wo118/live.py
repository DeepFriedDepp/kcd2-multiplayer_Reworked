"""WO-118 live harness: console/Lua through the Modding Tools REST API, kcd.log and
native mirror log tails, and the game window's focus.

Environment:
  KCD2MP_INSTALL   the Modding Tools install folder (holds kcd.log, Mods\\, Bin\\) -- required
  KCD2MP_API       REST base URL (default http://localhost:1403)
  MINIMIZE=1       live.focus() minimizes the game instead (measures the background-limited case)

Usage (python live.py <verb> ...):
  up                      is the console API answering
  cmd  "<console cmd>"    ExecuteString (no '#')
  lua  "<lua>"            ExecuteString('#' + lua)
  luaf <file.lua>         define every top-level function of a file, one command each
  once "<lua>"            token-guarded write: logs BEGIN <tok> first, never re-sent
  klog [n] [grep]         last n kcd.log lines matching grep
  nlog [n] [grep]         last n native mirror log lines matching grep
"""
import urllib.request, urllib.parse, urllib.error, time, os, sys, re, uuid, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
API = os.environ.get('KCD2MP_API', 'http://localhost:1403')
ROOT = os.environ.get('KCD2MP_INSTALL', '')
if not ROOT or not os.path.isdir(ROOT):
    sys.exit('set KCD2MP_INSTALL to the Modding Tools install folder (the one holding kcd.log)')
KLOG = os.path.join(ROOT, 'kcd.log')
NLOG = os.path.join(ROOT, 'kcdmp-native.mirror.log')
TRACES = os.path.join(HERE, 'traces')
LOGS = os.path.join(HERE, 'logs')
os.makedirs(TRACES, exist_ok=True)
os.makedirs(LOGS, exist_ok=True)


def dotnet():
    if os.environ.get('DOTNET_ROOT'):
        return os.path.join(os.environ['DOTNET_ROOT'], 'dotnet.exe')
    return 'dotnet'


def _get(url, timeout=20, maxbytes=4_000_000):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.read(maxbytes).decode('utf-8', 'replace')


def cmd(c, timeout=20):
    # The console truncates past ~2,100 encoded characters (kcd2-console-command-ceiling).
    enc = urllib.parse.quote(c, safe='')
    if len(enc) > 1900:
        raise ValueError('command too long: %d encoded' % len(enc))
    # 503 = the REST server is busy with another request (the agent's batch
    # flushes under a heavy puppet load); the command never ran, so retry. Under a
    # sustained load outside commands can still be lost -- arm schedules in Lua
    # (Script.SetTimer) before the load starts, as scale_run.py does.
    for attempt in range(40):
        try:
            return _get(API + '/api/System/Console/ExecuteString?command=' + enc, timeout)
        except (ConnectionResetError, ConnectionAbortedError) as e:
            return '<reset after send: %s>' % e   # a GET can execute before the reset (kcd2-rest-get-invokes-methods)
        except urllib.error.HTTPError as e:
            if e.code != 503 or attempt == 39: raise
            time.sleep(0.05 + 0.05 * attempt)


def lua(code, timeout=20):
    return cmd('#' + code, timeout)


def up():
    try:
        _get(API + '/api/rpg/SoulList/SoulCount', 3)
        return True
    except Exception:
        return False


def tail(path, n=40, grep=None):
    try:
        with open(path, 'rb') as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 4_000_000))
            data = f.read().decode('utf-8', 'replace').splitlines()
    except OSError as e:
        return ['<%s>' % e]
    if grep:
        rx = re.compile(grep)
        data = [l for l in data if rx.search(l)]
    return data[-n:]


def once(code):
    """Token-guarded write: the BEGIN line is logged by the same statement, so a
    connection reset after execution is detected in kcd.log and never re-sent."""
    tok = 'WO118TOK-' + uuid.uuid4().hex[:10]
    try:
        lua('System.LogAlways("[WO118] BEGIN %s"); %s' % (tok, code))
    except Exception as e:
        time.sleep(1.5)
        if any(tok in l for l in tail(KLOG, 400)):
            return 'executed (reset after execution): %s' % e
        return 'NOT executed: %s' % e
    return 'ok %s' % tok


def luaf(path):
    """Define each top-level function of a Lua file with its own command (the
    console ceiling rules out sending a whole file)."""
    chunks, cur = [], []
    for l in open(path, encoding='utf-8').read().splitlines():
        if l.startswith('function ') and cur:
            chunks.append(cur); cur = []
        if l.strip().startswith('--'): continue
        cur.append(l.strip())
    if cur: chunks.append(cur)
    for c in chunks:
        lua(' '.join(x for x in c if x))


def focus():
    """KCD2 drops to ~26 fps (its background frame limiter) whenever its window is
    not in the foreground: bring it forward before any per-frame measurement.
    MINIMIZE=1 does the opposite, to measure the limited case."""
    state = 'min' if os.environ.get('MINIMIZE') else 'restore'
    subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', os.path.join(HERE, 'winstate.ps1'), state],
                   capture_output=True)


if __name__ == '__main__':
    v = sys.argv[1] if len(sys.argv) > 1 else 'up'
    a = sys.argv[2:]
    if v == 'up':
        print('up' if up() else 'down')
    elif v == 'cmd':
        print(cmd(a[0]))
    elif v == 'lua':
        print(lua(a[0]))
    elif v == 'luaf':
        luaf(a[0]); print('defined')
    elif v == 'once':
        print(once(a[0]))
    elif v in ('klog', 'nlog'):
        n = int(a[0]) if a else 40
        g = a[1] if len(a) > 1 else None
        for l in tail(KLOG if v == 'klog' else NLOG, n, g):
            print(l)
