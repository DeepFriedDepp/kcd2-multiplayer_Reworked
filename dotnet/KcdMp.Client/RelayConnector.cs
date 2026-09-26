using System.Buffers.Binary;
using System.Diagnostics;
using System.Net.Sockets;
using System.Text;
using KcdMp.Steam;
using KcdMp.Wire;

namespace KcdMp.Client;

/// <summary>WO-127: a failed connect, already classified for the plain message. <see cref="Detail"/> is for the log only.</summary>
public sealed class RelayConnectException(ConnectionTrouble kind, string detail, string? theirs = null, string? mine = null)
    : Exception(detail)
{
    public ConnectionTrouble Kind { get; } = kind;
    public string Detail { get; } = detail;
    public string? Theirs { get; } = theirs;
    public string? Mine { get; } = mine;
    public PlainConnectionError Plain => PlainConnectionError.For(Kind, Theirs, Mine);
}

/// <summary>WO-127: one open connection to the relay, whatever carries it.</summary>
public sealed class RelayLink : IDisposable
{
    private readonly IDisposable _owner;
    private readonly Func<bool> _isOpen;
    public Stream Stream { get; }
    /// <summary>TcpClient.Connected on TCP; the Steam connection's state on Steam.</summary>
    public bool IsOpen => _isOpen();
    /// <summary>"direct" or "steam".</summary>
    public string Via { get; }
    /// <summary>Steam's own connection, for ping/relayed; null on TCP.</summary>
    public SteamP2PConnection? Steam { get; }

    public RelayLink(Stream stream, string via, IDisposable owner, Func<bool> isOpen, SteamP2PConnection? steam = null)
    {
        Stream = stream; Via = via; _owner = owner; _isOpen = isOpen; Steam = steam;
    }

    public void Dispose()
    {
        try { _owner.Dispose(); } catch { }
    }
}

/// <summary>
/// WO-127 Phase 1: how the agent reaches the relay. Direct TCP exactly as
/// before, or Steam P2P (the host's join code) into the same frames and the
/// same protocol v9 -- the rest of the agent only ever sees a
/// <see cref="Stream"/>. Every failure is a <see cref="RelayConnectException"/>
/// with a plain-language kind; Steam's own words go through SteamLogScrub.
/// </summary>
public static class RelayConnector
{
    public static async Task<RelayLink> ConnectTcpAsync(string host, int port, TimeSpan timeout, CancellationToken ct)
    {
        var tcp = new TcpClient { NoDelay = true };   // WO-110 R6: no Nagle on the 40-byte NPC frames
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout);
        try
        {
            await tcp.ConnectAsync(host, port, cts.Token);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            tcp.Dispose();
            throw new RelayConnectException(ConnectionTrouble.TimedOut, $"TCP connect to the relay timed out after {timeout.TotalSeconds:F0} s");
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            tcp.Dispose();
            throw new RelayConnectException(PlainConnectionError.Classify(ex), $"TCP connect failed: {ex.GetType().Name}: {ex.Message}");
        }
        return new RelayLink(tcp.GetStream(), "direct", tcp, () => tcp.Connected);
    }

    /// <summary>
    /// Starts (or reuses) this process's Steam session under <paramref name="appId"/>
    /// and dials the host named by <paramref name="code"/>. Gives up after
    /// <paramref name="timeout"/> (20 s in the product: PlainConnectionError.SteamRouteTimeout).
    /// </summary>
    public static async Task<RelayLink> ConnectSteamAsync(string code, uint appId, string? gameExe, TimeSpan timeout,
        CancellationToken ct, Action<string>? log = null)
    {
        if (!SteamJoinCode.TryParse(code, out ulong host, out uint codeApp))
            throw new RelayConnectException(ConnectionTrouble.BadCode, "the Steam code does not decode");
        if (codeApp != appId)
            throw new RelayConnectException(ConnectionTrouble.AppIdMismatch,
                $"code names app {codeApp}, this launcher is set to {appId}", SteamApps.Name(codeApp), SteamApps.Name(appId));

        var session = StartSession(appId, gameExe, log);
        if (host == session.LocalSteamId)
            throw new RelayConnectException(ConnectionTrouble.OwnCode, "the code names this Steam account");
        var sw = Stopwatch.StartNew();
        // Relay network + certificate first (about 4 s cold, observed): counted inside the same limit.
        bool ready = await session.WaitNetworkReadyAsync(timeout, ct);
        log?.Invoke($"MP-CONN steam network ready={(ready ? 1 : 0)} after {sw.ElapsedMilliseconds} ms (relay={SteamSession.AvailabilityName(session.RelayAvailability(out _))})");

        SteamP2PConnection conn;
        try { conn = session.Connect(host, SteamApps.RelayVirtualPort); }
        catch (Exception ex)
        {
            throw new RelayConnectException(ConnectionTrouble.SteamNoRoute, "ConnectP2P refused: " + SteamLogScrub.Scrub(ex.Message));
        }

        var left = timeout - sw.Elapsed;
        if (left < TimeSpan.FromSeconds(1)) left = TimeSpan.FromSeconds(1);
        var done = await Task.WhenAny(conn.WhenConnected, Task.Delay(left, ct));
        if (done != conn.WhenConnected || !conn.WhenConnected.Result)
        {
            string why = conn.EndDebug is { Length: > 0 } d ? $"closed (reason {conn.EndReason}: {d})" : $"no route within {timeout.TotalSeconds:F0} s";
            conn.Close("gave up");
            ct.ThrowIfCancellationRequested();
            throw new RelayConnectException(ConnectionTrouble.SteamNoRoute, "Steam P2P " + SteamLogScrub.Scrub(why));
        }
        log?.Invoke($"MP-CONN steam connected in {sw.ElapsedMilliseconds} ms relayed={((conn.InfoFlags() & 16) != 0 ? 1 : 0)}");
        return new RelayLink(conn.GetStream(), "steam", conn, () => conn.IsConnected, conn);
    }

    /// <summary>One Steam session per process (Steam's rule); kept for the agent's lifetime once started.</summary>
    public static SteamSession StartSession(uint appId, string? gameExe, Action<string>? log)
    {
        var s = SteamSession.TryStart(appId, out var failure, out var detail, gameExe);
        if (s is null)
        {
            var kind = failure switch
            {
                SteamStartFailure.SteamNotRunning => ConnectionTrouble.SteamNotRunning,
                SteamStartFailure.NotLoggedOn => ConnectionTrouble.SteamNotLoggedIn,
                _ => ConnectionTrouble.SteamUnavailable,
            };
            throw new RelayConnectException(kind, $"Steam did not start: {failure} ({SteamLogScrub.Scrub(detail)})");
        }
        if (s.AppId != appId)
            throw new RelayConnectException(ConnectionTrouble.AppIdMismatch,
                $"this process's Steam session already runs app {s.AppId}", SteamApps.Name(appId), SteamApps.Name(s.AppId));
        if (log is not null && _logHooked is null)
        {
            _logHooked = log;
            s.Log += l => log("MP-CONN steam " + l);   // already scrubbed by SteamSession
        }
        return s;
    }

    private static Action<string>? _logHooked;

    // ------------------------------------------------------------ the handshake

    /// <summary>The Handshake frame: [protocol:1][nameLen:1][name][release].</summary>
    public static byte[] BuildHandshake(string name, string release)
    {
        var nameBytes = Encoding.UTF8.GetBytes(name);
        if (nameBytes.Length > 255)
        {
            // Trim to 255 bytes without splitting a multi-byte UTF-8 sequence.
            int len = 255;
            while (len > 0 && (nameBytes[len] & 0xC0) == 0x80) len--;
            nameBytes = nameBytes[..len];
        }
        var rel = Encoding.UTF8.GetBytes(release);
        int payloadLen = 2 + nameBytes.Length + rel.Length;
        var p = new byte[3 + payloadLen];
        p[0] = Protocol.Handshake;
        BinaryPrimitives.WriteUInt16LittleEndian(p.AsSpan(1), (ushort)payloadLen);
        p[3] = Protocol.Version;
        p[4] = (byte)nameBytes.Length;
        nameBytes.CopyTo(p, 5);
        rel.CopyTo(p, 5 + nameBytes.Length);
        return p;
    }

    public static async Task<(byte Type, byte[] Body)> ReadFrameAsync(Stream s, CancellationToken ct)
    {
        var h = new byte[3];
        await ReadExactAsync(s, h, ct);
        int len = BinaryPrimitives.ReadUInt16LittleEndian(h.AsSpan(1));
        var body = new byte[len];
        if (len > 0) await ReadExactAsync(s, body, ct);
        return (h[0], body);
    }

    private static async Task ReadExactAsync(Stream s, byte[] buf, CancellationToken ct)
    {
        int o = 0;
        while (o < buf.Length)
        {
            int n = await s.ReadAsync(buf.AsMemory(o), ct);
            if (n == 0) throw new EndOfStreamException();
            o += n;
        }
    }
}
