namespace KcdMp.Steam;

/// <summary>
/// WO-127: the Steam app ids the launcher offers (Settings, advanced). Both
/// players must use the same one: Steam only connects two processes, and only
/// shows a friend's rich presence, under one app id.
/// </summary>
public static class SteamApps
{
    /// <summary>KCD2 Modding Tools: the app id the game itself runs as (WO-120).</summary>
    public const uint ModdingTools = 2429020;
    /// <summary>Valve's public test app ("Spacewar").</summary>
    public const uint Spacewar = 480;
    /// <summary>Retail KCD2.</summary>
    public const uint Retail = 1771300;

    /// <summary>The launcher's default until the maintainer decides after the WO-128 test.</summary>
    public const uint Default = ModdingTools;

    public static readonly uint[] Offered = [ModdingTools, Spacewar, Retail];

    /// <summary>The virtual port the relay listens on and the agent dials (P2P ports are per app, not per machine).</summary>
    public const int RelayVirtualPort = 7778;

    /// <summary>Rich presence key the hosting relay sets: "host;&lt;release&gt;".</summary>
    public const string PresenceKey = "kcdmp";

    public static bool IsOffered(uint app) => Array.IndexOf(Offered, app) >= 0;

    public static string Name(uint app) => app switch
    {
        ModdingTools => "KCD2 Modding Tools (2429020)",
        Spacewar => "Spacewar (480)",
        Retail => "KCD2 retail (1771300)",
        _ => $"app {app}",
    };

    /// <summary>The letter a join code carries for a non-default app (none for the game's own).</summary>
    internal static char? Suffix(uint app) => app switch { Spacewar => 'S', Retail => 'R', _ => null };

    internal static uint? FromSuffix(char c) => char.ToUpperInvariant(c) switch { 'S' => Spacewar, 'R' => Retail, _ => null };
}

/// <summary>
/// WO-127: the code the host reads out. The WO-120 friend code ("ABCD-EFG",
/// 7 chars) when the host runs under the game's own app id; one more letter
/// ("ABCD-EFG-S") when it runs under another, so a joiner set to a different
/// app id gets a plain "app setting doesn't match" instead of a silent
/// 20-second timeout. Never logged (<see cref="FriendCode.Redact"/>).
/// </summary>
public static class SteamJoinCode
{
    public static string Encode(ulong steamId64, uint appId)
    {
        string code = FriendCode.Encode(steamId64);
        return SteamApps.Suffix(appId) is char c ? $"{code}-{c}" : code;
    }

    /// <summary>
    /// Parses a typed code. <paramref name="appId"/> is the host's app id as
    /// the code states it (the default when it has no letter).
    /// </summary>
    public static bool TryParse(string? text, out ulong steamId64, out uint appId)
    {
        steamId64 = 0;
        appId = SteamApps.ModdingTools;
        if (string.IsNullOrWhiteSpace(text)) return false;
        var sig = new List<char>(10);
        foreach (char ch in text)
            if (ch is not ('-' or ' ' or '\t')) sig.Add(ch);
        if (sig.Count == 8)
        {
            if (SteamApps.FromSuffix(sig[7]) is not uint app) return false;
            appId = app;
            sig.RemoveAt(7);
        }
        if (sig.Count != 7) return false;
        return FriendCode.TryDecode(new string(sig.ToArray()), out steamId64);
    }
}
