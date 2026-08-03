using System.Diagnostics;

namespace KCDMP_launcher.Components.Shared
{
    /// <summary>
    /// Opens a URL via the OS's own default handler (browser, or Discord's own
    /// app if it has claimed discord.gg links) rather than the launcher trying
    /// to embed or parse it. Shared by ReportBugModal and
    /// VersionMismatchModal (WO-19).
    /// </summary>
    public static class UrlLauncher
    {
        public static void Open(string url)
        {
            try
            {
                Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });
            }
            catch (Exception ex)
            {
                Log.Warning(ex, $"Could not open {url}");
            }
        }
    }
}
