using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using Microsoft.Win32;
using System.Text.RegularExpressions;

namespace KCDMP_launcher.Components.Shared
{
    /// <summary>
    /// WO-39, item K: the tester diagnostics bundle. WO-38's real two-player
    /// test produced logs with ZERO game telemetry in them -- the testers sent
    /// the launcher's app.log because that was the only file they knew about,
    /// while everything that mattered (kcd.log, the agent console) was never
    /// collected. This gathers every diagnostic surface into one zip a tester
    /// can just hand over.
    ///
    /// WO-40: the first real bundles (2026-08-18) proved two collection bugs.
    /// kcd.log was missing from BOTH players' zips -- the steam_appid.txt
    /// walk-up in GameRootOf silently falls back to the exe's own directory,
    /// where kcd.log is not -- so the bundle now hunts for kcd.log itself
    /// (walk up from the game root, then scan every Steam library the way the
    /// agent's KcdLogLocator does). And "config.json" was collected from
    /// %AppData%\KCDMP_Launcher where the launcher never writes anything; the
    /// real settings live in settings.json in the launcher's working
    /// directory. Both are collected now (settings.json as the real one,
    /// config.json kept in case an old install has it).
    /// </summary>
    public static class LogBundle
    {
        /// <summary>
        /// Collects kcd.log, the agent's log files and the launcher's recent
        /// app logs into a timestamped zip on the user's Desktop. Returns the
        /// zip path. Files that do not exist are skipped, never fatal -- a
        /// partial bundle beats no bundle.
        /// </summary>
        public static string Collect(string gameRoot, string agentDirectory)
        {
            string zipPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
                $"KCDMP-logs-{DateTime.Now:yyyyMMdd-HHmmss}.zip");

            using var zip = ZipFile.Open(zipPath, ZipArchiveMode.Create);

            // The game holds kcd.log open while running; the agent holds
            // agent.log; Serilog holds the current app log. Everything is
            // therefore read with full sharing rather than ZipArchive's own
            // exclusive CreateEntryFromFile.
            void AddIfPresent(string? path, string entryName)
            {
                try
                {
                    if (string.IsNullOrWhiteSpace(path) || !File.Exists(path)) return;
                    using var src = new FileStream(path, FileMode.Open, FileAccess.Read,
                        FileShare.ReadWrite | FileShare.Delete);
                    var entry = zip.CreateEntry(entryName, CompressionLevel.Optimal);
                    using var dst = entry.Open();
                    src.CopyTo(dst);
                }
                catch
                {
                    // One unreadable file must not sink the bundle.
                }
            }

            string? kcdLog = FindKcdLog(gameRoot);
            AddIfPresent(kcdLog, "kcd.log");

            // WO-58: the two files this bundle was missing when it mattered.
            // The 2026-08-25 host freeze was only diagnosable because the
            // native mirror log and the engine's own kcd.log backup happened
            // to survive on disk -- neither was in any exported bundle.
            // kcdmp-native.mirror.log lives in the game root (next to
            // kcd.log, see native/KCDMP/log.h), and CryEngine rotates the
            // PREVIOUS run's kcd.log into logbackups\ -- which is the run a
            // tester is usually reporting about, since they collect logs
            // after restarting a crashed game.
            if (kcdLog is not null)
            {
                string kcdDir = Path.GetDirectoryName(kcdLog) ?? "";
                AddIfPresent(Path.Combine(kcdDir, "kcdmp-native.mirror.log"), "kcdmp-native.mirror.log");
                try
                {
                    var backups = new DirectoryInfo(Path.Combine(kcdDir, "logbackups"))
                        .GetFiles("*.log")
                        .OrderByDescending(f => f.LastWriteTimeUtc)
                        .Take(2);
                    foreach (var b in backups)
                        AddIfPresent(b.FullName, $"logbackups/{b.Name}");
                }
                catch { }
            }

            if (!string.IsNullOrWhiteSpace(agentDirectory))
            {
                AddIfPresent(Path.Combine(agentDirectory, "agent.log"), "agent.log");
                AddIfPresent(Path.Combine(agentDirectory, "agent.prev.log"), "agent.prev.log");
                AddIfPresent(Path.Combine(agentDirectory, "agent.prev2.log"), "agent.prev2.log");
                // The primary native log sits beside the DLL, which ships in
                // the same directory as the agent.
                AddIfPresent(Path.Combine(agentDirectory, "kcdmp-native.log"), "kcdmp-native.log");
            }

            // Serilog's rolling file names are app<yyyyMMdd>.log; take the two
            // newest so the bundle covers a session that straddled midnight.
            try
            {
                foreach (var f in new DirectoryInfo(Globals.AppFolder)
                             .GetFiles("app*.log")
                             .OrderByDescending(f => f.LastWriteTimeUtc)
                             .Take(2))
                    AddIfPresent(f.FullName, f.Name);
            }
            catch { }

            // The launcher's real settings file (written by Home.SaveSettings
            // as a working-directory-relative "settings.json").
            AddIfPresent(Path.GetFullPath("settings.json"), "settings.json");
            AddIfPresent(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "settings.json"),
                "settings.launcher-dir.json");
            AddIfPresent(Globals.ConfigFilePath, "config.json");

            return zipPath;
        }

        /// <summary>
        /// Finds the game's kcd.log the way the agent does, rather than
        /// trusting one derived directory: try the supplied game root, walk
        /// up from it a few levels, then scan every KCD-ish folder in every
        /// Steam library and take the most recently written match.
        /// </summary>
        private static string? FindKcdLog(string gameRoot)
        {
            try
            {
                // 1. The supplied root and its parents.
                string dir = gameRoot ?? "";
                for (int i = 0; i < 4 && !string.IsNullOrWhiteSpace(dir); i++)
                {
                    string candidate = Path.Combine(dir, "kcd.log");
                    if (File.Exists(candidate)) return candidate;
                    dir = Path.GetDirectoryName(dir) ?? "";
                }

                // 2. Steam library scan (the agent's KcdLogLocator logic).
                var logs = new List<FileInfo>();
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
                        if (!name.Contains("Kingdom", StringComparison.OrdinalIgnoreCase) &&
                            !name.Contains("KCD", StringComparison.OrdinalIgnoreCase))
                            continue;
                        try
                        {
                            logs.AddRange(new DirectoryInfo(d)
                                .EnumerateFiles("kcd.log", SearchOption.TopDirectoryOnly));
                        }
                        catch { }
                    }
                }

                return logs.Count == 0
                    ? null
                    : logs.OrderByDescending(f => f.LastWriteTimeUtc).First().FullName;
            }
            catch { return null; }
        }

        private static IEnumerable<string> SteamLibraryRoots()
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
                var m = Regex.Match(line.Trim(), @"""path""\s+""([^""]+)""", RegexOptions.IgnoreCase);
                if (!m.Success) continue;
                string p = m.Groups[1].Value.Replace(@"\\", @"\");
                if (seen.Add(p)) yield return p;
            }
        }
    }
}
