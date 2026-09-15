#!/usr/bin/env python3
"""WO-97 Phase 0 -- per-entry hazard audit of KCD2MP_OBJECTIVE_FIXES.

WO-96's census classified a narrow Haste trigger as "clean" when its OnTrigger
drove only the objective's State node. That is a statement about DIRECT effect
only. The state transition itself pulses its On<State> consumers, and those
consumers cross module boundaries through Output ports. This tool walks that
transitive chain in the fired direction and reports every node that belongs to
a hazard class -- above all CutsceneHandler.EnqueueCutscene, which WO-90
established has no pre-fire warning and no start-time sync.

Reads the Modding Tools Scripts.pak only. Writes nothing.
Requires Python 3.8+ (verified on 3.14.7; the rest of tools/ is PowerShell).

    python tools/Audit-ObjectiveFixHazards.py [--pak <path to Scripts.pak>]
    python tools/Audit-ObjectiveFixHazards.py --all      # every edge, not just hazards

Graph model (observed, see docs/WO-97-findings.md s1.1):
  * a node's XML TAG is its class; <Edge From="Src.Port" To="InPort"/> lives on
    the DESTINATION node, so consumers of X.OnDone are found by searching the
    file for Edge From="X.OnDone".
  * a node whose tag matches a sibling file <thisfile-without-.xml>/<tag>.xml is
    a module instance; a pulse into its in-port continues inside that file as
    Edge From="<inport>".
  * an <Output> node forwards to the PARENT module file as
    Edge From="<thisfile-basename>.<To>".
"""
import argparse
import csv
import os
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

BS = chr(92)
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def find_pak():
    try:
        import winreg
    except ImportError:
        return None
    roots = []
    for hive, key in ((winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam"),
                      (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam")):
        try:
            with winreg.OpenKey(hive, key) as k:
                roots.append(winreg.QueryValueEx(k, "SteamPath")[0])
                break
        except OSError:
            continue
    if not roots:
        return None
    vdf = os.path.join(roots[0], "steamapps", "libraryfolders.vdf")
    if os.path.exists(vdf):
        with open(vdf, encoding="utf-8", errors="replace") as f:
            roots += [m.group(1).replace(BS * 2, BS) for m in re.finditer(r'"path"\s+"([^"]+)"', f.read())]
    for r in roots:
        p = os.path.join(r, "steamapps", "common", "KCD2Mod", "Data", "Scripts.pak")
        if os.path.exists(p):
            return p
    return None


HAZARDS = [
    ("CUTSCENE", lambda t, n, to: t.startswith("cin_") or "trackview" in t.lower()
        or "cutscene" in (t + n + to).lower() or "cutscena" in (t + n + to).lower() or to == "enqueue_cs"),
    ("TELEPORT", lambda t, n, to: any(w in (t + n).lower() for w in ("teleport", "playergoto"))),
    ("ITEM",     lambda t, n, to: any(w in (t + n).lower() for w in
                                      ("additem", "addquestitem", "giveitem", "addreward", "itemdescriptor"))),
    ("DIALOG",   lambda t, n, to: any(w in (t + n + to).lower() for w in ("dialog", "trialog", "bark"))),
    ("SAVE",     lambda t, n, to: t == "SaveGame"),
    ("CLOTHING", lambda t, n, to: "clothing" in (t + n).lower() or "contextpreset" in (t + n).lower()),
    ("MOVE",     lambda t, n, to: t in ("Move", "UnstanceOnSpot", "ForceMount")),
]


class Pak:
    def __init__(self, path):
        self.z = zipfile.ZipFile(path)
        self.names = {n.replace(BS, "/"): n for n in self.z.namelist()}
        self.cache = {}

    def tree(self, key):
        if key not in self.cache:
            try:
                raw = self.z.read(self.names[key]).decode("utf-8-sig", errors="replace")
                self.cache[key] = ET.fromstring(raw.encode("utf-8"))
            except Exception:
                self.cache[key] = None
        return self.cache[key]

    def full(self, suffix):
        suffix = suffix.replace(BS, "/")
        for k in self.names:
            if k.endswith(suffix):
                return k
        return None

    def edges_from(self, key, spec):
        root = self.tree(key)
        if root is None:
            return []
        return [(e.tag, e.get("Name"), c.get("To"))
                for e in root.iter() for c in e
                if c.tag == "Edge" and c.get("From", "") == spec]

    def child(self, key, tag):
        cand = key[:-4] + "/" + tag + ".xml"
        return cand if cand in self.names else None

    def parent(self, key):
        p = key.rsplit("/", 1)[0] + ".xml"
        return p if p in self.names else None


def hazards_of(tag, name, to):
    return [h for h, f in HAZARDS if f(tag, name or "", to or "")]


def walk(pak, key, state, direction, maxdepth=6):
    """Breadth-first over the fired direction. 'pulse' follows On<State>;
    'bool' follows the <State> latch, which enables gates rather than firing
    them -- the distinction is carried so a finding is never rounded up."""
    ports = ["OnDone", "Done"] if direction == "done" else ["OnActive", "Active"]
    seen, out = set(), []
    frontier = [(key, state + "." + p, "pulse" if p.startswith("On") else "bool", 0) for p in ports]
    while frontier:
        fkey, spec, kind, depth = frontier.pop(0)
        if depth > maxdepth or (fkey, spec) in seen:
            continue
        seen.add((fkey, spec))
        for tag, name, to in pak.edges_from(fkey, spec):
            out.append((depth, kind, fkey, tag, name, to, hazards_of(tag, name, to)))
            if tag == "Output":
                pk = pak.parent(fkey)
                if pk:
                    frontier.append((pk, fkey.rsplit("/", 1)[1][:-4] + "." + to, kind, depth + 1))
                continue
            ck = pak.child(fkey, tag)
            if ck:
                frontier.append((ck, to, kind, depth + 1))
                continue
            if tag == "State" and to and to.startswith("Set"):
                frontier.append((fkey, name + ".On" + to[3:], "pulse", depth + 1))
                frontier.append((fkey, name + "." + to[3:], "bool", depth + 1))
    return out


LUA_ENTRY = re.compile(r'\{\s*q\s*=\s*"([^"]+)",\s*o\s*=\s*"([^"]+)",\s*dir\s*=\s*"([^"]+)",\s*t\s*=\s*"([^"]+)"\s*\}')


def load_fixes():
    lua = os.path.join(REPO, "kdcmp", "Data", "Scripts", "Startup", "kdcmp.lua")
    with open(lua, encoding="utf-8", errors="replace") as f:
        src = f.read()
    b = src.index("-- @@WO96-OBJECTIVE-FIXES-BEGIN@@")
    e = src.index("-- @@WO96-OBJECTIVE-FIXES-END@@")
    return LUA_ENTRY.findall(src[b:e])


def load_csv():
    path = os.path.join(REPO, "docs", "WO-96-objective-triggers.csv")
    t2f, t2p = {}, {}
    with open(path, encoding="utf-8-sig", newline="") as f:
        for r in csv.DictReader(f):
            if r["trigger"]:
                t2f.setdefault(r["trigger"], r["file"])
                t2p.setdefault(r["trigger"], r["ports"])
    return t2f, t2p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pak", default="")
    ap.add_argument("--all", action="store_true", help="print every downstream edge, not just hazard-class ones")
    args = ap.parse_args()
    pak_path = args.pak or find_pak()
    if not pak_path or not os.path.exists(pak_path):
        sys.exit("Scripts.pak not found; pass --pak")
    pak = Pak(pak_path)
    t2f, t2p = load_csv()
    fixes = load_fixes()
    print("=== WO-97 objective-fix hazard audit ===")
    print("    pak   : %s" % pak_path)
    print("    fixes : %d entries in KCD2MP_OBJECTIVE_FIXES\n" % len(fixes))
    worst = 0
    for q, o, d, t in fixes:
        fsuf = t2f.get(t)
        key = pak.full(fsuf) if fsuf else None
        state = (t2p.get(t) or ".").split(".")[0]
        print("=" * 92)
        print("[%s] %s (%s)  %s   state=%s" % (q, o, d, t, state))
        if not key:
            print("  !! no CSV row / file for this trigger")
            continue
        res = walk(pak, key, state, d)
        rows = res if args.all else [r for r in res if r[6]]
        if not rows:
            print("  no hazard-class node in %d downstream edges (depth<=6)" % len(res))
        for depth, kind, fkey, tag, name, to, hz in rows:
            if "CUTSCENE" in hz and kind == "pulse":
                worst += 1
            print("  d%d %-5s %-36s <%s Name=%s> -> %s   %s"
                  % (depth, kind, fkey.rsplit("/", 1)[1][:36], tag, name, to, ",".join(hz)))
    print("\n%d cutscene-on-a-pulse-path findings. Any non-zero count means the shipped"
          "\ntable still contains an entry WO-97 s1 would have withdrawn." % worst)
    return 1 if worst else 0


if __name__ == "__main__":
    sys.exit(main())
