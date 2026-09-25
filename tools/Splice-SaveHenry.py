#!/usr/bin/env python3
"""WO-115 -- splice the joiner's Henry into the host's world save (S3).

Writes a NEW .whs: the host's save with the joiner's `player_henry` soul
record and Henry's side blocks put in, re-deflated and re-signed. Inputs are
opened read-only and the output must not exist yet, so an input can never be
overwritten.

    python tools/Splice-SaveHenry.py splice <host.whs> <joiner.whs> <out.whs>
                                     --tables <Tables.pak> [--quest-items strip|host]
                                     [--bad-md5]
    python tools/Splice-SaveHenry.py check  <host.whs> <joiner.whs> <out.whs>
                                     --tables <Tables.pak> [--quest-items strip|host]

What comes from where (docs/WO-115-findings.md s2; WO-112 s1.3/s1.4;
docs/DECISIONS-coop-design.md):

  joiner  RPGModule soul record player_henry (0x115E): inventory incl. money,
          equipment, stats, skills, perks (codex), persistent buffs, states
    host    ... stat id 8 (storyProgress) XP inside it
    host    ... 0x12FF renown record inside it
    --      ... quest-class items: the joiner's are always removed (they belong
            to the joiner's world); --quest-items host also carries the host
            Henry's over (variant B); strip (variant A) adds none
  joiner  RPGModule 0x352E statistics, 0x352D map knowledge
  joiner  PlayerModule 0x7309/0000 tutorials, 0x7309/0001 map fog
  joiner  GUIModule 0x7301 journal UI
  joiner  EntityModule 01f9/7302/0002 (a list of Henry's item instances)
  merged  EntityModule 01f8/7302/000B key bindings: entries naming a host
          Henry item are dropped, entries naming a joiner Henry item are added
  host    everything else, including GameState (Dude's position), the
          companion list, XGenAI (Dude's brain), graves, quest state

The save description header is the host's, unchanged. The tool prints only
its non-identifying fields (Read-SaveAnatomy.description_summary).

--bad-md5 writes the same splice with one MD5 byte flipped, to test whether
the game enforces the footer. `check` re-derives every expectation from the
three files and exits non-zero on any mismatch; `splice` runs it on its own
output before returning.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import struct
import sys
import zipfile
import re
import zlib

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location('read_save_anatomy', os.path.join(_here, 'Read-SaveAnatomy.py'))
rsa = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rsa)

STAT_STORY = 8
CHUNK_RAW = 32768          # every game-written block inflates to 32 KB (last one shorter)
ZLIB_LEVEL = 5             # 0x78 0x5E header, as the game writes

# --------------------------------------------------------------------------
# node paths (tuples of (tag, off, len), outermost first)


def path_nodes(raw, *tags):
    out = []
    cur = None
    for t, o, l in rsa.top_level(raw):
        if t == tags[0]:
            cur = (t, o, l)
            break
    if cur is None:
        raise ValueError('no top-level %04x' % tags[0])
    out.append(cur)
    for tag in tags[1:]:
        cur = rsa.child(raw, cur, tag)
        if cur is None:
            raise ValueError('missing %s' % '/'.join('%04x' % t for t in tags[:len(out) + 1]))
        out.append(cur)
    return out


def henry_chain(raw):
    chain = path_nodes(raw, 0x01F4, 0x01F8, 0x7308, 0x3529, 0x1161)
    rec = rsa.find_soul(raw, rsa.HENRY_SOUL)
    if rec is None:
        raise ValueError('player_henry soul record not found')
    if rec[0] != 0x115E:
        raise ValueError('player_henry record is not a full 0x115E record')
    return chain + [rec]


def replace(buf, chain, new_payload):
    """Replace the payload of chain[-1] and fix every ancestor's u32 length.
    Returns a new bytes object."""
    t, o, l = chain[-1]
    delta = len(new_payload) - l
    out = bytearray(buf[:o] + struct.pack('<HI', t, len(new_payload)) + new_payload + buf[o + 6 + l:])
    for at, ao, al in chain[:-1]:
        if not (ao < o and o + 6 + l <= ao + 6 + al):
            raise ValueError('chain is not nested')
        struct.pack_into('<I', out, ao + 2, al + delta)
    return bytes(out)


def field_chain(rec_bytes, *tags):
    """Chain inside a standalone soul record (tag+len+32-byte prefix+TLV)."""
    t, l = struct.unpack_from('<HI', rec_bytes, 0)
    top = (t, 0, l)
    chain = [top]
    kids = rsa.children(rec_bytes, 6 + 32, 6 + l)
    cur = None
    for k in kids or []:
        if k[0] == tags[0]:
            cur = k
            break
    if cur is None:
        raise ValueError('soul field %04x missing' % tags[0])
    chain.append(cur)
    for tag in tags[1:]:
        cur = rsa.child(rec_bytes, cur, tag)
        if cur is None:
            raise ValueError('soul field path %s missing' % '/'.join('%04x' % x for x in tags))
        chain.append(cur)
    return chain


def node_bytes(raw, node):
    return raw[node[1]:node[1] + 6 + node[2]]

# --------------------------------------------------------------------------
# quest-item classes


def quest_classes(tables):
    out = {}
    rx = re.compile(rb'<(\w+)\s([^>]*IsQuestItem="true"[^>]*)>')
    with zipfile.ZipFile(tables) as z:
        for n in z.namelist():
            low = n.lower()
            if not low.endswith('.xml') or not low.startswith('libs/tables/item/'):
                continue
            for m in rx.finditer(z.read(n)):
                g = re.search(rb'\bId="([0-9a-fA-F-]{36})"', m.group(2))
                nm = re.search(rb'\bName="([^"]*)"', m.group(2))
                if g:
                    out[g.group(1).decode().lower()] = nm.group(1).decode('latin1') if nm else '?'
    if not out:
        raise ValueError('no IsQuestItem classes found in %s' % tables)
    return out


def inventory_items(rec_bytes):
    """[(node, instance guid str, class guid str)] of the 0x1301/0x0007 list."""
    ch = field_chain(rec_bytes, 0x1301, 0x0007)
    lst = ch[-1]
    items = []
    for node in rsa.children(rec_bytes, lst[1] + 6, lst[1] + 6 + lst[2]) or []:
        if node[0] == 0x0000:
            continue
        b = rec_bytes[node[1] + 6:node[1] + 6 + node[2]]
        items.append((node, rsa.guid_str(b[:16]), rsa.guid_str(b[20:36])))
    return ch, items


def equipped(rec_bytes):
    try:
        ch = field_chain(rec_bytes, 0x1301, 0x0006, 0x0001, 0x0000)
    except ValueError:
        return set()       # no equipped-instance list (seen on playline2 permanent014)
    b = rec_bytes[ch[-1][1] + 6:ch[-1][1] + 6 + ch[-1][2]]
    return {rsa.guid_str(b[i:i + 16]) for i in range(0, len(b) - 15, 16)}

# --------------------------------------------------------------------------
# the Henry record


def build_henry(host_raw, join_raw, qclasses, quest_mode, report):
    h_rec = henry_chain(host_raw)[-1]
    j_rec = henry_chain(join_raw)[-1]
    rec = node_bytes(join_raw, j_rec)
    hrec = node_bytes(host_raw, h_rec)
    if rec[6:38] != hrec[6:38]:
        raise ValueError('player_henry GUID prefix differs between the saves')

    # stat id 8 (storyProgress) from the host
    def stat_pairs(r):
        ch = field_chain(r, 0x12FB, 0x0927, 0x1385)
        n = ch[-1]
        return ch, bytearray(r[n[1] + 6:n[1] + 6 + n[2]])
    hch, hp = stat_pairs(hrec)
    jch, jp = stat_pairs(rec)
    hval = dict(rsa.pairs(bytes(hp))).get(STAT_STORY)
    if hval is None:
        raise ValueError('host Henry has no stat id %d' % STAT_STORY)
    done = False
    for i in range(0, len(jp) - 7, 8):
        k = struct.unpack_from('<I', jp, i)[0]
        if k == 0xFFFFFFFF:
            break
        if k == STAT_STORY:
            report['storyProgress'] = {'joiner': struct.unpack_from('<I', jp, i + 4)[0], 'host': hval}
            struct.pack_into('<I', jp, i + 4, hval)
            done = True
    if not done:
        raise ValueError('joiner Henry has no stat id %d slot' % STAT_STORY)
    rec = replace(rec, jch, bytes(jp))

    # 0x12FF renown record from the host
    hr = field_chain(hrec, 0x12FF)[-1]
    jr = field_chain(rec, 0x12FF)
    report['renown_record_bytes'] = {'joiner': jr[-1][2], 'host': hr[2]}
    rec = replace(rec, jr, hrec[hr[1] + 6:hr[1] + 6 + hr[2]])

    # quest-class items
    ch, items = inventory_items(rec)
    eq = equipped(rec)
    drop = [(n, inst, cls) for n, inst, cls in items if cls in qclasses]
    for n, inst, cls in drop:
        if inst in eq:
            raise ValueError('joiner quest item %s (%s) is equipped; refusing' % (inst, qclasses[cls]))
    lst = ch[-1]
    body = bytearray(rec[lst[1] + 6:lst[1] + 6 + lst[2]])
    for n, inst, cls in sorted(drop, key=lambda x: -x[0][1]):
        s = n[1] - (lst[1] + 6)
        del body[s:s + 6 + n[2]]
    report['quest_items_removed_from_joiner'] = [qclasses[c] for _, _, c in drop]
    added = []
    if quest_mode == 'host':
        _, hitems = inventory_items(hrec)
        for n, inst, cls in hitems:
            if cls in qclasses:
                body += hrec[n[1]:n[1] + 6 + n[2]]
                added.append(qclasses[cls])
    report['quest_items_added_from_host'] = added
    rec = replace(rec, ch, bytes(body))
    return rec


def merge_keys(host_raw, join_raw, host_items, join_items, report):
    """EntityModule 01f8/7302/000B: [8-byte header] then 0x05AD entries of
    [16 owner soul GUID][9 bytes][16 key item instance GUID]."""
    def entries(raw):
        n = path_nodes(raw, 0x01F4, 0x01F8, 0x7302, 0x000B)[-1]
        b = raw[n[1] + 6:n[1] + 6 + n[2]]
        kids = rsa.children(b, 8, len(b)) if len(b) > 8 else []
        if len(b) > 8 and kids is None:
            raise ValueError('EntityModule 000B does not parse')
        out = []
        for t, o, l in kids or []:
            if t != 0x05AD or l != 41:
                raise ValueError('unexpected 000B entry %04x/%d' % (t, l))
            out.append((b[o:o + 6 + l], rsa.guid_str(b[o + 6 + 25:o + 6 + 41])))
        return b[:8], out
    hh, he = entries(host_raw)
    _, je = entries(join_raw)
    keep = [e for e, key in he if key not in host_items]
    add = [e for e, key in je if key in join_items]
    report['key_bindings'] = {'host_kept': len(keep), 'host_dropped': len(he) - len(keep), 'joiner_added': len(add)}
    return hh + b''.join(keep) + b''.join(add)

# --------------------------------------------------------------------------
# container


def deflate(desc_bytes, raw, footer_tail):
    out = bytearray(struct.pack('<Ii', 0xFFFFFFFF, len(desc_bytes)) + desc_bytes)
    for i in range(0, len(raw), CHUNK_RAW):
        part = raw[i:i + CHUNK_RAW]
        z = zlib.compress(part, ZLIB_LEVEL)
        out += struct.pack('<ii', len(z), len(part)) + z
    footer = bytearray(b'0XBP' + bytes(16) + footer_tail)
    md5 = hashlib.md5(bytes(out) + bytes(footer)).digest()
    footer[4:20] = md5
    return bytes(out + footer)


def splice_stream(host_raw, join_raw, qclasses, quest_mode, report):
    raw = host_raw
    # 1) side blocks, highest offset first so earlier chains stay valid
    jobs = []
    for tags in ((0x01F4, 0x01F8, 0x7308, 0x352E), (0x01F4, 0x01F8, 0x7308, 0x352D),
                 (0x01F4, 0x01F8, 0x7309, 0x0000), (0x01F4, 0x01F8, 0x7309, 0x0001),
                 (0x01F4, 0x01F8, 0x7301), (0x01F4, 0x01F9, 0x7302, 0x0002)):
        jn = path_nodes(join_raw, *tags)[-1]
        jobs.append((tags, join_raw[jn[1] + 6:jn[1] + 6 + jn[2]]))
    h_items = {i for _, i, _ in inventory_items(node_bytes(host_raw, henry_chain(host_raw)[-1]))[1]}
    j_items = {i for _, i, _ in inventory_items(node_bytes(join_raw, henry_chain(join_raw)[-1]))[1]}
    jobs.append(((0x01F4, 0x01F8, 0x7302, 0x000B), merge_keys(host_raw, join_raw, h_items, j_items, report)))
    henry = build_henry(host_raw, join_raw, qclasses, quest_mode, report)
    jobs.append(('henry', henry[6:]))

    def where(r, tags):
        return henry_chain(r) if tags == 'henry' else path_nodes(r, *tags)
    for tags, payload in sorted(jobs, key=lambda j: -where(raw, j[0])[-1][1]):
        raw = replace(raw, where(raw, tags), payload)
    report['blocks'] = ['henry' if t == 'henry' else '/'.join('%04x' % x for x in t) for t, _ in jobs]
    return raw

# --------------------------------------------------------------------------
# check


def check(host_path, join_path, out_path, qclasses, quest_mode):
    """Re-derive every expectation from the three files. Returns a list of
    failures (empty = pass)."""
    fails = []
    hd, jd, od = (rsa.read_file(p) for p in (host_path, join_path, out_path))
    ok, _, _ = rsa.verify_footer(od)
    if not ok:
        fails.append('output MD5 footer does not verify')
    hdesc, h = rsa.inflate(hd)
    _, j = rsa.inflate(jd)
    odesc, o = rsa.inflate(od)
    if hdesc != odesc:
        fails.append('description header differs from the host')

    # every leaf equals the host except the spliced ones
    spliced = {'01f4/01f8/7308/352e', '01f4/01f8/7308/352d', '01f4/01f8/7309/0000', '01f4/01f8/7309/0001',
               '01f4/01f8/7301', '01f4/01f9/7302/0002', '01f4/01f8/7302/000b', '01f4/01f8/7308/3529/1161'}
    lh, lo = rsa.leaves(h), rsa.leaves(o)
    lj = rsa.leaves(j)

    def under(k):
        return any(k == s or k.startswith(s + '/') for s in spliced)
    for k in set(lh) | set(lo):
        if under(k):
            continue
        if k not in lh or k not in lo or rsa.digest(h, lh[k]) != rsa.digest(o, lo[k]):
            fails.append('host block changed: %s' % k)
    for s in sorted(spliced - {'01f4/01f8/7302/000b', '01f4/01f8/7308/3529/1161'}):
        ko = {k: v for k, v in lo.items() if k == s or k.startswith(s + '/')}
        kj = {k: v for k, v in lj.items() if k == s or k.startswith(s + '/')}
        if set(ko) != set(kj) or any(rsa.digest(o, ko[k]) != rsa.digest(j, kj[k]) for k in ko):
            fails.append('spliced block is not the joiner\'s: %s' % s)

    # key bindings: the host's header, host entries for non-Henry keys, the joiner's Henry keys
    h_items = {i for _, i, _ in inventory_items(node_bytes(h, henry_chain(h)[-1]))[1]}
    j_items = {i for _, i, _ in inventory_items(node_bytes(j, henry_chain(j)[-1]))[1]}
    k = path_nodes(o, 0x01F4, 0x01F8, 0x7302, 0x000B)[-1]
    if o[k[1] + 6:k[1] + 6 + k[2]] != merge_keys(h, j, h_items, j_items, {}):
        fails.append('EntityModule 000B key bindings are not the expected merge')

    # souls: all but Henry are the host's, byte for byte
    sh = {rsa.guid_str(h[r[1] + 6:r[1] + 22]): r for r in rsa.soul_list(h)}
    so = {rsa.guid_str(o[r[1] + 6:r[1] + 22]): r for r in rsa.soul_list(o)}
    if [rsa.guid_str(h[r[1] + 6:r[1] + 22]) for r in rsa.soul_list(h)] != \
       [rsa.guid_str(o[r[1] + 6:r[1] + 22]) for r in rsa.soul_list(o)]:
        fails.append('soul list order/membership differs from the host')
    for g, r in sh.items():
        if g != rsa.HENRY_SOUL and (g not in so or node_bytes(h, r) != node_bytes(o, so[g])):
            fails.append('soul changed: %s' % g)

    # Henry = the joiner's, field by field, with the host's story stat + renown
    lab = lambda b: rsa.guid_str(b)
    dh = rsa.decode_player_soul(h, rsa.find_soul(h, rsa.HENRY_SOUL), lab)
    dj = rsa.decode_player_soul(j, rsa.find_soul(j, rsa.HENRY_SOUL), lab)
    do = rsa.decode_player_soul(o, rsa.find_soul(o, rsa.HENRY_SOUL), lab)
    qc = set(qclasses)
    for key in dj:
        if key in ('record_bytes', 'fields', 'inventory', 'stat_xp'):
            continue
        if do.get(key) != dj.get(key):
            fails.append('Henry %s is not the joiner\'s' % key)
    exp_stats = dict(dj['stat_xp'])
    exp_stats['storyProgress'] = dh['stat_xp']['storyProgress']
    if do['stat_xp'] != exp_stats:
        fails.append('Henry stat_xp: %r != %r' % (do['stat_xp'], exp_stats))
    exp_inv = [i for i in dj['inventory'] if i['class'] not in qc]
    if quest_mode == 'host':
        exp_inv += [i for i in dh['inventory'] if i['class'] in qc]
    if do['inventory'] != exp_inv:
        fails.append('Henry inventory is not the expected list (%d vs %d items)' % (len(do['inventory']), len(exp_inv)))
    fo, fh = rsa.soul_fields(o, rsa.find_soul(o, rsa.HENRY_SOUL)), rsa.soul_fields(h, rsa.find_soul(h, rsa.HENRY_SOUL))
    if rsa.payload(o, fo[0x12FF][0]) != rsa.payload(h, fh[0x12FF][0]):
        fails.append('Henry 0x12FF renown is not the host\'s')
    return fails

# --------------------------------------------------------------------------


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    for name in ('splice', 'check'):
        p = sub.add_parser(name)
        p.add_argument('host')
        p.add_argument('joiner')
        p.add_argument('out')
        p.add_argument('--tables', required=True, help='Tables.pak of the install (quest-item classes)')
        p.add_argument('--quest-items', choices=('strip', 'host'), default='strip',
                       help='strip = variant A (no quest items on the spliced Henry); host = variant B (carry the host Henry\'s)')
        if name == 'splice':
            p.add_argument('--bad-md5', action='store_true', help='flip one MD5 byte (integrity-check test only)')
    a = ap.parse_args(argv)
    qclasses = quest_classes(a.tables)

    if a.cmd == 'check':
        fails = check(a.host, a.joiner, a.out, qclasses, a.quest_items)
        for f in fails:
            print('FAIL', f)
        print('check: %s' % ('PASS' if not fails else '%d failure(s)' % len(fails)))
        return 1 if fails else 0

    for p in (a.host, a.joiner):
        if os.path.abspath(p) == os.path.abspath(a.out):
            ap.error('output must not be an input')
    if os.path.exists(a.out):
        ap.error('output exists; refusing to overwrite: %s' % a.out)
    hd, jd = rsa.read_file(a.host), rsa.read_file(a.joiner)
    for nm, d in (('host', hd), ('joiner', jd)):
        if not rsa.verify_footer(d)[0]:
            ap.error('%s save does not verify; refusing' % nm)
    hdesc, hraw = rsa.inflate(hd)
    jdesc, jraw = rsa.inflate(jd)
    hs, js = rsa.description_summary(hdesc), rsa.description_summary(jdesc)
    if hs.get('BuildInfo') != js.get('BuildInfo'):
        ap.error('builds differ: %s vs %s' % (hs.get('BuildInfo'), js.get('BuildInfo')))
    report = {'host': hs, 'joiner': js, 'quest_items': a.quest_items}
    raw = splice_stream(hraw, jraw, qclasses, a.quest_items, report)
    desc_len = struct.unpack_from('<i', hd, 4)[0]
    data = deflate(hd[8:8 + desc_len], raw, hd[-44:])
    if a.bad_md5:
        data = data[:-60] + bytes([data[-60] ^ 0xFF]) + data[-59:]
        report['bad_md5'] = True
    with open(a.out, 'xb') as f:
        f.write(data)
    report['out_bytes'] = len(data)
    report['stream_bytes'] = {'host': len(hraw), 'out': len(raw)}
    print(json.dumps(report, indent=1))
    if a.bad_md5:
        ok = rsa.verify_footer(data)[0]
        print('bad-md5 copy written; footer verifies: %s (expected False)' % ok)
        return 0 if not ok else 1
    fails = check(a.host, a.joiner, a.out, qclasses, a.quest_items)
    for f in fails:
        print('FAIL', f)
    print('check: %s' % ('PASS' if not fails else '%d failure(s)' % len(fails)))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
