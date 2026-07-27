using System.Globalization;
using System.Text.RegularExpressions;

namespace KcdMp.Client;

/// <summary>
/// The existing channel, behind <see cref="IGameTransport"/>: the game's debug
/// REST API on localhost:1403, one HTTP round trip per call.
///
/// This is the WO-1 baseline, kept faithful to what the agent does today so a
/// benchmark against it is honest. Reading one player-state sample costs three
/// round trips:
///
///   1. GET  /api/rpg/SoulList/PlayerSoul   -> scrape Position="x,y,z"
///   2. GET  /api/System/Console/ExecuteString -> Lua stuffs yaw and mount
///      state into the sv_servername CVar
///   3. GET  /api/System/Console/GetCvarValue  -> read that CVar back
///
/// Steps 2 and 3 are the CVar hack: there is no push channel out of the game,
/// so an unrelated real CVar is hijacked as a one-slot mailbox. It also means
/// yaw and mount state cannot be read without *writing* to the game first.
///
/// The live agent softens this by running steps 2-3 on a slower background
/// loop (80 ms) than position (10 ms) and reusing the cached value. This class
/// exposes both: <see cref="ReadPlayerStateAsync"/> pays the full cost so the
/// benchmark measures the real thing, while <see cref="ReadPositionOnlyAsync"/>
/// and <see cref="ReadRotStateAsync"/> allow the split the agent actually uses.
/// </summary>
public sealed partial class HttpGameTransport(string gameApiBase, int timeoutMs = 800) : IGameTransport
{
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromMilliseconds(timeoutMs) };

    public string Name => "http-debug-api";

    /// <summary>Position, CVar write, CVar read.</summary>
    public int RoundTripsPerStateRead => 3;

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

    public async Task<PlayerState?> ReadPlayerStateAsync(CancellationToken ct = default)
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
    /// then read it back.
    ///
    /// The riding flag is computed in the interp tick rather than here because
    /// Terrain.GetElevation is not available in the console context, so the
    /// tick caches it in KCD2MP.isRiding and this only collects it.
    /// </summary>
    public async Task<(float rotZ, bool isRiding)?> ReadRotStateAsync(CancellationToken ct = default)
    {
        try
        {
            await ExecuteAsync(
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
        var cmd = Uri.EscapeDataString($"#{lua}");
        await _http.GetStringAsync($"{gameApiBase}/api/System/Console/ExecuteString?command={cmd}", ct);
    }

    /// <summary>Nothing is buffered; every call already went out.</summary>
    public Task FlushAsync(CancellationToken ct = default) => Task.CompletedTask;

    public ValueTask DisposeAsync()
    {
        _http.Dispose();
        return ValueTask.CompletedTask;
    }

    [GeneratedRegex(@"GameTime=""([^""]+)""")]
    private static partial Regex GameTimeRegex();

    [GeneratedRegex(@"Position=""([^""]+)""")]
    private static partial Regex PosRegex();

    [GeneratedRegex(@">([^<]*)<")]
    private static partial Regex CvarValueRegex();
}
