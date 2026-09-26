using System.Net.Sockets;
using KcdMp.Steam;
using KcdMp.Wire;

namespace KcdMp.Client.Tests;

/// <summary>WO-127: join codes, the plain error mapping, the host-claim bit, the Steam path over a synthetic stream.</summary>
public class Wo127Tests
{
    private const ulong SomeAccount = 0x0110000100000000UL | 0xFFFFFFF0u;   // synthetic: beyond any allocated account id

    [Fact]
    public void Default_app_code_is_the_seven_char_friend_code()
    {
        string code = SteamJoinCode.Encode(SomeAccount, SteamApps.ModdingTools);
        Assert.Equal(FriendCode.Encode(SomeAccount), code);
        Assert.Equal(8, code.Length);   // "ABCD-EFG"
        Assert.True(SteamJoinCode.TryParse(code, out ulong id, out uint app));
        Assert.Equal((SomeAccount, SteamApps.ModdingTools), (id, app));
    }

    [Theory]
    [InlineData(480u, 'S')]
    [InlineData(1771300u, 'R')]
    public void Other_apps_carry_one_letter_and_parse_back(uint appId, char letter)
    {
        string code = SteamJoinCode.Encode(SomeAccount, appId);
        Assert.EndsWith("-" + letter, code);
        Assert.True(SteamJoinCode.TryParse(code, out ulong id, out uint app));
        Assert.Equal((SomeAccount, appId), (id, app));
        // Forgiving like the friend code: lower case, no dashes, spaces.
        Assert.True(SteamJoinCode.TryParse(" " + code.Replace("-", "").ToLowerInvariant() + " ", out ulong id2, out uint app2));
        Assert.Equal((SomeAccount, appId), (id2, app2));
    }

    [Theory]
    [InlineData("")]
    [InlineData("ABCD-EFG")]        // check bits wrong
    [InlineData("ABCD-EF")]         // too short
    [InlineData("ABCD-EFGH-S")]     // too long
    public void Bad_codes_are_refused(string text)
    {
        Assert.False(SteamJoinCode.TryParse(text, out _, out _));
    }

    [Fact]
    public void An_unknown_app_letter_is_refused()
    {
        string code = FriendCode.Encode(SomeAccount) + "-X";
        Assert.False(SteamJoinCode.TryParse(code, out _, out _));
    }

    [Fact]
    public async Task A_code_for_another_app_is_an_app_id_mismatch_before_steam_starts()
    {
        string code = SteamJoinCode.Encode(SomeAccount, SteamApps.Spacewar);
        var ex = await Assert.ThrowsAsync<RelayConnectException>(() =>
            RelayConnector.ConnectSteamAsync(code, SteamApps.ModdingTools, null, TimeSpan.FromSeconds(1), CancellationToken.None));
        Assert.Equal(ConnectionTrouble.AppIdMismatch, ex.Kind);
        Assert.Contains("480", ex.Plain.Sentence);
        Assert.Contains("2429020", ex.Plain.Sentence);
    }

    [Fact]
    public async Task A_bad_code_fails_as_bad_code()
    {
        var ex = await Assert.ThrowsAsync<RelayConnectException>(() =>
            RelayConnector.ConnectSteamAsync("nope", SteamApps.ModdingTools, null, TimeSpan.FromSeconds(1), CancellationToken.None));
        Assert.Equal(ConnectionTrouble.BadCode, ex.Kind);
    }

    // ------------------------------------------------------------ plain errors

    [Theory]
    [InlineData(SocketError.ConnectionRefused, ConnectionTrouble.Refused)]
    [InlineData(SocketError.TimedOut, ConnectionTrouble.TimedOut)]
    [InlineData(SocketError.HostUnreachable, ConnectionTrouble.TimedOut)]
    [InlineData(SocketError.NetworkUnreachable, ConnectionTrouble.TimedOut)]
    [InlineData(SocketError.HostNotFound, ConnectionTrouble.WrongAddress)]
    [InlineData(SocketError.NoData, ConnectionTrouble.WrongAddress)]
    [InlineData(SocketError.ConnectionReset, ConnectionTrouble.Lost)]
    public void Socket_errors_map_to_one_trouble(SocketError code, ConnectionTrouble want)
    {
        Assert.Equal(want, PlainConnectionError.Classify(new SocketException((int)code)));
        // Wrapped, as HttpClient/TcpClient sometimes do.
        Assert.Equal(want, PlainConnectionError.Classify(new IOException("outer", new SocketException((int)code))));
    }

    [Fact]
    public void Timeouts_and_bad_addresses_classify()
    {
        Assert.Equal(ConnectionTrouble.TimedOut, PlainConnectionError.Classify(new TimeoutException()));
        Assert.Equal(ConnectionTrouble.TimedOut, PlainConnectionError.Classify(new OperationCanceledException()));
        Assert.Equal(ConnectionTrouble.WrongAddress, PlainConnectionError.Classify(new ArgumentException("bad host")));
        Assert.Equal(ConnectionTrouble.Lost, PlainConnectionError.Classify(new EndOfStreamException()));
        Assert.Equal(ConnectionTrouble.Unknown, PlainConnectionError.Classify(new InvalidOperationException("x")));
    }

    [Fact]
    public void Every_trouble_has_one_plain_sentence_and_a_next_step()
    {
        foreach (ConnectionTrouble k in Enum.GetValues<ConnectionTrouble>())
        {
            var p = PlainConnectionError.For(k, "0.28.3", "0.29.9");
            Assert.False(string.IsNullOrWhiteSpace(p.Sentence));
            if (k != ConnectionTrouble.None) Assert.False(string.IsNullOrWhiteSpace(p.NextStep), k.ToString());
            // No exception-speak on the player's screen.
            foreach (var bad in new[] { "Exception", "Socket", "errno", "0x", "HRESULT", "EResult" })
                Assert.DoesNotContain(bad, p.Text);
            Assert.EndsWith(".", p.Sentence);
        }
    }

    [Fact]
    public void Version_mismatch_names_both_versions()
    {
        var p = PlainConnectionError.For(ConnectionTrouble.VersionMismatch, "0.28.3", "0.29.9");
        Assert.Contains("0.28.3", p.Sentence);
        Assert.Contains("0.29.9", p.Sentence);
    }

    [Theory]
    [InlineData(ConnectionTrouble.SteamNotRunning)]
    [InlineData(ConnectionTrouble.SteamNotLoggedIn)]
    [InlineData(ConnectionTrouble.SteamUnavailable)]
    [InlineData(ConnectionTrouble.SteamNoRoute)]
    [InlineData(ConnectionTrouble.BadCode)]
    [InlineData(ConnectionTrouble.OwnCode)]
    [InlineData(ConnectionTrouble.AppIdMismatch)]
    public void Steam_failures_use_the_fallback_wording(ConnectionTrouble k)
    {
        string s = PlainConnectionError.SteamFallback(k, "Spacewar (480)", "KCD2 Modding Tools (2429020)");
        Assert.StartsWith("Couldn't connect through Steam: ", s);
        Assert.EndsWith(". Try the host's address instead.", s);
        Assert.DoesNotContain("something went wrong", s);
    }

    [Fact]
    public void Agent_status_json_carries_the_plain_words_not_the_detail()
    {
        AgentConnectionStatus.Fail("steam", ConnectionTrouble.SteamNoRoute, "Steam P2P closed (reason 5003: steamid:999999999999999999 timed out 203.0.113.9:27015)", fatal: false);
        string json = AgentConnectionStatus.Json();
        Assert.Contains("Couldn't connect through Steam", json);
        Assert.DoesNotContain("999999999999999999", json);
        Assert.DoesNotContain("203.0.113.9", json);
        Assert.DoesNotContain("5003", json);
        AgentConnectionStatus.Set("connected", "steam");
        Assert.Contains("\"state\":\"connected\"", AgentConnectionStatus.Json());
    }

    // ------------------------------------------------------------ the host-claim bit

    [Fact]
    public void Host_claim_sets_only_its_own_bit()
    {
        var off = PositionCodec.BuildPosition(1, 2, 3, 0, true, false, null, 7u);
        var on = PositionCodec.BuildPosition(1, 2, 3, 0, true, false, null, 7u, hostClaim: true);
        Assert.Equal(off.Length, on.Length);
        Assert.Equal(0, off[19] & Protocol.PositionFlagHostClaim);
        Assert.Equal(Protocol.PositionFlagHostClaim, on[19] & Protocol.PositionFlagHostClaim);
        Assert.Equal(off[19], on[19] & ~Protocol.PositionFlagHostClaim);
        // No other flag uses 0x40.
        foreach (byte f in new[] { Protocol.PositionFlagRiding, Protocol.PositionFlagStale, Protocol.PositionFlagBodyState,
                                   Protocol.PositionFlagSenderMs, Protocol.PositionFlagBodyState2 })
            Assert.Equal(0, f & Protocol.PositionFlagHostClaim);
    }

    // ------------------------------------------------------------ the Steam path, synthetic stream

    /// <summary>
    /// A stand-in for SteamConnectionStream with the same contract: every
    /// Write is one message, Read hands bytes out in any size, 0 at the end.
    /// Messages arrive split at arbitrary points, as Steam may deliver them.
    /// </summary>
    private sealed class MessageStream : Stream
    {
        private readonly System.Threading.Channels.Channel<byte[]> _in;
        private readonly System.Threading.Channels.Channel<byte[]> _out;
        private byte[]? _cur; private int _off;
        public MessageStream(System.Threading.Channels.Channel<byte[]> inbox, System.Threading.Channels.Channel<byte[]> outbox) { _in = inbox; _out = outbox; }
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default)
        {
            while (_cur is null || _off >= _cur.Length)
            {
                try { _cur = await _in.Reader.ReadAsync(ct); _off = 0; }
                catch (System.Threading.Channels.ChannelClosedException) { return 0; }
            }
            int n = Math.Min(buffer.Length, _cur.Length - _off);
            _cur.AsMemory(_off, n).CopyTo(buffer);
            _off += n;
            return n;
        }
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken ct = default)
        {
            // Split each write into two messages to prove boundaries are not load-bearing.
            int half = buffer.Length / 2;
            if (half > 0) _out.Writer.TryWrite(buffer[..half].ToArray());
            _out.Writer.TryWrite(buffer[half..].ToArray());
            return ValueTask.CompletedTask;
        }
        public override void Close() { _out.Writer.TryComplete(); base.Close(); }
        public override bool CanRead => true; public override bool CanWrite => true; public override bool CanSeek => false;
        public override void Flush() { }
        public override int Read(byte[] b, int o, int c) => ReadAsync(b.AsMemory(o, c)).AsTask().GetAwaiter().GetResult();
        public override void Write(byte[] b, int o, int c) => WriteAsync(b.AsMemory(o, c)).AsTask().GetAwaiter().GetResult();
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override long Seek(long o, SeekOrigin s) => throw new NotSupportedException();
        public override void SetLength(long v) => throw new NotSupportedException();
    }

    private static (Stream A, Stream B) Pair()
    {
        var ab = System.Threading.Channels.Channel.CreateUnbounded<byte[]>();
        var ba = System.Threading.Channels.Channel.CreateUnbounded<byte[]>();
        return (new MessageStream(ba, ab), new MessageStream(ab, ba));
    }

    [Fact]
    public async Task Handshake_and_frames_cross_a_message_stream_intact()
    {
        var (agent, relay) = Pair();
        var hs = RelayConnector.BuildHandshake("Henry", "0.29.9");
        await agent.WriteAsync(hs);
        var (t, body) = await RelayConnector.ReadFrameAsync(relay, CancellationToken.None);
        Assert.Equal(Protocol.Handshake, t);
        Assert.Equal(hs.AsSpan(3).ToArray(), body);

        // A connection test reply the other way, as a relay sends it.
        var reply = ConnectionTestReply.BuildPayload("0.29.9", 1, true);
        var frame = new byte[3 + reply.Length];
        frame[0] = Protocol.ReleaseVersionMismatch;
        System.Buffers.Binary.BinaryPrimitives.WriteUInt16LittleEndian(frame.AsSpan(1), (ushort)reply.Length);
        reply.CopyTo(frame, 3);
        await relay.WriteAsync(frame);
        var (t2, b2) = await RelayConnector.ReadFrameAsync(agent, CancellationToken.None);
        Assert.Equal(Protocol.ReleaseVersionMismatch, t2);
        Assert.True(ConnectionTestReply.Decode(b2).HostConnected);

        // Many position frames back to back, read in order.
        for (int i = 0; i < 50; i++) await agent.WriteAsync(PositionCodec.BuildPosition(i, 0, 0, 0, false, false, null, (uint)i));
        for (int i = 0; i < 50; i++)
        {
            var (pt, pb) = await RelayConnector.ReadFrameAsync(relay, CancellationToken.None);
            Assert.Equal(Protocol.Position, pt);
            Assert.Equal((float)i, BitConverter.ToSingle(pb, 0));
        }

        // Peer gone -> end of stream, which every loop treats as a disconnect.
        agent.Close();
        await Assert.ThrowsAsync<EndOfStreamException>(() => RelayConnector.ReadFrameAsync(relay, CancellationToken.None));
    }
}
