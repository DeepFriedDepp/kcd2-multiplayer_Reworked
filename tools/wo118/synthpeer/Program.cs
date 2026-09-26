// WO-118 live test tool (tools/wo118, never shipped): a synthetic AUTHORITY peer.
//
// Connects to a real local relay FIRST (lowest id -> the authority when two
// loopback clients are present, relay rule 2), then streams NpcStateUp (0x26)
// for scripted NPCs exactly like the mod's emitter: 100 ms while moving
// (> 5 cm), a 2 s heartbeat when still, per-NPC seq, the sender's ms stamp.
// Optional network noise: base delay + uniform jitter + spikes, applied per
// packet AFTER the sender stamp (so reordering and bunching happen like a
// real link; TCP keeps the order the packets are handed to it).
//
// usage: SynthPeer --plan plan.txt [--host 127.0.0.1] [--port 7778] [--name synth-host]
//                  [--duration 60] [--emit-ms 100] [--delay-ms 0] [--jitter-ms 0]
//                  [--spike-pct 0] [--spike-ms 0] [--seed 1] [--sender-clock qpc|tick]
//                  [--ghost-sender-ms on|off]   (the ghost's Position carries its stamp, flag 0x08)
//                  [--version-file path]   (default: the first VERSION found walking up from
//                                           the working directory, then from this binary)
//        SynthPeer --join ...  | --join-host ...   (WO-123: the synthetic joiner / host, JoinPeer.cs)
//        SynthPeer --join-host125 ...               (WO-125: the continuity host, Host125.cs)
// plan lines:
//   line <npc> <x0> <y0> <z0> <ux> <uy> <len> <speed> [pingpong]
//   hold <npc> <x> <y> <z> <yaw>
//   dead <npc> <x> <y> <z> <yaw>                                (WO-122: a corpse: hold + dead bit 0x01, hp 0)
//   saved <t> <kind> <playline> <idx>                           (WO-122: a WorldSaved 0x46 at stream time t, as the host)
//   path <npc> <speed> <x1> <y1> <z1> <x2> <y2> <z2> ...        (ping-pong)
//   timed <npc> <yaw> t0 x0 y0 z0 t1 x1 y1 z1 ...              (piecewise linear in time)
//   fight <npc> <cx> <cy> <cz> <r>      (circles; flag 0x04 drawn, a 0x08 swing cue every 2.5 s)
//   ghost <x0> <y0> <z0> <ux> <uy> <len> <speed> [ms]          (a player position stream, ping-pong)
//   ride <t0_s> <t1_s>                                         (WO-124 6a: the ghost rides between t0 and t1)
//   start <seconds>                                             (delay before streaming)
using System.Buffers.Binary;
using System.Diagnostics;
using System.Globalization;
using System.Net.Sockets;
using System.Text;
using KcdMp.Wire;

static class P
{
    static string Arg(string[] a, string k, string d) { int i = Array.IndexOf(a, k); return i >= 0 && i + 1 < a.Length ? a[i + 1] : d; }
    static float F(string s) => float.Parse(s, CultureInfo.InvariantCulture);

    abstract class Mover
    {
        public string Name = "";
        public ushort Seq;
        public double LastSent = -1e9, LastSentX, LastSentY, LastSentZ;
        public abstract (float x, float y, float z, float yaw) At(double t);
    }
    sealed class Line : Mover
    {
        public float X0, Y0, Z0, Ux, Uy, Len, Speed; public bool PingPong;
        public override (float, float, float, float) At(double t)
        {
            double s = Speed * t;
            double dir = 1;
            if (PingPong && Len > 0)
            {
                double period = 2 * Len;
                double m = s % period;
                if (m <= Len) { s = m; dir = 1; } else { s = period - m; dir = -1; }
            }
            else if (s > Len) s = Len;
            float yaw = (float)Math.Atan2(-Ux * dir, Uy * dir);
            return ((float)(X0 + Ux * s), (float)(Y0 + Uy * s), Z0, yaw);
        }
    }
    sealed class Hold : Mover
    {
        public float X, Y, Z, Yaw; public bool Dead;
        public override (float, float, float, float) At(double t) => (X, Y, Z, Yaw);
    }
    sealed class PathM : Mover
    {
        public List<(float x, float y, float z)> Pts = new(); public float Speed; double[] cum = [];
        public void Init() { cum = new double[Pts.Count]; for (int i = 1; i < Pts.Count; i++) { var a = Pts[i - 1]; var b = Pts[i]; cum[i] = cum[i - 1] + Math.Sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)); } }
        public override (float, float, float, float) At(double t)
        {
            double L = cum[^1]; double s = Speed * t; double period = 2 * L; double m = L > 0 ? s % period : 0; int dir = 1;
            if (m > L) { m = period - m; dir = -1; }
            int i = 1; while (i < Pts.Count - 1 && cum[i] < m) i++;
            var a = Pts[i - 1]; var b = Pts[i]; double seg = cum[i] - cum[i - 1]; double u = seg > 0 ? (m - cum[i - 1]) / seg : 0;
            float dx = (b.x - a.x) * dir, dy = (b.y - a.y) * dir;
            float yaw = (float)Math.Atan2(-dx, dy);
            return ((float)(a.x + (b.x - a.x) * u), (float)(a.y + (b.y - a.y) * u), (float)(a.z + (b.z - a.z) * u), yaw);
        }
    }

    // timed <npc> <yaw> t0 x0 y0 z0 t1 x1 y1 z1 ...  -- piecewise linear in time, holds at the ends
    sealed class Timed : Mover
    {
        public List<(double t, float x, float y, float z)> K = new(); public float Yaw;
        public override (float, float, float, float) At(double t)
        {
            if (t <= K[0].t) return (K[0].x, K[0].y, K[0].z, Yaw);
            for (int i = 1; i < K.Count; i++)
            {
                if (t <= K[i].t)
                {
                    var a = K[i - 1]; var b = K[i]; double u = (t - a.t) / Math.Max(1e-6, b.t - a.t);
                    float dx = b.x - a.x, dy = b.y - a.y;
                    float yaw = (dx * dx + dy * dy) > 1e-6 ? (float)Math.Atan2(-dx, dy) : Yaw;
                    return ((float)(a.x + dx * u), (float)(a.y + dy * u), (float)(a.z + (b.z - a.z) * u), yaw);
                }
            }
            var l = K[^1]; return (l.x, l.y, l.z, Yaw);
        }
    }

    // fight <npc> <cx> <cy> <cz> <radius> : strafes a circle at 1.2 m/s facing the centre, weapon drawn, a swing cue every 2.5 s
    sealed class Fight : Mover
    {
        public float Cx, Cy, Cz, R;
        public override (float, float, float, float) At(double t)
        {
            double w = 1.2 / Math.Max(0.5, R);
            double a = w * t + 0.4 * Math.Sin(t * 0.9);
            float x = (float)(Cx + R * Math.Cos(a)), y = (float)(Cy + R * Math.Sin(a));
            float yaw = (float)Math.Atan2(-(Cx - x), Cy - y);
            return (x, y, Cz, yaw);
        }
        public byte FlagsAt(double t) => (byte)(0x04 | (((int)(t / 2.5)) != (int)((t - 0.1) / 2.5) ? 0x08 : 0));
    }

    static byte[] BuildUp(string npc, float x, float y, float z, float rot, float hp, byte flags, ushort seq, uint ms)
    {
        var nb = Encoding.UTF8.GetBytes(npc);
        int payloadLen = 1 + nb.Length + Protocol.NpcStateFixedTail;
        var p = new byte[3 + payloadLen];
        p[0] = Protocol.NpcStateUp;
        BinaryPrimitives.WriteUInt16LittleEndian(p.AsSpan(1), (ushort)payloadLen);
        p[3] = (byte)nb.Length; nb.CopyTo(p, 4);
        int o = 4 + nb.Length;
        BinaryPrimitives.WriteSingleLittleEndian(p.AsSpan(o), x);
        BinaryPrimitives.WriteSingleLittleEndian(p.AsSpan(o + 4), y);
        BinaryPrimitives.WriteSingleLittleEndian(p.AsSpan(o + 8), z);
        BinaryPrimitives.WriteSingleLittleEndian(p.AsSpan(o + 12), rot);
        BinaryPrimitives.WriteSingleLittleEndian(p.AsSpan(o + 16), hp);
        p[o + Protocol.NpcStateFlagsOffset] = flags;
        BinaryPrimitives.WriteUInt16LittleEndian(p.AsSpan(o + Protocol.NpcStateSeqOffset), seq);
        BinaryPrimitives.WriteUInt32LittleEndian(p.AsSpan(o + Protocol.NpcStateSenderMsOffset), ms);
        return p;
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

    static string FindUp(string file)
    {
        foreach (var start in new[] { Directory.GetCurrentDirectory(), AppContext.BaseDirectory })
            for (var d = new DirectoryInfo(start); d is not null; d = d.Parent)
            {
                var f = Path.Combine(d.FullName, file);
                if (File.Exists(f)) return f;
            }
        return file;
    }

    static readonly KcdMp.Client.ActionOutbox s_actions = new();

    static async Task<int> Main(string[] a)
    {
        string host = Arg(a, "--host", "127.0.0.1"); int port = int.Parse(Arg(a, "--port", "7778"));
        string name = Arg(a, "--name", "synth-host"); double duration = double.Parse(Arg(a, "--duration", "60"), CultureInfo.InvariantCulture);
        int emitMs = int.Parse(Arg(a, "--emit-ms", "100"));
        double delayMs = double.Parse(Arg(a, "--delay-ms", "0"), CultureInfo.InvariantCulture);
        double jitterMs = double.Parse(Arg(a, "--jitter-ms", "0"), CultureInfo.InvariantCulture);
        double spikePct = double.Parse(Arg(a, "--spike-pct", "0"), CultureInfo.InvariantCulture);
        double spikeMs = double.Parse(Arg(a, "--spike-ms", "0"), CultureInfo.InvariantCulture);
        var rng = new Random(int.Parse(Arg(a, "--seed", "1")));
        // qpc = what the agent sends since WO-118 (1 ms QPC time); tick = the 15.6 ms
        // Environment.TickCount64 stamps of earlier agents.
        string senderClock = Arg(a, "--sender-clock", "qpc");
        // The agent stamps every Position since the WO-118 follow-up; off = an older sender.
        bool ghostSenderMs = Arg(a, "--ghost-sender-ms", "on") != "off";
        string versionFile = Arg(a, "--version-file", FindUp("VERSION"));
        string release = File.ReadAllText(versionFile).Trim();
        // WO-123: the synthetic joiner and the transfer-ceiling host (JoinPeer.cs).
        if (a.Contains("--join-host125")) return await Host125.RunAsync(a, release);   // WO-125: the continuity host (Host125.cs)
        if (a.Contains("--join")) return await JoinPeer.RunJoinerAsync(a, release);
        if (a.Contains("--join-host")) return await JoinPeer.RunHostAsync(a, release);

        var movers = new List<Mover>(); double startDelay = 0; Line? ghost = null; int ghostMs = 30;
        var rides = new List<(double T0, double T1)>();
        // WO-121: `row <t_s> <npc> <rowGuid>` -- the host NPC committed that
        // attack row at stream time t: an NpcAttack action event (v8).
        var rows = new List<(double T, string Npc, Guid Row)>();
        var saves = new List<(double T, byte Kind, byte Playline, ushort Idx)>(); uint wsSeq = 0;
        foreach (var raw in File.ReadAllLines(Arg(a, "--plan", "plan.txt")))
        {
            var t = raw.Trim(); if (t.Length == 0 || t.StartsWith('#')) continue;
            var f = t.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            switch (f[0])
            {
                case "line": movers.Add(new Line { Name = f[1], X0 = F(f[2]), Y0 = F(f[3]), Z0 = F(f[4]), Ux = F(f[5]), Uy = F(f[6]), Len = F(f[7]), Speed = F(f[8]), PingPong = f.Length > 9 && f[9] == "pingpong" }); break;
                case "hold": movers.Add(new Hold { Name = f[1], X = F(f[2]), Y = F(f[3]), Z = F(f[4]), Yaw = F(f[5]) }); break;
                case "dead": movers.Add(new Hold { Name = f[1], X = F(f[2]), Y = F(f[3]), Z = F(f[4]), Yaw = F(f[5]), Dead = true }); break;
                case "path":
                {
                    var pm = new PathM { Name = f[1], Speed = F(f[2]) };
                    for (int i = 3; i + 2 < f.Length; i += 3) pm.Pts.Add((F(f[i]), F(f[i + 1]), F(f[i + 2])));
                    pm.Init(); movers.Add(pm); break;
                }
                case "timed":
                {
                    var tm = new Timed { Name = f[1], Yaw = F(f[2]) };
                    for (int i = 3; i + 3 < f.Length; i += 4) tm.K.Add((double.Parse(f[i], CultureInfo.InvariantCulture), F(f[i + 1]), F(f[i + 2]), F(f[i + 3])));
                    movers.Add(tm); break;
                }
                case "fight": movers.Add(new Fight { Name = f[1], Cx = F(f[2]), Cy = F(f[3]), Cz = F(f[4]), R = F(f[5]) }); break;
                case "ghost":
                    ghost = new Line { Name = "ghost", X0 = F(f[1]), Y0 = F(f[2]), Z0 = F(f[3]), Ux = F(f[4]), Uy = F(f[5]), Len = F(f[6]), Speed = F(f[7]), PingPong = true };
                    ghostMs = f.Length > 8 ? int.Parse(f[8]) : 30;
                    break;
                // WO-124 (6a): `ride <t0_s> <t1_s>` -- the ghost's Position carries the
                // riding flag between t0 and t1 of the stream (mount, ride, dismount).
                case "ride":
                    rides.Add((F(f[1]), F(f[2])));
                    break;
                case "start": startDelay = double.Parse(f[1], CultureInfo.InvariantCulture); break;
                case "row": rows.Add((double.Parse(f[1], CultureInfo.InvariantCulture), f[2], Guid.Parse(f[3]))); break;
                case "saved": saves.Add((double.Parse(f[1], CultureInfo.InvariantCulture), byte.Parse(f[2]), byte.Parse(f[3]), ushort.Parse(f[4]))); break;
            }
        }

        using var tcp = new TcpClient { NoDelay = true };
        await tcp.ConnectAsync(host, port);
        var st = tcp.GetStream();
        var nb = Encoding.UTF8.GetBytes(name); var rb = Encoding.UTF8.GetBytes(release);
        int hl = 2 + nb.Length + rb.Length; var hs = new byte[3 + hl];
        hs[0] = Protocol.Handshake; BinaryPrimitives.WriteUInt16LittleEndian(hs.AsSpan(1), (ushort)hl);
        hs[3] = Protocol.Version; hs[4] = (byte)nb.Length; nb.CopyTo(hs, 5); rb.CopyTo(hs, 5 + nb.Length);
        await st.WriteAsync(hs);
        var (ty, pl) = await ReadPacket(st, CancellationToken.None);
        if (ty != Protocol.Ack) { Console.WriteLine($"SYNTH refused: 0x{ty:X2} {Encoding.UTF8.GetString(pl)}"); return 1; }
        Console.WriteLine($"SYNTH connected id={pl[0]} release={release} npcs={movers.Count} emit={emitMs}ms delay={delayMs} jitter={jitterMs} spike={spikePct}%/{spikeMs}ms");

        using var cts = new CancellationTokenSource();
        long rx = 0;
        var reader = Task.Run(async () =>
        {
            try
            {
                while (!cts.IsCancellationRequested)
                {
                    var (rt, rb2) = await ReadPacket(st, cts.Token); rx++;
                    // WO-122: the host's world-save announcement, as a joiner receives it.
                    if (rt == Protocol.WorldSavedDown && WorldSaved.TryDecode(rb2, down: true, out byte wsrc) is WorldSaved ws)
                        Console.WriteLine(FormattableString.Invariant(
                            $"SYNTH WorldSaved from={wsrc} file=playline{ws.Playline}/{ws.FileName} seq={ws.Seq} md5={Convert.ToHexString(ws.Md5)[..8].ToLowerInvariant()} age_ms={DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - ws.SenderUnixMs}"));
                    else if (rt == Protocol.CombatRole && rb2.Length == 1)
                        Console.WriteLine($"SYNTH role={(rb2[0] == 1 ? "authority (host)" : "not the authority (joiner)")}");
                }
            }
            catch { }
        });

        var sw = Stopwatch.StartNew();
        var queue = new PriorityQueue<byte[], double>();
        double lastPing = 0, lastReport = 0, lastGhost = -1e9; long sent = 0, emitted = 0;
        bool ghostWasRiding = false;
        double streamT0 = startDelay;
        while (sw.Elapsed.TotalSeconds < duration + startDelay)
        {
            double now = sw.Elapsed.TotalMilliseconds;
            double ts = sw.Elapsed.TotalSeconds;
            if (ts >= streamT0)
            {
                double t = ts - streamT0;
                for (int ri = rows.Count - 1; ri >= 0; ri--)
                {
                    if (rows[ri].T > t) continue;
                    var ev = new RowEvent(unchecked((uint)(Stopwatch.GetTimestamp() * 1000 / Stopwatch.Frequency)), 0, rows[ri].Row, rows[ri].Npc);
                    await st.WriteAsync(s_actions.Build(ActionKind.NpcAttack, ActionPhase.Commit, ev.ToBytes()));
                    Console.WriteLine(FormattableString.Invariant($"SYNTH t={t:F1}s NpcAttack npc={rows[ri].Npc} row={rows[ri].Row}"));
                    rows.RemoveAt(ri);
                }
                for (int si = saves.Count - 1; si >= 0; si--)
                {
                    if (saves[si].T > t) continue;
                    var md5 = System.Security.Cryptography.MD5.HashData(Encoding.UTF8.GetBytes($"synthetic-{saves[si].Idx}"));
                    var ws = new WorldSaved(++wsSeq, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), saves[si].Kind, saves[si].Playline, saves[si].Idx, md5);
                    var body = ws.Encode();
                    var wp = new byte[3 + body.Length]; wp[0] = Protocol.WorldSavedUp;
                    BinaryPrimitives.WriteUInt16LittleEndian(wp.AsSpan(1), (ushort)body.Length); body.CopyTo(wp, 3);
                    await st.WriteAsync(wp);
                    Console.WriteLine(FormattableString.Invariant($"SYNTH t={t:F1}s WorldSaved sent file=playline{ws.Playline}/{ws.FileName}"));
                    saves.RemoveAt(si);
                }
                foreach (var m in movers)
                {
                    if (now - m.LastSent < emitMs) continue;
                    var (x, y, z, yaw) = m.At(t);
                    double dx = x - m.LastSentX, dy = y - m.LastSentY, dz = z - m.LastSentZ;
                    bool moved = Math.Abs(dx) > 0.05 || Math.Abs(dy) > 0.05 || Math.Abs(dz) > 0.05;
                    if (!moved && now - m.LastSent < 2000) continue;
                    m.LastSent = now; m.LastSentX = x; m.LastSentY = y; m.LastSentZ = z;
                    m.Seq++;
                    byte fl = m is Fight fm ? fm.FlagsAt(t) : m is Hold { Dead: true } ? Protocol.NpcStateFlagDead : (byte)0;
                    uint sms = senderClock == "tick" ? unchecked((uint)Environment.TickCount64)
                             : unchecked((uint)(Stopwatch.GetTimestamp() * 1000 / Stopwatch.Frequency));
                    var pkt = BuildUp(m.Name, x, y, z, yaw, (fl & Protocol.NpcStateFlagDead) != 0 ? 0f : 100f, fl, m.Seq, sms);
                    double d = delayMs + rng.NextDouble() * jitterMs + (rng.NextDouble() * 100 < spikePct ? spikeMs : 0);
                    queue.Enqueue(pkt, now + d);
                    emitted++;
                }
            }
            if (ghost is not null && ts >= streamT0 && now - lastGhost >= ghostMs)
            {
                lastGhost = now;
                var (gx, gy, gz, gyaw) = ghost.At(ts - streamT0);
                int glen = Protocol.PositionPayloadLen + (ghostSenderMs ? Protocol.SenderMsLen : 0);
                var gp = new byte[3 + glen]; gp[0] = Protocol.Position; BinaryPrimitives.WriteUInt16LittleEndian(gp.AsSpan(1), (ushort)glen);
                BinaryPrimitives.WriteSingleLittleEndian(gp.AsSpan(3), gx); BinaryPrimitives.WriteSingleLittleEndian(gp.AsSpan(7), gy);
                BinaryPrimitives.WriteSingleLittleEndian(gp.AsSpan(11), gz); BinaryPrimitives.WriteSingleLittleEndian(gp.AsSpan(15), gyaw);
                gp[19] = ghostSenderMs ? Protocol.PositionFlagSenderMs : (byte)0;
                double gt = ts - streamT0;
                bool riding = rides.Any(r => gt >= r.T0 && gt < r.T1);
                if (riding) gp[19] |= Protocol.PositionFlagRiding;
                if (riding != ghostWasRiding) { Console.WriteLine(FormattableString.Invariant($"SYNTH ghost riding={(riding ? "ON" : "OFF")} at t={gt:F1}s")); ghostWasRiding = riding; }
                // Stamped at the sample, before the injected delay: the jitter then
                // shows as lateness against the stamp, exactly as on a real link.
                if (ghostSenderMs)
                    BinaryPrimitives.WriteUInt32LittleEndian(gp.AsSpan(20), senderClock == "tick" ? unchecked((uint)Environment.TickCount64)
                        : unchecked((uint)(Stopwatch.GetTimestamp() * 1000 / Stopwatch.Frequency)));
                double d = delayMs + rng.NextDouble() * jitterMs + (rng.NextDouble() * 100 < spikePct ? spikeMs : 0);
                queue.Enqueue(gp, now + d);
            }
            while (queue.TryPeek(out var p, out double at) && at <= now)
            {
                queue.Dequeue();
                await st.WriteAsync(p);
                sent++;
            }
            if (now - lastPing > 2000)
            {
                lastPing = now;
                var ping = new byte[3 + 8]; ping[0] = Protocol.Ping; BinaryPrimitives.WriteUInt16LittleEndian(ping.AsSpan(1), 8);
                BinaryPrimitives.WriteInt64LittleEndian(ping.AsSpan(3), DateTime.UtcNow.Ticks);
                await st.WriteAsync(ping);
            }
            if (now - lastReport > 10000) { lastReport = now; Console.WriteLine($"SYNTH t={ts:F0}s emitted={emitted} sent={sent} rx={rx} queued={queue.Count}"); }
            Thread.Sleep(1);
        }
        Console.WriteLine($"SYNTH done emitted={emitted} sent={sent} rx={rx}");
        cts.Cancel();
        return 0;
    }
}
