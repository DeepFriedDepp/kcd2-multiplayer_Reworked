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

    // ------------------------------------------------------------ the leash recorder (format)

    private static byte[] LeashReplyBytes(ushort total, ushort offset, params LeashEntry[] es)
    {
        var b = new List<byte> { 1, 7, 0, 2, 1, 0, 0, 0xFF };   // ok, seq, refuse, n=2, town [1,0], interior [0,-1]
        b.AddRange(BitConverter.GetBytes(4321u)); b.AddRange(BitConverter.GetBytes(123456u)); b.AddRange(BitConverter.GetBytes(850u));
        b.AddRange(BitConverter.GetBytes(total)); b.AddRange(BitConverter.GetBytes(offset)); b.AddRange(BitConverter.GetBytes((ushort)es.Length));
        foreach (var e in es)
        {
            b.AddRange(BitConverter.GetBytes(e.Wuid)); b.AddRange(BitConverter.GetBytes(e.X)); b.AddRange(BitConverter.GetBytes(e.Y)); b.AddRange(BitConverter.GetBytes(e.Z));
            b.AddRange(BitConverter.GetBytes(e.Flags)); b.Add(unchecked((byte)e.BrainState)); b.Add(e.BrainMask);
            b.AddRange(BitConverter.GetBytes(e.SpeedCms)); b.AddRange(BitConverter.GetBytes(e.StreamAgeMs));
            b.Add((byte)e.Name.Length); b.AddRange(System.Text.Encoding.ASCII.GetBytes(e.Name));
        }
        return b.ToArray();
    }

    private static LeashEntry Npc(ulong wuid, string name, float x, float y, ushort extra = 0, sbyte brain = 0, byte mask = 0) =>
        new(wuid, x, y, 1f, (ushort)(LeashEntry.EntFlagsKnown | LeashEntry.Active | LeashEntry.PhysPresent | LeashEntry.AwakeKnown
                                     | LeashEntry.Awake | LeashEntry.Living | LeashEntry.BrainKnown | extra), brain, mask, 140, 0xFFFF, name);

    [Fact]
    public void Leash_request_and_reply_round_trip()
    {
        var req = LeashCodec.BuildRequest(new[] { (1f, 2f, 3f), (4f, 5f, 6f) }, 200f, 3);
        Assert.Equal(4 + 1 + 24 + 2, req.Length);
        Assert.Equal(200f, BitConverter.ToSingle(req, 0));
        Assert.Equal(2, req[4]);
        Assert.Equal((ushort)3, BitConverter.ToUInt16(req, 29));

        var a = Npc(0xABCDEF0123456789, "npc_guard_01", 10, 20, LeashEntry.Driven, 1, 0x04);
        var bytes = LeashReplyBytes(5, 3, a, Npc(0, "horse_x", 1, 1, LeashEntry.Horse));
        Assert.True(LeashCodec.TryParse(bytes, out var page));
        Assert.NotNull(page);
        Assert.True(page!.Ok);
        Assert.Equal(new sbyte[] { 1, 0 }, page.Town);
        Assert.Equal(new sbyte[] { 0, -1 }, page.Interior);
        Assert.Equal((4321u, 123456u, 850u, (ushort)5, (ushort)3), (page.Walked, page.Frames, page.SampleUs, page.Total, page.Offset));
        Assert.Equal(2, page.Entries.Count);
        Assert.Equal(a, page.Entries[0]);
        Assert.True(page.Entries[1].Has(LeashEntry.Horse));
        Assert.False(LeashCodec.TryParse(bytes.AsSpan(0, bytes.Length - 3), out _));   // truncated -> refused, not guessed
    }

    private static int Cols(string line)
    {
        int n = 1; bool q = false;
        foreach (char c in line) { if (c == '"') q = !q; else if (c == ',' && !q) n++; }
        return n;
    }

    [Fact]
    public void Host_rows_match_the_header_and_derive_moved_and_gone()
    {
        int want = Cols(LeashCsv.HostHeader);
        Assert.Equal(4 + LeashRowBuilder.SummaryColumns + LeashRowBuilder.NpcColumns, want);
        var b = new LeashRowBuilder();
        var hostCtx = new LeashContext(true, false, false, null, false, false, false);
        var inputs1 = new LeashRowBuilder.HostInputs(new DateTime(2026, 9, 26, 12, 0, 0, DateTimeKind.Utc), 1.0, 2, 58.5f,
            (0, 0, 0), (30, 40, 0), hostCtx, default, 900, 4000,
            new[] { Npc(1, "a", 10, 0), Npc(2, "b,with comma", 50, 50) }, n => n == "a");
        var rows1 = b.HostRows(inputs1).ToList();
        Assert.Equal(3, rows1.Count);
        Assert.All(rows1, r => Assert.Equal(want, Cols(r)));
        var sum = rows1[0].Split(',');
        Assert.Equal("summary", sum[2]);
        Assert.Equal("2", sum[3]);
        Assert.Equal("58.5", sum[4]);
        Assert.Equal("50.00", sum[11]);   // host_joiner_m: 3-4-5 * 10
        Assert.Equal("1", sum[12]);       // host_town
        Assert.Equal("", sum[15]);        // host_fight unknown -> empty
        Assert.Equal("", sum[19]);        // joiner_town unknown (no joiner context) -> empty
        Assert.Contains("\"b,with comma\"", rows1[2]);
        var a1 = rows1[1].Split(',');
        int npc0 = 4 + LeashRowBuilder.SummaryColumns;
        Assert.Equal("0000000000000001", a1[npc0]);
        Assert.Equal("10.0", a1[npc0 + 6]);   // d_host
        Assert.Equal("1", a1[npc0 + 8]);      // exists
        Assert.Equal("", a1[npc0 + 12]);      // phys_awake: a living entity -> unknown (the engine never says)
        Assert.Equal("", a1[npc0 + 13]);      // phys_sim: not read in this entry
        Assert.Equal("", a1[npc0 + 19]);      // moved: no previous sample
        Assert.Equal("1", a1[npc0 + 20]);     // in_stream_1s

        // Next second: a moved, b gone.
        var inputs2 = inputs1 with { TSeconds = 2.0, Npcs = new[] { Npc(1, "a", 12, 0) } };
        var rows2 = b.HostRows(inputs2).ToList();
        Assert.Equal(3, rows2.Count);
        Assert.All(rows2, r => Assert.Equal(want, Cols(r)));
        var a2 = rows2[1].Split(',');
        Assert.Equal("1", a2[npc0 + 19]);     // moved
        Assert.Contains(",0,", rows2[2]);      // exists=0 row for b
        Assert.Contains("b,with comma", rows2[2]);
    }

    [Fact]
    public void Joiner_rows_match_the_header()
    {
        int want = Cols(LeashCsv.JoinerHeader);
        var b = new LeashRowBuilder();
        var rows = b.JoinerRows(new LeashRowBuilder.JoinerInputs(DateTime.UtcNow, 1, (0, 0, 0),
            new[] { Npc(9, "c", 3, 4, LeashEntry.Driven | LeashEntry.SimKnown | LeashEntry.SimActive, 2, 0x01) }, n => n == "c" ? 120.4 : null)).ToList();
        Assert.Single(rows);
        Assert.Equal(want, Cols(rows[0]));
        var f = rows[0].Split(',');
        Assert.Equal("copy", f[2]);
        Assert.Equal("5.0", f[9]);    // d_joiner
        Assert.Equal("120", f[11]);   // age_ms
        Assert.Equal("1", f[13]);     // suspended (brain state 2)
        Assert.Equal("01", f[15]);    // brain_mask
        Assert.Equal("1", f[16]);     // driven
        Assert.Equal("1", f[19]);     // phys_sim
    }

    [Fact]
    public void Leash_csv_rotates_past_the_size_limit()
    {
        string dir = Path.Combine(Path.GetTempPath(), "wo127-leash-" + Guid.NewGuid().ToString("N"));
        try
        {
            using (var csv = new LeashCsv(dir, "leash-host-test", LeashCsv.HostHeader, rotateBytes: 4096))
            {
                for (int i = 0; i < 400; i++) { csv.Write(new string('x', 40)); if (i % 50 == 0) csv.Flush(); }
                csv.Flush();
            }
            var files = Directory.GetFiles(dir).Select(Path.GetFileName).OrderBy(x => x).ToList();
            Assert.Contains("leash-host-test.csv", files);
            Assert.Contains("leash-host-test-part2.csv", files);
            foreach (var fpath in Directory.GetFiles(dir))
                Assert.StartsWith("utc,t_s,kind", File.ReadLines(fpath).First());   // every part starts with the header
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }
}
