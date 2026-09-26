using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using KcdMp.Wire;

namespace KcdMp.Client;

/// <summary>
/// WO-125 -- continuity: the joiner's Henry belongs to a world, not to the
/// player (docs/WO-125-findings.md). Dormant: nothing here runs unless the
/// HOST runs a shared world.
///
/// Host:
///   * knows its world: the playthrough seed and whether its player is Henry,
///     read from the save it loaded (from the menu or in a world) and from
///     every world save it writes; unknown at an agent start -> one world save
///     identifies it;
///   * announces both in the session status (JoinStatus state 8: the seed in
///     the joinId slot, flags in arg) and refuses a join in a non-Henry world
///     without pausing;
///   * tracks its BRANCH (each save's parent is the save before it; a load
///     makes the loaded save the head; persisted in &lt;data&gt;/host-branch.json)
///     and replays it right before every WorldOffer (WorldSaved, kind bit 0x80);
///   * tells every peer when it starts a load (JoinStatus state 9).
/// Joiner:
///   * Henry files per world (<see cref="HenryStore"/>, keyed by the seed's tag);
///   * a first join asks "bring my character" / "start fresh" (the launcher,
///     or mp_join_henry auto|fresh|playlineN/file) before any request, so the
///     host is never paused while someone decides; later joins restore the
///     snapshot paired with the newest save of the host's branch;
///   * every host world save while joined -> a QuickSave of this game's copy
///     (the one save type that passes the joiner's lock, WO-124 s9.1) -> the
///     Henry block is stored, paired with the host save's md5 -> the QuickSave
///     is moved out of the playline at once and the list rescanned;
///   * a host reload takes the joiner along (an in-world rejoin); a save with
///     the host world's seed is never "own" (Henry source, leave route,
///     Continue check); with no own save to go back to, a listed file with no
///     world in it fails its load and the engine returns to the main menu.
/// Save names in logs: playlineN/file. The seed is never logged: only its tag.
/// </summary>
public partial class GameBridge
{
    private readonly HenryStore _henry = new(HenryStore.DefaultRoot(), HenryStore.ClockFromEnv);

    // ---------------------------------------------------------------- host: its world

    private uint? _hostWorldSeed;
    private bool? _hostWorldHenry;
    private string _hostWorldPlayer = "?";
    private DateTime _identifyAskedUtc = DateTime.MinValue;
    private volatile bool _hostLoadAnnounced;
    private string? _branchHead;
    private readonly object _branchGate = new();

    private sealed class BranchNode
    {
        public string? Parent { get; set; }
        public string Tag { get; set; } = "";
        public string Name { get; set; } = "";
        public DateTime AtUtc { get; set; }
    }

    private Dictionary<string, BranchNode>? _branchMap;
    private string BranchPath => Path.Combine(Path.GetDirectoryName(HenryStore.DefaultRoot())!, "host-branch.json");

    private Dictionary<string, BranchNode> BranchMap()
    {
        if (_branchMap is not null) return _branchMap;
        try
        {
            if (File.Exists(BranchPath) && JsonSerializer.Deserialize<Dictionary<string, BranchNode>>(File.ReadAllText(BranchPath)) is { } m)
                return _branchMap = m;
        }
        catch (Exception ex) when (ex is IOException or JsonException) { Console.WriteLine($"MP-HENRY host: host-branch.json unreadable ({ex.Message}) -- starting a new branch map"); }
        return _branchMap = new Dictionary<string, BranchNode>(StringComparer.Ordinal);
    }

    private void SaveBranchMap()
    {
        var m = BranchMap();
        if (m.Count > 2000)
            foreach (var k in m.OrderBy(kv => kv.Value.AtUtc).Take(m.Count - 2000).Select(kv => kv.Key).ToList()) m.Remove(k);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(BranchPath)!);
            File.WriteAllText(BranchPath + ".part", JsonSerializer.Serialize(m));
            File.Move(BranchPath + ".part", BranchPath, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { Console.WriteLine($"MP-HENRY host: host-branch.json not written: {ex.Message}"); }
    }

    /// <summary>The host's current branch, newest first (the head and its parents), at most <paramref name="max"/>.</summary>
    internal List<string> BranchNewestFirst(int max = 64)
    {
        lock (_branchGate)
        {
            var o = new List<string>();
            var m = BranchMap();
            var cur = _branchHead;
            while (cur is not null && o.Count < max && !o.Contains(cur))
            {
                o.Add(cur);
                cur = m.TryGetValue(cur, out var n) ? n.Parent : null;
            }
            return o;
        }
    }

    /// <summary>
    /// Read the host world's identity from a save it loaded (<paramref name="loaded"/>) or wrote.
    /// A write becomes the new head with the old head as its parent; a load makes the loaded save the head.
    /// </summary>
    private void Wo125HostIdentify(string path, bool loaded, string why)
    {
        try
        {
            var bytes = WhsSave.ReadShared(path);
            var v = WhsSave.Verify(bytes);
            if (!v.Ok) { Console.WriteLine($"MP-HENRY host: {SaveDisplay(path)} does not verify ({v.Reason}) -- world identity unchanged"); return; }
            var raw = WhsSave.Inflate(bytes).Raw;
            uint? seed = WhsSave.ReadSeed(raw);
            var who = WhsSave.PlayerOf(raw);
            string md5 = v.Md5.ToLowerInvariant();
            bool changed = seed != _hostWorldSeed || who.IsHenry != _hostWorldHenry;
            _hostWorldSeed = seed;
            _hostWorldHenry = who.IsHenry;
            _hostWorldPlayer = who.Player;
            string tag = seed is uint s ? WhsSave.SeedTag(s) : "-";
            lock (_branchGate)
            {
                var m = BranchMap();
                if (loaded)
                {
                    if (!m.ContainsKey(md5)) m[md5] = new BranchNode { Parent = null, Tag = tag, Name = SaveDisplay(path), AtUtc = DateTime.UtcNow };
                }
                else if (!m.ContainsKey(md5))
                    m[md5] = new BranchNode { Parent = _branchHead, Tag = tag, Name = SaveDisplay(path), AtUtc = DateTime.UtcNow };
                _branchHead = md5;
                SaveBranchMap();
            }
            Console.WriteLine($"MP-HENRY host: world {tag} ({why}: {SaveDisplay(path)}, md5 {md5[..8]} = the save's footer MD5) player={who.Player} henry={On(who.IsHenry)} branch_depth={BranchNewestFirst().Count}");
            if (changed)
            {
                _modeTold.Clear();   // the session status carries the identity: resend at the next tick
                if (_hostWorldHenry == false && _sharedWorld)
                {
                    const string msg = "Co-op: you are in a part of the story your partner can't join yet.";
                    Console.WriteLine($"MP-HENRY host: this world's player is not Henry ({who.Player}) -- no join now; joiners are told");
                    _ = ExecLuaAsync($"if KCD2MP_Wo124Msg then KCD2MP_Wo124Msg(\"{EscapeLua(msg)}\") end");
                }
            }
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException)
        {
            Console.WriteLine($"MP-HENRY host: could not read {SaveDisplay(path)}: {ex.Message}");
        }
    }

    /// <summary>The session status's joinId + flags: the seed and whether the host's player is Henry.</summary>
    private (uint Seed, ushort Flags) Wo125SessionIdentity()
    {
        if (_hostWorldSeed is not uint s) return (0, 0);
        return (s, (ushort)(Protocol.SessionSeedKnown | (_hostWorldHenry == true ? Protocol.SessionHenryWorld : 0)));
    }

    /// <summary>Host tick: an unknown world (agent started mid-world) is identified by one world save, once a minute at most, only with a peer present.</summary>
    private void Wo125HostTick()
    {
        if (!_sharedWorld || _hostWorldSeed is not null || _where == GameWhere.Menu) return;
        if (_peerLastSeenUtc.IsEmpty && _ghostNames.IsEmpty) return;
        if ((DateTime.UtcNow - _identifyAskedUtc).TotalSeconds < 60 || Volatile.Read(ref _worldSaveBusy) != 0 || Wo123HostJoinActive) return;
        _identifyAskedUtc = DateTime.UtcNow;
        Console.WriteLine("MP-HENRY host: this world's seed is not known yet (no load or save seen since the agent started) -- one world save identifies it");
        _ = RequestWorldSaveAsync("identify");
    }

    /// <summary>"Loading saved game '...'" on the host: its world is about to change.</summary>
    private void Wo125HostOnLoadAccepted(string display)
    {
        if (!(_combatRoleApplied && _isDamageAuthority && _sharedWorld && _modeEverShared)) return;
        if (ResolveSavesDirForJoin() is string saves)
        {
            var m = Regex.Match(display, @"^playline([0-4])/([A-Za-z0-9_]+\.whs)$", RegexOptions.IgnoreCase);
            if (m.Success) Wo125HostIdentify(Path.Combine(saves, $"playline{m.Groups[1].Value}", m.Groups[2].Value), loaded: true, "loaded");
        }
        _hostLoadAnnounced = true;
        var peers = _peerLastSeenUtc.Keys.Concat(_ghostNames.Keys).Distinct().ToList();
        foreach (byte g in peers)
            _ = WriteJoinAsync(JoinStatusCodec.Build(g, 0, Protocol.JoinStateReloading, Protocol.JoinReasonId("reloading"), 0)).ContinueWith(_ => { });
        Console.WriteLine($"MP-HENRY host: a save load started ({display}) -- {peers.Count} peer(s) told 'your host is reloading'");
    }

    private void Wo125HostOnGameplayStarted()
    {
        if (!_hostLoadAnnounced) return;
        _hostLoadAnnounced = false;
        _modeTold.Clear();   // announce the (possibly new) world at the next tick: a joiner in it rejoins
    }

    /// <summary>Right before a WorldOffer: the branch, oldest first, as WorldSaved entries with the branch bit.</summary>
    private async Task Wo125SendBranchReplayAsync(uint joinId)
    {
        var br = BranchNewestFirst();
        br.Reverse();
        if (br.Count == 0 || _wo122Stream is not System.Net.Sockets.NetworkStream stream) { Console.WriteLine($"MP-HENRY host: join 0x{joinId:x8}: no branch to replay"); return; }
        var m = BranchMap();
        for (int i = 0; i < br.Count; i++)
        {
            byte kind = Protocol.SaveKindBranchFlag;
            byte pl = 0; ushort idx = 0;
            if (m.TryGetValue(br[i], out var n) && WorldSaved.ParsePath(n.Name.Replace('/', Path.DirectorySeparatorChar)) is { } id) { kind |= id.Kind; pl = id.Playline; idx = id.Idx; }
            var ws = new WorldSaved((uint)br.Count, i, kind, pl, idx, Convert.FromHexString(br[i]));
            var body = ws.Encode();
            var pkt = new byte[3 + body.Length];
            pkt[0] = Protocol.WorldSavedUp;
            BinaryPrimitives.WriteUInt16LittleEndian(pkt.AsSpan(1), (ushort)body.Length);
            body.CopyTo(pkt, 3);
            await WritePacketAsync(stream, pkt, _wo122Ct);
        }
        Console.WriteLine($"MP-HENRY host: join 0x{joinId:x8}: branch replayed ({br.Count} save(s), newest md5 {br[^1][..8]})");
    }

    // ---------------------------------------------------------------- joiner: what the host said

    private volatile bool _peerSeedKnown;
    private uint _peerSeed;
    private volatile bool _peerHenryWorld;
    private string? _peerTag;
    private readonly List<string> _hostBranch = [];            // newest first, from the last complete replay
    private string?[] _branchRx = [];
    private string? _firstChoice;                               // bring | fresh | playlineN/file, for _firstChoiceTag
    private string? _firstChoiceTag;
    private bool _chooseAsked, _notHenryTold;
    private volatile bool _rewinding;                          // the host is reloading: nothing gained now is kept
    private volatile bool _rejoinPending;                      // the host is back: rejoin from inside the world
    private DateTime _rejoinSinceUtc;
    private volatile bool _joinFromWorldOnce;                  // after leaving for a host's new world: join from the own world once
    private volatile bool _leaveInProgress;                    // a leave's own load (or the way to the menu) is running: no request
    private volatile bool _newWorldLeavePending;               // the host changed worlds while a join ran: leave when it ends
    private DateTime _leaveSinceUtc;
    private string? _joinedTag;                                // the world this game is in (while joined)
    private string? _resetTag;                                 // mp_henry_reset while in it: no snapshot for it until the next join
    private byte[]? _joinReceivedMd5;
    private byte[]? _lastWorldDesc;                             // the last received world's header, for the no-own-save way out
    private int _lastWorldPlayline = -1;

    /// <summary>The session status's identity (WO-124 hosts send joinId 0 and no flags).</summary>
    private void Wo125OnSessionIdentity(uint seed, ushort flags)
    {
        bool known = (flags & Protocol.SessionSeedKnown) != 0;
        bool henry = (flags & Protocol.SessionHenryWorld) != 0;
        string? tag = known ? WhsSave.SeedTag(seed) : null;
        bool changed = known != _peerSeedKnown || (known && seed != _peerSeed) || henry != _peerHenryWorld;
        _peerSeedKnown = known;
        _peerSeed = seed;
        _peerHenryWorld = henry;
        _peerTag = tag;
        if (changed)
        {
            Console.WriteLine(known
                ? $"MP-HENRY joiner: the host's world is {tag} (player {(henry ? "Henry" : "NOT Henry")}); Henry files for it here: {(_henry.HasWorld(tag!) ? _henry.Snapshots(tag!).Count + " snapshot(s)" : "none (a first join)")}"
                : "MP-HENRY joiner: the host has not identified its world yet");
            _chooseAsked = _notHenryTold = false;
            if (_joinedWorld && known && !henry)
            {
                const string msg = "Your host is in a part of the story you can't share yet.";
                Console.WriteLine("MP-HENRY joiner: the host entered a stretch where its player is not Henry -- told; no further behaviour (quest sync, later)");
                _ = ExecLuaAsync($"if KCD2MP_Wo124Msg then KCD2MP_Wo124Msg(\"{EscapeLua(msg)}\") end");
            }
        }
        if (_rewinding && known)
        {
            // The host is back from its load.
            if (_joinedWorld && tag == _joinedTag)
            {
                if (!_rejoinPending) { _rejoinPending = true; _rejoinSinceUtc = DateTime.UtcNow; Console.WriteLine($"MP-HENRY joiner: the host reloaded world {tag} -- rejoining from inside the world (the Henry rewinds to the matching snapshot)"); }
            }
            else if (_joinedWorld)
            {
                _rewinding = false;
                _joinFromWorldOnce = true;
                if (_jj is not null)
                {
                    // Never two loads at once (observed: a leave fired mid-join raced the join's own load).
                    _newWorldLeavePending = true;
                    Console.WriteLine($"MP-HENRY joiner: the host loaded ANOTHER playthrough ({tag}, was {_joinedTag}) -- a join is still running; leaving once it ends");
                }
                else
                {
                    Console.WriteLine($"MP-HENRY joiner: the host loaded ANOTHER playthrough ({tag}, was {_joinedTag}) -- leaving this world first, then joining the new one");
                    _ = LeaveSharedWorldAsync("host-new-world", "Your host loaded a different game.");
                }
            }
        }
    }

    /// <summary>JoinStatus state 9: the host started a load.</summary>
    private void Wo125OnHostReloading()
    {
        if (!_joinedWorld) { Console.WriteLine("MP-HENRY joiner: the host is reloading (this game is not in its world)"); return; }
        if (_rewinding) return;
        _rewinding = true;
        _rejoinPending = false;
        const string msg = "Your host is reloading... what you do now won't be kept.";
        Console.WriteLine($"MP-HENRY joiner: the host started a load -- this game's progress from here on is NOT kept; it rewinds with the host");
        SetJoinUi("rewinding", "Your host is reloading...");
        _ = ExecLuaAsync($"if KCD2MP_Wo124Msg then KCD2MP_Wo124Msg(\"{EscapeLua(msg)}\") end");
    }

    /// <summary>A branch-replay entry (WorldSaved with the branch bit): position SenderUnixMs of Seq.</summary>
    private void Wo125OnBranchEntry(WorldSaved w)
    {
        int pos = (int)w.SenderUnixMs, n = (int)w.Seq;
        if (n <= 0 || n > 512 || pos < 0 || pos >= n) return;
        if (pos == 0 || _branchRx.Length != n) _branchRx = new string?[n];
        _branchRx[pos] = Convert.ToHexString(w.Md5).ToLowerInvariant();
        if (pos == n - 1 && _branchRx.All(x => x is not null))
        {
            lock (_hostBranch)
            {
                _hostBranch.Clear();
                _hostBranch.AddRange(_branchRx.Reverse()!);
            }
            Console.WriteLine($"MP-HENRY joiner: the host's branch: {n} save(s), newest md5 {_hostBranch[0][..8]}");
        }
    }

    // ---------------------------------------------------------------- joiner: the first-join choice

    private void Wo125OnLauncherChoice(string c)
    {
        c = (c ?? "").Trim().ToLowerInvariant();
        if (c is not ("bring" or "fresh")) { Console.WriteLine($"MP-HENRY joiner: the launcher sent an unknown choice '{c}' -- ignored"); return; }
        _firstChoice = c;
        _firstChoiceTag = _peerTag;
        _chooseAsked = false;
        Console.WriteLine($"MP-HENRY joiner: first join to world {_peerTag ?? "?"}: the player chose '{(c == "bring" ? "Bring my character" : "Start fresh")}' (launcher)");
        _autoNextUtc = DateTime.UtcNow;
    }

    /// <summary>mp_join_henry typed at the console: the same answer as the launcher's (auto = bring the newest own save).</summary>
    private void Wo125OnConsoleChoice(string v)
    {
        v = (v ?? "").Trim();
        _firstChoice = v == "auto" ? "bring" : v;
        _firstChoiceTag = _peerTag;
        _chooseAsked = false;
        Console.WriteLine($"MP-HENRY joiner: first-join answer '{_firstChoice}' (mp_join_henry) for world {_peerTag ?? "the next host world"}");
        _autoNextUtc = DateTime.UtcNow;
    }

    private string? CurrentChoice() => _firstChoice is not null && (_firstChoiceTag is null || _firstChoiceTag == _peerTag) ? _firstChoice : null;

    /// <summary>
    /// Whether a request may go out now (the host is never paused while
    /// someone decides). Tells the player why not, once.
    /// </summary>
    private bool Wo125ReadyToRequest(out string why)
    {
        why = "";
        if (!_peerSeedKnown) { why = "the host has not identified its world yet"; SetJoinUi("waiting", "Waiting for your host..."); return false; }
        if (!_peerHenryWorld)
        {
            why = "the host's player is not Henry";
            if (!_notHenryTold)
            {
                _notHenryTold = true;
                const string msg = "Your host is in a part of the story where you can't join yet.";
                Console.WriteLine($"MP-HENRY joiner: no join asked -- {why} (world {_peerTag})");
                SetJoinUi("not-henry", msg);
            }
            return false;
        }
        if (_henry.HasWorld(_peerTag!)) return true;
        var choice = CurrentChoice();
        if (choice is null)
        {
            why = "a first join: waiting for the player's choice";
            if (!_chooseAsked)
            {
                _chooseAsked = true;
                Console.WriteLine($"MP-HENRY joiner: first join to world {_peerTag} -- asking the player: Bring my character / Start fresh (launcher; console: mp_join_henry auto|fresh|playlineN/file)");
                SetJoinUi("choose", "First time in this world: bring your character, or start fresh?");
            }
            return false;
        }
        var src = Wo125SourceFor(choice, out string swhy);
        if (src is null)
        {
            // The chosen source does not exist: nothing is asked of the host; the question is asked again.
            why = swhy;
            Console.WriteLine($"MP-HENRY joiner: no join asked -- '{choice}': {swhy} (asking again)");
            _firstChoice = null;
            _chooseAsked = true;
            SetJoinUi("choose", $"{swhy} Bring your character, or start fresh?");
            return false;
        }
        return true;
    }

    // ---------------------------------------------------------------- joiner: which saves are "own"

    public sealed record OwnSave(HenrySource Save, uint? Seed);

    /// <summary>
    /// Every engine-named save in playline0..4, newest SaveTime first, EXCEPT a
    /// save whose seed is <paramref name="hostSeed"/>: that is a copy of the
    /// host's world (e.g. copied in by hand under 0.28.x), never the player's
    /// own. Each skip is logged (a warning: the file is left where it is).
    /// </summary>
    public static List<OwnSave> OwnSaves(string saves, uint? hostSeed, Action<string>? log = null)
    {
        var o = new List<OwnSave>();
        var skipped = new List<string>();
        foreach (var s in ListOwnSaves(saves))
        {
            uint? seed = WhsSave.ReadSeedFromFile(s.FullPath);
            if (hostSeed is uint hs && seed == hs)
            {
                // Logged once per file per agent run: a tester with a whole host playline would otherwise see it on every lookup.
                if (Warned.TryAdd(s.FullPath, 0)) skipped.Add(s.Display);
                continue;
            }
            o.Add(new OwnSave(s, seed));
        }
        if (skipped.Count > 0)
            log?.Invoke($"MP-HENRY WARNING {skipped.Count} save(s) are copies of the host's world (same playthrough seed): never used as this player's own save, left where they are: {string.Join(", ", skipped.Take(6))}{(skipped.Count > 6 ? ", ..." : "")}");
        return o;
    }

    private static readonly ConcurrentDictionary<string, byte> Warned = new(StringComparer.OrdinalIgnoreCase);

    private uint? HostSeedForOwn() => _peerSeedKnown ? _peerSeed : null;

    private static bool TestNoOwnSave => Environment.GetEnvironmentVariable("KCDMP_TEST_NO_OWN_SAVE") == "1";

    /// <summary>The newest own save that verifies (the leave route's target), or null.</summary>
    private HenrySource? Wo125NewestOwn(out string why)
    {
        why = "";
        if (TestNoOwnSave) { why = "KCDMP_TEST_NO_OWN_SAVE=1 (test: no own save)"; Console.WriteLine("MP-HENRY TEST KCDMP_TEST_NO_OWN_SAVE=1 -- acting as if this player had no save of their own"); return null; }
        if (ResolveSavesDirForJoin() is not string saves) { why = "no saves folder"; return null; }
        foreach (var s in OwnSaves(saves, HostSeedForOwn(), l => Console.WriteLine(l)))
        {
            var v = WhsSave.VerifyFile(s.Save.FullPath);
            if (v.Ok) return s.Save;
            Console.WriteLine($"MP-HENRY skipping {s.Save.Display}: {v.Reason}");
        }
        why = "no save of this player's own (with a different playthrough than the host's)";
        return null;
    }

    /// <summary>
    /// The leave route's target: the newest own save the ENGINE can load -- rescanned and found in its
    /// cached list (a save that appeared after the game started is not in it, and wh_sys_LoadGame then
    /// silently loads nothing, WO-112 s3.5). No plugin answer: the newest own save, unchecked (logged).
    /// </summary>
    private async Task<(HenrySource? Save, string Why)> Wo125NewestOwnLoadableAsync()
    {
        if (TestNoOwnSave || ResolveSavesDirForJoin() is not string saves)
            return (Wo125NewestOwn(out string w0), w0);
        foreach (var s in OwnSaves(saves, HostSeedForOwn(), l => Console.WriteLine(l)))
        {
            var v = WhsSave.VerifyFile(s.Save.FullPath);
            if (!v.Ok) { Console.WriteLine($"MP-HENRY skipping {s.Save.Display}: {v.Reason}"); continue; }
            var r = await _combat.SaveListAsync(1, s.Save.Playline, s.Save.Base);
            if (r is null) { Console.WriteLine($"MP-HENRY leave target {s.Save.Display}: the plugin did not answer the rescan -- used unchecked"); return (s.Save, ""); }
            if (r.Listed) return (s.Save, "");
            Console.WriteLine($"MP-HENRY skipping {s.Save.Display} as the leave target: not in the engine's save list even after a rescan");
        }
        return (null, "no loadable save of this player's own (with a different playthrough than the host's)");
    }

    public sealed record HenryChoice(string Mode, WhsSave.HenryParts Parts, HenrySource? Save, string Detail);

    /// <summary>
    /// The source for a first join. bring = the newest own save whose player is
    /// Henry (Phase 7: a Godwin/prologue save is skipped); fresh = a new game's
    /// first Henry save on this machine (Phase 3); playlineN/file = that save,
    /// refused when it is a copy of the host's world or not a Henry save.
    /// </summary>
    private HenryChoice? Wo125SourceFor(string choice, out string why)
    {
        why = "";
        if (ResolveSavesDirForJoin() is not string saves) { why = "no saves folder"; return null; }
        uint? hostSeed = HostSeedForOwn();
        string? build = null;
        if (choice.StartsWith("playline", StringComparison.Ordinal))
        {
            var m = Regex.Match(choice, @"^playline([0-4])/([A-Za-z0-9_]+?)(\.whs)?$");
            if (!m.Success) { why = $"mp_join_henry '{choice}' is not playlineN/file"; return null; }
            string f = m.Groups[2].Value + ".whs", full = Path.Combine(saves, $"playline{m.Groups[1].Value}", f);
            if (!File.Exists(full)) { why = $"That save doesn't exist (playline{m.Groups[1].Value}/{f})."; return null; }
            if (hostSeed is uint hs && WhsSave.ReadSeedFromFile(full) == hs)
            {
                why = $"That save is a copy of your host's world, not your own character (playline{m.Groups[1].Value}/{f}).";
                Console.WriteLine($"MP-HENRY joiner: mp_join_henry playline{m.Groups[1].Value}/{f} REFUSED: it has the host world's playthrough seed");
                return null;
            }
            var src = new HenrySource(int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture), f, full, ReadSaveTime(full) ?? 0);
            return TryHenrySave(src, WhsSave.HenryParts.OriginSave, "bring", out why, requirePristine: false);
        }
        var own = OwnSaves(saves, hostSeed, l => Console.WriteLine(l));
        if (choice == "bring")
        {
            foreach (var s in own)
                if (TryHenrySave(s.Save, WhsSave.HenryParts.OriginSave, "bring", out string w, requirePristine: false, quiet: true) is { } c) return c;
                else Console.WriteLine($"MP-HENRY joiner: skipping {s.Save.Display} as the Henry source: {w}");
            why = own.Count == 0 ? NoOwnSaveMessage : "No save of your own with Henry in it yet.";
            return null;
        }
        if (choice == "fresh")
        {
            // A new game's first Henry save: quest saves first (a new game writes permanent002 right after the prologue).
            foreach (var s in own.OrderBy(x => x.Save.File.StartsWith("permanent", StringComparison.OrdinalIgnoreCase) ? 0 : 1).ThenBy(x => x.Save.SaveTime).Take(80))
                if (TryHenrySave(s.Save, WhsSave.HenryParts.OriginFreshSave, "fresh", out _, requirePristine: true, quiet: true) is { } c) return c;
            why = "Start fresh needs a new game's first save on this computer: start a new game once and play past the prologue (its first save after it is used, never your host's character).";
            return null;
        }
        why = $"unknown choice '{choice}'";
        _ = build;
        return null;
    }

    private HenryChoice? TryHenrySave(HenrySource s, string origin, string mode, out string why, bool requirePristine, bool quiet = false)
    {
        why = "";
        byte[] bytes;
        try { bytes = WhsSave.ReadShared(s.FullPath); }
        catch (IOException ex) { why = "unreadable: " + ex.Message; return null; }
        var v = WhsSave.Verify(bytes);
        if (!v.Ok) { why = v.Reason; return null; }
        var c = WhsSave.Inflate(bytes);
        var who = WhsSave.PlayerOf(c.Raw);
        if (!who.IsHenry) { why = $"its player is not Henry ({who.Player})"; if (!quiet) Console.WriteLine($"MP-HENRY joiner: {s.Display}: {why}"); return null; }
        if (requirePristine && !who.Pristine) { why = "not a new game's first Henry save"; return null; }
        var parts = WhsSave.PartsFromStream(c.Raw, WhsSave.DescriptionSummary(c.Desc).GetValueOrDefault("BuildInfo") ?? "", origin);
        return new HenryChoice(mode, parts, s, s.Display);
    }

    // ---------------------------------------------------------------- joiner: the Henry for a received world

    /// <summary>
    /// After the world arrived: check it is the world announced and a Henry
    /// world, then restore (a Henry file exists for it) or use the first-join
    /// choice. Null = abort with <paramref name="abortReason"/>.
    /// </summary>
    private HenryChoice? Wo125HenryForWorld(uint joinId, byte[] hostBytes, out string why, out byte abortReason, out string tag)
    {
        why = ""; abortReason = 0; tag = "";
        var c = WhsSave.Inflate(hostBytes);
        uint? seed = WhsSave.ReadSeed(c.Raw);
        var who = WhsSave.PlayerOf(c.Raw);
        _lastWorldDesc = c.DescBytes;
        if (seed is not uint s) { why = "the world has no playthrough seed"; abortReason = Protocol.JoinAbortSpliceFailed; return null; }
        tag = WhsSave.SeedTag(s);
        if (_peerSeedKnown && s != _peerSeed)
        {
            why = $"the world received ({tag}) is not the one the host announced ({_peerTag}) -- it changed; the next announcement decides";
            abortReason = Protocol.JoinAbortWorldChanged;
            return null;
        }
        if (!who.IsHenry) { why = $"the host's player in this world is not Henry ({who.Player})"; abortReason = Protocol.JoinAbortNotHenry; return null; }
        if (_henry.HasWorld(tag))
        {
            List<string> branch;
            lock (_hostBranch) branch = [.. _hostBranch];
            var pick = _henry.PickFor(tag, branch);
            if (pick is null) { why = $"world {tag}: no snapshot could be read (all broken)"; abortReason = Protocol.JoinAbortNoHenrySource; return null; }
            Console.WriteLine($"MP-HENRY joiner: join 0x{joinId:x8}: world {tag} -- RESTORE snapshot {pick.Snapshot.Short} ({pick.Snapshot.Source}): {pick.How}");
            return new HenryChoice("restore", pick.Parts, null, $"snapshot {pick.Snapshot.Short}");
        }
        var choice = CurrentChoice();
        if (choice is null) { why = $"a first join to world {tag} but no choice was made (bring / fresh)"; abortReason = Protocol.JoinAbortNoHenrySource; return null; }
        var src = Wo125SourceFor(choice, out string swhy);
        if (src is null) { why = swhy; abortReason = choice == "bring" ? Protocol.JoinAbortNoOwnSave : Protocol.JoinAbortNoHenrySource; return null; }
        Console.WriteLine($"MP-HENRY joiner: join 0x{joinId:x8}: world {tag} -- FIRST JOIN, {(src.Mode == "fresh" ? "Start fresh" : "Bring my character")}: the Henry comes from {src.Detail}{(src.Mode == "fresh" ? " (a new game's first Henry save; never the host's)" : "")}");
        return src;
    }

    /// <summary>After Ready: the join save pairs with the Henry just loaded (a matched pair: the joiner has not played in it yet).</summary>
    private void Wo125AfterReady(string tag, string mode, WhsSave.HenryParts parts, byte[]? offerMd5, uint seq)
    {
        _joinedTag = tag;
        _rewinding = false;
        _rejoinPending = false;
        if (_resetTag == tag) _resetTag = null;
        if (_newWorldLeavePending || (_peerSeedKnown && _peerTag != tag))
        {
            // The host moved to another playthrough while this join ran: the join save still pairs (the joiner
            // was in that world at it), then this game leaves for its own save and joins the new world.
            _newWorldLeavePending = false;
            _joinFromWorldOnce = true;
            Console.WriteLine($"MP-HENRY joiner: the host is in another playthrough now ({_peerTag}) -- leaving world {tag} after this join");
            _ = Task.Run(() => LeaveSharedWorldAsync("host-new-world", "Your host loaded a different game."));
        }
        if (offerMd5 is null) { Console.WriteLine("MP-HENRY joiner: the offer's md5 is unknown -- the join save is not paired"); return; }
        try
        {
            parts.Origin = WhsSave.HenryParts.OriginSnapshot;
            _henry.Store(tag, parts, Convert.ToHexString(offerMd5), mode == "restore" ? HenryStore.SourceJoin : mode, $"the join save (seq {seq})");
            _henry.MarkJoined(tag);
            if (_firstChoiceTag == tag || _firstChoiceTag is null) { _firstChoice = null; _firstChoiceTag = null; }
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException)
        {
            Console.WriteLine($"MP-HENRY joiner: the join save's pair was NOT stored: {ex.Message}");
        }
    }

    // ---------------------------------------------------------------- joiner: snapshots paired with host saves

    private int _snapBusy;
    private readonly object _snapGate = new();
    private (int Playline, DateTime Since, TaskCompletionSource<string> Tcs)? _snapWait;

    /// <summary>Guard: a playline near the engine's 100-quicksave rotation is never snapshotted into (the rotation could remove the player's oldest).</summary>
    public const int SnapshotQuicksaveGuard = 95;

    /// <summary>A host world save (not a branch entry) while this game is in the host's world.</summary>
    private async Task Wo125OnHostWorldSavedAsync(WorldSaved w, byte src)
    {
        string md5 = Convert.ToHexString(w.Md5).ToLowerInvariant();
        string skip = !_joinedWorld ? "" : _jj is not null ? "a join is running" : _rewinding ? "the host is reloading (nothing is kept until the rejoin)"
                    : _joinedTag is null ? "the world is not known" : _resetTag == _joinedTag ? "mp_henry_reset this session (a new choice next join)"
                    : !_peerHenryWorld ? "the host's player is not Henry" : _where != GameWhere.World ? "not in the world" : "";
        if (!_joinedWorld) return;   // not in the host's world: nothing to pair
        if (skip != "") { Console.WriteLine($"MP-HENRY joiner: host save seq={w.Seq} md5={md5[..8]}: no snapshot -- {skip}"); return; }
        if (Interlocked.CompareExchange(ref _snapBusy, 1, 0) != 0) { Console.WriteLine($"MP-HENRY joiner: host save seq={w.Seq}: no snapshot -- the previous one is still running"); return; }
        var tIn = DateTime.UtcNow;
        HenryStore.LedgerEntry? led = null;
        try
        {
            string? saves = ResolveSavesDirForJoin();
            int pl = _lastWorldPlayline;
            if (saves is null || pl < 0) { Console.WriteLine("MP-HENRY joiner: no snapshot -- the playline of this world is not known"); return; }
            string dir = Path.Combine(saves, $"playline{pl}");
            int qs = Directory.Exists(dir) ? Directory.EnumerateFiles(dir, "quicksave*.whs").Count() : 0;
            if (qs >= SnapshotQuicksaveGuard) { Console.WriteLine($"MP-HENRY joiner: no snapshot -- playline{pl} holds {qs} quicksaves (the engine rotates at 100; a snapshot could push out the player's oldest)"); return; }
            // Keep the engine's cached list in step with the disk first: a new quicksave is
            // named max(SaveId in the list)+1 (observed), so a stale list could name an existing file.
            await _combat.SaveListAsync(1, pl, "-");
            led = _henry.LedgerAdd(new HenryStore.LedgerEntry { Playline = pl, SinceUtc = DateTime.UtcNow.AddSeconds(-1), WorldTag = _joinedTag!, Kind = "snapshot" });
            var tcs = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
            lock (_snapGate) _snapWait = (pl, DateTime.UtcNow.AddSeconds(-1), tcs);
            var tReq = DateTime.UtcNow;
            string r = await AskModAsync("KCD2MP_Wo125Snapshot", 6000);
            if (!r.StartsWith("ok=true", StringComparison.Ordinal))
            {
                Console.WriteLine($"MP-HENRY joiner: host save seq={w.Seq} md5={md5[..8]}: the engine REFUSED the snapshot ({r}) -- no pair for it (its progress is kept up to the previous pair: loss, never duplication)");
                _henry.LedgerSet(led.Id, e => e.State = "done");
                return;
            }
            var done = await Task.WhenAny(tcs.Task, Task.Delay(20000));
            if (done != tcs.Task)
            {
                Console.WriteLine($"MP-HENRY joiner: host save seq={w.Seq}: no snapshot file within 20 s -- no pair (the ledger keeps it for the next sweep)");
                return;
            }
            string path = tcs.Task.Result;
            var tFile = DateTime.UtcNow;
            byte[] bytes = WhsSave.ReadShared(path);
            var v = WhsSave.Verify(bytes);
            _henry.LedgerSet(led.Id, e => { e.File = Path.GetFileName(path); e.Md5 = v.Md5; e.State = "written"; });
            string? storeWhy = null;
            if (!v.Ok) storeWhy = "the snapshot does not verify: " + v.Reason;
            WhsSave.HenryParts? parts = null;
            if (storeWhy is null)
            {
                var c = WhsSave.Inflate(bytes);
                uint? seed = WhsSave.ReadSeed(c.Raw);
                if (seed is not uint s || WhsSave.SeedTag(s) != _joinedTag) storeWhy = "the snapshot is not of the host's world (seed)";
                else if (!WhsSave.PlayerOf(c.Raw).IsHenry) storeWhy = "the snapshot's player is not Henry";
                else parts = WhsSave.PartsFromStream(c.Raw, WhsSave.DescriptionSummary(c.Desc).GetValueOrDefault("BuildInfo") ?? "", WhsSave.HenryParts.OriginSnapshot);
            }
            double lagS = (tReq - tIn).TotalSeconds;
            if (storeWhy is null && lagS > 3.0) storeWhy = $"the snapshot started {lagS:F1} s after the host's save arrived (over 3 s: its Henry is no longer a match for that save)";
            if (storeWhy is null)
            {
                var snap = _henry.Store(_joinedTag!, parts!, md5, HenryStore.SourceSnapshot, $"host {Protocol.SaveKindName(w.Kind)} playline{w.Playline}/{w.FileName} seq={w.Seq}");
                Console.WriteLine(FormattableString.Invariant(
                    $"MP-HENRY joiner: PAIRED host save seq={w.Seq} md5={md5[..8]} with snapshot {snap.Short}: host-save-in -> request {lagS:F2} s, -> file verified {(tFile - tReq).TotalSeconds:F2} s ({SaveDisplay(path)}, {bytes.Length} B)"));
            }
            else Console.WriteLine($"MP-HENRY joiner: host save seq={w.Seq} md5={md5[..8]}: snapshot NOT stored -- {storeWhy}");
            // The QuickSave is a copy of the host's world in this player's playline: out at once.
            bool gone = _henry.MoveOut(path, "a snapshot's QuickSave (the host's world)");
            var after = await _combat.SaveListAsync(1, pl, Path.GetFileNameWithoutExtension(path));
            string expect = OwnSaves(saves, HostSeedForOwn()).FirstOrDefault(s => s.Save.Playline == pl)?.Save.Base ?? "-";
            Console.WriteLine($"MP-HENRY joiner: snapshot file {SaveDisplay(path)} moved out={On(gone)}; rescan listed={(after is null ? "?" : On(after.Listed))}; Continue would load playline{after?.ContinuePlayline}/{after?.ContinueName ?? "?"} (own newest there: {expect})");
            if (gone) _henry.LedgerSet(led.Id, e => e.State = "done");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"MP-HENRY joiner: snapshot for host save seq={w.Seq} failed: {ex.GetType().Name}: {ex.Message}");
        }
        finally
        {
            lock (_snapGate) _snapWait = null;
            Volatile.Write(ref _snapBusy, 0);
        }
    }

    /// <summary>
    /// A verified save landed in a playline while this game is joined. The
    /// snapshot's own QuickSave completes the waiter; anything else is a leak
    /// (a console QuickSave, WO-124 s9.1): ledgered, then moved out at once.
    /// Returns true when handled here.
    /// </summary>
    private bool Wo125OnJoinerSaveObserved(string path, string md5)
    {
        var id = WorldSaved.ParsePath(path);
        lock (_snapGate)
        {
            if (_snapWait is { } w && id is { } i && i.Playline == w.Playline && i.Kind == Protocol.SaveKindQuick && File.GetLastWriteTimeUtc(path) >= w.Since)
            {
                w.Tcs.TrySetResult(path);
                return true;
            }
        }
        if (!_joinedWorld) return false;
        var led = _henry.LedgerAdd(new HenryStore.LedgerEntry
        {
            Playline = id?.Playline ?? -1, SinceUtc = DateTime.UtcNow, File = Path.GetFileName(path), Md5 = md5, WorldTag = _joinedTag ?? "", Kind = "leak", State = "written",
        });
        Console.WriteLine($"MP-SAVELOCK LEAK a save of the host's world was written on this joiner: {SaveDisplay(path)} -- moving it out of the playline");
        _ = Task.Run(async () =>
        {
            if (_henry.MoveOut(path, "written while in the host's world (a leak)")) _henry.LedgerSet(led.Id, e => e.State = "done");
            if (id is { } ii) await _combat.SaveListAsync(1, ii.Playline, "-");
        });
        return true;
    }

    // ---------------------------------------------------------------- sweeps (agent start, before every join)

    private static readonly Regex TransientAny = new(@"^mp(world|exit)[0-9a-f]{1,8}\.(whs|part)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// <summary>
    /// Move out every file the mod made or saw land in a playline: transient
    /// mpworld/mpexit files, and every ledgered save that is still there. A
    /// save the player put there (e.g. a copy of a host world) is left alone
    /// and only logged. Returns how many files were moved.
    /// </summary>
    internal int Wo125Sweep(string why)
    {
        string? saves = ResolveSavesDirForJoin();
        if (saves is null) return 0;
        int n = 0;
        for (int pl = 0; pl <= 4; pl++)
        {
            string dir = Path.Combine(saves, $"playline{pl}");
            if (!Directory.Exists(dir)) continue;
            foreach (var f in Directory.EnumerateFiles(dir))
                if (TransientAny.IsMatch(Path.GetFileName(f)) && (_jj?.PlacedPath is not string keep || !string.Equals(keep, f, StringComparison.OrdinalIgnoreCase))
                    && _henry.MoveOut(f, $"a transient file of the mod ({why})")) n++;
        }
        foreach (var e in _henry.Ledger().Where(x => x.State != "done"))
        {
            string dir = Path.Combine(saves, $"playline{e.Playline}");
            bool done = true;
            if (e.File is string f && File.Exists(Path.Combine(dir, f)))
            {
                string p = Path.Combine(dir, f);
                var v = WhsSave.VerifyFile(p);
                if (e.Md5 is null || string.Equals(v.Md5, e.Md5, StringComparison.OrdinalIgnoreCase))
                { if (_henry.MoveOut(p, $"a {e.Kind} save the mod made or saw while joined ({why})")) n++; else done = false; }
                else Console.WriteLine($"MP-HENRY sweep: {SaveDisplay(p)} changed since it was ledgered (a save of the player's own now) -- left alone");
            }
            else if (e.File is null && Directory.Exists(dir))
            {
                // A snapshot whose file was never seen (a crash between the request and the file): a save of
                // the host's world (its seed) that landed in that playline within two minutes of the request.
                foreach (var p in Directory.EnumerateFiles(dir, "*.whs"))
                {
                    var t = File.GetLastWriteTimeUtc(p);
                    if (t < e.SinceUtc || t > e.SinceUtc.AddMinutes(2) || WorldSaved.ParsePath(p) is null) continue;
                    if (WhsSave.ReadSeedFromFile(p) is uint s && WhsSave.SeedTag(s) == e.WorldTag)
                    { if (_henry.MoveOut(p, $"a snapshot's QuickSave left by a crash ({why})")) n++; else done = false; }
                }
            }
            if (done) _henry.LedgerSet(e.Id, x => x.State = "done");
        }
        // A copy of a host world placed by hand: warn (once per file per agent run), never touch.
        var known = _henry.Worlds().Select(w => w.Tag).ToHashSet();
        var copies = new List<string>();
        if (known.Count > 0)
            foreach (var s in ListOwnSaves(saves))
                if (WhsSave.ReadSeedFromFile(s.FullPath) is uint sd && known.Contains(WhsSave.SeedTag(sd)) && Warned.TryAdd("sweep:" + s.FullPath, 0))
                    copies.Add(s.Display);
        if (copies.Count > 0)
            Console.WriteLine($"MP-HENRY sweep WARNING {copies.Count} save(s) have the playthrough seed of a host world this player joined -- not saves the mod made (left alone), never used as this player's own: {string.Join(", ", copies.Take(6))}{(copies.Count > 6 ? ", ..." : "")}");
        Console.WriteLine($"MP-HENRY sweep ({why}): {n} file(s) moved out of the playlines");
        return n;
    }

    private void Wo125AtStart()
    {
        try
        {
            var gone = _henry.CleanupStale();
            var worlds = _henry.Worlds();
            Console.WriteLine($"MP-HENRY store <data>/henry: {worlds.Count} world(s), {worlds.Sum(w => w.Count)} snapshot(s); 90-day rule removed {gone.Count}; keep {HenryStore.KeepPerWorld} per world");
            Wo125Sweep("agent start");
        }
        catch (Exception ex) { Console.WriteLine($"MP-HENRY start failed: {ex.Message}"); }
    }

    // ---------------------------------------------------------------- the way out with no own save

    /// <summary>
    /// No own save to go back to: a listed file with no world in it (the last
    /// world's header over an empty stream, 837 B in the probe) fails its load
    /// deterministically and the engine returns to the main menu with a
    /// "Game load failed / OK" box (observed from inside a world). Nothing in it
    /// could ever load as a world.
    /// </summary>
    private async Task<bool> Wo125ExitToMenuAsync(string why)
    {
        string? saves = ResolveSavesDirForJoin();
        int pl = _lastWorldPlayline >= 0 ? _lastWorldPlayline : 0;
        if (saves is null || _lastWorldDesc is null) { Console.WriteLine($"MP-HENRY no own save and no way to build the exit file ({(saves is null ? "no saves folder" : "no world header kept")}) -- staying"); return false; }
        var raw = new byte[4 + 6];
        BinaryPrimitives.WriteUInt32LittleEndian(raw, 23);
        BinaryPrimitives.WriteUInt16LittleEndian(raw.AsSpan(4), 0x01FA);
        var file = WhsSave.Deflate(_lastWorldDesc, raw, new byte[44]);
        string name = $"mpexit{Random.Shared.Next(1, int.MaxValue):x8}";
        string path = Path.Combine(saves, $"playline{pl}", name + ".whs");
        try
        {
            using (var fs = new FileStream(path + ".part", FileMode.CreateNew, FileAccess.Write)) fs.Write(file);
            File.Move(path + ".part", path);
            var listed = await _combat.SaveListAsync(1, pl, name);
            if (listed is null || !listed.Listed) { Console.WriteLine($"MP-HENRY exit file not listed after the rescan -- removed; staying ({why})"); _henry.MoveOut(path, "exit file not listed"); return false; }
            Console.WriteLine($"MP-HENRY no own save to go back to ({why}) -- loading an empty file ({SaveDisplay(path)}, {file.Length} B, no world in it): the engine fails the load and returns to the MAIN MENU");
            SetJoinUi("exit-menu", "You have no save of your own to go back to, so the game returns to the main menu. It shows \"Game load failed\" -- press OK.");
            _ownLoadExpected = true;
            await ExecLuaAsync($"if KCD2MP_Wo124LoadGame then KCD2MP_Wo124LoadGame({pl}, \"{name}\", \"exit-to-menu\") end");
            _ = Task.Run(async () =>
            {
                for (int i = 0; i < 120 && _where != GameWhere.Menu; i++) await Task.Delay(1000);
                await Task.Delay(1500);
                _henry.MoveOut(path, "the exit file (its load failed as meant)");
                await _combat.SaveListAsync(1, pl, name);
                _ownLoadExpected = false;
                Console.WriteLine($"MP-HENRY back at the main menu after the exit file: {(_where == GameWhere.Menu ? "yes" : "NOT SEEN")}; exit file moved out");
            });
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Console.WriteLine($"MP-HENRY exit file failed: {ex.Message}");
            return false;
        }
    }

    // ---------------------------------------------------------------- commands

    private void Wo125OnEvent(string name, string? arg)
    {
        switch (name)
        {
            case "wo125_choice":        // mp_join_henry <auto|fresh|playlineN/file>, typed
                Wo125OnConsoleChoice(arg ?? "");
                return;
            case "wo125_reset":         // mp_henry_reset
            {
                if (_peerTag is not string tag) { Console.WriteLine("MP-HENRY mp_henry_reset: the host's world is not known (no host, or it has not identified its world)"); _ = Wo125ToastAsync("mp_henry_reset: no host world known yet."); return; }
                bool had = _henry.DeleteWorld(tag, "mp_henry_reset (the player starts over in this host's world)");
                _firstChoice = null; _firstChoiceTag = null; _chooseAsked = false;
                if (_joinedWorld && _joinedTag == tag) _resetTag = tag;
                Console.WriteLine($"MP-HENRY mp_henry_reset world {tag}: {(had ? "Henry files deleted" : "there were none")}; the next join asks Bring / Fresh again{(_resetTag == tag ? " (no snapshots for it this session)" : "")}");
                _ = Wo125ToastAsync(had ? "Your character for this world was deleted. Next join: bring or start fresh." : "No character stored for this world.");
                return;
            }
            case "wo125_files":         // mp_henry_files [delete <tag>]
            {
                var p = (arg ?? "").Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (p.Length >= 2 && p[0] == "delete")
                {
                    bool ok = Regex.IsMatch(p[1], "^[0-9a-f]{10}$") && _henry.DeleteWorld(p[1], "mp_henry_files delete");
                    Console.WriteLine($"MP-HENRY mp_henry_files delete {p[1]}: {(ok ? "deleted" : "no such world")}");
                    _ = Wo125ToastAsync(ok ? $"World {p[1]} deleted." : $"No world {p[1]}.");
                    return;
                }
                var ws = _henry.Worlds();
                Console.WriteLine($"MP-HENRY mp_henry_files: {ws.Count} world(s) (the {HenryStore.StaleDays}-day rule deletes a world not joined for {HenryStore.StaleDays} days)");
                var lines = new List<string>();
                foreach (var w in ws)
                {
                    string l = FormattableString.Invariant($"{w.Tag}  last joined {w.LastJoinedUtc:yyyy-MM-dd}  {w.Count} snapshot(s)  {w.Bytes / 1024.0:F0} KB  first={w.FirstSource}{(w.Tag == _peerTag ? "  <- your host's world" : "")}");
                    lines.Add(l);
                    Console.WriteLine("MP-HENRY   " + l);
                }
                _ = ExecLuaAsync($"if KCD2MP_Wo125FilesShow then KCD2MP_Wo125FilesShow(\"{EscapeLua(string.Join("|", lines))}\") end");
                return;
            }
        }
    }

    private Task Wo125ToastAsync(string msg) => ExecLuaAsync($"if KCD2MP_Wo124Msg then KCD2MP_Wo124Msg(\"{EscapeLua(msg)}\") end");
}
