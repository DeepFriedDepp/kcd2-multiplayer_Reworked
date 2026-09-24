using System.Diagnostics;
using System.Runtime.InteropServices;
using KcdMp.Steam;

namespace KcdMp.SteamProbe;

/// <summary>
/// The joiner side for one app id. Drives the whole test; the host only
/// answers. Every line it prints is a measurement with no identifiers in it.
/// </summary>
internal static class ProbeJoin
{
    private const int MessagesChannel = 1, LegacyChannel = 2;

    public static async Task<int> RunAsync(SteamSession s, ulong host, int gameSeconds, string apis, CancellationToken ct)
    {
        FriendCheck(s, host);

        bool socketsOk = false, messagesOk = false, legacyOk = false;
        SteamP2PConnection? conn = null;
        if (apis is "all" or "sockets")
            (socketsOk, conn) = await SocketsAsync(s, host, gameSeconds, ct);
        if (apis is "all" or "messages")
            messagesOk = await MessagesAsync(s, host, ct);
        if (apis is "all" or "legacy")
            legacyOk = await LegacyAsync(s, host, ct);

        // Tell the host to move on, on every path that might be listening.
        if (conn is { IsConnected: true })
        {
            try { await F.WriteAsync(conn.GetStream(), new SemaphoreSlim(1, 1), F.Done, Array.Empty<byte>(), ct); } catch { }
        }
        SendMessage(s, host, [F.Done]);
        SendLegacy(s, host, [F.Done]);
        await Task.Delay(1500, ct);
        conn?.Close("probe done");

        Out.Line($"WO120 join app={s.AppId} verdict sockets={(socketsOk ? "PASS" : "FAIL")} messages={(messagesOk ? "PASS" : "FAIL")} legacy={(legacyOk ? "PASS" : "FAIL")}");
        return socketsOk || messagesOk || legacyOk ? 0 : 4;
    }

    /// <summary>Phase 2's discovery question: can a joiner see the host from the friends list alone?</summary>
    private static void FriendCheck(SteamSession s, ulong host)
    {
        try
        {
            int total = s.FriendCount();
            var inApp = s.FriendsInThisApp("kcdmp_probe");
            bool hostIsFriendInApp = inApp.Any(f => f.SteamId == host);
            bool hostPresence = inApp.Any(f => f.SteamId == host && f.Value == "host");
            int hostingCount = inApp.Count(f => f.Value == "host");
            Out.Line($"WO120 join app={s.AppId} friends_total_bucket={Bucket(total)} friends_in_app={inApp.Count} hosting_in_app={hostingCount} host_seen_in_app={(hostIsFriendInApp ? 1 : 0)} host_presence_seen={(hostPresence ? 1 : 0)}");
        }
        catch (Exception ex) { Out.Line($"WO120 join friend_check_failed {ex.GetType().Name}"); }
    }

    private static string Bucket(int n) => n == 0 ? "0" : n < 10 ? "1-9" : n < 50 ? "10-49" : "50+";

    // ------------------------------------------------------------------ sockets

    private static async Task<(bool, SteamP2PConnection?)> SocketsAsync(SteamSession s, ulong host, int gameSeconds, CancellationToken ct)
    {
        var budget = Stopwatch.StartNew();
        SteamP2PConnection? c = null;
        int attempts = 0;
        long connectMs = -1;
        while (budget.Elapsed < TimeSpan.FromSeconds(120) && !ct.IsCancellationRequested)
        {
            attempts++;
            var t0 = Stopwatch.StartNew();
            c = s.Connect(host, F.VirtualPort);
            var won = await Task.WhenAny(c.WhenConnected, Task.Delay(TimeSpan.FromSeconds(30), ct));
            if (won == c.WhenConnected && c.WhenConnected.Result) { connectMs = t0.ElapsedMilliseconds; break; }
            Out.Line($"WO120 join api=sockets attempt={attempts} failed_after_ms={t0.ElapsedMilliseconds} state={c.State} end_reason={c.EndReason} debug=\"{SteamLogScrub.Scrub(c.EndDebug)}\"");
            c.Close("retry");
            c = null;
            await Task.Delay(3000, ct);
        }
        if (c is null)
        {
            Out.Line($"WO120 join api=sockets result=NO-CONNECTION attempts={attempts} waited_s={(int)budget.Elapsed.TotalSeconds}");
            return (false, null);
        }
        int flags = c.InfoFlags();
        Out.Line(Out.Inv($"WO120 join api=sockets result=CONNECTED connect_ms={connectMs} attempts={attempts} relayed={((flags & SteamNative.InfoFlagRelayed) != 0 ? 1 : 0)} flags={flags}"));

        var stream = c.GetStream();
        var gate = new SemaphoreSlim(1, 1);
        using var readerCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var st = new JoinStats();
        var reader = Task.Run(() => ReadLoopAsync(stream, gate, st, readerCts.Token));
        bool ok = true;
        try
        {
            // Handshake round trip.
            var hs = Stopwatch.StartNew();
            await F.WriteAsync(stream, gate, F.Hello, F.U32(120), ct);
            await st.HelloAck.Task.WaitAsync(TimeSpan.FromSeconds(10), ct);
            Out.Line($"WO120 join api=sockets handshake_ms={hs.ElapsedMilliseconds}");

            // Idle ping: 100 at 20 Hz.
            st.Rtt = new Samples();
            for (uint i = 0; i < 100; i++) { await F.WriteAsync(stream, gate, F.Ping, F.PingPayload(i), ct); await Task.Delay(50, ct); }
            await Task.Delay(1000, ct);
            Out.Line($"WO120 join api=sockets idle_rtt {st.Rtt.Summary()} steam_ping_ms={c.PingMs}");

            // A session's worth of traffic.
            st.Rtt = new Samples();
            st.ResetGame();
            await F.WriteAsync(stream, gate, F.StartGame, F.U32((uint)gameSeconds), ct);
            var link = new List<SteamLinkStatus>();
            var game = Stopwatch.StartNew();
            uint stateSeq = 0, pingSeq = 1000;
            long nextState = 0, nextPing = 0, nextSample = 5000;
            while (game.Elapsed < TimeSpan.FromSeconds(gameSeconds))
            {
                long now = game.ElapsedMilliseconds;
                if (now >= nextState) { await F.WriteAsync(stream, gate, F.State, F.Patterned(stateSeq++, F.StateBytes), ct); nextState += 50; }
                if (now >= nextPing) { await F.WriteAsync(stream, gate, F.Ping, F.PingPayload(pingSeq++), ct); nextPing += 100; }
                if (now >= nextSample) { if (c.RealTimeStatus() is { } ls) link.Add(ls); nextSample += 5000; }
                await Task.Delay(1, ct);
            }
            await Task.Delay(1500, ct);
            await F.WriteAsync(stream, gate, F.EndGame, Array.Empty<byte>(), ct);
            string? hostView = await st.HostStats.Task.WaitAsync(TimeSpan.FromSeconds(10), ct);

            double secs = gameSeconds;
            Out.Line(Out.Inv($"WO120 join api=sockets game_rtt {st.Rtt.Summary()}"));
            Out.Line(Out.Inv($"WO120 join api=sockets game_rx state_ok={st.StateOk} state_bad={st.StateBad} npc_ok={st.NpcOk} npc_bad={st.NpcBad} burst_chunks_ok={st.BurstOk} burst_bad={st.BurstBad} rx_kbps={st.GameBytes / 1024.0 / secs:0.0}"));
            Out.Line(Out.Inv($"WO120 join api=sockets game_state_gaps over100ms={st.GapsOver100} over250ms={st.GapsOver250} max_gap_ms={st.MaxGapMs:0.0}"));
            if (link.Count > 0)
                Out.Line(Out.Inv($"WO120 join api=sockets steam_link samples={link.Count} ping_ms_max={link.Max(l => l.PingMs)} q_local_min={link.Min(l => l.QualityLocal):0.00} q_remote_min={link.Min(l => l.QualityRemote):0.00} send_rate_kbps_min={link.Min(l => l.SendRateBytesPerSec) / 1024} pending_reliable_max={link.Max(l => l.PendingReliable)}"));
            Out.Line("WO120 join api=sockets " + (hostView ?? "host_view=missing"));
            ok &= st.StateBad == 0 && st.NpcBad == 0 && st.BurstBad == 0 && st.StateOk > 0 && st.NpcOk > 0;

            // Bulk ceiling: 4 MB host -> joiner.
            const int bulk = 4 * 1024 * 1024;
            st.BulkDone = new TaskCompletionSource<long>(TaskCreationOptions.RunContinuationsAsynchronously);
            st.BulkExpected = bulk / F.ChunkBytes;
            var bw = Stopwatch.StartNew();
            await F.WriteAsync(stream, gate, F.BulkReq, F.U32(bulk), ct);
            await st.BulkDone.Task.WaitAsync(TimeSpan.FromSeconds(60), ct);
            Out.Line(Out.Inv($"WO120 join api=sockets bulk bytes={bulk} ms={bw.ElapsedMilliseconds} mbps={bulk * 8.0 / 1e6 / bw.Elapsed.TotalSeconds:0.0} bulk_bad={st.BulkBad}"));
            ok &= st.BulkBad == 0;
        }
        catch (Exception ex)
        {
            ok = false;
            Out.Line($"WO120 join api=sockets aborted why={ex.GetType().Name} state={c.State} end_reason={c.EndReason} debug=\"{SteamLogScrub.Scrub(c.EndDebug)}\"");
        }
        Out.Line($"WO120 join api=sockets result={(ok ? "PASS" : "FAIL")}");
        return (ok, c);
    }

    private sealed class JoinStats
    {
        public readonly TaskCompletionSource HelloAck = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public readonly TaskCompletionSource<string?> HostStats = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource<long>? BulkDone;
        public int BulkExpected;
        public Samples Rtt = new();
        public long StateOk, StateBad, NpcOk, NpcBad, BurstOk, BurstBad, BulkOk, BulkBad, GameBytes;
        public long GapsOver100, GapsOver250;
        public double MaxGapMs;
        public uint ExpectState, ExpectNpc, ExpectBulk;
        public long LastState;
        public void ResetGame() { ExpectState = 0; ExpectNpc = 0; LastState = 0; }
    }

    private static async Task ReadLoopAsync(Stream stream, SemaphoreSlim gate, JoinStats st, CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var (type, p) = await F.ReadAsync(stream, ct);
                switch (type)
                {
                    case F.HelloAck: st.HelloAck.TrySetResult(); break;
                    case F.Pong: st.Rtt.Add(F.PingRttMs(p)); break;
                    case F.State:
                    {
                        uint seq = F.U32(p);
                        if (seq == st.ExpectState && F.CheckPattern(p, seq)) st.StateOk++; else st.StateBad++;
                        st.ExpectState = seq + 1;
                        st.GameBytes += p.Length + 5;
                        long now = Stopwatch.GetTimestamp();
                        if (st.LastState != 0)
                        {
                            double gap = Stopwatch.GetElapsedTime(st.LastState, now).TotalMilliseconds;
                            if (gap > 100) st.GapsOver100++;
                            if (gap > 250) st.GapsOver250++;
                            if (gap > st.MaxGapMs) st.MaxGapMs = gap;
                        }
                        st.LastState = now;
                        break;
                    }
                    case F.Npc:
                    {
                        uint seq = F.U32(p);
                        if (seq == st.ExpectNpc && F.CheckPattern(p, seq)) st.NpcOk++; else st.NpcBad++;
                        st.ExpectNpc = seq + 1;
                        st.GameBytes += p.Length + 5;
                        break;
                    }
                    case F.Burst:
                    {
                        uint id = F.U32(p);
                        if (F.CheckPattern(p, id, 8)) st.BurstOk++; else st.BurstBad++;
                        st.GameBytes += p.Length + 5;
                        if (p[4] == p[5] - 1) await F.WriteAsync(stream, gate, F.BurstAck, F.U32(id), ct);
                        break;
                    }
                    case F.Stats: st.HostStats.TrySetResult(System.Text.Encoding.UTF8.GetString(p)); break;
                    case F.Bulk:
                    {
                        uint i = F.U32(p);
                        if (i == st.ExpectBulk && F.CheckPattern(p, i)) st.BulkOk++; else st.BulkBad++;
                        st.ExpectBulk = i + 1;
                        if (st.ExpectBulk == st.BulkExpected) st.BulkDone?.TrySetResult(0);
                        break;
                    }
                }
            }
        }
        catch (Exception ex) when (ex is EndOfStreamException or IOException or OperationCanceledException)
        {
            st.HelloAck.TrySetException(ex);
            st.HostStats.TrySetResult(null);
            st.BulkDone?.TrySetException(ex);
        }
    }

    // ------------------------------------------------------------------ messages

    private static bool SendMessage(SteamSession s, ulong host, byte[] data)
    {
        var id = SteamNative.Identity.FromSteamId(host);
        unsafe
        {
            fixed (byte* p = data)
                return SteamNative.SteamAPI_ISteamNetworkingMessages_SendMessageToUser(s.Messages, ref id, p, (uint)data.Length, SteamNative.SendReliableNoNagle, MessagesChannel) == SteamNative.ResultOk;
        }
    }

    private static async Task<bool> MessagesAsync(SteamSession s, ulong host, CancellationToken ct)
    {
        var rtt = new Samples();
        var first = Stopwatch.StartNew();
        long firstReplyMs = -1;
        var msgs = new IntPtr[32];
        uint sent = 0;
        int sendFail = 0;
        var sw = Stopwatch.StartNew();
        long nextSend = 0;
        while (sw.Elapsed < TimeSpan.FromSeconds(45) && rtt.Count < 50)
        {
            if (sw.ElapsedMilliseconds >= nextSend && sent < 200)
            {
                if (!SendMessage(s, host, F.PingPayload(sent++))) sendFail++;
                nextSend += firstReplyMs < 0 ? 500 : 50;
            }
            int n = SteamNative.SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel(s.Messages, MessagesChannel, msgs, msgs.Length);
            for (int i = 0; i < n; i++)
            {
                int size = Marshal.ReadInt32(msgs[i], SteamNative.Msg.Size);
                var d = new byte[size];
                Marshal.Copy(Marshal.ReadIntPtr(msgs[i], SteamNative.Msg.Data), d, 0, size);
                SteamNative.SteamAPI_SteamNetworkingMessage_t_Release(msgs[i]);
                if (size != 12) continue;
                if (firstReplyMs < 0) firstReplyMs = first.ElapsedMilliseconds;
                rtt.Add(F.PingRttMs(d));
            }
            await Task.Delay(1, ct);
        }
        bool ok = rtt.Count >= 50;
        Out.Line($"WO120 join api=messages result={(ok ? "PASS" : "FAIL")} first_reply_ms={firstReplyMs} sent={sent} send_fail={sendFail} rtt {rtt.Summary()}");
        return ok;
    }

    // ------------------------------------------------------------------ legacy

    private static bool SendLegacy(SteamSession s, ulong host, byte[] data)
    {
        unsafe { fixed (byte* p = data) return SteamNative.SteamAPI_ISteamNetworking_SendP2PPacket(s.Legacy, host, p, (uint)data.Length, SteamNative.P2PReliable, LegacyChannel); }
    }

    private static async Task<bool> LegacyAsync(SteamSession s, ulong host, CancellationToken ct)
    {
        var rtt = new Samples();
        var first = Stopwatch.StartNew();
        long firstReplyMs = -1;
        var buf = new byte[1024];
        uint sent = 0;
        int sendFail = 0;
        var sw = Stopwatch.StartNew();
        long nextSend = 0;
        while (sw.Elapsed < TimeSpan.FromSeconds(45) && rtt.Count < 50)
        {
            if (sw.ElapsedMilliseconds >= nextSend && sent < 200)
            {
                if (!SendLegacy(s, host, F.PingPayload(sent++))) sendFail++;
                nextSend += firstReplyMs < 0 ? 500 : 50;
            }
            while (SteamNative.SteamAPI_ISteamNetworking_IsP2PPacketAvailable(s.Legacy, out _, LegacyChannel)
                   && SteamNative.SteamAPI_ISteamNetworking_ReadP2PPacket(s.Legacy, buf, (uint)buf.Length, out uint got, out _, LegacyChannel))
            {
                if (got != 12) continue;
                if (firstReplyMs < 0) firstReplyMs = first.ElapsedMilliseconds;
                rtt.Add(F.PingRttMs(buf[..12]));
            }
            await Task.Delay(1, ct);
        }
        bool ok = rtt.Count >= 50;
        Out.Line($"WO120 join api=legacy result={(ok ? "PASS" : "FAIL")} first_reply_ms={firstReplyMs} sent={sent} send_fail={sendFail} rtt {rtt.Summary()}");
        return ok;
    }
}
