// WO-121 live test tool (tools/wo121, never shipped): a synthetic v8 PEER whose
// avatar does scripted things -- the stand-in for the second player in a solo
// session. Connects to a real local relay FIRST (lowest id, so it is the
// session's authority/host when two loopback clients are present, relay rule 2),
// then plays a timed scenario:
//
//   at <t> stand <x> <y> <z> <yawRad>          put the avatar there, still
//   at <t> move <speedMps> <headingRad> <secs>  walk/run on a heading (the state
//                                              block's speed = speed; facing = heading)
//   at <t> strafe <speedMps> <moveDirRad> <secs>  move at moveDir relative to the facing
//   at <t> state k=v ...                       bits/zones: crouch=0|1 combat=0|1 block=0|1
//                                              locked=0|1 gz=<zone> gs=<left|right|none> az=<zone>
//                                              (zones by table name: head upper_left upper_right
//                                              lower_left lower_right lower undefined)
//   at <t> jump [heightM] [secs]               a Jump event + a REAL Z arc on the stream
//   at <t> attack <rowGuid> [zone]             a v8 Attack event with that row
//   at <t> block_impulse <rowGuid> [perfect]   a BlockImpulse row event
//   at <t> dodge <rowGuid>                     a Dodge row event
//   at <t> ff on|off                           a SessionSetting (friendly fire) -- valid only as host
//   at <t> hit <hp> <st> [unarmed]             a PlayerHit 0x44 on the joiner (the agent's id)
//   end <t>                                    stop
//
// Position packets: every 30 ms while moving, 2 s heartbeat still; the state
// block is change-gated exactly like the agent (and heartbeated at 1 s while
// non-zero). Every received PlayerHit (0x45) and ActionDown is printed.
//
// usage: AvatarPeer --scenario s.txt [--host 127.0.0.1] [--port 7778] [--name wo121-peer]
using System.Buffers.Binary;
using System.Diagnostics;
using System.Globalization;
using System.Net.Sockets;
using System.Text;
using KcdMp.Client;
using KcdMp.Wire;

static class P
{
    static string Arg(string[] a, string k, string d) { int i = Array.IndexOf(a, k); return i >= 0 && i + 1 < a.Length ? a[i + 1] : d; }
    static float F(string s) => float.Parse(s, CultureInfo.InvariantCulture);
    static uint Ms() => unchecked((uint)(Stopwatch.GetTimestamp() * 1000 / Stopwatch.Frequency));

    record Step(double T, string[] F);

    static WireZone Zone(string n) => n switch
    {
        "head" => WireZone.Head, "upper_left" => WireZone.UpperLeft, "upper_right" => WireZone.UpperRight,
        "lower_left" => WireZone.LowerLeft, "lower_right" => WireZone.LowerRight, "lower" => WireZone.Lower, _ => WireZone.Undefined,
    };
    static WireGuardStance Stance(string n) => n switch { "left" => WireGuardStance.Left, "right" => WireGuardStance.Right, _ => WireGuardStance.None };

    static async Task<int> Main(string[] a)
    {
        string host = Arg(a, "--host", "127.0.0.1"); int port = int.Parse(Arg(a, "--port", "7778"));
        string name = Arg(a, "--name", "wo121-peer");
        string release = File.ReadAllText(FindUp("VERSION")).Trim();
        var steps = new List<Step>(); double endT = 60;
        foreach (var raw in File.ReadAllLines(Arg(a, "--scenario", "scenario.txt")))
        {
            var t = raw.Trim(); if (t.Length == 0 || t.StartsWith('#')) continue;
            var f = t.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (f[0] == "end") { endT = double.Parse(f[1], CultureInfo.InvariantCulture); continue; }
            if (f[0] != "at") continue;
            steps.Add(new Step(double.Parse(f[1], CultureInfo.InvariantCulture), f[2..]));
        }
        steps.Sort((x, y) => x.T.CompareTo(y.T));

        using var tcp = new TcpClient { NoDelay = true };
        await tcp.ConnectAsync(host, port);
        var st = tcp.GetStream();
        var nb = Encoding.UTF8.GetBytes(name); var rb = Encoding.UTF8.GetBytes(release);
        int hl = 2 + nb.Length + rb.Length; var hs = new byte[3 + hl];
        hs[0] = Protocol.Handshake; BinaryPrimitives.WriteUInt16LittleEndian(hs.AsSpan(1), (ushort)hl);
        hs[3] = Protocol.Version; hs[4] = (byte)nb.Length; nb.CopyTo(hs, 5); rb.CopyTo(hs, 5 + nb.Length);
        await st.WriteAsync(hs);
        var (ty, pl) = await ReadPacket(st, CancellationToken.None);
        if (ty != Protocol.Ack) { Console.WriteLine($"PEER refused: 0x{ty:X2} {Encoding.UTF8.GetString(pl)}"); return 1; }
        byte myId = pl[0];
        Console.WriteLine($"PEER connected id={myId} release={release} protocol=v{Protocol.Version} steps={steps.Count}");

        byte? joiner = null;
        using var cts = new CancellationTokenSource();
        var inbox = new ActionInbox();
        var reader = Task.Run(async () =>
        {
            try
            {
                while (!cts.IsCancellationRequested)
                {
                    var (t2, b2) = await ReadPacket(st, cts.Token);
                    if (t2 == Protocol.Name && b2.Length >= 2 && b2[0] != myId) { joiner ??= b2[0]; }
                    else if (t2 == Protocol.Ghost && b2.Length >= 1 && b2[0] != myId) joiner ??= b2[0];
                    else if (t2 == Protocol.PlayerHitV8Down && PlayerHitV8.TryDecodeDown(b2, out byte att, out var h))
                        Console.WriteLine($"PEER got PlayerHit from ghost {att}: {h}");
                    else if (t2 == Protocol.ActionDown && inbox.Accept(b2, out _) is InboundAction ia)
                        Console.WriteLine($"PEER got action kind={ia.Kind} phase={ia.Phase} from={ia.SourceGhostId} len={ia.Payload.Length}");
                }
            }
            catch { }
        });

        var outbox = new ActionOutbox();
        var sw = Stopwatch.StartNew();
        float x = 0, y = 0, z = 0, yaw = 0, speed = 0, head = 0, moveDir = 0; double moveUntil = -1;
        double jumpT0 = -1, jumpDur = 0.8; float jumpH = 0.5f, zBase = 0;
        var s2 = new BodyState2(0, 0, BodyState2Bits.None, WireZone.Undefined, WireGuardStance.None, WireZone.Undefined, 0, 0, 0);
        BodyState2? lastSent = null; double lastSentT = -9, lastPos = -9, lastPing = 0; int si = 0; bool placed = false, frozen = false;
        double lastT = 0;
        string? control = Arg(a, "--control", "") is { Length: > 0 } c ? c : null;
        long controlPos = 0; double lastPoll = 0;
        if (control is not null) File.WriteAllText(control, "");
        while (sw.Elapsed.TotalSeconds < endT)
        {
            double t = sw.Elapsed.TotalSeconds, dt = t - lastT; lastT = t;
            // Live control: every line appended to the control file runs now.
            if (control is not null && t - lastPoll > 0.05)
            {
                lastPoll = t;
                try
                {
                    using var fs = new FileStream(control, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
                    if (fs.Length > controlPos)
                    {
                        fs.Seek(controlPos, SeekOrigin.Begin);
                        var buf = new byte[fs.Length - controlPos]; int n = fs.Read(buf, 0, buf.Length); controlPos += n;
                        foreach (var line in Encoding.UTF8.GetString(buf, 0, n).Split((char)10))
                        {
                            var ln = line.Trim(); if (ln.Length == 0 || ln.StartsWith('#')) continue;
                            if (ln == "quit") { endT = 0; break; }
                            steps.Insert(si, new Step(t, ln.Split(' ', StringSplitOptions.RemoveEmptyEntries)));
                        }
                    }
                }
                catch (IOException) { }
            }
            while (si < steps.Count && steps[si].T <= t)
            {
                var f = steps[si++].F;
                switch (f[0])
                {
                    case "freeze": frozen = true; break;      // stop sending (photo-mode shots: the native writer keeps rendering)
                    case "unfreeze": frozen = false; break;
                    case "stand": frozen = false; x = F(f[1]); y = F(f[2]); z = zBase = F(f[3]); yaw = F(f[4]); speed = 0; moveUntil = -1; placed = true; break;
                    case "move": speed = F(f[1]); head = F(f[2]); yaw = head; moveDir = 0; moveUntil = t + F(f[3]); break;
                    case "strafe": speed = F(f[1]); moveDir = F(f[2]); head = yaw + moveDir; moveUntil = t + F(f[3]); break;
                    case "state":
                        foreach (var kv in f[1..])
                        {
                            var p = kv.Split('='); if (p.Length != 2) continue;
                            BodyState2Bits Bit(string k) => k switch { "crouch" => BodyState2Bits.Crouched, "combat" => BodyState2Bits.CombatMode, "block" => BodyState2Bits.BlockHeld, "locked" => BodyState2Bits.Locked, _ => 0 };
                            switch (p[0])
                            {
                                case "gz": s2 = s2 with { GuardZone = Zone(p[1]) }; break;
                                case "gs": s2 = s2 with { GuardStance = Stance(p[1]) }; break;
                                case "az": s2 = s2 with { AtkZone = Zone(p[1]) }; break;
                                default:
                                    var b = Bit(p[0]);
                                    s2 = s2 with { Bits = p[1] == "1" ? s2.Bits | b : s2.Bits & ~b };
                                    break;
                            }
                        }
                        Console.WriteLine($"PEER t={t:F1} state {s2}");
                        break;
                    case "jump":
                        if (f.Length > 1) jumpH = F(f[1]);
                        if (f.Length > 2) jumpDur = double.Parse(f[2], CultureInfo.InvariantCulture);
                        jumpT0 = t; zBase = z;
                        await Send(st, outbox.Build(ActionKind.Jump, ActionPhase.Commit, BitConverter.GetBytes(Ms())));
                        Console.WriteLine($"PEER t={t:F1} jump h={jumpH} dur={jumpDur}");
                        break;
                    case "attack":
                    {
                        var ev = new AttackEvent(Ms(), 1, f.Length > 2 ? Zone(f[2]) : WireZone.UpperRight, 1, 0, Guid.Parse(f[1]));
                        await Send(st, outbox.Build(ActionKind.Attack, ActionPhase.Commit, ev.ToBytes()));
                        Console.WriteLine($"PEER t={t:F1} attack {ev}");
                        break;
                    }
                    case "block_impulse":
                        await Send(st, outbox.Build(ActionKind.BlockImpulse, ActionPhase.Commit,
                            new RowEvent(Ms(), (byte)(f.Length > 2 && f[2] == "perfect" ? RowEvent.FlagPerfect : 0), Guid.Parse(f[1]), "").ToBytes()));
                        Console.WriteLine($"PEER t={t:F1} block_impulse {f[1]}");
                        break;
                    case "dodge":
                        await Send(st, outbox.Build(ActionKind.Dodge, ActionPhase.Commit, new RowEvent(Ms(), 0, Guid.Parse(f[1]), "").ToBytes()));
                        Console.WriteLine($"PEER t={t:F1} dodge {f[1]}");
                        break;
                    case "draw":
                    case "sheathe":
                    {
                        // The 0x2C combat event (v2: [event][sid:2]) -- the avatar's weapon draw/sheathe.
                        var ce = new byte[3 + 3]; ce[0] = Protocol.CombatEventUp; BinaryPrimitives.WriteUInt16LittleEndian(ce.AsSpan(1), 3);
                        ce[3] = f[0] == "draw" ? Protocol.CombatEventWeaponDrawn : Protocol.CombatEventWeaponSheathed;
                        await Send(st, ce);
                        Console.WriteLine($"PEER t={t:F1} {f[0]}");
                        break;
                    }
                    case "ff":
                        await Send(st, outbox.Build(ActionKind.SessionSetting, ActionPhase.Commit, [SessionSettingKey.FriendlyFire, f[1] == "on" ? (byte)1 : (byte)0]));
                        Console.WriteLine($"PEER t={t:F1} ff {f[1]} (as host)");
                        break;
                    case "npchit":   // npchit <npcName> <hp> <st>: this peer's attributed hit on a world NPC (0x30, WO-121 Phase 5)
                    {
                        var nhb = Encoding.UTF8.GetBytes(f[1]);
                        var pk = new byte[3 + 1 + nhb.Length + Protocol.NpcDamageFixedTail];
                        pk[0] = Protocol.NpcDamageUp;
                        BinaryPrimitives.WriteUInt16LittleEndian(pk.AsSpan(1), (ushort)(1 + nhb.Length + Protocol.NpcDamageFixedTail));
                        pk[3] = (byte)nhb.Length; nhb.CopyTo(pk, 4);
                        int o = 4 + nhb.Length;
                        BinaryPrimitives.WriteSingleLittleEndian(pk.AsSpan(o), F(f[3]));
                        BinaryPrimitives.WriteSingleLittleEndian(pk.AsSpan(o + 4), F(f[2]));
                        pk[o + 8] = (byte)(Protocol.DamageFlagSuppressHitReaction | Protocol.NpcDamageFlagAttributed);
                        await Send(st, pk);
                        Console.WriteLine($"PEER t={t:F1} npchit {f[1]} hp={f[2]} st={f[3]} attributed");
                        break;
                    }
                    case "hit":
                        if (joiner is byte j)
                        {
                            byte fl = (byte)(f.Length > 3 && f[3] == "unarmed" ? PlayerHitV8.FlagUnarmed : 0);
                            await Send(st, new PlayerHitV8(j, F(f[2]), F(f[1]), fl, 0).BuildUp());
                            Console.WriteLine($"PEER t={t:F1} hit ghost {j} hp={f[1]} st={f[2]} flags={fl}");
                        }
                        else Console.WriteLine($"PEER t={t:F1} hit: no joiner seen yet");
                        break;
                }
            }
            if (!placed || frozen) { await Task.Delay(5); continue; }
            bool moving = moveUntil > t && speed > 0;
            if (moving)
            {
                x += (float)(-Math.Sin(head) * speed * dt);
                y += (float)(Math.Cos(head) * speed * dt);
            }
            float zNow = zBase;
            if (jumpT0 >= 0)
            {
                double u = (t - jumpT0) / jumpDur;
                if (u >= 1) { jumpT0 = -1; }
                else zNow = zBase + (float)(4 * jumpH * u * (1 - u));   // a real arc: rises, peaks at jumpH, lands
            }
            else zBase = z;
            z = zNow;
            int dirQ = (int)Math.Round(moveDir * 128 / Math.PI); if (dirQ > 127) dirQ -= 256;
            s2 = s2 with { SpeedCm = (ushort)(moving ? speed * 100 : 0), MoveDir = (sbyte)(moving ? dirQ : 0) };
            bool changed = lastSent is not BodyState2 l || l != s2;
            bool nonZero = s2.SpeedCm != 0 || s2.Bits != 0;
            bool hb = nonZero && t - lastSentT >= 1.0;
            bool due = changed || hb;
            double period = moving || jumpT0 >= 0 ? 0.030 : 2.0;
            if (t - lastPos >= period || due)
            {
                lastPos = t;
                BodyState2? block = due ? s2 : null;
                if (due) { lastSent = s2; lastSentT = t; }
                await Send(st, PositionCodec.BuildPosition(x, y, z, yaw, false, false, block, Ms()));
            }
            if (t - lastPing > 2) { lastPing = t; var ping = new byte[11]; ping[0] = Protocol.Ping; BinaryPrimitives.WriteUInt16LittleEndian(ping.AsSpan(1), 8); await Send(st, ping); }
            await Task.Delay(5);
        }
        Console.WriteLine("PEER done");
        cts.Cancel();
        return 0;
    }

    static readonly SemaphoreSlim WriteLock = new(1, 1);
    static async Task Send(NetworkStream s, byte[] p) { await WriteLock.WaitAsync(); try { await s.WriteAsync(p); } finally { WriteLock.Release(); } }

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
}
