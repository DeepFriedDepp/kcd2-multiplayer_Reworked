using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Text;

namespace KcdMp.Steam;

/// <summary>Why a session could not start, in the words the launcher shows.</summary>
public enum SteamStartFailure
{
    None,
    NoSteamDll,        // no KCD2 install found to borrow steam_api64.dll from
    SteamNotRunning,   // the Steam client isn't up
    NotLoggedOn,       // Steam is up but offline / logged out
    InitFailed,        // SteamAPI_InitFlat refused (usually: this account doesn't own the app id)
}

/// <summary>
/// One SteamAPI_InitFlat for this process, pumped by manual dispatch on a
/// dedicated thread.
///
/// Manual dispatch rather than SteamAPI_RunCallbacks so nothing depends on a
/// C++ callback object layout: each callback arrives as (id, bytes) and the
/// few this needs are decoded by offset. The pump also drains every open
/// connection's receive queue, so inbound bytes reach a reader within one
/// pump period (1 ms at timeBeginPeriod(1)).
///
/// The app id is chosen by the caller (SteamAppId in the environment, read
/// by steam_api when the DLL loads) -- WO-120 Phase 0 decides which.
/// </summary>
public sealed class SteamSession : IDisposable
{
    private static SteamSession? _current;

    private readonly IntPtr _user, _utils, _friends, _sockets, _netUtils, _messages, _legacy;
    private readonly int _pipe;
    private readonly Thread _pump;
    private volatile bool _running = true;
    private readonly ConcurrentDictionary<uint, SteamP2PConnection> _conns = new();
    private readonly ConcurrentDictionary<uint, SteamP2PListener> _listeners = new();

    public uint AppId { get; }
    public ulong LocalSteamId { get; }

    /// <summary>Raised on the pump thread for every callback id, for probes. Keep it quick.</summary>
    public event Action<int, byte[]>? RawCallback;

    /// <summary>A peer opened an ISteamNetworkingMessages session (probe only).</summary>
    public event Action<ulong>? MessagesSessionRequested;

    /// <summary>A peer opened a legacy ISteamNetworking P2P session (probe only).</summary>
    public event Action<ulong>? LegacySessionRequested;

    /// <summary>Anything the maintainer should see; never carries a SteamID or persona.</summary>
    public event Action<string>? Log;

    internal IntPtr Sockets => _sockets;
    internal IntPtr Messages => _messages;
    internal IntPtr Legacy => _legacy;
    internal IntPtr Friends => _friends;

    private SteamSession(uint appId)
    {
        _pipe = SteamNative.SteamAPI_GetHSteamPipe();
        SteamNative.SteamAPI_ManualDispatch_Init();
        _user = SteamNative.SteamAPI_SteamUser_v023();
        _utils = SteamNative.SteamAPI_SteamUtils_v010();
        _friends = SteamNative.SteamAPI_SteamFriends_v017();
        _sockets = SteamNative.SteamAPI_SteamNetworkingSockets_SteamAPI_v012();
        _netUtils = SteamNative.SteamAPI_SteamNetworkingUtils_SteamAPI_v004();
        _messages = SteamNative.SteamAPI_SteamNetworkingMessages_SteamAPI_v002();
        _legacy = SteamNative.SteamAPI_SteamNetworking_v006();
        AppId = SteamNative.SteamAPI_ISteamUtils_GetAppID(_utils);
        LocalSteamId = SteamNative.SteamAPI_ISteamUser_GetSteamID(_user);
        if (AppId != appId) EmitLog($"steam app id requested={appId} reported={AppId}");

        // SDR: start fetching the relay config and measuring pings now, so the
        // first connect doesn't pay for it.
        SteamNative.SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess(_netUtils);
        SteamNative.SteamAPI_ISteamNetworkingSockets_InitAuthentication(_sockets);

        _pump = new Thread(PumpLoop) { IsBackground = true, Name = "steam-pump" };
        _pump.Start();
    }

    /// <summary>
    /// Starts Steam for this process under <paramref name="appId"/>. At most
    /// one session per process (Steam's rule, not ours).
    /// </summary>
    public static SteamSession? TryStart(uint appId, out SteamStartFailure failure, out string detail, string? gameExePath = null)
    {
        detail = "";
        if (_current is not null) { failure = SteamStartFailure.None; return _current; }

        if (SteamLibraryLocator.Install(gameExePath) is null)
        {
            failure = SteamStartFailure.NoSteamDll;
            detail = "no steam_api64.dll found beside a KCD2 install";
            return null;
        }

        // steam_api reads these when it initialises; both, as Steam's own launch does.
        Environment.SetEnvironmentVariable("SteamAppId", appId.ToString());
        Environment.SetEnvironmentVariable("SteamGameId", appId.ToString());

        try
        {
            // WO-127 Phase 0: SteamAPI_IsSteamRunning only reads the
            // ActiveProcess registry pid, which the current Steam client leaves
            // at 0 while it is up and logged on (observed). InitFlat's own
            // answer is the authority; the registry reading is kept as detail.
            bool runningHint = SteamNative.SteamAPI_IsSteamRunning();
            var err = new byte[1024];
            int r = SteamNative.SteamAPI_InitFlat(err);
            if (r != 0)
            {
                failure = r == 2 ? SteamStartFailure.SteamNotRunning : SteamStartFailure.InitFailed;
                detail = $"SteamAPI_InitFlat={r} {CString(err)} IsSteamRunning={(runningHint ? 1 : 0)}";
                return null;
            }
            if (!runningHint) detail = "IsSteamRunning=0 (registry hint) but InitFlat=OK";
        }
        catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException)
        {
            failure = SteamStartFailure.NoSteamDll;
            detail = ex.GetType().Name + ": " + ex.Message;
            return null;
        }

        var s = new SteamSession(appId);
        if (!SteamNative.SteamAPI_ISteamUser_BLoggedOn(s._user))
        {
            failure = SteamStartFailure.NotLoggedOn;
            detail = "BLoggedOn=false";
            s.Dispose();
            return null;
        }
        failure = SteamStartFailure.None;
        _current = s;
        return s;
    }

    // --- relay network --------------------------------------------------------

    /// <summary>ESteamNetworkingAvailability of the relay network: 100 = current, 3 = attempting, negative = failed.</summary>
    public int RelayAvailability(out string debug)
    {
        var buf = new byte[4 * 4 + 256];
        int avail = SteamNative.SteamAPI_ISteamNetworkingUtils_GetRelayNetworkStatus(_netUtils, buf);
        debug = SteamLogScrub.Scrub(CString(buf.AsSpan(16)));
        return avail;
    }

    public int AuthenticationAvailability() =>
        SteamNative.SteamAPI_ISteamNetworkingSockets_GetAuthenticationStatus(_sockets, IntPtr.Zero);

    public static string AvailabilityName(int a) => a switch
    {
        100 => "current", 3 => "attempting", 2 => "waiting", 1 => "never-tried", 0 => "unknown",
        -10 => "retrying", -100 => "previously", -101 => "failed", -102 => "cannot-try", _ => a.ToString(),
    };

    /// <summary>Waits until the relay network and our certificate are usable, or the timeout passes.</summary>
    public async Task<bool> WaitNetworkReadyAsync(TimeSpan timeout, CancellationToken ct)
    {
        var until = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < until)
        {
            ct.ThrowIfCancellationRequested();
            if (RelayAvailability(out _) == 100 && AuthenticationAvailability() == 100) return true;
            await Task.Delay(100, ct);
        }
        return false;
    }

    // --- P2P sockets ------------------------------------------------------------

    public SteamP2PListener Listen(int virtualPort)
    {
        uint h = SteamNative.SteamAPI_ISteamNetworkingSockets_CreateListenSocketP2P(_sockets, virtualPort, 0, IntPtr.Zero);
        if (h == 0) throw new IOException($"CreateListenSocketP2P({virtualPort}) returned an invalid handle.");
        var l = new SteamP2PListener(this, h, virtualPort);
        _listeners[h] = l;
        return l;
    }

    public SteamP2PConnection Connect(ulong remoteSteamId, int virtualPort)
    {
        var id = SteamNative.Identity.FromSteamId(remoteSteamId);
        uint h = SteamNative.SteamAPI_ISteamNetworkingSockets_ConnectP2P(_sockets, ref id, virtualPort, 0, IntPtr.Zero);
        if (h == 0) throw new IOException("ConnectP2P returned an invalid handle.");
        var c = new SteamP2PConnection(this, h, remoteSteamId, incoming: false);
        _conns[h] = c;
        return c;
    }

    internal void Forget(SteamP2PConnection c) => _conns.TryRemove(c.Handle, out _);
    internal void Forget(SteamP2PListener l) => _listeners.TryRemove(l.Handle, out _);

    // --- rich presence ------------------------------------------------------------

    public bool SetRichPresence(string key, string? value) =>
        SteamNative.SteamAPI_ISteamFriends_SetRichPresence(_friends, key, value);

    public void ClearRichPresence() => SteamNative.SteamAPI_ISteamFriends_ClearRichPresence(_friends);

    /// <summary>Our own rich presence value for <paramref name="key"/> as Steam reports it (null when unset).</summary>
    public string? OwnRichPresence(string key)
    {
        var p = SteamNative.SteamAPI_ISteamFriends_GetFriendRichPresence(_friends, LocalSteamId, key);
        string? v = p == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(p);
        return string.IsNullOrEmpty(v) ? null : v;
    }

    /// <summary>
    /// Friends playing under the same app id right now, with one of their
    /// rich presence values. Returned in memory only; callers must not log
    /// the ids.
    /// </summary>
    public List<(ulong SteamId, string? Value)> FriendsInThisApp(string richPresenceKey)
    {
        var list = new List<(ulong, string?)>();
        int n = SteamNative.SteamAPI_ISteamFriends_GetFriendCount(_friends, SteamNative.FriendFlagImmediate);
        for (int i = 0; i < n; i++)
        {
            ulong f = SteamNative.SteamAPI_ISteamFriends_GetFriendByIndex(_friends, i, SteamNative.FriendFlagImmediate);
            if (!SteamNative.SteamAPI_ISteamFriends_GetFriendGamePlayed(_friends, f, out var g)) continue;
            if ((uint)(g.GameId & 0xFFFFFF) != AppId) continue;
            SteamNative.SteamAPI_ISteamFriends_RequestFriendRichPresence(_friends, f);
            var p = SteamNative.SteamAPI_ISteamFriends_GetFriendRichPresence(_friends, f, richPresenceKey);
            string? v = p == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(p);
            list.Add((f, string.IsNullOrEmpty(v) ? null : v));
        }
        return list;
    }

    /// <summary>
    /// WO-127: friends in this app whose <paramref name="richPresenceKey"/> is
    /// set, with their persona name, for the launcher's "pick a friend" list.
    /// In memory only: the name and id must never reach a log.
    /// </summary>
    public List<(ulong SteamId, string Persona, string Value)> FriendsWithPresence(string richPresenceKey)
    {
        var list = new List<(ulong, string, string)>();
        foreach (var (id, value) in FriendsInThisApp(richPresenceKey))
        {
            if (value is null) continue;
            var p = SteamNative.SteamAPI_ISteamFriends_GetFriendPersonaName(_friends, id);
            list.Add((id, p == IntPtr.Zero ? "" : Marshal.PtrToStringUTF8(p) ?? "", value));
        }
        return list;
    }

    public int FriendCount() => SteamNative.SteamAPI_ISteamFriends_GetFriendCount(_friends, SteamNative.FriendFlagImmediate);

    public bool InviteToGame(ulong friend, string connectString) =>
        SteamNative.SteamAPI_ISteamFriends_InviteUserToGame(_friends, friend, connectString);

    // --- pump -----------------------------------------------------------------------

    [DllImport("winmm.dll")] private static extern uint timeBeginPeriod(uint ms);
    [DllImport("winmm.dll")] private static extern uint timeEndPeriod(uint ms);

    private void PumpLoop()
    {
        if (OperatingSystem.IsWindows()) timeBeginPeriod(1);
        var msgs = new IntPtr[64];
        try
        {
            while (_running)
            {
                SteamNative.SteamAPI_ManualDispatch_RunFrame(_pipe);
                while (SteamNative.SteamAPI_ManualDispatch_GetNextCallback(_pipe, out var cb))
                {
                    try { Dispatch(cb); }
                    catch (Exception ex) { EmitLog($"steam callback {cb.ICallback} handler threw {ex.GetType().Name}: {ex.Message}"); }
                    finally { SteamNative.SteamAPI_ManualDispatch_FreeLastCallback(_pipe); }
                }
                foreach (var c in _conns.Values) c.Drain(msgs);
                Thread.Sleep(1);
            }
        }
        finally
        {
            if (OperatingSystem.IsWindows()) timeEndPeriod(1);
        }
    }

    private void Dispatch(SteamNative.CallbackMsg cb)
    {
        byte[] data = new byte[Math.Max(0, cb.CubParam)];
        if (cb.CubParam > 0) Marshal.Copy(cb.PubParam, data, 0, cb.CubParam);
        RawCallback?.Invoke(cb.ICallback, data);

        switch (cb.ICallback)
        {
            case SteamNative.CbConnectionStatusChanged:
                OnStatusChanged(data);
                break;
            case SteamNative.CbMessagesSessionRequest when data.Length >= 16:
                MessagesSessionRequested?.Invoke(BitConverter.ToUInt64(data, 8));
                break;
            case SteamNative.CbP2PSessionRequest when data.Length >= 8:
                LegacySessionRequested?.Invoke(BitConverter.ToUInt64(data, 0));
                break;
        }
    }

    private void OnStatusChanged(byte[] data)
    {
        if (data.Length != SteamNative.StatusChangedSize)
            EmitLog($"steam status-changed callback size={data.Length} expected={SteamNative.StatusChangedSize} (layout drift; reading by offset anyway)");
        if (data.Length < SteamNative.StatusChangedInfoOffset + SteamNative.ConnInfo.Size) return;

        uint h = BitConverter.ToUInt32(data, 0);
        var info = data.AsSpan(SteamNative.StatusChangedInfoOffset, SteamNative.ConnInfo.Size);
        uint listen = BitConverter.ToUInt32(info[SteamNative.ConnInfo.ListenSocket..]);
        int state = BitConverter.ToInt32(info[SteamNative.ConnInfo.State..]);
        int endReason = BitConverter.ToInt32(info[SteamNative.ConnInfo.EndReason..]);
        string endDebug = SteamLogScrub.Scrub(CString(info.Slice(SteamNative.ConnInfo.EndDebug, 128)));
        ulong remote = BitConverter.ToUInt64(info[8..]); // identity union, when type == SteamID

        if (!_conns.TryGetValue(h, out var conn))
        {
            if (state != SteamNative.StateConnecting || listen == 0 || !_listeners.TryGetValue(listen, out var l))
            {
                // Not ours (or already forgotten): release the handle.
                if (state is SteamNative.StateClosedByPeer or SteamNative.StateProblemDetectedLocally)
                    SteamNative.SteamAPI_ISteamNetworkingSockets_CloseConnection(_sockets, h, 0, null, false);
                return;
            }
            conn = new SteamP2PConnection(this, h, remote, incoming: true);
            _conns[h] = conn;
            if (!l.Offer(conn))
            {
                conn.Close("listener closed");
                return;
            }
        }
        conn.OnState(state, endReason, endDebug);
    }

    internal void EmitLog(string line) => Log?.Invoke(SteamLogScrub.Scrub(line));

    internal static string CString(ReadOnlySpan<byte> b)
    {
        int n = b.IndexOf((byte)0);
        return Encoding.UTF8.GetString(n < 0 ? b : b[..n]);
    }

    public void Dispose()
    {
        if (!_running) return;
        foreach (var c in _conns.Values) c.Close("shutdown");
        foreach (var l in _listeners.Values) l.Dispose();
        _running = false;
        if (Thread.CurrentThread != _pump) _pump.Join(2000);
        try { ClearRichPresence(); } catch { }
        SteamNative.SteamAPI_Shutdown();
        if (ReferenceEquals(_current, this)) _current = null;
    }
}
