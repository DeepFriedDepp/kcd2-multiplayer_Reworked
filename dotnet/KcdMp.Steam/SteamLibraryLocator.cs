using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace KcdMp.Steam;

/// <summary>
/// Finds the steam_api64.dll to bind against: the game's own copy.
///
/// The repo does not ship Valve's DLL. Every player already has one, beside
/// the game: &lt;install&gt;\Bin\Win64Shared\steam_api64.dll, the same file in
/// retail and the Modding Tools build (byte-identical, checked 2026-09-24).
/// Search order, first hit wins:
///   1. KCDMP_STEAM_API (an explicit path, for tests)
///   2. beside the running exe (a developer dropping one in)
///   3. the launcher's configured GamePath (%LOCALAPPDATA%\KCDMP\settings.json)
///   4. every Steam library's KCD2Mod / KingdomComeDeliverance2 install
/// </summary>
public static class SteamLibraryLocator
{
    private static readonly string[] InstallFolders = ["KCD2Mod", "KingdomComeDeliverance2"];
    private static int _installed;
    private static string? _resolvedPath;

    public static string? ResolvedPath => _resolvedPath;

    /// <summary>
    /// Hooks the P/Invoke resolver for this assembly. Idempotent. Returns the
    /// path it will load, or null when there is no Steam DLL on this machine
    /// (the caller turns that into "Steam isn't installed" for the player).
    /// </summary>
    public static string? Install(string? gameExePath = null)
    {
        _resolvedPath ??= Find(gameExePath);
        if (Interlocked.Exchange(ref _installed, 1) == 0)
        {
            NativeLibrary.SetDllImportResolver(typeof(SteamLibraryLocator).Assembly, Resolve);
        }
        return _resolvedPath;
    }

    private static IntPtr Resolve(string name, Assembly asm, DllImportSearchPath? path)
    {
        if (name != SteamNative.Lib || _resolvedPath is null) return IntPtr.Zero;
        return NativeLibrary.Load(_resolvedPath);
    }

    public static string? Find(string? gameExePath = null)
    {
        foreach (var candidate in Candidates(gameExePath))
        {
            try { if (File.Exists(candidate)) return Path.GetFullPath(candidate); }
            catch { /* unreadable path: next */ }
        }
        return null;
    }

    private static IEnumerable<string> Candidates(string? gameExePath)
    {
        var env = Environment.GetEnvironmentVariable("KCDMP_STEAM_API");
        if (!string.IsNullOrWhiteSpace(env)) yield return env;

        yield return Path.Combine(AppContext.BaseDirectory, "steam_api64.dll");

        foreach (var exe in new[] { gameExePath, LauncherGamePath() })
        {
            if (string.IsNullOrWhiteSpace(exe)) continue;
            var dir = Path.GetDirectoryName(exe);
            if (string.IsNullOrEmpty(dir)) continue;
            // <root>\Bin\<config>\KingdomCome.exe -> <root>\Bin\Win64Shared\steam_api64.dll
            yield return Path.Combine(dir, "..", "Win64Shared", "steam_api64.dll");
            yield return Path.Combine(dir, "steam_api64.dll");
        }

        foreach (var lib in SteamLibraries())
            foreach (var folder in InstallFolders)
                yield return Path.Combine(lib, "steamapps", "common", folder, "Bin", "Win64Shared", "steam_api64.dll");
    }

    private static string? LauncherGamePath()
    {
        try
        {
            var settings = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "KCDMP", "settings.json");
            if (!File.Exists(settings)) return null;
            using var doc = JsonDocument.Parse(File.ReadAllText(settings));
            return doc.RootElement.TryGetProperty("GamePath", out var p) ? p.GetString() : null;
        }
        catch { return null; }
    }

    /// <summary>Steam's install dir from the registry, plus every library in libraryfolders.vdf.</summary>
    public static IEnumerable<string> SteamLibraries()
    {
        var roots = new List<string>();
        if (OperatingSystem.IsWindows())
        {
            try
            {
                using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Valve\Steam");
                if (key?.GetValue("SteamPath") is string sp) roots.Add(sp.Replace('/', '\\'));
            }
            catch { }
        }
        roots.Add(@"C:\Program Files (x86)\Steam");

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var root in roots)
        {
            if (seen.Add(root)) yield return root;
            string vdf = Path.Combine(root, "steamapps", "libraryfolders.vdf");
            string text;
            try { text = File.Exists(vdf) ? File.ReadAllText(vdf) : ""; } catch { text = ""; }
            foreach (Match m in Regex.Matches(text, "\"path\"\\s+\"([^\"]+)\""))
            {
                var lib = m.Groups[1].Value.Replace(@"\\", @"\");
                if (seen.Add(lib)) yield return lib;
            }
        }
    }
}
