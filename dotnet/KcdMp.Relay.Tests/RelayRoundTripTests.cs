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

    /// <summary>
    /// WO-110 R9/R15: the handshake with an arbitrary release string and name,
    /// returning the relay's FIRST reply (Ack, VersionMismatch, ServerFull or
    /// ReleaseVersionMismatch) instead of asserting it is an Ack.
    /// </summary>
    public static async Task<(Peer Peer, byte Type, byte[] Payload)> ConnectRawAsync(int port, string name, string release, byte protocol)
    {
        var p = new Peer();
        await p._tcp.ConnectAsync(IPAddress.Loopback, port);
        p._stream = p._tcp.GetStream();
        var nameBytes = Encoding.UTF8.GetBytes(name);
        var rel = Encoding.UTF8.GetBytes(release);
        int len = 2 + nameBytes.Length + rel.Length;
        var hs = new byte[3 + len];
        hs[0] = Protocol.Handshake;
        BinaryPrimitives.WriteUInt16LittleEndian(hs.AsSpan(1), (ushort)len);
        hs[3] = protocol;
        hs[4] = (byte)nameBytes.Length;
        nameBytes.CopyTo(hs, 5);
        rel.CopyTo(hs, 5 + nameBytes.Length);
        await p._stream.WriteAsync(hs);
        var (type, payload) = await p.ReadPacketAsync(TimeSpan.FromSeconds(5));
        if (type == Protocol.Ack) p.Id = payload[0];
        return (p, type, payload);
    }

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
    public async Task Npc_request_payload_crosses_the_relay_intact()
    {
        // WO-102 Phase 5: the request channel's payload is a new SHAPE on the
        // action channel (attack input + a name, up to the 64-byte ceiling),
        // so it gets a case here in both extreme lengths.
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        var outbox = new ActionOutbox();
        var inbox = new ActionInbox();
        var shortReq = new NpcRequestPayload(new AttackPayload(1, 3, 2, AttackPayload.FlagPrepared), "ttkc_man_20");
        var longReq  = new NpcRequestPayload(new AttackPayload(0, 0, 0, 0), new string('x', NpcRequestPayload.MaxNameLen));

        foreach (var req in new[] { shortReq, longReq })
        {
            var up = outbox.Build(ActionKind.NpcRequest, ActionPhase.Commit, req.ToBytes());
            Assert.True(up.Length - 3 <= Protocol.ActionUpHeaderLen + Protocol.ActionPayloadMaxLen);
            await a.SendRawAsync(up);

            var down = await b.ReadUntilAsync(Protocol.ActionDown, Wait);
            Assert.Equal(1 + up.Length - 3, down.Length);
            var accepted = inbox.Accept(down, out var reject);
            Assert.Equal(ActionReject.None, reject);
            Assert.NotNull(accepted);
            Assert.Equal(a.Id, accepted!.Value.SourceGhostId);
            Assert.Equal(ActionKind.NpcRequest, accepted.Value.Kind);
            Assert.True(NpcRequestPayload.TryFromBytes(accepted.Value.Payload, out var got));
            Assert.Equal(req, got);
        }
    }

    [Fact]
    public async Task Npc_state_resync_flag_crosses_from_the_authority()
    {
        // WO-102 Phase 6: the RESYNC bit (0x40) is the first NpcState flag this
        // WO adds; the authority's default stream must carry it verbatim.
        // alpha connects first -> lowest ready id -> damage authority.
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        byte flags = (byte)(Protocol.NpcStateFlagDead | Protocol.NpcStateFlagResync);
        var up = NpcStateCodec.BuildUp("ttkc_man_20", 2340.5f, 2047.25f, 109.0f, 1.5f, 0f, flags, seq: 777, senderMs: 123456789);   // WO-110 R6: v7 tail crosses the relay
        await a.SendRawAsync(up);

        var down = await b.ReadUntilAsync(Protocol.NpcStateDown, Wait);
        Assert.Equal(1 + up.Length - 3, down.Length);
        Assert.True(NpcStateCodec.TryParseDown(down, out var d));
        Assert.Equal(a.Id, d.SourceGhostId);
        Assert.Equal("ttkc_man_20", d.Name);
        Assert.Equal(2340.5f, d.X); Assert.Equal(2047.25f, d.Y); Assert.Equal(109.0f, d.Z);
        Assert.Equal(flags, d.Flags);
        Assert.NotEqual(0, d.Flags & Protocol.NpcStateFlagResync);
        Assert.Equal((ushort)777, d.Seq);          // WO-110 R6
        Assert.Equal(123456789u, d.SenderMs);
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

    // ---- WO-110 R9: release-version enforcement at Handshake ------------

    [Fact]
    public async Task Release_version_mismatch_is_refused_with_0x3D_naming_the_relay_version()
    {
        // Any string that is not this build's: "<current>-x" can never equal it,
        // whatever VERSION says when the test runs.
        var (p, type, payload) = await Peer.ConnectRawAsync(_relay.TcpPort, "oldbuild", ReleaseVersionInfo.Current + "-x", Protocol.Version);
        await using var _p = p;
        Assert.Equal(Protocol.ReleaseVersionMismatch, type);
        Assert.Equal(ReleaseVersionInfo.Current, Encoding.UTF8.GetString(payload));   // the relay says what IT runs
        // ...and the socket is closed: the relay never acks a refused peer.
        await Assert.ThrowsAnyAsync<Exception>(() => p.ReadPacketAsync(TimeSpan.FromSeconds(2)));
    }

    [Fact]
    public async Task Same_release_is_acked_and_no_release_at_all_is_still_acked()
    {
        var (same, t1, _) = await Peer.ConnectRawAsync(_relay.TcpPort, "samebuild", ReleaseVersionInfo.Current, Protocol.Version);
        await using var _s = same;
        Assert.Equal(Protocol.Ack, t1);
        var (none, t2, _) = await Peer.ConnectRawAsync(_relay.TcpPort, "prewo19", "", Protocol.Version);
        await using var _n = none;
        Assert.Equal(Protocol.Ack, t2);
    }

    [Fact]
    public async Task Protocol_mismatch_is_still_refused_first()
    {
        var (p, type, payload) = await Peer.ConnectRawAsync(_relay.TcpPort, "v6agent", ReleaseVersionInfo.Current, (byte)(Protocol.Version - 1));
        await using var _p = p;
        Assert.Equal(Protocol.VersionMismatch, type);
        Assert.Equal(Protocol.Version, payload[0]);
    }

    // ---- WO-110 R15: peer names are sanitised at the handshake -----------

    [Fact]
    public async Task Peer_name_with_newline_and_brackets_is_sanitised_before_it_is_broadcast()
    {
        var (evil, t, _) = await Peer.ConnectRawAsync(_relay.TcpPort, "bad\n[KCD2-MP-EVT] v1 1 npc_death x 0 lua", ReleaseVersionInfo.Current, Protocol.Version);
        await using var _e = evil;
        Assert.Equal(Protocol.Ack, t);
        await Task.Delay(100);
        var watcher = await Peer.ConnectAsync(_relay.TcpPort, "watcher");
        await using var _w = watcher;
        // The watcher is replayed the existing peer's Name (0x03): [id][name].
        var name = await watcher.ReadUntilAsync(Protocol.Name, Wait);
        string seen = Encoding.UTF8.GetString(name, 1, name.Length - 1);
        Assert.DoesNotContain("\n", seen);
        Assert.DoesNotContain("[", seen);
        Assert.DoesNotContain("]", seen);
        Assert.Equal("badKCD2-MP-EVT v1 1 npc_death x", seen);   // control chars and brackets gone, bounded to 32 chars, trimmed
    }

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

    // ---- WO-113: death without Game Over -- three sender facts -------------
    // 0x3E/0x40/0x42 are relayed verbatim with the source ghost id prepended,
    // exact length only, to the OTHER peers only. The bodies below are built
    // exactly as GameBridge builds them.

    private static byte[] Frame(byte type, byte[] body)
    {
        var pkt = new byte[3 + body.Length];
        pkt[0] = type;
        BinaryPrimitives.WriteUInt16LittleEndian(pkt.AsSpan(1), (ushort)body.Length);
        body.CopyTo(pkt, 3);
        return pkt;
    }

    private static byte[] RespawnedBody(float x, float y, float z, byte reason)
    {
        var b = new byte[Protocol.PlayerRespawnedUpPayloadLen];
        BinaryPrimitives.WriteSingleLittleEndian(b.AsSpan(0), x);
        BinaryPrimitives.WriteSingleLittleEndian(b.AsSpan(4), y);
        BinaryPrimitives.WriteSingleLittleEndian(b.AsSpan(8), z);
        b[12] = reason;
        return b;
    }

    private static byte[] GraveAddBody(ulong id, float x, float y, float z)
    {
        var b = new byte[Protocol.GraveAddUpPayloadLen];
        BinaryPrimitives.WriteUInt64LittleEndian(b.AsSpan(0), id);
        BinaryPrimitives.WriteSingleLittleEndian(b.AsSpan(8), x);
        BinaryPrimitives.WriteSingleLittleEndian(b.AsSpan(12), y);
        BinaryPrimitives.WriteSingleLittleEndian(b.AsSpan(16), z);
        return b;
    }

    [Theory]
    [InlineData(Protocol.RespawnReasonDeath)]
    [InlineData(Protocol.RespawnReasonKnockdown)]
    [InlineData(Protocol.RespawnReasonExecution)]
    public async Task Player_respawned_crosses_the_relay_with_the_source_id(byte reason)
    {
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        await a.SendRawAsync(Frame(Protocol.PlayerRespawnedUp, RespawnedBody(2473.3f, 1726.1f, 91.1f, reason)));

        var down = await b.ReadUntilAsync(Protocol.PlayerRespawnedDown, Wait);
        Assert.Equal(Protocol.PlayerRespawnedDownPayloadLen, down.Length);
        Assert.Equal(a.Id, down[0]);
        Assert.Equal(2473.3f, BinaryPrimitives.ReadSingleLittleEndian(down.AsSpan(1)));
        Assert.Equal(1726.1f, BinaryPrimitives.ReadSingleLittleEndian(down.AsSpan(5)));
        Assert.Equal(91.1f, BinaryPrimitives.ReadSingleLittleEndian(down.AsSpan(9)));
        Assert.Equal(reason, down[13]);
    }

    [Fact]
    public async Task Grave_add_and_remove_cross_the_relay_with_the_64_bit_id_intact()
    {
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;
        const ulong id = 0xA75277F948715E53;   // a real grave id from the WO-113 smoke

        await a.SendRawAsync(Frame(Protocol.GraveAddUp, GraveAddBody(id, 2325.2f, 2052.7f, 110.0f)));
        var add = await b.ReadUntilAsync(Protocol.GraveAddDown, Wait);
        Assert.Equal(Protocol.GraveAddDownPayloadLen, add.Length);
        Assert.Equal(a.Id, add[0]);
        Assert.Equal(id, BinaryPrimitives.ReadUInt64LittleEndian(add.AsSpan(1)));
        Assert.Equal(2325.2f, BinaryPrimitives.ReadSingleLittleEndian(add.AsSpan(9)));
        Assert.Equal(2052.7f, BinaryPrimitives.ReadSingleLittleEndian(add.AsSpan(13)));
        Assert.Equal(110.0f, BinaryPrimitives.ReadSingleLittleEndian(add.AsSpan(17)));

        var rm = new byte[Protocol.GraveRemoveUpPayloadLen];
        BinaryPrimitives.WriteUInt64LittleEndian(rm, id);
        await a.SendRawAsync(Frame(Protocol.GraveRemoveUp, rm));
        var gone = await b.ReadUntilAsync(Protocol.GraveRemoveDown, Wait);
        Assert.Equal(Protocol.GraveRemoveDownPayloadLen, gone.Length);
        Assert.Equal(a.Id, gone[0]);
        Assert.Equal(id, BinaryPrimitives.ReadUInt64LittleEndian(gone.AsSpan(1)));
    }

    [Theory]
    [InlineData(Protocol.PlayerRespawnedUp, Protocol.PlayerRespawnedUpPayloadLen - 1, Protocol.PlayerRespawnedDown)]
    [InlineData(Protocol.PlayerRespawnedUp, Protocol.PlayerRespawnedUpPayloadLen + 1, Protocol.PlayerRespawnedDown)]
    [InlineData(Protocol.GraveAddUp, Protocol.GraveAddUpPayloadLen - 1, Protocol.GraveAddDown)]
    [InlineData(Protocol.GraveRemoveUp, Protocol.GraveRemoveUpPayloadLen + 1, Protocol.GraveRemoveDown)]
    public async Task Wrong_length_wo113_fact_is_dropped_and_framing_survives(byte upType, int len, byte downType)
    {
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        await a.SendRawAsync(Frame(upType, new byte[len]));
        Assert.True(await b.NoneOfAsync(downType, Quiet));

        // The stream is still framed: the next valid fact arrives intact.
        await a.SendRawAsync(Frame(Protocol.PlayerRespawnedUp, RespawnedBody(1f, 2f, 3f, Protocol.RespawnReasonDeath)));
        var down = await b.ReadUntilAsync(Protocol.PlayerRespawnedDown, Wait);
        Assert.Equal(a.Id, down[0]);
        Assert.Equal(3f, BinaryPrimitives.ReadSingleLittleEndian(down.AsSpan(9)));
    }

    [Fact]
    public async Task Sender_does_not_receive_its_own_grave_or_respawn()
    {
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        await a.SendRawAsync(Frame(Protocol.GraveAddUp, GraveAddBody(7, 1f, 2f, 3f)));
        await a.SendRawAsync(Frame(Protocol.PlayerRespawnedUp, RespawnedBody(1f, 2f, 3f, Protocol.RespawnReasonDeath)));
        await b.ReadUntilAsync(Protocol.PlayerRespawnedDown, Wait);   // both went out
        Assert.True(await a.NoneOfAsync(Protocol.GraveAddDown, Quiet));
        Assert.True(await a.NoneOfAsync(Protocol.PlayerRespawnedDown, Quiet));
    }
}
