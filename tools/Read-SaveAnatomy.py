#!/usr/bin/env python3
"""WO-112 Phase 1 -- read-only anatomy of a KCD2 .whs save.

Maps every block of the engine state stream, says whether it holds WORLD
state, HENRY (the local player) or both (MIXED), decodes Henry's own record,
and diffs two saves block by block. Nothing here writes a save; files are
opened read-only.

    python tools/Read-SaveAnatomy.py map    <save.whs> [--depth N]
    python tools/Read-SaveAnatomy.py henry  <save.whs> [--tables <Tables.pak>]
    python tools/Read-SaveAnatomy.py diff   <a.whs> <b.whs> [--souls]
    python tools/Read-SaveAnatomy.py find   <save.whs> <hex bytes>
    python tools/Read-SaveAnatomy.py entity <save.whs> <entity name>
    python tools/Read-SaveAnatomy.py verify <save.whs>...

--tables labels GUIDs (items, perks, buffs) from the game's own Tables.pak;
without it GUIDs print bare. Requires Python 3.8+ (verified on 3.14.7).

Format (observed on this build, BuildInfo 1.5.5; docs/WO-112-split-save.md s1):
  file   = [u32 FFFFFFFF][i32 descLen][XML description]
           { [i32 clen][i32 rawLen][zlib] | [i32 -1][i32 rawLen][raw] }*
           [64-byte footer]                      (SaveGameReader.cs, WO-96)
  footer = [u32 'PBX0'][16-byte MD5][zeros]: MD5 over the whole file up to
           the footer plus the footer with those 16 bytes zeroed (CryEngine
           XMLCPB convention; matched on every save checked).
  stream = [u32 23] then TLV chunks [u16 tag][u32 len][payload], nested.
  0x1F5 header, 0x1F4 body, 0x1FA end. Inside the body:
    0x1FB  4 bytes          0x1F6 phase A (pre-level module state)
    0x1F7  CryAction CGameSerialize sections (named blobs)
    0x1F8  phase B          0x1F9 phase C (post-entity module state)
  Module chunks are tagged 0x7300 + n; each tag is an immediate in exactly
  one module DLL (scan of the Modding Tools binaries).
  Named blobs (0x20A7 string / 0x20A8 int / 0x20A9 binary) carry a NUL-
  terminated name. 0x20A9 "GameState" etc. use a hashed-key token stream:
  [type:u8][FNV-1 32-bit key hash][value], 0x00 begins a group, 0x01 ends it.
"""
import argparse
import collections
import hashlib
import json
import re
import struct
import sys
import uuid
import zipfile
import zlib

# --------------------------------------------------------------------------
# container

def read_file(path):
    with open(path, 'rb') as f:
        return f.read()


def inflate(data):
    """(description xml, stream bytes). Raises ValueError on a framing mismatch."""
    if len(data) < 72 or struct.unpack_from('<I', data, 0)[0] != 0xFFFFFFFF:
        raise ValueError('not a .whs save')
    desc_len = struct.unpack_from('<i', data, 4)[0]
    desc = data[8:8 + desc_len].decode('utf-8', 'replace')
    pos = 8 + desc_len
    out = bytearray()
    while pos + 8 <= len(data) - 64:
        clen, rlen = struct.unpack_from('<ii', data, pos)
        if clen == -1:
            out += data[pos + 8:pos + 8 + rlen]
            pos += 8 + rlen
        else:
            out += zlib.decompress(data[pos + 8:pos + 8 + clen])
            pos += 8 + clen
    if pos != len(data) - 64:
        raise ValueError('blocks do not end at the 64-byte footer')
    return desc, bytes(out)


def description_summary(desc):
    """Only the non-identifying header fields. The description also carries a
    DebugInfoHistory with the writing machine's user and build-computer names,
    which this tool never prints."""
    out = {}
    for k in ('SaveType', 'SaveId', 'LevelName', 'GameReleaseVersion', 'BuildInfo', 'GameMode'):
        m = re.search(r'\b%s="([^"]*)"' % k, desc)
        if m:
            out[k] = m.group(1)
    return out

# --------------------------------------------------------------------------
# TLV tree

def children(buf, start, end):
    """[(tag, off, len)] if [start,end) parses exactly as TLV children, else None."""
    out = []
    p = start
    while p < end:
        if p + 6 > end:
            return None
        tag, ln = struct.unpack_from('<HI', buf, p)
        if ln > end - p - 6:
            return None
        out.append((tag, p, ln))
        p += 6 + ln
    return out if (p == end and out) else None


def top_level(raw):
    out = []
    p = 4
    while p + 6 <= len(raw):
        tag, ln = struct.unpack_from('<HI', raw, p)
        if ln > len(raw) - p - 6:
            break
        out.append((tag, p, ln))
        p += 6 + ln
    return out


def child(raw, parent, tag):
    t, o, l = parent
    for c in children(raw, o + 6, o + 6 + l) or []:
        if c[0] == tag:
            return c
    return None


def path_get(raw, *tags):
    cur = None
    for t, o, l in top_level(raw):
        if t == tags[0]:
            cur = (t, o, l)
            break
    for tag in tags[1:]:
        if cur is None:
            return None
        cur = child(raw, cur, tag)
    return cur

# --------------------------------------------------------------------------
# labels

MODULES = {
    0x7300: 'TestModule', 0x7301: 'GUIModule', 0x7302: 'EntityModule', 0x7303: 'QuestModule',
    0x7304: 'ShopModule', 0x7305: 'EnvironmentModule', 0x7306: 'XGenAIModule', 0x7308: 'RPGModule',
    0x7309: 'PlayerModule', 0x730A: 'ConceptModule', 0x730B: 'CombatModule', 0x730C: 'WHGame',
}
SECTIONS = {
    0x01F5: 'save header', 0x01F4: 'body', 0x01FA: 'end marker', 0x01FB: 'body word (4 bytes)',
    0x01F6: 'phase A: pre-level module state', 0x01F7: 'CryAction CGameSerialize',
    0x01F8: 'phase B: module state', 0x01F9: 'phase C: post-entity module state',
    0x1F90: 'Framework game variables', 0x1F91: 'XBehavior per-NPC records',
}

# (path, class, what) -- the Phase 1 block map. Classes: WORLD, HENRY, MIXED,
# META (container bookkeeping), UNKNOWN. Evidence for each row is in
# docs/WO-112-split-save.md s1.
BLOCKS = [
    ('01f5/0012', 'META', 'binary save description (type, id, time, level, UI text, versions)'),
    ('01f5/0010', 'META', 'u32'),
    ('01f5/000e', 'META', 'used mods list'),
    ('01f4/01fb', 'META', '4-byte body word (differs per save; not decoded)'),
    ('01f4/01f6/7309', 'WORLD', 'PlayerModule: homestead build states (house_*/room_*/yard_*)'),
    ('01f4/01f6/7303', 'WORLD', 'QuestModule: one u32'),
    ('01f4/01f6/730a', 'WORLD', 'ConceptModule: event place + <Roots> ConceptState XML (all quest state)'),
    ('01f4/01f6/730c', 'META', 'WHGame: empty'),
    ('01f4/01f7/version', 'META', 'CryAction save version'),
    ('01f4/01f7/level', 'META', 'CryAction level name'),
    ('01f4/01f7/gameRules', 'META', 'CryAction game rules'),
    ('01f4/01f7/build', 'META', 'CryAction build'),
    ('01f4/01f7/Bit', 'META', 'CryAction bit'),
    ('01f4/01f7/checkPointName', 'META', 'CryAction checkpoint name'),
    ('01f4/01f7/saveTime', 'META', 'CryAction save time (UTC text)'),
    ('01f4/01f7/Timer', 'WORLD', 'CryAction timer'),
    ('01f4/01f7/TerrainState', 'WORLD', 'CryAction terrain state (grew 238 B -> 297 KB in one WO-111 session)'),
    ('01f4/01f7/GameTokens', 'WORLD', 'CryAction game tokens'),
    ('01f4/01f7/ViewSystem', 'META', 'CryAction view system'),
    ('01f4/01f7/FlowSystem', 'WORLD', 'CryAction flow system'),
    ('01f4/01f7/MatFX', 'META', 'CryAction material effects'),
    ('01f4/01f7/GameState', 'MIXED', 'CryAction entities: BasicEntityData (all ~12k entities incl. Dude: pos/rot/flags), NormalEntityData, Layers, ExtraEntityData (actor extensions incl. Dude: dirt, blood, fastTravelEnabled, view angles), timers, breakables'),
    ('01f4/01f8/7302', 'WORLD', 'EntityModule: stash contents (incl. graves, quest-added stash items) keyed by entity GUID; per-object params; 0x000A = quest-item manager state (live managed quest items, items held for the other level, per-class wear)'),
    ('01f4/01f8/7308/3529/1161', 'MIXED', 'RPGModule souls: ~6.4k soul records; ONE is Henry (player_henry) with states, stat/skill XP, perks incl. codex, persistent buffs incl. injuries, inventory incl. money, equipment; also player_bohuta; NPC records hold per-NPC opinion modifiers (0x12FF)'),
    ('01f4/01f8/7308/3529/1160', 'MIXED', 'RPGModule companion list: [master soul GUID][companion soul GUID] (player horse, dog; empty in early saves)'),
    ('01f4/01f8/7308/3530', 'UNKNOWN', 'RPGModule: 33 bytes, changes minute to minute'),
    ('01f4/01f8/7308/352b', 'UNKNOWN', 'RPGModule: 44 bytes'),
    ('01f4/01f8/7308/352c', 'WORLD', 'RPGModule: 1,059 faction nodes (FactionTree) with relation/reputation records'),
    ('01f4/01f8/7308/352d', 'HENRY', 'RPGModule: POI instances (1.2-1.7k), 74 location records, discovered POI types -- map knowledge (inconclusive: POI record flags not decoded)'),
    ('01f4/01f8/7308/352e', 'HENRY', 'RPGModule: 204 player statistics (kills, distances, items used, diet timers)'),
    ('01f4/01f8/7308/3531', 'UNKNOWN', 'RPGModule: small timer-like records'),
    ('01f4/01f8/7308/352f', 'META', 'RPGModule: empty'),
    ('01f4/01f8/7309', 'MIXED', 'PlayerModule: tutorials seen + per-level map fog (HENRY); random-event director (WORLD)'),
    ('01f4/01f8/7304', 'WORLD', 'ShopModule: per-shop records only where a shop differs from default (items sold in, stock counters); stock itself lives in shop chests'),
    ('01f4/01f8/7301', 'HENRY', 'GUIModule: tracked quest, journal UI, custom map marker, map filter toggles'),
    ('01f4/01f8/7306', 'META', 'XGenAIModule: empty in phase B'),
    ('01f4/01f9/1f90', 'WORLD', 'Framework game variables (_SaveGameVersion, shop/haggle UI values)'),
    ('01f4/01f9/1f91', 'WORLD', 'XBehavior per-NPC records (name + id, then hash/value pairs)'),
    ('01f4/01f9/7300', 'META', 'TestModule: "test"'),
    ('01f4/01f9/7305', 'WORLD', 'EnvironmentModule: weather zones + current preset'),
    ('01f4/01f9/7302', 'HENRY', 'EntityModule: list of the player\'s item instance GUIDs (8 in the sample; meaning not decoded)'),
    ('01f4/01f9/730b', 'META', 'CombatModule: empty'),
    ('01f4/01f9/7306', 'MIXED', 'XGenAIModule: global AI state (smart objects, script contexts, shop/crime state) + ~600 per-entity brain records incl. Dude (faction player, dialog mailbox)'),
    ('01fa', 'META', 'end'),
]


def classify(path):
    best = None
    for pat, cls, what in BLOCKS:
        if path == pat or path.startswith(pat + '/'):
            if best is None or len(pat) > len(best[0]):
                best = (pat, cls, what)
    return best


class Labels:
    """GUID -> 'table:name' from a Tables.pak (optional)."""

    def __init__(self, pak=None):
        self.map = {}
        if not pak:
            return
        rx = re.compile(rb'<(\w+)\s([^>]*)>')
        gx = re.compile(rb'(\w*[Ii]d)="([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"')
        nx = re.compile(rb'\b(\w*_?[Nn]ame)="([^"]*)"')
        with zipfile.ZipFile(pak) as z:
            for n in z.namelist():
                low = n.lower()
                if not low.endswith('.xml') or not (low.startswith('libs/tables/rpg/') or low.startswith('libs/tables/item/')):
                    continue
                table = n.split('/')[-1][:-4]
                for m in rx.finditer(z.read(n)):
                    attrs = m.group(2)
                    nm = nx.search(attrs)
                    for _, g in gx.findall(attrs):
                        key = g.decode().lower()
                        if key not in self.map:
                            self.map[key] = '%s:%s' % (table, nm.group(2).decode('latin1') if nm else m.group(1).decode())

    def __call__(self, guid16):
        s = guid_str(guid16)
        return s + ('  ' + self.map[s] if s in self.map else '')


def guid_str(b):
    return str(uuid.UUID(bytes_le=bytes(b)))

# --------------------------------------------------------------------------
# hashed-key token stream (GameState and friends)


def fnv1(s):
    h = 0x811C9DC5
    for c in s.encode() if isinstance(s, str) else s:
        h = (h * 0x01000193) & 0xFFFFFFFF
        h ^= c
    return h


# Key names confirmed by their FNV-1 hash in real saves (identifiers only).
KNOWN_KEYS = [
    'BasicEntityData', 'BasicEntity', 'id', 'beguid', 'flags', 'flags2', 'flagsEx', 'aiObjectID', 'pos', 'rot',
    'name', 'class', 'archetype', 'parent', 'bepguid', 'EntityPoolManager_Bookmarks', 'NormalEntityData',
    'EntityProperties', 'Entity', 'guid', 'EntityTemplate', 'StateFlags', 'BreakableObjects', 'Timers', 'Timer',
    'Paused', 'ScriptTimers', 'Layers', 'LayerDesc', 'ExtraEntityData', 'IGame', 'EntityProxies', 'bHasSubst',
    'GameObject', 'updateState', 'numExtensions', 'Extension', 'CActor', 'm_SerShouldRagdollize', 'ActorDirt',
    'ArmorRuntimeData', 'dirt', 'bloodZone', 'i', 'v', 'Human', 'fastTravelEnabled', 'PlayerRotation',
    'viewAngles', 'viewQuat', 'viewQuatFinal', 'baseQuat', 'ScriptProxy', 'scriptUpdateRate', 'currStateId',
]
TOKEN_SIZES = {0x03: 1, 0x04: 4, 0x06: 12, 0x07: 16, 0x08: 12, 0x0B: 4, 0x0C: 8, 0x0D: 1, 0x0F: 4, 0x10: 8, 0x12: 8}
KEYNAMES = {fnv1(k): k for k in KNOWN_KEYS}


class TokenError(Exception):
    pass


def parse_any(buf, p):
    t = buf[p]
    if t == 0x01:
        return None, p + 1
    if t == 0x02:
        return bool(buf[p + 1]), p + 2
    if t == 0x03:
        return ('handle', struct.unpack_from('<Q', buf, p + 1)[0]), p + 9
    if t == 0x04:
        return struct.unpack_from('<f', buf, p + 1)[0], p + 5
    if t == 0x05:
        ln = struct.unpack_from('<H', buf, p + 1)[0]
        return buf[p + 3:p + 3 + ln].decode('latin1'), p + 3 + ln
    if t == 0x06:
        if buf[p + 1] != 0x05:
            raise TokenError('table header 0x%02x at 0x%x' % (buf[p + 1], p))
        cnt = struct.unpack_from('<I', buf, p + 2)[0]
        p += 6
        out = []
        for _ in range(cnt):
            k, p = parse_any(buf, p)
            v, p = parse_any(buf, p)
            out.append((k, v))
        return out, p
    if t == 0x09:
        return struct.unpack_from('<3f', buf, p + 1), p + 13
    raise TokenError('script value type 0x%02x at 0x%x' % (t, p))


def tokens(buf, start, end):
    """Yield (depth, type, keyhash, value bytes|object, offset)."""
    p = start
    depth = 0
    while p < end:
        t = buf[p]
        if t == 0x00:
            yield depth, t, struct.unpack_from('<I', buf, p + 1)[0], None, p
            depth += 1
            p += 5
        elif t == 0x01:
            depth -= 1
            yield depth, t, None, None, p
            p += 1
        elif t == 0x02:
            h, ln = struct.unpack_from('<IH', buf, p + 1)
            yield depth, t, h, buf[p + 7:p + 7 + ln], p
            p += 7 + ln
        elif t == 0x11:
            h = struct.unpack_from('<I', buf, p + 1)[0]
            v, np_ = parse_any(buf, p + 5)
            yield depth, t, h, v, p
            p = np_
        elif t in TOKEN_SIZES:
            h = struct.unpack_from('<I', buf, p + 1)[0]
            yield depth, t, h, buf[p + 5:p + 5 + TOKEN_SIZES[t]], p
            p += 5 + TOKEN_SIZES[t]
        else:
            raise TokenError('token type 0x%02x at 0x%x' % (t, p))


def keyname(h):
    return KEYNAMES.get(h, '#%08x' % h) if h is not None else ''


def fmt_token(t, v):
    if v is None:
        return ''
    if t == 0x02:
        return repr(v.decode('utf-8', 'replace'))
    if t == 0x03:
        return str(bool(v[0]))
    if t == 0x04:
        return '%g' % struct.unpack('<f', v)[0]
    if t == 0x06:
        return '(%.3f, %.3f, %.3f)' % struct.unpack('<3f', v)
    if t == 0x07:
        return 'quat(%.3f, %.3f, %.3f, %.3f)' % struct.unpack('<4f', v)
    if t == 0x08:
        return 'ang(%.3f, %.3f, %.3f)' % struct.unpack('<3f', v)
    if t == 0x0B:
        return str(struct.unpack('<i', v)[0])
    if t == 0x0D:
        return str(v[0])
    if t == 0x0F:
        return '0x%x' % struct.unpack('<I', v)[0]
    if t in (0x0C, 0x10, 0x12):
        return '0x%016x' % struct.unpack('<Q', v)[0]
    if t == 0x11:
        return 'table ' + json.dumps(v, default=str)[:160]
    return v.hex()


def named_blobs(raw):
    """name -> (payload start after the name, payload end) for 0x1F7's children."""
    s7 = path_get(raw, 0x01F4, 0x01F7)
    out = {}
    if not s7:
        return out
    for t, o, l in children(raw, s7[1] + 6, s7[1] + 6 + s7[2]) or []:
        nm = raw[o + 6:o + 6 + l].split(b'\0', 1)[0].decode('latin1')
        out[nm] = (t, o + 6 + len(nm) + 1, o + 6 + l)
    return out


def gamestate_groups(raw, group='BasicEntity'):
    """[(name-or-guid, [tokens])] for every <group> element of GameState."""
    blobs = named_blobs(raw)
    if 'GameState' not in blobs:
        return []
    _, s, e = blobs['GameState']
    out = []
    cur = None
    gdepth = None
    for tok in tokens(raw, s, e):
        depth, t, h, v, off = tok
        if cur is None and t == 0x00 and keyname(h) == group:
            cur = [tok]
            gdepth = depth
            continue
        if cur is not None:
            cur.append(tok)
            if t == 0x01 and depth == gdepth:
                label = guid = None
                for d2, t2, h2, v2, _ in cur:
                    if label is None and t2 == 0x02 and keyname(h2) == 'name' and d2 == gdepth + 1:
                        label = v2.decode('latin1')
                    if guid is None and t2 == 0x10 and keyname(h2) in ('guid', 'beguid') and d2 == gdepth + 1:
                        guid = struct.unpack('<Q', v2)[0]
                out.append((label, guid, cur))
                cur = None
    return out

# --------------------------------------------------------------------------
# RPGModule souls

HENRY_SOUL = '4c2dcffb-dea1-6263-72d7-b39f4db2d8b5'   # soul__player.xml player_henry
BOHUTA_SOUL = '4666cffb-dea1-6263-72d7-b39f4db2d666'  # soul__player.xml player_bohuta
HENRY_ENTITY_ID = 0x7777
STATS = {0: 'strength', 1: 'agility', 2: 'vitality', 3: 'speech', 8: 'storyProgress', 9: 'prestige'}
SKILLS = {0: 'stealth', 1: 'horse_riding', 2: 'fencing', 3: 'bard', 4: 'thievery', 6: 'alchemy', 7: 'cooking',
          8: 'craftsmanship', 10: 'fishing', 11: 'mining', 12: 'first_aid', 13: 'drinking', 14: 'survival',
          15: 'defense', 16: 'weapon_sword', 17: 'heavy_weapons', 19: 'marksmanship', 20: 'weapon_shield',
          22: 'weapon_dagger', 23: 'weapon_large', 24: 'weapon_unarmed', 26: 'scholarship', 27: 'tailoring',
          28: 'armourer', 29: 'weaponsmithing', 30: 'shoemaking', 31: 'gunsmithing', 32: 'bowyery',
          33: 'gambling', 34: 'houndmaster'}


def soul_list(raw):
    lst = path_get(raw, 0x01F4, 0x01F8, 0x7308, 0x3529, 0x1161)
    if not lst:
        return []
    return children(raw, lst[1] + 6, lst[1] + 6 + lst[2]) or []


def soul_fields(raw, rec):
    """Full soul record (0x115E): [16 soul guid][16 shared guid] then TLV fields."""
    t, o, l = rec
    if t != 0x115E:
        return {}
    out = collections.OrderedDict()
    for tt, oo, ll in children(raw, o + 6 + 32, o + 6 + l) or []:
        out.setdefault(tt, []).append((tt, oo, ll))
    return out


def soul_name(raw, rec):
    f = soul_fields(raw, rec)
    if 0x12F9 not in f:
        return ''
    _, o, l = f[0x12F9][0]
    return raw[o + 6:o + 6 + l].split(b'\0', 1)[0].decode('latin1')


def find_soul(raw, guid):
    for rec in soul_list(raw):
        if guid_str(raw[rec[1] + 6:rec[1] + 22]) == guid:
            return rec
    return None


def kids_of(raw, node):
    t, o, l = node
    out = collections.OrderedDict()
    for c in children(raw, o + 6, o + 6 + l) or []:
        out.setdefault(c[0], []).append(c)
    return out


def payload(raw, node):
    return raw[node[1] + 6:node[1] + 6 + node[2]]


def pairs(b):
    out = []
    for i in range(0, len(b), 8):
        k = struct.unpack_from('<I', b, i)[0]
        if k == 0xFFFFFFFF or i + 8 > len(b):
            break
        out.append((k, struct.unpack_from('<I', b, i + 4)[0]))
    return out


def decode_player_soul(raw, rec, lab):
    """Henry's soul, field by field. Offsets and meanings: WO-112 s1.3."""
    res = collections.OrderedDict()
    f = soul_fields(raw, rec)
    res['record_bytes'] = rec[2]
    res['fields'] = ['0x%04X (%d B)' % (k, v[0][2]) for k, v in f.items()]
    if 0x12F9 in f:
        b = payload(raw, f[0x12F9][0])
        nm = b.split(b'\0', 1)[0]
        res['name'] = nm.decode('latin1')
        res['entity_guid'] = '0x%016x' % struct.unpack_from('<Q', b, len(nm) + 1)[0]
    main = kids_of(raw, f[0x12FB][0]) if 0x12FB in f else {}
    core = kids_of(raw, main[0x0927][0]) if 0x0927 in main else {}
    if 0x138B in core:
        b = payload(raw, core[0x138B][0])
        res['states_f32 (health, stamina, exhaust, hunger, karma, alcoholism)'] = [round(x, 3) for x in struct.unpack('<%df' % (len(b) // 4), b)]
    if 0x1385 in core:
        res['stat_xp'] = {STATS.get(k, 'stat%d' % k): v for k, v in pairs(payload(raw, core[0x1385][0]))}
    if 0x138D in core:
        res['skill_xp'] = {SKILLS.get(k, 'skill%d' % k): v for k, v in pairs(payload(raw, core[0x138D][0]))}
    if 0x137E in core:
        perks = []
        extra = []
        for node in children(raw, core[0x137E][0][1] + 6, core[0x137E][0][1] + 6 + core[0x137E][0][2]) or []:
            if node[0] != 0x03D8:
                extra.append('0x%04X (%d B)' % (node[0], node[2]))
                continue
            sub = kids_of(raw, node)
            inner = kids_of(raw, sub[0x137E][0]) if 0x137E in sub else {}
            if 0x1379 in inner:
                perks.append(lab(payload(raw, inner[0x1379][0])[:16]))
        res['perks (incl. codex, recipes, locations)'] = perks
        res['perk_list_other'] = extra
    if 0x0926 in main:
        res['0x0926 f64 (meaning inconclusive)'] = {'0x%04X' % c[0]: round(struct.unpack('<d', payload(raw, c)[:8])[0], 4)
                                                     for c in children(raw, main[0x0926][0][1] + 6, main[0x0926][0][1] + 6 + main[0x0926][0][2]) or []}
    if 0x0928 in main:
        # persistent buff instances only; non-persistent buffs are never saved
        # (WO-111 observed; the list holds none of them). Record: [8 bytes, the
        # same for every buff of one soul][16-byte buff GUID][state]. Injury
        # buffs share their GUID with the body_part row (Warhorse data).
        b = payload(raw, main[0x0928][0])
        n = struct.unpack_from('<I', b, 0)[0]
        buffs = []
        p = 4
        for _ in range(n):
            t, ln = struct.unpack_from('<HI', b, p)
            body = b[p + 6:p + 6 + ln]
            buffs.append({'buff': lab(body[8:24]), 'record_bytes': ln})
            p += 6 + ln
        res['persistent_buffs'] = buffs
    if 0x1301 in f:
        inv = kids_of(raw, f[0x1301][0])
        items = []
        if 0x0007 in inv:
            for node in children(raw, inv[0x0007][0][1] + 6, inv[0x0007][0][1] + 6 + inv[0x0007][0][2]) or []:
                b = payload(raw, node)
                if node[0] == 0x0000:
                    res['inventory_header'] = guid_str(b[:16])
                    continue
                params = {}
                for pt, po, pl in children(b, 36, len(b)) or []:
                    v = b[po + 6:po + 6 + pl]
                    if pt == 0 and pl == 4:
                        # stored as amount - 1; absent means 1 (money 78 stored = 79 live, observed)
                        params['amount'] = struct.unpack('<I', v)[0] + 1
                    elif pt == 1 and pl == 4:
                        params['p1_f32'] = round(struct.unpack('<f', v)[0], 3)
                    else:
                        params['p%x' % pt] = v.hex()
                items.append({'instance': guid_str(b[:16]), 'flags': '0x%x' % struct.unpack_from('<I', b, 16)[0],
                              'class': lab(b[20:36]), 'params': params})
        res['inventory'] = items
        if 0x0006 in inv:
            eq = kids_of(raw, inv[0x0006][0])
            slots = []
            if 0x0001 in eq:
                e1 = kids_of(raw, eq[0x0001][0])
                if 0x0000 in e1:
                    b = payload(raw, e1[0x0000][0])
                    slots = [guid_str(b[i:i + 16]) for i in range(0, len(b) - 15, 16)]
            res['equipped_instances'] = slots
    return res

# --------------------------------------------------------------------------
# block walk and diff


def leaves(raw, maxdepth=14):
    """path -> [(off, len)]. Homogeneous lists of more than 50 same-tag children
    collapse to 'tag[*]'; the soul list is one leaf (use --souls for per-soul)."""
    res = collections.OrderedDict()
    blob_names = {}

    def rec(off, ln, path, depth):
        kids = children(raw, off + 6, off + 6 + ln) if (ln >= 6 and depth < maxdepth and not path.endswith('/1161')) else None
        if kids is None:
            res.setdefault(path, []).append((off, ln))
            return
        seen = collections.Counter(t for t, _, _ in kids)
        idx = collections.Counter()
        for t, o, l in kids:
            idx[t] += 1
            if path.endswith('01f4/01f7'):
                key = raw[o + 6:o + 6 + l].split(b'\0', 1)[0].decode('latin1')
            elif seen[t] > 50:
                key = '%04x[*]' % t
            elif seen[t] > 1:
                key = '%04x[%d]' % (t, idx[t])
            else:
                key = '%04x' % t
            rec(o, l, path + '/' + key, depth + 1)

    for t, o, l in top_level(raw):
        rec(o, l, '%04x' % t, 0)
    return res


def digest(raw, spans):
    h = hashlib.sha1()
    tot = 0
    for o, l in spans:
        h.update(raw[o + 6:o + 6 + l])
        tot += l
    return h.hexdigest(), tot


def label_path(path):
    parts = path.split('/')
    names = []
    for p in parts:
        m = re.match(r'([0-9a-f]{4})', p)
        if m and int(m.group(1), 16) in MODULES and len(p) == 4:
            names.append(MODULES[int(m.group(1), 16)])
    c = classify(re.sub(r'\[[^\]]*\]', '', path))
    return (' '.join(names), c[1] if c else '?', c[2] if c else '')

# --------------------------------------------------------------------------
# commands


def cmd_map(args):
    desc, raw = inflate(read_file(args.save))
    print('header', description_summary(desc))
    print('stream %d bytes, version word %d' % (len(raw), struct.unpack_from('<I', raw, 0)[0]))

    def show(off, ln, tag, path, depth):
        name = SECTIONS.get(tag) or MODULES.get(tag) or ''
        if path.startswith('01f4/01f7/') and depth == 2:
            name = raw[off + 6:off + 6 + ln].split(b'\0', 1)[0].decode('latin1')
            path = '01f4/01f7/' + name
        cls = classify(path)
        tagtxt = '%04x' % tag
        print('%s%-6s %-38s %9d B  %-7s %s' % ('  ' * depth, tagtxt, name[:38], ln,
                                               cls[1] if cls else '', (cls[2][:90] if cls and cls[0] == path else '')))
        if depth >= args.depth or path.endswith('/1161'):
            return
        kids = children(raw, off + 6, off + 6 + ln) if ln >= 6 else None
        if not kids or (path.startswith('01f4/01f7/') and depth >= 2):
            return
        c = collections.Counter(t for t, _, _ in kids)
        if len(kids) > 12 and len(c) <= 4 and path != '01f4/01f7':
            print('%s  (%d children: %s)' % ('  ' * depth, len(kids), ', '.join('%04x x%d' % kv for kv in c.most_common())))
            shown = set()
            for t, o, l in kids:
                if t not in shown:
                    shown.add(t)
                    show(o, l, t, path + '/%04x' % t, depth + 1)
            return
        for t, o, l in kids:
            show(o, l, t, path + '/%04x' % t, depth + 1)

    for t, o, l in top_level(raw):
        show(o, l, t, '%04x' % t, 0)
    souls = soul_list(raw)
    full = sum(1 for s in souls if s[0] == 0x115E)
    print('RPGModule souls: %d records (%d full 0x115E, %d short 0x115D)' % (len(souls), full, len(souls) - full))
    for g in (HENRY_SOUL, BOHUTA_SOUL):
        r = find_soul(raw, g)
        print('  player soul %s: %s' % (g, ('%d B at 0x%x (%s)' % (r[2], r[1], soul_name(raw, r))) if r else 'absent'))


def cmd_henry(args):
    desc, raw = inflate(read_file(args.save))
    lab = Labels(args.tables)
    print('header', description_summary(desc))
    rec = find_soul(raw, HENRY_SOUL)
    if not rec:
        print('player_henry soul not found')
        return 1
    print(json.dumps(decode_player_soul(raw, rec, lab), indent=1))
    print('\nGameState footprint of the player entity (id 0x%x):' % HENRY_ENTITY_ID)
    for grp in ('BasicEntity', 'Entity'):
        for label, guid, toks in gamestate_groups(raw, grp):
            if guid == HENRY_ENTITY_ID:
                print('  <%s> %d tokens' % (grp, len(toks)))
                for depth, t, h, v, _ in toks:
                    if t not in (0x00, 0x01):
                        print('    %s%s = %s' % ('  ' * (depth - toks[0][0]), keyname(h), fmt_token(t, v)))
    st = path_get(raw, 0x01F4, 0x01F8, 0x7308, 0x352E)
    if st:
        names = [payload(raw, c).split(b'\0', 1)[0].decode('latin1') for c in children(raw, st[1] + 6, st[1] + 6 + st[2]) or []]
        print('\nRPGModule 0x352E player statistics: %d counters, e.g. %s' % (len(names), ', '.join(names[:8])))
    return 0


def cmd_diff(args):
    da, a = inflate(read_file(args.a))
    db, b = inflate(read_file(args.b))
    la, lb = leaves(a), leaves(b)
    keys = list(la.keys()) + [k for k in lb if k not in la]
    agg = collections.OrderedDict()
    for k in keys:
        ha = digest(a, la[k]) if k in la else ('-', 0)
        hb = digest(b, lb[k]) if k in lb else ('-', 0)
        mods, cls, _ = label_path(k)
        group = re.sub(r'\[\d+\]', '[n]', k)
        g = agg.setdefault(group, [0, 0, 0, 0, cls, mods])
        g[0] += 1
        g[1] += (ha[0] != hb[0])
        g[2] += ha[1]
        g[3] += hb[1]
    print('%-5s %-52s %-8s %11s %11s  %s' % ('', 'block', 'class', 'a bytes', 'b bytes', 'module'))
    for k, (n, nd, sa, sb, cls, mods) in agg.items():
        mark = 'same' if nd == 0 else ('DIFF' if n == 1 else 'DIFF %d/%d' % (nd, n))
        print('%-5s %-52s %-8s %11d %11d  %s' % (mark[:9], k[:52], cls, sa, sb, mods))
    if args.souls:
        sa = {guid_str(a[r[1] + 6:r[1] + 22]): r for r in soul_list(a)}
        sb = {guid_str(b[r[1] + 6:r[1] + 22]): r for r in soul_list(b)}
        changed = [g for g in sa if g in sb and payload(a, sa[g]) != payload(b, sb[g])]
        fc = collections.Counter()
        for g in changed:
            fa, fb = soul_fields(a, sa[g]), soul_fields(b, sb[g])
            for fld in set(fa) | set(fb):
                pa = [payload(a, x) for x in fa.get(fld, [])]
                pb = [payload(b, x) for x in fb.get(fld, [])]
                if pa != pb:
                    fc['0x%04X' % fld] += 1
        print('\nsouls: a=%d b=%d only-a=%d only-b=%d changed=%d; changed fields: %s' % (
            len(sa), len(sb), len([g for g in sa if g not in sb]), len([g for g in sb if g not in sa]), len(changed),
            ', '.join('%s x%d' % kv for kv in fc.most_common())))
        for g in (HENRY_SOUL, BOHUTA_SOUL):
            if g in sa and g in sb:
                print('  %s (%s): %s' % (g, soul_name(a, sa[g]), 'changed' if g in changed else 'same'))


def cmd_find(args):
    desc, raw = inflate(read_file(args.save))
    pat = bytes.fromhex(args.hex.replace(' ', ''))
    tops = top_level(raw)

    def path_at(o):
        out = []

        def rec(tag, off, ln, depth):
            if not (off <= o < off + 6 + ln):
                return
            out.append('%04x' % tag)
            kids = children(raw, off + 6, off + 6 + ln) if ln >= 6 and depth < 14 else None
            for t, oo, ll in kids or []:
                rec(t, oo, ll, depth + 1)
        for t, off, ln in tops:
            rec(t, off, ln, 0)
        return '/'.join(out)
    n = 0
    for m in re.finditer(re.escape(pat), raw):
        p = path_at(m.start())
        print('0x%07x  %s  %s' % (m.start(), p, label_path(p)[0]))
        n += 1
    print('%d hit(s)' % n)


def verify_footer(data):
    """(ok, stored hex, computed hex). Read-only."""
    if len(data) < 72 or data[-64:-60] != b'0XBP':
        return False, '', ''
    stored = data[-60:-44]
    zeroed = data[-64:-60] + bytes(16) + data[-44:]
    computed = hashlib.md5(data[:-64] + zeroed).digest()
    return stored == computed, stored.hex(), computed.hex()


def cmd_verify(args):
    bad = 0
    for path in args.saves:
        data = read_file(path)
        ok, st, co = verify_footer(data)
        try:
            inflate(data)
            framing = 'framing ok'
        except Exception as e:
            framing = 'framing BAD (%s)' % e
            ok = False
        print('%-4s %s md5=%s %s' % ('OK' if ok else 'BAD', path, st, framing))
        bad += not ok
    return 1 if bad else 0


def cmd_entity(args):
    desc, raw = inflate(read_file(args.save))
    for grp in ('BasicEntity',):
        for label, guid, toks in gamestate_groups(raw, grp):
            if label == args.name:
                for depth, t, h, v, _ in toks:
                    print('%s%02x %s = %s' % ('  ' * (depth - toks[0][0]), t, keyname(h), fmt_token(t, v)))
                return 0
    print('no BasicEntity named %r' % args.name)
    return 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('map')
    p.add_argument('save')
    p.add_argument('--depth', type=int, default=4)
    p = sub.add_parser('henry')
    p.add_argument('save')
    p.add_argument('--tables', help='Tables.pak of the install, for GUID labels')
    p = sub.add_parser('diff')
    p.add_argument('a')
    p.add_argument('b')
    p.add_argument('--souls', action='store_true')
    p = sub.add_parser('find')
    p.add_argument('save')
    p.add_argument('hex')
    p = sub.add_parser('entity')
    p.add_argument('save')
    p.add_argument('name')
    p = sub.add_parser('verify')
    p.add_argument('saves', nargs='+')
    args = ap.parse_args(argv)
    return {'map': cmd_map, 'henry': cmd_henry, 'diff': cmd_diff, 'find': cmd_find, 'entity': cmd_entity,
            'verify': cmd_verify}[args.cmd](args) or 0


if __name__ == '__main__':
    sys.exit(main())
