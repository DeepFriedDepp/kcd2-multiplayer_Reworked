using System.Buffers.Binary;
using System.Security.Cryptography;

namespace KcdMp.Client;

/// <summary>
/// WO-123: the world-save transfer, both ends, with no socket in it -- the
/// agent (host and joiner) and the synthetic joiner (tools/wo118/synthpeer)
/// drive the same code, and the unit tests drive it with synthetic bytes.
///
/// Sender: one verified file, cut into <see cref="Protocol.WorldChunkMaxData"/>
/// chunks, at most <see cref="Protocol.WorldWindowBytes"/> unacknowledged.
/// Receiver: writes into a staging file in the agent's own data folder (never
/// the game's saves folder), hashes as it writes, and on the last chunk checks
/// SHA-256 against the offer, then <see cref="WhsSave.Verify"/> and the save's
/// own MD5 against the offer's. Any mismatch deletes the file. The game does
/// not check a save (WO-115 s5): these two checks are the only protection.
/// </summary>
public sealed class WorldSender
{
    private readonly byte[] _file;
    public uint JoinId { get; }
    public byte Target { get; }
    public WorldOffer Offer { get; }
    public int ChunkSize { get; }
    public int WindowBytes { get; }
    /// <summary>Index of the next chunk to send.</summary>
    public int NextToSend { get; private set; }
    /// <summary>Every chunk below this has been acknowledged.</summary>
    public int Acked { get; private set; }
    public int ChunkCount => Offer.ChunkCount;
    public long TotalBytes => _file.Length;
    public long AckedBytes => Math.Min((long)Acked * ChunkSize, _file.Length);
    public long SentBytes => Math.Min((long)NextToSend * ChunkSize, _file.Length);
    public long InFlightBytes => SentBytes - AckedBytes;
    public bool AllSent => NextToSend >= ChunkCount;
    public bool AllAcked => Acked >= ChunkCount;

    public WorldSender(byte[] file, uint joinId, byte target, uint worldSavedSeq, byte[] md5,
                       int chunkSize = Protocol.WorldChunkMaxData, int windowBytes = Protocol.WorldWindowBytes)
    {
        if (file.Length == 0) throw new ArgumentException("empty file");
        if (file.Length > Protocol.WorldMaxBytes) throw new ArgumentException($"{file.Length} bytes is over the {Protocol.WorldMaxBytes} limit");
        if (chunkSize <= 0 || chunkSize > Protocol.WorldChunkMaxData) throw new ArgumentOutOfRangeException(nameof(chunkSize));
        if (windowBytes < chunkSize) throw new ArgumentOutOfRangeException(nameof(windowBytes), "the window must hold one chunk");
        _file = file;
        JoinId = joinId;
        Target = target;
        ChunkSize = chunkSize;
        WindowBytes = windowBytes;
        int n = (file.Length + chunkSize - 1) / chunkSize;
        Offer = new WorldOffer(file.Length, chunkSize, n, SHA256.HashData(file), worldSavedSeq, md5);
    }

    public byte[] BuildOfferPacket() => Protocol.BuildJoinUp(Protocol.WorldOfferUp, Target, JoinId, Offer.Encode());

    /// <summary>The chunk packets that fit in the window now (none when it is full or everything is sent).</summary>
    public List<byte[]> TakeSendable()
    {
        var o = new List<byte[]>();
        while (NextToSend < ChunkCount)
        {
            int off = NextToSend * ChunkSize;
            int len = Math.Min(ChunkSize, _file.Length - off);
            if (InFlightBytes + len > WindowBytes) break;
            var body = new byte[4 + len];
            BinaryPrimitives.WriteUInt32LittleEndian(body, (uint)NextToSend);
            _file.AsSpan(off, len).CopyTo(body.AsSpan(4));
            o.Add(Protocol.BuildJoinUp(Protocol.WorldChunkUp, Target, JoinId, body));
            NextToSend++;
        }
        return o;
    }

    /// <summary>A cumulative ack: every chunk below <paramref name="next"/> is written. It may not go back or past what was sent.</summary>
    public bool OnAck(uint next, out string why)
    {
        why = "";
        if (next < Acked) { why = $"ack {next} goes back (was {Acked})"; return false; }
        if (next > NextToSend) { why = $"ack {next} is past the {NextToSend} chunks sent"; return false; }
        Acked = (int)next;
        return true;
    }
}

public sealed class WorldReceiver : IDisposable
{
    public enum ChunkResult { Ok, AckDue, Complete, Error }

    /// <summary>The staging file's name prefix; the sweep deletes anything carrying it.</summary>
    public const string FilePrefix = "world-";

    private FileStream? _fs;
    private readonly IncrementalHash _sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    private bool _finished;

    public uint JoinId { get; }
    public byte Host { get; }
    public WorldOffer Offer { get; }
    public string PartPath { get; }
    public string FinalPath { get; }
    public int Next { get; private set; }
    public long Received { get; private set; }
    public DateTime StartedUtc { get; } = DateTime.UtcNow;
    public double Percent => Offer.Size == 0 ? 0 : 100.0 * Received / Offer.Size;
    /// <summary>The staged file's SHA-256 once <see cref="Finish"/> ran.</summary>
    public byte[]? Sha256 { get; private set; }

    /// <summary>
    /// The agent's own data folder: %LOCALAPPDATA%\KCDMP\join-staging (the
    /// install's per-user root), never the game's saves folder -- placing the
    /// file for the game is the next WO's job. KCDMP_DATA_DIR overrides the root
    /// (tests, the synthetic joiner).
    /// </summary>
    public static string DefaultStagingDir()
    {
        string root = Environment.GetEnvironmentVariable("KCDMP_DATA_DIR") is { Length: > 0 } d
            ? d : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "KCDMP");
        return Path.Combine(root, "join-staging");
    }

    /// <summary>Deletes every staging file (an agent start, a new join). Returns how many.</summary>
    public static int SweepStaging(string dir, string? keep = null)
    {
        if (!Directory.Exists(dir)) return 0;
        int n = 0;
        foreach (var f in Directory.EnumerateFiles(dir, FilePrefix + "*"))
        {
            if (keep is not null && string.Equals(Path.GetFullPath(f), Path.GetFullPath(keep), StringComparison.OrdinalIgnoreCase)) continue;
            try { File.Delete(f); n++; } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
        return n;
    }

    public WorldReceiver(string stagingDir, uint joinId, byte host, WorldOffer offer)
    {
        JoinId = joinId;
        Host = host;
        Offer = offer;
        Directory.CreateDirectory(stagingDir);
        PartPath = Path.Combine(stagingDir, $"{FilePrefix}{joinId:x8}.part");
        FinalPath = Path.Combine(stagingDir, $"{FilePrefix}{joinId:x8}.whs");
        _fs = new FileStream(PartPath, FileMode.Create, FileAccess.Write, FileShare.Read);
    }

    /// <summary>
    /// One chunk. Chunks arrive in order (TCP, a FIFO relay); anything else, or
    /// a length that does not match the offer, is an error and the caller aborts.
    /// </summary>
    public ChunkResult Accept(uint index, ReadOnlySpan<byte> data, out string why)
    {
        why = "";
        if (_finished || _fs is null) { why = "the transfer is over"; return ChunkResult.Error; }
        if (index != (uint)Next) { why = $"chunk {index} out of order (expected {Next})"; return ChunkResult.Error; }
        long remaining = Offer.Size - Received;
        int expect = (int)Math.Min(Offer.ChunkSize, remaining);
        if (data.Length != expect) { why = $"chunk {index} is {data.Length} bytes, expected {expect}"; return ChunkResult.Error; }
        try { _fs.Write(data); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { why = "write failed: " + ex.Message; return ChunkResult.Error; }
        _sha.AppendData(data);
        Received += data.Length;
        Next++;
        if (Next == Offer.ChunkCount) return ChunkResult.Complete;
        return Next % Protocol.WorldAckEvery == 0 ? ChunkResult.AckDue : ChunkResult.Ok;
    }

    /// <summary>
    /// After the last chunk: SHA-256 against the offer, then WhsSave.Verify and
    /// the save's MD5 against the offer's. OK: the file is renamed to .whs and
    /// kept (the next WO places it). Anything else: deleted, with the abort reason.
    /// </summary>
    public (bool Ok, byte Reason, string Why) Finish()
    {
        if (_finished) return (false, Protocol.JoinAbortProtocol, "already finished");
        _finished = true;
        try { _fs?.Flush(true); } catch { }
        _fs?.Dispose();
        _fs = null;
        Sha256 = _sha.GetHashAndReset();
        if (Received != Offer.Size || Next != Offer.ChunkCount)
            return Fail(Protocol.JoinAbortProtocol, $"got {Received} of {Offer.Size} bytes");
        if (!Sha256.AsSpan().SequenceEqual(Offer.Sha256))
            return Fail(Protocol.JoinAbortHashMismatch,
                $"sha256 {Convert.ToHexString(Sha256)[..16].ToLowerInvariant()} does not match the offer's {Convert.ToHexString(Offer.Sha256)[..16].ToLowerInvariant()}");
        var v = WhsSave.VerifyFile(PartPath);
        if (!v.Ok) return Fail(Protocol.JoinAbortVerifyFailed, "WhsSave.Verify: " + v.Reason);
        if (!string.Equals(v.Md5, Convert.ToHexString(Offer.Md5), StringComparison.OrdinalIgnoreCase))
            return Fail(Protocol.JoinAbortVerifyFailed, $"the save's md5 {v.Md5[..8].ToLowerInvariant()} is not the offered world's {Convert.ToHexString(Offer.Md5)[..8].ToLowerInvariant()}");
        try
        {
            if (File.Exists(FinalPath)) File.Delete(FinalPath);
            File.Move(PartPath, FinalPath);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return Fail(Protocol.JoinAbortIo, "rename failed: " + ex.Message);
        }
        return (true, 0, "ok");
    }

    private (bool, byte, string) Fail(byte reason, string why)
    {
        DeleteFiles();
        return (false, reason, why);
    }

    /// <summary>Stops and deletes whatever was staged (an abort, a disconnect, a timeout).</summary>
    public void Abort()
    {
        _finished = true;
        try { _fs?.Dispose(); } catch { }
        _fs = null;
        DeleteFiles();
    }

    private void DeleteFiles()
    {
        foreach (var p in new[] { PartPath, FinalPath })
            try { if (File.Exists(p)) File.Delete(p); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    public byte[] BuildAck()
    {
        var b = new byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(b, (uint)Next);
        return Protocol.BuildJoinUp(Protocol.WorldAckUp, Protocol.JoinTargetHost, JoinId, b);
    }

    public byte[] BuildDone() => Protocol.BuildJoinUp(Protocol.WorldDoneUp, Protocol.JoinTargetHost, JoinId, (Sha256 ?? new byte[32]).AsSpan(0, 8));

    public static byte[] BuildAbort(byte target, uint joinId, byte reason) =>
        Protocol.BuildJoinUp(Protocol.JoinAbortUp, target, joinId, [reason]);

    public static byte[] BuildReady(uint joinId, uint worldSavedSeq)
    {
        var b = new byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(b, worldSavedSeq);
        return Protocol.BuildJoinUp(Protocol.JoinerReadyUp, Protocol.JoinTargetHost, joinId, b);
    }

    public static byte[] BuildRequest(uint joinId, byte flags = 0) =>
        Protocol.BuildJoinUp(Protocol.JoinRequestUp, Protocol.JoinTargetHost, joinId, [flags]);

    public void Dispose()
    {
        if (!_finished) Abort();
        _sha.Dispose();
    }
}

/// <summary>WO-123: JoinStatus body [state][reason][arg:u16] (arg = seconds, or percent while sending).</summary>
public static class JoinStatusCodec
{
    public static byte[] Build(byte target, uint joinId, byte state, byte reason, ushort arg)
    {
        var b = new byte[4];
        b[0] = state; b[1] = reason;
        BinaryPrimitives.WriteUInt16LittleEndian(b.AsSpan(2), arg);
        return Protocol.BuildJoinUp(Protocol.JoinStatusUp, target, joinId, b);
    }

    public static bool TryDecode(ReadOnlySpan<byte> body, out byte state, out byte reason, out ushort arg)
    {
        state = reason = 0; arg = 0;
        if (body.Length != 4) return false;
        state = body[0]; reason = body[1];
        arg = BinaryPrimitives.ReadUInt16LittleEndian(body[2..]);
        return true;
    }
}
