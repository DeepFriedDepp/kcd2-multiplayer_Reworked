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

    /// <summary>WO-127: the relay's services (ClientSessionRunner, ClientHandler) for transport-level tests.</summary>
    public IServiceProvider Services => _app!.Services;

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

    // ---- Position 0x01 -> Ghost 0x02 (protocol v8, WO-121) ----------------

    private static readonly BodyState2 SampleState2 = new(
        305, -12, BodyState2Bits.CombatMode | BodyState2Bits.BlockHeld, WireZone.UpperRight, WireGuardStance.Right,
        WireZone.Head, 0, 0, 0);

    [Fact]
    public async Task V8_position_with_state2_arrives_intact()
    {
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        var pkt = PositionCodec.BuildPosition(2340.12f, 2047.04f, 109.17f, 1.68f, isRiding: false, stale: false, SampleState2);
        Assert.Equal(3 + Protocol.PositionPayloadLenV8, pkt.Length);   // 29
        await a.SendRawAsync(pkt);

        var ghost = await b.ReadUntilAsync(Protocol.Ghost, Wait);
        Assert.Equal(Protocol.GhostPayloadLenV8, ghost.Length);        // 30
        Assert.True(PositionCodec.TryDecodeGhost(ghost, out var g));
        Assert.Equal(a.Id, g.GhostId);
        Assert.Equal(2340.12f, g.X); Assert.Equal(2047.04f, g.Y); Assert.Equal(109.17f, g.Z);
        Assert.Equal(1.68f, g.RotZ);
        Assert.False(g.IsRiding); Assert.False(g.IsStale);
        Assert.False(g.BodyStateShort);
        Assert.Equal(SampleState2, g.State2);   // all twelve bytes
        Assert.Equal(BodyPace.Run, g.Body?.Pace);   // the legacy derivation for the Lua gait path
    }

    [Fact]
    public async Task Old_length_position_still_round_trips()
    {
        // No state block this packet (change-gated), 17 bytes.
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        var pkt = PositionCodec.BuildPosition(1f, 2f, 3f, 0.5f, isRiding: true, stale: false, state2: null);
        Assert.Equal(3 + Protocol.PositionPayloadLen, pkt.Length);
        await a.SendRawAsync(pkt);

        var ghost = await b.ReadUntilAsync(Protocol.Ghost, Wait);
        Assert.Equal(Protocol.GhostPayloadLen, ghost.Length);
        Assert.True(PositionCodec.TryDecodeGhost(ghost, out var g));
        Assert.Equal(a.Id, g.GhostId);
        Assert.Equal((1f, 2f, 3f, 0.5f), (g.X, g.Y, g.Z, g.RotZ));
        Assert.True(g.IsRiding);
        Assert.Null(g.Body); Assert.Null(g.State2);
        Assert.False(g.BodyStateShort);
    }

    [Fact]
    public async Task Stale_heartbeat_round_trips_with_its_flag()
    {
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        await a.SendRawAsync(PositionCodec.BuildPosition(9f, 8f, 7f, 0f, isRiding: false, stale: true, state2: null));
        var ghost = await b.ReadUntilAsync(Protocol.Ghost, Wait);
        Assert.True(PositionCodec.TryDecodeGhost(ghost, out var g));
        Assert.True(g.IsStale);
        Assert.Null(g.State2);
    }

    [Fact]
    public async Task Wrong_length_position_is_dropped_and_framing_survives()
    {
        // 20 bytes is no accepted length. The relay must skip it AND stay in
        // frame, so the valid packet right behind it still arrives -- only that one.
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
    public async Task V7_body_state_position_is_dropped_by_a_v8_relay()
    {
        // WO-121: the WO-100.5 22/26-byte shapes are superseded. Only a v7
        // sender builds them (and the handshake refuses one); a stray one is
        // dropped whole and framing survives.
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        foreach (int len in new[] { 22, 26 })
        {
            var old = new byte[3 + len];
            old[0] = Protocol.Position;
            BinaryPrimitives.WriteUInt16LittleEndian(old.AsSpan(1), (ushort)len);
            old[3 + 16] = Protocol.PositionFlagBodyState;
            await a.SendRawAsync(old);
        }
        await a.SendRawAsync(PositionCodec.BuildPosition(6f, 6f, 6f, 0f, false, false, null));
        var ghost = await b.ReadUntilAsync(Protocol.Ghost, Wait);
        Assert.True(PositionCodec.TryDecodeGhost(ghost, out var g));
        Assert.Equal(6f, g.X);
        Assert.True(await b.NoneOfAsync(Protocol.Ghost, Quiet));
    }

    [Fact]
    public async Task Sender_does_not_receive_its_own_ghost()
    {
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        await a.SendRawAsync(PositionCodec.BuildPosition(1f, 1f, 1f, 0f, false, false, SampleState2));
        _ = await b.ReadUntilAsync(Protocol.Ghost, Wait);
        Assert.True(await a.NoneOfAsync(Protocol.Ghost, Quiet));
    }

    [Fact]
    public async Task Sender_ms_position_arrives_with_its_stamp()
    {
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        var pkt = PositionCodec.BuildPosition(2326.14f, 2050.21f, 109.06f, 0.25f, isRiding: false, stale: false,
            state2: null, senderMs: 3_000_000_123u);
        Assert.Equal(3 + Protocol.PositionPayloadLen + Protocol.SenderMsLen, pkt.Length);   // 21
        await a.SendRawAsync(pkt);

        var ghost = await b.ReadUntilAsync(Protocol.Ghost, Wait);
        Assert.Equal(Protocol.GhostPayloadLen + Protocol.SenderMsLen, ghost.Length);          // 22
        Assert.True(PositionCodec.TryDecodeGhost(ghost, out var g));
        Assert.Equal(a.Id, g.GhostId);
        Assert.Equal((2326.14f, 2050.21f, 109.06f, 0.25f), (g.X, g.Y, g.Z, g.RotZ));
        Assert.Equal(3_000_000_123u, g.SenderMs);
        Assert.Null(g.State2);
        Assert.False(g.BodyStateShort);
    }

    [Fact]
    public async Task Sender_ms_after_state2_both_arrive_intact()
    {
        // The live v8 shape: a state change and the stamp behind it. 33 up, 34 down.
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        var pkt = PositionCodec.BuildPosition(10f, 20f, 30f, -1.5f, isRiding: true, stale: false, SampleState2, senderMs: 42u);
        Assert.Equal(3 + Protocol.PositionPayloadLenV8Max, pkt.Length);                          // 33
        await a.SendRawAsync(pkt);

        var ghost = await b.ReadUntilAsync(Protocol.Ghost, Wait);
        Assert.Equal(Protocol.GhostPayloadLenV8Max, ghost.Length);                               // 34
        Assert.True(PositionCodec.TryDecodeGhost(ghost, out var g));
        Assert.Equal(SampleState2, g.State2);
        Assert.Equal(42u, g.SenderMs);
        Assert.True(g.IsRiding);
        Assert.Equal(BodyStance.Horse, g.Body?.Stance);
        Assert.False(g.BodyStateShort);
    }

    [Fact]
    public async Task Every_accepted_length_round_trips()
    {
        // All four v8 shapes through one pair of peers, one at a time.
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        var lens = new List<int>();
        for (int i = 1; i <= 4; i++)
        {
            await a.SendRawAsync(PositionCodec.BuildPosition(i, 0f, 0f, 0f, false, false,
                i is 3 or 4 ? SampleState2 : null, i is 2 or 4 ? (uint)i : null));
            var ghost = await b.ReadUntilAsync(Protocol.Ghost, Wait);
            lens.Add(ghost.Length);
            Assert.True(PositionCodec.TryDecodeGhost(ghost, out var g));
            Assert.Equal((float)i, g.X);
            Assert.Equal(i is 2 or 4 ? (uint)i : 0u, g.SenderMs);
            Assert.Equal(i is 3 or 4 ? SampleState2 : null, g.State2);
        }
        Assert.Equal(new[] { 18, 22, 30, 34 }, lens);
    }

    [Fact]
    public void Decoder_never_reads_a_flag_without_its_bytes()
    {
        var g18 = new byte[Protocol.GhostPayloadLen];
        g18[17] = Protocol.PositionFlagSenderMs;
        Assert.True(PositionCodec.TryDecodeGhost(g18, out var a));
        Assert.Equal(0u, a.SenderMs);

        var g22 = new byte[Protocol.GhostPayloadLen + Protocol.SenderMsLen];
        g22[17] = (byte)(Protocol.PositionFlagSenderMs | Protocol.PositionFlagBodyState2);
        BinaryPrimitives.WriteUInt32LittleEndian(g22.AsSpan(18), 77u);
        Assert.True(PositionCodec.TryDecodeGhost(g22, out var b));
        Assert.True(b.BodyStateShort);    // state bit, 4 bytes of room: not a state block
        Assert.Null(b.State2);
        Assert.Equal(77u, b.SenderMs);    // the four bytes are the stamp

        Assert.False(PositionCodec.TryDecodeGhost(new byte[Protocol.GhostPayloadLen + 1], out _));
        Assert.False(PositionCodec.TryDecodeGhost(new byte[Protocol.GhostPayloadLen + 5], out _));   // a v7 23-byte ghost
        Assert.True(Protocol.IsPositionPayloadLen(21) && Protocol.IsPositionPayloadLen(29) && Protocol.IsPositionPayloadLen(33));
        Assert.False(Protocol.IsPositionPayloadLen(22) || Protocol.IsPositionPayloadLen(26) || Protocol.IsPositionPayloadLen(20));
    }

    [Fact]
    public void State2_round_trips_every_field()
    {
        var st = new BodyState2(65535, -128, (BodyState2Bits)0x1F, WireZone.Lower, WireGuardStance.Left, WireZone.LowerLeft,
                                255, short.MinValue, short.MaxValue);
        var buf = new byte[BodyState2.Len];
        st.Write(buf);
        Assert.Equal(st, BodyState2.Read(buf));
        // Legacy derivation bands (measured on Henry: walk ~1.5, run 3.05, sprint ~5.5 m/s).
        Assert.Equal(BodyPace.None, (st with { SpeedCm = 5 }).ToLegacy(false).Pace);
        Assert.Equal(BodyPace.Walk, (st with { SpeedCm = 150 }).ToLegacy(false).Pace);
        Assert.Equal(BodyPace.Run, (st with { SpeedCm = 305 }).ToLegacy(false).Pace);
        Assert.Equal(BodyPace.Sprint, (st with { SpeedCm = 550 }).ToLegacy(false).Pace);
        Assert.Equal(BodyStance.Stealth, (st with { Bits = BodyState2Bits.Crouched }).ToLegacy(false).Stance);
        Assert.Equal(BodyDir.Backward, (st with { SpeedCm = 150, MoveDir = -128 }).ToLegacy(false).Dir);
        Assert.Equal(BodyDir.Forward, (st with { SpeedCm = 150, MoveDir = 3 }).ToLegacy(false).Dir);
    }

    // ---- WO-121: PlayerHit v8 (0x44 -> 0x45), routed to the victim alone ----

    [Fact]
    public async Task Player_hit_v8_reaches_the_victim_only_with_the_attackers_id()
    {
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        var hit = new PlayerHitV8(b.Id, 3.5f, 12.25f, PlayerHitV8.FlagUnarmed, 7);
        await a.SendRawAsync(hit.BuildUp());
        var down = await b.ReadUntilAsync(Protocol.PlayerHitV8Down, Wait);
        Assert.True(PlayerHitV8.TryDecodeDown(down, out byte attacker, out var got));
        Assert.Equal(a.Id, attacker);
        Assert.Equal(hit, got);
        Assert.True(got.Unarmed);
        Assert.True(await a.NoneOfAsync(Protocol.PlayerHitV8Down, Quiet));
    }

    [Fact]
    public async Task Player_hit_v8_on_oneself_or_wrong_length_goes_nowhere()
    {
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        await a.SendRawAsync(new PlayerHitV8(a.Id, 1f, 1f, 0, 0).BuildUp());          // aimed at itself
        var bad = new byte[3 + 10]; bad[0] = Protocol.PlayerHitV8Up;
        BinaryPrimitives.WriteUInt16LittleEndian(bad.AsSpan(1), 10);
        bad[3] = b.Id;
        await a.SendRawAsync(bad);                                                     // one byte short
        await a.SendRawAsync(PositionCodec.BuildPosition(4f, 4f, 4f, 0f, false, false, null));
        _ = await b.ReadUntilAsync(Protocol.Ghost, Wait);                              // framing survived
        Assert.True(await b.NoneOfAsync(Protocol.PlayerHitV8Down, Quiet));
        Assert.True(await a.NoneOfAsync(Protocol.PlayerHitV8Down, Quiet));
    }

    [Fact]
    public async Task Session_setting_is_forwarded_only_from_the_host()
    {
        // WO-121: the friendly-fire lever is the host's. With two loopback
        // peers the relay's authority is the lowest ready id (rule 2) -- a.
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        var fromJoiner = new ActionOutbox().Build(ActionKind.SessionSetting, ActionPhase.Commit, new byte[] { SessionSettingKey.FriendlyFire, 0 });
        await b.SendRawAsync(fromJoiner);
        Assert.True(await a.NoneOfAsync(Protocol.ActionDown, Quiet));

        var fromHost = new ActionOutbox().Build(ActionKind.SessionSetting, ActionPhase.Commit, new byte[] { SessionSettingKey.FriendlyFire, 1 });
        await a.SendRawAsync(fromHost);
        var down = await b.ReadUntilAsync(Protocol.ActionDown, Wait);
        var got = new ActionInbox().Accept(down, out _);
        Assert.NotNull(got);
        Assert.Equal(ActionKind.SessionSetting, got!.Value.Kind);
        Assert.Equal(new byte[] { SessionSettingKey.FriendlyFire, 1 }, got.Value.Payload);
    }

    [Fact]
    public async Task V8_attack_event_carries_its_row_guid_through_the_relay()
    {
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;
        var row = Guid.Parse("1a78ac7e-b10f-315b-bbed-6e688f3050eb");   // a live-captured short-sword slash row
        var ev = new AttackEvent(123456u, 1, WireZone.UpperRight, 1, 0, row);
        await a.SendRawAsync(new ActionOutbox().Build(ActionKind.Attack, ActionPhase.Commit, ev.ToBytes()));
        var down = await b.ReadUntilAsync(Protocol.ActionDown, Wait);
        var got = new ActionInbox().Accept(down, out _);
        Assert.NotNull(got);
        Assert.True(AttackEvent.TryFromBytes(got!.Value.Payload, out var back));
        Assert.Equal(ev, back);
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

    // ---- WO-123: the join channel 0x48..0x57, protocol v9 ------------------

    [Fact]
    public async Task A_v8_agent_is_refused_by_the_v9_relay()
    {
        var (p, type, payload) = await Peer.ConnectRawAsync(_relay.TcpPort, "v8build", ReleaseVersionInfo.Current, 8);
        await using var _p = p;
        Assert.Equal(Protocol.VersionMismatch, type);
        Assert.Equal(Protocol.Version, payload[0]);
        Assert.Equal(9, Protocol.Version);
    }

    [Fact]
    public async Task A_whole_world_crosses_the_relay_windowed_and_byte_exact()
    {
        // alpha connects first -> lowest ready id -> damage authority (the host); bravo joins.
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;
        uint join = 0x0BADF00D;

        // the joiner asks "the host" (0xFF); the relay names the joiner to the host
        await b.SendRawAsync(WorldReceiver.BuildRequest(join));
        var req = await a.ReadUntilAsync(Protocol.JoinRequestDown, Wait);
        Assert.True(Protocol.TrySplitJoinDown(req, out byte src, out _, out uint rid, out _));
        Assert.Equal(b.Id, src);
        Assert.Equal(join, rid);

        var file = System.Security.Cryptography.RandomNumberGenerator.GetBytes(700_001);   // 22 chunks: three windows' worth
        var tx = new WorldSender(file, join, src, 5, new byte[16]);
        await a.SendRawAsync(tx.BuildOfferPacket());
        var offerDown = await b.ReadUntilAsync(Protocol.WorldOfferDown, Wait);
        Assert.True(Protocol.TrySplitJoinDown(offerDown, out byte host, out _, out _, out _));
        Assert.Equal(a.Id, host);
        var offer = WorldOffer.TryDecode(offerDown.AsSpan(1 + Protocol.JoinHeaderLen), out string why);
        Assert.NotNull(offer);
        Assert.Equal(file.Length, offer!.Value.Size);

        var got = new MemoryStream();
        int next = 0, acksSeen = 0;
        while (next < offer.Value.ChunkCount)
        {
            foreach (var pkt in tx.TakeSendable()) await a.SendRawAsync(pkt);
            Assert.True(tx.InFlightBytes <= Protocol.WorldWindowBytes);
            // the joiner drains what is in flight and acks every 4th chunk and the last
            while (next < tx.NextToSend)
            {
                var c = await b.ReadUntilAsync(Protocol.WorldChunkDown, Wait);
                var cb = c.AsSpan(1 + Protocol.JoinHeaderLen).ToArray();
                Assert.Equal((uint)next, BinaryPrimitives.ReadUInt32LittleEndian(cb));
                got.Write(cb, 4, cb.Length - 4);
                next++;
                if (next % Protocol.WorldAckEvery == 0 || next == offer.Value.ChunkCount)
                {
                    var ack = new byte[4];
                    BinaryPrimitives.WriteUInt32LittleEndian(ack, (uint)next);
                    await b.SendRawAsync(Protocol.BuildJoinUp(Protocol.WorldAckUp, Protocol.JoinTargetHost, join, ack));
                    var ad = await a.ReadUntilAsync(Protocol.WorldAckDown, Wait);
                    Assert.True(tx.OnAck(BinaryPrimitives.ReadUInt32LittleEndian(ad.AsSpan(1 + Protocol.JoinHeaderLen)), out why), why);
                    acksSeen++;
                }
            }
        }
        Assert.Equal(file, got.ToArray());
        Assert.True(tx.AllAcked);
        Assert.Equal(6, acksSeen);   // 22 chunks: acks at 4, 8, 12, 16, 20 and 22

        // done, then ready, reach the host; status reaches the joiner; nothing echoes
        await b.SendRawAsync(Protocol.BuildJoinUp(Protocol.WorldDoneUp, Protocol.JoinTargetHost, join, tx.Offer.Sha256.AsSpan(0, 8)));
        var done = await a.ReadUntilAsync(Protocol.WorldDoneDown, Wait);
        Assert.Equal(tx.Offer.Sha256.AsSpan(0, 8).ToArray(), done.AsSpan(1 + Protocol.JoinHeaderLen).ToArray());
        await a.SendRawAsync(JoinStatusCodec.Build(b.Id, join, Protocol.JoinStateWaitingReady, 0, 0));
        Assert.NotNull(await b.ReadUntilAsync(Protocol.JoinStatusDown, Wait));
        await b.SendRawAsync(WorldReceiver.BuildReady(join, 5));
        var ready = await a.ReadUntilAsync(Protocol.JoinerReadyDown, Wait);
        Assert.Equal(5u, BinaryPrimitives.ReadUInt32LittleEndian(ready.AsSpan(1 + Protocol.JoinHeaderLen)));
        Assert.True(await b.NoneOfAsync(Protocol.JoinerReadyDown, Quiet));
    }

    [Fact]
    public async Task Join_messages_from_the_wrong_side_or_of_a_wrong_length_are_dropped()
    {
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;
        uint join = 77;
        var tx = new WorldSender(new byte[1000], join, b.Id, 1, new byte[16]);

        await b.SendRawAsync(Protocol.BuildJoinUp(Protocol.WorldOfferUp, a.Id, join, tx.Offer.Encode()));   // a joiner cannot offer a world
        await b.SendRawAsync(JoinStatusCodec.Build(a.Id, join, Protocol.JoinStateResumed, 0, 0));           // nor send host status
        await a.SendRawAsync(WorldReceiver.BuildRequest(join));                                            // the host does not ask itself
        await a.SendRawAsync(Protocol.BuildJoinUp(Protocol.WorldChunkUp, b.Id, join, new byte[4 + Protocol.WorldChunkMaxData + 1])); // too long
        await a.SendRawAsync(Protocol.BuildJoinUp(Protocol.WorldChunkUp, b.Id, join, new byte[4]));         // no data
        await a.SendRawAsync(Protocol.BuildJoinUp(Protocol.WorldOfferUp, 200, join, tx.Offer.Encode()));   // nobody is id 200
        await b.SendRawAsync(Protocol.BuildJoinUp(Protocol.JoinerReadyUp, 200, join, new byte[4]));       // the joiner may only name the host
        Assert.True(await a.NoneOfAsync(Protocol.WorldOfferDown, Quiet));
        Assert.True(await a.NoneOfAsync(Protocol.JoinStatusDown, Quiet));
        Assert.True(await a.NoneOfAsync(Protocol.JoinerReadyDown, Quiet));
        Assert.True(await a.NoneOfAsync(Protocol.JoinRequestDown, Quiet));
        Assert.True(await b.NoneOfAsync(Protocol.WorldChunkDown, Quiet));
        Assert.True(await b.NoneOfAsync(Protocol.WorldOfferDown, Quiet));

        // the framing survived every drop: a real offer still arrives, and an abort goes either way
        await a.SendRawAsync(tx.BuildOfferPacket());
        Assert.NotNull(await b.ReadUntilAsync(Protocol.WorldOfferDown, Wait));
        await b.SendRawAsync(WorldReceiver.BuildAbort(Protocol.JoinTargetHost, join, Protocol.JoinAbortHashMismatch));
        var ab = await a.ReadUntilAsync(Protocol.JoinAbortDown, Wait);
        Assert.Equal(Protocol.JoinAbortHashMismatch, ab[^1]);
        await a.SendRawAsync(WorldReceiver.BuildAbort(b.Id, join, Protocol.JoinAbortTimeout));
        var ab2 = await b.ReadUntilAsync(Protocol.JoinAbortDown, Wait);
        Assert.Equal(Protocol.JoinAbortTimeout, ab2[^1]);
    }

    [Fact]
    public async Task A_full_window_into_a_joiner_that_is_not_reading_does_not_overflow_its_queue()
    {
        // WO-110 4.4: 512 KB queued for one client disconnects it. The window is
        // 256 KB, so a joiner that stalls (loading, a slow disk) keeps its connection.
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;
        var tx = new WorldSender(new byte[2_000_000], 9, b.Id, 1, new byte[16]);
        await a.SendRawAsync(tx.BuildOfferPacket());
        var window = tx.TakeSendable();
        Assert.Equal(8, window.Count);
        foreach (var pkt in window) await a.SendRawAsync(pkt);
        Assert.Empty(tx.TakeSendable());   // the sender holds back until an ack
        await Task.Delay(500);             // the relay queues all of it for bravo, who reads nothing yet
        Assert.NotNull(await b.ReadUntilAsync(Protocol.WorldOfferDown, Wait));
        for (int i = 0; i < 8; i++) Assert.NotNull(await b.ReadUntilAsync(Protocol.WorldChunkDown, Wait));
        // still connected both ways
        await b.SendRawAsync(Protocol.BuildJoinUp(Protocol.WorldAckUp, Protocol.JoinTargetHost, 9, [8, 0, 0, 0]));
        Assert.NotNull(await a.ReadUntilAsync(Protocol.WorldAckDown, Wait));
    }

    // ---- WO-122: WorldSaved 0x46 -> 0x47, from the host only --------------

    private static byte[] WorldSavedBody(uint seq, byte kind, byte playline, ushort idx) =>
        new WorldSaved(seq, 1_790_000_000_123L, kind, playline, idx, Enumerable.Range(0, 16).Select(i => (byte)(0xA0 + i)).ToArray()).Encode();

    [Fact]
    public async Task World_saved_crosses_from_the_host_intact()
    {
        // alpha connects first -> lowest ready id -> damage authority (the host).
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        await a.SendRawAsync(Frame(Protocol.WorldSavedUp, WorldSavedBody(7, Protocol.SaveKindAuto, 1, 42)));
        var down = await b.ReadUntilAsync(Protocol.WorldSavedDown, Wait);
        var ws = WorldSaved.TryDecode(down, down: true, out byte src);
        Assert.NotNull(ws);
        Assert.Equal(a.Id, src);
        Assert.Equal(7u, ws!.Value.Seq);
        Assert.Equal(1_790_000_000_123L, ws.Value.SenderUnixMs);
        Assert.Equal("autosave042.whs", ws.Value.FileName);
        Assert.Equal(1, ws.Value.Playline);
        Assert.Equal(0xAF, ws.Value.Md5[15]);
        Assert.True(await a.NoneOfAsync(Protocol.WorldSavedDown, Quiet));   // never echoed to the sender
    }

    [Fact]
    public async Task World_saved_from_a_joiner_or_of_the_wrong_length_is_dropped()
    {
        var (a, b) = await TwoPeersAsync();
        await using var _a = a; await using var _b = b;

        await b.SendRawAsync(Frame(Protocol.WorldSavedUp, WorldSavedBody(1, Protocol.SaveKindQuick, 1, 3)));   // bravo is not the authority
        await a.SendRawAsync(Frame(Protocol.WorldSavedUp, new byte[Protocol.WorldSavedUpPayloadLen - 1]));
        Assert.True(await a.NoneOfAsync(Protocol.WorldSavedDown, Quiet));
        Assert.True(await b.NoneOfAsync(Protocol.WorldSavedDown, Quiet));

        // framing survives: the host's next valid save arrives
        await a.SendRawAsync(Frame(Protocol.WorldSavedUp, WorldSavedBody(2, Protocol.SaveKindManual, 1, 9)));
        var down = await b.ReadUntilAsync(Protocol.WorldSavedDown, Wait);
        Assert.Equal("save009.whs", WorldSaved.TryDecode(down, true, out _)!.Value.FileName);
    }
}
