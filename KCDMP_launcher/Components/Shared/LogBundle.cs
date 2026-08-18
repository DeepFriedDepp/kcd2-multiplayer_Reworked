using System;
using System.IO;
using System.IO.Compression;
using System.Linq;

namespace KCDMP_launcher.Components.Shared
{
    /// <summary>
    /// WO-39, item K: the tester diagnostics bundle. WO-38's real two-player
    /// test produced logs with ZERO game telemetry in them -- the testers sent
    /// the launcher's app.log because that was the only file they knew about,
    /// while everything that mattered (kcd.log, the agent console) was never
    /// collected. This gathers every diagnostic surface into one zip a tester
    /// can just hand over.
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

            if (!string.IsNullOrWhiteSpace(gameRoot))
                AddIfPresent(Path.Combine(gameRoot, "kcd.log"), "kcd.log");

            if (!string.IsNullOrWhiteSpace(agentDirectory))
            {
                AddIfPresent(Path.Combine(agentDirectory, "agent.log"), "agent.log");
                AddIfPresent(Path.Combine(agentDirectory, "agent.prev.log"), "agent.prev.log");
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

            AddIfPresent(Globals.ConfigFilePath, "config.json");

            return zipPath;
        }
    }
}
