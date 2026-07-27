using Microsoft.Win32;
using System.Text.RegularExpressions;

namespace KcdMp.Client;

/// <summary>
/// Finds the game's kcd.log.
///
/// The Modding Tools entry installs separately (steamapps\common\KCD2Mod) and
/// writes its own kcd.log, and it is the build that actually gets launched for
/// modding -- so looking only under KingdomComeDeliverance2 finds nothing, or
/// worse, finds a stale log from the base game. Every KCD-ish folder in every
/// Steam library is scanned and the most recently written match wins.
/// </summary>
public static partial class KcdLogLocator
{
    /// <summary>Full path to the most recently written kcd.log, or null.</summary>
    public static string? Find()
    {
        try
        {
            var logs = new List<FileInfo>();
            foreach (var dir in CandidateDirectories())
            {
                try
                {
                    logs.AddRange(new DirectoryInfo(dir)
                        .EnumerateFiles("kcd.log", SearchOption.TopDirectoryOnly));
                }
                catch { /* unreadable directory */ }
            }

            return logs.Count == 0
                ? null
                : logs.OrderByDescending(f => f.LastWriteTimeUtc).First().FullName;
        }
        catch { return null; }
    }

    /// <summary>Game install directories worth searching, across all Steam libraries.</summary>
    private static IEnumerable<string> CandidateDirectories()
    {
        foreach (var root in SteamLibraryRoots())
        {
            string common = Path.Combine(root, "steamapps", "common");
            if (!Directory.Exists(common)) continue;

            IEnumerable<string> subdirs;
            try { subdirs = Directory.EnumerateDirectories(common); }
            catch { continue; }

            foreach (var d in subdirs)
            {
                string name = Path.GetFileName(d);
                if (name.Contains("Kingdom", StringComparison.OrdinalIgnoreCase) ||
                    name.Contains("KCD", StringComparison.OrdinalIgnoreCase))
                {
                    yield return d;
                }
            }
        }
    }

    /// <summary>Steam install dir plus every library root in libraryfolders.vdf.</summary>
    public static IEnumerable<string> SteamLibraryRoots()
    {
        string? steam =
            Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath", null) as string
            ?? Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Valve\Steam", "InstallPath", null) as string
            ?? Registry.GetValue(@"HKEY_CURRENT_USER\SOFTWARE\Valve\Steam", "SteamPath", null) as string;

        if (steam is null) yield break;
        yield return steam;

        string vdf = Path.Combine(steam, "config", "libraryfolders.vdf");
        if (!File.Exists(vdf)) yield break;

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { steam };
        IEnumerable<string> lines;
        try { lines = File.ReadLines(vdf); }
        catch { yield break; }

        foreach (var line in lines)
        {
            var m = LibraryPathRegex().Match(line.Trim());
            if (!m.Success) continue;
            string p = m.Groups[1].Value.Replace(@"\\", @"\");
            if (seen.Add(p)) yield return p;
        }
    }

    [GeneratedRegex(@"""path""\s+""([^""]+)""", RegexOptions.IgnoreCase)]
    private static partial Regex LibraryPathRegex();
}
