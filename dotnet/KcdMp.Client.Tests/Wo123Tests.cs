using System.Buffers.Binary;
using System.Security.Cryptography;
using KcdMp.Wire;

namespace KcdMp.Client.Tests;

/// <summary>
/// WO-123: the world transfer (WorldSender / WorldReceiver) and the join wire
/// table, on SYNTHETIC data only -- the saves are built in code
/// (WhsSaveTests.SyntheticSave) or are random bytes. No real save anywhere.
/// </summary>
public class Wo123Tests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "kcdmp-wo123-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try { Directory.Delete(_dir, true); } catch { }
    }

    private static byte[] Md5Of(byte[] save) => Convert.FromHexString(WhsSave.Verify(save).Md5);

    /// <summary>The packet body after [type][len:2][target][joinId:4].</summary>
    private static byte[] Body(byte[] pkt) => pkt.AsSpan(8).ToArray();

    /// <summary>Runs a sender into a receiver the way the two agents do; returns the receiver's result.</summary>
    private (bool Ok, byte Reason, string Why, WorldReceiver Rx, int Acks, long MaxInFlight) Transfer(
        WorldSender tx, Func<int, byte[], byte[]>? tamper = null, WorldOffer? offerOverride = null)
    {
        var offer = offerOverride ?? WorldOffer.TryDecode(Body(tx.BuildOfferPacket()), out _)!.Value;
        var rx = new WorldReceiver(_dir, tx.JoinId, 0, offer);
        int acks = 0;
        long maxInFlight = 0;
        var queue = new Queue<byte[]>();
        while (true)
        {
            foreach (var p in tx.TakeSendable()) queue.Enqueue(p);
            maxInFlight = Math.Max(maxInFlight, tx.InFlightBytes);
            if (queue.Count == 0) break;
            while (queue.Count > 0)
            {
                var body = Body(queue.Dequeue());
                uint idx = BinaryPrimitives.ReadUInt32LittleEndian(body);
                var data = body.AsSpan(4).ToArray();
                if (tamper is not null) data = tamper((int)idx, data);
                var r = rx.Accept(idx, data, out string why);
                if (r == WorldReceiver.ChunkResult.Error) return (false, Protocol.JoinAbortProtocol, why, rx, acks, maxInFlight);
                if (r is WorldReceiver.ChunkResult.AckDue or WorldReceiver.ChunkResult.Complete)
                {
                    acks++;
                    uint next = BinaryPrimitives.ReadUInt32LittleEndian(Body(rx.BuildAck()));
                    Assert.True(tx.OnAck(next, out string ackWhy), ackWhy);
                }
                if (r == WorldReceiver.ChunkResult.Complete)
                {
                    var (ok, reason, fwhy) = rx.Finish();
                    return (ok, reason, fwhy, rx, acks, maxInFlight);
                }
            }
        }
        return (false, 0, "sender stalled", rx, acks, maxInFlight);
    }

    // ---------------------------------------------------------------- the wire table

    [Fact]
    public void Join_wire_table_is_consistent()
    {
        var ups = Protocol.JoinWire.Select(r => r.Up).ToList();
        Assert.Equal(ups.Count, ups.Distinct().Count());
        foreach (var r in Protocol.JoinWire)
        {
            Assert.Equal(r.Up + 1, r.Down);
            Assert.True(r.Up >= 0x48 && r.Down <= 0x57, $"{r.Name} outside 0x48..0x57");
            Assert.True(r.Min >= Protocol.JoinHeaderLen && r.Max >= r.Min && r.Max + 1 <= ushort.MaxValue, r.Name);
            Assert.True(Protocol.IsJoinDown(r.Down, r.Min + 1));
            Assert.True(Protocol.IsJoinDown(r.Down, r.Max + 1));
            Assert.False(Protocol.IsJoinDown(r.Down, r.Min));
            Assert.False(Protocol.IsJoinDown(r.Down, r.Max + 2));
            Assert.Equal(r, Protocol.JoinWireFor(r.Up));
        }
        Assert.Null(Protocol.JoinWireFor(Protocol.WorldSavedUp));
        Assert.False(Protocol.IsJoinDown(Protocol.WorldSavedDown, Protocol.WorldSavedDownPayloadLen));
        Assert.Equal(9, Protocol.Version);
        // the biggest frame the join sends fits a u16 length and the relay's queue many times over
        var chunk = Protocol.JoinWireFor(Protocol.WorldChunkUp)!.Value;
        Assert.Equal(Protocol.JoinHeaderLen + 4 + Protocol.WorldChunkMaxData, chunk.Max);
        Assert.True(Protocol.WorldWindowBytes + Protocol.WorldWindowBytes / Protocol.WorldChunkMaxData * 16 < 512 * 1024);
    }

    [Fact]
    public void Every_builder_emits_a_length_its_row_allows()
    {
        void Fits(byte[] pkt)
        {
            var row = Protocol.JoinWireFor(pkt[0]);
            Assert.NotNull(row);
            int len = BinaryPrimitives.ReadUInt16LittleEndian(pkt.AsSpan(1));
            Assert.Equal(pkt.Length - 3, len);
            Assert.InRange(len, row!.Value.Min, row.Value.Max);
        }
        var save = WhsSaveTests.SyntheticSave();
        var tx = new WorldSender(save, 0xA1B2C3D4, 1, 7, Md5Of(save));
        Fits(tx.BuildOfferPacket());
        foreach (var p in tx.TakeSendable()) Fits(p);
        Fits(WorldReceiver.BuildRequest(5));
        Fits(WorldReceiver.BuildAbort(1, 5, Protocol.JoinAbortTimeout));
        Fits(WorldReceiver.BuildReady(5, 7));
        Fits(JoinStatusCodec.Build(1, 5, Protocol.JoinStateDeferred, Protocol.JoinReasonId("combat"), 0));
        var rx = new WorldReceiver(_dir, 5, 0, tx.Offer);
        Fits(rx.BuildAck());
        Fits(rx.BuildDone());
        rx.Dispose();
        Assert.Equal(Protocol.JoinTargetHost, WorldReceiver.BuildRequest(5)[3]);
    }

    [Fact]
    public void Status_and_reasons_round_trip()
    {
        var p = JoinStatusCodec.Build(2, 0x1234, Protocol.JoinStateDeferred, Protocol.JoinReasonId("dialogue"), 42);
        Assert.True(JoinStatusCodec.TryDecode(Body(p), out byte st, out byte rs, out ushort arg));
        Assert.Equal(Protocol.JoinStateDeferred, st);
        Assert.Equal("dialogue", Protocol.JoinReasonName(rs));
        Assert.Equal(42, arg);
        Assert.Equal("deferred", Protocol.JoinStateName(st));
        Assert.Equal(0, Protocol.JoinReasonId("no-such-reason"));
        // every busy reason the mod can answer has an id
        foreach (var r in new[] { "combat", "dialogue", "cutscene", "loading", "dead", "shared-world-off", "no-mod", "another-join" })
            Assert.NotEqual(0, Protocol.JoinReasonId(r));
    }

    // ---------------------------------------------------------------- the offer

    [Fact]
    public void Offer_round_trips_and_rejects_nonsense()
    {
        var sha = SHA256.HashData(new byte[] { 1, 2, 3 });
        var md5 = Enumerable.Range(0, 16).Select(i => (byte)i).ToArray();
        var o = new WorldOffer(1_434_374, 32768, 44, sha, 9, md5);
        var d = WorldOffer.TryDecode(o.Encode(), out string why);
        Assert.NotNull(d);
        Assert.Equal(o.Size, d!.Value.Size);
        Assert.Equal(44, d.Value.ChunkCount);
        Assert.Equal(9u, d.Value.WorldSavedSeq);
        Assert.Equal(sha, d.Value.Sha256);
        Assert.Equal(md5, d.Value.Md5);

        Assert.Null(WorldOffer.TryDecode(o.Encode().AsSpan(1).ToArray(), out why));
        Assert.Null(WorldOffer.TryDecode((o with { Size = 0 }).Encode(), out why));
        Assert.Null(WorldOffer.TryDecode((o with { Size = Protocol.WorldMaxBytes + 1, ChunkCount = (Protocol.WorldMaxBytes + 1 + 32767) / 32768 }).Encode(), out why));
        Assert.Contains("limit", why);
        Assert.Null(WorldOffer.TryDecode((o with { ChunkSize = 0 }).Encode(), out why));
        Assert.Null(WorldOffer.TryDecode((o with { ChunkSize = Protocol.WorldChunkMaxData + 1 }).Encode(), out why));
        Assert.Null(WorldOffer.TryDecode((o with { ChunkCount = 43 }).Encode(), out why));
        Assert.Contains("do not cover", why);
    }

    // ---------------------------------------------------------------- chunking and the window

    [Fact]
    public void Chunks_are_32KB_the_last_one_short_and_the_window_holds_256KB()
    {
        var file = RandomNumberGenerator.GetBytes(1_434_374);   // the size of a real early-game save; random bytes
        var tx = new WorldSender(file, 1, 1, 1, new byte[16]);
        Assert.Equal(44, tx.ChunkCount);
        var first = tx.TakeSendable();
        Assert.Equal(8, first.Count);                           // 8 x 32 KB = 256 KB
        Assert.Equal(Protocol.WorldWindowBytes, tx.InFlightBytes);
        Assert.Empty(tx.TakeSendable());                        // full until an ack
        Assert.True(tx.OnAck(4, out _));
        Assert.Equal(4, tx.TakeSendable().Count);               // 4 acked -> 4 more
        Assert.False(tx.OnAck(3, out string back));             // an ack never goes back
        Assert.Contains("goes back", back);
        Assert.False(tx.OnAck(13, out string past));            // or past what was sent
        Assert.Contains("past", past);
        while (!tx.AllSent)
        {
            tx.OnAck((uint)tx.NextToSend, out _);
            var batch = tx.TakeSendable();
            if (tx.AllSent)
            {
                var last = batch[^1];
                int len = BinaryPrimitives.ReadUInt16LittleEndian(last.AsSpan(1));
                Assert.Equal(Protocol.JoinHeaderLen + 4 + (file.Length - 43 * 32768), len);
            }
        }
        Assert.True(tx.OnAck(44, out _));
        Assert.True(tx.AllAcked);
    }

    [Fact]
    public void Sender_refuses_an_empty_or_oversized_file()
    {
        Assert.Throws<ArgumentException>(() => new WorldSender([], 1, 1, 1, new byte[16]));
        Assert.Throws<ArgumentOutOfRangeException>(() => new WorldSender(new byte[10], 1, 1, 1, new byte[16], chunkSize: Protocol.WorldChunkMaxData + 1));
        Assert.Throws<ArgumentOutOfRangeException>(() => new WorldSender(new byte[10], 1, 1, 1, new byte[16], chunkSize: 1024, windowBytes: 512));
    }

    // ---------------------------------------------------------------- reassembly

    [Fact]
    public void A_whole_transfer_reassembles_the_file_exactly_and_verifies()
    {
        var save = WhsSaveTests.SyntheticSave();
        var tx = new WorldSender(save, 0xC0FFEE, 1, 12, Md5Of(save), chunkSize: 256, windowBytes: 1024);
        Assert.True(tx.ChunkCount > 8, $"the synthetic save is only {save.Length} bytes");
        var (ok, _, why, rx, acks, maxInFlight) = Transfer(tx);
        Assert.True(ok, why);
        Assert.True(File.Exists(rx.FinalPath));
        Assert.False(File.Exists(rx.PartPath));
        Assert.Equal(save, File.ReadAllBytes(rx.FinalPath));
        Assert.Equal(SHA256.HashData(save), rx.Sha256);
        Assert.True(maxInFlight <= 1024, $"in flight {maxInFlight}");
        Assert.Equal((tx.ChunkCount + Protocol.WorldAckEvery - 1) / Protocol.WorldAckEvery, acks);   // every 4th chunk and the last
        Assert.True(tx.AllAcked);
        Assert.Equal(SHA256.HashData(save).AsSpan(0, 8).ToArray(), Body(rx.BuildDone()));
        Assert.StartsWith(WorldReceiver.FilePrefix, Path.GetFileName(rx.FinalPath));
        rx.Dispose();
        Assert.True(File.Exists(rx.FinalPath), "a finished, verified file is kept for the next WO to place");
    }

    [Fact]
    public void A_corrupted_chunk_fails_the_hash_and_leaves_nothing_staged()
    {
        var save = WhsSaveTests.SyntheticSave();
        var tx = new WorldSender(save, 0xBAD, 1, 3, Md5Of(save), chunkSize: 256, windowBytes: 1024);
        var (ok, reason, why, rx, _, _) = Transfer(tx, (i, d) => { if (i == 2) d[100] ^= 0x40; return d; });
        Assert.False(ok);
        Assert.Equal(Protocol.JoinAbortHashMismatch, reason);
        Assert.Contains("sha256", why);
        Assert.False(File.Exists(rx.PartPath));
        Assert.False(File.Exists(rx.FinalPath));
        Assert.Empty(Directory.GetFiles(_dir));
    }

    [Fact]
    public void A_file_whose_hash_matches_but_is_no_save_fails_Verify_and_is_deleted()
    {
        var junk = RandomNumberGenerator.GetBytes(50_000);   // the offer's own hash: the transfer is intact, the content is not a save
        var tx = new WorldSender(junk, 0x51, 1, 3, new byte[16], chunkSize: 8192, windowBytes: 32768);
        var (ok, reason, why, rx, _, _) = Transfer(tx);
        Assert.False(ok);
        Assert.Equal(Protocol.JoinAbortVerifyFailed, reason);
        Assert.Contains("WhsSave.Verify", why);
        Assert.Empty(Directory.GetFiles(_dir));
    }

    [Fact]
    public void A_valid_save_that_is_not_the_offered_world_is_refused()
    {
        var save = WhsSaveTests.SyntheticSave();
        var other = Md5Of(WhsSaveTests.SyntheticSave("another-world"));
        var tx = new WorldSender(save, 0x52, 1, 3, other, chunkSize: 8192, windowBytes: 32768);
        var (ok, reason, why, _, _, _) = Transfer(tx);
        Assert.False(ok);
        Assert.Equal(Protocol.JoinAbortVerifyFailed, reason);
        Assert.Contains("offered world", why);
        Assert.Empty(Directory.GetFiles(_dir));
    }

    [Fact]
    public void Out_of_order_and_wrong_length_chunks_are_errors()
    {
        var save = WhsSaveTests.SyntheticSave();
        var tx = new WorldSender(save, 0x53, 1, 3, Md5Of(save), chunkSize: 256, windowBytes: 1024);
        using var rx = new WorldReceiver(_dir, 0x53, 0, tx.Offer);
        Assert.Equal(WorldReceiver.ChunkResult.Error, rx.Accept(1, new byte[256], out string why));
        Assert.Contains("out of order", why);
        Assert.Equal(WorldReceiver.ChunkResult.Error, rx.Accept(0, new byte[255], out why));
        Assert.Contains("expected 256", why);
        Assert.Equal(WorldReceiver.ChunkResult.Ok, rx.Accept(0, save.AsSpan(0, 256), out _));
        Assert.Equal(WorldReceiver.ChunkResult.Error, rx.Accept(0, save.AsSpan(0, 256), out why));   // a duplicate
    }

    // ---------------------------------------------------------------- aborts and the sweep

    [Fact]
    public void Abort_and_dispose_mid_transfer_delete_the_staging_file()
    {
        var save = WhsSaveTests.SyntheticSave();
        var tx = new WorldSender(save, 0x54, 1, 3, Md5Of(save), chunkSize: 256, windowBytes: 1024);
        var rx = new WorldReceiver(_dir, 0x54, 0, tx.Offer);
        rx.Accept(0, save.AsSpan(0, 256), out _);
        Assert.True(File.Exists(rx.PartPath));
        rx.Abort();
        Assert.False(File.Exists(rx.PartPath));
        Assert.Equal(WorldReceiver.ChunkResult.Error, rx.Accept(1, save.AsSpan(256, 256), out _));   // over

        var rx2 = new WorldReceiver(_dir, 0x55, 0, tx.Offer);
        rx2.Accept(0, save.AsSpan(0, 256), out _);
        rx2.Dispose();   // a disconnect: never finished
        Assert.Empty(Directory.GetFiles(_dir));
    }

    [Fact]
    public void The_sweep_removes_only_staging_files()
    {
        Directory.CreateDirectory(_dir);
        File.WriteAllText(Path.Combine(_dir, "world-0000abcd.part"), "x");
        File.WriteAllText(Path.Combine(_dir, "world-0000abce.whs"), "x");
        File.WriteAllText(Path.Combine(_dir, "notes.txt"), "keep");
        Assert.Equal(1, WorldReceiver.SweepStaging(_dir, keep: Path.Combine(_dir, "world-0000abce.whs")));
        Assert.Equal(1, WorldReceiver.SweepStaging(_dir));
        Assert.Equal(new[] { "notes.txt" }, Directory.GetFiles(_dir).Select(Path.GetFileName).ToArray());
        Assert.Equal(0, WorldReceiver.SweepStaging(Path.Combine(_dir, "missing")));
    }

    [Fact]
    public void Staging_lives_in_the_agent_data_folder_never_the_saves_folder()
    {
        string old = Environment.GetEnvironmentVariable("KCDMP_DATA_DIR") ?? "";
        try
        {
            Environment.SetEnvironmentVariable("KCDMP_DATA_DIR", "");
            string d = WorldReceiver.DefaultStagingDir();
            Assert.EndsWith(Path.Combine("KCDMP", "join-staging"), d);
            Assert.DoesNotContain("Saved Games", d);
            Environment.SetEnvironmentVariable("KCDMP_DATA_DIR", _dir);
            Assert.Equal(Path.Combine(_dir, "join-staging"), WorldReceiver.DefaultStagingDir());
        }
        finally { Environment.SetEnvironmentVariable("KCDMP_DATA_DIR", old); }
    }
}
