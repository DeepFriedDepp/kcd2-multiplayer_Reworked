using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Text;
using KcdMp.Client;
using KcdMp.Server;
using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.Hosting;

namespace KcdMp.Relay.Tests;

// =============================================================================
// WO-101: THE RELAY ROUND-TRIP GATE. THIS IS A PRE-SHIP GATE, NOT AN OPTIONAL
// SUITE.
//
// Why it exists: 0.23.1 added five body-state bytes to the Position packet
// (WO-100.5). The agent's encoder, the agent's decoder and 111 unit tests all
// agreed with each other. The relay -- the one hop between two machines -- had
// an exact-length gate that took only the OLD length, and dropped every live
// packet without a log line. Two players could not see each other move
// (docs/WO-101-findings.md S0). Codec unit tests do not prove a packet crosses
// the wire. Only this does.
//
// What it does: hosts the REAL relay (KcdMp.Server, Program.CreateApp -- the
// same DI graph Main runs) on a loopback port, connects real TCP peers that
// speak the real handshake, sends packets built by the SHIPPED agent code
// (PositionCodec, ActionOutbox) and decodes what arrives with the shipped agent
// code (PositionCodec, ActionInbox). If a field does not survive, this fails.
//
// The rule this enforces, and which tools/Build-Installer.ps1 runs before it
// publishes anything: ANY CHANGE TO A PACKET'S SHAPE -- a new flag, a new
// optional tail, a second valid length -- MUST GAIN A CASE HERE AND PASS
// BEFORE A BUILD SHIPS. Both the old length and the new one must round-trip,
// because mixed-version degradation is designed behaviour, not an accident.
// =============================================================================

/// <summary>One real relay, started once per test class, on free loopback ports.</summary>
public sealed class RelayFixture : IAsyncLifetime
{
    public int TcpPort { get; private set; }
    private WebApplication? _app;

    public async Task InitializeAsync()
    {
        TcpPort = FreePort();
        int httpPort = FreePort();
        _app = Program.CreateApp(new[]
        {
            "--port", TcpPort.ToString(),
            "--Urls", $"http://127.0.0.1:{httpPort}",
            // Keep the relay's rolling file sink out of the test tree.
            "--Serilog:WriteTo:1:Name", "Console",
        });
        await _app.StartAsync();

        // TcpSocketService binds inside its own background task; wait for it.
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (true)
        {
            try
            {
                using var probe = new TcpClient();
                await probe.ConnectAsync(IPAddress.Loopback, TcpPort);
                return;
            }
            catch (SocketException) when (DateTime.UtcNow < deadline)
            {
                await Task.Delay(50);
            }
        }
    }

    public async Task DisposeAsync()
    {
        if (_app is null) return;
        await _app.StopAsync();
        await _app.DisposeAsync();
    }

    private static int FreePort()
    {
        var l = new TcpListener(IPAddress.Loopback, 0);
        l.Start();
        int port = ((IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return port;
    }
}

/// <summary>
/// A real TCP peer of the relay. Speaks the same handshake bytes GameBridge
/// writes ([0x00][len:2][version][nameLen][name][release]) and reads the Ack.
/// </summary>
public sealed class Peer : IAsyncDisposable
{
    private readonly TcpClient _tcp = new();
    private NetworkStream _stream = null!;
    public byte Id { get; private set; }

    public static async Task<Peer> ConnectAsync(int port, string name)
    {
        var p = new Peer();
        await p._tcp.ConnectAsync(IPAddress.Loopback, port);
        p._stream = p._tcp.GetStream();

        var nameBytes = Encoding.UTF8.GetBytes(name);
        var rel = Encoding.UTF8.GetBytes(ReleaseVersionInfo.Current);
        int len = 2 + nameBytes.Length + rel.Length;
        var hs = new byte[3 + len];
        hs[0] = Protocol.Handshake;
        BinaryPrimitives.WriteUInt16LittleEndian(hs.AsSpan(1), (ushort)len);
        hs[3] = Protocol.Version;
        hs[4] = (byte)nameBytes.Length;
        nameBytes.CopyTo(hs, 5);
        rel.CopyTo(hs, 5 + nameBytes.Length);
        await p._stream.WriteAsync(hs);

        var (type, payload) = await p.ReadPacketAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(Protocol.Ack, type);
        p.Id = payload[0];
        return p;
    }

    public async Task SendRawAsync(byte[] packet)
    {
        await _stream.WriteAsync(packet);
        await _stream.FlushAsync();
    }

    /// <summary>Reads one framed packet: [type:1][len:2][payload].</summary>
    public async Task<(byte Type, byte[] Payload)> ReadPacketAsync(TimeSpan timeout)
    {
        using var cts = new CancellationTokenSource(timeout);
        var header = new byte[3];
        await ReadExactAsync(header, cts.Token);
        int len = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(1));
        var payload = new byte[len];
        await ReadExactAsync(payload, cts.Token);
        return (header[0], payload);
    }

    /// <summary>
    /// Reads until a packet of <paramref name="wanted"/> arrives, skipping the
    /// relay's own chatter (Name, ReleaseVersion, CombatRole, ...).
    /// </summary>
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

    /// <summary>True if NO packet of <paramref name="type"/> arrives within the window.</summary>
    public async Task<bool> NoneOfAsync(byte type, TimeSpan window)
    {
        try { await ReadUntilAsync(type, window); return false; }
        catch (TimeoutException) { return true; }
        catch (OperationCanceledException) { return true; }
    }

    private async Task ReadExactAsync(byte[] buf, CancellationToken ct)
    {
        int got = 0;
        while (got < buf.Length)
        {
            int n = await _stream.ReadAsync(buf.AsMemory(got), ct);
            if (n <= 0) throw new EndOfStreamException();
            got += n;
        }
    }

    public ValueTask DisposeAsync()
    {
        _tcp.Dispose();
        return ValueTask.CompletedTask;
    }
}

public class RelayRoundTripTests : IClassFixture<RelayFixture>
{
    private static readonly TimeSpan Wait = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan Quiet = TimeSpan.FromMilliseconds(400);
    private readonly RelayFixture _relay;

    public RelayRoundTripTests(RelayFixture relay) => _relay = relay;

    private async Task<(Peer A, Peer B)> TwoPeersAsync()
    {
        var a = await Peer.ConnectAsync(_relay.TcpPort, "alpha");
        var b = await Peer.ConnectAsync(_relay.TcpPort, "bravo");
        // Let the relay finish both ready-handshakes before anything is sent,
        // otherwise a Position from A can race B's TryMarkReady and be
        // (correctly) not forwarded.
        await Task.Delay(100);
        return (a, b);
    }

    // ---- Position 0x01 -> Ghost 0x02 -------------------------------------

    [Fact]
    public async Task V2_position_with_body_state_arrives_intact()
    {
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        var body = new BodyState(BodyPace.Run, BodyDir.Forward, BodyStance.Upright, 12345);
        var pkt = PositionCodec.BuildPosition(2340.12f, 2047.04f, 109.17f, 1.68f, isRiding: false, stale: false, body);
        Assert.Equal(3 + Protocol.PositionPayloadLenV2, pkt.Length);   // this IS the 0.23.1 live packet
        await a.SendRawAsync(pkt);

        var ghost = await b.ReadUntilAsync(Protocol.Ghost, Wait);
        Assert.Equal(Protocol.GhostPayloadLenV2, ghost.Length);
        Assert.True(PositionCodec.TryDecodeGhost(ghost, out var g));
        Assert.Equal(a.Id, g.GhostId);
        Assert.Equal(2340.12f, g.X); Assert.Equal(2047.04f, g.Y); Assert.Equal(109.17f, g.Z);
        Assert.Equal(1.68f, g.RotZ);
        Assert.False(g.IsRiding); Assert.False(g.IsStale);
        Assert.False(g.BodyStateShort);
        Assert.Equal(body, g.Body);   // pace, dir, stance, animSpeedCenti -- all five bytes
    }

    [Fact]
    public async Task Old_length_position_still_round_trips()
    {
        // The negative: a pre-WO-100.5 sender, or a body-state miss, sends 17
        // bytes. Mixed-version degradation is designed, so this must keep working.
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        var pkt = PositionCodec.BuildPosition(1f, 2f, 3f, 0.5f, isRiding: true, stale: false, body: null);
        Assert.Equal(3 + Protocol.PositionPayloadLen, pkt.Length);
        await a.SendRawAsync(pkt);

        var ghost = await b.ReadUntilAsync(Protocol.Ghost, Wait);
        Assert.Equal(Protocol.GhostPayloadLen, ghost.Length);
        Assert.True(PositionCodec.TryDecodeGhost(ghost, out var g));
        Assert.Equal(a.Id, g.GhostId);
        Assert.Equal((1f, 2f, 3f, 0.5f), (g.X, g.Y, g.Z, g.RotZ));
        Assert.True(g.IsRiding);
        Assert.Null(g.Body);
        Assert.False(g.BodyStateShort);
    }

    [Fact]
    public async Task Stale_heartbeat_round_trips_with_its_flag()
    {
        // The one path that DID work in 0.23.1 (the STALE heartbeat is bodiless).
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        await a.SendRawAsync(PositionCodec.BuildPosition(9f, 8f, 7f, 0f, isRiding: false, stale: true, body: null));
        var ghost = await b.ReadUntilAsync(Protocol.Ghost, Wait);
        Assert.True(PositionCodec.TryDecodeGhost(ghost, out var g));
        Assert.True(g.IsStale);
        Assert.Null(g.Body);
    }

    [Fact]
    public async Task Wrong_length_position_is_dropped_and_framing_survives()
    {
        // 20 bytes is neither length. The relay must skip it AND stay in frame,
        // so the valid packet right behind it still arrives -- and only that one.
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        var bad = new byte[3 + 20];
        bad[0] = Protocol.Position;
        BinaryPrimitives.WriteUInt16LittleEndian(bad.AsSpan(1), 20);
        await a.SendRawAsync(bad);
        await a.SendRawAsync(PositionCodec.BuildPosition(5f, 5f, 5f, 0f, false, false, null));

        var ghost = await b.ReadUntilAsync(Protocol.Ghost, Wait);
        Assert.True(PositionCodec.TryDecodeGhost(ghost, out var g));
        Assert.Equal(5f, g.X);
        Assert.True(await b.NoneOfAsync(Protocol.Ghost, Quiet));
    }

    [Fact]
    public async Task Sender_does_not_receive_its_own_ghost()
    {
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        await a.SendRawAsync(PositionCodec.BuildPosition(1f, 1f, 1f, 0f, false, false,
            new BodyState(BodyPace.Walk, BodyDir.Left, BodyStance.Stealth, 1)));
        _ = await b.ReadUntilAsync(Protocol.Ghost, Wait);
        Assert.True(await a.NoneOfAsync(Protocol.Ghost, Quiet));
    }

    // ---- Action channel 0x3B -> 0x3C -------------------------------------

    [Fact]
    public async Task Action_with_payload_arrives_intact()
    {
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        var outbox = new ActionOutbox();
        var inbox = new ActionInbox();
        var payload = new AttackPayload(1, 2, 1, AttackPayload.FlagPrepared);
        var up = outbox.Build(ActionKind.Attack, ActionPhase.Commit, payload.ToBytes());
        await a.SendRawAsync(up);

        var down = await b.ReadUntilAsync(Protocol.ActionDown, Wait);
        Assert.Equal(1 + up.Length - 3, down.Length);
        var accepted = inbox.Accept(down, out var reject);
        Assert.Equal(ActionReject.None, reject);
        Assert.NotNull(accepted);
        Assert.Equal(a.Id, accepted!.Value.SourceGhostId);
        Assert.Equal(ActionKind.Attack, accepted.Value.Kind);
        Assert.Equal(ActionPhase.Commit, accepted.Value.Phase);
        Assert.Equal(payload, AttackPayload.FromBytes(accepted.Value.Payload));
    }

    [Fact]
    public async Task Action_with_empty_payload_arrives()
    {
        // The other valid length: header only (ActionUpHeaderLen), len byte 0.
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        var up = new ActionOutbox().Build(ActionKind.Attack, ActionPhase.Complete, ReadOnlySpan<byte>.Empty);
        Assert.Equal(3 + Protocol.ActionUpHeaderLen, up.Length);
        await a.SendRawAsync(up);

        var down = await b.ReadUntilAsync(Protocol.ActionDown, Wait);
        var accepted = new ActionInbox().Accept(down, out var reject);
        Assert.Equal(ActionReject.None, reject);
        Assert.NotNull(accepted);
        Assert.Empty(accepted!.Value.Payload);
        Assert.Equal(ActionPhase.Complete, accepted.Value.Phase);
    }

    [Fact]
    public async Task Action_whose_len_byte_lies_is_dropped()
    {
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        var up = new ActionOutbox().Build(ActionKind.Attack, ActionPhase.Press, new byte[] { 1, 2, 3, 4 });
        up[3 + Protocol.ActionUpHeaderLen - 1] = 9;   // claims 9 payload bytes, carries 4
        await a.SendRawAsync(up);
        Assert.True(await b.NoneOfAsync(Protocol.ActionDown, Quiet));
    }

    // ---- CombatEvent 0x2C -> 0x2D (the other multi-length pair) ----------

    [Theory]
    [InlineData(1)]
    [InlineData(3)]
    public async Task Combat_event_round_trips_in_both_lengths(int len)
    {
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        var pkt = new byte[3 + len];
        pkt[0] = Protocol.CombatEventUp;
        BinaryPrimitives.WriteUInt16LittleEndian(pkt.AsSpan(1), (ushort)len);
        for (int i = 0; i < len; i++) pkt[3 + i] = (byte)(0x40 + i);
        await a.SendRawAsync(pkt);

        var down = await b.ReadUntilAsync(Protocol.CombatEventDown, Wait);
        Assert.Equal(1 + len, down.Length);
        Assert.Equal(a.Id, down[0]);
        for (int i = 0; i < len; i++) Assert.Equal((byte)(0x40 + i), down[1 + i]);
    }
}
