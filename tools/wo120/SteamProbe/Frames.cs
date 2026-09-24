using System.Buffers.Binary;
using System.Diagnostics;

namespace KcdMp.SteamProbe;

/// <summary>
/// The probe's own framing, over the same byte-stream view the agent would
/// use: [type:1][len:4 LE][payload]. Every payload is filled from its
/// sequence number, so the receiver can prove order and content, not just
/// arrival.
/// </summary>
internal static class F
{
    public const byte Hello = 1, HelloAck = 2, Ping = 3, Pong = 4, State = 5, Npc = 6, Burst = 7, BurstAck = 8,
                      StartGame = 9, EndGame = 10, BulkReq = 11, Bulk = 12, Done = 13, Stats = 14;

    public const int StateBytes = 40;     // one player-state frame (0x01 is 20 B + header; round up)
    public const int NpcBytes = 512;      // 20 Hz x 512 B = 10 KB/s, the top of WO-109 §4.3's 6-10 KB/s
    public const int ChunkBytes = 16 * 1024;
    public const int BurstChunks = 4;     // 64 KB burst: a crowd resync
    public const int VirtualPort = 7120;

    public static async Task WriteAsync(Stream s, SemaphoreSlim gate, byte type, ReadOnlyMemory<byte> payload, CancellationToken ct)
    {
        var buf = new byte[5 + payload.Length];
        buf[0] = type;
        BinaryPrimitives.WriteInt32LittleEndian(buf.AsSpan(1), payload.Length);
        payload.CopyTo(buf.AsMemory(5));
        await gate.WaitAsync(ct);
        try { await s.WriteAsync(buf, ct); }
        finally { gate.Release(); }
    }

    public static async Task<(byte Type, byte[] Payload)> ReadAsync(Stream s, CancellationToken ct)
    {
        var h = new byte[5];
        await ReadExact(s, h, ct);
        int len = BinaryPrimitives.ReadInt32LittleEndian(h.AsSpan(1));
        if (len < 0 || len > 4 * 1024 * 1024) throw new InvalidDataException($"frame length {len}");
        var p = new byte[len];
        await ReadExact(s, p, ct);
        return (h[0], p);
    }

    private static async Task ReadExact(Stream s, byte[] b, CancellationToken ct)
    {
        int o = 0;
        while (o < b.Length)
        {
            int n = await s.ReadAsync(b.AsMemory(o), ct);
            if (n == 0) throw new EndOfStreamException();
            o += n;
        }
    }

    /// <summary>[seq:4][filler from seq]. Size includes the seq.</summary>
    public static byte[] Patterned(uint seq, int size, int headerBytes = 4)
    {
        var b = new byte[size];
        BinaryPrimitives.WriteUInt32LittleEndian(b, seq);
        for (int i = headerBytes; i < size; i++) b[i] = (byte)(seq * 31 + i);
        return b;
    }

    public static bool CheckPattern(byte[] b, uint seq, int headerBytes = 4)
    {
        for (int i = headerBytes; i < b.Length; i++) if (b[i] != (byte)(seq * 31 + i)) return false;
        return true;
    }

    public static byte[] U32(uint v) { var b = new byte[4]; BinaryPrimitives.WriteUInt32LittleEndian(b, v); return b; }
    public static uint U32(byte[] b, int o = 0) => BinaryPrimitives.ReadUInt32LittleEndian(b.AsSpan(o));

    /// <summary>A ping: [seq:4][sender stopwatch ticks:8].</summary>
    public static byte[] PingPayload(uint seq)
    {
        var b = new byte[12];
        BinaryPrimitives.WriteUInt32LittleEndian(b, seq);
        BinaryPrimitives.WriteInt64LittleEndian(b.AsSpan(4), Stopwatch.GetTimestamp());
        return b;
    }

    public static double PingRttMs(byte[] pong) =>
        Stopwatch.GetElapsedTime(BinaryPrimitives.ReadInt64LittleEndian(pong.AsSpan(4))).TotalMilliseconds;
}

internal sealed class Samples
{
    private readonly List<double> _v = new();
    private readonly object _lock = new();
    public void Add(double x) { lock (_lock) _v.Add(x); }
    public int Count { get { lock (_lock) return _v.Count; } }

    public string Summary(string unit = "ms")
    {
        double[] s;
        lock (_lock) s = _v.OrderBy(x => x).ToArray();
        if (s.Length == 0) return "n=0";
        double P(double q) => s[Math.Clamp((int)Math.Ceiling(q / 100 * s.Length) - 1, 0, s.Length - 1)];
        return FormattableString.Invariant($"n={s.Length} p50={P(50):0.0}{unit} p95={P(95):0.0}{unit} p99={P(99):0.0}{unit} max={s[^1]:0.0}{unit}");
    }
}

/// <summary>Everything the probe prints. Lines prefixed CONSOLE: never reach the report file.</summary>
internal static class Out
{
    public static void Line(string s) { lock (typeof(Out)) Console.WriteLine(s); }
    public static void ConsoleOnly(string s) => Line("CONSOLE:" + s);
    public static string Inv(FormattableString f) => FormattableString.Invariant(f);
}
