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
    // WO-110: the batch is bounded by ENCODED size against the console's
    // measured ceiling (LuaCommandBudget), not by a raw character count. The
    // previous 4,000-raw bound let a full batch be truncated by the engine
    // with a Lua error nobody on this side could see.
    private const int MaxBatchChars = LuaCommandBudget.MaxEncodedCommandChars;
    private int _pendingEncoded;   // encoded size of the statements in _pending, wrappers included

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

        int enc = LuaCommandBudget.EncodedLength(lua) + LuaCommandBudget.WrapperEncodedChars;
        if (enc > MaxBatchChars)
        {
            // Cannot ever be sent whole: the engine would truncate it and fail
            // every statement around it. Said out loud, once per 5 s, counted.
            OversizeDropped++;
            var now = DateTime.UtcNow;
            if ((now - _lastOversizeLogUtc) >= TimeSpan.FromSeconds(5))
            {
                _lastOversizeLogUtc = now;
                Console.WriteLine($"MP-BATCH-DROP reason=oversize encoded={enc} budget={MaxBatchChars} total={OversizeDropped} first=\"{(lua.Length > 100 ? lua[..100] + "..." : lua)}\"");
            }
            return;
        }

        bool flushFirst = false, flushAfter = false;
        await _batchLock.WaitAsync(ct);
        try
        {
            if (_pending.Count > 0 && _pendingEncoded + enc > MaxBatchChars) flushFirst = true;
        }
        finally { _batchLock.Release(); }
        if (flushFirst) await FlushAsync(ct);   // send what is queued; this statement starts the next batch

        await _batchLock.WaitAsync(ct);
        try
        {
            _pending.Add(lua);
            _pendingEncoded += enc;
            if (_pendingEncoded >= MaxBatchChars - 200) flushAfter = true;   // full enough: do not wait for the loop
        }
        finally { _batchLock.Release(); }

        if (flushAfter) await FlushAsync(ct);
    }

    /// <summary>WO-110: statements that could never fit one ExecuteString and were dropped (see LuaCommandBudget).</summary>
    public long OversizeDropped { get; private set; }
    private DateTime _lastOversizeLogUtc = DateTime.MinValue;

    public async Task FlushAsync(CancellationToken ct = default)
    {
        string[] batch;
        await _batchLock.WaitAsync(ct);
        try
        {
            if (_pending.Count == 0) return;
            batch = [.. _pending];
            _pending.Clear();
            _pendingEncoded = 0;
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

        // WO-110 Phase 6 (WO-109 s2.3): a failed flush drops EVERY statement
        // in the batch -- one Lua syntax error fails the whole ExecuteString
        // before any per-statement pcall runs, and an 800 ms timeout drops it
        // too. This used to be silent. Logged with the count and the head of
        // the batch, throttled to one line per 5 s so a stuck game does not
        // flood; the total is in the counter for the summary.
        try { await SendNowAsync(sb.ToString(), ct); }
        catch (Exception ex)
        {
            BatchesDropped++;
            StatementsDropped += batch.Length;
            var now = DateTime.UtcNow;
            if ((now - _lastDropLogUtc) >= TimeSpan.FromSeconds(5))
            {
                _lastDropLogUtc = now;
                string head = batch[0].Length > 120 ? batch[0][..120] + "..." : batch[0];
                Console.WriteLine($"MP-BATCH-DROP statements={batch.Length} total_batches={BatchesDropped} total_statements={StatementsDropped} why={ex.GetType().Name}: {ex.Message} first=\"{head}\"");
            }
        }
    }

    /// <summary>WO-110 Phase 6: batches whose ExecuteString failed (timeout, HTTP error, a syntax error in any statement).</summary>
    public long BatchesDropped { get; private set; }
    /// <summary>WO-110 Phase 6: statements lost inside those batches.</summary>
    public long StatementsDropped { get; private set; }
    private DateTime _lastDropLogUtc = DateTime.MinValue;

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
    /// Two round trips: every ItemClass in the player's
    /// EquipmentManager.EquippedArmorsByClassId AND EquippedWeaponsByClassId
    /// maps, merged. This is the real per-slot equipment state -- proven in
    /// WO-9 Phase 0 (armor) and WO-10 (weapons, identical shape, confirmed
    /// live) to track a player who equipped by hand, unlike
    /// BaseClothingPreset, which reads all-zero the moment a player stops
    /// matching the preset they spawned with. One merged read rather than two
    /// separate wire messages because EquipItem/UnequipItem do not care which
    /// map a class came from -- see the diff/apply path in GameBridge.
    /// </summary>
    public async Task<Guid[]?> ReadEquippedItemClassesAsync(CancellationToken ct = default)
    {
        var armor = await ReadItemClassMapAsync(
            $"{gameApiBase}/api/rpg/SoulList/PlayerSoul/EquipmentManager/EquippedArmorsByClassId?depth=1", ct);
        var weapons = await ReadItemClassMapAsync(
            $"{gameApiBase}/api/rpg/SoulList/PlayerSoul/EquipmentManager/EquippedWeaponsByClassId?depth=1", ct);
        // WO-59: a failed half is not an empty half. Under load the game's
        // REST API times out one endpoint while the other answers (host at
        // 15 fps, WO-54 §5.1) -- merging a failed armor read with a good
        // weapon read used to produce a REAL-looking smaller set, which the
        // appearance loop then sent as a genuine outfit change and every
        // peer unequipped half the player's clothes. Null means "don't know",
        // and the caller skips the poll instead of acting on it.
        if (armor is null || weapons is null) return null;
        return [.. armor, .. weapons];
    }

    /// <summary>
    /// Reads a named ghost's own EquippedArmorsByClassId and
    /// EquippedWeaponsByClassId, merged. Not used by the normal apply path --
    /// GameBridge tracks what it last applied to each ghost itself, so it
    /// never needs to ask the game what is currently equipped -- but kept for
    /// verification retries, diagnostics and the manual test procedure.
    /// </summary>
    public async Task<Guid[]?> ReadGhostEquippedItemClassesAsync(string ghostSoulName, CancellationToken ct = default)
    {
        string soul = Uri.EscapeDataString(ghostSoulName);
        var armor = await ReadItemClassMapAsync(
            $"{gameApiBase}/api/rpg/SoulList/SoulsByName/{soul}/EquipmentManager/EquippedArmorsByClassId?depth=1", ct);
        var weapons = await ReadItemClassMapAsync(
            $"{gameApiBase}/api/rpg/SoulList/SoulsByName/{soul}/EquipmentManager/EquippedWeaponsByClassId?depth=1", ct);
        // WO-59: same null discipline as the player read above. The verify
        // path used to take a timed-out read for "nothing is equipped" and
        // mass-blacklist a whole batch of perfectly equippable items.
        if (armor is null || weapons is null) return null;
        return [.. armor, .. weapons];
    }

    private async Task<Guid[]?> ReadItemClassMapAsync(string url, CancellationToken ct)
    {
        try
        {
            var xml = await _http.GetStringAsync(url, ct);
            return ParseItemClasses(xml);
        }
        catch { return null; }
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

    /// <summary>
    /// Reads a ghost's own Soul.Guid (WO-17). This is NOT the same field as
    /// SharedSoulGuid used elsewhere for cross-client damage matching -- a
    /// locally-spawned ghost proxy carries SharedSoulGuid=0, so Guid is the
    /// identity that actually resolves through the DLL's SoulsByGuid lookup
    /// for it. Depth=1 with a heavy-subtree exclude list keeps this cheap,
    /// same idiom as Get-KcdSoulSnapshot in tools\KcdApi.ps1. Null if the
    /// ghost is not (yet) a real soul the game will answer for.
    /// </summary>
    public async Task<Guid?> ReadGhostSoulGuidAsync(string ghostSoulName, CancellationToken ct = default)
    {
        string soul = Uri.EscapeDataString(ghostSoulName);
        try
        {
            var xml = await _http.GetStringAsync(
                $"{gameApiBase}/api/rpg/SoulList/SoulsByName/{soul}?depth=1&exclude=" +
                "DerivedStatsByName,Buffs,Roles,StaticData,PersistentData,Archetype,Inventory," +
                "CombatSoul,CompanionManager,EquipmentManager,FactionNode,SoulClass,SocialClass,StormDebug", ct);
            var m = SoulGuidRegex().Match(xml);
            return m.Success ? Guid.Parse(m.Groups[1].Value) : null;
        }
        catch { return null; }
    }

    /// <summary>
    /// Reads the soul NAME for a per-save Soul.Guid (WO-40 Phase 5). The DLL
    /// resolves damage targets through a SoulsByGuid lookup; the reflection
    /// API exposes the same container. Two route spellings are tried since
    /// only SoulsByName has ever been exercised from this side; a route that
    /// 404s on this build degrades to null (sender falls back to 0x12).
    /// </summary>
    public async Task<string?> ReadSoulNameByGuidAsync(Guid soulGuid, CancellationToken ct = default)
    {
        foreach (var route in new[] { "SoulsByGuid", "SoulsById" })
        {
            try
            {
                var xml = await _http.GetStringAsync(
                    $"{gameApiBase}/api/rpg/SoulList/{route}/{soulGuid}?depth=1&exclude=" +
                    "DerivedStatsByName,Buffs,Roles,StaticData,PersistentData,Archetype,Inventory," +
                    "CombatSoul,CompanionManager,EquipmentManager,FactionNode,SoulClass,SocialClass,StormDebug", ct);
                var m = SoulNameRegex().Match(xml);
                if (m.Success) return m.Groups[1].Value;
            }
            catch { /* try the next spelling */ }
        }
        return null;
    }

    /// <summary>
    /// WO-99 Phase 0: the local player's soul guid + name from the same
    /// PlayerSoul route the position read uses, one round trip. Same
    /// attribute regexes as the SoulsByName/SoulsByGuid reads (the route
    /// returns one Soul object; the first Name= on it is the soul's own).
    /// </summary>
    public async Task<(Guid? Guid, string? Name)> ReadPlayerSoulIdentityAsync(CancellationToken ct = default)
    {
        try
        {
            var xml = await _http.GetStringAsync(
                $"{gameApiBase}/api/rpg/SoulList/PlayerSoul?depth=1&exclude=" +
                "DerivedStatsByName,Buffs,Roles,StaticData,PersistentData,Archetype,Inventory," +
                "CombatSoul,CompanionManager,EquipmentManager,FactionNode,SoulClass,SocialClass,StormDebug", ct);
            var g = SoulGuidRegex().Match(xml);
            var n = SoulNameRegex().Match(xml);
            Guid? guid = g.Success && Guid.TryParse(g.Groups[1].Value, out var parsed) && parsed != Guid.Empty ? parsed : null;
            string? name = n.Success ? n.Groups[1].Value : null;
            return (guid, name);
        }
        catch { return (null, null); }
    }

    private static Guid[] ParseItemClasses(string xml)
    {
        var matches = ItemClassRegex().Matches(xml);
        var result = new Guid[matches.Count];
        for (int i = 0; i < matches.Count; i++)
            result[i] = Guid.Parse(matches[i].Groups[1].Value);
        return result;
    }

    // -------------------------------------------------------------------------
    // Unbatched Lua (WO-13)
    // -------------------------------------------------------------------------

    /// <summary>
    /// Runs one Lua statement immediately. Same wire path as the batched
    /// sender, minus the buffer -- so it inherits the property WO-12 s0.4
    /// proved and this depends on: an ExecuteString-driven statement executes
    /// straight away even while a menu has focus and Script.SetTimer is
    /// frozen.
    /// </summary>
    public Task ExecuteNowAsync(string lua, CancellationToken ct = default)
    {
        int enc = LuaCommandBudget.EncodedLength(lua) + LuaCommandBudget.WrapperEncodedChars;
        if (enc > MaxBatchChars)
        {
            OversizeDropped++;
            Console.WriteLine($"MP-BATCH-DROP reason=oversize-now encoded={enc} budget={MaxBatchChars} total={OversizeDropped} first=\"{(lua.Length > 100 ? lua[..100] + "..." : lua)}\"");
            return Task.CompletedTask;
        }
        return SendNowAsync($"pcall(function() {lua} end)", ct);
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

    // Negative lookbehind for "Soul" so this matches the Soul element's own
    // Guid="..." attribute but not SharedSoulGuid="..." -- both end in
    // "Guid=", only the latter is preceded by "Soul".
    [GeneratedRegex(@"(?<!Soul)Guid=""([0-9a-fA-F-]{36})""")]
    private static partial Regex SoulGuidRegex();

    // The soul element's Name attribute -- restricted to the authored-name
    // charset because the value crosses onto the wire and into Lua string
    // literals downstream.
    [GeneratedRegex(@"\bName=""([A-Za-z0-9_]+)""")]
    private static partial Regex SoulNameRegex();
}
