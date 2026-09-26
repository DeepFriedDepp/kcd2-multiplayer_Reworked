using System.Buffers.Binary;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace KcdMp.Client;

/// <summary>
/// WO-122 Phase 5: the save tools, in the agent. A port of
/// <c>tools/Read-SaveAnatomy.py</c> (inflate, the TLV walk, the soul record,
/// the MD5 footer) and <c>tools/Splice-SaveHenry.py</c> (the S3 splice and its
/// check), with the same behaviour -- the Python tools stay the reference
/// (docs/WO-112-split-save.md s1, docs/WO-115-findings.md s2).
///
/// <code>
///   file   = [u32 FFFFFFFF][i32 descLen][XML description]
///            { [i32 clen][i32 rawLen][zlib] | [i32 -1][i32 rawLen][raw] }*
///            [64-byte footer]
///   footer = ['0XBP'][16-byte MD5][44 bytes]: MD5 over everything before the
///            footer plus the footer with the MD5 bytes zeroed
///   stream = [u32 23] then TLV chunks [u16 tag][u32 len][payload], nested
/// </code>
///
/// The game does NOT check the footer (WO-115 s5: a copy with one flipped MD5
/// byte loaded silently), so <see cref="Verify"/> is the only protection
/// against a bad transfer and must run at every step that moves a save.
///
/// One deliberate difference from the Python splicer: the zlib encoder. The
/// Python tool compresses with CPython's zlib (zlib-ng 2.2.4 on 3.14) at
/// level 5; .NET 8 ships a different zlib and no level-5 knob, so the blocks
/// here are deflated at <see cref="CompressionLevel.Optimal"/>. Every byte of
/// the INFLATED stream, the block framing (32 KB raw per block), the
/// description header and the footer tail are identical to the Python
/// output; only the compressed bytes differ (docs/WO-122-findings.md s5).
/// </summary>
public static partial class WhsSave
{
    public const string HenrySoul = "4c2dcffb-dea1-6263-72d7-b39f4db2d8b5";   // soul__player.xml player_henry
    public const int StatStory = 8;
    public const int ChunkRaw = 32768;   // every game-written block inflates to 32 KB (last one shorter)
    public const int FooterLen = 64;

    public readonly record struct Node(ushort Tag, int Off, int Len)
    {
        public int PayloadOff => Off + 6;
        public int End => Off + 6 + Len;
    }

    public sealed record Container(byte[] DescBytes, byte[] Raw, byte[] FooterTail)
    {
        public string Desc => Encoding.UTF8.GetString(DescBytes);
    }

    // ------------------------------------------------------------------ container

    /// <summary>(description, stream). Throws <see cref="InvalidDataException"/> on a framing mismatch.</summary>
    public static Container Inflate(byte[] data)
    {
        if (data.Length < 72 || BinaryPrimitives.ReadUInt32LittleEndian(data) != 0xFFFFFFFFu)
            throw new InvalidDataException("not a .whs save");
        int descLen = BinaryPrimitives.ReadInt32LittleEndian(data.AsSpan(4));
        if (descLen < 0 || 8L + descLen > data.Length - FooterLen) throw new InvalidDataException("description length out of range");
        var desc = data.AsSpan(8, descLen).ToArray();
        long pos = 8 + descLen;
        using var outMs = new MemoryStream();
        while (pos + 8 <= data.Length - FooterLen)
        {
            int clen = BinaryPrimitives.ReadInt32LittleEndian(data.AsSpan((int)pos));
            int rlen = BinaryPrimitives.ReadInt32LittleEndian(data.AsSpan((int)pos + 4));
            if (rlen < 0) throw new InvalidDataException("negative block length");
            if (clen == -1)
            {
                if (pos + 8 + rlen > data.Length - FooterLen) throw new InvalidDataException("raw block overruns the footer");
                outMs.Write(data, (int)pos + 8, rlen);
                pos += 8 + rlen;
            }
            else
            {
                if (clen < 0 || pos + 8 + clen > data.Length - FooterLen) throw new InvalidDataException("zlib block overruns the footer");
                using var zin = new ZLibStream(new MemoryStream(data, (int)pos + 8, clen, writable: false), CompressionMode.Decompress);
                long before = outMs.Length;
                zin.CopyTo(outMs);
                if (outMs.Length - before != rlen) throw new InvalidDataException("block inflates to a different length than its header says");
                pos += 8 + clen;
            }
        }
        if (pos != data.Length - FooterLen) throw new InvalidDataException("blocks do not end at the 64-byte footer");
        return new Container(desc, outMs.ToArray(), data.AsSpan(data.Length - 44).ToArray());
    }

    /// <summary>(ok, stored hex, computed hex). Read-only.</summary>
    public static (bool Ok, string Stored, string Computed) VerifyFooter(byte[] data)
    {
        if (data.Length < 72 || !data.AsSpan(data.Length - 64, 4).SequenceEqual("0XBP"u8)) return (false, "", "");
        var stored = data.AsSpan(data.Length - 60, 16).ToArray();
        var computed = FooterMd5(data.AsSpan(0, data.Length - 64), data.AsSpan(data.Length - 44));
        return (stored.AsSpan().SequenceEqual(computed), Convert.ToHexString(stored).ToLowerInvariant(), Convert.ToHexString(computed).ToLowerInvariant());
    }

    private static byte[] FooterMd5(ReadOnlySpan<byte> body, ReadOnlySpan<byte> tail)
    {
        using var md5 = IncrementalHash.CreateHash(HashAlgorithmName.MD5);
        md5.AppendData(body);
        md5.AppendData("0XBP"u8);
        md5.AppendData(new byte[16]);
        md5.AppendData(tail);
        return md5.GetHashAndReset();
    }

    public sealed record VerifyResult(bool Ok, string Reason, string Md5, int StreamBytes, bool HenryFound);

    /// <summary>
    /// The gate for every save the mod moves: the MD5 footer, the block
    /// framing (every block inflates to its stated length and they end at the
    /// footer), and the stream's own shape (the soul list parses and holds
    /// player_henry). The game checks none of this.
    /// </summary>
    public static VerifyResult Verify(byte[] data)
    {
        var (ok, stored, computed) = VerifyFooter(data);
        if (!ok) return new(false, stored == "" ? "no 0XBP footer" : $"md5 mismatch (stored {stored}, computed {computed})", stored, 0, false);
        Container c;
        try { c = Inflate(data); }
        catch (Exception ex) { return new(false, "framing: " + ex.Message, stored, 0, false); }
        bool henry;
        try { henry = FindSoul(c.Raw, HenrySoul) is Node r && r.Tag == 0x115E; }
        catch (Exception ex) { return new(false, "stream: " + ex.Message, stored, c.Raw.Length, false); }
        if (!henry) return new(false, "stream: no full player_henry soul record", stored, c.Raw.Length, false);
        return new(true, "ok", stored, c.Raw.Length, true);
    }

    public static VerifyResult VerifyFile(string path)
    {
        byte[] data;
        try { data = ReadShared(path); }
        catch (Exception ex) { return new(false, "unreadable: " + ex.Message, "", 0, false); }
        return Verify(data);
    }

    /// <summary>Read without blocking the game's own writer.</summary>
    public static byte[] ReadShared(string path)
    {
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        var buf = new byte[fs.Length];
        int got = 0;
        while (got < buf.Length) { int n = fs.Read(buf, got, buf.Length - got); if (n <= 0) break; got += n; }
        if (got != buf.Length) throw new IOException("short read");
        return buf;
    }

    /// <summary>Re-deflate a stream as the game frames it: 32 KB raw per zlib block, then the re-signed footer.</summary>
    public static byte[] Deflate(byte[] descBytes, byte[] raw, byte[] footerTail)
    {
        if (footerTail.Length != 44) throw new ArgumentException("the footer tail is 44 bytes", nameof(footerTail));
        using var ms = new MemoryStream();
        Span<byte> head = stackalloc byte[8];
        BinaryPrimitives.WriteUInt32LittleEndian(head, 0xFFFFFFFFu);
        BinaryPrimitives.WriteInt32LittleEndian(head[4..], descBytes.Length);
        ms.Write(head);
        ms.Write(descBytes);
        for (int i = 0; i < raw.Length; i += ChunkRaw)
        {
            int n = Math.Min(ChunkRaw, raw.Length - i);
            byte[] z;
            using (var zms = new MemoryStream())
            {
                using (var zs = new ZLibStream(zms, CompressionLevel.Optimal, leaveOpen: true)) zs.Write(raw, i, n);
                z = zms.ToArray();
            }
            BinaryPrimitives.WriteInt32LittleEndian(head, z.Length);
            BinaryPrimitives.WriteInt32LittleEndian(head[4..], n);
            ms.Write(head);
            ms.Write(z);
        }
        var body = ms.ToArray();
        var md5 = FooterMd5(body, footerTail);
        var outBytes = new byte[body.Length + FooterLen];
        body.CopyTo(outBytes, 0);
        "0XBP"u8.CopyTo(outBytes.AsSpan(body.Length));
        md5.CopyTo(outBytes, body.Length + 4);
        footerTail.CopyTo(outBytes, body.Length + 20);
        return outBytes;
    }

    /// <summary>Only the non-identifying header fields (the description also carries machine and account names).</summary>
    public static SortedDictionary<string, string> DescriptionSummary(string desc)
    {
        var o = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var k in new[] { "SaveType", "SaveId", "LevelName", "GameReleaseVersion", "BuildInfo", "GameMode" })
        {
            var m = Regex.Match(desc, $@"\b{k}=""([^""]*)""");
            if (m.Success) o[k] = m.Groups[1].Value;
        }
        return o;
    }

    // ------------------------------------------------------------------ TLV tree

    /// <summary>The TLV children of [start,end) if it parses EXACTLY as a non-empty list, else null.</summary>
    public static List<Node>? Children(byte[] buf, int start, int end)
    {
        var o = new List<Node>();
        int p = start;
        while (p < end)
        {
            if (p + 6 > end) return null;
            ushort tag = BinaryPrimitives.ReadUInt16LittleEndian(buf.AsSpan(p));
            uint ln = BinaryPrimitives.ReadUInt32LittleEndian(buf.AsSpan(p + 2));
            if (ln > (uint)(end - p - 6)) return null;
            o.Add(new Node(tag, p, (int)ln));
            p += 6 + (int)ln;
        }
        return p == end && o.Count > 0 ? o : null;
    }

    public static List<Node> TopLevel(byte[] raw)
    {
        var o = new List<Node>();
        int p = 4;
        while (p + 6 <= raw.Length)
        {
            ushort tag = BinaryPrimitives.ReadUInt16LittleEndian(raw.AsSpan(p));
            uint ln = BinaryPrimitives.ReadUInt32LittleEndian(raw.AsSpan(p + 2));
            if (ln > (uint)(raw.Length - p - 6)) break;
            o.Add(new Node(tag, p, (int)ln));
            p += 6 + (int)ln;
        }
        return o;
    }

    public static Node? Child(byte[] raw, Node parent, ushort tag)
    {
        foreach (var c in Children(raw, parent.PayloadOff, parent.End) ?? [])
            if (c.Tag == tag) return c;
        return null;
    }

    public static Node? PathGet(byte[] raw, params ushort[] tags)
    {
        Node? cur = null;
        foreach (var t in TopLevel(raw))
            if (t.Tag == tags[0]) { cur = t; break; }
        for (int i = 1; i < tags.Length; i++)
        {
            if (cur is not Node c) return null;
            cur = Child(raw, c, tags[i]);
        }
        return cur;
    }

    /// <summary>The node chain for a path, outermost first. Throws when a step is missing.</summary>
    public static List<Node> PathNodes(byte[] raw, params ushort[] tags)
    {
        var o = new List<Node>();
        Node? cur = null;
        foreach (var t in TopLevel(raw))
            if (t.Tag == tags[0]) { cur = t; break; }
        if (cur is not Node first) throw new InvalidDataException($"no top-level {tags[0]:x4}");
        o.Add(first);
        for (int i = 1; i < tags.Length; i++)
        {
            cur = Child(raw, o[^1], tags[i]);
            if (cur is not Node n) throw new InvalidDataException("missing " + string.Join("/", tags.Take(i + 1).Select(x => x.ToString("x4"))));
            o.Add(n);
        }
        return o;
    }

    public static byte[] Payload(byte[] raw, Node n) => raw.AsSpan(n.PayloadOff, n.Len).ToArray();
    public static byte[] NodeBytes(byte[] raw, Node n) => raw.AsSpan(n.Off, 6 + n.Len).ToArray();

    /// <summary>Replace the payload of chain[^1] and fix every ancestor's u32 length. Returns a new buffer.</summary>
    public static byte[] Replace(byte[] buf, IReadOnlyList<Node> chain, byte[] newPayload)
    {
        var last = chain[^1];
        int delta = newPayload.Length - last.Len;
        var o = new byte[buf.Length + delta];
        buf.AsSpan(0, last.Off).CopyTo(o);
        BinaryPrimitives.WriteUInt16LittleEndian(o.AsSpan(last.Off), last.Tag);
        BinaryPrimitives.WriteUInt32LittleEndian(o.AsSpan(last.Off + 2), (uint)newPayload.Length);
        newPayload.CopyTo(o, last.Off + 6);
        buf.AsSpan(last.End).CopyTo(o.AsSpan(last.Off + 6 + newPayload.Length));
        for (int i = 0; i < chain.Count - 1; i++)
        {
            var a = chain[i];
            if (!(a.Off < last.Off && last.End <= a.End)) throw new InvalidDataException("chain is not nested");
            BinaryPrimitives.WriteUInt32LittleEndian(o.AsSpan(a.Off + 2), (uint)(a.Len + delta));
        }
        return o;
    }

    /// <summary>bytes_le GUID text, as Python's uuid.UUID(bytes_le=...).</summary>
    public static string GuidStr(ReadOnlySpan<byte> b16) => new Guid(b16[..16]).ToString();

    // ------------------------------------------------------------------ souls

    public static List<Node> SoulList(byte[] raw)
    {
        var lst = PathGet(raw, 0x01F4, 0x01F8, 0x7308, 0x3529, 0x1161);
        if (lst is not Node l) return [];
        return Children(raw, l.PayloadOff, l.End) ?? [];
    }

    public static Node? FindSoul(byte[] raw, string guid)
    {
        foreach (var rec in SoulList(raw))
            if (GuidStr(raw.AsSpan(rec.Off + 6, 16)) == guid) return rec;
        return null;
    }

    /// <summary>Full soul record (0x115E): [16 soul guid][16 shared guid] then TLV fields, grouped by tag in order.</summary>
    public static Dictionary<ushort, List<Node>> SoulFields(byte[] raw, Node rec)
    {
        var o = new Dictionary<ushort, List<Node>>();
        if (rec.Tag != 0x115E) return o;
        foreach (var f in Children(raw, rec.Off + 6 + 32, rec.End) ?? [])
        {
            if (!o.TryGetValue(f.Tag, out var l)) o[f.Tag] = l = [];
            l.Add(f);
        }
        return o;
    }

    private static Dictionary<ushort, List<Node>> KidsOf(byte[] raw, Node n)
    {
        var o = new Dictionary<ushort, List<Node>>();
        foreach (var c in Children(raw, n.PayloadOff, n.End) ?? [])
        {
            if (!o.TryGetValue(c.Tag, out var l)) o[c.Tag] = l = [];
            l.Add(c);
        }
        return o;
    }

    public static List<(uint Key, uint Value)> Pairs(ReadOnlySpan<byte> b)
    {
        var o = new List<(uint, uint)>();
        for (int i = 0; i + 4 <= b.Length; i += 8)
        {
            uint k = BinaryPrimitives.ReadUInt32LittleEndian(b[i..]);
            if (k == 0xFFFFFFFFu || i + 8 > b.Length) break;
            o.Add((k, BinaryPrimitives.ReadUInt32LittleEndian(b[(i + 4)..])));
        }
        return o;
    }

    private static readonly Dictionary<uint, string> Stats = new() { [0] = "strength", [1] = "agility", [2] = "vitality", [3] = "speech", [8] = "storyProgress", [9] = "prestige" };
    private static readonly Dictionary<uint, string> Skills = new()
    {
        [0] = "stealth", [1] = "horse_riding", [2] = "fencing", [3] = "bard", [4] = "thievery", [6] = "alchemy", [7] = "cooking",
        [8] = "craftsmanship", [10] = "fishing", [11] = "mining", [12] = "first_aid", [13] = "drinking", [14] = "survival",
        [15] = "defense", [16] = "weapon_sword", [17] = "heavy_weapons", [19] = "marksmanship", [20] = "weapon_shield",
        [22] = "weapon_dagger", [23] = "weapon_large", [24] = "weapon_unarmed", [26] = "scholarship", [27] = "tailoring",
        [28] = "armourer", [29] = "weaponsmithing", [30] = "shoemaking", [31] = "gunsmithing", [32] = "bowyery",
        [33] = "gambling", [34] = "houndmaster",
    };

    public sealed record InvItem(string Instance, uint Flags, string Class, string Params);

    /// <summary>
    /// Henry's soul, field by field (Read-SaveAnatomy.decode_player_soul).
    /// <see cref="Scalars"/> holds every compared field as canonical text; the
    /// inventory and stat XP are kept structured because the splice check
    /// derives them rather than comparing them whole.
    /// </summary>
    public sealed class PlayerSoul
    {
        public int RecordBytes;
        public readonly SortedDictionary<string, string> Scalars = new(StringComparer.Ordinal);
        public readonly SortedDictionary<string, uint> StatXp = new(StringComparer.Ordinal);
        public readonly List<InvItem> Inventory = [];
    }

    public static PlayerSoul DecodePlayerSoul(byte[] raw, Node rec)
    {
        var res = new PlayerSoul { RecordBytes = rec.Len };
        var f = SoulFields(raw, rec);
        if (f.TryGetValue(0x12F9, out var nf))
        {
            var b = Payload(raw, nf[0]);
            int nul = Array.IndexOf(b, (byte)0);
            if (nul < 0) nul = b.Length;
            res.Scalars["name"] = Encoding.Latin1.GetString(b, 0, nul);
            res.Scalars["entity_guid"] = nul + 1 + 8 <= b.Length ? $"0x{BinaryPrimitives.ReadUInt64LittleEndian(b.AsSpan(nul + 1)):x16}" : "?";
        }
        var main = f.TryGetValue(0x12FB, out var mf) ? KidsOf(raw, mf[0]) : [];
        var core = main.TryGetValue(0x0927, out var cf) ? KidsOf(raw, cf[0]) : [];
        if (core.TryGetValue(0x138B, out var st)) res.Scalars["states_f32"] = Convert.ToHexString(Payload(raw, st[0]));
        if (core.TryGetValue(0x1385, out var sx))
            foreach (var (k, v) in Pairs(Payload(raw, sx[0]))) res.StatXp[Stats.TryGetValue(k, out var nm) ? nm : $"stat{k}"] = v;
        if (core.TryGetValue(0x138D, out var kx))
            res.Scalars["skill_xp"] = string.Join(",", Pairs(Payload(raw, kx[0])).Select(p => $"{(Skills.TryGetValue(p.Key, out var nm) ? nm : $"skill{p.Key}")}={p.Value}"));
        if (core.TryGetValue(0x137E, out var pk))
        {
            var perks = new List<string>();
            var extra = new List<string>();
            foreach (var node in Children(raw, pk[0].PayloadOff, pk[0].End) ?? [])
            {
                if (node.Tag != 0x03D8) { extra.Add($"0x{node.Tag:X4} ({node.Len} B)"); continue; }
                var sub = KidsOf(raw, node);
                var inner = sub.TryGetValue(0x137E, out var s1) ? KidsOf(raw, s1[0]) : [];
                if (inner.TryGetValue(0x1379, out var pid)) perks.Add(GuidStr(Payload(raw, pid[0])));
            }
            res.Scalars["perks"] = string.Join(",", perks);
            res.Scalars["perk_list_other"] = string.Join(",", extra);
        }
        if (main.TryGetValue(0x0926, out var f64))
            res.Scalars["0x0926"] = string.Join(",", (Children(raw, f64[0].PayloadOff, f64[0].End) ?? []).Select(c => $"0x{c.Tag:X4}={Convert.ToHexString(Payload(raw, c).AsSpan(0, Math.Min(8, c.Len)))}"));
        if (main.TryGetValue(0x0928, out var bf))
        {
            // persistent buff instances: [u32 n] then n records [8 bytes][16-byte buff GUID][state]
            var b = Payload(raw, bf[0]);
            uint n = BinaryPrimitives.ReadUInt32LittleEndian(b);
            var buffs = new List<string>();
            int p = 4;
            for (uint i = 0; i < n; i++)
            {
                uint ln = BinaryPrimitives.ReadUInt32LittleEndian(b.AsSpan(p + 2));
                buffs.Add($"{GuidStr(b.AsSpan(p + 6 + 8, 16))}/{ln}");
                p += 6 + (int)ln;
            }
            res.Scalars["persistent_buffs"] = string.Join(",", buffs);
        }
        if (f.TryGetValue(0x1301, out var invf))
        {
            var inv = KidsOf(raw, invf[0]);
            if (inv.TryGetValue(0x0007, out var lst))
            {
                foreach (var node in Children(raw, lst[0].PayloadOff, lst[0].End) ?? [])
                {
                    var b = Payload(raw, node);
                    if (node.Tag == 0x0000) { res.Scalars["inventory_header"] = GuidStr(b); continue; }
                    var ps = new List<string>();
                    foreach (var pn in Children(b, 36, b.Length) ?? [])
                    {
                        var v = b.AsSpan(pn.PayloadOff, pn.Len);
                        if (pn.Tag == 0 && pn.Len == 4) ps.Add($"amount={BinaryPrimitives.ReadUInt32LittleEndian(v) + 1}");   // stored as amount - 1
                        else ps.Add($"p{pn.Tag:x}={Convert.ToHexString(v).ToLowerInvariant()}");
                    }
                    res.Inventory.Add(new InvItem(GuidStr(b), BinaryPrimitives.ReadUInt32LittleEndian(b.AsSpan(16)), GuidStr(b.AsSpan(20)), string.Join(";", ps)));
                }
            }
            if (inv.TryGetValue(0x0006, out var eqn))
            {
                var eq = KidsOf(raw, eqn[0]);
                var slots = new List<string>();
                if (eq.TryGetValue(0x0001, out var e1n))
                {
                    var e1 = KidsOf(raw, e1n[0]);
                    if (e1.TryGetValue(0x0000, out var e0))
                    {
                        var b = Payload(raw, e0[0]);
                        for (int i = 0; i < b.Length - 15; i += 16) slots.Add(GuidStr(b.AsSpan(i)));
                    }
                }
                res.Scalars["equipped_instances"] = string.Join(",", slots);
            }
        }
        return res;
    }

    // ------------------------------------------------------------------ leaves

    /// <summary>
    /// path -> spans (Read-SaveAnatomy.leaves): lists of more than 50 same-tag
    /// children collapse to 'tag[*]'; the soul list is one leaf; the CryAction
    /// section's children are keyed by their blob name.
    /// </summary>
    public static Dictionary<string, List<(int Off, int Len)>> Leaves(byte[] raw, int maxDepth = 14)
    {
        var res = new Dictionary<string, List<(int, int)>>(StringComparer.Ordinal);
        void Rec(int off, int ln, string path, int depth)
        {
            var kids = (ln >= 6 && depth < maxDepth && !path.EndsWith("/1161", StringComparison.Ordinal)) ? Children(raw, off + 6, off + 6 + ln) : null;
            if (kids is null)
            {
                if (!res.TryGetValue(path, out var l)) res[path] = l = [];
                l.Add((off, ln));
                return;
            }
            var seen = new Dictionary<ushort, int>();
            foreach (var k in kids) seen[k.Tag] = seen.GetValueOrDefault(k.Tag) + 1;
            var idx = new Dictionary<ushort, int>();
            bool blobs = path.EndsWith("01f4/01f7", StringComparison.Ordinal);
            foreach (var k in kids)
            {
                idx[k.Tag] = idx.GetValueOrDefault(k.Tag) + 1;
                string key;
                if (blobs)
                {
                    var p = raw.AsSpan(k.PayloadOff, k.Len);
                    int nul = p.IndexOf((byte)0);
                    key = Encoding.Latin1.GetString(nul < 0 ? p : p[..nul]);
                }
                else if (seen[k.Tag] > 50) key = $"{k.Tag:x4}[*]";
                else if (seen[k.Tag] > 1) key = $"{k.Tag:x4}[{idx[k.Tag]}]";
                else key = $"{k.Tag:x4}";
                Rec(k.Off, k.Len, path + "/" + key, depth + 1);
            }
        }
        foreach (var t in TopLevel(raw)) Rec(t.Off, t.Len, $"{t.Tag:x4}", 0);
        return res;
    }

    public static string Digest(byte[] raw, List<(int Off, int Len)> spans)
    {
        using var h = IncrementalHash.CreateHash(HashAlgorithmName.SHA1);
        long tot = 0;
        foreach (var (o, l) in spans) { h.AppendData(raw, o + 6, l); tot += l; }
        return Convert.ToHexString(h.GetHashAndReset()).ToLowerInvariant() + "/" + tot;
    }

    // ------------------------------------------------------------------ quest-item classes

    /// <summary>Item class GUID (lower) -> name, for every IsQuestItem="true" row under libs/tables/item/ in Tables.pak.</summary>
    public static Dictionary<string, string> QuestClasses(string tablesPak)
    {
        var o = new Dictionary<string, string>(StringComparer.Ordinal);
        var rx = new Regex(@"<(\w+)\s([^>]*IsQuestItem=""true""[^>]*)>", RegexOptions.CultureInvariant);
        var gid = new Regex(@"\bId=""([0-9a-fA-F-]{36})""", RegexOptions.CultureInvariant);
        var gnm = new Regex(@"\bName=""([^""]*)""", RegexOptions.CultureInvariant);
        using var z = ZipFile.OpenRead(tablesPak);
        foreach (var e in z.Entries)
        {
            string low = e.FullName.ToLowerInvariant();
            if (!low.EndsWith(".xml", StringComparison.Ordinal) || !low.StartsWith("libs/tables/item/", StringComparison.Ordinal)) continue;
            string text;
            using (var s = e.Open()) using (var ms = new MemoryStream()) { s.CopyTo(ms); text = Encoding.Latin1.GetString(ms.ToArray()); }
            foreach (Match m in rx.Matches(text))
            {
                var g = gid.Match(m.Groups[2].Value);
                if (!g.Success) continue;
                var nm = gnm.Match(m.Groups[2].Value);
                o[g.Groups[1].Value.ToLowerInvariant()] = nm.Success ? nm.Groups[1].Value : "?";
            }
        }
        if (o.Count == 0) throw new InvalidDataException("no IsQuestItem classes found in " + Path.GetFileName(tablesPak));
        return o;
    }

    // ------------------------------------------------------------------ the splice (Splice-SaveHenry.py)

    public enum QuestItemMode { Strip, Host }

    private static List<Node> HenryChain(byte[] raw)
    {
        var chain = PathNodes(raw, 0x01F4, 0x01F8, 0x7308, 0x3529, 0x1161);
        var rec = FindSoul(raw, HenrySoul) ?? throw new InvalidDataException("player_henry soul record not found");
        if (rec.Tag != 0x115E) throw new InvalidDataException("player_henry record is not a full 0x115E record");
        chain.Add(rec);
        return chain;
    }

    /// <summary>A chain inside a standalone soul record (tag+len+32-byte prefix+TLV).</summary>
    private static List<Node> FieldChain(byte[] rec, params ushort[] tags)
    {
        var top = new Node(BinaryPrimitives.ReadUInt16LittleEndian(rec), 0, (int)BinaryPrimitives.ReadUInt32LittleEndian(rec.AsSpan(2)));
        var chain = new List<Node> { top };
        Node? cur = null;
        foreach (var k in Children(rec, 6 + 32, 6 + top.Len) ?? [])
            if (k.Tag == tags[0]) { cur = k; break; }
        if (cur is not Node first) throw new InvalidDataException($"soul field {tags[0]:x4} missing");
        chain.Add(first);
        for (int i = 1; i < tags.Length; i++)
        {
            cur = Child(rec, chain[^1], tags[i]);
            if (cur is not Node n) throw new InvalidDataException("soul field path " + string.Join("/", tags.Select(x => x.ToString("x4"))) + " missing");
            chain.Add(n);
        }
        return chain;
    }

    private static (List<Node> Chain, List<(Node Node, string Inst, string Cls)> Items) InventoryItems(byte[] rec)
    {
        var ch = FieldChain(rec, 0x1301, 0x0007);
        var lst = ch[^1];
        var items = new List<(Node, string, string)>();
        foreach (var node in Children(rec, lst.PayloadOff, lst.End) ?? [])
        {
            if (node.Tag == 0x0000) continue;
            items.Add((node, GuidStr(rec.AsSpan(node.PayloadOff)), GuidStr(rec.AsSpan(node.PayloadOff + 20))));
        }
        return (ch, items);
    }

    private static HashSet<string> Equipped(byte[] rec)
    {
        List<Node> ch;
        try { ch = FieldChain(rec, 0x1301, 0x0006, 0x0001, 0x0000); }
        catch (InvalidDataException) { return []; }   // no equipped-instance list (seen on a playline2 permanent save)
        var n = ch[^1];
        var o = new HashSet<string>();
        for (int i = 0; i < n.Len - 15; i += 16) o.Add(GuidStr(rec.AsSpan(n.PayloadOff + i)));
        return o;
    }

    public sealed class SpliceReport
    {
        public uint? StoryJoiner, StoryHost;
        public int RenownJoinerBytes, RenownHostBytes;
        public List<string> QuestItemsRemoved = [], QuestItemsAdded = [];
        public int KeysHostKept, KeysHostDropped, KeysJoinerAdded;
        public List<string> Blocks = [];
    }

    private static byte[] BuildHenry(byte[] hostRaw, HenryParts parts, Dictionary<string, string> qclasses, QuestItemMode mode, SpliceReport rep)
    {
        var hRec = HenryChain(hostRaw)[^1];
        var rec = parts.Record;
        var hrec = NodeBytes(hostRaw, hRec);
        if (!rec.AsSpan(6, 32).SequenceEqual(hrec.AsSpan(6, 32))) throw new InvalidDataException("player_henry GUID prefix differs between the saves");

        // stat id 8 (storyProgress) from the host. WO-125: an early save may hold
        // no story stat (host or joiner), and a new game's first Henry save holds
        // no stat list at all: the host's value is written, inserted or (the host
        // has none) removed, so the world's story progress is always the host's.
        uint? hval = StoryOf(hrec);
        rep.StoryHost = hval;
        rec = WithStory(rec, hval, out uint? jOld);
        rep.StoryJoiner = jOld;

        // 0x12FF renown record from the host
        var hr = FieldChain(hrec, 0x12FF)[^1];
        rep.RenownHostBytes = hr.Len;
        if (HasField(rec, 0x12FF))
        {
            var jr = FieldChain(rec, 0x12FF);
            rep.RenownJoinerBytes = jr[^1].Len;
            rec = Replace(rec, jr, Payload(hrec, hr));
        }
        else rec = AppendField(rec, 0x12FF, Payload(hrec, hr));

        // quest-class items: the joiner's always go (they belong to the joiner's world)
        if (!HasField(rec, 0x1301)) return rec;   // no inventory record (WO-125: the engine-default Henry)
        var (ch, items) = InventoryItems(rec);
        var eq = Equipped(rec);
        var drop = items.Where(it => qclasses.ContainsKey(it.Cls)).ToList();
        foreach (var d in drop)
            if (eq.Contains(d.Inst)) throw new InvalidDataException($"joiner quest item {d.Inst} ({qclasses[d.Cls]}) is equipped; refusing");
        var lst = ch[^1];
        var body = new List<byte>(Payload(rec, lst));
        foreach (var d in drop.OrderByDescending(x => x.Node.Off))
            body.RemoveRange(d.Node.Off - lst.PayloadOff, 6 + d.Node.Len);
        rep.QuestItemsRemoved = drop.Select(d => qclasses[d.Cls]).ToList();
        if (mode == QuestItemMode.Host)
        {
            var (_, hitems) = InventoryItems(hrec);
            foreach (var h in hitems)
                if (qclasses.ContainsKey(h.Cls)) { body.AddRange(NodeBytes(hrec, h.Node)); rep.QuestItemsAdded.Add(qclasses[h.Cls]); }
        }
        return Replace(rec, ch, body.ToArray());
    }

    /// <summary>
    /// EntityModule 01f8/7302/000B: [8-byte header] then 0x05AD entries of
    /// [16 owner soul GUID][9 bytes][16 key item instance GUID]. Host entries
    /// naming a host Henry item are dropped; the joiner's entries (those naming
    /// one of the joiner Henry's own items, <see cref="HenryParts.KeyEntries"/>)
    /// are added.
    /// </summary>
    private static byte[] MergeKeys(byte[] hostRaw, HashSet<string> hostItems, IReadOnlyList<byte[]> joinerEntries, SpliceReport? rep)
    {
        var (hh, he) = KeyEntries(hostRaw);
        var keep = he.Where(e => !hostItems.Contains(e.Key)).ToList();
        if (rep is not null) { rep.KeysHostKept = keep.Count; rep.KeysHostDropped = he.Count - keep.Count; rep.KeysJoinerAdded = joinerEntries.Count; }
        using var ms = new MemoryStream();
        ms.Write(hh);
        foreach (var e in keep) ms.Write(e.Entry);
        foreach (var e in joinerEntries) ms.Write(e);
        return ms.ToArray();
    }

    private static (byte[] Head, List<(byte[] Entry, string Key)> Entries) KeyEntries(byte[] raw)
    {
        var n = PathNodes(raw, KeyBlock)[^1];
        var b = Payload(raw, n);
        var kids = b.Length > 8 ? Children(b, 8, b.Length) : [];
        if (b.Length > 8 && kids is null) throw new InvalidDataException("EntityModule 000B does not parse");
        var o = new List<(byte[], string)>();
        foreach (var k in kids ?? [])
        {
            if (k.Tag != 0x05AD || k.Len != 41) throw new InvalidDataException($"unexpected 000B entry {k.Tag:x4}/{k.Len}");
            o.Add((b.AsSpan(k.Off, 6 + k.Len).ToArray(), GuidStr(b.AsSpan(k.Off + 6 + 25))));
        }
        return (b.AsSpan(0, Math.Min(8, b.Length)).ToArray(), o);
    }

    internal static readonly ushort[][] SideBlocks =
    [
        [0x01F4, 0x01F8, 0x7308, 0x352E], [0x01F4, 0x01F8, 0x7308, 0x352D],
        [0x01F4, 0x01F8, 0x7309, 0x0000], [0x01F4, 0x01F8, 0x7309, 0x0001],
        [0x01F4, 0x01F8, 0x7301], [0x01F4, 0x01F9, 0x7302, 0x0002],
    ];
    private static readonly ushort[] KeyBlock = [0x01F4, 0x01F8, 0x7302, 0x000B];

    private static HashSet<string> HenryItemSet(byte[] raw) => RecordItemSet(NodeBytes(raw, HenryChain(raw)[^1]));

    private static HashSet<string> RecordItemSet(byte[] rec) =>
        HasField(rec, 0x1301) ? InventoryItems(rec).Items.Select(i => i.Inst).ToHashSet() : [];

    /// <summary>The spliced stream: the host's, with the joiner's Henry record and side blocks put in.</summary>
    public static byte[] SpliceStream(byte[] hostRaw, byte[] joinRaw, Dictionary<string, string> qclasses, QuestItemMode mode, SpliceReport rep) =>
        SpliceStream(hostRaw, PartsFromStream(joinRaw, "", "save"), qclasses, mode, rep);

    /// <summary>WO-125: the spliced stream from a Henry's parts (a save's, a stored snapshot's, a fresh Henry's).</summary>
    public static byte[] SpliceStream(byte[] hostRaw, HenryParts parts, Dictionary<string, string> qclasses, QuestItemMode mode, SpliceReport rep)
    {
        if (parts.Side.Length != SideBlocks.Length) throw new InvalidDataException("the Henry parts do not carry the six side blocks");
        var jobs = new List<(ushort[]? Tags, byte[] Payload)>();
        for (int i = 0; i < SideBlocks.Length; i++)
            if (parts.Side[i] is byte[] sp) jobs.Add((SideBlocks[i], sp));
        jobs.Add((KeyBlock, MergeKeys(hostRaw, HenryItemSet(hostRaw), parts.KeyEntries, rep)));
        var henry = BuildHenry(hostRaw, parts, qclasses, mode, rep);
        jobs.Add((null, henry.AsSpan(6).ToArray()));

        List<Node> Where(byte[] r, ushort[]? tags) => tags is null ? HenryChain(r) : PathNodes(r, tags);
        var raw = hostRaw;
        // highest offset first so the chains still to come stay valid
        foreach (var (tags, payload) in jobs.OrderByDescending(j => Where(hostRaw, j.Tags)[^1].Off).ToList())
            raw = Replace(raw, Where(raw, tags), payload);
        rep.Blocks = jobs.Select(j => j.Tags is null ? "henry" : string.Join("/", j.Tags.Select(t => t.ToString("x4")))).ToList();
        return raw;
    }

    public sealed record SpliceResult(byte[] File, SpliceReport Report, SortedDictionary<string, string> Host, SortedDictionary<string, string> Joiner);

    /// <summary>
    /// The whole splice from two file images. Refuses inputs whose footer
    /// does not verify and mixed builds; the output is re-signed.
    /// </summary>
    public static SpliceResult Splice(byte[] hostFile, byte[] joinFile, Dictionary<string, string> qclasses, QuestItemMode mode)
    {
        if (!VerifyFooter(hostFile).Ok) throw new InvalidDataException("host save does not verify; refusing");
        if (!VerifyFooter(joinFile).Ok) throw new InvalidDataException("joiner save does not verify; refusing");
        var j = Inflate(joinFile);
        var js = DescriptionSummary(j.Desc);
        return SpliceParts(hostFile, PartsFromStream(j.Raw, js.GetValueOrDefault("BuildInfo") ?? "", "save"), qclasses, mode, js);
    }

    /// <summary>WO-125: the splice from a Henry's parts (a stored snapshot, a fresh Henry). Refuses an unverified host and mixed builds.</summary>
    public static SpliceResult SpliceParts(byte[] hostFile, HenryParts parts, Dictionary<string, string> qclasses, QuestItemMode mode,
                                           SortedDictionary<string, string>? joinerSummary = null)
    {
        if (!VerifyFooter(hostFile).Ok) throw new InvalidDataException("host save does not verify; refusing");
        var h = Inflate(hostFile);
        var hs = DescriptionSummary(h.Desc);
        hs.TryGetValue("BuildInfo", out var hb);
        if ((hb ?? "") != parts.Build && !(parts.Build == "" && parts.Origin == HenryParts.OriginFreshDefault))
            throw new InvalidDataException($"builds differ: {hb} vs {parts.Build}");
        var rep = new SpliceReport();
        var raw = SpliceStream(h.Raw, parts, qclasses, mode, rep);
        var js = joinerSummary ?? new SortedDictionary<string, string>(StringComparer.Ordinal) { ["BuildInfo"] = parts.Build, ["Origin"] = parts.Origin };
        return new SpliceResult(Deflate(h.DescBytes, raw, h.FooterTail), rep, hs, js);
    }

    /// <summary>Re-derive every expectation from the three files. Returns the failures (empty = pass).</summary>
    public static List<string> Check(byte[] hostFile, byte[] joinFile, byte[] outFile, Dictionary<string, string> qclasses, QuestItemMode mode)
    {
        var jc = Inflate(joinFile);
        return CheckParts(hostFile, PartsFromStream(jc.Raw, DescriptionSummary(jc.Desc).GetValueOrDefault("BuildInfo") ?? "", "save"), outFile, qclasses, mode);
    }

    /// <summary>
    /// WO-125: the check against a Henry's parts. Every block the parts carry
    /// is theirs byte for byte; every other block is the host's.
    /// </summary>
    public static List<string> CheckParts(byte[] hostFile, HenryParts parts, byte[] outFile, Dictionary<string, string> qclasses, QuestItemMode mode)
    {
        var fails = new List<string>();
        if (!VerifyFooter(outFile).Ok) fails.Add("output MD5 footer does not verify");
        var hc = Inflate(hostFile);
        var oc = Inflate(outFile);
        byte[] h = hc.Raw, o = oc.Raw;
        if (!hc.DescBytes.AsSpan().SequenceEqual(oc.DescBytes)) fails.Add("description header differs from the host");

        var spliced = new List<string> { "01f4/01f8/7302/000b", "01f4/01f8/7308/3529/1161" };
        for (int i = 0; i < SideBlocks.Length; i++)
            if (parts.Side[i] is not null) spliced.Add(PathText(SideBlocks[i]));
        bool Under(string k) => spliced.Any(s => k == s || k.StartsWith(s + "/", StringComparison.Ordinal));
        var lh = Leaves(h); var lo = Leaves(o);
        foreach (var k in lh.Keys.Union(lo.Keys).OrderBy(x => x, StringComparer.Ordinal))
        {
            if (Under(k)) continue;
            if (!lh.TryGetValue(k, out var a) || !lo.TryGetValue(k, out var b) || Digest(h, a) != Digest(o, b))
                fails.Add("host block changed: " + k);
        }
        for (int i = 0; i < SideBlocks.Length; i++)
        {
            if (parts.Side[i] is not byte[] want) continue;
            if (PathGet(o, SideBlocks[i]) is not Node n || !Payload(o, n).AsSpan().SequenceEqual(want))
                fails.Add("spliced block is not the joiner's: " + PathText(SideBlocks[i]));
        }

        var k0 = PathNodes(o, KeyBlock)[^1];
        if (!Payload(o, k0).AsSpan().SequenceEqual(MergeKeys(h, HenryItemSet(h), parts.KeyEntries, null)))
            fails.Add("EntityModule 000B key bindings are not the expected merge");

        var sh = SoulList(h); var so = SoulList(o);
        var gh = sh.Select(r => GuidStr(h.AsSpan(r.Off + 6))).ToList();
        var go = so.Select(r => GuidStr(o.AsSpan(r.Off + 6))).ToList();
        if (!gh.SequenceEqual(go)) fails.Add("soul list order/membership differs from the host");
        var byO = new Dictionary<string, Node>();
        for (int i = 0; i < so.Count; i++) byO[go[i]] = so[i];
        for (int i = 0; i < sh.Count; i++)
            if (gh[i] != HenrySoul && (!byO.TryGetValue(gh[i], out var r) || !NodeBytes(h, sh[i]).AsSpan().SequenceEqual(NodeBytes(o, r))))
                fails.Add("soul changed: " + gh[i]);

        var dh = DecodePlayerSoul(h, FindSoul(h, HenrySoul)!.Value);
        var dj = DecodePlayerSoul(parts.Record, RecordNode(parts.Record));
        var dout = DecodePlayerSoul(o, FindSoul(o, HenrySoul)!.Value);
        foreach (var (key, val) in dj.Scalars)
            if (!dout.Scalars.TryGetValue(key, out var ov) || ov != val) fails.Add($"Henry {key} is not the joiner's");
        foreach (var key in dout.Scalars.Keys)
            if (!dj.Scalars.ContainsKey(key)) fails.Add($"Henry {key} is not the joiner's");
        var expStats = new SortedDictionary<string, uint>(dj.StatXp, StringComparer.Ordinal);
        expStats.Remove("storyProgress");
        if (dh.StatXp.TryGetValue("storyProgress", out var hsp)) expStats["storyProgress"] = hsp;
        if (!expStats.SequenceEqual(dout.StatXp)) fails.Add("Henry stat_xp is not the joiner's with the host's storyProgress");
        var expInv = dj.Inventory.Where(i => !qclasses.ContainsKey(i.Class)).ToList();
        if (mode == QuestItemMode.Host) expInv.AddRange(dh.Inventory.Where(i => qclasses.ContainsKey(i.Class)));
        if (!expInv.SequenceEqual(dout.Inventory)) fails.Add($"Henry inventory is not the expected list ({dout.Inventory.Count} vs {expInv.Count} items)");
        var fo = SoulFields(o, FindSoul(o, HenrySoul)!.Value);
        var fh = SoulFields(h, FindSoul(h, HenrySoul)!.Value);
        if (!fo.ContainsKey(0x12FF) || !fh.ContainsKey(0x12FF) || !Payload(o, fo[0x12FF][0]).AsSpan().SequenceEqual(Payload(h, fh[0x12FF][0])))
            fails.Add("Henry 0x12FF renown is not the host's");
        return fails;
    }

    // ------------------------------------------------------------------ CLI (KcdMpClient --save-tool ...)

    /// <summary>
    /// <c>--save-tool verify &lt;save.whs&gt;...</c>,
    /// <c>--save-tool splice &lt;host&gt; &lt;joiner&gt; &lt;out&gt; --tables &lt;Tables.pak&gt; [--quest-items strip|host]</c>,
    /// <c>--save-tool check ...</c> (same arguments), <c>--save-tool inflate &lt;save.whs&gt; &lt;out.raw&gt;</c>.
    /// Prints only non-identifying header fields. Never overwrites an input
    /// or an existing file.
    /// </summary>
    public static int RunCli(string[] args, TextWriter w)
    {
        int at = Array.IndexOf(args, "--save-tool");
        var a = args.Skip(at + 1).ToList();
        if (a.Count == 0) { w.WriteLine("usage: --save-tool verify|splice|check|inflate ..."); return 2; }
        string cmd = a[0];
        string? Opt(string name) { int i = a.IndexOf(name); return i >= 0 && i + 1 < a.Count ? a[i + 1] : null; }
        var pos = new List<string>();
        for (int i = 1; i < a.Count; i++)
        {
            if (a[i].StartsWith("--", StringComparison.Ordinal)) { i++; continue; }
            pos.Add(a[i]);
        }
        try
        {
            switch (cmd)
            {
                case "verify":
                {
                    int bad = 0;
                    foreach (var p in pos)
                    {
                        var r = VerifyFile(p);
                        w.WriteLine($"{(r.Ok ? "OK " : "BAD")} {Path.GetFileName(p)} md5={r.Md5} {r.Reason} stream={r.StreamBytes}");
                        if (!r.Ok) bad++;
                    }
                    return bad == 0 && pos.Count > 0 ? 0 : 1;
                }
                case "inflate":
                {
                    if (pos.Count != 2) { w.WriteLine("usage: --save-tool inflate <save.whs> <out.raw>"); return 2; }
                    if (File.Exists(pos[1])) { w.WriteLine("output exists; refusing to overwrite"); return 2; }
                    File.WriteAllBytes(pos[1], Inflate(ReadShared(pos[0])).Raw);
                    return 0;
                }
                case "splice":
                case "check":
                {
                    if (pos.Count != 3) { w.WriteLine($"usage: --save-tool {cmd} <host> <joiner> <out> --tables <Tables.pak> [--quest-items strip|host]"); return 2; }
                    string? tables = Opt("--tables");
                    if (tables is null) { w.WriteLine("--tables <Tables.pak> is required"); return 2; }
                    var mode = (Opt("--quest-items") ?? "strip") == "host" ? QuestItemMode.Host : QuestItemMode.Strip;
                    var q = QuestClasses(tables);
                    string host = pos[0], join = pos[1], outp = pos[2];
                    if (cmd == "splice")
                    {
                        foreach (var p in new[] { host, join })
                            if (Path.GetFullPath(p).Equals(Path.GetFullPath(outp), StringComparison.OrdinalIgnoreCase)) { w.WriteLine("output must not be an input"); return 2; }
                        if (File.Exists(outp)) { w.WriteLine("output exists; refusing to overwrite"); return 2; }
                        var res = Splice(ReadShared(host), ReadShared(join), q, mode);
                        using (var fs = new FileStream(outp, FileMode.CreateNew, FileAccess.Write)) fs.Write(res.File);
                        var rp = res.Report;
                        w.WriteLine($"host: {string.Join(" ", res.Host.Select(kv => kv.Key + "=" + kv.Value))}");
                        w.WriteLine($"joiner: {string.Join(" ", res.Joiner.Select(kv => kv.Key + "=" + kv.Value))}");
                        w.WriteLine($"storyProgress joiner={rp.StoryJoiner} host={rp.StoryHost}; renown bytes joiner={rp.RenownJoinerBytes} host={rp.RenownHostBytes}");
                        w.WriteLine($"quest items removed=[{string.Join(",", rp.QuestItemsRemoved)}] added=[{string.Join(",", rp.QuestItemsAdded)}]; keys host_kept={rp.KeysHostKept} host_dropped={rp.KeysHostDropped} joiner_added={rp.KeysJoinerAdded}");
                        w.WriteLine($"blocks: {string.Join(" ", rp.Blocks)}; out_bytes={res.File.Length}");
                    }
                    var fails = Check(ReadShared(host), ReadShared(join), ReadShared(outp), q, mode);
                    foreach (var f in fails) w.WriteLine("FAIL " + f);
                    w.WriteLine("check: " + (fails.Count == 0 ? "PASS" : $"{fails.Count} failure(s)"));
                    return fails.Count == 0 ? 0 : 1;
                }
                default:
                    if (RunCliWo125(cmd, pos, Opt, w) is int rc) return rc;
                    w.WriteLine($"unknown --save-tool command '{cmd}'");
                    return 2;
            }
        }
        catch (Exception ex) when (ex is InvalidDataException or IOException)
        {
            w.WriteLine($"{cmd}: {ex.Message}");
            return 1;
        }
    }
}
