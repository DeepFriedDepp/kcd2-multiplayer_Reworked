using System.Globalization;
using System.Text;

namespace KcdMp.Client;

/// <summary>
/// The WO-1 replacement channel: the game pushes state into kcd.log and the
/// agent tails it.
///
/// Deliberately hybrid, because the log only runs one way. Outbound
/// (agent to game) still needs the debug API, so an <see cref="HttpGameTransport"/>
/// is composed for that; this class replaces only the *inbound* direction,
/// which is where the cost was:
///
///   before: 3 HTTP round trips per sample, ~128 ms, 7.8 samples/s
///   after:  0 round trips -- reads whatever the emitter last pushed
///
/// The mod's KCD2MP_EmitTick writes one line per tick, which this parses into
/// a cached <see cref="PlayerState"/>. Reads are then free and the sample rate
/// is set by the Lua timer rather than by HTTP.
///
/// Three things the tail has to survive, all of them observed rather than
/// hypothetical: the log is huge (3.5 MB during testing) and flooded with
/// unrelated engine chatter, so it is opened at the end and never re-read; the
/// game truncates or replaces it on restart, so shrinkage is detected and the
/// handle reopened; and lines are written while we read, so a trailing partial
/// line is held back until its newline arrives.
/// </summary>
public sealed class LogTailGameTransport : IGameTransport
{
    /// <summary>Emitted by KCD2MP_EmitState. Must match the Lua EMIT_VERSION.</summary>
    private const string Tag = "[KCD2-MP-DATA]";

    /// <summary>
    /// The original WO-1 line: <c>v1 &lt;seq&gt; &lt;clock&gt; &lt;x&gt; &lt;y&gt; &lt;z&gt; &lt;rotZ&gt; &lt;flags&gt;</c>.
    /// </summary>
    private const string VersionV1 = "v1";

    /// <summary>
    /// WO-28 Flow A: the same line plus <c>&lt;health&gt; &lt;stamina&gt;</c>, and two
    /// more flag bits (dead, unconscious).
    ///
    /// **Both versions are parsed, deliberately.** An agent and a kdcmp.pak are
    /// separate installables that update independently -- the pak is rebuilt by
    /// tools/Build-And-Install-Mod.ps1 and the agent by the installer -- so a
    /// new agent reading an old pak's v1 lines is a real, ordinary state, not a
    /// broken one. It degrades to "health unknown": position keeps working and
    /// PlayerStateUp is simply never sent, rather than the tail rejecting every
    /// line and the transport looking like a missing mod.
    /// </summary>
    private const string VersionV2 = "v2";

    /// <summary>The emitter version of the most recent line parsed, for diagnostics.</summary>
    public string? EmitterVersion { get; private set; }

    /// <summary>
    /// Discrete player actions, emitted by KCD2MP_EmitEvent on the same log
    /// channel: [KCD2-MP-EVT] v1 &lt;seq&gt; &lt;name&gt; &lt;arg&gt;
    ///
    /// This is the only way anything travels game → agent. There is no socket
    /// and no file API in the sandbox, so an accepted invite has to come out
    /// through the log like everything else.
    /// </summary>
    private const string EventTag = "[KCD2-MP-EVT]";

    /// <summary>
    /// Raised for each game event line: (name, argument). The argument is the
    /// raw remainder of the line, so an event can carry whatever it needs.
    /// </summary>
    public event Action<string, string>? GameEvent;

    /// <summary>Events seen since start.</summary>
    public long EventsReceived { get; private set; }

    private readonly HttpGameTransport _http;
    private readonly string _logPath;
    private readonly int _emitIntervalMs;
    private readonly CancellationTokenSource _cts = new();

    private Task? _tailTask;
    private volatile bool _emitterStarted;

    // Latest parsed frame. Written by the tail loop, read by callers.
    private readonly object _stateLock = new();
    private PlayerState? _latest;
    private long _latestSeq = -1;
    private DateTime _latestAtUtc = DateTime.MinValue;

    /// <summary>Frames parsed since start.</summary>
    public long FramesReceived { get; private set; }

    /// <summary>
    /// Frames missing according to the emitter's sequence numbers. Non-zero
    /// means the log dropped lines or the tailer could not keep up, which is
    /// the signal that this transport is not delivering what it promises.
    /// </summary>
    public long FramesDropped { get; private set; }

    /// <summary>
    /// A sample older than this is treated as no sample. Generous relative to
    /// the emit interval so a single late tick does not blank the state.
    /// </summary>
    public TimeSpan MaxAge { get; init; } = TimeSpan.FromMilliseconds(500);

    public string Name => "kcd-log-tail";

    /// <summary>Reads come from cached push state, so none.</summary>
    public int RoundTripsPerStateRead => 0;

    public LogTailGameTransport(HttpGameTransport http, string logPath, int emitIntervalMs = 20)
    {
        _http = http;
        _logPath = logPath;
        _emitIntervalMs = emitIntervalMs;
    }

    /// <summary>
    /// Resolves kcd.log automatically. Throws if it cannot be found, because a
    /// silently non-functional transport would look like a game that is simply
    /// never ready.
    /// </summary>
    public static LogTailGameTransport Create(HttpGameTransport http, int emitIntervalMs = 20)
    {
        string path = KcdLogLocator.Find()
            ?? throw new FileNotFoundException(
                "Could not locate kcd.log in any Steam library. Set it explicitly to use the log-tail transport.");
        return new LogTailGameTransport(http, path, emitIntervalMs);
    }

    public string LogPath => _logPath;

    /// <summary>
    /// Starts the tail loop and asks the mod to begin emitting. Safe to call
    /// repeatedly; the Lua side is idempotent too.
    /// </summary>
    public async Task StartAsync(CancellationToken ct = default)
    {
        _tailTask ??= Task.Run(() => TailLoopAsync(_cts.Token), CancellationToken.None);

        if (!_emitterStarted)
        {
            // Flush explicitly: the HTTP transport batches by default, and a
            // buffered start command would sit unsent while we wait for frames
            // that can never arrive -- which reads exactly like a missing mod.
            await _http.ExecuteAsync($"KCD2MP_StartEmitter({_emitIntervalMs})", ct);
            await _http.FlushAsync(ct);
            _emitterStarted = true;
        }
    }

    /// <summary>
    /// Forgets that the emitter-start command was already sent, so a following
    /// <see cref="StartAsync"/> issues it again (WO-13). The send path swallows
    /// its own exceptions, so a lost start command is indistinguishable from a
    /// missing mod without simply asking twice.
    /// </summary>
    public void ResetEmitterStart() => _emitterStarted = false;

    public Task<bool> IsGameReadyAsync(CancellationToken ct = default) =>
        _http.IsGameReadyAsync(ct);

    public Task<PlayerState?> ReadPlayerStateAsync(CancellationToken ct = default)
    {
        lock (_stateLock)
        {
            if (_latest is null || DateTime.UtcNow - _latestAtUtc > MaxAge)
                return Task.FromResult<PlayerState?>(null);
            return Task.FromResult(_latest);
        }
    }

    public Task ExecuteAsync(string lua, CancellationToken ct = default) =>
        _http.ExecuteAsync(lua, ct);

    public Task FlushAsync(CancellationToken ct = default) =>
        _http.FlushAsync(ct);

    // Appearance (WO-9) has no push-based equivalent -- it always goes
    // through the debug REST API regardless of which transport reads
    // position, so these simply delegate to the composed HttpGameTransport
    // exactly like ExecuteAsync/FlushAsync above.
    public Task<Guid[]> ReadEquippedItemClassesAsync(CancellationToken ct = default) =>
        _http.ReadEquippedItemClassesAsync(ct);

    public Task<Guid[]> ReadGhostEquippedItemClassesAsync(string ghostSoulName, CancellationToken ct = default) =>
        _http.ReadGhostEquippedItemClassesAsync(ghostSoulName, ct);

    public Task EquipItemOnGhostAsync(string ghostSoulName, Guid itemClass, bool createIfMissing, CancellationToken ct = default) =>
        _http.EquipItemOnGhostAsync(ghostSoulName, itemClass, createIfMissing, ct);

    public Task UnequipItemOnGhostAsync(string ghostSoulName, Guid itemClass, CancellationToken ct = default) =>
        _http.UnequipItemOnGhostAsync(ghostSoulName, itemClass, ct);

    public Task<Guid?> ReadGhostSoulGuidAsync(string ghostSoulName, CancellationToken ct = default) =>
        _http.ReadGhostSoulGuidAsync(ghostSoulName, ct);

    public Task<string?> ReadSoulNameByGuidAsync(Guid soulGuid, CancellationToken ct = default) =>
        _http.ReadSoulNameByGuidAsync(soulGuid, ct);

    public Task ExecuteNowAsync(string lua, CancellationToken ct = default) =>
        _http.ExecuteNowAsync(lua, ct);

    /// <summary>
    /// Raised when the local player's aggregate pause-like state changes
    /// (WO-11): true on entering any tracked UI state, false when the last
    /// one clears. Aggregated from independent enter/exit marker pairs in
    /// <see cref="ProcessPauseMarkers"/> so two overlapping states (e.g.
    /// opening inventory while a skip-time animation is still resolving)
    /// don't produce a spurious "exited" when only one of them closes.
    ///
    /// Raised on the tail loop's thread, same discipline as
    /// <see cref="GameEvent"/> -- subscribers must not block.
    /// </summary>
    public event Action<bool>? PauseStateChanged;

    /// <summary>
    /// Raised on the skip-time marker edges specifically (WO-38 Phase 1):
    /// true when the AfterSkipTime readiness observer starts waiting, false
    /// when it reports ready. The aggregate <see cref="PauseStateChanged"/>
    /// keeps firing exactly as before -- this is an additional, narrower
    /// signal for the time-skip sync layer, which needs the skip itself and
    /// not "any pausing UI state". Raised on the tail loop's thread;
    /// subscribers must not block.
    /// </summary>
    public event Action<bool>? SkipTimeStateChanged;

    /// <summary>
    /// Which trigger action the current/most recent skip came from
    /// (Protocol.TimeSkipKind*). WO-11's live kcd.log diff bracketed bed
    /// sleep, wait and fast travel with the same AfterSkipTime observer and
    /// never isolated a marker that distinguishes them, so until a live
    /// marker diff fills this in, every skip reports
    /// <see cref="Protocol.TimeSkipKindUnknown"/> and receivers use the
    /// generic "passed time to" wording. The extension point is
    /// <see cref="ProcessPauseMarkers"/>: latch a kind from a
    /// bed/fast-travel-specific line seen shortly before the skip start
    /// marker, exactly as the three existing marker pairs were found.
    /// </summary>
    public byte LastSkipKind { get; private set; } = Protocol.TimeSkipKindUnknown;

    // Independent because they were confirmed as genuinely distinct engine
    // signals (docs/WO-11-findings.md addendum, isolated live tests): the
    // ESC pause menu's RTPC tag does not fire for inventory, and neither
    // fires for a time skip.
    private bool _menuOpen;
    private bool _inventoryOpen;
    private bool _skipTimeActive;

    private bool AggregatePaused => _menuOpen || _inventoryOpen || _skipTimeActive;

    /// <summary>
    /// Scans one raw (untagged) engine log line for the marker pairs found
    /// live in WO-11. These are not this mod's own lines -- no
    /// [KCD2-MP-...] tag -- so they are matched by substring against
    /// whatever CryEngine/Warhorse actually wrote, confirmed against real
    /// isolated single-action tests rather than the mixed first pass that
    /// initially looked ambiguous.
    /// </summary>
    private void ProcessPauseMarkers(ReadOnlySpan<char> line)
    {
        bool before = AggregatePaused;

        // ESC/system pause menu: confirmed live, isolated
        // (docs/WO-11-findings.md addendum) -- MenuOpen pairs with the RTPC
        // tag going to 1, ui_menu_close with it going to 0. The RTPC line is
        // used as the authoritative edge since it is an explicit boolean,
        // not just an audio cue that could in principle fire elsewhere.
        if (line.IndexOf("'sqc_ptag_menu' will be 1") >= 0) _menuOpen = true;
        else if (line.IndexOf("'sqc_ptag_menu' will be 0") >= 0) _menuOpen = false;

        // Inventory: confirmed live, isolated -- its own PlayAudio pair,
        // distinct from the pause menu's (WO-11 addendum: the first mixed
        // test wrongly suggested inventory shared the menu RTPC tag; an
        // isolated re-test showed that was leftover state from a menu still
        // open at the start of that window, not inventory at all).
        if (line.IndexOf("PlayAudio: ApseOpen") >= 0) _inventoryOpen = true;
        else if (line.IndexOf("PlayAudio: ApseClose") >= 0) _inventoryOpen = false;

        // Skip-time (sleep/wait/bed): brackets the entire skip, start to
        // finish, via CryEngine's own readiness-observer logging.
        //
        // WO-38: no marker distinguishing bed sleep from wait from fast
        // travel has been confirmed live yet -- when one is, latch it into
        // LastSkipKind here, *before* the start edge fires, so the kind
        // rides the very first packet of the skip.
        if (line.IndexOf("Readiness observer 'AfterSkipTime'") >= 0)
        {
            bool skipBefore = _skipTimeActive;
            if (line.IndexOf("started async waiting") >= 0) _skipTimeActive = true;
            else if (line.IndexOf("is ready") >= 0) _skipTimeActive = false;
            if (_skipTimeActive != skipBefore)
            {
                try { SkipTimeStateChanged?.Invoke(_skipTimeActive); }
                catch (Exception ex) { Console.WriteLine($"[timeskip] handler threw: {ex.Message}"); }
            }
        }

        bool after = AggregatePaused;
        if (after != before)
        {
            try { PauseStateChanged?.Invoke(after); }
            catch (Exception ex) { Console.WriteLine($"[pause] handler threw: {ex.Message}"); }
        }
    }

    // -------------------------------------------------------------------------

    private async Task TailLoopAsync(CancellationToken ct)
    {
        var decoder = Encoding.UTF8.GetDecoder();
        var buffer = new byte[64 * 1024];
        var chars = new char[64 * 1024];
        var partial = new StringBuilder();

        FileStream? fs = null;
        try
        {
            while (!ct.IsCancellationRequested)
            {
                if (fs is null)
                {
                    try
                    {
                        // FileShare.ReadWrite|Delete: the game holds this open and
                        // may replace it; refusing to share would fail the open or
                        // block the game's own writes.
                        fs = new FileStream(_logPath, FileMode.Open, FileAccess.Read,
                            FileShare.ReadWrite | FileShare.Delete);
                        fs.Seek(0, SeekOrigin.End); // only new lines matter
                        partial.Clear();
                        decoder.Reset();
                    }
                    catch
                    {
                        await Task.Delay(500, ct);
                        continue;
                    }
                }

                // Rotation or truncation on game restart: the file got shorter
                // than where we are, so our offset is meaningless. Start over.
                try
                {
                    if (fs.Length < fs.Position)
                    {
                        fs.Dispose();
                        fs = null;
                        continue;
                    }
                }
                catch
                {
                    fs.Dispose();
                    fs = null;
                    continue;
                }

                int read;
                try { read = await fs.ReadAsync(buffer.AsMemory(0, buffer.Length), ct); }
                catch (OperationCanceledException) { break; }
                catch { fs.Dispose(); fs = null; continue; }

                if (read == 0)
                {
                    // Caught up. Poll well inside the emit interval so a fresh
                    // line is picked up promptly without spinning a core.
                    await Task.Delay(Math.Max(2, _emitIntervalMs / 4), ct);
                    continue;
                }

                int charCount = decoder.GetChars(buffer, 0, read, chars, 0);
                partial.Append(chars, 0, charCount);

                // Consume whole lines only; anything after the last newline is
                // an incomplete write and stays buffered.
                int start = 0;
                string text = partial.ToString();
                for (int i = 0; i < text.Length; i++)
                {
                    if (text[i] != '\n') continue;
                    ProcessLine(text.AsSpan(start, i - start));
                    start = i + 1;
                }

                partial.Clear();
                if (start < text.Length)
                    partial.Append(text, start, text.Length - start);
            }
        }
        catch (OperationCanceledException) { }
        finally { fs?.Dispose(); }
    }

    /// <summary>
    /// Parses one log line if it is ours. The tag is searched for rather than
    /// anchored at position 0, so an engine-added prefix does not break it.
    /// </summary>
    private void ProcessLine(ReadOnlySpan<char> line)
    {
        int evtIdx = line.IndexOf(EventTag);
        if (evtIdx >= 0)
        {
            ProcessEventLine(line[(evtIdx + EventTag.Length)..].Trim());
            return;
        }

        int tagIdx = line.IndexOf(Tag);
        if (tagIdx < 0)
        {
            // Not one of this mod's own tagged lines -- still worth scanning
            // for the raw engine markers WO-11 found (menu/inventory/skip-
            // time). Those never appear on a [KCD2-MP-...] line, so checking
            // only here costs nothing on the hot (DATA-tagged) path.
            ProcessPauseMarkers(line);
            return;
        }

        var rest = line[(tagIdx + Tag.Length)..].Trim();

        // v1 <seq> <clock> <x> <y> <z> <rotZ> <flags>
        // v2 <seq> <clock> <x> <y> <z> <rotZ> <flags> <health> <stamina>
        Span<Range> fields = stackalloc Range[11];
        int n = SplitOnSpaces(rest, fields);
        if (n < 8) return;

        bool isV2 = rest[fields[0]].SequenceEqual(VersionV2);
        if (!isV2 && !rest[fields[0]].SequenceEqual(VersionV1)) return; // unknown emitter version

        if (!long.TryParse(rest[fields[1]], NumberStyles.Integer, CultureInfo.InvariantCulture, out long seq)) return;
        if (!float.TryParse(rest[fields[3]], NumberStyles.Float, CultureInfo.InvariantCulture, out float x)) return;
        if (!float.TryParse(rest[fields[4]], NumberStyles.Float, CultureInfo.InvariantCulture, out float y)) return;
        if (!float.TryParse(rest[fields[5]], NumberStyles.Float, CultureInfo.InvariantCulture, out float z)) return;
        if (!float.TryParse(rest[fields[6]], NumberStyles.Float, CultureInfo.InvariantCulture, out float rotZ)) return;
        if (!int.TryParse(rest[fields[7]], NumberStyles.Integer, CultureInfo.InvariantCulture, out int flags)) return;

        // Health/stamina stay null on a v1 line, and on a v2 line whose trailing
        // fields are missing or malformed. Null means "unknown, leave it alone"
        // all the way up -- it is never coerced to a zero that would read as a
        // dead player. The mod sends Protocol.UnknownStat (-1) for a reading it
        // could not obtain at all (no stamina binding on this build), which is
        // passed through as-is for the same reason.
        float? health = null, stamina = null;
        bool? isDead = null, isUnconscious = null;
        if (isV2)
        {
            if (n >= 10
                && float.TryParse(rest[fields[8]], NumberStyles.Float, CultureInfo.InvariantCulture, out float h)
                && float.TryParse(rest[fields[9]], NumberStyles.Float, CultureInfo.InvariantCulture, out float st))
            {
                health = h;
                stamina = st;
            }
            // Flag bits 2 and 3 exist only in v2, so they are only trusted
            // there -- a v1 emitter leaves them clear, which would otherwise
            // read as a positive "not dead" it never actually asserted.
            isDead = (flags & 0x04) != 0;
            isUnconscious = (flags & 0x08) != 0;
        }

        lock (_stateLock)
        {
            // Emitter restarts reset the sequence, so only count a gap when it
            // moves forward -- otherwise a restart would report a huge fake drop.
            if (_latestSeq >= 0 && seq > _latestSeq + 1)
                FramesDropped += seq - _latestSeq - 1;

            _latestSeq = seq;
            _latest = new PlayerState(x, y, z, rotZ, (flags & 0x01) != 0,
                                      health, stamina, isDead, isUnconscious);
            _latestAtUtc = DateTime.UtcNow;
            EmitterVersion = isV2 ? VersionV2 : VersionV1;
            FramesReceived++;
        }
    }

    /// <summary>
    /// Parses "v1 &lt;seq&gt; &lt;name&gt; &lt;arg...&gt;" and raises <see cref="GameEvent"/>.
    ///
    /// The handler runs on the tail loop's thread, so subscribers must not block.
    /// A throwing subscriber is swallowed: losing one event is bad, but killing
    /// the tail loop would silently stop all position updates too.
    /// </summary>
    private void ProcessEventLine(ReadOnlySpan<char> rest)
    {
        Span<Range> fields = stackalloc Range[4];
        int n = SplitOnSpaces(rest, fields, limit: 3);
        if (n < 3) return;
        // The event channel has its own version, still v1: WO-28 changed the
        // state line's shape, not this one.
        if (!rest[fields[0]].SequenceEqual(VersionV1)) return;

        string name = rest[fields[2]].ToString();
        string arg = n > 3 ? rest[fields[3]].ToString().Trim() : string.Empty;

        EventsReceived++;
        try { GameEvent?.Invoke(name, arg); }
        catch (Exception ex) { Console.WriteLine($"[event] handler for '{name}' threw: {ex.Message}"); }
    }

    /// <summary>Splits on runs of spaces without allocating.</summary>
    /// <param name="limit">
    /// When non-negative, everything after this many fields is returned as one
    /// final field, so a trailing argument may itself contain spaces.
    /// </param>
    private static int SplitOnSpaces(ReadOnlySpan<char> s, Span<Range> into, int limit = -1)
    {
        int count = 0, i = 0;
        while (i < s.Length && count < into.Length)
        {
            while (i < s.Length && s[i] == ' ') i++;
            if (i >= s.Length) break;
            int start = i;

            if (limit >= 0 && count == limit)
            {
                into[count++] = new Range(start, s.Length);
                break;
            }

            while (i < s.Length && s[i] != ' ') i++;
            into[count++] = new Range(start, i);
        }
        return count;
    }

    public async ValueTask DisposeAsync()
    {
        _cts.Cancel();
        if (_tailTask is not null)
        {
            try { await _tailTask; } catch { }
        }

        if (_emitterStarted)
        {
            // Best effort: leaving the emitter running would keep writing to
            // kcd.log for the rest of the session. Flushed for the same reason
            // as the start command.
            try
            {
                await _http.ExecuteAsync("KCD2MP_StopEmitter()");
                await _http.FlushAsync();
            }
            catch { }
        }

        _cts.Dispose();
    }
}
