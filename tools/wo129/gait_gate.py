"""WO-129 live gait gate (tools only, never shipped).

Proves the engine really animates a native-written avatar: while the avatar
peer walks/runs/sprints, the body's own Mannequin tags must carry a pace tag
(walk/run/sprint) and a direction tag. On the 0.29.9 DLL (2b3561e) every
sample reads `pace=- dir=-` (the slide: RED, 0/9 0/9 0/8); with the WO-129
tag-update hook they read `pace=walk dir=forward` etc. (GREEN, 9/9 8/8 9/9).
The WO-121 commit (dd7ab9b) slides the same on screen.

Setup (docs/WO-129-progress.md s4): the Modding Tools game in a world with
KCDMP.dll injected, a local relay, the agent, and tools/wo121/avatarpeer with
--control <file>. The avatar must stand on the ground (flat line, stream z =
terrain), or it flies and plays no locomotion at all.

usage: python gait_gate.py <peer control file> <x> <y> <z> <heading>
       (KCD2MP_INSTALL = the Modding Tools folder)
Exit 0 = GATE GREEN: at each speed at least 3 samples after the start, and at least
3 in 4 of them carry the wanted pace tag and a direction tag.
"""
import os, re, sys, time

ROOT = os.environ.get('KCD2MP_INSTALL', '')
NLOG = os.path.join(ROOT, 'kcdmp-native.mirror.log')
MANN = os.path.join(ROOT, 'kcdmp-mannequin.txt')


def tail(n=4000):
    with open(NLOG, 'rb') as f:
        f.seek(0, 2); size = f.tell(); f.seek(max(0, size - 2_000_000))
        return f.read().decode('utf-8', 'replace').splitlines()[-n:]


def size():
    return os.path.getsize(NLOG)


def since(offset):
    """The log's lines written after byte `offset` (one window per speed)."""
    with open(NLOG, 'rb') as f:
        f.seek(offset)
        return f.read().decode('utf-8', 'replace').splitlines()


def paces_in(lines):
    """(pace/dir, pseudoSpeed) per MANN sample. Older DLLs collapse identical
    lines into "(previous line repeated N times)", flushed only when the line
    changes: that counts as N more of the last sample."""
    out = []
    for l in lines:
        m = re.search(r'MANN: pace=(\S+) dir=(\S+) \S+ pseudoSpeed=([-0-9.]+)', l)
        if m:
            out.append((m.group(1) + '/' + m.group(2), float(m.group(3)))); continue
        r = re.search(r'MANN: \(previous line repeated (\d+) times\)', l)
        if r and out:
            out.extend([out[-1]] * int(r.group(1)))
    return out


def ctl(path, line):
    with open(path, 'a') as f:
        f.write(line + '\n')


def main():
    if len(sys.argv) < 6 or not os.path.isfile(NLOG):
        sys.exit(__doc__)
    control, x, y, z, h = sys.argv[1], *sys.argv[2:6]
    eids = [m.group(1) for l in tail() for m in [re.search(r'WO121-MOTION body=kcd2mp_\d+ eid=0x([0-9A-F]+) attach avatar=1', l)] if m]
    if not eids:
        sys.exit('no avatar attached yet (WO121-MOTION ... attach avatar=1): place the peer first')
    open(MANN, 'w').write('%d 300' % int(eids[-1], 16))
    results = {}
    try:
        for speed, want in (('1.4', 'walk'), ('3.05', 'run'), ('5.0', 'sprint')):
            ctl(control, 'stand %s %s %s %s' % (x, y, z, h)); time.sleep(3)
            mark = size()
            ctl(control, 'move %s %s 3' % (speed, h)); time.sleep(3.2)
            ctl(control, 'stand %s %s %s %s' % (x, y, z, h)); time.sleep(1.5)
            # the samples written while moving (pseudo-speed above 0), less the
            # first (the start from standing)
            paces = [p for p, ps in paces_in(since(mark)) if ps > 0][1:]
            ok = sum(1 for p in paces if p.startswith(want + '/') and not p.endswith('/-'))
            results[speed] = (want, ok, len(paces))
            print('speed %s m/s: want %s, %d/%d samples tagged (%s)' % (speed, want, ok, len(paces), ','.join(paces)))
    finally:
        try: os.remove(MANN)
        except OSError: pass
    gait = [l for l in tail(600) if 'WO121-GAIT' in l]
    applied = [int(m.group(1)) for l in gait for m in [re.search(r'tags_applied=(\d+)', l)] if m]
    print('tag hook applied: %s' % (applied[-1] if applied else 'NO tags_applied field (pre-WO-129 DLL)'))
    green = all(n >= 3 and ok * 4 >= n * 3 for _, ok, n in results.values()) and bool(applied) and applied[-1] > 0
    print('GATE GREEN' if green else 'GATE RED')
    sys.exit(0 if green else 1)


if __name__ == '__main__':
    main()
