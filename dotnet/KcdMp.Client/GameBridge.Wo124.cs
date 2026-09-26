using System.Collections.Concurrent;
using System.Globalization;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace KcdMp.Client;

/// <summary>
/// WO-124 -- the join, on the joiner's side (docs/WO-124-findings.md). Dormant:
/// nothing here runs unless the HOST's mp_shared_world is on.
///
/// The host announces its session mode to every peer (JoinStatus state
/// "session", joinId 0: on connect, on a new peer, on a toggle and every 30 s).
/// A joiner takes the mode from the host. Then:
///   * at the main menu: the agent asks for the world by itself (WO-123 does
///     the pause, the save and the transfer);
///   * already in a world: nothing is asked; the player is told to come back
///     through the main menu (KCD2 has no exit-to-menu, so: restart the game);
///   * the world arrives (verified by WO-123) -> the joiner's own Henry is
///     spliced in (WhsSave.Splice + Check + Verify) from their newest own save
///     (or mp_join_henry) -> the result is placed as a transient
///     mpworld&lt;joinId&gt;.whs in that save's playline, read back, the engine's
///     cached save list is rescanned natively and the file must be listed ->
///     wh_sys_LoadGame from the menu;
///   * right after "Gameplay started": the file is deleted and the list
///     rescanned (Continue must never find it), then in order: the save lock
///     read back, the death guard, the Henry check (money + items against the
///     source), the teleport beside the host, and Ready (the host resumes).
/// Every failure sends JoinAbort (the host resumes) and leaves the joiner
/// where it can go on: at the menu before the load; after it, back in their
/// own newest save (KCD2 1.5.5 has no safe exit to the main menu: console
/// `disconnect` crashes the game (observed) and the menu's Quit ends the
/// process (code-verified)).
/// Save names in logs are playlineN/file only.
/// </summary>
public partial class GameBridge
{
    // ---------------------------------------------------------------- session mode

    private volatile bool _hostSharedWorld;
    private volatile bool _hostModeKnown;
    private volatile byte _hostModeFrom = 0xFF;
    private readonly ConcurrentDictionary<byte, bool> _modeTold = new();
    private DateTime _modeBroadcastUtc = DateTime.MinValue;
    private bool _modeEverShared;

    /// <summary>The session's mode as this machine should act on it: the host's word once heard, else the local toggle (older hosts, WO-122 tests).</summary>
    private bool JoinerSharedEffective => _hostModeKnown ? _hostSharedWorld : _sharedWorld;

    // ---------------------------------------------------------------- where the game is

    private enum GameWhere { Unknown, Menu, Loading, World }
    private volatile GameWhere _where = GameWhere.Unknown;
    private DateTime _whereAskedUtc = DateTime.MinValue;

    // ---------------------------------------------------------------- the joiner's join

    /// <summary>This game's world is (true) or is no longer (false) the host's; the WO-122 saves watch follows it.</summary>
    private void SetJoinedWorld(bool on)
    {
        if (_joinedWorld == on) return;
        _joinedWorld = on;
        Wo122EnsureWatcher();
    }

    private sealed class JoinerJoin
    {
        public uint JoinId;
        public byte Host;
        public uint WorldSavedSeq;
        public HenrySource? Source;
        public string? PlacedPath;
        public int Playline;
        public string Name = "";
        public byte[]? SplicedSha;
        public WhsSave.PlayerSoul? Henry;          // the spliced file's Henry (= the source's, minus quest items)
        public DateTime LoadCmdUtc, LoadStartUtc, LoadGameUtc, GameplayUtc;
        public volatile string Phase = "preparing";
        public bool InWorld;                        // WO-125: an in-world rejoin (a host reload) or a join from the own world
        public string Mode = "bring";               // WO-125: bring | fresh | restore
        public string? WorldTag;
        public WhsSave.HenryParts? SplicedParts;
        public byte[]? OfferMd5;
        public TaskCompletionSource<bool>? LoadStarted, GameplayStarted, LoadFailed;
    }

    private JoinerJoin? _jj;
    private volatile bool _joinedWorld;            // this game's loaded world is the host's (after a join, until it leaves)
    private HenrySource? _joinedSource;            // the save to go back to when leaving
    private volatile bool _ownLoadExpected;        // our own "leave" load is running
    private int _autoRequests;
    private DateTime _autoNextUtc = DateTime.MinValue;
    private volatile bool _needsMenuTold;
    private volatile bool _gameQuitting;           // "CSystem::Quit invoked" seen; cleared by the next connection
    private string _henryOverride = "auto";        // mp_join_henry
    private Dictionary<string, string>? _questClasses;

    private readonly ConcurrentDictionary<string, TaskCompletionSource<string>> _wo124Replies = new();

    public sealed record HenrySource(int Playline, string File, string FullPath, long SaveTime)
    {
        public string Display => $"playline{Playline}/{File}";
        public string Base => Path.GetFileNameWithoutExtension(File);
    }

    // ---------------------------------------------------------------- lifecycle

    /// <summary>KCDMP_JOIN_SAVES_DIR (tests) or the engine's saves folder.</summary>
    private static string? ResolveSavesDirForJoin() =>
        Environment.GetEnvironmentVariable("KCDMP_JOIN_SAVES_DIR") is { Length: > 0 } d ? d : ResolveSavesDir();

    private static readonly Regex TransientName = new(@"^mpworld[0-9a-f]{1,8}\.(whs|part)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// <summary>Delete every mpworld* file in playline0..4 (except <paramref name="keep"/>). Returns the count.</summary>
    public static int SweepTransientWorlds(string saves, string? keep)
    {
        int n = 0;
        for (int pl = 0; pl <= 4; pl++)
        {
            string dir = Path.Combine(saves, $"playline{pl}");
            if (!Directory.Exists(dir)) continue;
            foreach (var f in Directory.EnumerateFiles(dir))
            {
                if (!TransientName.IsMatch(Path.GetFileName(f))) continue;
                if (keep is not null && string.Equals(Path.GetFullPath(f), Path.GetFullPath(keep), StringComparison.OrdinalIgnoreCase)) continue;
                try { File.Delete(f); n++; Console.WriteLine($"MP-JOIN joiner: removed stale {SaveDisplay(f)}"); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                { Console.WriteLine($"MP-JOIN joiner: could not remove {SaveDisplay(f)}: {ex.Message}"); }
            }
        }
        return n;
    }

    private void Wo124OnConnect(Stream stream, CancellationToken ct)
    {
        _modeTold.Clear();
        _modeBroadcastUtc = DateTime.MinValue;
        _hostModeKnown = false;
        _autoRequests = 0;
        _autoNextUtc = DateTime.UtcNow.AddSeconds(2);
        _needsMenuTold = false;
        _gameQuitting = false;
        _ = ExecLuaAsync("if KCD2MP_Wo124CfgEmit then KCD2MP_Wo124CfgEmit() end");
        _ = Wo124LoopAsync(ct);
    }

    private async Task Wo124OnDisconnectAsync()
    {
        _hostModeKnown = false;
        if (_jj is { } jj && jj.Phase is "loading" or "post-load")
            Console.WriteLine($"MP-JOIN joiner: the relay connection dropped while join 0x{jj.JoinId:x8} was {jj.Phase}");
        if (_joinedWorld) await LeaveSharedWorldAsync("relay-lost", "Lost the connection to your host.");
        else if (_jj is { Phase: "preparing" or "loading" } j2) await AbortJoinerJoinAsync(j2, Protocol.JoinAbortIo, "relay-lost", "Lost the connection to your host.", sendAbort: false);
    }

    private async Task Wo124LoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(1000, ct); } catch { return; }
            try
            {
                if (!_combatRoleApplied) continue;
                if (_isDamageAuthority) { await Wo124HostModeTickAsync(); continue; }
                // Joiner: learn where the game is (the mod answers wo124_where).
                if (_where == GameWhere.Unknown && (DateTime.UtcNow - _whereAskedUtc).TotalSeconds >= 5)
                {
                    _whereAskedUtc = DateTime.UtcNow;
                    await ExecLuaAsync("if KCD2MP_Wo124Where then KCD2MP_Wo124Where() end");
                }
                await Wo124JoinerTickAsync();
            }
            catch (Exception ex) { Console.WriteLine($"MP-JOIN wo124 tick failed: {ex.Message}"); }
        }
    }

    // ---------------------------------------------------------------- host: the mode announcement

    private async Task Wo124HostModeTickAsync()
    {
        // Dormant: a host that never ran a shared world says nothing (peers then
        // keep their own toggle, as before WO-124); once it has, it keeps saying
        // which mode it runs, so a flip back to separate reaches every joiner.
        if (_sharedWorld) _modeEverShared = true;
        if (!_modeEverShared) return;
        Wo125HostTick();   // WO-125: an unknown world is identified by one world save
        // WO-125: silent while a load runs. The status carries the world's identity; sent mid-load it names
        // the world being left, and a joiner rewinding with the host would rejoin THAT one (observed with the
        // synthetic host). The next tick after "Gameplay started" announces the loaded world.
        if (_hostLoadAnnounced) return;
        bool resendAll = (DateTime.UtcNow - _modeBroadcastUtc).TotalSeconds >= 30;
        var peers = _peerLastSeenUtc.Keys.Concat(_ghostNames.Keys).Distinct().ToList();
        foreach (byte g in peers)
        {
            if (!resendAll && _modeTold.TryGetValue(g, out bool told) && told == _sharedWorld) continue;
            try
            {
                var (seed, flags) = _sharedWorld ? Wo125SessionIdentity() : (0u, (ushort)0);   // WO-125: the world's identity rides along
                await WriteJoinAsync(JoinStatusCodec.Build(g, seed, Protocol.JoinStateSession, Protocol.JoinReasonId(_sharedWorld ? "shared-world" : "separate"), flags));
                if (!_modeTold.TryGetValue(g, out bool was) || was != _sharedWorld)
                    Console.WriteLine($"MP-JOIN host: session mode {(_sharedWorld ? "shared-world" : "separate")} -> ghost {g}");
                _modeTold[g] = _sharedWorld;
            }
            catch (Exception ex) { Console.WriteLine($"MP-JOIN host: session mode not sent to ghost {g}: {ex.Message}"); }
        }
        if (resendAll) _modeBroadcastUtc = DateTime.UtcNow;
    }

    /// <summary>A toggle flip on the host: tell every peer at the next tick.</summary>
    private void Wo124OnSharedWorldChanged() => _modeTold.Clear();

    /// <summary>JoinStatus state "session" from the host (WO-125: the joinId slot carries the world's seed, arg its flags).</summary>
    private void Wo124OnSessionMode(byte src, byte reason, uint joinId = 0, ushort arg = 0)
    {
        bool on = Protocol.JoinReasonName(reason) == "shared-world";
        bool changed = !_hostModeKnown || _hostSharedWorld != on || _hostModeFrom != src;
        _hostSharedWorld = on;
        _hostModeKnown = true;
        _hostModeFrom = src;
        if (on) Wo125OnSessionIdentity(joinId, arg);
        if (!changed) return;
        Console.WriteLine($"MP-JOIN joiner: the host (ghost {src}) runs {(on ? "a SHARED WORLD" : "separate worlds")} -- this machine follows (local mp_shared_world={On(_sharedWorld)} ignored while connected)");
        _ = ExecLuaAsync($"if KCD2MP_Wo124SessionMode then KCD2MP_Wo124SessionMode({(on ? "true" : "false")}) end");
        if (!on)
        {
            _needsMenuTold = false;
            if (_joinUiState is "waiting" or "needs-menu" or "no-save") SetJoinUi("idle", "");
            // This game is in the host's world and the host stopped sharing it: without
            // the lock it could now be saved into this player's own playline. Leave it.
            if (_joinedWorld) _ = LeaveSharedWorldAsync("host-separate", "Your host turned the shared world off.");
        }
    }

    // ---------------------------------------------------------------- joiner: where the game is

    /// <summary>wo124_where menu|world|loading (the mod, asked by this agent).</summary>
    private void Wo124OnWhere(string? arg)
    {
        var w = (arg ?? "").Trim() switch { "menu" => GameWhere.Menu, "world" => GameWhere.World, "loading" => GameWhere.Loading, _ => GameWhere.Unknown };
        if (w == GameWhere.Unknown) return;
        if (_where != w) Console.WriteLine($"MP-JOIN joiner: the game is at {(w == GameWhere.Menu ? "the MAIN MENU" : w == GameWhere.World ? "a loaded world" : "a load")} (asked the mod)");
        _where = w;
    }

    /// <summary>"[CryAction] LoadGame: '...'" -- the save's data is being read (from the menu: after the level load).</summary>
    private void Wo124OnLoadStarted()
    {
        _where = GameWhere.Loading;
        if (_jj is { LoadStarted: not null } j) { if (j.LoadGameUtc == default) j.LoadGameUtc = DateTime.UtcNow; }
    }

    /// <summary>"Loading saved game '...playlineN/x.whs'" -- the engine accepted a load (printed at once).</summary>
    private void Wo124OnSaveLoadAccepted(string display)
    {
        _where = GameWhere.Loading;
        if (_combatRoleApplied && _isDamageAuthority) { Wo125HostOnLoadAccepted(display); return; }   // WO-125: the host's world changes
        if (_jj is { LoadStarted: { } t } j && display.Equals($"playline{j.Playline}/{j.Name}.whs", StringComparison.OrdinalIgnoreCase))
        {
            if (j.LoadStartUtc == default) j.LoadStartUtc = DateTime.UtcNow;
            t.TrySetResult(true);
            return;
        }
        if (_ownLoadExpected) return;
        if (_joinedWorld)
        {
            // The joiner loaded a save of its own from the pause menu: it has left the host's world.
            Console.WriteLine("MP-JOIN joiner: a load started that the join did not ask for -- this game is leaving the host's world (its progress there is kept up to the host's last save, WO-125)");
            _rewinding = false; _rejoinPending = false;
            SetJoinedWorld(false);
            _ = Wo122SetLockAsync(false, "left-shared-world");
            SetJoinUi("idle", "");
        }
    }

    /// <summary>"Exiting to main menu because save game loading failed." -- the engine went back to the menu.</summary>
    private void Wo124OnLoadFailedToMenu()
    {
        _where = GameWhere.Menu;
        _leaveInProgress = false;
        Console.WriteLine("MP-JOIN joiner: the engine reports a failed load and is back at the MAIN MENU");
        if (_jj is { LoadFailed: { } f }) f.TrySetResult(true);
        if (_joinedWorld) { SetJoinedWorld(false); _ = Wo122SetLockAsync(false, "load-failed"); }
    }

    private void Wo124OnMainMenuShown()
    {
        if (_where != GameWhere.Menu) Console.WriteLine("MP-JOIN joiner: the main menu is up");
        _where = GameWhere.Menu;
        _autoNextUtc = DateTime.UtcNow.AddSeconds(3);
        if (_gameQuitting)
        {
            // A new game process (the last one quit): a fresh start for the automatic join.
            _gameQuitting = false;
            _autoRequests = 0;
            _needsMenuTold = false;
        }
        // WO-125: a new process's mod starts with no session mode and the agent pushes it only on a change,
        // so an agent kept across a restart left the mod refusing the joiner's lock (observed: lock=failed).
        // Every main-menu line re-tells it (idempotent in the mod; a crash prints no quit line).
        if (_hostModeKnown)
        {
            Console.WriteLine($"MP-JOIN joiner: at the main menu -- telling the mod the host's session mode ({(_hostSharedWorld ? "shared world" : "separate")})");
            _ = ExecLuaAsync($"if KCD2MP_Wo124SessionMode then KCD2MP_Wo124SessionMode({(_hostSharedWorld ? "true" : "false")}) end");
        }
    }

    private void Wo124OnGameplayStarted()
    {
        _where = GameWhere.World;
        Wo125HostOnGameplayStarted();
        if (_ownLoadExpected) { _ownLoadExpected = false; _leaveInProgress = false; Console.WriteLine("MP-JOIN joiner: back in this player's own world (Gameplay started)"); }
        if (_jj is { } j && j.GameplayStarted is { } t) { j.GameplayUtc = DateTime.UtcNow; t.TrySetResult(true); }
    }

    // ---------------------------------------------------------------- joiner: the tick

    private async Task Wo124JoinerTickAsync()
    {
        if (!_hostModeKnown || !_hostSharedWorld) return;
        if (_jj is not null || _joinRx is not null || _joinOutId != 0 || _gameQuitting) return;
        // WO-125: nothing is asked while this game is leaving a world (its own load not yet in). Observed
        // before this gate: a join asked during the leave's 4 s notice raced the leave's own load, and the
        // own load landed last -- the agent believed the joiner was in the host's world.
        if (_leaveInProgress)
        {
            if ((DateTime.UtcNow - _leaveSinceUtc).TotalMinutes < 5) return;
            Console.WriteLine("MP-HENRY joiner: the leave's own load never reported in (5 min) -- the join gate opens again");
            _leaveInProgress = false;
        }
        if (_joinedWorld)
        {
            // WO-125 Phase 6: the host reloaded this world -- rejoin from inside it (the host defers while it loads).
            if (!_rejoinPending || DateTime.UtcNow < _autoNextUtc) return;
            if ((DateTime.UtcNow - _rejoinSinceUtc).TotalMinutes > 5)
            {
                _rejoinPending = false;
                await LeaveSharedWorldAsync("rejoin-timeout", "Could not rejoin your host after its reload.");
                return;
            }
            _autoNextUtc = DateTime.UtcNow.AddSeconds(20);
            Console.WriteLine("MP-HENRY joiner: asking the host for its reloaded world (an in-world rejoin)");
            await SendJoinRequestAsync();
            return;
        }
        bool fromWorld = _where == GameWhere.World && _joinFromWorldOnce;   // WO-125: after leaving for the host's new world
        if (_where == GameWhere.World && !fromWorld && !_needsMenuTold)
        {
            _needsMenuTold = true;
            const string msg = "Your host is in a shared world. Quit, start the game again and wait at the main menu to join.";
            Console.WriteLine("MP-JOIN joiner: the host is in a shared world but this game is already in a world -- no join asked; telling the player");
            SetJoinUi("needs-menu", msg);
            await ExecLuaAsync($"if KCD2MP_Wo124Msg then KCD2MP_Wo124Msg(\"{EscapeLua(msg)}\") end");
            return;
        }
        if ((_where != GameWhere.Menu && !fromWorld) || DateTime.UtcNow < _autoNextUtc) return;
        if (_autoRequests >= 5) return;   // five automatic tries per connection; mp_join_request always works
        // WO-125: the host's world must be known and a Henry world; a first join needs the player's choice
        // and a usable source BEFORE the request, so the host is never paused while someone decides.
        if (!Wo125ReadyToRequest(out string why))
        {
            _autoNextUtc = DateTime.UtcNow.AddSeconds(2);
            return;
        }
        _autoRequests++;
        _autoNextUtc = DateTime.UtcNow.AddSeconds(30);
        if (fromWorld) _joinFromWorldOnce = false;
        string what = _henry.HasWorld(_peerTag!) ? $"its own Henry for world {_peerTag} is restored" : $"first join ({CurrentChoice()})";
        Console.WriteLine($"MP-JOIN joiner: {(fromWorld ? "in its own world after the host changed worlds" : "at the main menu")} with a shared-world host -- asking for the world (auto, try {_autoRequests}; {what})");
        await SendJoinRequestAsync();
        if (_joinOutId != 0) SetJoinUi("waiting", "Waiting for your host...");
    }

    private const string NoOwnSaveMessage = "Start a game of your own first, so your character can come with you.";

    // ---------------------------------------------------------------- Phase 1: which Henry

    /// <summary>Every engine-named save in playline0..4, newest SaveTime first.</summary>
    public static List<HenrySource> ListOwnSaves(string saves)
    {
        var o = new List<HenrySource>();
        for (int pl = 0; pl <= 4; pl++)
        {
            string dir = Path.Combine(saves, $"playline{pl}");
            if (!Directory.Exists(dir)) continue;
            foreach (var f in Directory.EnumerateFiles(dir, "*.whs"))
            {
                string name = Path.GetFileName(f);
                if (name.StartsWith("mpworld", StringComparison.OrdinalIgnoreCase)) continue;
                if (WorldSaved.ParsePath(f) is null) continue;   // engine names only
                if (ReadSaveTime(f) is long t) o.Add(new HenrySource(pl, name, f, t));
            }
        }
        return o.OrderByDescending(s => s.SaveTime).ThenBy(s => s.Display, StringComparer.Ordinal).ToList();
    }

    /// <summary>SaveTime="unix seconds" from a save's description header (the first bytes only).</summary>
    public static long? ReadSaveTime(string path)
    {
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var head = new byte[8];
            if (fs.Read(head, 0, 8) != 8 || BitConverter.ToUInt32(head, 0) != 0xFFFFFFFFu) return null;
            int n = BitConverter.ToInt32(head, 4);
            if (n <= 0 || n > 64 * 1024) return null;
            var desc = new byte[n];
            int got = 0;
            while (got < n) { int r = fs.Read(desc, got, n - got); if (r <= 0) return null; got += r; }
            var m = Regex.Match(Encoding.UTF8.GetString(desc), @"\bSaveTime=""(\d+)""");
            return m.Success ? long.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture) : null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return null; }
    }

    // ---------------------------------------------------------------- Phase 2+3: splice, place, load

    /// <summary>WO-123 received and verified the world (Done sent). Called from the chunk handler.</summary>
    private Task Wo124OnWorldReceivedAsync(uint joinId, byte host, string stagedPath, uint seq)
    {
        if (!JoinerSharedEffective) return Task.CompletedTask;
        var j = new JoinerJoin { JoinId = joinId, Host = host, WorldSavedSeq = seq, InWorld = _where == GameWhere.World, OfferMd5 = _joinReceivedMd5 };
        _jj = j;
        // Never awaited by the frame loop: observed, awaiting it held every relay
        // frame (the host's positions, its aborts) for the whole ~50 s load.
        _ = Task.Run(() => RunJoinerJoinAsync(j, stagedPath));
        return Task.CompletedTask;
    }

    private async Task RunJoinerJoinAsync(JoinerJoin j, string stagedPath)
    {
        var t0 = DateTime.UtcNow;
        try
        {
            SetJoinUi("preparing", "Preparing your character...");
            string? saves = ResolveSavesDirForJoin();
            string? tables = TablesPakPath();
            if (saves is null || tables is null)
            {
                Console.WriteLine($"MP-JOIN joiner: join 0x{j.JoinId:x8}: {(saves is null ? "no saves folder" : "Tables.pak not found beside kcd.log")} -- abort");
                await AbortJoinerJoinAsync(j, Protocol.JoinAbortSpliceFailed, "splice-failed", "Your character could not be prepared.");
                return;
            }
            byte[] hostBytes = WhsSave.ReadShared(stagedPath);

            // ---- Phase 1 (WO-125): which Henry. The world's own (restore) or the first-join choice
            // (bring / fresh); the world must be the one announced and a Henry world.
            var choice = Wo125HenryForWorld(j.JoinId, hostBytes, out string why, out byte abortWhy, out string worldTag);
            if (choice is null)
            {
                Console.WriteLine($"MP-JOIN joiner: join 0x{j.JoinId:x8}: {why}");
                string msg = abortWhy switch
                {
                    Protocol.JoinAbortNotHenry => "Your host is in a part of the story where you can't join yet.",
                    Protocol.JoinAbortWorldChanged => "Your host changed worlds -- trying again in a moment.",
                    Protocol.JoinAbortNoOwnSave => NoOwnSaveMessage,
                    _ => why.EndsWith('.') ? why : "Your character could not be prepared.",
                };
                if (j.InWorld) await LeaveAfterFailedJoinAsync(j, abortWhy, Protocol.JoinAbortName(abortWhy), msg);
                else await AbortJoinerJoinAsync(j, abortWhy, abortWhy == Protocol.JoinAbortNoOwnSave ? "no-own-save" : Protocol.JoinAbortName(abortWhy), msg);
                return;
            }
            j.Source = choice.Save;
            j.Mode = choice.Mode;
            j.WorldTag = worldTag;

            // ---- Phase 2: splice + check + verify, in memory
            _questClasses ??= WhsSave.QuestClasses(tables);
            var ts = DateTime.UtcNow;
            WhsSave.SpliceResult res;
            List<string> fails;
            try
            {
                res = WhsSave.SpliceParts(hostBytes, choice.Parts, _questClasses, WhsSave.QuestItemMode.Strip);
                fails = WhsSave.CheckParts(hostBytes, choice.Parts, res.File, _questClasses, WhsSave.QuestItemMode.Strip);
            }
            catch (Exception ex) when (ex is InvalidDataException or IOException or ArgumentException)
            {
                Console.WriteLine($"MP-JOIN joiner: join 0x{j.JoinId:x8}: splice REFUSED: {ex.Message}");
                await AbortJoinerJoinAsync(j, Protocol.JoinAbortSpliceFailed, "splice-failed", "Your character could not be brought into your host's world.");
                return;
            }
            var ver = WhsSave.Verify(res.File);
            double spliceMs = (DateTime.UtcNow - ts).TotalMilliseconds;
            if (fails.Count > 0 || !ver.Ok)
            {
                foreach (var f in fails.Take(8)) Console.WriteLine($"MP-JOIN joiner:   check FAIL {f}");
                Console.WriteLine($"MP-JOIN joiner: join 0x{j.JoinId:x8}: splice check {fails.Count} failure(s), verify {(ver.Ok ? "ok" : ver.Reason)} -- abort, nothing placed");
                await AbortJoinerJoinAsync(j, Protocol.JoinAbortSpliceFailed, "splice-failed", "Your character could not be brought into your host's world.");
                return;
            }
            var rp = res.Report;
            var splicedRaw = WhsSave.Inflate(res.File).Raw;
            j.Henry = WhsSave.DecodePlayerSoul(splicedRaw, WhsSave.FindSoul(splicedRaw, WhsSave.HenrySoul)!.Value);
            // WO-125: the Henry exactly as loaded -- the join save pairs with it after Ready.
            j.SplicedParts = WhsSave.PartsFromStream(splicedRaw, choice.Parts.Build, WhsSave.HenryParts.OriginSnapshot);
            Console.WriteLine(FormattableString.Invariant(
                $"MP-JOIN joiner: join 0x{j.JoinId:x8} spliced world={hostBytes.Length} B + henry={choice.Detail} ({choice.Mode}) -> {res.File.Length} B in {spliceMs:F0} ms; check PASS, verify ok; quest items stripped={rp.QuestItemsRemoved.Count}, keys host_kept={rp.KeysHostKept} joiner_added={rp.KeysJoinerAdded}"));
            try { File.Delete(stagedPath); } catch { }

            // ---- Phase 3: place, read back, rescan, listed. In the playline of this player's newest own
            // save (= the menu's current playline, WO-124 s4.2); in a world: the playline it is in.
            j.Playline = j.InWorld && _lastWorldPlayline >= 0 ? _lastWorldPlayline : Wo125NewestOwn(out _)?.Playline ?? choice.Save?.Playline ?? 0;
            _lastWorldPlayline = j.Playline;
            j.Name = $"mpworld{j.JoinId:x8}";
            string dir = Path.Combine(saves, $"playline{j.Playline}");
            string part = Path.Combine(dir, j.Name + ".part");
            string final = Path.Combine(dir, j.Name + ".whs");
            Wo125Sweep("before a join");
            using (var fs = new FileStream(part, FileMode.CreateNew, FileAccess.Write)) fs.Write(res.File);
            File.Move(part, final);
            j.PlacedPath = final;
            j.SplicedSha = SHA256.HashData(res.File);
            var back = WhsSave.ReadShared(final);
            if (!SHA256.HashData(back).AsSpan().SequenceEqual(j.SplicedSha) || !WhsSave.Verify(back).Ok)
            {
                Console.WriteLine($"MP-JOIN joiner: join 0x{j.JoinId:x8}: the placed file does not read back as written -- abort");
                await AbortJoinerJoinAsync(j, Protocol.JoinAbortIo, "load-failed", "Your host's world could not be placed.");
                return;
            }
            Console.WriteLine($"MP-JOIN joiner: join 0x{j.JoinId:x8} placed {SaveDisplay(final)} ({back.Length} B, read back: sha256 = the splice, verify ok)");
            var listed = await _combat.SaveListAsync(1, j.Playline, j.Name);
            if (listed is null || !listed.Listed)
            {
                Console.WriteLine($"MP-JOIN joiner: join 0x{j.JoinId:x8}: the native rescan {(listed is null ? "did not answer (is the plugin running?)" : $"does not list it (playline{j.Playline} has {listed.Count})")} -- abort, fail closed");
                await AbortJoinerJoinAsync(j, Protocol.JoinAbortLoadFailed, "load-failed", "Your host's world could not be loaded.");
                return;
            }
            Console.WriteLine($"MP-JOIN joiner: join 0x{j.JoinId:x8} rescan: {j.Name} is listed (idx {listed.Idx} of {listed.Count} in playline{j.Playline}; current playline {listed.Current}, Continue would load playline{listed.ContinuePlayline}/{listed.ContinueName})");

            // ---- the load, from the menu
            j.Phase = "loading";
            SetJoinUi("loading", "Loading your host's world...");
            j.LoadStarted = new(TaskCreationOptions.RunContinuationsAsynchronously);
            j.GameplayStarted = new(TaskCreationOptions.RunContinuationsAsynchronously);
            j.LoadFailed = new(TaskCreationOptions.RunContinuationsAsynchronously);
            j.LoadCmdUtc = DateTime.UtcNow;
            await ExecLuaAsync($"if KCD2MP_Wo124LoadGame then KCD2MP_Wo124LoadGame({j.Playline}, \"{j.Name}\", \"join\") end");
            // The engine prints "Loading saved game '...'" at once; from the menu it
            // then loads the level and reads the FILE only ~40 s later (the second
            // "Loading saved game" + "[CryAction] LoadGame"), so the file must stay
            // until "Gameplay started" (observed: deleting it earlier failed the
            // load and the engine went back to the menu).
            if (await Task.WhenAny(j.LoadStarted.Task, Task.Delay(20000)) != j.LoadStarted.Task)
            {
                Console.WriteLine($"MP-JOIN joiner: join 0x{j.JoinId:x8}: the engine did not accept wh_sys_LoadGame {j.Playline} {j.Name} within 20 s -- abort");
                await AbortJoinerJoinAsync(j, Protocol.JoinAbortLoadFailed, "load-failed", "Your host's world could not be loaded.");
                return;
            }
            var endT = await Task.WhenAny(j.GameplayStarted.Task, j.LoadFailed.Task, Task.Delay(300000));
            if (endT != j.GameplayStarted.Task)
            {
                Console.WriteLine($"MP-JOIN joiner: join 0x{j.JoinId:x8}: the load {(endT == j.LoadFailed.Task ? "FAILED (the engine went back to the menu)" : "never reached \"Gameplay started\" in 300 s")} -- abort");
                await AbortJoinerJoinAsync(j, Protocol.JoinAbortLoadFailed, "load-failed", "Your host's world could not be loaded.");
                return;
            }
            Console.WriteLine(FormattableString.Invariant(
                $"MP-JOIN joiner: join 0x{j.JoinId:x8} loaded: command -> accepted {(j.LoadStartUtc - j.LoadCmdUtc).TotalSeconds:F1} s, -> file read (LoadGame) {(j.LoadGameUtc == default ? double.NaN : (j.LoadGameUtc - j.LoadCmdUtc).TotalSeconds):F1} s, -> Gameplay started {(j.GameplayUtc - j.LoadCmdUtc).TotalSeconds:F1} s (received -> in world {(j.GameplayUtc - t0).TotalSeconds:F1} s)"));
            j.Phase = "post-load";
            _joinedSource = choice.Save;
            SetJoinedWorld(true);   // the saves watch runs: a save that still lands here is a leak (QuickSave passes the lock)

            // ---- right after Gameplay started: the file goes, Continue must not find it
            await RemovePlacedWorldAsync(j, "after-load");
            await PostLoadAsync(j);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"MP-JOIN joiner: join 0x{j.JoinId:x8} failed: {ex.GetType().Name}: {ex.Message}");
            await AbortJoinerJoinAsync(j, Protocol.JoinAbortIo, "failed", "The join failed.");
        }
    }

    private static string? TablesPakPath()
    {
        string? dir = Environment.GetEnvironmentVariable("KCD2MP_INSTALL");
        if (string.IsNullOrEmpty(dir)) dir = KcdLogLocator.Find() is string log ? Path.GetDirectoryName(log) : null;
        if (dir is null) return null;
        string p = Path.Combine(dir, "Data", "Tables.pak");
        return File.Exists(p) ? p : null;
    }

    /// <summary>Delete the transient file, rescan, and report what Continue would load now.</summary>
    private async Task RemovePlacedWorldAsync(JoinerJoin j, string why)
    {
        if (j.PlacedPath is not string p) return;
        bool gone = false;
        try { if (File.Exists(p)) File.Delete(p); gone = !File.Exists(p); } catch (Exception ex) { Console.WriteLine($"MP-JOIN joiner: could not delete {SaveDisplay(p)}: {ex.Message}"); }
        j.PlacedPath = gone ? null : p;
        var after = await _combat.SaveListAsync(1, j.Playline, j.Name);
        string expect = "?";
        if (ResolveSavesDirForJoin() is string saves)
        {
            var own = OwnSaves(saves, HostSeedForOwn(), l => Console.WriteLine(l)).FirstOrDefault(s => s.Save.Playline == j.Playline);   // WO-125: a host-seed copy is never "own"
            expect = own?.Save.Base ?? "-";
        }
        bool contOk = after is not null && !after.Listed && after.ContinueName == expect;
        Console.WriteLine($"MP-JOIN joiner: join 0x{j.JoinId:x8} {why}: {SaveDisplay(p)} deleted={On(gone)}; rescan listed={(after is null ? "?" : On(after.Listed))}; " +
                          $"Continue would load playline{after?.ContinuePlayline}/{after?.ContinueName ?? "?"} (this player's newest own save in playline{j.Playline}: {expect}) -> {(contOk ? "OK" : "CHECK")}");
    }

    // ---------------------------------------------------------------- Phase 4: in the world, before Ready

    private async Task PostLoadAsync(JoinerJoin j)
    {
        // 0. WO-125: the world in memory is the file this join placed (the engine's own record of the last
        // load). The Henry check cannot tell two worlds apart when the Henry is the same (a "bring" restore
        // equals the player's own save's Henry), so it is asked here.
        string last = await AskModAsync("KCD2MP_Wo125LastLoaded", 6000);
        string lastBase = last.StartsWith("last=", StringComparison.Ordinal) ? last[5..] : "?";
        if (lastBase is "?" or "" or "nil" or "timeout" || last == "timeout")
            Console.WriteLine($"MP-JOIN joiner: join 0x{j.JoinId:x8} step 0 loaded file: the engine's last-loaded save is not readable ({last}) -- not checked (inconclusive)");
        else if (!string.Equals(lastBase, j.Name, StringComparison.OrdinalIgnoreCase))
        {
            Console.WriteLine($"MP-JOIN joiner: join 0x{j.JoinId:x8} step 0 loaded file: the engine last loaded '{lastBase}', not {j.Name} -- this is not the host's world; leaving");
            await LeaveAfterFailedJoinAsync(j, Protocol.JoinAbortLoadFailed, "load-failed", "Your host's world did not load.");
            return;
        }
        else Console.WriteLine($"MP-JOIN joiner: join 0x{j.JoinId:x8} step 0 loaded file: {lastBase} (the engine's last load = the placed file)");

        // 1. the save lock, read back
        await Wo122SetLockAsync(true, "join");
        string lockR = await AskModAsync("KCD2MP_Wo124Lock", 6000);
        Console.WriteLine($"MP-JOIN joiner: join 0x{j.JoinId:x8} step 1 save lock: {lockR}");
        if (!lockR.StartsWith("lock=held", StringComparison.Ordinal))
        {
            await LeaveAfterFailedJoinAsync(j, Protocol.JoinAbortLockFailed, "lock-failed", "Your saves could not be locked for the shared world.");
            return;
        }

        // 2. the death guard (WO-113; re-applied by the DLL every 250 ms after a load)
        (bool Session, bool Enabled, bool Applied)? g = null;
        for (int i = 0; i < 40; i++)   // up to 10 s: the DLL re-finds the player soul every 2 s after a load
        {
            g = await _combat.JoinGuardAsync();
            if (g is { Applied: true } || g is { Enabled: false }) break;
            await Task.Delay(250);
        }
        string gs = g is null ? "no answer" : $"session={On(g.Value.Session)} mp_respawn={On(g.Value.Enabled)} applied={On(g.Value.Applied)}";
        Console.WriteLine($"MP-JOIN joiner: join 0x{j.JoinId:x8} step 2 death guard: {gs}");
        if (g is not { } gg || (gg.Enabled && !gg.Applied))
        {
            await LeaveAfterFailedJoinAsync(j, Protocol.JoinAbortLockFailed, "lock-failed", "The death guard could not be set up.");
            return;
        }

        // 3. the Henry is the spliced one
        string henry = await AskModAsync("KCD2MP_Wo124Henry", 8000);
        var (hOk, hWhy) = CompareHenry(j.Henry!, henry);
        Console.WriteLine($"MP-JOIN joiner: join 0x{j.JoinId:x8} step 3 Henry check: {(hOk ? "MATCH" : "MISMATCH")} -- {hWhy}");
        if (!hOk)
        {
            await LeaveAfterFailedJoinAsync(j, Protocol.JoinAbortHenryMismatch, "henry-mismatch", "Your character did not arrive as expected.");
            return;
        }

        // 4. beside the host, on the ground
        if (_ghostLastPos.TryGetValue(j.Host, out var hp) && (DateTime.UtcNow - hp.AtUtc).TotalSeconds < 10)
        {
            var pr = await _combat.JoinPlaceAsync(hp.X, hp.Y, hp.Z, 3.0f);
            Console.WriteLine(pr is null
                ? $"MP-JOIN joiner: join 0x{j.JoinId:x8} step 4 beside the host: no answer from the plugin (the joiner keeps the spliced spot)"
                : FormattableString.Invariant($"MP-JOIN joiner: join 0x{j.JoinId:x8} step 4 beside the host ({hp.X:F1}, {hp.Y:F1}, {hp.Z:F1}): {(pr.Ok ? "placed" : "NOT placed")} at ({pr.After[0]:F1}, {pr.After[1]:F1}, {pr.After[2]:F1}) snapped={On(pr.Snapped)} residual_m={pr.Residual:F2} moved_m={Dist(pr.Before, pr.After):F1}"));
        }
        else Console.WriteLine($"MP-JOIN joiner: join 0x{j.JoinId:x8} step 4 beside the host: no fresh host position (ghost {j.Host}) -- the joiner keeps the spliced spot");

        // 5. Ready
        uint readySeq = _joinReceivedSeq;
        await SendJoinerReadyAsync("wo124");
        if (j.WorldTag is string wt && j.SplicedParts is { } sp) Wo125AfterReady(wt, j.Mode, sp, j.OfferMd5, readySeq);   // WO-125: the join save's matched pair
        j.Phase = "in";
        SetJoinUi("in", "In your host's world.");
        await ExecLuaAsync("if KCD2MP_Wo124Msg then KCD2MP_Wo124Msg(\"Co-op: you are in your host's world.\") end");
        _jj = null;
        _ = Task.Delay(10000).ContinueWith(_ => { if (_joinUiState == "in") SetJoinUi("idle", ""); });
    }

    private static double Dist(float[] a, float[] b) => Math.Sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]) + (a[2] - b[2]) * (a[2] - b[2]));

    public const string MoneyClass = "5ef63059-322e-4e1b-abe8-926e100c770e";
    public const string KeyringClass = "b54eaa25-f0e9-425b-8b29-1fb14a71de56";

    /// <summary>
    /// The live Henry against the spliced file's: money (the file's money item
    /// amount = live GetMoney x 10) and every item class with its total amount
    /// (the live-only keyring aside). Skills are logged only: their saved XP
    /// encoding is not decoded (WO-115).
    /// </summary>
    public static (bool Ok, string Why) CompareHenry(WhsSave.PlayerSoul file, string live)
    {
        var kv = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var part in live.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            int eq = part.IndexOf('=');
            if (eq > 0) kv[part[..eq]] = part[(eq + 1)..];
        }
        if (!kv.TryGetValue("money", out var ms) || !double.TryParse(ms, NumberStyles.Float, CultureInfo.InvariantCulture, out double money))
            return (false, $"the live read is incomplete ('{(live.Length > 80 ? live[..80] : live)}')");
        static int Amount(string p)
        {
            var m = Regex.Match(p, @"\bamount=(\d+)");
            return m.Success ? int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture) : 1;
        }
        long fileMoney = file.Inventory.Where(i => i.Class == MoneyClass).Sum(i => (long)Amount(i.Params));
        long liveMoney = (long)Math.Round(money * 10);
        var fileItems = new SortedDictionary<string, long>(StringComparer.Ordinal);
        foreach (var i in file.Inventory.Where(i => i.Class != MoneyClass && i.Class != KeyringClass))
            fileItems[i.Class] = fileItems.GetValueOrDefault(i.Class) + Amount(i.Params);
        var liveItems = new SortedDictionary<string, long>(StringComparer.Ordinal);
        foreach (var e in (kv.GetValueOrDefault("items") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            int c = e.LastIndexOf(':');
            if (c <= 0) continue;
            string cls = e[..c].ToLowerInvariant();
            if (cls == MoneyClass || cls == KeyringClass) continue;
            liveItems[cls] = liveItems.GetValueOrDefault(cls) + (long.TryParse(e[(c + 1)..], out long a) ? a : 1);
        }
        var diff = fileItems.Keys.Union(liveItems.Keys).Where(k => fileItems.GetValueOrDefault(k) != liveItems.GetValueOrDefault(k)).ToList();
        string skills = kv.GetValueOrDefault("skills") ?? "-";
        string why = $"money file={fileMoney} live={liveMoney}; item classes file={fileItems.Count} ({fileItems.Values.Sum()}) live={liveItems.Count} ({liveItems.Values.Sum()}), differing={diff.Count}; skills (logged, not compared)={skills}";
        if (diff.Count > 0) why += "; e.g. " + string.Join(",", diff.Take(3).Select(k => $"{k[..8]} file={fileItems.GetValueOrDefault(k)} live={liveItems.GetValueOrDefault(k)}"));
        return (fileMoney == liveMoney && diff.Count == 0, why);
    }

    // ---------------------------------------------------------------- asking the mod

    /// <summary>Call a mod function with a token; its reply comes back as wo124_reply &lt;tok&gt; &lt;payload&gt;.</summary>
    private async Task<string> AskModAsync(string fn, int timeoutMs)
    {
        string tok = Convert.ToHexString(RandomNumberGenerator.GetBytes(4)).ToLowerInvariant();
        var tcs = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        _wo124Replies[tok] = tcs;
        try
        {
            await ExecLuaAsync($"if {fn} then {fn}(\"{tok}\") else KCD2MP_EmitEvent(\"wo124_reply\", \"{tok} missing\") end");
            var done = await Task.WhenAny(tcs.Task, Task.Delay(timeoutMs));
            return done == tcs.Task ? tcs.Task.Result : "timeout";
        }
        finally { _wo124Replies.TryRemove(tok, out _); }
    }

    private void Wo124OnEvent(string name, string? arg)
    {
        switch (name)
        {
            case "wo124_reply":
            {
                var s = arg ?? "";
                int sp = s.IndexOf(' ');
                string tok = sp > 0 ? s[..sp] : s, payload = sp > 0 ? s[(sp + 1)..] : "";
                if (_wo124Replies.TryGetValue(tok, out var t)) t.TrySetResult(payload);
                return;
            }
            case "wo124_where":
                Wo124OnWhere(arg);
                return;
            case "wo124_henry_cfg":      // mp_join_henry <auto|playlineN/file>
            {
                string v = (arg ?? "").Trim();
                _henryOverride = v == "" ? "auto" : v;
                Console.WriteLine($"MP-JOIN mp_join_henry {_henryOverride}");
                return;
            }
        }
    }

    // ---------------------------------------------------------------- failures and leaving

    /// <summary>Before the load: abort to the host (it resumes), clean up, stay at the menu.</summary>
    private async Task AbortJoinerJoinAsync(JoinerJoin j, byte reason, string why, string message, bool sendAbort = true)
    {
        if (sendAbort)
            try { await WriteJoinAsync(WorldReceiver.BuildAbort(j.Host, j.JoinId, reason)); } catch { }
        if (j.PlacedPath is string p)
        {
            try { File.Delete(p); } catch { }
            j.PlacedPath = null;
            var after = await _combat.SaveListAsync(1, j.Playline, j.Name);
            Console.WriteLine($"MP-JOIN joiner: join 0x{j.JoinId:x8}: removed {SaveDisplay(p)}; rescan listed={(after is null ? "?" : On(after.Listed))}");
        }
        WorldReceiver.SweepStaging(WorldReceiver.DefaultStagingDir());
        _joinReceivedId = 0;
        if (ReferenceEquals(_jj, j)) _jj = null;
        _autoNextUtc = DateTime.UtcNow.AddSeconds(30);
        SetJoinUi(why == "no-own-save" ? "no-save" : "failed", message);
        Console.WriteLine($"MP-JOIN joiner: join 0x{j.JoinId:x8} ABORTED ({why}) -- JoinAbort {Protocol.JoinAbortName(reason)} {(sendAbort ? "sent (the host resumes)" : "not sent")}; {(j.InWorld && _joinedWorld ? "leaving the host's world" : "staying where it is")}");
        // WO-125: a failed in-world rejoin leaves the host's world (what the joiner did since the reload is not kept).
        if (j.InWorld && _joinedWorld) await LeaveSharedWorldAsync(why, message);
    }

    /// <summary>After the load: abort to the host, then leave its world (back to this player's own newest save).</summary>
    private async Task LeaveAfterFailedJoinAsync(JoinerJoin j, byte reason, string why, string message)
    {
        try { await WriteJoinAsync(WorldReceiver.BuildAbort(j.Host, j.JoinId, reason)); } catch { }
        Console.WriteLine($"MP-JOIN joiner: join 0x{j.JoinId:x8} ABORTED after the load ({why}) -- JoinAbort {Protocol.JoinAbortName(reason)} sent (the host resumes)");
        _joinReceivedId = 0;
        if (ReferenceEquals(_jj, j)) _jj = null;
        _autoRequests = 99;   // no automatic retry into the same failure
        await LeaveSharedWorldAsync(why, message);
    }

    /// <summary>
    /// Out of the host's world: the player is told, then this player's own
    /// newest save (the join's Henry source) is loaded. KCD2 1.5.5 has no safe
    /// exit to the main menu.
    /// </summary>
    private async Task LeaveSharedWorldAsync(string why, string message)
    {
        if (!_joinedWorld && _jj is null) return;
        _leaveInProgress = true;           // WO-125: no join is asked until this leave's own load is in
        _newWorldLeavePending = false;
        _leaveSinceUtc = DateTime.UtcNow;
        // WO-125 Phase 2: the target is recomputed now -- the newest own save whose playthrough is not the
        // host's (a hand-placed copy of the host's world is never "own"). None: the way back to the menu.
        var (src, ownWhy) = await Wo125NewestOwnLoadableAsync();
        SetJoinedWorld(false);
        _jj = null;
        _rewinding = false;
        _rejoinPending = false;
        await Wo122SetLockAsync(false, "left-shared-world");
        string full = src is null ? message : $"{message} Going back to your own game.";
        SetJoinUi("left", full);
        Console.WriteLine($"MP-JOIN joiner: leaving the host's world ({why}) -> {(src is null ? "no own save (" + ownWhy + "): back to the main menu" : "loading " + src.Display)}");
        await ExecLuaAsync($"if KCD2MP_Wo124Msg then KCD2MP_Wo124Msg(\"{EscapeLua(full)}\") end");
        if (src is null)
        {
            await Task.Delay(4000);
            if (!await Wo125ExitToMenuAsync(why)) { _leaveInProgress = false; SetJoinUi("left", message + " Quit the game to get back to the main menu."); }
            return;
        }
        await Task.Delay(4000);
        _ownLoadExpected = true;
        await ExecLuaAsync($"if KCD2MP_Wo124LoadGame then KCD2MP_Wo124LoadGame({src.Playline}, \"{src.Base}\", \"leave\") end");
    }

    /// <summary>The host left the relay (0x06) while this game was in its world or joining.</summary>
    private async Task Wo124OnPeerGoneAsync(byte ghostId)
    {
        _modeTold.TryRemove(ghostId, out _);
        if (_hostModeKnown && ghostId == _hostModeFrom)
        {
            _hostModeKnown = false;
            if (_joinedWorld) await LeaveSharedWorldAsync("host-left", "Your host left the game.");
            else if (_jj is { Phase: "preparing" } j) await AbortJoinerJoinAsync(j, 0, "host-left", "Your host left the game.", sendAbort: false);
            else if (_jj is { Phase: "loading" } jl)
            {
                // Mid-load: the file goes now; the world that arrives is left at Gameplay started.
                Console.WriteLine($"MP-JOIN joiner: the host left during the load of join 0x{jl.JoinId:x8}");
                jl.Phase = "orphaned";
                _joinedSource ??= jl.Source;
                SetJoinedWorld(true);
                _ = Task.Run(async () =>
                {
                    if (jl.GameplayStarted is { } gs) await Task.WhenAny(gs.Task, Task.Delay(240000));
                    await RemovePlacedWorldAsync(jl, "host-left");
                    await LeaveSharedWorldAsync("host-left", "Your host left the game.");
                });
            }
        }
    }

    /// <summary>The host aborted a join this machine is running (its safety timeout, a reload, a cancel).</summary>
    private async Task<bool> Wo124OnHostAbortAsync(uint joinId, string reason)
    {
        if (_jj is not { } j || j.JoinId != joinId) return false;
        Console.WriteLine($"MP-JOIN joiner: the host aborted join 0x{joinId:x8} ({reason}) while it was {j.Phase}");
        switch (j.Phase)
        {
            case "preparing":
                await AbortJoinerJoinAsync(j, 0, reason, $"Your host stopped the join ({reason}).", sendAbort: false);
                break;
            case "loading":
                // The world arriving is no longer the host's: leave it once it is up.
                j.Phase = "orphaned";
                _joinedSource ??= j.Source;
                _ = Task.Run(async () =>
                {
                    if (j.GameplayStarted is { } gs) await Task.WhenAny(gs.Task, Task.Delay(240000));
                    SetJoinedWorld(true);
                    await RemovePlacedWorldAsync(j, "host-abort");
                    await LeaveSharedWorldAsync(reason, $"Your host stopped the join ({reason}).");
                });
                break;
            default:
                _joinReceivedId = 0;
                await LeaveSharedWorldAsync(reason, $"Your host stopped the join ({reason}).");
                break;
        }
        return true;
    }

    /// <summary>The game is quitting ("CSystem::Quit invoked").</summary>
    private void Wo124OnGameQuit()
    {
        bool wasShared = _joinedWorld;
        // WO-125: the next process starts at the main menu, so the menu gate holds world pushes from now
        // until a world loads. With Unknown here (WO-124) an agent kept running across a restart pushed a
        // ghost spawn into the new game at its menu and crashed it (observed). The join tick stays quiet
        // meanwhile: _gameQuitting blocks it until the next "main menu" line.
        _where = GameWhere.Menu;
        _gameQuitting = true;
        SetJoinedWorld(false);
        Wo125Sweep("game quit");
        if (!wasShared) return;
        // WO-125: true now -- the Henry for this world is the snapshot paired with the host's last save.
        var last = _joinedTag is string t ? _henry.Snapshots(t).FirstOrDefault() : null;
        Console.WriteLine($"MP-JOIN joiner: the game is quitting from the host's world -- its Henry for world {_joinedTag ?? "?"} is the last pair ({last?.Short ?? "none"})");
        SetJoinUi("notice", "Your progress in this world is saved up to your host's last save.");
    }
}
