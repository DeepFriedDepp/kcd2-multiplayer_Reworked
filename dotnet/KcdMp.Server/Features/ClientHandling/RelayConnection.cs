using System.Net;
using System.Net.Sockets;

namespace KcdMp.Server.Features.ClientHandling;

/// <summary>
/// WO-127: one client's byte stream, whatever carries it. A TCP socket (the
/// original path, unchanged) or a Steam P2P connection
/// (KcdMp.Steam.SteamConnectionStream). ClientSession reads and writes the
/// same frames on either.
///
/// <see cref="IsLoopback"/> feeds the relay-local authority rule (WO-110 R4),
/// so it is true only for a TCP socket from a loopback address. A Steam peer
/// is never local, whatever machine it is on: a Steam joiner must not take
/// authority from the host's own agent (docs/WO-120-findings.md, "Constraint
/// found for Phase 1").
///
/// <see cref="Remote"/> is what log lines print: the TCP endpoint as before,
/// and only "steam-peer" for Steam (never a SteamID).
/// </summary>
public sealed class RelayConnection : IDisposable
{
    private readonly Action _dispose;
    private int _disposed;

    public Stream Stream { get; }
    public string Remote { get; }
    public bool IsLoopback { get; }
    public string Transport { get; }

    public RelayConnection(Stream stream, string remote, bool isLoopback, string transport, Action dispose)
    {
        Stream = stream;
        Remote = remote;
        IsLoopback = isLoopback;
        Transport = transport;
        _dispose = dispose;
    }

    public static RelayConnection FromTcp(TcpClient tcp)
    {
        var ep = tcp.Client.RemoteEndPoint;
        bool loop = ep is IPEndPoint ip && IPAddress.IsLoopback(ip.Address);
        return new RelayConnection(tcp.GetStream(), ep?.ToString() ?? "(unknown)", loop, "tcp", tcp.Dispose);
    }

    /// <summary>A Steam P2P stream: never loopback, logged without an id.</summary>
    public static RelayConnection FromSteam(Stream steamStream) =>
        new(steamStream, "steam-peer", isLoopback: false, "steam", steamStream.Dispose);

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        try { _dispose(); } catch { /* closing a dead transport */ }
    }
}
