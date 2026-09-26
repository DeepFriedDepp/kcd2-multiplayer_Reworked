using System.Buffers.Binary;

namespace KcdMp.Wire;

// ---------------------------------------------------------------------------
// WO-123 -- send the world, pause the host (docs/WO-123-findings.md).
// Protocol v9 (this WO's bump also carries WO-122's WorldSaved 0x46/0x47).
//
// A join: the joiner (at the main menu) asks, the host pauses its world,
// writes a fresh world save (WO-122 Phase 4), and streams the file to the
// joiner over the relay in chunks; the joiner verifies it and later reports
// "ready" (loaded and in the world, the next WO), which unfreezes the host.
//
// Every message is between two machines. Up bodies start with the TARGET
// ghost id and the join id; the relay routes to that one peer and prefixes
// the SOURCE id, so a Down body is [sourceGhostId:1] + the Up body verbatim.
//
//   type up/down  name           up body (after [target:1][joinId:4])        sent by
//   0x48 / 0x49   JoinRequest    [flags:1]                                 (6)  joiner -> host
//   0x4A / 0x4B   WorldOffer     [size:4][chunkSize:4][chunkCount:4][sha256:32][wsSeq:4][md5:16] (69) host
//   0x4C / 0x4D   WorldChunk     [index:4][data:1..WorldChunkMaxData]   (10..32777)  host
//   0x4E / 0x4F   WorldAck       [next:4] every chunk < next is written    (9)  joiner
//   0x50 / 0x51   WorldDone      [sha256 prefix:8] hash + Verify passed   (13)  joiner
//   0x52 / 0x53   JoinAbort      [reason:1]                                (6)  either
//   0x54 / 0x55   JoinerReady    [wsSeq:4] the world it loaded             (9)  joiner
//   0x56 / 0x57   JoinStatus     [state:1][reason:1][arg:2]                (9)  host
//
// Routing (relay): the joiner's messages (request, ack, done, ready) go to
// the damage authority only -- target 0xFF means "the host" -- and are
// dropped from the authority itself; the host's (offer, chunk, status) are
// accepted only FROM the damage authority. Abort goes either way. Lengths
// come from ONE table, JoinWire, which the relay's gate and the tests read.
//
// Sizes: a frame's payload length is a u16, so a chunk is at most 32 KB of
// data; the relay's per-client queue is 512 KB and overflow disconnects the
// client (WO-110 4.4), so the sender keeps at most WorldWindowBytes (256 KB)
// unacknowledged, and the receiver acks every WorldAckEvery chunks and on
// the last one. TCP keeps the order, so chunks arrive in index order.
// ---------------------------------------------------------------------------

public static partial class Protocol
{
    public const byte JoinRequestUp   = 0x48, JoinRequestDown = 0x49;
    public const byte WorldOfferUp    = 0x4A, WorldOfferDown  = 0x4B;
    public const byte WorldChunkUp    = 0x4C, WorldChunkDown  = 0x4D;
    public const byte WorldAckUp      = 0x4E, WorldAckDown    = 0x4F;
    public const byte WorldDoneUp     = 0x50, WorldDoneDown   = 0x51;
    public const byte JoinAbortUp     = 0x52, JoinAbortDown   = 0x53;
    public const byte JoinerReadyUp   = 0x54, JoinerReadyDown = 0x55;
    public const byte JoinStatusUp    = 0x56, JoinStatusDown  = 0x57;

    /// <summary>Target id meaning "whoever holds damage authority" (the host).</summary>
    public const byte JoinTargetHost = 0xFF;

    public const int JoinHeaderLen = 1 + 4;                 // [target][joinId]
    public const int WorldChunkMaxData = 32 * 1024;
    public const int WorldWindowBytes = 256 * 1024;
    public const int WorldAckEvery = 4;
    /// <summary>A world save bigger than this is refused at the offer (late game is ~13 MB of stream, ~4 MB of file).</summary>
    public const int WorldMaxBytes = 64 * 1024 * 1024;

    public enum JoinFrom : byte { Joiner, Host, Either }

    /// <summary>
    /// THE list of WO-123 up types: their down type, exact (min..max) up body
    /// lengths and who may send them. The relay's gate reads only this.
    /// </summary>
    public static readonly (byte Up, byte Down, string Name, int Min, int Max, JoinFrom From)[] JoinWire =
    {
        (JoinRequestUp, JoinRequestDown, "join-request", JoinHeaderLen + 1, JoinHeaderLen + 1, JoinFrom.Joiner),
        (WorldOfferUp,  WorldOfferDown,  "world-offer",  JoinHeaderLen + 64, JoinHeaderLen + 64, JoinFrom.Host),
        (WorldChunkUp,  WorldChunkDown,  "world-chunk",  JoinHeaderLen + 4 + 1, JoinHeaderLen + 4 + WorldChunkMaxData, JoinFrom.Host),
        (WorldAckUp,    WorldAckDown,    "world-ack",    JoinHeaderLen + 4, JoinHeaderLen + 4, JoinFrom.Joiner),
        (WorldDoneUp,   WorldDoneDown,   "world-done",   JoinHeaderLen + 8, JoinHeaderLen + 8, JoinFrom.Joiner),
        (JoinAbortUp,   JoinAbortDown,   "join-abort",   JoinHeaderLen + 1, JoinHeaderLen + 1, JoinFrom.Either),
        (JoinerReadyUp, JoinerReadyDown, "joiner-ready", JoinHeaderLen + 4, JoinHeaderLen + 4, JoinFrom.Joiner),
        (JoinStatusUp,  JoinStatusDown,  "join-status",  JoinHeaderLen + 4, JoinHeaderLen + 4, JoinFrom.Host),
    };

    /// <summary>The JoinWire row for an up type, or null.</summary>
    public static (byte Up, byte Down, string Name, int Min, int Max, JoinFrom From)? JoinWireFor(int upType)
    {
        foreach (var r in JoinWire) if (r.Up == upType) return r;
        return null;
    }

    /// <summary>True for a WO-123 down type with a length its up row allows (+1 for the source id).</summary>
    public static bool IsJoinDown(int downType, int len)
    {
        foreach (var r in JoinWire)
            if (r.Down == downType) return len >= r.Min + 1 && len <= r.Max + 1;
        return false;
    }

    // ---- JoinAbort reasons (APPEND-ONLY) ----
    public const byte JoinAbortHostCancel = 1, JoinAbortTimeout = 2, JoinAbortHashMismatch = 3, JoinAbortVerifyFailed = 4,
                      JoinAbortSaveFailed = 5, JoinAbortIo = 6, JoinAbortProtocol = 7, JoinAbortSharedWorldOff = 8,
                      JoinAbortJoinerCancel = 9, JoinAbortHostReload = 10, JoinAbortTooBig = 11;

    public static string JoinAbortName(byte r) => r switch
    {
        JoinAbortHostCancel => "host-cancel", JoinAbortTimeout => "timeout", JoinAbortHashMismatch => "hash-mismatch",
        JoinAbortVerifyFailed => "verify-failed", JoinAbortSaveFailed => "save-failed", JoinAbortIo => "io-error",
        JoinAbortProtocol => "protocol", JoinAbortSharedWorldOff => "shared-world-off", JoinAbortJoinerCancel => "joiner-cancel",
        JoinAbortHostReload => "host-reload", JoinAbortTooBig => "too-big", _ => $"unknown-{r}",
    };

    // ---- JoinStatus states and deferral reasons (APPEND-ONLY) ----
    public const byte JoinStateDeferred = 1, JoinStatePaused = 2, JoinStateSaving = 3, JoinStateSending = 4,
                      JoinStateWaitingReady = 5, JoinStateResumed = 6, JoinStateRefused = 7;

    public static string JoinStateName(byte s) => s switch
    {
        JoinStateDeferred => "deferred", JoinStatePaused => "paused", JoinStateSaving => "saving", JoinStateSending => "sending",
        JoinStateWaitingReady => "waiting-ready", JoinStateResumed => "resumed", JoinStateRefused => "refused", _ => $"unknown-{s}",
    };

    /// <summary>Why a host defers (JoinStateDeferred) or refuses (JoinStateRefused). APPEND-ONLY.</summary>
    public static readonly string[] JoinBusyReasons =
    {
        "none", "combat", "dialogue", "cutscene", "loading", "cannot-save", "dead", "shared-world-off", "not-host",
        "another-join", "no-mod", "skip-time", "menu", "ready", "joiner-gone", "cancel", "timeout", "failed", "host-reload", "clock-sync",
    };

    public static byte JoinReasonId(string name)
    {
        int i = Array.IndexOf(JoinBusyReasons, name);
        return i < 0 ? (byte)0 : (byte)i;
    }

    public static string JoinReasonName(byte id) => id < JoinBusyReasons.Length ? JoinBusyReasons[id] : $"unknown-{id}";

    /// <summary>A framed WO-123 up packet: [type][len:2][target][joinId:4][body].</summary>
    public static byte[] BuildJoinUp(byte type, byte target, uint joinId, ReadOnlySpan<byte> body)
    {
        int len = JoinHeaderLen + body.Length;
        var p = new byte[3 + len];
        p[0] = type;
        BinaryPrimitives.WriteUInt16LittleEndian(p.AsSpan(1), (ushort)len);
        p[3] = target;
        BinaryPrimitives.WriteUInt32LittleEndian(p.AsSpan(4), joinId);
        body.CopyTo(p.AsSpan(8));
        return p;
    }

    /// <summary>Splits a WO-123 down payload into (source, target, joinId, body).</summary>
    public static bool TrySplitJoinDown(ReadOnlySpan<byte> p, out byte source, out byte target, out uint joinId, out ReadOnlySpan<byte> body)
    {
        source = target = 0; joinId = 0; body = default;
        if (p.Length < 1 + JoinHeaderLen) return false;
        source = p[0]; target = p[1];
        joinId = BinaryPrimitives.ReadUInt32LittleEndian(p[2..]);
        body = p[(1 + JoinHeaderLen)..];
        return true;
    }
}

/// <summary>WO-123: the host's offer of one world save (body after [target][joinId]).</summary>
public readonly record struct WorldOffer(int Size, int ChunkSize, int ChunkCount, byte[] Sha256, uint WorldSavedSeq, byte[] Md5)
{
    public const int BodyLen = 4 + 4 + 4 + 32 + 4 + 16;

    public byte[] Encode()
    {
        if (Sha256.Length != 32 || Md5.Length != 16) throw new ArgumentException("sha256 is 32 bytes, md5 16");
        var b = new byte[BodyLen];
        BinaryPrimitives.WriteInt32LittleEndian(b, Size);
        BinaryPrimitives.WriteInt32LittleEndian(b.AsSpan(4), ChunkSize);
        BinaryPrimitives.WriteInt32LittleEndian(b.AsSpan(8), ChunkCount);
        Sha256.CopyTo(b, 12);
        BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(44), WorldSavedSeq);
        Md5.CopyTo(b, 48);
        return b;
    }

    /// <summary>Decodes and sanity-checks an offer: sizes in range and consistent with the chunk count.</summary>
    public static WorldOffer? TryDecode(ReadOnlySpan<byte> b, out string why)
    {
        why = "";
        if (b.Length != BodyLen) { why = $"offer is {b.Length} bytes, not {BodyLen}"; return null; }
        int size = BinaryPrimitives.ReadInt32LittleEndian(b), cs = BinaryPrimitives.ReadInt32LittleEndian(b[4..]),
            n = BinaryPrimitives.ReadInt32LittleEndian(b[8..]);
        if (size <= 0) { why = "empty file"; return null; }
        if (size > Protocol.WorldMaxBytes) { why = $"{size} bytes is over the {Protocol.WorldMaxBytes} limit"; return null; }
        if (cs <= 0 || cs > Protocol.WorldChunkMaxData) { why = $"chunk size {cs} out of range"; return null; }
        if (n != (size + cs - 1) / cs) { why = $"{n} chunks do not cover {size} bytes at {cs}"; return null; }
        return new WorldOffer(size, cs, n, b.Slice(12, 32).ToArray(), BinaryPrimitives.ReadUInt32LittleEndian(b[44..]), b.Slice(48, 16).ToArray());
    }
}
