using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace KcdMp.Client;

/// <summary>
/// The game's debug REST API on localhost:1403, one HTTP round trip per call.
///
/// Two measured facts shape this class:
///
/// **Cost is per round trip, flat.** ~13-42 ms depending on game load, and
/// completely independent of payload -- 20 Lua statements in one call cost the
/// same as one. So statements are batched and flushed together, turning N ghost
/// updates per tick from N round trips into one.
///
/// **A batch aborts at the first error.** With twelve statements and a
/// deliberate fault at the sixth, an unwrapped batch ran only the first five;
/// the same batch with each statement wrapped in its own pcall ran all eleven
/// good ones. So every batched statement is wrapped individually. This also
/// matches the project rule that Lua touching game state goes in a pcall.
///
/// Reading player state is split the way the agent has always done it: position
/// is one round trip per tick, while yaw and mount state come from a slower
/// background loop through the sv_servername CVar. That CVar round trip is the
/// hack WO-1 removes -- see <see cref="LogTailGameTransport"/> -- but it stays
/// here so this remains an honest baseline and a working fallback.
/// </summary>
public sealed partial class HttpGameTransport(string gameApiBase, int timeoutMs = 800) : IGameTransport
{
    /// <summary>How often the background loop refreshes yaw and mount state.</summary>
    private const int RotStateIntervalMs = 80;

    /// <summary>
    /// Flush before the batch gets long. Payload does not affect latency and an
    /// 8000-character chunk was verified to execute, so this is comfortably
    /// conservative rather than a measured ceiling.
    /// </summary>
    private const int MaxBatchChars = 4000;

    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromMilliseconds(timeoutMs) };

    private readonly List<string> _pending = [];
    private readonly SemaphoreSlim _batchLock = new(1, 1);

    private CancellationTokenSource? _rotCts;
    private Task? _rotTask;
    private volatile float _cachedRotZ;
    private volatile bool _cachedIsRiding;

    /// <summary>
    /// When true, <see cref="ExecuteAsync"/> buffers until <see cref="FlushAsync"/>.
    /// </summary>
    public bool BatchingEnabled { get; set; } = true;

    public string Name => "http-debug-api";

    /// <summary>
    /// One: position. Yaw and mount state come from the background loop, so they
    /// are not charged per read. <see cref="ReadPlayerStateUncachedAsync"/> is
    /// the three-round-trip cost of doing it without that loop.
    /// </summary>
    public int RoundTripsPerStateRead => 1;

    /// <summary>Starts the background yaw/mount-state refresh.</summary>
    public Task StartAsync(CancellationToken ct = default)
    {
        if (_rotTask is not null) return Task.CompletedTask;
        _rotCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        _rotTask = Task.Run(() => RotStateLoopAsync(_rotCts.Token), CancellationToken.None);
        return Task.CompletedTask;
    }

    private async Task RotStateLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            var rot = await ReadRotStateAsync(ct);
            if (rot is not null)
            {
                _cachedRotZ = rot.Value.rotZ;
                _cachedIsRiding = rot.Value.isRiding;
            }
            try { await Task.Delay(RotStateIntervalMs, ct); }
            catch (OperationCanceledException) { break; }
        }
    }

    public async Task<bool> IsGameReadyAsync(CancellationToken ct = default)
    {
        try
        {
            var xml = await _http.GetStringAsync($"{gameApiBase}/api/rpg/Calendar?depth=1", ct);
            var m = GameTimeRegex().Match(xml);
            return m.Success
                && float.TryParse(m.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out float t)
                && t > 0;
        }
        catch { return false; }
    }

    /// <summary>Position this tick, plus the most recent cached yaw/mount state.</summary>
    public async Task<PlayerState?> ReadPlayerStateAsync(CancellationToken ct = default)
    {
        var pos = await ReadPositionOnlyAsync(ct);
        if (pos is null) return null;
        var (x, y, z) = pos.Value;
        return new PlayerState(x, y, z, _cachedRotZ, _cachedIsRiding);
    }

    /// <summary>
    /// Full state without the cache: three round trips. Only used to measure
    /// what the CVar hack actually costs.
    /// </summary>
    public async Task<PlayerState?> ReadPlayerStateUncachedAsync(CancellationToken ct = default)
    {
        var pos = await ReadPositionOnlyAsync(ct);
        if (pos is null) return null;
        var rot = await ReadRotStateAsync(ct);
        var (x, y, z) = pos.Value;
        return new PlayerState(x, y, z, rot?.rotZ ?? 0f, rot?.isRiding ?? false);
    }

    /// <summary>One round trip: scrape Position from the player soul XML.</summary>
    public async Task<(float x, float y, float z)?> ReadPositionOnlyAsync(CancellationToken ct = default)
    {
        try
        {
            var xml = await _http.GetStringAsync($"{gameApiBase}/api/rpg/SoulList/PlayerSoul?depth=1", ct);
            var m = PosRegex().Match(xml);
            if (!m.Success) return null;

            var parts = m.Groups[1].Value.Split(',');
            if (parts.Length < 3) return null;

            return (float.Parse(parts[0], CultureInfo.InvariantCulture),
                    float.Parse(parts[1], CultureInfo.InvariantCulture),
                    float.Parse(parts[2], CultureInfo.InvariantCulture));
        }
        catch { return null; }
    }

    /// <summary>
    /// Two round trips: have Lua pack yaw and mount state into sv_servername,
    /// then read it back. Sent immediately -- buffering the write would leave
    /// the read fetching a stale value.
    ///
    /// The riding flag is computed in the interp tick rather than here, because
    /// Terrain is not available in the console context; this only collects what
    /// the tick already cached in KCD2MP.isRiding.
    /// </summary>
    public async Task<(float rotZ, bool isRiding)?> ReadRotStateAsync(CancellationToken ct = default)
    {
        try
        {
            await SendNowAsync(
                @"System.SetCVar(""sv_servername"",(function()" +
                @"local r=player:GetWorldAngles().z;" +
                @"local ride=KCD2MP and KCD2MP.isRiding and 'r' or 's';" +
                @"return string.format('%.4f,%s',r,ride)end)())", ct);

            var xml = await _http.GetStringAsync(
                $"{gameApiBase}/api/System/Console/GetCvarValue?name=sv_servername", ct);

            var m = CvarValueRegex().Match(xml);
            if (!m.Success) return null;

            var parts = m.Groups[1].Value.Split(',');
            float rot = 0f;
            if (parts.Length >= 1)
                float.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out rot);

            return (rot, parts.Length >= 2 && parts[1].Trim() == "r");
        }
        catch { return null; }
    }

    public async Task ExecuteAsync(string lua, CancellationToken ct = default)
    {
        if (!BatchingEnabled)
        {
            await SendNowAsync(lua, ct);
            return;
        }

        bool flushNow = false;
        await _batchLock.WaitAsync(ct);
        try
        {
            _pending.Add(lua);
            if (_pending.Sum(s => s.Length + 32) >= MaxBatchChars) flushNow = true;
        }
        finally { _batchLock.Release(); }

        if (flushNow) await FlushAsync(ct);
    }

    public async Task FlushAsync(CancellationToken ct = default)
    {
        string[] batch;
        await _batchLock.WaitAsync(ct);
        try
        {
            if (_pending.Count == 0) return;
            batch = [.. _pending];
            _pending.Clear();
        }
        finally { _batchLock.Release(); }

        // Each statement gets its own pcall so one failure cannot swallow the
        // rest of the batch -- measured: unwrapped, a fault at statement 6 of 12
        // lost everything after it.
        var sb = new StringBuilder();
        foreach (var stmt in batch)
        {
            sb.Append("pcall(function() ").Append(stmt).Append(" end)\n");
        }

        try { await SendNowAsync(sb.ToString(), ct); }
        catch { /* fire-and-forget, same as the unbatched path */ }
    }

    /// <summary>Sends immediately, bypassing the batch buffer.</summary>
    private async Task SendNowAsync(string lua, CancellationToken ct = default)
    {
        var cmd = Uri.EscapeDataString($"#{lua}");
        await _http.GetStringAsync($"{gameApiBase}/api/System/Console/ExecuteString?command={cmd}", ct);
    }

    // -------------------------------------------------------------------------
    // Appearance (WO-9)
    // -------------------------------------------------------------------------

    /// <summary>
    /// One round trip: every ItemClass currently in the player's
    /// EquipmentManager.EquippedArmorsByClassId map. This is the real
    /// per-slot equipment state -- proven in WO-9 Phase 0 to track a player
    /// who equipped by hand, unlike BaseClothingPreset, which reads all-zero
    /// the moment a player stops matching the preset they spawned with.
    /// </summary>
    public async Task<Guid[]> ReadEquippedItemClassesAsync(CancellationToken ct = default)
    {
        try
        {
            var xml = await _http.GetStringAsync(
                $"{gameApiBase}/api/rpg/SoulList/PlayerSoul/EquipmentManager/EquippedArmorsByClassId?depth=1", ct);
            return ParseItemClasses(xml);
        }
        catch { return []; }
    }

    /// <summary>
    /// Reads a named ghost's own EquippedArmorsByClassId. Not used by the
    /// normal apply path -- GameBridge tracks what it last applied to each
    /// ghost itself, so it never needs to ask the game what is currently
    /// equipped -- but kept for diagnostics and the manual test procedure.
    /// </summary>
    public async Task<Guid[]> ReadGhostEquippedItemClassesAsync(string ghostSoulName, CancellationToken ct = default)
    {
        try
        {
            var xml = await _http.GetStringAsync(
                $"{gameApiBase}/api/rpg/SoulList/SoulsByName/{Uri.EscapeDataString(ghostSoulName)}" +
                "/EquipmentManager/EquippedArmorsByClassId?depth=1", ct);
            return ParseItemClasses(xml);
        }
        catch { return []; }
    }

    public async Task EquipItemOnGhostAsync(string ghostSoulName, Guid itemClass, bool createIfMissing, CancellationToken ct = default)
    {
        string soul = Uri.EscapeDataString(ghostSoulName);
        string cls = itemClass.ToString();

        if (createIfMissing)
        {
            // Fire-and-forget the descriptor: CreateItems returns an
            // ItemClassDescriptor with no readable properties at this depth,
            // and the only verification that matters is the equip that
            // follows actually taking effect.
            await _http.GetStringAsync(
                $"{gameApiBase}/api/rpg/SoulList/SoulsByName/{soul}/Inventory/CreateItems" +
                $"?ItemClass={cls}&Amount=1&ShowUINotification=false", ct);
        }

        await _http.GetStringAsync(
            $"{gameApiBase}/api/rpg/SoulList/SoulsByName/{soul}/EquipmentManager/EquipItem?itemClassId={cls}", ct);
    }

    public async Task UnequipItemOnGhostAsync(string ghostSoulName, Guid itemClass, CancellationToken ct = default)
    {
        string soul = Uri.EscapeDataString(ghostSoulName);
        await _http.GetStringAsync(
            $"{gameApiBase}/api/rpg/SoulList/SoulsByName/{soul}/EquipmentManager/UnequipItem?itemClassId={itemClass}", ct);
    }

    private static Guid[] ParseItemClasses(string xml)
    {
        var matches = ItemClassRegex().Matches(xml);
        var result = new Guid[matches.Count];
        for (int i = 0; i < matches.Count; i++)
            result[i] = Guid.Parse(matches[i].Groups[1].Value);
        return result;
    }

    public async ValueTask DisposeAsync()
    {
        try { await FlushAsync(); } catch { }

        _rotCts?.Cancel();
        if (_rotTask is not null)
        {
            try { await _rotTask; } catch { }
        }
        _rotCts?.Dispose();
        _batchLock.Dispose();
        _http.Dispose();
    }

    [GeneratedRegex(@"GameTime=""([^""]+)""")]
    private static partial Regex GameTimeRegex();

    [GeneratedRegex(@"Position=""([^""]+)""")]
    private static partial Regex PosRegex();

    [GeneratedRegex(@">([^<]*)<")]
    private static partial Regex CvarValueRegex();

    [GeneratedRegex(@"ItemClass=""([0-9a-fA-F-]{36})""")]
    private static partial Regex ItemClassRegex();
}
