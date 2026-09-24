using System.Buffers.Binary;
using System.Diagnostics;
using System.Text;
using System.Threading.Channels;

namespace KcdMp.Client;

/// <summary>
/// WO-118: why the native per-frame writer (KCDMP.dll npc_drive.h) refused a
/// bind or stopped writing a puppet on its own. Mirrors
/// <c>kcdmp::npcdrive::Reason</c> by number; APPEND-ONLY.
/// </summary>
public enum NativeNpcReason : byte
{
    Ok = 0,
    Disarmed = 1,
    ToggleOff = 2,
    NoEntity = 3,
    NameMismatch = 4,
    WuidMismatch = 5,
    NotLiving = 6,
    Parented = 7,
    BadRequest = 8,
    EntityGone = 9,
    Silence = 10,
    Fault = 11,
    Unbound = 12,
    TableFull = 13,
    PipeClosed = 14,
}

/// <summary>WO-118: the 0x89 heartbeat answer.</summary>
public readonly record struct NativeNpcStatus(bool Armed, bool NativeOn, int Bound, int Writing,
                                              uint FramesWritten, uint Writes, uint Drops, uint Samples);

/// <summary>One inbound NPC sample, as the agent hands it to the DLL.</summary>
public readonly record struct NativeNpcSample(byte Src, string Name, float X, float Y, float Z, float Rot,
                                              byte Flags, ushort Seq, uint SenderMs, long ArrivalQpc);

/// <summary>
/// WO-118: byte layouts of the agent -&gt; DLL frames 0x10-0x15 and the 0x89
/// reply (native/KCDMP/pipe_server.h). Pure functions, unit-tested.
/// </summary>
public static class NativeNpcCodec
{
    /// <summary>The DLL accepts a 0x10 body up to this size (kNpcSamplesMaxLen).</summary>
    public const int MaxSamplesPayload = 4096;
    /// <summary>What the feed packs per frame, below the cap with room to spare.</summary>
    public const int TargetSamplesPayload = 3800;
    public const int MaxNameLen = 63;

    public static string ReasonTag(byte r) => r switch
    {
        0 => "ok", 1 => "disarmed", 2 => "toggle-off", 3 => "no-entity", 4 => "name-mismatch",
        5 => "wuid-mismatch", 6 => "not-living", 7 => "parented", 8 => "bad-request", 9 => "entity-gone",
        10 => "silence", 11 => "fault", 12 => "unbound", 13 => "table-full", 14 => "pipe-closed",
        200 => "not-connected", 201 => "no-answer", 17 => "task-faulted", 18 => "unknown-command",
        _ => $"reason-{r}",
    };

    /// <summary>Bytes one sample takes inside a 0x10 body.</summary>
    public static int SampleSize(string name) => 2 + Encoding.UTF8.GetByteCount(name) + 16 + 1 + 2 + 4 + 8;

    /// <summary>0x10: [count:1]{[src][nameLen][name][x][y][z][rot][flags][seq:2][senderMs:4][arrivalQpc:8]}*count.</summary>
    public static byte[] BuildSamples(IReadOnlyList<NativeNpcSample> samples)
    {
        if (samples.Count is 0 or > 255) throw new ArgumentOutOfRangeException(nameof(samples));
        int len = 1;
        foreach (var s in samples) len += SampleSize(s.Name);
        if (len > MaxSamplesPayload) throw new ArgumentException($"0x10 body {len} B exceeds {MaxSamplesPayload}");
        var b = new byte[len];
        b[0] = (byte)samples.Count;
        int o = 1;
        foreach (var s in samples)
        {
            var name = Encoding.UTF8.GetBytes(s.Name);
            if (name.Length is 0 or > MaxNameLen) throw new ArgumentException("bad name length");
            b[o++] = s.Src;
            b[o++] = (byte)name.Length;
            name.CopyTo(b, o); o += name.Length;
            BinaryPrimitives.WriteSingleLittleEndian(b.AsSpan(o), s.X); o += 4;
            BinaryPrimitives.WriteSingleLittleEndian(b.AsSpan(o), s.Y); o += 4;
            BinaryPrimitives.WriteSingleLittleEndian(b.AsSpan(o), s.Z); o += 4;
            BinaryPrimitives.WriteSingleLittleEndian(b.AsSpan(o), s.Rot); o += 4;
            b[o++] = s.Flags;
            BinaryPrimitives.WriteUInt16LittleEndian(b.AsSpan(o), s.Seq); o += 2;
            BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(o), s.SenderMs); o += 4;
            BinaryPrimitives.WriteInt64LittleEndian(b.AsSpan(o), s.ArrivalQpc); o += 8;
        }
        return b;
    }

    /// <summary>0x11: [on:1][eid:4][wuid:8][ax:4f][ay:4f][az:4f][delayMs:2][nameLen:1][name].</summary>
    public static byte[] BuildBind(bool on, uint eid, ulong wuid, float ax, float ay, float az, ushort delayMs, string name)
    {
        var n = Encoding.UTF8.GetBytes(name);
        if (n.Length is 0 or > MaxNameLen) throw new ArgumentException("bad name length");
        var b = new byte[28 + n.Length];
        b[0] = on ? (byte)1 : (byte)0;
        BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(1), eid);
        BinaryPrimitives.WriteUInt64LittleEndian(b.AsSpan(5), wuid);
        BinaryPrimitives.WriteSingleLittleEndian(b.AsSpan(13), ax);
        BinaryPrimitives.WriteSingleLittleEndian(b.AsSpan(17), ay);
        BinaryPrimitives.WriteSingleLittleEndian(b.AsSpan(21), az);
        BinaryPrimitives.WriteUInt16LittleEndian(b.AsSpan(25), delayMs);
        b[27] = (byte)n.Length;
        n.CopyTo(b, 28);
        return b;
    }

    /// <summary>0x12: [ms:2][nameLen:1][name].</summary>
    public static byte[] BuildHold(string name, ushort ms)
    {
        var n = Encoding.UTF8.GetBytes(name);
        if (n.Length is 0 or > MaxNameLen) throw new ArgumentException("bad name length");
        var b = new byte[3 + n.Length];
        BinaryPrimitives.WriteUInt16LittleEndian(b, ms);
        b[2] = (byte)n.Length;
        n.CopyTo(b, 3);
        return b;
    }

    /// <summary>0x15: [seconds:2][nameLen:1][name].</summary>
    public static byte[] BuildTrace(string name, ushort seconds) => BuildHold(name, seconds);

    /// <summary>0x89: [ok][seq][armed][nativeOn][bound:2][writing:2][frames:4][writes:4][drops:4][samples:4].</summary>
    public static bool TryParseStatus(byte[]? body, out NativeNpcStatus st)
    {
        st = default;
        if (body is null || body.Length < 24 || body[0] != 1) return false;
        st = new NativeNpcStatus(body[2] != 0, body[3] != 0,
            BinaryPrimitives.ReadUInt16LittleEndian(body.AsSpan(4)),
            BinaryPrimitives.ReadUInt16LittleEndian(body.AsSpan(6)),
            BinaryPrimitives.ReadUInt32LittleEndian(body.AsSpan(8)),
            BinaryPrimitives.ReadUInt32LittleEndian(body.AsSpan(12)),
            BinaryPrimitives.ReadUInt32LittleEndian(body.AsSpan(16)),
            BinaryPrimitives.ReadUInt32LittleEndian(body.AsSpan(20)));
        return true;
    }

    /// <summary>
    /// Pack as many queued samples as fit one 0x10 body (<see cref="TargetSamplesPayload"/>,
    /// at most 255). Returns how many were consumed from the front of <paramref name="pending"/>.
    /// </summary>
    public static int TakeBatch(List<NativeNpcSample> pending, List<NativeNpcSample> batch)
    {
        batch.Clear();
        int len = 1;
        foreach (var s in pending)
        {
            int sz = SampleSize(s.Name);
            if (batch.Count == 255 || (batch.Count > 0 && len + sz > TargetSamplesPayload)) break;
            batch.Add(s);
            len += sz;
        }
        return batch.Count;
    }
}

/// <summary>
/// WO-118 Phase 1: every inbound NPC sample goes to the DLL as well as to Lua.
/// The relay reader enqueues without waiting; one background loop packs what
/// accumulated into 0x10 frames (the pipe is one request/reply channel, so a
/// frame per sample would queue behind every swing and scan). Arrival times
/// are the agent's own QPC stamps -- the DLL reads the same clock -- so pipe
/// queueing never shifts a sample on the sender-clock timeline.
/// </summary>
public sealed class NativeNpcFeed
{
    private readonly CombatPipe _pipe;
    private readonly Channel<NativeNpcSample> _queue = Channel.CreateBounded<NativeNpcSample>(
        new BoundedChannelOptions(8192) { FullMode = BoundedChannelFullMode.DropOldest, SingleReader = true, SingleWriter = false });
    private Task? _loop;
    private readonly CancellationTokenSource _cts = new();

    /// <summary>Mirrors the mod's mp_npc_native_write (default on). Off: nothing is forwarded.</summary>
    public volatile bool Enabled = true;

    public long Enqueued, Sent, Batches, FailedBatches, DroppedNotConnected;

    public NativeNpcFeed(CombatPipe pipe) { _pipe = pipe; }

    public void Enqueue(in NativeNpcSample s)
    {
        if (!Enabled) return;
        if (!_pipe.IsConnected) { Interlocked.Increment(ref DroppedNotConnected); return; }
        if (Encoding.UTF8.GetByteCount(s.Name) is 0 or > NativeNpcCodec.MaxNameLen) return;
        _loop ??= Task.Run(() => LoopAsync(_cts.Token));
        if (_queue.Writer.TryWrite(s)) Interlocked.Increment(ref Enqueued);
    }

    private async Task LoopAsync(CancellationToken ct)
    {
        var pending = new List<NativeNpcSample>(512);
        var batch = new List<NativeNpcSample>(128);
        while (!ct.IsCancellationRequested)
        {
            try
            {
                if (!await _queue.Reader.WaitToReadAsync(ct)) return;
                while (_queue.Reader.TryRead(out var s)) pending.Add(s);
                while (pending.Count > 0)
                {
                    int n = NativeNpcCodec.TakeBatch(pending, batch);
                    if (n == 0) { pending.Clear(); break; }
                    var payload = NativeNpcCodec.BuildSamples(batch);
                    pending.RemoveRange(0, n);
                    var r = await _pipe.NpcSamplesAsync(payload, ct);
                    Interlocked.Increment(ref Batches);
                    if (r.Ok) Interlocked.Add(ref Sent, n); else Interlocked.Increment(ref FailedBatches);
                }
            }
            catch (OperationCanceledException) { return; }
            catch (Exception ex)
            {
                Console.WriteLine($"[npcwrite] sample feed error: {ex.GetType().Name}: {ex.Message}");
                pending.Clear();
                await Task.Delay(100, ct).ContinueWith(_ => { });
            }
        }
    }

    public static long Now() => Stopwatch.GetTimestamp();
}

/// <summary>
/// WO-118 follow-up: which NpcState samples go to Lua, for puppets the DLL
/// writes. Always for an unbound puppet; for a bound one the latest sample at
/// most every interval, and at once whenever its flags or its health (to the
/// 0.1 Lua is sent) changed. A skipped sample waits as the pending latest and
/// <see cref="TakeDue"/> hands it out when due -- at once when its puppet is no
/// longer bound (Lua writes it again and must start from the latest).
/// Single-threaded by design: GameBridge calls it from its frame processor only.
/// </summary>
public sealed class NpcLuaCoalescer(long intervalTicks)
{
    private sealed class State { public long LastPushAt; public byte LastFlags; public float LastHp; public string? Pending; }
    private readonly Dictionary<string, State> _st = new(StringComparer.Ordinal);

    public long Pushed { get; private set; }
    public long Coalesced { get; private set; }
    public int Tracked => _st.Count;

    public void Clear() => _st.Clear();

    /// <summary>True when <paramref name="lua"/> should be sent now.</summary>
    public bool Offer(string npc, bool bound, byte flags, float hp, long now, string lua)
    {
        if (!bound)
        {
            _st.Remove(npc);   // anything pending is older than this sample
            Pushed++;
            return true;
        }
        float hp1 = MathF.Round(hp, 1);
        if (!_st.TryGetValue(npc, out var st))
        {
            _st[npc] = new State { LastPushAt = now, LastFlags = flags, LastHp = hp1 };
            Pushed++;
            return true;
        }
        if (flags != st.LastFlags || hp1 != st.LastHp || now - st.LastPushAt >= intervalTicks)
        {
            st.LastPushAt = now; st.LastFlags = flags; st.LastHp = hp1; st.Pending = null;
            Pushed++;
            return true;
        }
        st.Pending = lua;
        Coalesced++;
        return false;
    }

    /// <summary>The pending pushes due at <paramref name="now"/>, oldest decision first; null when none.</summary>
    public List<string>? TakeDue(Func<string, bool> isBound, long now)
    {
        List<string>? due = null, gone = null;
        foreach (var (npc, st) in _st)
        {
            bool bound = isBound(npc);
            if (st.Pending is string lua && (!bound || now - st.LastPushAt >= intervalTicks))
            {
                (due ??= new()).Add(lua);
                st.Pending = null; st.LastPushAt = now;
                Pushed++;
            }
            if (!bound) (gone ??= new()).Add(npc);
        }
        if (gone is not null) foreach (var n in gone) _st.Remove(n);
        return due;
    }
}
