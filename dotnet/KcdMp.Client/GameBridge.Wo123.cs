using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Globalization;
using System.Net.Sockets;
using System.Text;
using System.Threading.Channels;

namespace KcdMp.Client;

/// <summary>
/// WO-123 -- send the world, pause the host: the agent half
/// (docs/WO-123-findings.md; wire in ProtocolWo123.cs; transfer core in
/// WorldTransfer.cs). Dormant: nothing here runs unless mp_shared_world is on.
///
/// Host (the damage authority), on a JoinRequest:
///   1. ask the mod to pause (KCD2MP_JoinTry): it refuses while the host is in
///      combat, a dialogue, a cutscene, a load or dead, and the join is
///      DEFERRED -- the joiner is told "your host is busy" and the agent asks
///      again every 2 s;
///   2. the mod froze the clock (ratio 0, the old ratio kept), paused the NPCs
///      it found awake (the list is kept, and only those are resumed), held
///      the player's input and put up "<partner> is joining";
///   3. a fresh world save through WO-122's on-demand route, verified;
///   4. offer (size, SHA-256, chunk count, the WorldSaved seq and md5), then
///      32 KB chunks, at most 256 KB unacknowledged;
///   5. the joiner's Done (hash + Verify passed), then its Ready (loaded, in
///      the world -- sent by the next WO) resumes the host.
/// The host is never left paused: ready, the joiner's disconnect, an abort
/// either way, a failed save or transfer, mp_join_cancel, a load on the host,
/// the relay connection dropping, and the safety timeout (mp_join_timeout,
/// default 180 s) all resume -- and the mod keeps its own timer too, so an
/// agent that dies mid-join cannot strand the host either.
///
/// Joiner: a JoinRequest (mp_join_request, or the next WO's menu flow), then
/// the offer is received into a staging file in the agent's own data folder
/// (WorldReceiver), checked, and Done is sent; the launcher polls
/// /join-status for "Receiving the world... 62%".
/// </summary>
public partial class GameBridge
{
    public const int JoinTimeoutDefaultS = 180;
    private const int JoinDeferMaxS = 600;         // a host busy for 10 minutes: give the joiner up
    private const int JoinAckTimeoutS = 20;        // no ack progress for this long mid-transfer: abort
    private const int JoinDoneTimeoutS = 30;       // after the last ack, the joiner's hash + verify
    private const int JoinLuaReplyTimeoutMs = 6000;
    /// <summary>After Gameplay started, the agent's post-load work (the clock's reload check, the WO-102 resync) settles first.</summary>
    private const int JoinSettleAfterLoadS = 10;

    private volatile int _joinTimeoutS = JoinTimeoutDefaultS;
    private DateTime _wo123GameplayStartedUtc = DateTime.MinValue;
    private DateTime _wo123LoadStartedUtc = DateTime.MinValue;   // MinValue = no load in progress
    private const int JoinLoadStaleS = 300;                      // a load whose "Gameplay started" the tail missed

    // ---------------------------------------------------------------- host side

    private sealed class HostJoin
    {
        public uint JoinId;
        public byte Joiner;
        public string Partner = "";
        public DateTime RequestUtc = DateTime.UtcNow;
        public DateTime? PausedUtc;
        public DateTime Deadline = DateTime.MaxValue;
        public volatile string Phase = "deferred";
        public readonly CancellationTokenSource Cts = new();
        public volatile string? CancelReason;
        public readonly Channel<(byte Type, byte[] Body)> Inbox = Channel.CreateUnbounded<(byte, byte[])>();
        public WorldSender? Sender;
        public TaskCompletionSource<(string Kind, string Arg)>? LuaReply;
        public void Cancel(string reason) { CancelReason ??= reason; try { Cts.Cancel(); } catch (ObjectDisposedException) { } }
    }

    private HostJoin? _hostJoin;
    private readonly object _joinGate = new();

    private bool Wo123HostJoinActive => _hostJoin is not null;

    // ---------------------------------------------------------------- joiner side

    private WorldReceiver? _joinRx;
    private uint _joinOutId;                 // the join this machine asked for
    private volatile string _joinUiState = "idle";
    private volatile string _joinUiMessage = "";
    private long _joinUiBytes, _joinUiTotal;
    private double _joinUiEtaS;
    private int _joinRxLastDecile = -1;

    // ---------------------------------------------------------------- lifecycle

    /// <summary>An agent start sweeps whatever an earlier agent left in staging (a crash mid-transfer).</summary>
    private static void Wo123SweepAtStart()
    {
        try
        {
            string dir = WorldReceiver.DefaultStagingDir();
            int n = WorldReceiver.SweepStaging(dir);
            if (n > 0) Console.WriteLine($"MP-JOIN swept {n} staging file(s) left by an earlier agent (<data>/join-staging)");
        }
        catch (Exception ex) { Console.WriteLine($"MP-JOIN staging sweep failed: {ex.Message}"); }
    }

    private void Wo123OnConnect(NetworkStream stream, CancellationToken ct)
    {
        _ = ExecLuaAsync("if KCD2MP_Wo123CfgEmit then KCD2MP_Wo123CfgEmit() end");
    }

    private async Task Wo123OnDisconnectAsync()
    {
        _hostJoin?.Cancel("relay-lost");
        if (_joinRx is { } rx)
        {
            rx.Abort();
            _joinRx = null;
            SetJoinUi("aborted", "Lost the connection -- the world transfer stopped.");
            Console.WriteLine($"MP-JOIN joiner: relay connection lost -- staged transfer 0x{rx.JoinId:x8} deleted");
        }
        await Task.CompletedTask;
    }

    private void Wo123OnGameplayStarted()
    {
        _wo123GameplayStartedUtc = DateTime.UtcNow;
        _wo123LoadStartedUtc = DateTime.MinValue;
        // A load on the host rewinds the world under a join: the save being sent
        // is no longer the world. Resume and tell the joiner.
        if (_hostJoin is { PausedUtc: not null } j) j.Cancel("host-reload");
        // A load kills the mod's own safety timer, and a resume sent during the
        // load can meet the post-load REST outage. Ask again once the world is
        // up: idempotent in the mod (a no-op unless it is still paused).
        if (_sharedWorld) _ = Wo123ResumeAfterLoadAsync();
    }

    /// <summary>
    /// A load STARTED. A join waits it out (Wo123AgentBusy). A paused join ends
    /// now, not at "Gameplay started": observed live, a load begun under the
    /// pause did not reach "Gameplay started" until the pause was lifted
    /// 45 s later (the safety timeout).
    /// </summary>
    private void Wo123OnLoadStarted()
    {
        _wo123LoadStartedUtc = DateTime.UtcNow;
        if (_hostJoin is { PausedUtc: not null } j)
        {
            Console.WriteLine($"MP-JOIN host: a save load started under join 0x{j.JoinId:x8} -- resuming now (host-reload)");
            j.Cancel("host-reload");
        }
    }

    private async Task Wo123ResumeAfterLoadAsync()
    {
        foreach (int delayS in new[] { 3, 12 })
        {
            await Task.Delay(TimeSpan.FromSeconds(delayS));
            if (_hostJoin is not null) return;   // a new join owns the pause now
            try { await ExecLuaAsync("if KCD2MP_JoinResumeStale then KCD2MP_JoinResumeStale(\"host-reload\") end"); } catch { }
        }
    }

    /// <summary>A peer left the relay (0x06).</summary>
    private async Task Wo123OnPeerGoneAsync(byte ghostId)
    {
        if (_hostJoin is { } j && j.Joiner == ghostId) j.Cancel("joiner-gone");
        if (_joinRx is { } rx && rx.Host == ghostId)
        {
            rx.Abort();
            _joinRx = null;
            SetJoinUi("aborted", "Your host left -- the world transfer stopped.");
            Console.WriteLine($"MP-JOIN joiner: the host (ghost {ghostId}) disconnected -- staged transfer 0x{rx.JoinId:x8} deleted");
        }
        await Task.CompletedTask;
    }

    // ---------------------------------------------------------------- mod events

    /// <summary><c>wo123_cfg timeout_s=180</c>.</summary>
    private void Wo123OnCfgEvent(string? arg)
    {
        foreach (var kv in (arg ?? "").Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            int eq = kv.IndexOf('=');
            if (eq > 0 && kv[..eq] == "timeout_s" && int.TryParse(kv[(eq + 1)..], NumberStyles.Integer, CultureInfo.InvariantCulture, out int t))
                _joinTimeoutS = Math.Clamp(t, 30, 1800);
        }
        Console.WriteLine($"MP-JOIN cfg timeout_s={_joinTimeoutS}");
    }

    private void Wo123OnEvent(string name, string? arg)
    {
        var p = (arg ?? "").Split(' ', StringSplitOptions.RemoveEmptyEntries);
        uint id = p.Length > 0 && uint.TryParse(p[0], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var v) ? v : 0;
        switch (name)
        {
            case "join_try":        // "<joinId> paused <n> ..." | "<joinId> busy <reason>"
                if (_hostJoin is { } j && j.JoinId == id && p.Length >= 2)
                    j.LuaReply?.TrySetResult((p[1], p.Length > 2 ? p[2] : ""));
                return;
            case "join_resumed":    // "<joinId> <reason>": the mod resumed on its own (mp_join_cancel, its safety timer)
                if (_hostJoin is { } j2 && j2.JoinId == id) j2.Cancel(p.Length > 1 ? p[1] : "mod");
                return;
            case "join_cancel":     // mp_join_cancel, on either machine
                if (_hostJoin is { } j3) { Console.WriteLine("MP-JOIN host: mp_join_cancel"); j3.Cancel("cancel"); }
                else if (_joinRx is not null || _joinOutId != 0) _ = CancelOutgoingJoinAsync("mp_join_cancel");
                else Console.WriteLine("MP-JOIN mp_join_cancel: no join in progress");
                return;
            case "join_request":    // mp_join_request on the joiner
                _ = SendJoinRequestAsync();
                return;
            case "join_ready":      // the next WO: the joiner loaded the world and is in it
                _ = SendJoinerReadyAsync("mod");
                return;
        }
    }

    // ---------------------------------------------------------------- inbound frames

    private async Task Wo123OnFrameAsync(int type, byte[] payload, CancellationToken ct)
    {
        if (!SplitJoinDown(payload, out byte src, out uint joinId, out var body)) return;
        switch (type)
        {
            case Protocol.JoinRequestDown:
                await OnJoinRequestAsync(src, joinId);
                return;
            case Protocol.WorldAckDown:
            case Protocol.WorldDoneDown:
            case Protocol.JoinerReadyDown:
                if (_hostJoin is { } j && j.JoinId == joinId && j.Joiner == src) j.Inbox.Writer.TryWrite(((byte)type, body));
                else Console.WriteLine($"MP-JOIN host: 0x{type:X2} for join 0x{joinId:x8} from ghost {src} -- no such join here, ignored");
                return;
            case Protocol.JoinAbortDown:
                if (_hostJoin is { } ja && ja.JoinId == joinId && ja.Joiner == src)
                {
                    ja.Inbox.Writer.TryWrite(((byte)type, body));
                    return;
                }
                if (_joinRx is { } rxa && rxa.JoinId == joinId && rxa.Host == src)
                {
                    rxa.Abort();
                    _joinRx = null;
                    string r = Protocol.JoinAbortName(body.Length > 0 ? body[0] : (byte)0);
                    SetJoinUi("aborted", $"The world transfer was stopped ({r}).");
                    Console.WriteLine($"MP-JOIN joiner: the host aborted join 0x{joinId:x8} ({r}) -- staging deleted");
                    return;
                }
                if (_joinOutId == joinId) { _joinOutId = 0; SetJoinUi("aborted", "The host stopped the join."); }
                return;
            case Protocol.JoinStatusDown:
                OnJoinStatusIn(src, joinId, body);
                return;
            case Protocol.WorldOfferDown:
                await OnWorldOfferInAsync(src, joinId, body, ct);
                return;
            case Protocol.WorldChunkDown:
                await OnWorldChunkInAsync(src, joinId, body, ct);
                return;
        }
    }

    private static bool SplitJoinDown(byte[] payload, out byte src, out uint joinId, out byte[] body)
    {
        bool ok = Protocol.TrySplitJoinDown(payload, out src, out _, out joinId, out var span);
        body = ok ? span.ToArray() : [];
        return ok;
    }

    private async Task WriteJoinAsync(byte[] pkt)
    {
        if (_wo122Stream is not NetworkStream s) throw new IOException("no relay connection");
        await WritePacketAsync(s, pkt, _wo122Ct);
    }

    private async Task TrySendStatusAsync(HostJoin j, byte state, string reason, ushort arg = 0)
    {
        try { await WriteJoinAsync(JoinStatusCodec.Build(j.Joiner, j.JoinId, state, Protocol.JoinReasonId(reason), arg)); }
        catch (Exception ex) { Console.WriteLine($"MP-JOIN host: status {Protocol.JoinStateName(state)} not sent: {ex.Message}"); }
    }

    private async Task OnJoinRequestAsync(byte joiner, uint joinId)
    {
        string who = _ghostNames.TryGetValue(joiner, out var n) ? n : $"player {joiner}";
        string refuse = !_sharedWorld ? "shared-world-off"
                      : !(_combatRoleApplied && _isDamageAuthority) ? "not-host"
                      : "";
        HostJoin? j = null;
        if (refuse == "")
        {
            lock (_joinGate)
            {
                if (_hostJoin is { } cur)
                {
                    if (cur.JoinId == joinId && cur.Joiner == joiner) return;   // a repeat of the one in progress
                    refuse = "another-join";
                }
                else
                {
                    j = new HostJoin { JoinId = joinId, Joiner = joiner, Partner = who };
                    _hostJoin = j;
                }
            }
        }
        if (j is null)
        {
            Console.WriteLine($"MP-JOIN host: join 0x{joinId:x8} from {who} (ghost {joiner}) refused: {refuse}");
            try { await WriteJoinAsync(JoinStatusCodec.Build(joiner, joinId, Protocol.JoinStateRefused, Protocol.JoinReasonId(refuse), 0)); } catch { }
            return;
        }
        Console.WriteLine($"MP-JOIN host: join 0x{joinId:x8} requested by {who} (ghost {joiner}) -- timeout {_joinTimeoutS} s once paused");
        _ = RunHostJoinAsync(j);
    }

    /// <summary>
    /// Why the AGENT will not pause yet, or null: a load just finished (its
    /// clock check has not run), or a reload convergence is still moving the
    /// clock -- a save written now would not be the world after the resume
    /// (observed live: the host resumed 3.8 game hours past the save it sent).
    /// </summary>
    private string? Wo123AgentBusy()
    {
        if (_wo123LoadStartedUtc != DateTime.MinValue && (DateTime.UtcNow - _wo123LoadStartedUtc).TotalSeconds < JoinLoadStaleS) return "loading";
        if ((DateTime.UtcNow - _wo123GameplayStartedUtc).TotalSeconds < JoinSettleAfterLoadS) return "loading";
        if (_reloadConvergeTarget is not null) return "clock-sync";
        return null;
    }

    /// <summary>Ask the mod to pause (or learn why it cannot); the reply comes back as a join_try event.</summary>
    private async Task<(string Kind, string Arg)?> AskModJoinTryAsync(HostJoin j)
    {
        var tcs = new TaskCompletionSource<(string, string)>(TaskCreationOptions.RunContinuationsAsynchronously);
        j.LuaReply = tcs;
        await ExecLuaAsync(FormattableString.Invariant(
            $"if KCD2MP_JoinTry then KCD2MP_JoinTry(\"{j.JoinId:x8}\", \"{EscapeLua(j.Partner)}\", {_joinTimeoutS}) else KCD2MP_EmitEvent(\"join_try\", \"{j.JoinId:x8} busy no-mod\") end"));
        var done = await Task.WhenAny(tcs.Task, Task.Delay(JoinLuaReplyTimeoutMs, j.Cts.Token));
        j.LuaReply = null;
        return done == tcs.Task ? tcs.Task.Result : null;
    }

    private async Task RunHostJoinAsync(HostJoin j)
    {
        string resumeReason = "failed";
        byte abortReason = 0;
        var ct = j.Cts.Token;
        try
        {
            // ---- 1. defer until the mod can pause the world
            string lastBusy = "";
            var lastStatus = DateTime.MinValue;
            while (true)
            {
                ct.ThrowIfCancellationRequested();
                var reply = Wo123AgentBusy() is { } agentBusy ? ("busy", agentBusy) : await AskModJoinTryAsync(j);
                if (reply is null)
                {
                    Console.WriteLine($"MP-JOIN host: join 0x{j.JoinId:x8}: the mod did not answer KCD2MP_JoinTry in {JoinLuaReplyTimeoutMs} ms -- asking again");
                    reply = ("busy", "no-mod");
                }
                if (reply.Value.Kind == "paused") break;
                string busy = reply.Value.Arg == "" ? "failed" : reply.Value.Arg;
                if (busy != lastBusy || (DateTime.UtcNow - lastStatus).TotalSeconds >= 10)
                {
                    Console.WriteLine($"MP-JOIN host: join 0x{j.JoinId:x8} deferred: {busy} -- telling {j.Partner} 'your host is busy'");
                    await TrySendStatusAsync(j, Protocol.JoinStateDeferred, busy);
                    lastBusy = busy; lastStatus = DateTime.UtcNow;
                }
                if ((DateTime.UtcNow - j.RequestUtc).TotalSeconds > JoinDeferMaxS)
                {
                    abortReason = Protocol.JoinAbortTimeout; resumeReason = "timeout";
                    Console.WriteLine($"MP-JOIN host: join 0x{j.JoinId:x8} gave up: the host stayed busy ({busy}) for {JoinDeferMaxS} s");
                    return;
                }
                await Task.Delay(2000, ct);
            }
            j.PausedUtc = DateTime.UtcNow;
            j.Deadline = j.PausedUtc.Value.AddSeconds(_joinTimeoutS);
            j.Phase = "saving";
            Console.WriteLine($"MP-JOIN host: join 0x{j.JoinId:x8} paused the world after {(j.PausedUtc.Value - j.RequestUtc).TotalSeconds:F1} s of deferral -- writing the world save");
            await TrySendStatusAsync(j, Protocol.JoinStatePaused, "none");
            await TrySendStatusAsync(j, Protocol.JoinStateSaving, "none");
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
            deadline.CancelAfter(j.Deadline - DateTime.UtcNow);
            var dct = deadline.Token;

            // ---- 2. the world save (WO-122 Phase 4), with the world frozen
            while (Volatile.Read(ref _worldSaveBusy) != 0) await Task.Delay(250, dct);   // a scheduled save in flight: wait it out
            var t0 = DateTime.UtcNow;
            // Raced against the deadline and every cancel: a joiner who leaves while
            // the engine is still writing must not keep the host frozen for the
            // request's own 60 s. The request runs on and clears its own busy flag.
            var saveTask = RequestWorldSaveCoreAsync("join");
            await Task.WhenAny(saveTask, Task.Delay(Timeout.Infinite, dct));
            dct.ThrowIfCancellationRequested();
            var save = await saveTask;
            if (save is null) { abortReason = Protocol.JoinAbortSaveFailed; resumeReason = "failed"; Console.WriteLine($"MP-JOIN host: join 0x{j.JoinId:x8}: no world save -- abort"); return; }
            var bytes = WhsSave.ReadShared(save.FullPath);
            var v = WhsSave.Verify(bytes);
            if (!v.Ok || !string.Equals(v.Md5, Convert.ToHexString(save.Md5), StringComparison.OrdinalIgnoreCase))
            {
                abortReason = Protocol.JoinAbortSaveFailed; resumeReason = "failed";
                Console.WriteLine($"MP-JOIN host: join 0x{j.JoinId:x8}: {save.Display} failed WhsSave.Verify before sending ({(v.Ok ? "md5 changed since it was announced" : v.Reason)}) -- abort");
                return;
            }
            if (bytes.Length > Protocol.WorldMaxBytes) { abortReason = Protocol.JoinAbortTooBig; resumeReason = "failed"; return; }
            var sender = new WorldSender(bytes, j.JoinId, j.Joiner, save.Seq, save.Md5);
            j.Sender = sender;
            string sha = Convert.ToHexString(sender.Offer.Sha256).ToLowerInvariant();
            Console.WriteLine(FormattableString.Invariant(
                $"MP-JOIN host: join 0x{j.JoinId:x8} world={save.Display} bytes={bytes.Length} chunks={sender.ChunkCount} sha256={sha[..16]} worldsaved_seq={save.Seq} md5={v.Md5[..8].ToLowerInvariant()} verify=ok save_ms={(DateTime.UtcNow - t0).TotalMilliseconds:F0}"));

            // ---- 3. offer + windowed chunks
            j.Phase = "sending";
            await TrySendStatusAsync(j, Protocol.JoinStateSending, "none");
            await WriteJoinAsync(sender.BuildOfferPacket());
            var sendT0 = DateTime.UtcNow;
            var lastProgress = DateTime.MinValue;
            var lastAckAt = DateTime.UtcNow;
            bool done = false;
            while (!done)
            {
                foreach (var pkt in sender.TakeSendable()) await WriteJoinAsync(pkt);
                if ((DateTime.UtcNow - lastProgress).TotalMilliseconds >= 500)
                {
                    lastProgress = DateTime.UtcNow;
                    double pct = 100.0 * sender.AckedBytes / sender.TotalBytes;
                    _ = ExecLuaAsync(FormattableString.Invariant($"if KCD2MP_JoinProgress then KCD2MP_JoinProgress(\"{j.JoinId:x8}\", {pct:F0}, \"sending\") end"));
                }
                using var wait = CancellationTokenSource.CreateLinkedTokenSource(dct);
                wait.CancelAfter(TimeSpan.FromSeconds(sender.AllAcked ? JoinDoneTimeoutS : JoinAckTimeoutS));
                (byte Type, byte[] Body) msg;
                try { msg = await j.Inbox.Reader.ReadAsync(wait.Token); }
                catch (OperationCanceledException) when (!dct.IsCancellationRequested)
                {
                    abortReason = Protocol.JoinAbortTimeout; resumeReason = "timeout";
                    Console.WriteLine(FormattableString.Invariant(
                        $"MP-JOIN host: join 0x{j.JoinId:x8}: {(sender.AllAcked ? "no Done" : "no ack")} from {j.Partner} for {(sender.AllAcked ? JoinDoneTimeoutS : JoinAckTimeoutS)} s (acked {sender.AckedBytes}/{sender.TotalBytes} B) -- abort"));
                    return;
                }
                switch (msg.Type)
                {
                    case Protocol.WorldAckDown:
                        uint next = msg.Body.Length == 4 ? BinaryPrimitives.ReadUInt32LittleEndian(msg.Body) : uint.MaxValue;
                        if (!sender.OnAck(next, out string why))
                        {
                            abortReason = Protocol.JoinAbortProtocol; resumeReason = "failed";
                            Console.WriteLine($"MP-JOIN host: join 0x{j.JoinId:x8}: bad ack ({why}) -- abort");
                            return;
                        }
                        lastAckAt = DateTime.UtcNow;
                        break;
                    case Protocol.WorldDoneDown:
                        if (!sender.AllAcked)
                        {
                            abortReason = Protocol.JoinAbortProtocol; resumeReason = "failed";
                            Console.WriteLine($"MP-JOIN host: join 0x{j.JoinId:x8}: Done before every chunk was acked -- abort");
                            return;
                        }
                        bool shaOk = msg.Body.Length == 8 && msg.Body.AsSpan().SequenceEqual(sender.Offer.Sha256.AsSpan(0, 8));
                        double s = (DateTime.UtcNow - sendT0).TotalSeconds;
                        Console.WriteLine(FormattableString.Invariant(
                            $"MP-JOIN host: join 0x{j.JoinId:x8} transfer done: {sender.TotalBytes} B in {s:F2} s ({sender.TotalBytes / 1048576.0 / Math.Max(s, 1e-3):F2} MB/s); the joiner's hash + verify passed (sha prefix echo {(shaOk ? "matches" : "DIFFERS")})"));
                        if (!shaOk) { abortReason = Protocol.JoinAbortHashMismatch; resumeReason = "failed"; return; }
                        done = true;
                        break;
                    case Protocol.JoinAbortDown:
                        byte r = msg.Body.Length > 0 ? msg.Body[0] : (byte)0;
                        Console.WriteLine($"MP-JOIN host: join 0x{j.JoinId:x8}: {j.Partner} aborted ({Protocol.JoinAbortName(r)}) -- resuming");
                        resumeReason = r == Protocol.JoinAbortJoinerCancel ? "cancel" : "failed";
                        return;
                    case Protocol.JoinerReadyDown:
                        Console.WriteLine($"MP-JOIN host: join 0x{j.JoinId:x8}: Ready before the transfer finished -- ignored");
                        break;
                }
            }

            // ---- 4. the joiner loads (the next WO) and says ready
            j.Phase = "waiting-ready";
            await TrySendStatusAsync(j, Protocol.JoinStateWaitingReady, "none");
            _ = ExecLuaAsync($"if KCD2MP_JoinProgress then KCD2MP_JoinProgress(\"{j.JoinId:x8}\", 100, \"loading\") end");
            while (true)
            {
                var msg = await j.Inbox.Reader.ReadAsync(dct);
                if (msg.Type == Protocol.JoinerReadyDown)
                {
                    uint seq = msg.Body.Length == 4 ? BinaryPrimitives.ReadUInt32LittleEndian(msg.Body) : 0;
                    Console.WriteLine($"MP-JOIN host: join 0x{j.JoinId:x8}: {j.Partner} is ready (loaded worldsaved_seq={seq}, sent {sender.Offer.WorldSavedSeq}{(seq == sender.Offer.WorldSavedSeq ? "" : " -- MISMATCH")})");
                    resumeReason = "ready";
                    return;
                }
                if (msg.Type == Protocol.JoinAbortDown)
                {
                    byte r = msg.Body.Length > 0 ? msg.Body[0] : (byte)0;
                    Console.WriteLine($"MP-JOIN host: join 0x{j.JoinId:x8}: {j.Partner} aborted while loading ({Protocol.JoinAbortName(r)})");
                    resumeReason = r == Protocol.JoinAbortJoinerCancel ? "cancel" : "failed";
                    return;
                }
            }
        }
        catch (OperationCanceledException)
        {
            if (j.CancelReason is { } why)
            {
                resumeReason = why;
                abortReason = why switch
                {
                    "cancel" => Protocol.JoinAbortHostCancel,
                    "host-reload" => Protocol.JoinAbortHostReload,
                    "joiner-gone" or "relay-lost" => 0,
                    _ => Protocol.JoinAbortHostCancel,
                };
            }
            else
            {
                resumeReason = "timeout";
                abortReason = Protocol.JoinAbortTimeout;
                Console.WriteLine($"MP-JOIN host: join 0x{j.JoinId:x8}: safety timeout ({_joinTimeoutS} s paused) -- resuming");
            }
        }
        catch (Exception ex)
        {
            resumeReason = "failed";
            abortReason = Protocol.JoinAbortIo;
            Console.WriteLine($"MP-JOIN host: join 0x{j.JoinId:x8} failed: {ex.GetType().Name}: {ex.Message}");
        }
        finally
        {
            await FinishHostJoinAsync(j, resumeReason, abortReason);
        }
    }

    private async Task FinishHostJoinAsync(HostJoin j, string reason, byte abortReason)
    {
        double pausedS = j.PausedUtc is { } p ? (DateTime.UtcNow - p).TotalSeconds : 0;
        // Resume first: nothing below may keep the host frozen.
        if (j.PausedUtc is not null)
        {
            try { await ExecLuaAsync($"if KCD2MP_JoinResume then KCD2MP_JoinResume(\"{j.JoinId:x8}\", \"{EscapeLua(reason)}\") end"); }
            catch (Exception ex) { Console.WriteLine($"MP-JOIN host: resume could not reach the mod: {ex.Message} (the mod's own timer resumes)"); }
        }
        else
        {
            try { await ExecLuaAsync($"if KCD2MP_JoinDeferEnd then KCD2MP_JoinDeferEnd(\"{j.JoinId:x8}\", \"{EscapeLua(reason)}\") end"); } catch { }
        }
        if (abortReason != 0 && reason != "joiner-gone" && reason != "relay-lost")
            try { await WriteJoinAsync(WorldReceiver.BuildAbort(j.Joiner, j.JoinId, abortReason)); } catch { }
        if (reason != "joiner-gone" && reason != "relay-lost")
            await TrySendStatusAsync(j, Protocol.JoinStateResumed, reason, (ushort)Math.Min(pausedS, ushort.MaxValue));
        Console.WriteLine(FormattableString.Invariant(
            $"MP-JOIN host: resume join=0x{j.JoinId:x8} reason={reason} paused_s={pausedS:F1} phase_at_end={j.Phase}{(abortReason != 0 ? $" abort_sent={Protocol.JoinAbortName(abortReason)}" : "")}"));
        lock (_joinGate) if (ReferenceEquals(_hostJoin, j)) _hostJoin = null;
        j.Cts.Dispose();
    }

    // ---------------------------------------------------------------- joiner side

    private async Task SendJoinRequestAsync()
    {
        if (!_sharedWorld) { Console.WriteLine("MP-JOIN mp_join_request needs mp_shared_world on"); return; }
        if (!_wo122Connected || !_combatRoleApplied) { Console.WriteLine("MP-JOIN mp_join_request: no session"); return; }
        if (_isDamageAuthority) { Console.WriteLine("MP-JOIN mp_join_request: this machine is the host -- the joiner asks"); return; }
        if (_joinRx is not null) { Console.WriteLine("MP-JOIN mp_join_request: a transfer is already running"); return; }
        _joinOutId = (uint)Random.Shared.Next(1, int.MaxValue);
        WorldReceiver.SweepStaging(WorldReceiver.DefaultStagingDir());
        SetJoinUi("requested", "Asking your host for the world...");
        try
        {
            await WriteJoinAsync(WorldReceiver.BuildRequest(_joinOutId));
            Console.WriteLine($"MP-JOIN joiner: join 0x{_joinOutId:x8} requested from the host");
        }
        catch (Exception ex) { Console.WriteLine($"MP-JOIN joiner: request not sent: {ex.Message}"); }
    }

    private async Task CancelOutgoingJoinAsync(string why)
    {
        uint id = _joinRx?.JoinId ?? _joinOutId;
        _joinRx?.Abort();
        _joinRx = null;
        _joinOutId = 0;
        SetJoinUi("aborted", "Join cancelled.");
        try { await WriteJoinAsync(WorldReceiver.BuildAbort(Protocol.JoinTargetHost, id, Protocol.JoinAbortJoinerCancel)); } catch { }
        Console.WriteLine($"MP-JOIN joiner: join 0x{id:x8} cancelled ({why}) -- staging deleted, the host resumes");
    }

    /// <summary>The next WO calls this once the joiner has spliced, loaded and is in the world.</summary>
    private async Task SendJoinerReadyAsync(string why)
    {
        if (_joinReceivedId == 0) { Console.WriteLine($"MP-JOIN joiner: ready ({why}) but no world was received -- not sent"); return; }
        try
        {
            await WriteJoinAsync(WorldReceiver.BuildReady(_joinReceivedId, _joinReceivedSeq));
            Console.WriteLine($"MP-JOIN joiner: ready sent for join 0x{_joinReceivedId:x8} (worldsaved_seq={_joinReceivedSeq}, {why})");
            SetJoinUi("ready", "In the world.");
            _joinReceivedId = 0;
        }
        catch (Exception ex) { Console.WriteLine($"MP-JOIN joiner: ready not sent: {ex.Message}"); }
    }

    private uint _joinReceivedId, _joinReceivedSeq;

    private void OnJoinStatusIn(byte src, uint joinId, byte[] body)
    {
        if (!JoinStatusCodec.TryDecode(body, out byte state, out byte reason, out ushort arg)) return;
        string st = Protocol.JoinStateName(state), rs = Protocol.JoinReasonName(reason);
        Console.WriteLine($"MP-JOIN joiner: host status join=0x{joinId:x8} state={st} reason={rs} arg={arg}");
        switch (state)
        {
            case Protocol.JoinStateDeferred: SetJoinUi("deferred", "Your host is busy, you'll join in a moment."); break;
            case Protocol.JoinStatePaused:
            case Protocol.JoinStateSaving: SetJoinUi("saving", "Your host is saving the world..."); break;
            case Protocol.JoinStateWaitingReady: SetJoinUi("received", "World received. Loading..."); break;
            case Protocol.JoinStateRefused: _joinOutId = 0; SetJoinUi("refused", $"Your host can't take a join right now ({rs})."); break;
            case Protocol.JoinStateResumed:
                if (rs != "ready") SetJoinUi("aborted", $"The join ended ({rs}).");
                break;
        }
    }

    private async Task OnWorldOfferInAsync(byte host, uint joinId, byte[] body, CancellationToken ct)
    {
        if (!_sharedWorld || _isDamageAuthority)
        {
            Console.WriteLine($"MP-JOIN joiner: offer 0x{joinId:x8} refused ({(!_sharedWorld ? "mp_shared_world off" : "this machine is the host")})");
            try { await WriteJoinAsync(WorldReceiver.BuildAbort(host, joinId, Protocol.JoinAbortSharedWorldOff)); } catch { }
            return;
        }
        if (joinId != _joinOutId)
        {
            Console.WriteLine($"MP-JOIN joiner: offer 0x{joinId:x8} refused: this machine asked for 0x{_joinOutId:x8}");
            try { await WriteJoinAsync(WorldReceiver.BuildAbort(host, joinId, Protocol.JoinAbortProtocol)); } catch { }
            return;
        }
        var offer = WorldOffer.TryDecode(body, out string why);
        if (offer is null)
        {
            Console.WriteLine($"MP-JOIN joiner: offer 0x{joinId:x8} refused: {why}");
            try { await WriteJoinAsync(WorldReceiver.BuildAbort(host, joinId, why.Contains("limit") ? Protocol.JoinAbortTooBig : Protocol.JoinAbortProtocol)); } catch { }
            return;
        }
        _joinRx?.Abort();
        string dir = WorldReceiver.DefaultStagingDir();
        int swept = WorldReceiver.SweepStaging(dir);
        try { _joinRx = new WorldReceiver(dir, joinId, host, offer.Value); }
        catch (Exception ex)
        {
            Console.WriteLine($"MP-JOIN joiner: cannot stage the world: {ex.Message}");
            try { await WriteJoinAsync(WorldReceiver.BuildAbort(host, joinId, Protocol.JoinAbortIo)); } catch { }
            return;
        }
        _joinRxLastDecile = -1;
        Interlocked.Exchange(ref _joinUiTotal, offer.Value.Size);
        Interlocked.Exchange(ref _joinUiBytes, 0);
        SetJoinUi("receiving", "Receiving the world... 0%");
        Console.WriteLine(FormattableString.Invariant(
            $"MP-JOIN joiner: offer 0x{joinId:x8} bytes={offer.Value.Size} chunks={offer.Value.ChunkCount} sha256={Convert.ToHexString(offer.Value.Sha256)[..16].ToLowerInvariant()} worldsaved_seq={offer.Value.WorldSavedSeq} md5={Convert.ToHexString(offer.Value.Md5)[..8].ToLowerInvariant()} -> <data>/join-staging (swept {swept})"));
    }

    private async Task OnWorldChunkInAsync(byte host, uint joinId, byte[] body, CancellationToken ct)
    {
        if (_joinRx is not { } rx || rx.JoinId != joinId || rx.Host != host || body.Length < 5) return;
        uint index = BinaryPrimitives.ReadUInt32LittleEndian(body);
        var res = rx.Accept(index, body.AsSpan(4), out string why);
        if (res == WorldReceiver.ChunkResult.Error)
        {
            rx.Abort();
            _joinRx = null;
            SetJoinUi("failed", "The world transfer failed.");
            Console.WriteLine($"MP-JOIN joiner: join 0x{joinId:x8} chunk rejected ({why}) -- staging deleted, aborting");
            try { await WriteJoinAsync(WorldReceiver.BuildAbort(host, joinId, Protocol.JoinAbortProtocol)); } catch { }
            return;
        }
        double secs = (DateTime.UtcNow - rx.StartedUtc).TotalSeconds;
        double rate = rx.Received / Math.Max(secs, 1e-3);
        Interlocked.Exchange(ref _joinUiBytes, rx.Received);
        _joinUiEtaS = rate > 0 ? (rx.Offer.Size - rx.Received) / rate : 0;
        _joinUiMessage = FormattableString.Invariant($"Receiving the world... {rx.Percent:F0}%");
        int decile = (int)(rx.Percent / 10);
        if (decile != _joinRxLastDecile)
        {
            _joinRxLastDecile = decile;
            Console.WriteLine(FormattableString.Invariant($"MP-JOIN joiner: receiving {rx.Received}/{rx.Offer.Size} B ({rx.Percent:F0}%) eta_s={_joinUiEtaS:F1}"));
        }
        if (res is WorldReceiver.ChunkResult.AckDue or WorldReceiver.ChunkResult.Complete)
            await WriteJoinAsync(rx.BuildAck());
        if (res != WorldReceiver.ChunkResult.Complete) return;

        var (ok, reason, fwhy) = rx.Finish();
        _joinRx = null;
        if (!ok)
        {
            SetJoinUi("failed", "The world arrived damaged -- the join was stopped.");
            Console.WriteLine($"MP-JOIN joiner: join 0x{joinId:x8} REJECTED: {fwhy} -- deleted, aborting ({Protocol.JoinAbortName(reason)})");
            try { await WriteJoinAsync(WorldReceiver.BuildAbort(host, joinId, reason)); } catch { }
            return;
        }
        await WriteJoinAsync(rx.BuildDone());
        _joinReceivedId = joinId;
        _joinReceivedSeq = rx.Offer.WorldSavedSeq;
        SetJoinUi("received", "World received. Loading...");
        Console.WriteLine(FormattableString.Invariant(
            $"MP-JOIN joiner: join 0x{joinId:x8} received {rx.Received} B in {secs:F2} s -- sha256 ok, WhsSave.Verify ok, md5 = the offer's -> <data>/join-staging/{Path.GetFileName(rx.FinalPath)}"));
    }

    private void SetJoinUi(string state, string message)
    {
        _joinUiState = state;
        _joinUiMessage = message;
    }

    /// <summary>GET /join-status for the launcher (hand-rolled JSON, like /version-status).</summary>
    internal string JoinStatusJson()
    {
        long b = Interlocked.Read(ref _joinUiBytes), t = Interlocked.Read(ref _joinUiTotal);
        double pct = t > 0 ? 100.0 * b / t : 0;
        var sb = new StringBuilder(160);
        sb.Append("{\"State\":\"").Append(_joinUiState).Append("\",\"Percent\":").Append(pct.ToString("F1", CultureInfo.InvariantCulture))
          .Append(",\"Bytes\":").Append(b).Append(",\"Total\":").Append(t)
          .Append(",\"EtaS\":").Append(_joinUiEtaS.ToString("F1", CultureInfo.InvariantCulture))
          .Append(",\"Message\":\"").Append(_joinUiMessage.Replace("\\", "\\\\").Replace("\"", "\\\"")).Append("\"}");
        return sb.ToString();
    }
}
