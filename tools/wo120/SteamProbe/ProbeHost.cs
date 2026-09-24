using System.Diagnostics;
using System.Runtime.InteropServices;
using KcdMp.Steam;

namespace KcdMp.SteamProbe;

/// <summary>
/// The host side for one app id: listen on all three Steam APIs, echo the
/// joiner's pings, and when asked, play the relay's part of a session
/// (player state, the NPC stream, bursts, a bulk transfer).
/// </summary>
internal static class ProbeHost
{
    private const int MessagesChannel = 1, LegacyChannel = 2;

    public static async Task<int> RunAsync(SteamSession s, TimeSpan waitForJoiner, CancellationToken ct)
    {
        using var done = CancellationTokenSource.CreateLinkedTokenSource(ct);
        long lastActivity = Stopwatch.GetTimestamp();
        bool anyContact = false;
        void Touch() { lastActivity = Stopwatch.GetTimestamp(); anyContact = true; }

        s.SetRichPresence("kcdmp_probe", "host");
        Out.Line(Out.Inv($"WO120 host app={s.AppId} rich_presence_set=1 listening vport={F.VirtualPort}"));

        using var listener = s.Listen(F.VirtualPort);

        // ISteamNetworkingMessages and legacy ISteamNetworking: accept any session, echo on a poll thread.
        s.MessagesSessionRequested += id =>
        {
            var ident = SteamNative.Identity.FromSteamId(id);
            bool ok = SteamNative.SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser(s.Messages, ref ident);
            Out.Line($"WO120 host api=messages session_request accepted={(ok ? 1 : 0)}");
        };
        s.LegacySessionRequested += id =>
        {
            bool ok = SteamNative.SteamAPI_ISteamNetworking_AcceptP2PSessionWithUser(s.Legacy, id);
            Out.Line($"WO120 host api=legacy session_request accepted={(ok ? 1 : 0)}");
        };
        var echo = new Thread(() => EchoLoop(s, done.Token, Touch, () => done.Cancel())) { IsBackground = true, Name = "echo" };
        echo.Start();

        var acceptTask = Task.Run(async () =>
        {
            while (!done.IsCancellationRequested)
            {
                SteamP2PConnection c;
                try { c = await listener.AcceptAsync(done.Token); }
                catch { return; }
                Touch();
                Out.Line(Out.Inv($"WO120 host api=sockets accepted relayed={Relayed(c)} flags={c.InfoFlags()}"));
                _ = Task.Run(() => ServeAsync(c, Touch, () => done.Cancel(), done.Token));
            }
        });

        Out.ConsoleOnly("Waiting for your friend to connect... (this window closes by itself when the test is done)");
        while (!done.IsCancellationRequested)
        {
            try { await Task.Delay(500, done.Token); } catch { break; }
            var idle = Stopwatch.GetElapsedTime(lastActivity);
            if (!anyContact && idle > waitForJoiner) { Out.Line($"WO120 host app={s.AppId} result=NO-JOINER waited_s={(int)waitForJoiner.TotalSeconds}"); break; }
            if (anyContact && idle > TimeSpan.FromSeconds(90)) { Out.Line($"WO120 host app={s.AppId} result=JOINER-WENT-QUIET"); break; }
        }
        done.Cancel();
        echo.Join(1000);
        Out.Line($"WO120 host app={s.AppId} finished contact={(anyContact ? 1 : 0)}");
        return anyContact ? 0 : 3;
    }

    private static int Relayed(SteamP2PConnection c) { int f = c.InfoFlags(); return f < 0 ? -1 : (f & SteamNative.InfoFlagRelayed) != 0 ? 1 : 0; }

    private static void EchoLoop(SteamSession s, CancellationToken ct, Action touch, Action finish)
    {
        var msgs = new IntPtr[32];
        var buf = new byte[64 * 1024];
        int mCount = 0, lCount = 0;
        while (!ct.IsCancellationRequested)
        {
            int n = SteamNative.SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel(s.Messages, MessagesChannel, msgs, msgs.Length);
            for (int i = 0; i < n; i++)
            {
                IntPtr m = msgs[i];
                int size = Marshal.ReadInt32(m, SteamNative.Msg.Size);
                var data = new byte[size];
                Marshal.Copy(Marshal.ReadIntPtr(m, SteamNative.Msg.Data), data, 0, size);
                ulong from = (ulong)Marshal.ReadInt64(m, SteamNative.Msg.PeerIdentity + 8);
                SteamNative.SteamAPI_SteamNetworkingMessage_t_Release(m);
                touch();
                if (size == 1 && data[0] == F.Done) { Out.Line($"WO120 host api=messages echoed={mCount} done=1"); finish(); continue; }
                var id = SteamNative.Identity.FromSteamId(from);
                unsafe { fixed (byte* p = data) SteamNative.SteamAPI_ISteamNetworkingMessages_SendMessageToUser(s.Messages, ref id, p, (uint)size, SteamNative.SendReliableNoNagle, MessagesChannel); }
                mCount++;
            }

            while (SteamNative.SteamAPI_ISteamNetworking_IsP2PPacketAvailable(s.Legacy, out uint sz, LegacyChannel))
            {
                if (!SteamNative.SteamAPI_ISteamNetworking_ReadP2PPacket(s.Legacy, buf, (uint)buf.Length, out uint got, out ulong from, LegacyChannel)) break;
                touch();
                if (got == 1 && buf[0] == F.Done) { Out.Line($"WO120 host api=legacy echoed={lCount} done=1"); finish(); continue; }
                unsafe { fixed (byte* p = buf) SteamNative.SteamAPI_ISteamNetworking_SendP2PPacket(s.Legacy, from, p, got, SteamNative.P2PReliable, LegacyChannel); }
                lCount++;
            }
            Thread.Sleep(1);
        }
    }

    /// <summary>One joiner over ISteamNetworkingSockets, through the Stream adapter.</summary>
    private static async Task ServeAsync(SteamP2PConnection c, Action touch, Action finish, CancellationToken ct)
    {
        var stream = c.GetStream();
        var gate = new SemaphoreSlim(1, 1);
        using var game = CancellationTokenSource.CreateLinkedTokenSource(ct);
        CancellationTokenSource? senders = null;
        uint expectState = 0;
        long stateOk = 0, stateBad = 0, pongs = 0;
        var burstStarted = new Dictionary<uint, long>();
        var burstMs = new Samples();

        try
        {
            while (!ct.IsCancellationRequested)
            {
                var (type, p) = await F.ReadAsync(stream, ct);
                touch();
                switch (type)
                {
                    case F.Hello:
                        await F.WriteAsync(stream, gate, F.HelloAck, p, ct);
                        break;
                    case F.Ping:
                        await F.WriteAsync(stream, gate, F.Pong, p, ct);
                        pongs++;
                        break;
                    case F.State:
                    {
                        uint seq = F.U32(p);
                        if (seq == expectState && F.CheckPattern(p, seq)) stateOk++; else stateBad++;
                        expectState = seq + 1;
                        break;
                    }
                    case F.StartGame:
                    {
                        int seconds = (int)F.U32(p);
                        senders = CancellationTokenSource.CreateLinkedTokenSource(ct);
                        senders.CancelAfter(TimeSpan.FromSeconds(seconds));
                        Out.Line(Out.Inv($"WO120 host api=sockets game_phase start seconds={seconds}"));
                        _ = RunSendersAsync(stream, gate, burstStarted, senders.Token);
                        break;
                    }
                    case F.BurstAck:
                    {
                        uint id = F.U32(p);
                        lock (burstStarted)
                            if (burstStarted.Remove(id, out long t0)) burstMs.Add(Stopwatch.GetElapsedTime(t0).TotalMilliseconds);
                        break;
                    }
                    case F.EndGame:
                    {
                        senders?.Cancel();
                        var st = c.RealTimeStatus();
                        string line = Out.Inv($"host_view state_rx_ok={stateOk} state_rx_bad={stateBad} pongs={pongs} burst64k_done {burstMs.Summary()} steam_ping_ms={st?.PingMs ?? -1} q_local={st?.QualityLocal ?? -1:0.00} q_remote={st?.QualityRemote ?? -1:0.00} send_retries={c.SendRetries}");
                        Out.Line("WO120 host api=sockets " + line);
                        await F.WriteAsync(stream, gate, F.Stats, System.Text.Encoding.UTF8.GetBytes(line), ct);
                        break;
                    }
                    case F.BulkReq:
                    {
                        int total = (int)F.U32(p);
                        int chunks = (total + F.ChunkBytes - 1) / F.ChunkBytes;
                        var sw = Stopwatch.StartNew();
                        for (uint i = 0; i < chunks; i++)
                            await F.WriteAsync(stream, gate, F.Bulk, F.Patterned(i, F.ChunkBytes), ct);
                        Out.Line(Out.Inv($"WO120 host api=sockets bulk_queued bytes={chunks * F.ChunkBytes} queue_ms={sw.ElapsedMilliseconds} send_retries={c.SendRetries}"));
                        break;
                    }
                    case F.Done:
                        Out.Line("WO120 host api=sockets done=1");
                        finish();
                        return;
                }
            }
        }
        catch (Exception ex) when (ex is EndOfStreamException or IOException or OperationCanceledException)
        {
            Out.Line($"WO120 host api=sockets connection_ended why={ex.GetType().Name} state={c.State} end_reason={c.EndReason} debug=\"{SteamLogScrub.Scrub(c.EndDebug)}\"");
        }
        finally
        {
            senders?.Cancel();
        }
    }

    /// <summary>The relay's share of a session, joiner-bound: state 20 Hz, NPC stream 10 KB/s, a 64 KB burst every 10 s.</summary>
    private static async Task RunSendersAsync(Stream stream, SemaphoreSlim gate, Dictionary<uint, long> burstStarted, CancellationToken ct)
    {
        uint stateSeq = 0, npcSeq = 0, burstId = 0;
        var tick = Stopwatch.StartNew();
        long nextTick = 0, nextBurst = 5000;
        try
        {
            while (!ct.IsCancellationRequested)
            {
                long now = tick.ElapsedMilliseconds;
                if (now >= nextTick)
                {
                    await F.WriteAsync(stream, gate, F.State, F.Patterned(stateSeq++, F.StateBytes), ct);
                    await F.WriteAsync(stream, gate, F.Npc, F.Patterned(npcSeq++, F.NpcBytes), ct);
                    nextTick += 50;
                }
                if (now >= nextBurst)
                {
                    uint id = burstId++;
                    lock (burstStarted) burstStarted[id] = Stopwatch.GetTimestamp();
                    for (int i = 0; i < F.BurstChunks; i++)
                    {
                        var b = F.Patterned(id, F.ChunkBytes, 8);
                        b[4] = (byte)i; b[5] = F.BurstChunks;
                        await F.WriteAsync(stream, gate, F.Burst, b, ct);
                    }
                    nextBurst += 10_000;
                }
                await Task.Delay(1, ct);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { Out.Line($"WO120 host api=sockets sender_stopped why={ex.GetType().Name}"); }
    }
}
