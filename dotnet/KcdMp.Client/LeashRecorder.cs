using System.Buffers.Binary;
using System.Globalization;
using System.Text;

namespace KcdMp.Client;

/// <summary>WO-127: one NPC in a native leash sample (native/KCDMP/leash.h, pipe 0x8F).</summary>
public readonly record struct LeashEntry(ulong Wuid, float X, float Y, float Z, ushort Flags, sbyte BrainState, byte BrainMask,
    ushort SpeedCms, ushort StreamAgeMs, string Name)
{
    public const ushort Horse = 1 << 0, Hidden = 1 << 1, Active = 1 << 2, PhysPresent = 1 << 3, AwakeKnown = 1 << 4,
        Awake = 1 << 5, Living = 1 << 6, Flying = 1 << 7, Driven = 1 << 8, BrainKnown = 1 << 9, EntFlagsKnown = 1 << 10,
        SimKnown = 1 << 11, SimActive = 1 << 12;
    public bool Has(ushort f) => (Flags & f) != 0;
    /// <summary>A stable key: the WUID, or the name when the WUID read failed.</summary>
    public string Key => Wuid != 0 ? Wuid.ToString("X16", CultureInfo.InvariantCulture) : "n:" + Name;
}

/// <summary>WO-127: one page of a native leash sample.</summary>
public sealed record LeashPage(bool Ok, byte Refuse, sbyte[] Town, sbyte[] Interior, uint Walked, uint Frames, uint SampleUs,
    ushort Total, ushort Offset, List<LeashEntry> Entries);

/// <summary>WO-127: the 0x1F request and the 0x8F reply (layout in native/KCDMP/pipe_server.h).</summary>
public static class LeashCodec
{
    public static byte[] BuildRequest(IReadOnlyList<(float X, float Y, float Z)> anchors, float radius, ushort offset)
    {
        if (anchors.Count is < 1 or > 4) throw new ArgumentOutOfRangeException(nameof(anchors));
        var p = new byte[4 + 1 + anchors.Count * 12 + 2];
        BinaryPrimitives.WriteSingleLittleEndian(p, radius);
        p[4] = (byte)anchors.Count;
        int o = 5;
        foreach (var a in anchors)
        {
            BinaryPrimitives.WriteSingleLittleEndian(p.AsSpan(o), a.X);
            BinaryPrimitives.WriteSingleLittleEndian(p.AsSpan(o + 4), a.Y);
            BinaryPrimitives.WriteSingleLittleEndian(p.AsSpan(o + 8), a.Z);
            o += 12;
        }
        BinaryPrimitives.WriteUInt16LittleEndian(p.AsSpan(o), offset);
        return p;
    }

    public static bool TryParse(ReadOnlySpan<byte> b, out LeashPage? page)
    {
        page = null;
        if (b.Length < 4) return false;
        bool ok = b[0] != 0;
        byte refuse = b[2];
        int n = b[3];
        int o = 4;
        if (n > 4 || b.Length < o + 2 * n + 18) return false;
        var town = new sbyte[n]; var inter = new sbyte[n];
        for (int i = 0; i < n; i++) town[i] = unchecked((sbyte)b[o + i]);
        o += n;
        for (int i = 0; i < n; i++) inter[i] = unchecked((sbyte)b[o + i]);
        o += n;
        uint walked = BinaryPrimitives.ReadUInt32LittleEndian(b[o..]); o += 4;
        uint frames = BinaryPrimitives.ReadUInt32LittleEndian(b[o..]); o += 4;
        uint us = BinaryPrimitives.ReadUInt32LittleEndian(b[o..]); o += 4;
        ushort total = BinaryPrimitives.ReadUInt16LittleEndian(b[o..]); o += 2;
        ushort offset = BinaryPrimitives.ReadUInt16LittleEndian(b[o..]); o += 2;
        ushort count = BinaryPrimitives.ReadUInt16LittleEndian(b[o..]); o += 2;
        var list = new List<LeashEntry>(count);
        for (int i = 0; i < count; i++)
        {
            if (b.Length < o + 31) return false;
            ulong wuid = BinaryPrimitives.ReadUInt64LittleEndian(b[o..]);
            float x = BinaryPrimitives.ReadSingleLittleEndian(b[(o + 8)..]);
            float y = BinaryPrimitives.ReadSingleLittleEndian(b[(o + 12)..]);
            float z = BinaryPrimitives.ReadSingleLittleEndian(b[(o + 16)..]);
            ushort flags = BinaryPrimitives.ReadUInt16LittleEndian(b[(o + 20)..]);
            sbyte bs = unchecked((sbyte)b[o + 22]);
            byte bm = b[o + 23];
            ushort sp = BinaryPrimitives.ReadUInt16LittleEndian(b[(o + 24)..]);
            ushort age = BinaryPrimitives.ReadUInt16LittleEndian(b[(o + 26)..]);
            int nl = b[o + 28];
            o += 29;
            if (b.Length < o + nl) return false;
            string name = Encoding.ASCII.GetString(b.Slice(o, nl));
            o += nl;
            list.Add(new LeashEntry(wuid, x, y, z, flags, bs, bm, sp, age, name));
        }
        page = new LeashPage(ok, refuse, town, inter, walked, frames, us, total, offset, list);
        return true;
    }
}

/// <summary>
/// WO-127 Phase 3: the leash recorder's file format (for WO-128). One CSV per
/// side, one row kind per line (<c>kind</c> column): on the host a
/// <c>summary</c> row and one <c>npc</c> row per NPC within 200 m of either
/// player each second; on the joiner one <c>copy</c> row per NPC copy within
/// 200 m. Empty cell = unknown. Positions are game coordinates; nothing else
/// identifying (no player names: "host" and the joiner's relay id only).
/// Files rotate at 50 MB.
/// </summary>
public sealed class LeashCsv : IDisposable
{
    public const string HostHeader =
        "utc,t_s,kind,joiner_id," +
        // summary
        "fps,host_x,host_y,host_z,joiner_x,joiner_y,joiner_z,host_joiner_m," +
        "host_town,host_interior,host_riding,host_fight,host_dialogue,host_cutscene,host_menu," +
        "joiner_town,joiner_interior,joiner_riding,joiner_fight,joiner_dialogue,joiner_cutscene,joiner_menu," +
        "npcs,sample_us,walked," +
        // npc
        "wuid,name,horse,x,y,z,d_host,d_joiner,exists,hidden,active,phys,phys_awake,phys_sim,living,flying,speed_mps," +
        "brain_state,brain_mask,moved_1s,in_stream_1s,driven,stream_age_ms";

    public const string JoinerHeader =
        "utc,t_s,kind,wuid,name,horse,x,y,z,d_joiner,exists,age_ms,stream_age_ms,suspended,brain_state,brain_mask,driven,hidden,active,phys_sim,moved_1s";

    public const long RotateBytes = 50L * 1024 * 1024;

    private readonly string _dir, _stem, _header;
    private readonly long _rotate;
    private StreamWriter? _w;
    private int _part = 1;
    public string? CurrentPath { get; private set; }
    public long Rows { get; private set; }

    public LeashCsv(string dir, string stem, string header, long rotateBytes = RotateBytes)
    {
        _dir = dir; _stem = stem; _header = header; _rotate = rotateBytes;
    }

    public void Write(string line)
    {
        if (_w is null || _w.BaseStream.Length >= _rotate) Open();
        _w!.WriteLine(line);
        Rows++;
    }

    public void Flush() => _w?.Flush();

    private void Open()
    {
        if (_w is not null) { _w.Dispose(); _part++; }
        Directory.CreateDirectory(_dir);
        CurrentPath = Path.Combine(_dir, _part == 1 ? $"{_stem}.csv" : $"{_stem}-part{_part}.csv");
        _w = new StreamWriter(new FileStream(CurrentPath, FileMode.Create, FileAccess.Write, FileShare.Read), new UTF8Encoding(false));
        _w.WriteLine(_header);
    }

    public void Dispose() { _w?.Dispose(); _w = null; }

    // ------------------------------------------------------------ cells

    public static string F(float? v, string fmt = "0.00") => v is float f && float.IsFinite(f) ? f.ToString(fmt, CultureInfo.InvariantCulture) : "";
    public static string B(bool? v) => v is bool b ? (b ? "1" : "0") : "";
    public static string T(sbyte v) => v < 0 ? "" : v.ToString(CultureInfo.InvariantCulture);
    public static string Csv(string s) => s.IndexOfAny(new[] { ',', '"', '\n', '\r' }) < 0 ? s : "\"" + s.Replace("\"", "\"\"") + "\"";
    public static float Dist2D(float ax, float ay, float bx, float by) => MathF.Sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by));
}

/// <summary>One player's context flags for the summary row. Null = unknown.</summary>
public readonly record struct LeashContext(bool? Town, bool? Interior, bool? Riding, bool? Fight, bool? Dialogue, bool? Cutscene, bool? Menu)
{
    public string Cells() => string.Join(",", LeashCsv.B(Town), LeashCsv.B(Interior), LeashCsv.B(Riding), LeashCsv.B(Fight),
        LeashCsv.B(Dialogue), LeashCsv.B(Cutscene), LeashCsv.B(Menu));
}

/// <summary>
/// WO-127: turns successive samples into rows. Pure (no I/O), so the format is
/// tested without a game: moved-in-the-last-second and "gone since the last
/// sample" (exists=0) are derived here from the previous sample.
/// </summary>
public sealed class LeashRowBuilder
{
    public const float Radius = 200f;
    public const float MovedEpsilonM = 0.05f;

    private Dictionary<string, LeashEntry> _prev = new();

    public sealed record HostInputs(DateTime Utc, double TSeconds, byte? JoinerId, float? Fps,
        (float X, float Y, float Z) Host, (float X, float Y, float Z)? Joiner,
        LeashContext HostCtx, LeashContext JoinerCtx, uint SampleUs, uint Walked,
        IReadOnlyList<LeashEntry> Npcs, Func<string, bool> InStream);

    public const int SummaryColumns = 25, NpcColumns = 23;

    public IEnumerable<string> HostRows(HostInputs i)
    {
        string utc = i.Utc.ToString("O", CultureInfo.InvariantCulture), t = i.TSeconds.ToString("0.000", CultureInfo.InvariantCulture);
        string jid = i.JoinerId?.ToString(CultureInfo.InvariantCulture) ?? "";
        var j = i.Joiner;
        float? hj = j is { } jj ? LeashCsv.Dist2D(i.Host.X, i.Host.Y, jj.X, jj.Y) : null;
        string summary = string.Join(",",
            LeashCsv.F(i.Fps, "0.0"), LeashCsv.F(i.Host.X), LeashCsv.F(i.Host.Y), LeashCsv.F(i.Host.Z),
            LeashCsv.F(j?.X), LeashCsv.F(j?.Y), LeashCsv.F(j?.Z), LeashCsv.F(hj),
            i.HostCtx.Cells(), i.JoinerCtx.Cells(),
            i.Npcs.Count.ToString(CultureInfo.InvariantCulture), i.SampleUs.ToString(CultureInfo.InvariantCulture),
            i.Walked.ToString(CultureInfo.InvariantCulture));
        string npcBlank = new string(',', NpcColumns - 1);
        string sumBlank = new string(',', SummaryColumns - 1);
        yield return string.Join(",", utc, t, "summary", jid, summary, npcBlank);

        var now = new Dictionary<string, LeashEntry>();
        foreach (var n in i.Npcs)
        {
            now[n.Key] = n;
            bool? moved = _prev.TryGetValue(n.Key, out var p) ? LeashCsv.Dist2D(n.X, n.Y, p.X, p.Y) > MovedEpsilonM || MathF.Abs(n.Z - p.Z) > MovedEpsilonM : null;
            yield return string.Join(",", utc, t, "npc", jid, sumBlank, NpcCells(n, i.Host, j, exists: true, moved, i.InStream(n.Name)));
        }
        foreach (var (k, p) in _prev)
            if (!now.ContainsKey(k))
                yield return string.Join(",", utc, t, "npc", jid, sumBlank, NpcCells(p, i.Host, j, exists: false, null, i.InStream(p.Name)));
        _prev = now;
    }

    private static string NpcCells(LeashEntry n, (float X, float Y, float Z) host, (float X, float Y, float Z)? joiner, bool exists, bool? moved, bool inStream)
    {
        bool fk = n.Has(LeashEntry.EntFlagsKnown), ak = n.Has(LeashEntry.AwakeKnown) && !n.Has(LeashEntry.Living), bk = n.Has(LeashEntry.BrainKnown),
             sk = n.Has(LeashEntry.SimKnown);
        float? speed = n.SpeedCms == 0xFFFF ? null : n.SpeedCms / 100f;
        return string.Join(",",
            n.Wuid == 0 ? "" : n.Wuid.ToString("X16", CultureInfo.InvariantCulture), LeashCsv.Csv(n.Name), LeashCsv.B(n.Has(LeashEntry.Horse)),
            LeashCsv.F(n.X), LeashCsv.F(n.Y), LeashCsv.F(n.Z),
            LeashCsv.F(LeashCsv.Dist2D(n.X, n.Y, host.X, host.Y), "0.0"),
            LeashCsv.F(joiner is { } j ? LeashCsv.Dist2D(n.X, n.Y, j.X, j.Y) : null, "0.0"),
            LeashCsv.B(exists),
            exists && fk ? LeashCsv.B(n.Has(LeashEntry.Hidden)) : "", exists && fk ? LeashCsv.B(n.Has(LeashEntry.Active)) : "",
            exists ? LeashCsv.B(n.Has(LeashEntry.PhysPresent)) : "", exists && ak ? LeashCsv.B(n.Has(LeashEntry.Awake)) : "",
            exists && sk ? LeashCsv.B(n.Has(LeashEntry.SimActive)) : "",
            exists ? LeashCsv.B(n.Has(LeashEntry.Living)) : "", exists ? LeashCsv.B(n.Has(LeashEntry.Flying)) : "",
            exists ? LeashCsv.F(speed) : "",
            exists && bk ? LeashCsv.T(n.BrainState) : "", exists && bk ? n.BrainMask.ToString("X2", CultureInfo.InvariantCulture) : "",
            LeashCsv.B(moved), LeashCsv.B(inStream), exists ? LeashCsv.B(n.Has(LeashEntry.Driven)) : "",
            n.StreamAgeMs == 0xFFFF ? "" : n.StreamAgeMs.ToString(CultureInfo.InvariantCulture));
    }

    public sealed record JoinerInputs(DateTime Utc, double TSeconds, (float X, float Y, float Z) Joiner,
        IReadOnlyList<LeashEntry> Copies, Func<string, double?> AgeMs);

    public IEnumerable<string> JoinerRows(JoinerInputs i)
    {
        string head = i.Utc.ToString("O", CultureInfo.InvariantCulture) + "," + i.TSeconds.ToString("0.000", CultureInfo.InvariantCulture);
        var now = new Dictionary<string, LeashEntry>();
        foreach (var n in i.Copies)
        {
            now[n.Key] = n;
            bool? moved = _prev.TryGetValue(n.Key, out var p) ? LeashCsv.Dist2D(n.X, n.Y, p.X, p.Y) > MovedEpsilonM : null;
            yield return head + ",copy," + CopyCells(n, i.Joiner, true, i.AgeMs(n.Name), moved);
        }
        foreach (var (k, p) in _prev)
            if (!now.ContainsKey(k)) yield return head + ",copy," + CopyCells(p, i.Joiner, false, i.AgeMs(p.Name), null);
        _prev = now;
    }

    private static string CopyCells(LeashEntry n, (float X, float Y, float Z) me, bool exists, double? ageMs, bool? moved)
    {
        bool bk = n.Has(LeashEntry.BrainKnown), fk = n.Has(LeashEntry.EntFlagsKnown), sk = n.Has(LeashEntry.SimKnown);
        return string.Join(",",
            n.Wuid == 0 ? "" : n.Wuid.ToString("X16", CultureInfo.InvariantCulture), LeashCsv.Csv(n.Name), LeashCsv.B(n.Has(LeashEntry.Horse)),
            LeashCsv.F(n.X), LeashCsv.F(n.Y), LeashCsv.F(n.Z), LeashCsv.F(LeashCsv.Dist2D(n.X, n.Y, me.X, me.Y), "0.0"),
            LeashCsv.B(exists),
            ageMs is double a ? Math.Round(a).ToString(CultureInfo.InvariantCulture) : "",
            n.StreamAgeMs == 0xFFFF ? "" : n.StreamAgeMs.ToString(CultureInfo.InvariantCulture),
            exists && bk ? LeashCsv.B(n.BrainState > 0) : "", exists && bk ? LeashCsv.T(n.BrainState) : "",
            exists && bk ? n.BrainMask.ToString("X2", CultureInfo.InvariantCulture) : "",
            exists ? LeashCsv.B(n.Has(LeashEntry.Driven)) : "",
            exists && fk ? LeashCsv.B(n.Has(LeashEntry.Hidden)) : "", exists && fk ? LeashCsv.B(n.Has(LeashEntry.Active)) : "",
            exists && sk ? LeashCsv.B(n.Has(LeashEntry.SimActive)) : "",
            LeashCsv.B(moved));
    }
}
