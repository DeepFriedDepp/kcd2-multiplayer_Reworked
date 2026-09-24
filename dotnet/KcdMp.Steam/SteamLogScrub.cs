using System.Text.RegularExpressions;

namespace KcdMp.Steam;

/// <summary>
/// Strips identifiers from text Steam hands back (connection end reasons,
/// relay debug messages), before it reaches any log line.
///
/// Steam's debug strings name the peer ("steamid:&lt;17 digits&gt;"), and can
/// carry IP addresses and relay point-of-presence codes. The launcher's log
/// and a tester's report both leave the machine, so none of that may.
/// </summary>
public static partial class SteamLogScrub
{
    [GeneratedRegex(@"(?i)steamid:\s*\d+|\[U:\d:\d+\]|\b\d{15,20}\b")]
    private static partial Regex SteamIds();

    [GeneratedRegex(@"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b|\[?\b(?:[0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{0,4}\b\]?(?::\d+)?")]
    private static partial Regex IpAddresses();

    public static string Scrub(string? text)
    {
        if (string.IsNullOrEmpty(text)) return "";
        var s = SteamIds().Replace(text, "<steam-id>");
        s = IpAddresses().Replace(s, "<ip>");
        return s.Replace('"', '\'').Replace('\n', ' ').Replace('\r', ' ');
    }
}
