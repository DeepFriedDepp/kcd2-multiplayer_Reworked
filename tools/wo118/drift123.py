"""WO-123 live: what moves on the host while a join holds the world paused.

usage: python drift123.py snap <tag>          one sample: every actor within 80 m + the clock -> kcd.log [WO123-DRIFT] <tag>
       python drift123.py diff <tagA> <tagB>  per-entity movement between two samples (metres), grouped by class

A sample is one Lua batch (read-only): name, class, position of every entity
within 80 m of the player that has an actor or a soul, plus Calendar.GetWorldTime
and the ratio. Names are world entity names (no player identity).
"""
import math, os, re, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import live

SNAP = r'''local tag = "%s"
local pp = player:GetWorldPos()
local wt, r = Calendar.GetWorldTime(), Calendar.GetWorldTimeRatio()
System.LogAlways(string.format("[WO123-DRIFT] %%s clock %%s ratio=%%s pos=%%.2f,%%.2f,%%.2f", tag, tostring(wt), tostring(r), pp.x, pp.y, pp.z))
local buf, n = {}, 0
for _, e in ipairs(System.GetEntitiesInSphere(pp, 80) or {}) do
  if (e.actor or e.soul) and e ~= player then
    local p = e:GetWorldPos()
    buf[#buf + 1] = string.format("%%s|%%s|%%.2f,%%.2f,%%.2f", e:GetName(), tostring(e.class), p.x, p.y, p.z)
    n = n + 1
    if #buf == 8 then System.LogAlways("[WO123-DRIFT] " .. tag .. " e " .. table.concat(buf, " ")); buf = {} end
  end
end
if #buf > 0 then System.LogAlways("[WO123-DRIFT] " .. tag .. " e " .. table.concat(buf, " ")) end
System.LogAlways("[WO123-DRIFT] " .. tag .. " n=" .. n)'''


def snap(tag):
    live.lua(' '.join(l.strip() for l in (SNAP % tag).splitlines()))
    time.sleep(1.0)


def load(tag):
    ents, clock = {}, None
    for l in live.tail(live.KLOG, 4000, r'\[WO123-DRIFT\] %s ' % re.escape(tag)):
        m = re.search(r'\] %s clock (\S+) ratio=(\S+)' % re.escape(tag), l)
        if m: clock = (m.group(1), m.group(2)); ents = {}
        if (' %s e ' % tag) in l:
            for tok in l.split(' e ', 1)[1].split():
                name, cls, pos = tok.split('|')
                ents[name] = (cls, tuple(float(v) for v in pos.split(',')))
    return clock, ents


def diff(a, b):
    ca, ea = load(a)
    cb, eb = load(b)
    print('clock %s -> %s (ratio %s -> %s)' % (ca[0], cb[0], ca[1], cb[1]))
    common = sorted(set(ea) & set(eb))
    by = {}
    for n in common:
        d = math.dist(ea[n][1], eb[n][1])
        by.setdefault(ea[n][0], []).append((d, n))
    for cls, v in sorted(by.items()):
        moved = [x for x in v if x[0] > 0.10]
        print('%-22s n=%-3d moved>0.1m=%-3d max=%.2f m  %s' % (cls, len(v), len(moved), max(x[0] for x in v),
              ' '.join('%s:%.1f' % (n, d) for d, n in sorted(moved, reverse=True)[:6])))
    print('only in %s: %d  only in %s: %d' % (a, len(set(ea) - set(eb)), b, len(set(eb) - set(ea))))


if __name__ == '__main__':
    if sys.argv[1] == 'snap': snap(sys.argv[2])
    elif sys.argv[1] == 'diff': diff(sys.argv[2], sys.argv[3])
