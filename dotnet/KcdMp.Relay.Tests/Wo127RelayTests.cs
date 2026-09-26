using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Text;
using KcdMp.Client;
using KcdMp.Server.Features.ClientHandling;
using Microsoft.Extensions.DependencyInjection;

namespace KcdMp.Relay.Tests;

// =============================================================================
// WO-127: the connection test, the HOST CLAIM bit, and a Steam session (a
// ClientSession over a non-loopback stream, exactly what SteamRelayService
// builds from a SteamConnectionStream) against the REAL relay.
// =============================================================================

/// <summary>A peer on a synthetic "Steam" stream: the relay sees a non-loopback RelayConnection.</summary>
public sealed class SteamShapedPeer : IAsyncDisposable
{
    private TcpClient _near = null!, _far = null!;
    private NetworkStream _s = null!;
    public byte Id { get; private set; }

    public static async Task<SteamShapedPeer> ConnectAsync(IServiceProvider relay, string name)
    {
        var p = new SteamShapedPeer();
        var l = new TcpListener(IPAddress.Loopback, 0);
        l.Start();
        p._near = new TcpClient();
        var accept = l.AcceptTcpClientAsync();
        await p._near.ConnectAsync(IPAddress.Loopback, ((IPEndPoint)l.LocalEndpoint).Port);
        p._far = await accept;
        l.Stop();
        var far = p._far;
        // The relay end: marked non-loopback and "steam", as RelayConnection.FromSteam does.
        var conn = new RelayConnection(far.GetStream(), "steam-peer", isLoopback: false, "steam", far.Dispose);
        var runner = relay.GetRequiredService<ClientSessionRunner>();
        runner.Start(runner.Create(conn));

        p._s = p._near.GetStream();
        await p._s.WriteAsync(RelayConnector.BuildHandshake(name, ReleaseVersionInfo.Current));
        var (type, body) = await p.ReadPacketAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(Protocol.Ack, type);
        p.Id = body[0];
        return p;
    }

    public Task SendRawAsync(byte[] packet) => _s.WriteAsync(packet).AsTask();

    public async Task<(byte Type, byte[] Payload)> ReadPacketAsync(TimeSpan timeout)
    {
        using var cts = new CancellationTokenSource(timeout);
        return await RelayConnector.ReadFrameAsync(_s, cts.Token);
    }

    public async Task<byte[]> ReadUntilAsync(byte wanted, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (true)
        {
            var remaining = deadline - DateTime.UtcNow;
            if (remaining <= TimeSpan.Zero) throw new TimeoutException($"no 0x{wanted:X2} within {timeout}");
            var (type, payload) = await ReadPacketAsync(remaining);
            if (type == wanted) return payload;
        }
    }

    public ValueTask DisposeAsync()
    {
        _near.Dispose();
        _far.Dispose();
        return ValueTask.CompletedTask;
    }
}

public class Wo127RelayTests : IClassFixture<RelayFixture>
{
    private static readonly TimeSpan Wait = TimeSpan.FromSeconds(5);
    private readonly RelayFixture _relay;

    public Wo127RelayTests(RelayFixture relay) => _relay = relay;

    private ClientHandler Clients => _relay.Services.GetRequiredService<ClientHandler>();

    private static byte[] Position(bool claim) =>
        PositionCodec.BuildPosition(1f, 2f, 3f, 0.5f, false, false, null, 1234u, hostClaim: claim);

    /// <summary>Reads CombatRole packets until one says <paramref name="want"/> (the relay may send several as peers come and go).</summary>
    private static async Task<bool> RoleBecomesAsync(Func<TimeSpan, Task<byte[]>> readRole, bool want)
    {
        var until = DateTime.UtcNow + Wait;
        while (DateTime.UtcNow < until)
        {
            try
            {
                var p = await readRole(until - DateTime.UtcNow);
                if ((p[0] == 1) == want) return true;
            }
            catch (TimeoutException) { return false; }
            catch (OperationCanceledException) { return false; }
        }
        return false;
    }

    private async Task WaitNoClientsAsync()
    {
        var until = DateTime.UtcNow + Wait;
        while (Clients.ReadyClientCount > 0 && DateTime.UtcNow < until) await Task.Delay(50);
    }

    [Fact]
    public async Task Connection_test_is_answered_and_never_becomes_a_session()
    {
        await WaitNoClientsAsync();
        var (probe, type, payload) = await Peer.ConnectRawAsync(_relay.TcpPort, "connection-test", Protocol.ConnectionTestRelease, Protocol.Version);
        await using (probe)
        {
            Assert.Equal(Protocol.ReleaseVersionMismatch, type);
            var r = ConnectionTestReply.Decode(payload);
            Assert.Equal(ReleaseVersionInfo.Current, r.Release);
            Assert.True(r.HasDetail);
            Assert.False(r.HostConnected);
            Assert.Equal(0, r.Ready);
        }
        Assert.Equal(0, Clients.ReadyClientCount);

        // With the host's own agent connected (loopback), the test says so.
        await using var host = await Peer.ConnectAsync(_relay.TcpPort, "host");
        var (probe2, type2, payload2) = await Peer.ConnectRawAsync(_relay.TcpPort, "connection-test", Protocol.ConnectionTestRelease, Protocol.Version);
        await using (probe2)
        {
            Assert.Equal(Protocol.ReleaseVersionMismatch, type2);
            var r2 = ConnectionTestReply.Decode(payload2);
            Assert.True(r2.HostConnected);
            Assert.Equal(1, r2.Ready);
        }
        Assert.Equal(1, Clients.ReadyClientCount);
    }

    [Fact]
    public void A_pre_wo127_release_reply_decodes_as_release_only()
    {
        var r = ConnectionTestReply.Decode(Encoding.UTF8.GetBytes("0.28.3"));
        Assert.Equal("0.28.3", r.Release);
        Assert.False(r.HasDetail);
        var r2 = ConnectionTestReply.Decode(ConnectionTestReply.BuildPayload("0.29.9", 2, true));
        Assert.Equal(("0.29.9", 2, true, true), (r2.Release, r2.Ready, r2.HostConnected, r2.HasDetail));
    }

    [Fact]
    public async Task A_refused_release_is_recorded_for_the_hosts_launcher()
    {
        var (p, type, _) = await Peer.ConnectRawAsync(_relay.TcpPort, "old", "0.28.3", Protocol.Version);
        await using (p) Assert.Equal(Protocol.ReleaseVersionMismatch, type);
        var (rel, _) = Clients.LastRefusedRelease;
        Assert.Equal("0.28.3", rel);
    }

    [Fact]
    public async Task A_steam_session_never_takes_authority_from_the_hosts_own_agent()
    {
        await WaitNoClientsAsync();
        // The Steam joiner connects FIRST, so it holds the lowest id.
        await using var steam = await SteamShapedPeer.ConnectAsync(_relay.Services, "steam-joiner");
        await using var host = await Peer.ConnectAsync(_relay.TcpPort, "host");
        Assert.True(steam.Id < host.Id);

        // Rule 1 (relay-local): the loopback host is the authority; the Steam peer is not local.
        Assert.True(await RoleBecomesAsync(t => host.ReadUntilAsync(Protocol.CombatRole, t), true));
        Assert.True(await RoleBecomesAsync(t => steam.ReadUntilAsync(Protocol.CombatRole, t), false));

        // Same frames both ways over the Steam-shaped stream.
        await host.SendRawAsync(Position(false));
        var ghost = await steam.ReadUntilAsync(Protocol.Ghost, Wait);
        Assert.Equal(host.Id, ghost[0]);
        await steam.SendRawAsync(Position(false));
        var ghost2 = await host.ReadUntilAsync(Protocol.Ghost, Wait);
        Assert.Equal(steam.Id, ghost2[0]);
    }

    [Fact]
    public async Task With_a_remote_relay_the_claiming_host_wins_not_the_first_to_connect()
    {
        await WaitNoClientsAsync();
        // No loopback client at all: a dedicated/remote relay. The joiner connects first.
        await using var joiner = await SteamShapedPeer.ConnectAsync(_relay.Services, "joiner");
        await using var host = await SteamShapedPeer.ConnectAsync(_relay.Services, "host");
        Assert.True(joiner.Id < host.Id);
        Assert.True(await RoleBecomesAsync(t => joiner.ReadUntilAsync(Protocol.CombatRole, t), true));   // lowest id, before any claim

        await host.SendRawAsync(Position(claim: true));
        Assert.True(await RoleBecomesAsync(t => host.ReadUntilAsync(Protocol.CombatRole, t), true));
        Assert.True(await RoleBecomesAsync(t => joiner.ReadUntilAsync(Protocol.CombatRole, t), false));

        // The claim bit is the relay's alone: the joiner's Ghost of the host has it cleared.
        var ghost = await joiner.ReadUntilAsync(Protocol.Ghost, Wait);
        Assert.Equal(host.Id, ghost[0]);
        Assert.Equal(0, ghost[17] & Protocol.PositionFlagHostClaim);

        // Dropping the claim hands authority back by the old rules.
        await host.SendRawAsync(Position(claim: false));
        Assert.True(await RoleBecomesAsync(t => joiner.ReadUntilAsync(Protocol.CombatRole, t), true));
    }

    [Fact]
    public async Task A_claiming_host_keeps_authority_over_an_earlier_loopback_peer()
    {
        await WaitNoClientsAsync();
        await using var a = await Peer.ConnectAsync(_relay.TcpPort, "first");
        await using var b = await Peer.ConnectAsync(_relay.TcpPort, "claimant");
        await b.SendRawAsync(Position(claim: true));
        Assert.True(await RoleBecomesAsync(t => b.ReadUntilAsync(Protocol.CombatRole, t), true));
        Assert.True(await RoleBecomesAsync(t => a.ReadUntilAsync(Protocol.CombatRole, t), false));
    }
}
