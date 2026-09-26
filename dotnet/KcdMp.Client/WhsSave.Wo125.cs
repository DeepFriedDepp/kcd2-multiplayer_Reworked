using System.Buffers.Binary;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

namespace KcdMp.Client;

/// <summary>
/// WO-125 -- continuity: a Henry that belongs to a world (docs/WO-125-findings.md).
///
/// <see cref="HenryParts"/> is the joiner side of the S3 splice, lifted out of a
/// save: the player_henry soul record, the six Henry side blocks and the
/// joiner's key-binding entries. A stored snapshot is exactly these bytes
/// (a "Henry block", <see cref="SerializeBlock"/>): splicing a block into a
/// host world gives the same stream as splicing the save it came from, byte
/// for byte (tested). No save header is stored (it carries the account name).
///
/// Also here: the playthrough seed (body 0x01FB, WO-112 s1.1: the same across
/// one playthrough, different across playthroughs -- save-verified on every
/// 1.5.5 playline on this machine) and "is the player in this save Henry"
/// (player_henry's soul is bound to the player entity 0x7777; in the prologue
/// and the Godwin stretch player_bohuta is -- save-verified on 194 saves).
/// </summary>
public static partial class WhsSave
{
    public const string BohutaSoul = "4666cffb-dea1-6263-72d7-b39f4db2d666";   // soul__player.xml player_bohuta (Godwin)
    public const ulong PlayerEntityGuid = 0x7777;                               // the player entity ("Dude") every Henry save binds to

    /// <summary>The joiner side of a splice.</summary>
    public sealed class HenryParts
    {
        public const string OriginSave = "save", OriginSnapshot = "snapshot", OriginFreshSave = "fresh-save", OriginFreshDefault = "fresh-default";

        /// <summary>The full 0x115E player_henry record: tag + length + payload.</summary>
        public byte[] Record = [];
        /// <summary>One payload per <see cref="SideBlocks"/> entry; null = the host's block stays.</summary>
        public byte[]?[] Side = new byte[]?[6];
        /// <summary>0x05AD key-binding entries (whole TLV nodes) naming one of this Henry's own items.</summary>
        public List<byte[]> KeyEntries = [];
        public string Build = "";
        public uint? Seed;
        public string Origin = OriginSave;
    }

    internal static Node RecordNode(byte[] rec) =>
        new(BinaryPrimitives.ReadUInt16LittleEndian(rec), 0, (int)BinaryPrimitives.ReadUInt32LittleEndian(rec.AsSpan(2)));

    internal static string PathText(ushort[] tags) => string.Join("/", tags.Select(t => t.ToString("x4")));

    /// <summary>Lift the joiner side out of a save's stream.</summary>
    public static HenryParts PartsFromStream(byte[] raw, string build, string origin)
    {
        var rec = NodeBytes(raw, HenryChain(raw)[^1]);
        var items = RecordItemSet(rec);
        var p = new HenryParts { Record = rec, Build = build, Seed = ReadSeed(raw), Origin = origin };
        for (int i = 0; i < SideBlocks.Length; i++) p.Side[i] = Payload(raw, PathNodes(raw, SideBlocks[i])[^1]);
        foreach (var (entry, key) in KeyEntries(raw).Entries)
            if (items.Contains(key)) p.KeyEntries.Add(entry);
        return p;
    }

    /// <summary>The parts of a save file (verified first).</summary>
    public static HenryParts PartsFromFile(byte[] file, string origin)
    {
        if (!VerifyFooter(file).Ok) throw new InvalidDataException("save does not verify; refusing");
        var c = Inflate(file);
        return PartsFromStream(c.Raw, DescriptionSummary(c.Desc).GetValueOrDefault("BuildInfo") ?? "", origin);
    }

    // ------------------------------------------------------------------ the stored block

    private static readonly byte[] BlockMagic = "KCDMPHB1"u8.ToArray();
    private const int BlockVersion = 1;

    /// <summary>
    /// <code>
    ///   "KCDMPHB1" [u32 version=1] [str build] [u8 hasSeed][u32 seed] [str origin]
    ///   [u32 len][player_henry record]
    ///   [u8 6] { [i32 len (-1 = the host's block stays)][payload] } x6
    ///   [u32 n] { [u16 len][0x05AD entry] } x n
    ///   [32-byte SHA-256 of everything before]
    /// </code>
    /// No save header, no world: nothing but Henry.
    /// </summary>
    public static byte[] SerializeBlock(HenryParts p)
    {
        using var ms = new MemoryStream();
        using (var w = new BinaryWriter(ms, Encoding.UTF8, leaveOpen: true))
        {
            w.Write(BlockMagic);
            w.Write(BlockVersion);
            void Str(string s) { var b = Encoding.UTF8.GetBytes(s); w.Write((ushort)b.Length); w.Write(b); }
            Str(p.Build);
            w.Write((byte)(p.Seed is null ? 0 : 1));
            w.Write(p.Seed ?? 0u);
            Str(p.Origin);
            w.Write(p.Record.Length);
            w.Write(p.Record);
            w.Write((byte)p.Side.Length);
            foreach (var s in p.Side)
            {
                w.Write(s is null ? -1 : s.Length);
                if (s is not null) w.Write(s);
            }
            w.Write(p.KeyEntries.Count);
            foreach (var e in p.KeyEntries) { w.Write((ushort)e.Length); w.Write(e); }
        }
        var body = ms.ToArray();
        var o = new byte[body.Length + 32];
        body.CopyTo(o, 0);
        SHA256.HashData(body).CopyTo(o, body.Length);
        return o;
    }

    /// <summary>Parse and fully check a stored block. Throws <see cref="InvalidDataException"/> on anything wrong.</summary>
    public static HenryParts ParseBlock(byte[] b)
    {
        if (b.Length < BlockMagic.Length + 4 + 32 || !b.AsSpan(0, BlockMagic.Length).SequenceEqual(BlockMagic))
            throw new InvalidDataException("not a Henry block");
        if (!SHA256.HashData(b.AsSpan(0, b.Length - 32)).AsSpan().SequenceEqual(b.AsSpan(b.Length - 32)))
            throw new InvalidDataException("Henry block hash mismatch");
        var p = new HenryParts();
        using var r = new BinaryReader(new MemoryStream(b, 0, b.Length - 32), Encoding.UTF8);
        try
        {
            r.ReadBytes(BlockMagic.Length);
            int ver = r.ReadInt32();
            if (ver != BlockVersion) throw new InvalidDataException($"Henry block version {ver}");
            string Str() => Encoding.UTF8.GetString(r.ReadBytes(r.ReadUInt16()));
            p.Build = Str();
            bool hasSeed = r.ReadByte() == 1;
            uint seed = r.ReadUInt32();
            p.Seed = hasSeed ? seed : null;
            p.Origin = Str();
            int rl = r.ReadInt32();
            if (rl < 38 || rl > 16 * 1024 * 1024) throw new InvalidDataException("Henry block record length out of range");
            p.Record = r.ReadBytes(rl);
            int n = r.ReadByte();
            if (n != SideBlocks.Length) throw new InvalidDataException($"Henry block carries {n} side blocks, not {SideBlocks.Length}");
            p.Side = new byte[]?[n];
            for (int i = 0; i < n; i++)
            {
                int l = r.ReadInt32();
                if (l < -1 || l > 64 * 1024 * 1024) throw new InvalidDataException("Henry block side length out of range");
                p.Side[i] = l < 0 ? null : r.ReadBytes(l);
                if (l > 0 && p.Side[i]!.Length != l) throw new InvalidDataException("Henry block truncated");
            }
            int k = r.ReadInt32();
            if (k < 0 || k > 100000) throw new InvalidDataException("Henry block key count out of range");
            for (int i = 0; i < k; i++) p.KeyEntries.Add(r.ReadBytes(r.ReadUInt16()));
            if (r.BaseStream.Position != r.BaseStream.Length) throw new InvalidDataException("Henry block has trailing bytes");
        }
        catch (EndOfStreamException) { throw new InvalidDataException("Henry block truncated"); }
        if (p.Record.Length != 6 + RecordNode(p.Record).Len || RecordNode(p.Record).Tag != 0x115E || GuidStr(p.Record.AsSpan(6)) != HenrySoul)
            throw new InvalidDataException("Henry block record is not a full player_henry record");
        if (Children(p.Record, 6 + 32, p.Record.Length) is null) throw new InvalidDataException("Henry block record does not parse");
        foreach (var e in p.KeyEntries)
            if (e.Length != 47 || BinaryPrimitives.ReadUInt16LittleEndian(e) != 0x05AD) throw new InvalidDataException("Henry block key entry malformed");
        return p;
    }

    // ------------------------------------------------------------------ story stat, fields

    internal static bool HasField(byte[] rec, ushort tag) =>
        (Children(rec, 6 + 32, 6 + RecordNode(rec).Len) ?? []).Any(k => k.Tag == tag);

    /// <summary>Append a soul field (tag, payload) to a standalone record, fixing its length.</summary>
    internal static byte[] AppendField(byte[] rec, ushort tag, byte[] payload)
    {
        var o = new byte[rec.Length + 6 + payload.Length];
        rec.CopyTo(o, 0);
        BinaryPrimitives.WriteUInt16LittleEndian(o.AsSpan(rec.Length), tag);
        BinaryPrimitives.WriteUInt32LittleEndian(o.AsSpan(rec.Length + 2), (uint)payload.Length);
        payload.CopyTo(o, rec.Length + 6);
        BinaryPrimitives.WriteUInt32LittleEndian(o.AsSpan(2), (uint)(o.Length - 6));
        return o;
    }

    /// <summary>The record's storyProgress (stat id 8) or null (no stat list / no slot).</summary>
    internal static uint? StoryOf(byte[] rec)
    {
        List<Node> ch;
        try { ch = FieldChain(rec, 0x12FB, 0x0927, 0x1385); }
        catch (InvalidDataException) { return null; }
        uint? v = null;
        foreach (var (k, val) in Pairs(Payload(rec, ch[^1]))) if (k == StatStory) v = val;   // the last pair with the key wins
        return v;
    }

    /// <summary>
    /// The record with storyProgress set to <paramref name="host"/>: written in
    /// place, inserted in key order, or removed when the host has none. A
    /// record without a stat list gets one (the first 0x0927 child, as the game
    /// writes it) only when there is a value to hold.
    /// </summary>
    internal static byte[] WithStory(byte[] rec, uint? host, out uint? old)
    {
        old = StoryOf(rec);
        List<Node>? ch = null;
        try { ch = FieldChain(rec, 0x12FB, 0x0927, 0x1385); } catch (InvalidDataException) { }
        if (ch is null)
        {
            if (host is not uint hv0) return rec;
            List<Node> core;
            try { core = FieldChain(rec, 0x12FB, 0x0927); }
            catch (InvalidDataException) { throw new InvalidDataException("joiner Henry has no 0x12FB/0x0927 core to hold the story stat"); }
            var list = new byte[12];
            BinaryPrimitives.WriteUInt32LittleEndian(list, StatStory);
            BinaryPrimitives.WriteUInt32LittleEndian(list.AsSpan(4), hv0);
            BinaryPrimitives.WriteUInt32LittleEndian(list.AsSpan(8), 0xFFFFFFFFu);
            var node = new byte[6 + list.Length];
            BinaryPrimitives.WriteUInt16LittleEndian(node, 0x1385);
            BinaryPrimitives.WriteUInt32LittleEndian(node.AsSpan(2), (uint)list.Length);
            list.CopyTo(node, 6);
            return Replace(rec, core, [.. node, .. Payload(rec, core[^1])]);
        }
        var p = Payload(rec, ch[^1]);
        var pairs = new List<(uint K, uint V)>();
        int i = 0;
        for (; i + 8 <= p.Length; i += 8)
        {
            uint k = BinaryPrimitives.ReadUInt32LittleEndian(p.AsSpan(i));
            if (k == 0xFFFFFFFFu) break;
            pairs.Add((k, BinaryPrimitives.ReadUInt32LittleEndian(p.AsSpan(i + 4))));
        }
        var tail = p.AsSpan(Math.Min(i, p.Length)).ToArray();   // the terminator and anything after it, kept as is
        if (host is uint hv)
        {
            bool set = false;
            for (int n = 0; n < pairs.Count; n++) if (pairs[n].K == StatStory) { pairs[n] = (StatStory, hv); set = true; }
            if (!set)
            {
                int at = pairs.FindIndex(x => x.K > StatStory);
                pairs.Insert(at < 0 ? pairs.Count : at, (StatStory, hv));
            }
        }
        else pairs.RemoveAll(x => x.K == StatStory);
        var o = new byte[pairs.Count * 8 + tail.Length];
        for (int n = 0; n < pairs.Count; n++)
        {
            BinaryPrimitives.WriteUInt32LittleEndian(o.AsSpan(n * 8), pairs[n].K);
            BinaryPrimitives.WriteUInt32LittleEndian(o.AsSpan(n * 8 + 4), pairs[n].V);
        }
        tail.CopyTo(o, pairs.Count * 8);
        return o.AsSpan().SequenceEqual(p) ? rec : Replace(rec, ch, o);
    }

    // ------------------------------------------------------------------ seed, player

    /// <summary>The playthrough seed (body 0x01FB, u32) or null.</summary>
    public static uint? ReadSeed(byte[] raw)
    {
        var n = PathGet(raw, 0x01F4, 0x01FB);
        return n is Node s && s.Len == 4 ? BinaryPrimitives.ReadUInt32LittleEndian(raw.AsSpan(s.PayloadOff)) : null;
    }

    /// <summary>
    /// The seed straight from a file, inflating only the first blocks (0x01FB is
    /// the body's first child, right after the header chunk). Null when it
    /// cannot be read: never an exception for an unreadable or foreign file.
    /// </summary>
    public static uint? ReadSeedFromFile(string path)
    {
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var head = new byte[8];
            if (fs.Read(head, 0, 8) != 8 || BinaryPrimitives.ReadUInt32LittleEndian(head) != 0xFFFFFFFFu) return null;
            int descLen = BinaryPrimitives.ReadInt32LittleEndian(head.AsSpan(4));
            if (descLen < 0 || descLen > 1 << 20) return null;
            fs.Seek(descLen, SeekOrigin.Current);
            var raw = new MemoryStream();
            var bh = new byte[8];
            for (int block = 0; block < 64; block++)
            {
                if (fs.Read(bh, 0, 8) != 8) return null;
                int clen = BinaryPrimitives.ReadInt32LittleEndian(bh), rlen = BinaryPrimitives.ReadInt32LittleEndian(bh.AsSpan(4));
                if (rlen < 0 || rlen > 1 << 20) return null;
                if (clen == -1)
                {
                    var b = new byte[rlen];
                    if (fs.Read(b, 0, rlen) != rlen) return null;
                    raw.Write(b);
                }
                else
                {
                    if (clen < 0 || clen > 1 << 21) return null;
                    var z = new byte[clen];
                    if (fs.Read(z, 0, clen) != clen) return null;
                    using var zin = new ZLibStream(new MemoryStream(z), CompressionMode.Decompress);
                    zin.CopyTo(raw);
                }
                if (SeedInPrefix(raw.GetBuffer().AsSpan(0, (int)raw.Length)) is { } r) return r.Found ? r.Seed : null;
            }
            return null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException) { return null; }
    }

    /// <summary>(found, seed) once the prefix is long enough to decide; null = need more bytes.</summary>
    private static (bool Found, uint Seed)? SeedInPrefix(ReadOnlySpan<byte> raw)
    {
        int p = 4;
        while (true)
        {
            if (p + 6 > raw.Length) return null;
            ushort tag = BinaryPrimitives.ReadUInt16LittleEndian(raw[p..]);
            uint len = BinaryPrimitives.ReadUInt32LittleEndian(raw[(p + 2)..]);
            if (tag == 0x01F4)
            {
                int q = p + 6;
                if (q + 6 > raw.Length) return null;
                ushort t2 = BinaryPrimitives.ReadUInt16LittleEndian(raw[q..]);
                uint l2 = BinaryPrimitives.ReadUInt32LittleEndian(raw[(q + 2)..]);
                if (t2 != 0x01FB || l2 != 4) return (false, 0);
                if (q + 10 > raw.Length) return null;
                return (true, BinaryPrimitives.ReadUInt32LittleEndian(raw[(q + 6)..]));
            }
            if (tag == 0x01FA) return (false, 0);
            p += 6 + (int)len;
            if (len > 64u << 20) return (false, 0);
        }
    }

    /// <summary>A short, non-reversible label for a seed in logs and folder names (never the seed itself).</summary>
    public static string SeedTag(uint seed)
    {
        Span<byte> b = stackalloc byte[4 + 12];
        BinaryPrimitives.WriteUInt32LittleEndian(b, seed);
        "kcdmp-world"u8.CopyTo(b[4..]);
        return Convert.ToHexString(SHA256.HashData(b[..15]))[..10].ToLowerInvariant();
    }

    public readonly record struct PlayerInfo(bool IsHenry, string Player, bool Pristine);

    /// <summary>
    /// Who the player is in this save: the soul whose 0x12F9 names the player
    /// entity 0x7777. IsHenry = player_henry and nobody else. Pristine = a new
    /// game's first Henry save: Henry holds no stat and no skill XP yet.
    /// </summary>
    public static PlayerInfo PlayerOf(byte[] raw)
    {
        var bound = new List<string>();
        bool pristine = false;
        foreach (var rec in SoulList(raw))
        {
            if (rec.Tag != 0x115E) continue;
            var f = SoulFields(raw, rec);
            if (!f.TryGetValue(0x12F9, out var nf)) continue;
            var b = Payload(raw, nf[0]);
            int nul = Array.IndexOf(b, (byte)0);
            if (nul < 0 || nul + 9 > b.Length || BinaryPrimitives.ReadUInt64LittleEndian(b.AsSpan(nul + 1)) != PlayerEntityGuid) continue;
            string g = GuidStr(raw.AsSpan(rec.Off + 6, 16));
            bound.Add(g);
            if (g == HenrySoul)
            {
                var rb = NodeBytes(raw, rec);
                bool xp = false;
                try { xp |= FieldChain(rb, 0x12FB, 0x0927, 0x1385) is not null; } catch (InvalidDataException) { }
                try { xp |= FieldChain(rb, 0x12FB, 0x0927, 0x138D) is not null; } catch (InvalidDataException) { }
                pristine = !xp;
            }
        }
        string who = bound.Count == 0 ? "none" : bound.Count > 1 ? "several" : bound[0] == HenrySoul ? "player_henry" : bound[0] == BohutaSoul ? "player_bohuta" : bound[0][..8];
        return new PlayerInfo(bound.Count == 1 && bound[0] == HenrySoul, who, bound.Count == 1 && bound[0] == HenrySoul && pristine);
    }

    // ------------------------------------------------------------------ a fresh Henry

    /// <summary>
    /// WO-125 Phase 3, the fallback when the joiner's machine holds no new
    /// game's first Henry save: a player_henry record with nothing in it but
    /// what binds it to the player entity, so the engine's own soul loader
    /// builds the rest from the game's soul database (C_Soul::LoadGame copies
    /// the soul from the DB before reading the saved fields, WO-112 s2.4).
    /// Built in code: no byte of any real save except the soul's 32-byte GUID
    /// prefix, which is the soul's identity (the same in every save). The
    /// side blocks stay the host's (null) -- see the findings for what that
    /// carries. The splice then writes the host's story stat and renown.
    /// </summary>
    public static HenryParts FreshDefaultParts(byte[] hostRaw)
    {
        var hrec = NodeBytes(hostRaw, HenryChain(hostRaw)[^1]);
        var prefix = hrec.AsSpan(6, 32).ToArray();
        static byte[] T(ushort tag, byte[] payload)
        {
            var b = new byte[6 + payload.Length];
            BinaryPrimitives.WriteUInt16LittleEndian(b, tag);
            BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(2), (uint)payload.Length);
            payload.CopyTo(b, 6);
            return b;
        }
        var name = new byte[5 + 8];
        "Dude"u8.CopyTo(name);
        BinaryPrimitives.WriteUInt64LittleEndian(name.AsSpan(5), PlayerEntityGuid);
        var fields = new List<byte>();
        fields.AddRange(T(0x1303, Convert.FromHexString("fd1203000000000001")));   // the same 9 bytes in every save seen (194)
        fields.AddRange(T(0x12F9, name));
        fields.AddRange(T(0x12FB, T(0x0927, T(0x1385, [0xFF, 0xFF, 0xFF, 0xFF]))));  // an empty stat list: the splice writes the host's story stat into it
        fields.AddRange(T(0x12FF, new byte[16]));                                   // replaced by the host's renown
        var rec = T(0x115E, [.. prefix, .. fields]);
        return new HenryParts { Record = rec, Side = new byte[]?[SideBlocks.Length], Build = "", Origin = HenryParts.OriginFreshDefault };
    }

    // ------------------------------------------------------------------ comparing two blocks

    /// <summary>
    /// What differs between two Henry blocks: the record field by field (and
    /// inside 0x12FB/0x0927 one level deeper), each side block, the key
    /// entries. Empty = byte-identical Henry.
    /// </summary>
    public static List<string> DiffBlocks(HenryParts a, HenryParts b)
    {
        var o = new List<string>();
        static Dictionary<string, byte[]> Flat(byte[] rec)
        {
            var d = new Dictionary<string, byte[]>(StringComparer.Ordinal);
            var seen = new Dictionary<ushort, int>();
            foreach (var f in Children(rec, 6 + 32, rec.Length) ?? [])
            {
                int i = seen[f.Tag] = seen.GetValueOrDefault(f.Tag) + 1;
                string k = $"{f.Tag:x4}#{i}";
                if (f.Tag == 0x12FB)
                {
                    foreach (var c in Children(rec, f.PayloadOff, f.End) ?? [])
                    {
                        if (c.Tag == 0x0927)
                            foreach (var cc in Children(rec, c.PayloadOff, c.End) ?? []) d[$"{k}/0927/{cc.Tag:x4}"] = Payload(rec, cc);
                        else d[$"{k}/{c.Tag:x4}"] = Payload(rec, c);
                    }
                }
                else d[k] = Payload(rec, f);
            }
            return d;
        }
        if (!a.Record.AsSpan().SequenceEqual(b.Record))
        {
            var fa = Flat(a.Record); var fb = Flat(b.Record);
            foreach (var k in fa.Keys.Union(fb.Keys).OrderBy(x => x, StringComparer.Ordinal))
                if (!fa.TryGetValue(k, out var x) || !fb.TryGetValue(k, out var y) || !x.AsSpan().SequenceEqual(y))
                    o.Add($"record {k} ({(fa.TryGetValue(k, out var x2) ? x2.Length : -1)} vs {(fb.TryGetValue(k, out var y2) ? y2.Length : -1)} B)");
            if (o.Count == 0) o.Add("record (framing)");
        }
        for (int i = 0; i < SideBlocks.Length; i++)
        {
            var x = a.Side[i]; var y = b.Side[i];
            if (x is null && y is null) continue;
            if (x is null || y is null || !x.AsSpan().SequenceEqual(y)) o.Add($"side {PathText(SideBlocks[i])} ({x?.Length ?? -1} vs {y?.Length ?? -1} B)");
        }
        if (a.KeyEntries.Count != b.KeyEntries.Count || a.KeyEntries.Zip(b.KeyEntries).Any(p => !p.First.AsSpan().SequenceEqual(p.Second)))
            o.Add($"keys ({a.KeyEntries.Count} vs {b.KeyEntries.Count})");
        return o;
    }

    // ------------------------------------------------------------------ CLI

    /// <summary>
    /// <c>--save-tool extract &lt;save&gt; &lt;out.hblk&gt;</c>, <c>splice-block &lt;host&gt; &lt;block&gt; &lt;out&gt; --tables</c>,
    /// <c>splice-fresh &lt;host&gt; &lt;out&gt; --tables</c>, <c>blockdiff &lt;a&gt; &lt;b&gt;</c> (blocks or saves),
    /// <c>seed|who &lt;save&gt;...</c>. The seed is printed only as its tag.
    /// </summary>
    private static int? RunCliWo125(string cmd, List<string> pos, Func<string, string?> opt, TextWriter w)
    {
        HenryParts Load(string p)
        {
            var b = ReadShared(p);
            return b.AsSpan().StartsWith(BlockMagic) ? ParseBlock(b) : PartsFromFile(b, HenryParts.OriginSave);
        }
        void WriteNew(string p, byte[] data)
        {
            if (File.Exists(p)) throw new IOException("output exists; refusing to overwrite");
            using var fs = new FileStream(p, FileMode.CreateNew, FileAccess.Write);
            fs.Write(data);
        }
        switch (cmd)
        {
            case "seed":
            case "who":
                foreach (var p in pos)
                {
                    if (cmd == "seed") { var s = ReadSeedFromFile(p); w.WriteLine($"{Path.GetFileName(p)} seed_tag={(s is uint v ? SeedTag(v) : "-")}"); continue; }
                    var raw = Inflate(ReadShared(p)).Raw;
                    var pi = PlayerOf(raw);
                    w.WriteLine($"{Path.GetFileName(p)} player={pi.Player} henry={(pi.IsHenry ? "yes" : "no")} pristine={(pi.Pristine ? "yes" : "no")} seed_tag={(ReadSeed(raw) is uint v2 ? SeedTag(v2) : "-")}");
                }
                return 0;
            case "extract":
            {
                if (pos.Count != 2) { w.WriteLine("usage: --save-tool extract <save.whs> <out.hblk>"); return 2; }
                var parts = PartsFromFile(ReadShared(pos[0]), HenryParts.OriginSnapshot);
                var blk = SerializeBlock(parts);
                WriteNew(pos[1], blk);
                w.WriteLine($"block {blk.Length} B: record {parts.Record.Length} B, sides {string.Join(",", parts.Side.Select(x => x?.Length ?? -1))}, keys {parts.KeyEntries.Count}, seed_tag={(parts.Seed is uint s ? SeedTag(s) : "-")}");
                return 0;
            }
            case "blockdiff":
            {
                if (pos.Count != 2) { w.WriteLine("usage: --save-tool blockdiff <a> <b>"); return 2; }
                var d = DiffBlocks(Load(pos[0]), Load(pos[1]));
                foreach (var x in d) w.WriteLine("DIFF " + x);
                w.WriteLine(d.Count == 0 ? "blockdiff: IDENTICAL" : $"blockdiff: {d.Count} difference(s)");
                return d.Count == 0 ? 0 : 1;
            }
            case "splice-block":
            case "splice-fresh":
            {
                int need = cmd == "splice-block" ? 3 : 2;
                if (pos.Count != need) { w.WriteLine($"usage: --save-tool {cmd} <host> {(need == 3 ? "<block|save> " : "")}<out> --tables <Tables.pak>"); return 2; }
                string? tables = opt("--tables");
                if (tables is null) { w.WriteLine("--tables <Tables.pak> is required"); return 2; }
                var q = QuestClasses(tables);
                var host = ReadShared(pos[0]);
                var parts = cmd == "splice-block" ? Load(pos[1]) : FreshDefaultParts(Inflate(host).Raw);
                var res = SpliceParts(host, parts, q, QuestItemMode.Strip);
                var fails = CheckParts(host, parts, res.File, q, QuestItemMode.Strip);
                var ver = Verify(res.File);
                foreach (var f in fails) w.WriteLine("FAIL " + f);
                w.WriteLine($"origin={parts.Origin} story joiner={res.Report.StoryJoiner?.ToString() ?? "-"} host={res.Report.StoryHost?.ToString() ?? "-"}; quest items removed={res.Report.QuestItemsRemoved.Count}; keys joiner_added={res.Report.KeysJoinerAdded}; out_bytes={res.File.Length}; verify={(ver.Ok ? "ok" : ver.Reason)}");
                w.WriteLine("check: " + (fails.Count == 0 ? "PASS" : $"{fails.Count} failure(s)"));
                if (fails.Count > 0 || !ver.Ok) return 1;
                WriteNew(pos[^1], res.File);
                return 0;
            }
        }
        return null;
    }
}
