// WO-125 live test tool (tools/wo118, never shipped): a synthetic HOST for the
// continuity tests. The real game is the joiner; this plays a WO-125 host agent:
//   * announces its session mode WITH its world's identity (JoinStatus state 8:
//     the playthrough seed in the joinId slot, SessionSeedKnown|SessionHenryWorld);
//   * serves joins (the WO-123 status sequence), replaying its branch as
//     WorldSaved entries with the branch bit right before every WorldOffer;
//   * refuses a join in a non-Henry world without "pausing";
//   * takes commands from a control file, one per line, each run once in order:
//       save <file> [name]        a host world save: WorldSaved (seq, the file's footer md5), the branch grows
//                                 (parent = the head); the file is the world served from now on. name =
//                                 e.g. autosave061 (the engine-style name the joiner logs), default autosave<seq>
//       reload <file> [reseed]    the host loads a save: "reloading" to every peer, 3 s, then that file is the
//                                 world and the branch head (a known md5 keeps its parents)
//       world <file> <reseed>     the same, another playthrough (give a synthetic seed in hex)
//       mode shared|separate      the session mode
//       leave                     disconnect (the joiner must leave the world)
//     [reseed] = a synthetic seed (hex) written into the save's body 0x01FB, re-signed: a second
//     "playthrough" made from a copy. Files are COPIES of real host saves; never logged by path.
//
// usage: SynthPeer --join-host125 <file> --ctl <control file> [--port 7778] [--name synth-host]
//                  [--duration 3600] [--host-pos x,y,z] [--reseed hex]
using System.Buffers.Binary;
using System.Diagnostics;
using System.Globalization;
using System.Net.Sockets;
using System.Text;
using System.Threading.Channels;
using KcdMp.Client;
using KcdMp.Wire;

static class Host125
{
    static string Arg(string[] a, string k, string d) { int i = Array.IndexOf(a, k); return i >= 0 && i + 1 < a.Length ? a[i + 1] : d; }
    static readonly Stopwatch Clock = Stopwatch.StartNew();
    static void Say(string s) => Console.WriteLine(FormattableString.Invariant($"SYNTH125 t={Clock.Elapsed.TotalSeconds:F2}s {s}"));

    sealed class World
    {
        public byte[] Bytes = [];
        public string Md5 = "";
        public uint? Seed;
        public bool Henry;
        public string Player = "?";
        public string Label = "";
    }

    static World Load(string path, string? reseed)
    {
        var b = File.ReadAllBytes(path);
        if (reseed is { Length: > 0 } rs && rs != "keep")
        {
            uint seed = uint.Parse(rs, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            var c = WhsSave.Inflate(b);
            var n = WhsSave.PathGet(c.Raw, 0x01F4, 0x01FB) ?? throw new InvalidDataException("no seed chunk");
            BinaryPrimitives.WriteUInt32LittleEndian(c.Raw.AsSpan(n.PayloadOff), seed);
            b = WhsSave.Deflate(c.DescBytes, c.Raw, c.FooterTail);
        }
        var v = WhsSave.Verify(b);
        if (!v.Ok) throw new InvalidDataException($"{Path.GetFileName(path)} does not verify: {v.Reason}");
        var raw = WhsSave.Inflate(b).Raw;
        var who = WhsSave.PlayerOf(raw);
        var w = new World { Bytes = b, Md5 = v.Md5.ToLowerInvariant(), Seed = WhsSave.ReadSeed(raw), Henry = who.IsHenry, Player = who.Player, Label = Path.GetFileName(path) };
        return w;
    }

    static (byte Src, uint JoinId, byte[] Body)? Split(byte[] p) =>
        Protocol.TrySplitJoinDown(p, out byte src, out _, out uint jid, out var body) ? (src, jid, body.ToArray()) : null;

    static string Tag(World w) => w.Seed is uint s ? WhsSave.SeedTag(s) : "-";

    public static async Task<int> RunAsync(string[] a, string release)
    {
        string host = Arg(a, "--host", "127.0.0.1"); int port = int.Parse(Arg(a, "--port", "7778"), CultureInfo.InvariantCulture);
        string name = Arg(a, "--name", "synth-host");
        string ctl = Arg(a, "--ctl", "");
        double duration = double.Parse(Arg(a, "--duration", "3600"), CultureInfo.InvariantCulture);
        var hp = Arg(a, "--host-pos", "0,0,0").Split(',').Select(v => float.Parse(v, CultureInfo.InvariantCulture)).ToArray();
        var world = Load(Arg(a, "--join-host125", ""), Arg(a, "--reseed", ""));
        bool shared = true;
        bool loading = false;   // like a WO-125 host agent: silent, and joins deferred, while a load runs
        uint seq = 0;
        var parent = new Dictionary<string, string?>(StringComparer.Ordinal) { [world.Md5] = null };
        string head = world.Md5;
        var names = new Dictionary<string, (byte Kind, byte Pl, ushort Idx)>(StringComparer.Ordinal);

        using var hard = new CancellationTokenSource(TimeSpan.FromSeconds(duration));
        var tcp = new TcpClient { NoDelay = true };
        await tcp.ConnectAsync(host, port);
        var st = tcp.GetStream();
        {
            var nb = Encoding.UTF8.GetBytes(name); var rb = Encoding.UTF8.GetBytes(release);
            int hl = 2 + nb.Length + rb.Length; var hs = new byte[3 + hl];
            hs[0] = Protocol.Handshake; BinaryPrimitives.WriteUInt16LittleEndian(hs.AsSpan(1), (ushort)hl);
            hs[3] = Protocol.Version; hs[4] = (byte)nb.Length; nb.CopyTo(hs, 5); rb.CopyTo(hs, 5 + nb.Length);
            await st.WriteAsync(hs);
        }
        var inbox = Channel.CreateUnbounded<(byte Type, byte[] Payload)>();
        async Task<(byte, byte[])> Read()
        {
            var h = new byte[3]; await Exact(h);
            var b = new byte[BinaryPrimitives.ReadUInt16LittleEndian(h.AsSpan(1))]; await Exact(b);
            return (h[0], b);
        }
        async Task Exact(byte[] b) { int got = 0; while (got < b.Length) { int n = await st.ReadAsync(b.AsMemory(got), hard.Token); if (n <= 0) throw new IOException("closed"); got += n; } }
        var (t0, ack) = await Read();
        if (t0 != Protocol.Ack) { Say("refused by the relay"); return 1; }
        Say($"host connected id={ack[0]} world={world.Label} ({world.Bytes.Length} B) tag={Tag(world)} player={world.Player} henry={(world.Henry ? "yes" : "no")} md5={world.Md5[..8]}");
        var wlock = new SemaphoreSlim(1, 1);
        async Task W(byte[] pkt) { await wlock.WaitAsync(); try { await st.WriteAsync(pkt, hard.Token); } finally { wlock.Release(); } }
        async Task Announce()
        {
            if (loading) return;
            ushort flags = world.Seed is null ? (ushort)0 : (ushort)(Protocol.SessionSeedKnown | (world.Henry ? Protocol.SessionHenryWorld : 0));
            for (byte g = 1; g < 8; g++)
                await W(JoinStatusCodec.Build(g, shared ? world.Seed ?? 0 : 0, Protocol.JoinStateSession, Protocol.JoinReasonId(shared ? "shared-world" : "separate"), shared ? flags : (ushort)0));
        }
        byte[] WsPacket(WorldSaved ws)
        {
            var body = ws.Encode();
            var p = new byte[3 + body.Length];
            p[0] = Protocol.WorldSavedUp; BinaryPrimitives.WriteUInt16LittleEndian(p.AsSpan(1), (ushort)body.Length); body.CopyTo(p, 3);
            return p;
        }
        List<string> Branch()
        {
            var o = new List<string>(); string? cur = head;
            while (cur is not null && o.Count < 64 && !o.Contains(cur)) { o.Add(cur); cur = parent.GetValueOrDefault(cur); }
            return o;
        }
        // reader
        _ = Task.Run(async () =>
        {
            try { while (true) { var p = await Read(); await inbox.Writer.WriteAsync(p); } }
            catch (Exception ex) { Say($"connection ended: {ex.Message}"); hard.Cancel(); }
        });
        // heartbeat
        _ = Task.Run(async () =>
        {
            int n = 0;
            try
            {
                while (!hard.IsCancellationRequested)
                {
                    await W(PositionCodec.BuildPosition(hp[0], hp[1], hp[2], 0, false, false, null, hostClaim: true));   // WO-127: the synthetic host claims the session like a real one
                    if (n++ % 5 == 0) await Announce();
                    await Task.Delay(1000, hard.Token);
                }
            }
            catch { }
        });
        // control file
        var joinQ = Channel.CreateUnbounded<(byte Joiner, uint JoinId)>();
        var joinMsgs = Channel.CreateUnbounded<(byte Type, byte[] Body)>();
        _ = Task.Run(async () =>
        {
            int done = 0;
            while (!hard.IsCancellationRequested && ctl != "")
            {
                try
                {
                    var lines = File.Exists(ctl) ? File.ReadAllLines(ctl) : [];
                    for (; done < lines.Length; done++)
                    {
                        var p = lines[done].Split(' ', StringSplitOptions.RemoveEmptyEntries);
                        if (p.Length == 0 || p[0].StartsWith('#')) continue;
                        switch (p[0])
                        {
                            case "save":
                            {
                                var nw = Load(p[1], null);
                                if (nw.Seed != world.Seed && world.Seed is uint cs) nw = Load(p[1], cs.ToString("x8"));   // a save of THIS playthrough
                                string nm = p.Length > 2 ? p[2] : $"autosave{100 + (int)seq:D3}";
                                var id = WorldSaved.ParsePath(Path.Combine("playline1", nm + ".whs")) ?? (Protocol.SaveKindAuto, (byte)1, (ushort)seq);
                                parent.TryAdd(nw.Md5, head);
                                head = nw.Md5;
                                names[nw.Md5] = id;
                                world = nw;
                                var ws = new WorldSaved(++seq, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), id.Item1, id.Item2, id.Item3, Convert.FromHexString(nw.Md5));
                                await W(WsPacket(ws));
                                Say($"SAVE seq={seq} as playline{id.Item2}/{ws.FileName} md5={nw.Md5[..8]} (from {nw.Label}); branch depth {Branch().Count}");
                                break;
                            }
                            case "reload":
                            case "world":
                            {
                                loading = true;
                                for (byte g = 1; g < 8; g++) await W(JoinStatusCodec.Build(g, 0, Protocol.JoinStateReloading, Protocol.JoinReasonId("reloading"), 0));
                                Say($"{p[0].ToUpperInvariant()} {Path.GetFileName(p[1])}: 'reloading' sent to every peer; loading 3 s");
                                await Task.Delay(3000, hard.Token);
                                var nw = Load(p[1], p.Length > 2 ? p[2] : null);
                                if (!parent.ContainsKey(nw.Md5)) parent[nw.Md5] = null;
                                head = nw.Md5;
                                world = nw;
                                loading = false;
                                await Announce();
                                Say($"{p[0].ToUpperInvariant()} done: world {nw.Label} tag={Tag(nw)} player={nw.Player} md5={nw.Md5[..8]} branch depth {Branch().Count}; announced");
                                break;
                            }
                            case "mode":
                                shared = p.Length > 1 && p[1] == "shared";
                                await Announce();
                                Say($"MODE {(shared ? "shared-world" : "separate")} announced");
                                break;
                            case "leave":
                                Say("LEAVE: disconnecting -- the joiner must leave the host's world");
                                tcp.Close();
                                hard.Cancel();
                                return;
                        }
                    }
                }
                catch (Exception ex) when (ex is not OperationCanceledException) { Say($"control line {done + 1} failed: {ex.Message}"); done++; }
                try { await Task.Delay(500, hard.Token); } catch { return; }
            }
        });
        // joins, one at a time
        _ = Task.Run(async () =>
        {
            await foreach (var (joiner, joinId) in joinQ.Reader.ReadAllAsync(hard.Token))
            {
                while (loading) await Task.Delay(500, hard.Token);   // a real host defers a join through its load
                var w0 = world;
                if (!shared) { await W(JoinStatusCodec.Build(joiner, joinId, Protocol.JoinStateRefused, Protocol.JoinReasonId("shared-world-off"), 0)); Say("refused: shared-world-off"); continue; }
                if (!w0.Henry)
                {
                    await W(JoinStatusCodec.Build(joiner, joinId, Protocol.JoinStateRefused, Protocol.JoinReasonId("not-henry"), 0));
                    Say($"JOIN 0x{joinId:x8} refused: this world's player is not Henry ({w0.Player}) -- NOT paused");
                    continue;
                }
                double tr = Clock.Elapsed.TotalSeconds;
                await W(JoinStatusCodec.Build(joiner, joinId, Protocol.JoinStatePaused, 0, 0));
                await W(JoinStatusCodec.Build(joiner, joinId, Protocol.JoinStateSaving, 0, 0));
                Say($"JOIN 0x{joinId:x8} from {joiner}: 'paused' (synthetic); serving {w0.Label} md5={w0.Md5[..8]} (the join save = the current world)");
                var tx = new WorldSender(w0.Bytes, joinId, joiner, seq, Convert.FromHexString(w0.Md5));
                await W(JoinStatusCodec.Build(joiner, joinId, Protocol.JoinStateSending, 0, 0));
                var br = Branch(); br.Reverse();
                for (int i = 0; i < br.Count; i++)
                {
                    var id = names.TryGetValue(br[i], out var x) ? x : (Protocol.SaveKindAuto, (byte)1, (ushort)0);
                    await W(WsPacket(new WorldSaved((uint)br.Count, i, (byte)(Protocol.SaveKindBranchFlag | id.Item1), id.Item2, id.Item3, Convert.FromHexString(br[i]))));
                }
                Say($"JOIN 0x{joinId:x8}: branch replayed ({br.Count}, newest {br[^1][..8]})");
                await W(tx.BuildOfferPacket());
                bool done = false; double tDone = 0; string end = "";
                while (end == "")
                {
                    foreach (var pkt in tx.TakeSendable()) await W(pkt);
                    var rt = joinMsgs.Reader.ReadAsync(hard.Token).AsTask();
                    double left = done ? 300 - (Clock.Elapsed.TotalSeconds - tDone) : 60;
                    if (await Task.WhenAny(rt, Task.Delay(TimeSpan.FromSeconds(Math.Max(1, left)), hard.Token)) != rt)
                    { await W(WorldReceiver.BuildAbort(joiner, joinId, Protocol.JoinAbortTimeout)); end = "timeout"; break; }
                    var (ty, body) = await rt;
                    switch (ty)
                    {
                        case Protocol.WorldAckDown: tx.OnAck(BinaryPrimitives.ReadUInt32LittleEndian(body), out _); break;
                        case Protocol.WorldDoneDown:
                            done = true; tDone = Clock.Elapsed.TotalSeconds;
                            await W(JoinStatusCodec.Build(joiner, joinId, Protocol.JoinStateWaitingReady, 0, 0));
                            Say(FormattableString.Invariant($"JOIN 0x{joinId:x8}: Done after {tDone - tr:F2} s; waiting for Ready"));
                            break;
                        case Protocol.JoinerReadyDown: end = "ready"; break;
                        case Protocol.JoinAbortDown: end = "abort " + Protocol.JoinAbortName(body.Length > 0 ? body[0] : (byte)0); break;
                    }
                }
                double now = Clock.Elapsed.TotalSeconds;
                await W(JoinStatusCodec.Build(joiner, joinId, Protocol.JoinStateResumed, Protocol.JoinReasonId(end == "ready" ? "ready" : "failed"), (ushort)(now - tr)));
                Say(FormattableString.Invariant($"JOIN 0x{joinId:x8} ended: {end} after {now - tr:F1} s -- THE HOST RESUMES"));
            }
        });
        try
        {
            await foreach (var (type, p) in inbox.Reader.ReadAllAsync(hard.Token))
            {
                if (!Protocol.IsJoinDown(type, p.Length) || Split(p) is not var (src, jid, body)) continue;
                if (type == Protocol.JoinRequestDown) { Say($"JoinRequest 0x{jid:x8} from {src}"); await joinQ.Writer.WriteAsync((src, jid)); }
                else await joinMsgs.Writer.WriteAsync((type, body));
            }
        }
        catch (OperationCanceledException) { Say("stopped"); }
        finally { tcp.Dispose(); }
        return 0;
    }
}
