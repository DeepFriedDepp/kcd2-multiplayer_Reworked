using System.Collections.Concurrent;
using System.Diagnostics;

namespace KcdMp.Client;

/// <summary>
/// WO-127 Phase 3: the leash recorder (for WO-128). <c>mp_leash_trace on|off</c>
/// in the game console (default off). While on, once a second:
///   * host (damage authority): one native sample around the host and the
///     joiner's avatar -> a summary row + one row per NPC within 200 m of
///     either (LeashRowBuilder), in <c>leash/leash-host-&lt;utc&gt;.csv</c>
///     beside agent.log;
///   * joiner: one native sample around this player -> one row per NPC copy
///     within 200 m, in <c>leash/leash-joiner-&lt;utc&gt;.csv</c>.
/// The NPC walk and every per-NPC signal are native (leash.cpp, one
/// main-thread hop per second); this side adds what only the agent knows (the
/// NPC stream, the players' context, the relay ids) and writes the file off
/// the game's thread. Off = no timer, no pipe request, nothing per frame.
/// Cost: MP-LEASH-COST every 60 s (sample_us is main-thread time; per_frame_us
/// = sample_us / frames in that second).
/// </summary>
public partial class GameBridge
{
    private volatile bool _leashOn;
    private CancellationTokenSource? _leashCts;
    private readonly ConcurrentDictionary<string, long> _leashSent = new(StringComparer.OrdinalIgnoreCase);   // host: name -> QPC ms of the last NpcState sent
    private readonly ConcurrentDictionary<string, long> _leashRecv = new(StringComparer.OrdinalIgnoreCase);   // joiner: name -> QPC ms of the last NpcState received
    private readonly ConcurrentDictionary<byte, (float X, float Y, float Z, bool Riding, bool Stale, long Ms)> _leashGhost = new();
    private readonly ConcurrentDictionary<byte, bool> _leashPeerMenu = new();
    private (float X, float Y, float Z, bool Riding)? _leashLocal;
    private (bool? Dialogue, bool? Fight, long Ms) _leashLuaCtx = (null, null, 0);

    private static long LeashNowMs() => Stopwatch.GetTimestamp() * 1000 / Stopwatch.Frequency;

    // ---- hooks (cheap; only a timestamp while the trace is off would be wasted, so they check _leashOn) ----
    private void Wo127NoteLocal(float x, float y, float z, bool riding) { if (_leashOn) _leashLocal = (x, y, z, riding); }
    private void Wo127NoteSent(string npc) { if (_leashOn) _leashSent[npc] = LeashNowMs(); }
    private void Wo127NoteRecv(string npc) { if (_leashOn) _leashRecv[npc] = LeashNowMs(); }
    private void Wo127NoteGhost(byte id, float x, float y, float z, bool riding, bool stale) { if (_leashOn) _leashGhost[id] = (x, y, z, riding, stale, LeashNowMs()); }
    private void Wo127NotePeerMenu(byte id, bool paused) => _leashPeerMenu[id] = paused;

    /// <summary>Lua events: "leash_trace on|off" (the console toggle), "leash_ctx d=0|1 f=0|1" (dialogue, fight).</summary>
    private void Wo127LeashOnEvent(string name, string arg)
    {
        if (name == "leash_ctx")
        {
            bool? d = null, f = null;
            foreach (var kv in arg.Split(' ', StringSplitOptions.RemoveEmptyEntries))
            {
                if (kv == "d=1") d = true; else if (kv == "d=0") d = false;
                if (kv == "f=1") f = true; else if (kv == "f=0") f = false;
            }
            _leashLuaCtx = (d, f, LeashNowMs());
            return;
        }
        bool on = arg.Trim().Equals("on", StringComparison.OrdinalIgnoreCase);
        if (on == _leashOn) { Console.WriteLine($"MP-LEASH trace already {(on ? "on" : "off")}"); return; }
        _leashOn = on;
        _leashCts?.Cancel();
        if (on)
        {
            _leashCts = new CancellationTokenSource();
            _ = Task.Run(() => LeashLoopAsync(_leashCts.Token));
        }
        else Console.WriteLine("MP-LEASH trace off");
    }

    private async Task LeashLoopAsync(CancellationToken ct)
    {
        string dir = Path.Combine(AppContext.BaseDirectory, "leash");
        string stamp = DateTime.UtcNow.ToString("yyyyMMdd-HHmmss");
        LeashCsv? host = null, joiner = null;
        var rows = new LeashRowBuilder();
        var t0 = Stopwatch.StartNew();
        uint lastFrames = 0; double lastT = 0;
        double costSum = 0, costMax = 0, perFrameSum = 0; int costN = 0; long costAt = 0;
        int failures = 0;
        Console.WriteLine($"MP-LEASH trace on -- one sample a second, CSV under {dir}");
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var tickStart = Stopwatch.GetTimestamp();
                try
                {
                    bool isHost = _combatRoleApplied && _isDamageAuthority;
                    if (_leashLocal is not { } me) { await Task.Delay(1000, ct); continue; }

                    // The joiner's avatar (host) -- the lowest relay id with a fresh position.
                    byte? jid = null; (float X, float Y, float Z)? jpos = null; bool jRiding = false, jStale = false;
                    long now = LeashNowMs();
                    foreach (var kv in _leashGhost.OrderBy(k => k.Key))
                        if (now - kv.Value.Ms < 10_000) { jid = kv.Key; jpos = (kv.Value.X, kv.Value.Y, kv.Value.Z); jRiding = kv.Value.Riding; jStale = kv.Value.Stale; break; }

                    var anchors = new List<(float X, float Y, float Z)> { (me.X, me.Y, me.Z) };
                    if (isHost && jpos is { } jp) anchors.Add(jp);

                    // Host context from Lua (dialogue, fight): asked each second, answered on the log channel.
                    if (isHost) { try { await ExecLuaAsync("if KCD2MP_LeashCtx then KCD2MP_LeashCtx() end"); } catch { } }

                    var sample = await _combat.LeashSampleAsync(anchors, LeashRowBuilder.Radius, ct);
                    if (sample is not { } s)
                    {
                        if (++failures is 1 or 10 or 100) Console.WriteLine($"MP-LEASH sample refused/unanswered (x{failures}) -- the DLL must be 0.29.9 and the game in a world");
                        await Task.Delay(1000, ct);
                        continue;
                    }
                    double t = t0.Elapsed.TotalSeconds;
                    float? fps = lastT > 0 && s.Head.Frames >= lastFrames ? (float)((s.Head.Frames - lastFrames) / (t - lastT)) : null;
                    uint framesThisSecond = lastT > 0 && s.Head.Frames > lastFrames ? s.Head.Frames - lastFrames : 0;
                    lastFrames = s.Head.Frames; lastT = t;

                    // Cost bookkeeping (main-thread time per sample, amortised per frame).
                    costSum += s.Head.SampleUs; costN++;
                    if (s.Head.SampleUs > costMax) costMax = s.Head.SampleUs;
                    if (framesThisSecond > 0) perFrameSum += (double)s.Head.SampleUs / framesThisSecond;
                    if (costAt == 0) costAt = now;
                    if (now - costAt >= 60_000)
                    {
                        Console.WriteLine($"MP-LEASH-COST samples={costN} sample_us_mean={costSum / costN:F0} sample_us_max={costMax:F0} per_frame_us_mean={perFrameSum / costN:F1} npcs_last={s.All.Count} walked={s.Head.Walked}");
                        costSum = costMax = perFrameSum = 0; costN = 0; costAt = now;
                    }

                    var utc = DateTime.UtcNow;
                    if (isHost)
                    {
                        host ??= new LeashCsv(dir, $"leash-host-{stamp}", LeashCsv.HostHeader);
                        var (dlg, fight, ctxMs) = _leashLuaCtx;
                        bool luaFresh = now - ctxMs < 3000;
                        var hostCtx = new LeashContext(Town(s.Head, 0), Inter(s.Head, 0), me.Riding,
                            luaFresh ? fight : null, luaFresh ? dlg : null, _localCutsceneActive, _localAutoPaused || _localManualPaused);
                        bool? jFight = jid is byte g && _peerLastState2.TryGetValue(g, out var st2) ? st2.CombatMode : null;
                        bool? jCut = jid is byte g2 && _peerCutscene.TryGetValue(g2, out var cs) ? cs.Active : null;
                        bool? jMenu = jid is byte g3 ? (_leashPeerMenu.TryGetValue(g3, out var pm) ? pm || jStale : jStale) : null;
                        var joinerCtx = jpos is null ? default : new LeashContext(Town(s.Head, 1), Inter(s.Head, 1), jRiding, jFight, null, jCut, jMenu);
                        foreach (var line in rows.HostRows(new LeashRowBuilder.HostInputs(utc, t, jid, fps, (me.X, me.Y, me.Z), jpos,
                                     hostCtx, joinerCtx, s.Head.SampleUs, s.Head.Walked, s.All,
                                     n => _leashSent.TryGetValue(n, out var ms) && now - ms <= 1000)))
                            host.Write(line);
                        host.Flush();
                    }
                    else
                    {
                        joiner ??= new LeashCsv(dir, $"leash-joiner-{stamp}", LeashCsv.JoinerHeader);
                        foreach (var line in rows.JoinerRows(new LeashRowBuilder.JoinerInputs(utc, t, (me.X, me.Y, me.Z), s.All,
                                     n => _leashRecv.TryGetValue(n, out var ms) ? now - ms : null)))
                            joiner.Write(line);
                        joiner.Flush();
                    }
                }
                catch (OperationCanceledException) { break; }
                catch (Exception ex) { Console.WriteLine($"MP-LEASH tick failed: {ex.GetType().Name}: {ex.Message}"); }

                // One sample a second, whatever the tick took.
                var spent = Stopwatch.GetElapsedTime(tickStart);
                var wait = TimeSpan.FromSeconds(1) - spent;
                if (wait > TimeSpan.Zero) await Task.Delay(wait, ct);
            }
        }
        catch (OperationCanceledException) { }
        finally
        {
            Console.WriteLine($"MP-LEASH stopped: host rows={host?.Rows ?? 0} joiner rows={joiner?.Rows ?? 0}{(host?.CurrentPath is { } hp ? " file=" + Path.GetFileName(hp) : "")}{(joiner?.CurrentPath is { } jpth ? " file=" + Path.GetFileName(jpth) : "")}");
            host?.Dispose();
            joiner?.Dispose();
        }

        static bool? Town(LeashPage p, int i) => i < p.Town.Length && p.Town[i] >= 0 ? p.Town[i] == 1 : null;
        static bool? Inter(LeashPage p, int i) => i < p.Interior.Length && p.Interior[i] >= 0 ? p.Interior[i] == 1 : null;
    }
}
