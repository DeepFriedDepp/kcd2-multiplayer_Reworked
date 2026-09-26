using System;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace KCDMP_launcher.Models
{
    /// <summary>
    /// WO-127: runs the agent (KcdMpClient.exe) as a one-shot helper --
    /// --test-connection or --steam-friends -- and returns the one JSON line it
    /// prints after its tag. The agent owns the network and Steam code, so the
    /// launcher never loads Steam itself (a Steam session here would show the
    /// player "in game" for as long as the launcher is open).
    ///
    /// stderr is read and thrown away: steam_api prints the account's SteamID
    /// there, and nothing of it may reach a log. stdout lines other than the
    /// tagged one are ignored for the same reason.
    /// </summary>
    public static class AgentHelper
    {
        private static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };

        public static async Task<T?> RunAsync<T>(string agentPath, string arguments, string tag, TimeSpan timeout) where T : class
        {
            var psi = new ProcessStartInfo
            {
                FileName = agentPath,
                Arguments = arguments,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                WorkingDirectory = Path.GetDirectoryName(agentPath) ?? "",
            };
            using var p = Process.Start(psi);
            if (p is null) return null;
            _ = p.StandardError.ReadToEndAsync();   // discarded on purpose (see above)
            using var cts = new CancellationTokenSource(timeout);
            string? found = null;
            try
            {
                while (await p.StandardOutput.ReadLineAsync(cts.Token) is { } line)
                {
                    if (line.StartsWith(tag + " ", StringComparison.Ordinal)) { found = line[(tag.Length + 1)..]; break; }
                }
            }
            catch (OperationCanceledException) { }
            try { if (!p.HasExited) p.Kill(); } catch { }
            if (found is null) return null;
            try { return JsonSerializer.Deserialize<T>(found, Json); }
            catch { return null; }
        }
    }
}
