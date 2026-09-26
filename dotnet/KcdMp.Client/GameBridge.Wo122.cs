using System.Collections.Concurrent;
using System.Globalization;
using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace KcdMp.Client;

/// <summary>
/// WO-122 -- shared-world foundations, the agent half (docs/WO-122-findings.md).
///
/// Phase 1 (ships ON, mp_owner_death): on the joiner, an NPC the owner streams
/// dead while this world's copy reads ALIVE is killed here, whatever the local
/// copy says and however it got alive again (a load). The mod reads the local
/// state and asks (npc_owner_dead, throttled); this file applies it through the
/// WO-86 route. One-way: nothing here ever revives anything.
///
/// Phases 2-4 (dormant: only with mp_shared_world on):
///   * joiner: the named script save lock kcdmp_host_only, held while connected
///     as the joiner, re-asserted after every load and read back every second;
///     released on disconnect so a solo game saves as before;
///   * host: an autosave every mp_autosave_minutes through the engine's own
///     queue (Game.SaveGameViaResting = EnqueueAutoSave, code-verified), and a
///     world save on demand that returns the file it wrote;
///   * host: every save the game writes (any type) is seen landing in the saves
///     folder, verified (WhsSave.Verify) and announced as WorldSaved (0x46).
///
/// Paths in log lines are written as playlineN/file.whs, never the absolute
/// path: the saves folder sits under the account's profile folder.
/// </summary>
public partial class GameBridge
{
    public const bool SharedWorldDefault = false;
    public const bool OwnerDeathDefault = true;
    public const int AutosaveMinutesDefault = 5;

    // ---- mirrors of the mod's WO-122 toggles (Lua emits wo122_cfg) ---------
    private volatile bool _sharedWorld = SharedWorldDefault;
    private volatile bool _ownerDeath = OwnerDeathDefault;
    private volatile int _autosaveMinutes = AutosaveMinutesDefault;

    private Stream? _wo122Stream;
    private CancellationToken _wo122Ct;
    private volatile bool _wo122Connected;
    private volatile bool _lockHeld;            // we asked the mod to hold kcdmp_host_only
    private volatile bool _lockSwept;           // this connection has cleared any lock an earlier agent left
    private int _lockAsserts;
    private DateTime _lastWorldSaveUtc = DateTime.MinValue;
    private uint _worldSavedSeq;
    private int _worldSaveBusy;
    private readonly object _saveWaitGate = new();
    private (DateTime Since, TaskCompletionSource<ObservedSave> Tcs)? _saveWaiter;

    private FileSystemWatcher? _savesWatcher;
    private string? _savesDir;
    private readonly ConcurrentDictionary<string, DateTime> _saveEventAt = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, byte> _saveSettling = new(StringComparer.OrdinalIgnoreCase);
    private string? _lastObservedMd5;

    /// <summary>A verified world save. FullPath stays on this machine (never logged); Seq is its WorldSaved seq once announced.</summary>
    private sealed record ObservedSave(string Display, byte Kind, byte Playline, ushort Idx, byte[] Md5, int Bytes, DateTime AtUtc, string FullPath, uint Seq = 0);

    // ------------------------------------------------------------------ lifecycle

    private void Wo122OnConnect(Stream stream, CancellationToken ct)
    {
        _wo122Stream = stream;
        _wo122Ct = ct;
        _wo122Connected = true;
        _lockSwept = false;
        _lastWorldSaveUtc = DateTime.UtcNow;   // the first scheduled save is N minutes into the session
        Wo122EnsureWatcher();
        // The mod emits wo122_cfg at its init and on every toggle; an agent that
        // starts (or restarts) later would keep its defaults. Ask for the current state.
        _ = ExecLuaAsync("if KCD2MP_Wo122CfgEmit then KCD2MP_Wo122CfgEmit() end");
        _ = Wo122LoopAsync(ct);
    }

    private async Task Wo122OnDisconnectAsync()
    {
        _wo122Connected = false;
        _wo122Stream = null;
        if (_lockHeld) await Wo122SetLockAsync(false, "disconnect");
    }

    private async Task Wo122LoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(1000, ct); } catch { return; }
            try
            {
                // Phase 2: the joiner's lock. Role unknown (no CombatRole yet) = do nothing:
                // a host must never lock its own saves for the first second of a session.
                bool want = Wo122WantLock();
                if (want) await Wo122SetLockAsync(true, "tick");
                else if (_lockHeld) await Wo122SetLockAsync(false, _sharedWorld ? "not-the-joiner" : "shared-world-off");
                else if (!_lockSwept && _combatRoleApplied)
                {
                    // An agent killed while it held the lock leaves it in the game until the
                    // next load. The first tick of a connection that is not a joiner clears it
                    // (the mod logs only if there was one to remove).
                    _lockSwept = true;
                    await ExecLuaAsync("if KCD2MP_HostOnlyLock then KCD2MP_HostOnlyLock(false, \"agent-start\") end");
                }
                if (want) _lockSwept = true;

                // Phase 3: the host's scheduled world save.
                if (_sharedWorld && _combatRoleApplied && _isDamageAuthority && _autosaveMinutes > 0
                    && (DateTime.UtcNow - _lastWorldSaveUtc).TotalMinutes >= _autosaveMinutes
                    && Volatile.Read(ref _worldSaveBusy) == 0
                    && !Wo123HostJoinActive)   // WO-123: never a scheduled save while a join holds the world
                {
                    _ = RequestWorldSaveAsync("schedule");
                }
            }
            catch (Exception ex) { Console.WriteLine($"MP-WO122 tick failed: {ex.Message}"); }
        }
    }

    // WO-124: the session mode is the host's (JoinerSharedEffective), and with a
    // host that announces it the lock is held only while this game's world IS
    // the host's (after a join). Without the announcement (an older host, the
    // WO-122 synthetic runs) it is held as WO-122 shipped it.
    private bool Wo122WantLock() => JoinerSharedEffective && _wo122Connected && _combatRoleApplied && !_isDamageAuthority
                                    && (!_hostModeKnown || _joinedWorld);

    private void Wo122OnGameplayStarted()
    {
        // Every load wipes every script lock (WO-112 s3.6, observed). Put it back
        // at once rather than on the next tick.
        if (Wo122WantLock())
        {
            Console.WriteLine("MP-SAVELOCK load finished (Gameplay started) -- re-asserting kcdmp_host_only now");
            _ = Wo122SetLockAsync(true, "after-load");
        }
    }

    private void Wo122OnAutoSaveRefused(string lockName)
    {
        if (lockName != "kcdmp_host_only") return;   // someone else's lock: not ours to explain
        Console.WriteLine("MP-SAVELOCK the engine refused an autosave on this joiner (kcdmp_host_only) -- telling the player");
        _ = ExecLuaAsync("if KCD2MP_SaveRefused then KCD2MP_SaveRefused(\"autosave\") end");
    }

    /// <summary>
    /// The mod adds (or removes) the lock and READS IT BACK: a second add of the
    /// same name must be refused by the engine, which is what "held" means. The
    /// mod logs MP-SAVELOCK on every change and on any failed read-back.
    /// </summary>
    private async Task Wo122SetLockAsync(bool on, string why)
    {
        if (on && !_lockHeld)
        {
            Interlocked.Increment(ref _lockAsserts);
            Console.WriteLine($"MP-SAVELOCK joiner: holding kcdmp_host_only (why={why}) -- only the host saves this world");
        }
        else if (!on && _lockHeld)
            Console.WriteLine($"MP-SAVELOCK releasing kcdmp_host_only (why={why}) -- this machine saves as before");
        _lockHeld = on;
        try { await ExecLuaAsync($"if KCD2MP_HostOnlyLock then KCD2MP_HostOnlyLock({(on ? "true" : "false")}, \"{why}\") end"); }
        catch (Exception ex) { Console.WriteLine($"MP-SAVELOCK could not reach the mod: {ex.Message}"); }
    }

    // ------------------------------------------------------------------ mod events

    /// <summary><c>wo122_cfg shared_world=off owner_death=on autosave_min=5</c>.</summary>
    private void Wo122OnCfgEvent(string? arg)
    {
        if (string.IsNullOrWhiteSpace(arg)) return;
        bool wasShared = _sharedWorld;
        foreach (var kv in arg.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            int eq = kv.IndexOf('=');
            if (eq <= 0) continue;
            string k = kv[..eq], v = kv[(eq + 1)..];
            switch (k)
            {
                case "shared_world": _sharedWorld = v == "on"; break;
                case "owner_death": _ownerDeath = v == "on"; break;
                case "autosave_min": if (int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out int m)) _autosaveMinutes = Math.Clamp(m, 0, 120); break;
            }
        }
        Console.WriteLine(FormattableString.Invariant(
            $"MP-WO122 cfg shared_world={On(_sharedWorld)} owner_death={On(_ownerDeath)} autosave_minutes={_autosaveMinutes} role={(!_combatRoleApplied ? "unknown" : _isDamageAuthority ? "host" : "joiner")} connected={On(_wo122Connected)}"));
        if (wasShared != _sharedWorld)
        {
            Wo124OnSharedWorldChanged();   // WO-124: tell the peers the new session mode
            Wo122EnsureWatcher();
            if (_sharedWorld) _lastWorldSaveUtc = DateTime.UtcNow;
        }
    }

    private void Wo122OnEvent(string name, string? arg)
    {
        switch (name)
        {
            case "npc_owner_dead":
            {
                // "<npc> <x> <y> <z> <owner>" -- the mod read this world's copy ALIVE
                // while the owner's stream says dead.
                var p = (arg ?? "").Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (p.Length < 1 || !NpcNamePattern.IsMatch(p[0]) || p[0].Length > Protocol.MaxNpcNameLen)
                {
                    Console.WriteLine($"MP-OWNERDEATH malformed request '{arg}'");
                    return;
                }
                string npc = p[0];
                byte owner = p.Length > 4 && byte.TryParse(p[4], out var o) ? o : (byte)0xFF;
                string refused = !_ownerDeath ? "mp_owner_death off"
                               : !_npcDeathSyncEnabled ? "mp_npc_deathsync off"
                               : !_wo122Connected ? "no session"
                               : _combatRoleApplied && _isDamageAuthority ? "this machine is the host (its own world is the truth)"
                               : "";
                if (refused != "")
                {
                    Console.WriteLine($"MP-OWNERDEATH npc={npc} owner={owner} not applied: {refused}");
                    return;
                }
                Console.WriteLine($"MP-OWNERDEATH npc={npc} owner={owner} local=alive stream=dead -> applying the owner's death");
                _ = ApplyRemoteNpcDeathAsync(npc, null, owner, "owner-death (local copy alive)", _wo122Ct, bypassDedupe: true);
                return;
            }
            case "world_save_request":
                _ = RequestWorldSaveAsync(string.IsNullOrWhiteSpace(arg) ? "manual" : arg.Trim());
                return;
        }
    }

    // ------------------------------------------------------------------ Phase 3/4: the host's world saves

    /// <summary>
    /// WO-122 Phase 4 (and the Phase 3 schedule): ask the engine for a save of
    /// the host's world and wait for the file. The engine picks the moment
    /// (EnqueueAutoSave fires when CanSave passes: not mid-cutscene, skip or
    /// death); the request is repeated every 5 s for up to a minute in case
    /// the engine discarded it. Returns the verified file, or null.
    /// </summary>
    private async Task<string?> RequestWorldSaveAsync(string why) => (await RequestWorldSaveCoreAsync(why))?.Display;

    /// <summary>The request itself; WO-123's join takes the file (path, md5, WorldSaved seq) from here.</summary>
    private async Task<ObservedSave?> RequestWorldSaveCoreAsync(string why)
    {
        if (!_sharedWorld || !_combatRoleApplied || !_isDamageAuthority)
        {
            string cause = !_sharedWorld ? "mp_shared_world off" : !_combatRoleApplied ? "role unknown (no session)" : "this machine is not the host";
            Console.WriteLine($"MP-WORLDSAVE request why={why} refused: {cause}");
            _ = ExecLuaAsync($"if KCD2MP_WorldSaveDone then KCD2MP_WorldSaveDone(false, \"\", \"{why}\", 0, 0, \"{cause}\") end");
            return null;
        }
        if (Interlocked.CompareExchange(ref _worldSaveBusy, 1, 0) != 0)
        {
            Console.WriteLine($"MP-WORLDSAVE request why={why} skipped: a request is already waiting for its file");
            return null;
        }
        var t0 = DateTime.UtcNow;
        var tcs = new TaskCompletionSource<ObservedSave>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_saveWaitGate) _saveWaiter = (t0.AddSeconds(-1), tcs);
        try
        {
            Wo122EnsureWatcher();
            for (int attempt = 1; attempt <= 12; attempt++)
            {
                await ExecLuaAsync($"if KCD2MP_HostWorldSave then KCD2MP_HostWorldSave(\"{why}\", {attempt}) end");
                var done = await Task.WhenAny(tcs.Task, Task.Delay(5000));
                if (done == tcs.Task)
                {
                    var s = tcs.Task.Result;
                    double ms = (s.AtUtc - t0).TotalMilliseconds;
                    Console.WriteLine(FormattableString.Invariant(
                        $"MP-WORLDSAVE done why={why} file={s.Display} attempts={attempt} request_to_verified_ms={ms:F0} bytes={s.Bytes} md5={Convert.ToHexString(s.Md5).ToLowerInvariant()} verify=ok"));
                    _ = ExecLuaAsync(FormattableString.Invariant(
                        $"if KCD2MP_WorldSaveDone then KCD2MP_WorldSaveDone(true, \"{s.Display}\", \"{why}\", {attempt}, {ms:F0}, \"ok\") end"));
                    return s;
                }
                Console.WriteLine($"MP-WORLDSAVE why={why} attempt={attempt}: no verified file 5 s after the request -- asking again (the engine may be unable to save right now)");
            }
            Console.WriteLine($"MP-WORLDSAVE why={why} gave up after 12 requests over 60 s");
            _ = ExecLuaAsync($"if KCD2MP_WorldSaveDone then KCD2MP_WorldSaveDone(false, \"\", \"{why}\", 12, 60000, \"no file\") end");
            return null;
        }
        finally
        {
            lock (_saveWaitGate) _saveWaiter = null;
            _lastWorldSaveUtc = DateTime.UtcNow;   // a failed request waits a full period too, rather than retrying every second
            Volatile.Write(ref _worldSaveBusy, 0);
        }
    }

    // ------------------------------------------------------------------ the saves folder

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHGetKnownFolderPath([MarshalAs(UnmanagedType.LPStruct)] Guid rfid, uint flags, IntPtr token, out IntPtr path);
    private static readonly Guid FolderIdSavedGames = new("4C5C32FF-BB9D-43b0-B5B4-2D72E54EAAA4");

    /// <summary>&lt;Saved Games&gt;\KingdomCome2\saves (the engine's "User folder" + saves), or null.</summary>
    internal static string? ResolveSavesDir()
    {
        string? root = null;
        try
        {
            if (SHGetKnownFolderPath(FolderIdSavedGames, 0, IntPtr.Zero, out var p) == 0)
            {
                root = Marshal.PtrToStringUni(p);
                Marshal.FreeCoTaskMem(p);
            }
        }
        catch { }
        root ??= Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Saved Games");
        string dir = Path.Combine(root, "KingdomCome2", "saves");
        return Directory.Exists(dir) ? dir : null;
    }

    /// <summary>playline1/autosave042.whs -- never the absolute path.</summary>
    public static string SaveDisplay(string path) =>
        $"{Path.GetFileName(Path.GetDirectoryName(path))}/{Path.GetFileName(path)}";

    /// <summary>The watcher runs only while mp_shared_world is on: dormant means nothing new happens.</summary>
    private void Wo122EnsureWatcher()
    {
        // WO-124: a joiner in its host's world watches too (its own toggle may be off).
        if (!_sharedWorld && !_joinedWorld)
        {
            if (_savesWatcher is not null)
            {
                _savesWatcher.EnableRaisingEvents = false;
                _savesWatcher.Dispose();
                _savesWatcher = null;
                Console.WriteLine("MP-WORLDSAVE saves-folder watch stopped (mp_shared_world off)");
            }
            return;
        }
        if (_savesWatcher is not null) return;
        _savesDir ??= ResolveSavesDir();
        if (_savesDir is null)
        {
            Console.WriteLine("MP-WORLDSAVE no saves folder found (<Saved Games>/KingdomCome2/saves) -- world saves cannot be seen");
            return;
        }
        try
        {
            var w = new FileSystemWatcher(_savesDir, "*.whs")
            {
                IncludeSubdirectories = true,
                NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size,
                InternalBufferSize = 64 * 1024,
            };
            w.Created += (_, e) => OnSaveFileEvent(e.FullPath);
            w.Changed += (_, e) => OnSaveFileEvent(e.FullPath);
            w.Renamed += (_, e) => OnSaveFileEvent(e.FullPath);
            w.EnableRaisingEvents = true;
            _savesWatcher = w;
            Console.WriteLine("MP-WORLDSAVE watching <saves> for world saves (mp_shared_world on)");
        }
        catch (Exception ex) { Console.WriteLine($"MP-WORLDSAVE could not watch the saves folder: {ex.Message}"); }
    }

    private void OnSaveFileEvent(string path)
    {
        if (WorldSaved.ParsePath(path) is null) return;   // not an engine-named save (e.g. a transient mpworld file)
        _saveEventAt[path] = DateTime.UtcNow;
        if (_saveSettling.TryAdd(path, 0)) _ = SettleSaveAsync(path);
    }

    /// <summary>Wait for the writer to finish (no event for 600 ms), then verify; the game writes a save in well under a second.</summary>
    private async Task SettleSaveAsync(string path)
    {
        try
        {
            string display = SaveDisplay(path);
            WhsSave.VerifyResult? last = null;
            for (int i = 0; i < 40; i++)
            {
                await Task.Delay(500);
                if (_saveEventAt.TryGetValue(path, out var at) && (DateTime.UtcNow - at).TotalMilliseconds < 600) continue;
                last = WhsSave.VerifyFile(path);
                if (last.Ok) break;
            }
            if (last is null || !last.Ok)
            {
                Console.WriteLine($"MP-WORLDSAVE {display} did not verify within 20 s: {last?.Reason ?? "still being written"}");
                return;
            }
            var id = WorldSaved.ParsePath(path)!.Value;
            var md5 = Convert.FromHexString(last.Md5);
            if (_lastObservedMd5 == last.Md5) return;   // the same file seen again (Changed fires more than once)
            _lastObservedMd5 = last.Md5;
            int bytes = (int)new FileInfo(path).Length;
            var obs = new ObservedSave(display, id.Kind, id.Playline, id.Idx, md5, bytes, DateTime.UtcNow, path);
            await OnWorldSaveObservedAsync(obs);
        }
        catch (Exception ex) { Console.WriteLine($"MP-WORLDSAVE settle failed for {SaveDisplay(path)}: {ex.Message}"); }
        finally { _saveSettling.TryRemove(path, out _); }
    }

    private async Task OnWorldSaveObservedAsync(ObservedSave s)
    {
        string kind = Protocol.SaveKindName(s.Kind);
        if (_combatRoleApplied && _wo122Connected && !_isDamageAuthority)
        {
            // WO-125: the snapshot's own QuickSave, or a leak moved out at once.
            if (Wo125OnJoinerSaveObserved(s.FullPath, Convert.ToHexString(s.Md5).ToLowerInvariant())) return;
            // The lock should make this impossible on the joiner (QuickSave passes a
            // script lock, and nothing in the mod calls it). Loud, for the next WO.
            Console.WriteLine($"MP-SAVELOCK LEAK a {kind} was written on this joiner: {s.Display} (lock held={On(_lockHeld)})");
            await ExecLuaAsync($"if KCD2MP_SaveLeak then KCD2MP_SaveLeak(\"{s.Display}\") end");
            return;
        }
        if (!(_combatRoleApplied && _isDamageAuthority && _wo122Stream is Stream stream))
        {
            Console.WriteLine($"MP-WORLDSAVE observed {s.Display} ({kind}, {s.Bytes} B, verify ok) -- no session as the host, not announced");
            return;
        }
        _lastWorldSaveUtc = s.AtUtc;
        var ws = new WorldSaved(++_worldSavedSeq, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), s.Kind, s.Playline, s.Idx, s.Md5);
        var body = ws.Encode();
        var pkt = new byte[3 + body.Length];
        pkt[0] = Protocol.WorldSavedUp;
        System.Buffers.Binary.BinaryPrimitives.WriteUInt16LittleEndian(pkt.AsSpan(1), (ushort)body.Length);
        body.CopyTo(pkt, 3);
        try
        {
            await WritePacketAsync(stream, pkt, _wo122Ct);
            int gen = (_transport as LogTailGameTransport)?.LastSaveGenerationMs ?? 0;
            Console.WriteLine($"MP-WORLDSAVE saved {s.Display} ({kind}, {s.Bytes} B, verify ok, engine generation_ms={gen}) -> WorldSaved seq={ws.Seq} md5={Convert.ToHexString(s.Md5)[..8].ToLowerInvariant()}");
        }
        catch (Exception ex) { Console.WriteLine($"MP-WORLDSAVE WorldSaved not sent for {s.Display}: {ex.Message}"); }
        Wo125HostIdentify(s.FullPath, loaded: false, "saved");   // WO-125: the world's identity and the branch, before a join takes the file
        lock (_saveWaitGate)
        {
            if (_saveWaiter is { } w && s.AtUtc >= w.Since) w.Tcs.TrySetResult(s with { Seq = ws.Seq });
        }
    }

    /// <summary>WorldSavedDown (0x47): logged on the receiver (the Henry-snapshot WO pairs with it).</summary>
    private async Task OnWorldSavedInAsync(byte[] payload)
    {
        var ws = WorldSaved.TryDecode(payload, down: true, out byte src);
        if (ws is not WorldSaved w) return;
        if (w.IsBranchEntry) { Wo125OnBranchEntry(w); return; }   // WO-125: the host's branch, replayed before an offer
        _ = Wo125OnHostWorldSavedAsync(w, src);                    // WO-125: a joiner in the world snapshots its Henry
        long age = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - w.SenderUnixMs;
        string md5 = Convert.ToHexString(w.Md5).ToLowerInvariant();
        Console.WriteLine(FormattableString.Invariant(
            $"MP-WORLDSAVED in: host ghost {src} saved playline{w.Playline}/{w.FileName} seq={w.Seq} md5={md5[..8]} sender_ms={w.SenderUnixMs} age_ms={age} (clock skew not removed)"));
        await ExecLuaAsync(FormattableString.Invariant(
            $"if KCD2MP_WorldSavedIn then KCD2MP_WorldSavedIn({src}, {w.Seq}, \"playline{w.Playline}/{w.FileName}\", \"{md5}\", {age}) end"));
    }
}
