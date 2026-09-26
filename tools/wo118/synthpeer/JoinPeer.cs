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
// Synthetic host (WO-124: what a REAL joiner game joins): connects FIRST, announces
// its session mode, streams its avatar, waits for a JoinRequest, sends --join-host
// <file> (a copy of a real host save, or random:<bytes>) with the agent's own
// WorldSender and the host's status sequence, then waits for Done/abort and Ready.
// Options: see RunHostAsync.
using System.Buffers.Binary;
using System.Diagnostics;
using System.Globalization;
using System.Net.Sockets;
using System.Text;
using KcdMp.Client;
using KcdMp.Wire;
using System.Linq;

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

    // WO-124: the synthetic HOST a real joiner game joins. Connect it FIRST (id 0 =
    // the damage authority). It announces its session mode to peers 1..7 every
    // 5 s (JoinStatus state "session", joinId 0, as a WO-124 host agent does),
    // streams its avatar at --host-pos every second, and on a JoinRequest sends
    // --join-host <file> (a COPY of a real host save; never logged by path) with
    // the agent's own WorldSender and the real host's status sequence, then
    // waits for the joiner's Done and Ready ("the host resumes") or an abort.
    //        SynthPeer --join-host <file|random:N> [--port 7778] [--name synth-host] [--duration 600]
    //                  [--host-pos x,y,z] [--shared on|off] [--corrupt-chunk N] [--ready-wait 240]
    //                  [--leave-after-ready S]   disconnect S seconds after Ready (the joiner must leave the world)
    //                  [--serve 1]               joins to serve before staying idle
    // The offer carries the save's OWN footer MD5 (the joiner checks it against the file); random bytes have none.
    static byte[] FooterMd5(byte[] file)
    {
        var v = WhsSave.Verify(file);
        return v.Md5.Length == 32 ? Convert.FromHexString(v.Md5) : new byte[16];
    }

    public static async Task<int> RunHostAsync(string[] a, string release)
    {
        string host = Arg(a, "--host", "127.0.0.1"); int port = IntArg(a, "--port", 7778);
        string name = Arg(a, "--name", "synth-host");
        string src = Arg(a, "--join-host", "");
        double duration = DblArg(a, "--duration", 600), readyWait = DblArg(a, "--ready-wait", 240);
        double leaveAfterReady = DblArg(a, "--leave-after-ready", -1);
        int corrupt = IntArg(a, "--corrupt-chunk", -1), serve = IntArg(a, "--serve", 1);
        bool shared = Arg(a, "--shared", "on") != "off";
        var hp = Arg(a, "--host-pos", "0,0,0").Split(',').Select(v => float.Parse(v, CultureInfo.InvariantCulture)).ToArray();
        byte[] file = src.StartsWith("random:", StringComparison.Ordinal)
            ? System.Security.Cryptography.RandomNumberGenerator.GetBytes(int.Parse(src[7..], CultureInfo.InvariantCulture))
            : File.ReadAllBytes(src);
        using var hard = new CancellationTokenSource(TimeSpan.FromSeconds(duration));
        var (st, myId, tcp) = await ConnectAsync(host, port, name, release);
        Say(FormattableString.Invariant($"host connected id={myId} file_bytes={file.Length} ({(src.StartsWith("random:") ? "random bytes" : "a host save copy")}) mode={(shared ? "shared-world" : "separate")} pos={hp[0]:F1},{hp[1]:F1},{hp[2]:F1}"));
        var wlock = new SemaphoreSlim(1, 1);
        async Task W(byte[] pkt) { await wlock.WaitAsync(); try { await st.WriteAsync(pkt, hard.Token); } finally { wlock.Release(); } }
        // Heartbeat: the avatar every second, the session mode every 5 s.
        _ = Task.Run(async () =>
        {
            int n = 0;
            try
            {
                while (!hard.IsCancellationRequested)
                {
                    await W(PositionCodec.BuildPosition(hp[0], hp[1], hp[2], 0, false, false, null));
                    if (n++ % 5 == 0)
                        for (byte g = 1; g < 8; g++)
                            await W(JoinStatusCodec.Build(g, 0, Protocol.JoinStateSession, Protocol.JoinReasonId(shared ? "shared-world" : "separate"), 0));
                    await Task.Delay(1000, hard.Token);
                }
            }
            catch { }
        });
        int served = 0, rc = 0;
        try
        {
            while (served < serve)
            {
                var (type, p) = await ReadPacket(st, hard.Token);
                if (type != Protocol.JoinRequestDown || !Protocol.TrySplitJoinDown(p, out byte joiner, out _, out uint joinId, out _)) continue;
                served++;
                Say($"JoinRequest 0x{joinId:x8} from {joiner}");
                if (!shared)
                {
                    await W(JoinStatusCodec.Build(joiner, joinId, Protocol.JoinStateRefused, Protocol.JoinReasonId("shared-world-off"), 0));
                    Say("refused: shared-world-off (as a real host with mp_shared_world off)");
                    continue;
                }
                var t0 = Clock.Elapsed.TotalSeconds;
                await W(JoinStatusCodec.Build(joiner, joinId, Protocol.JoinStatePaused, 0, 0));
                Say("world 'paused' (synthetic: nothing to pause)");
                await W(JoinStatusCodec.Build(joiner, joinId, Protocol.JoinStateSaving, 0, 0));
                var tx = new WorldSender(file, joinId, joiner, 1, FooterMd5(file));
                await W(JoinStatusCodec.Build(joiner, joinId, Protocol.JoinStateSending, 0, 0));
                await W(tx.BuildOfferPacket());
                bool done = false, ended = false;
                double tDone = 0;
                while (!ended)
                {
                    foreach (var pkt in tx.TakeSendable())
                    {
                        if (corrupt >= 0 && pkt.Length > 16 && BinaryPrimitives.ReadUInt32LittleEndian(pkt.AsSpan(8)) == (uint)corrupt)
                        {
                            pkt[pkt.Length / 2] ^= 0x5A;
                            Say($"corrupted chunk {corrupt} (one byte flipped) on the way out");
                        }
                        await W(pkt);
                    }
                    var rt = ReadPacket(st, hard.Token);
                    double left = done ? readyWait - (Clock.Elapsed.TotalSeconds - tDone) : 60;
                    if (await Task.WhenAny(rt, Task.Delay(TimeSpan.FromSeconds(Math.Max(1, left)), hard.Token)) != rt)
                    {
                        Say(done ? $"no Ready {readyWait:F0} s after Done -- the host would resume (timeout)" : "no ack/Done for 60 s -- the host would resume (timeout)");
                        await W(WorldReceiver.BuildAbort(joiner, joinId, Protocol.JoinAbortTimeout));
                        rc = 2; ended = true; break;
                    }
                    var (ty, rp) = await rt;
                    if (!Protocol.IsJoinDown(ty, rp.Length)) continue;
                    var body = BodyOf(rp);
                    double now = Clock.Elapsed.TotalSeconds;
                    switch (ty)
                    {
                        case Protocol.WorldAckDown: tx.OnAck(BinaryPrimitives.ReadUInt32LittleEndian(body), out _); break;
                        case Protocol.WorldDoneDown:
                            done = true; tDone = now;
                            Say(FormattableString.Invariant($"Done after {now - t0:F2} s (acked {tx.AckedBytes}/{tx.TotalBytes} B); waiting for Ready (up to {readyWait:F0} s)"));
                            await W(JoinStatusCodec.Build(joiner, joinId, Protocol.JoinStateWaitingReady, 0, 0));
                            break;
                        case Protocol.JoinerReadyDown:
                            Say(FormattableString.Invariant($"Ready {now - tDone:F1} s after Done ({now - t0:F1} s after the request) -- THE HOST RESUMES (ready)"));
                            await W(JoinStatusCodec.Build(joiner, joinId, Protocol.JoinStateResumed, Protocol.JoinReasonId("ready"), (ushort)(now - t0)));
                            ended = true;
                            break;
                        case Protocol.JoinAbortDown:
                            Say(FormattableString.Invariant($"JoinAbort {Protocol.JoinAbortName(body.Length > 0 ? body[0] : (byte)0)} after {now - t0:F1} s -- THE HOST RESUMES (failed)"));
                            await W(JoinStatusCodec.Build(joiner, joinId, Protocol.JoinStateResumed, Protocol.JoinReasonId("failed"), (ushort)(now - t0)));
                            rc = 3; ended = true;
                            break;
                    }
                }
                if (rc == 0 && leaveAfterReady >= 0)
                {
                    await Task.Delay(TimeSpan.FromSeconds(leaveAfterReady), hard.Token);
                    Say($"leaving {leaveAfterReady:F0} s after Ready (disconnect) -- the joiner must leave the host's world");
                    tcp.Close();
                    return rc;
                }
            }
            // stay up (heartbeat) until the duration ends
            await Task.Delay(Timeout.Infinite, hard.Token);
        }
        catch (OperationCanceledException) { Say("duration reached"); }
        catch (IOException ex) { Say($"connection ended: {ex.Message}"); }
        finally { tcp.Dispose(); }
        return rc;
    }
}
