using System.Runtime.InteropServices;
using System.Threading.Channels;

namespace KcdMp.Steam;

/// <summary>Steam's own view of a live connection (GetConnectionRealTimeStatus). Quality is 0..1, -1 unknown.</summary>
public readonly record struct SteamLinkStatus(int PingMs, float QualityLocal, float QualityRemote,
    float OutBytesPerSec, float InBytesPerSec, int SendRateBytesPerSec, int PendingReliable,
    int SentUnackedReliable, long QueueTimeUsec);

/// <summary>A P2P listen socket on one virtual port. Incoming connections are accepted as they arrive.</summary>
public sealed class SteamP2PListener : IDisposable
{
    private readonly SteamSession _session;
    private readonly Channel<SteamP2PConnection> _incoming = Channel.CreateUnbounded<SteamP2PConnection>();
    private volatile bool _closed;

    internal uint Handle { get; }
    public int VirtualPort { get; }

    internal SteamP2PListener(SteamSession session, uint handle, int virtualPort)
    {
        _session = session;
        Handle = handle;
        VirtualPort = virtualPort;
    }

    /// <summary>Called on the pump thread when a peer knocks: accept now, hand it out once connected.</summary>
    internal bool Offer(SteamP2PConnection c)
    {
        if (_closed) return false;
        int r = SteamNative.SteamAPI_ISteamNetworkingSockets_AcceptConnection(_session.Sockets, c.Handle);
        if (r != SteamNative.ResultOk)
        {
            _session.EmitLog($"steam accept refused result={r}");
            return false;
        }
        c.WhenConnected.ContinueWith(t => { if (t.Result) _incoming.Writer.TryWrite(c); }, TaskScheduler.Default);
        return true;
    }

    public ValueTask<SteamP2PConnection> AcceptAsync(CancellationToken ct) => _incoming.Reader.ReadAsync(ct);

    public void Dispose()
    {
        if (_closed) return;
        _closed = true;
        _incoming.Writer.TryComplete();
        SteamNative.SteamAPI_ISteamNetworkingSockets_CloseListenSocket(_session.Sockets, Handle);
        _session.Forget(this);
    }
}

/// <summary>
/// One ISteamNetworkingSockets connection. Messages are reliable and
/// ordered (k_nSteamNetworkingSend_ReliableNoNagle), which is the TCP
/// guarantee the protocol was written against. <see cref="GetStream"/> gives
/// the byte-stream view the agent and relay already speak.
/// </summary>
public sealed class SteamP2PConnection : IDisposable
{
    private readonly SteamSession _session;
    private readonly Channel<byte[]> _inbox = Channel.CreateUnbounded<byte[]>(new UnboundedChannelOptions { SingleReader = true, SingleWriter = true });
    private readonly TaskCompletionSource<bool> _connected = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private volatile int _state = SteamNative.StateConnecting;
    private int _closedFlag;
    private SteamConnectionStream? _stream;

    internal uint Handle { get; }
    internal ulong RemoteSteamId { get; }
    public bool Incoming { get; }

    /// <summary>ESteamNetworkingConnectionState as last reported.</summary>
    public int State => _state;
    public bool IsConnected => _state == SteamNative.StateConnected;

    /// <summary>k_ESteamNetConnectionEnd_* and Steam's own text, once closed. Safe to log (no ids).</summary>
    public int EndReason { get; private set; }
    public string EndDebug { get; private set; } = "";

    /// <summary>true once connected; false if it closed first.</summary>
    public Task<bool> WhenConnected => _connected.Task;

    public long BytesSent, BytesReceived, MessagesSent, MessagesReceived, SendRetries;

    internal SteamP2PConnection(SteamSession session, uint handle, ulong remote, bool incoming)
    {
        _session = session;
        Handle = handle;
        RemoteSteamId = remote;
        Incoming = incoming;
    }

    internal void OnState(int state, int endReason, string endDebug)
    {
        _state = state;
        switch (state)
        {
            case SteamNative.StateConnected:
                _connected.TrySetResult(true);
                break;
            case SteamNative.StateClosedByPeer:
            case SteamNative.StateProblemDetectedLocally:
                EndReason = endReason;
                EndDebug = endDebug;
                _session.EmitLog($"steam connection {(state == SteamNative.StateClosedByPeer ? "closed-by-peer" : "problem-detected-locally")} reason={endReason} debug=\"{endDebug}\"");
                Close(null);
                break;
        }
    }

    /// <summary>Pump thread: move every waiting message into the inbox.</summary>
    internal void Drain(IntPtr[] buf)
    {
        if (Volatile.Read(ref _closedFlag) != 0) return;
        while (true)
        {
            int n = SteamNative.SteamAPI_ISteamNetworkingSockets_ReceiveMessagesOnConnection(_session.Sockets, Handle, buf, buf.Length);
            if (n <= 0) return;
            for (int i = 0; i < n; i++)
            {
                IntPtr m = buf[i];
                IntPtr data = Marshal.ReadIntPtr(m, SteamNative.Msg.Data);
                int size = Marshal.ReadInt32(m, SteamNative.Msg.Size);
                var bytes = new byte[size];
                if (size > 0) Marshal.Copy(data, bytes, 0, size);
                SteamNative.SteamAPI_SteamNetworkingMessage_t_Release(m);
                MessagesReceived++;
                BytesReceived += size;
                _inbox.Writer.TryWrite(bytes);
            }
            if (n < buf.Length) return;
        }
    }

    /// <summary>
    /// Sends one reliable, ordered message. Waits (never drops) when Steam's
    /// send buffer is full: the TCP path blocks in the same place.
    /// </summary>
    public async ValueTask SendAsync(ReadOnlyMemory<byte> data, CancellationToken ct = default)
    {
        for (int off = 0; off < data.Length; )
        {
            int len = Math.Min(SteamNative.MaxMessageSize, data.Length - off);
            while (true)
            {
                if (Volatile.Read(ref _closedFlag) != 0) throw new IOException("Steam connection closed. " + EndDebug);
                int r = SendOnce(data.Slice(off, len));
                if (r == SteamNative.ResultOk) break;
                if (r == SteamNative.ResultLimitExceeded)
                {
                    Interlocked.Increment(ref SendRetries);
                    await Task.Delay(2, ct);
                    continue;
                }
                throw new IOException($"Steam send failed (EResult {r}).");
            }
            off += len;
        }
    }

    private unsafe int SendOnce(ReadOnlyMemory<byte> chunk)
    {
        fixed (byte* p = chunk.Span)
        {
            int r = SteamNative.SteamAPI_ISteamNetworkingSockets_SendMessageToConnection(
                _session.Sockets, Handle, p, (uint)chunk.Length, SteamNative.SendReliableNoNagle, out _);
            if (r == SteamNative.ResultOk)
            {
                Interlocked.Increment(ref MessagesSent);
                Interlocked.Add(ref BytesSent, chunk.Length);
            }
            return r;
        }
    }

    public ValueTask<byte[]> ReceiveAsync(CancellationToken ct) => _inbox.Reader.ReadAsync(ct);
    internal ChannelReader<byte[]> Inbox => _inbox.Reader;

    public SteamLinkStatus? RealTimeStatus()
    {
        int r = SteamNative.SteamAPI_ISteamNetworkingSockets_GetConnectionRealTimeStatus(_session.Sockets, Handle, out var s, 0, IntPtr.Zero);
        return r == SteamNative.ResultOk
            ? new SteamLinkStatus(s.Ping, s.QualityLocal, s.QualityRemote, s.OutBytesPerSec, s.InBytesPerSec,
                                  s.SendRateBytesPerSecond, s.PendingReliable, s.SentUnackedReliable, s.QueueTimeUsec)
            : null;
    }

    /// <summary>Round-trip time Steam measures itself, in ms; -1 before it knows.</summary>
    public int PingMs => RealTimeStatus()?.PingMs ?? -1;

    /// <summary>k_nSteamNetworkConnectionInfoFlags_*; Relayed (16) means through Valve's relays.</summary>
    public int InfoFlags()
    {
        var info = new byte[SteamNative.ConnInfo.Size];
        return SteamNative.SteamAPI_ISteamNetworkingSockets_GetConnectionInfo(_session.Sockets, Handle, info)
            ? BitConverter.ToInt32(info, SteamNative.ConnInfo.Flags) : -1;
    }

    public Stream GetStream() => _stream ??= new SteamConnectionStream(this);

    public void Close(string? why)
    {
        if (Interlocked.Exchange(ref _closedFlag, 1) != 0) return;
        _state = _state is SteamNative.StateClosedByPeer or SteamNative.StateProblemDetectedLocally ? _state : SteamNative.StateNone;
        // linger=true: a Close right after a final Send still delivers it, like a TCP FIN after the last write.
        SteamNative.SteamAPI_ISteamNetworkingSockets_CloseConnection(_session.Sockets, Handle, 0, why, true);
        _connected.TrySetResult(false);
        _inbox.Writer.TryComplete();
        _session.Forget(this);
    }

    public void Dispose() => Close("disposed");
}

/// <summary>
/// The byte-stream view of a Steam connection, so code written against a
/// NetworkStream carries over unchanged.
///
/// Write = one reliable message per call (the agent and relay write whole
/// frames under a lock, so a frame never straddles two writers). Read hands
/// out received bytes in order, in whatever sizes the caller asks for: the
/// reader reassembles frames exactly as it does from TCP, so a message
/// boundary is never load-bearing. Read returns 0 once the peer is gone,
/// which the existing loops already treat as end of stream.
/// </summary>
public sealed class SteamConnectionStream : Stream
{
    private readonly SteamP2PConnection _conn;
    private byte[]? _current;
    private int _offset;

    internal SteamConnectionStream(SteamP2PConnection conn) => _conn = conn;

    public SteamP2PConnection Connection => _conn;

    public override bool CanRead => true;
    public override bool CanWrite => true;
    public override bool CanSeek => false;

    /// <summary>Idle-read cutoff in ms, as NetworkStream.ReadTimeout (Timeout.Infinite = none).</summary>
    public override int ReadTimeout { get; set; } = Timeout.Infinite;
    public override int WriteTimeout { get; set; } = Timeout.Infinite;
    public override bool CanTimeout => true;

    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default)
    {
        if (buffer.Length == 0) return 0;
        while (_current is null || _offset >= _current.Length)
        {
            _current = null;
            try
            {
                if (ReadTimeout is Timeout.Infinite or <= 0)
                {
                    _current = await _conn.Inbox.ReadAsync(ct);
                }
                else
                {
                    using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                    cts.CancelAfter(ReadTimeout);
                    try { _current = await _conn.Inbox.ReadAsync(cts.Token); }
                    catch (OperationCanceledException) when (!ct.IsCancellationRequested)
                    {
                        throw new IOException("Steam read timed out.", new TimeoutException());
                    }
                }
            }
            catch (ChannelClosedException) { return 0; }
            _offset = 0;
        }
        int n = Math.Min(buffer.Length, _current.Length - _offset);
        _current.AsMemory(_offset, n).CopyTo(buffer);
        _offset += n;
        return n;
    }

    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken ct) =>
        ReadAsync(buffer.AsMemory(offset, count), ct).AsTask();

    public override int Read(byte[] buffer, int offset, int count) =>
        ReadAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();

    public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken ct = default) =>
        buffer.Length == 0 ? ValueTask.CompletedTask : _conn.SendAsync(buffer, ct);

    public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken ct) =>
        WriteAsync(buffer.AsMemory(offset, count), ct).AsTask();

    public override void Write(byte[] buffer, int offset, int count) =>
        WriteAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();

    public override void Flush() { }
    public override Task FlushAsync(CancellationToken ct) => Task.CompletedTask;

    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();

    protected override void Dispose(bool disposing)
    {
        if (disposing) _conn.Close("stream disposed");
        base.Dispose(disposing);
    }
}
