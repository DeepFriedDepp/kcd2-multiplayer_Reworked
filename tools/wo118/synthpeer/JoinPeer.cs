// WO-123 live test tool (tools/wo118, never shipped): a synthetic JOINER, and a
// synthetic host for the transfer-ceiling run.
//
// Joiner: connects to a real local relay AFTER the host (the host's agent must
// hold the lowest id = damage authority), asks for the world, receives it with
// the agent's own WorldReceiver (KcdMp.Client), checks SHA-256 + WhsSave.Verify,
// sends Done and, after --ready-after seconds, Ready. The staging folder is a
// temporary folder of its own and is deleted at exit: a received file is a real
// save and must never land in the repo or a log.
//
// usage: SynthPeer --join [--host 127.0.0.1] [--port 7778] [--name synth-joiner]
//                  [--request-after 1] [--ready-after 5] [--no-ready]
//                  [--corrupt-chunk N]            flip one byte of chunk N before it is written
//                  [--disconnect-after-chunks N]  drop the connection mid-transfer
//                  [--cancel-after-chunks N]      send JoinAbort joiner-cancel mid-transfer
//                  [--stall-after-chunks N]       stop reading (acks stop) -- the host's ack timeout
//                  [--linger 8]                   seconds to stay connected after the last step
//                  [--duration 400]               hard stop
//
// Synthetic host: connects FIRST, waits for a JoinRequest, sends --join-host <file>
// (or random:<bytes>) with the agent's own WorldSender, then waits for Done/abort
// and Ready. Measures the relay transfer alone.
//        SynthPeer --join-host <file|random:N> [--port 7778] [--name synth-host] [--duration 120]
using System.Buffers.Binary;
using System.Diagnostics;
using System.Globalization;
using System.Net.Sockets;
using System.Text;
using KcdMp.Client;
using KcdMp.Wire;

static class JoinPeer
{
    static string Arg(string[] a, string k, string d) { int i = Array.IndexOf(a, k); return i >= 0 && i + 1 < a.Length ? a[i + 1] : d; }
    static int IntArg(string[] a, string k, int d) => int.Parse(Arg(a, k, d.ToString(CultureInfo.InvariantCulture)), CultureInfo.InvariantCulture);
    static double DblArg(string[] a, string k, double d) => double.Parse(Arg(a, k, d.ToString(CultureInfo.InvariantCulture)), CultureInfo.InvariantCulture);

    static readonly Stopwatch Clock = Stopwatch.StartNew();
    static void Say(string s) => Console.WriteLine(FormattableString.Invariant($"SYNTH-JOIN t={Clock.Elapsed.TotalSeconds:F2}s {s}"));

    static async Task<(NetworkStream, byte, TcpClient)> ConnectAsync(string host, int port, string name, string release)
    {
        var tcp = new TcpClient { NoDelay = true };
        await tcp.ConnectAsync(host, port);
        var st = tcp.GetStream();
        var nb = Encoding.UTF8.GetBytes(name); var rb = Encoding.UTF8.GetBytes(release);
        int hl = 2 + nb.Length + rb.Length; var hs = new byte[3 + hl];
        hs[0] = Protocol.Handshake; BinaryPrimitives.WriteUInt16LittleEndian(hs.AsSpan(1), (ushort)hl);
        hs[3] = Protocol.Version; hs[4] = (byte)nb.Length; nb.CopyTo(hs, 5); rb.CopyTo(hs, 5 + nb.Length);
        await st.WriteAsync(hs);
        var (ty, pl) = await ReadPacket(st, CancellationToken.None);
        if (ty != Protocol.Ack) throw new IOException($"refused: 0x{ty:X2} {Encoding.UTF8.GetString(pl)}");
        return (st, pl[0], tcp);
    }

    static async Task<(byte, byte[])> ReadPacket(NetworkStream s, CancellationToken ct)
    {
        var h = new byte[3]; await ReadExact(s, h, ct);
        int len = BinaryPrimitives.ReadUInt16LittleEndian(h.AsSpan(1));
        var b = new byte[len]; await ReadExact(s, b, ct);
        return (h[0], b);
    }
    static async Task ReadExact(NetworkStream s, byte[] b, CancellationToken ct)
    {
        int got = 0; while (got < b.Length) { int n = await s.ReadAsync(b.AsMemory(got), ct); if (n <= 0) throw new IOException("closed"); got += n; }
    }
    static byte[] BodyOf(byte[] down) => down.AsSpan(1 + Protocol.JoinHeaderLen).ToArray();

    public static async Task<int> RunJoinerAsync(string[] a, string release)
    {
        string host = Arg(a, "--host", "127.0.0.1"); int port = IntArg(a, "--port", 7778);
        string name = Arg(a, "--name", "synth-joiner");
        double requestAfter = DblArg(a, "--request-after", 1), readyAfter = DblArg(a, "--ready-after", 5), linger = DblArg(a, "--linger", 8);
        bool noReady = a.Contains("--no-ready");
        int corrupt = IntArg(a, "--corrupt-chunk", -1), dropAfter = IntArg(a, "--disconnect-after-chunks", -1);
        int cancelAfter = IntArg(a, "--cancel-after-chunks", -1), stallAfter = IntArg(a, "--stall-after-chunks", -1);
        double duration = DblArg(a, "--duration", 400);

        string staging = Path.Combine(Path.GetTempPath(), "kcdmp-synthjoin-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(staging);
        using var hard = new CancellationTokenSource(TimeSpan.FromSeconds(duration));
        var (st, myId, tcp) = await ConnectAsync(host, port, name, release);
        Say($"connected id={myId} release={release} staging=<temp> options corrupt={corrupt} drop_after={dropAfter} cancel_after={cancelAfter} stall_after={stallAfter} ready_after={(noReady ? "never" : readyAfter.ToString(CultureInfo.InvariantCulture))}");
        uint joinId = (uint)Random.Shared.Next(1, int.MaxValue);
        WorldReceiver? rx = null;
        double tRequest = 0, tOffer = 0, tDone = 0;
        int chunks = 0;
        int rc = 0;
        bool stalled = false;   // --stall-after-chunks: stops reading AND the heartbeat, like a hung agent
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(requestAfter), hard.Token);
            await st.WriteAsync(WorldReceiver.BuildRequest(joinId), hard.Token);
            tRequest = Clock.Elapsed.TotalSeconds;
            Say($"JoinRequest join=0x{joinId:x8} sent");
            double readyAt = double.MaxValue, lingerUntil = double.MaxValue, lastHb = 0;
            var readTask = ReadPacket(st, hard.Token);
            while (true)
            {
                double now = Clock.Elapsed.TotalSeconds;
                if (now >= lingerUntil) break;
                // A joiner at the main menu still sends the agent's 2 s stale-position
                // heartbeat; without it the relay's 30 s idle timeout drops the peer.
                if (now - lastHb >= 2 && !stalled)
                {
                    await st.WriteAsync(PositionCodec.BuildPosition(0, 0, 0, 0, false, true, null), hard.Token);
                    lastHb = now;
                }
                if (now >= readyAt)
                {
                    await st.WriteAsync(WorldReceiver.BuildReady(joinId, rx?.Offer.WorldSavedSeq ?? 0), hard.Token);
                    Say(FormattableString.Invariant($"JoinerReady sent ({now - tDone:F1} s after the file verified) -- the host should resume now"));
                    readyAt = double.MaxValue;
                    lingerUntil = now + linger;
                }
                var tick = Task.Delay(100, hard.Token);
                if (await Task.WhenAny(readTask, tick) != readTask) continue;
                var (type, p) = await readTask;
                readTask = ReadPacket(st, hard.Token);
                if (!Protocol.IsJoinDown(type, p.Length)) continue;
                var body = BodyOf(p);
                switch (type)
                {
                    case Protocol.JoinStatusDown:
                        JoinStatusCodec.TryDecode(body, out byte s, out byte r, out ushort arg);
                        Say($"host status {Protocol.JoinStateName(s)} reason={Protocol.JoinReasonName(r)} arg={arg}");
                        if (s == Protocol.JoinStateResumed && lingerUntil == double.MaxValue) lingerUntil = Clock.Elapsed.TotalSeconds + 2;
                        break;
                    case Protocol.WorldOfferDown:
                    {
                        var o = WorldOffer.TryDecode(body, out string why);
                        if (o is null) { Say($"offer REFUSED: {why}"); rc = 3; await st.WriteAsync(WorldReceiver.BuildAbort(Protocol.JoinTargetHost, joinId, Protocol.JoinAbortProtocol)); break; }
                        tOffer = Clock.Elapsed.TotalSeconds;
                        rx = new WorldReceiver(staging, joinId, p[0], o.Value);
                        Say(FormattableString.Invariant($"offer bytes={o.Value.Size} chunks={o.Value.ChunkCount} sha256={Convert.ToHexString(o.Value.Sha256)[..16].ToLowerInvariant()} worldsaved_seq={o.Value.WorldSavedSeq} md5={Convert.ToHexString(o.Value.Md5)[..8].ToLowerInvariant()} request_to_offer_s={tOffer - tRequest:F2}"));
                        break;
                    }
                    case Protocol.WorldChunkDown:
                    {
                        if (rx is null) break;
                        if (stallAfter >= 0 && chunks >= stallAfter)
                        {
                            stalled = true;
                            lingerUntil = Math.Min(lingerUntil, Clock.Elapsed.TotalSeconds + linger);
                            if (chunks == stallAfter) Say($"stalling after {chunks} chunks: no more reads or acks (the host's ack timeout should fire)");
                            chunks++;
                            // stop reading: park until the host gives up
                            readTask = Task.Delay(Timeout.Infinite, hard.Token).ContinueWith(_ => ((byte)0, Array.Empty<byte>()));
                            break;
                        }
                        uint idx = BinaryPrimitives.ReadUInt32LittleEndian(body);
                        var data = body.AsSpan(4).ToArray();
                        if ((int)idx == corrupt) { data[data.Length / 2] ^= 0x5A; Say($"corrupted chunk {idx} (one byte flipped) before writing it"); }
                        var res = rx.Accept(idx, data, out string why);
                        chunks++;
                        if (res == WorldReceiver.ChunkResult.Error)
                        {
                            Say($"chunk refused ({why}) -> abort");
                            rx.Abort();
                            await st.WriteAsync(WorldReceiver.BuildAbort(Protocol.JoinTargetHost, joinId, Protocol.JoinAbortProtocol));
                            rc = 4; lingerUntil = Clock.Elapsed.TotalSeconds + linger; break;
                        }
                        if (res is WorldReceiver.ChunkResult.AckDue or WorldReceiver.ChunkResult.Complete) await st.WriteAsync(rx.BuildAck());
                        if (dropAfter >= 0 && chunks >= dropAfter)
                        {
                            Say($"dropping the connection after {chunks} chunks ({rx.Received} B) -- the host should resume");
                            rx.Abort();
                            tcp.Close();
                            Say($"staging after the drop: {Directory.GetFiles(staging).Length} file(s)");
                            return 0;
                        }
                        if (cancelAfter >= 0 && chunks >= cancelAfter)
                        {
                            Say($"cancelling after {chunks} chunks (JoinAbort joiner-cancel)");
                            rx.Abort();
                            await st.WriteAsync(WorldReceiver.BuildAbort(Protocol.JoinTargetHost, joinId, Protocol.JoinAbortJoinerCancel));
                            cancelAfter = -1;
                            lingerUntil = Clock.Elapsed.TotalSeconds + linger;
                            break;
                        }
                        if (res == WorldReceiver.ChunkResult.Complete)
                        {
                            double xfer = Clock.Elapsed.TotalSeconds - tOffer;
                            var (ok, reason, fwhy) = rx.Finish();
                            tDone = Clock.Elapsed.TotalSeconds;
                            if (!ok)
                            {
                                Say(FormattableString.Invariant($"file REJECTED after {xfer:F2} s: {fwhy} -> JoinAbort {Protocol.JoinAbortName(reason)}; staging now {Directory.GetFiles(staging).Length} file(s)"));
                                await st.WriteAsync(WorldReceiver.BuildAbort(Protocol.JoinTargetHost, joinId, reason));
                                rc = 5; lingerUntil = Clock.Elapsed.TotalSeconds + linger; break;
                            }
                            await st.WriteAsync(rx.BuildDone());
                            Say(FormattableString.Invariant($"file OK: {rx.Received} B in {xfer:F2} s ({rx.Received / 1048576.0 / Math.Max(xfer, 1e-3):F2} MB/s), sha256 = the offer's, WhsSave.Verify ok, md5 = the offer's; Done sent"));
                            if (!noReady) readyAt = Clock.Elapsed.TotalSeconds + readyAfter;
                            else { Say("--no-ready: never sending Ready (the host's safety timeout should fire)"); }
                        }
                        break;
                    }
                    case Protocol.JoinAbortDown:
                        Say($"host aborted: {Protocol.JoinAbortName(body.Length > 0 ? body[0] : (byte)0)}");
                        rx?.Abort();
                        lingerUntil = Math.Min(lingerUntil, Clock.Elapsed.TotalSeconds + 2);
                        break;
                }
            }
        }
        catch (OperationCanceledException) { Say("duration reached"); }
        catch (IOException ex) { Say($"connection ended: {ex.Message}"); }
        finally
        {
            rx?.Dispose();
            int left = Directory.Exists(staging) ? Directory.GetFiles(staging).Length : 0;
            try { Directory.Delete(staging, true); } catch { }
            Say($"done rc={rc} chunks={chunks} staging_files_at_exit={left} (the folder is deleted: a received world is a real save)");
            tcp.Dispose();
        }
        return rc;
    }

    public static async Task<int> RunHostAsync(string[] a, string release)
    {
        string host = Arg(a, "--host", "127.0.0.1"); int port = IntArg(a, "--port", 7778);
        string name = Arg(a, "--name", "synth-host");
        string src = Arg(a, "--join-host", "");
        double duration = DblArg(a, "--duration", 120);
        byte[] file = src.StartsWith("random:", StringComparison.Ordinal)
            ? System.Security.Cryptography.RandomNumberGenerator.GetBytes(int.Parse(src[7..], CultureInfo.InvariantCulture))
            : File.ReadAllBytes(src);
        using var hard = new CancellationTokenSource(TimeSpan.FromSeconds(duration));
        var (st, myId, tcp) = await ConnectAsync(host, port, name, release);
        Say($"host connected id={myId} file_bytes={file.Length} ({(src.StartsWith("random:") ? "random bytes" : "a file")})");
        try
        {
            while (true)
            {
                var (type, p) = await ReadPacket(st, hard.Token);
                if (type != Protocol.JoinRequestDown || !Protocol.TrySplitJoinDown(p, out byte joiner, out _, out uint joinId, out _)) continue;
                Say($"JoinRequest 0x{joinId:x8} from {joiner}");
                var tx = new WorldSender(file, joinId, joiner, 1, new byte[16]);
                await st.WriteAsync(tx.BuildOfferPacket(), hard.Token);
                var t0 = Clock.Elapsed.TotalSeconds;
                while (true)
                {
                    foreach (var pkt in tx.TakeSendable()) await st.WriteAsync(pkt, hard.Token);
                    var (rt, rp) = await ReadPacket(st, hard.Token);
                    if (!Protocol.IsJoinDown(rt, rp.Length)) continue;
                    var body = BodyOf(rp);
                    if (rt == Protocol.WorldAckDown) tx.OnAck(BinaryPrimitives.ReadUInt32LittleEndian(body), out _);
                    else if (rt == Protocol.WorldDoneDown || rt == Protocol.JoinAbortDown)
                    {
                        double s = Clock.Elapsed.TotalSeconds - t0;
                        Say(FormattableString.Invariant($"{(rt == Protocol.WorldDoneDown ? "Done" : "JoinAbort " + Protocol.JoinAbortName(body[0]))} after {s:F2} s; acked {tx.AckedBytes}/{tx.TotalBytes} B = {tx.AckedBytes / 1048576.0 / Math.Max(s, 1e-3):F2} MB/s through the relay"));
                        return 0;
                    }
                }
            }
        }
        catch (OperationCanceledException) { Say("duration reached"); return 1; }
        finally { tcp.Dispose(); }
    }
}
