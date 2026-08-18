using KcdMp.Client;
using Microsoft.Win32;
using System.Text.RegularExpressions;

// Settings live in kcdmp-client.json next to the executable; it is created with
// defaults on first run. Everything can still be overridden on the command line:
//   named:      --host <ip> --port <n> --name <s> --game-api <url> [--no-voice]
//   positional: <serverHost> <serverPort> <name> <gameApiBase>   (legacy form)
var config = ClientConfig.Load();
config.ApplyCommandLine(args);

// WO-39 (item K): tee everything the agent prints into agent.log next to the
// executable. WO-38's real testers sent logs containing ZERO game telemetry
// because the agent's console -- where every [combat]/[npcsync]/[timeskip]/
// [playerhit] line goes -- was never captured anywhere. The console keeps
// working exactly as before; the launcher's "collect logs" bundle picks the
// file up. Failure to open the file must never stop the agent: worst case we
// are back to today's console-only behaviour.
try
{
    string agentLogPath = Path.Combine(AppContext.BaseDirectory, "agent.log");
    // One log per run, capped history: rotate the previous run's log aside.
    if (File.Exists(agentLogPath))
        File.Copy(agentLogPath, Path.ChangeExtension(agentLogPath, ".prev.log"), overwrite: true);
    var teeStream = new StreamWriter(agentLogPath, append: false) { AutoFlush = true };
    Console.SetOut(new TeeTextWriter(Console.Out, teeStream));
    Console.WriteLine($"[log] agent output tee -> {agentLogPath}");
}
catch (Exception ex)
{
    Console.WriteLine($"[log] file logging unavailable: {ex.Message}");
}

// --benchmark measures the game channel and exits; it never touches the relay,
// so it needs no name resolution and no server.
if (args.Contains("--benchmark"))
{
    using var benchCts = new CancellationTokenSource();
    Console.CancelKeyPress += (_, e) => { e.Cancel = true; benchCts.Cancel(); };
    return await TransportBenchmark.RunAsync(config, benchCts.Token);
}

// An empty name means auto-detect.
if (string.IsNullOrWhiteSpace(config.PlayerName))
    config.PlayerName =
        GetSteamNameFromKcdLog()     // primary: kcd.log written by KCD2's own Steam API
        ?? GetSteamPersonaName()     // fallback: loginusers.vdf
        ?? Environment.MachineName;  // last resort

// ---------------------------------------------------------------------------
// Find all Steam library paths via libraryfolders.vdf, then look for
// KCD2's kcd.log (which contains the line user_id=STEAMID='PersonaName').
// ---------------------------------------------------------------------------
static string? GetSteamNameFromKcdLog()
{
    try
    {
        // This used to hardcode steamapps\common\KingdomComeDeliverance2, which
        // misses the Modding Tools install (KCD2Mod) -- the one actually launched
        // for modding -- and so silently fell through to the loginusers.vdf
        // fallback. KcdLogLocator scans every library and takes the newest log.
        string? logPath = KcdLogLocator.Find();
        Console.WriteLine($"[KcdLog] kcd.log = {logPath ?? "(not found)"}");
        if (logPath is null) return null;

        var nameRe = new Regex(@"user_id=\d+='([^']+)'");

        // The running game keeps kcd.log open, so File.ReadLines throws
        // "used by another process". Open it shared instead.
        using var stream = new FileStream(logPath, FileMode.Open, FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream);

        int n = 0;
        while (reader.ReadLine() is { } line)
        {
            var m = nameRe.Match(line);
            if (m.Success)
            {
                Console.WriteLine($"[KcdLog] Found Steam name: {m.Groups[1].Value}");
                return m.Groups[1].Value;
            }
            if (++n > 500) break;
        }
    }
    catch (Exception ex) { Console.WriteLine($"[KcdLog] Error: {ex.Message}"); }
    return null;
}

// ---------------------------------------------------------------------------
// Parse Steam's loginusers.vdf: prefer AutoLoginUser, fall back to MostRecent.
// ---------------------------------------------------------------------------
static string? GetSteamPersonaName()
{
    try
    {
        string? steamPath =
            Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath", null) as string
            ?? Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Valve\Steam",           "InstallPath", null) as string;

        string? autoLogin =
            Registry.GetValue(@"HKEY_CURRENT_USER\SOFTWARE\Valve\Steam", "AutoLoginUser", null) as string;

        Console.WriteLine($"[Steam] VDF InstallPath={steamPath ?? "(not found)"}  AutoLoginUser={autoLogin ?? "(not found)"}");
        if (steamPath is null) return null;

        string vdfPath = Path.Combine(steamPath, "config", "loginusers.vdf");
        if (!File.Exists(vdfPath)) { Console.WriteLine("[Steam] loginusers.vdf not found"); return null; }

        int depth = 0;
        string? curPersona = null;
        bool curIsAutoLogin = false, curIsMostRecent = false;
        string? bestPersona = null, recentPersona = null;
        var kvRe = new Regex(@"^""([^""]+)""\s+""([^""]*)""$");

        foreach (string raw in File.ReadLines(vdfPath))
        {
            string line = raw.Trim();
            if (line == "{") { depth++; continue; }
            if (line == "}")
            {
                if (depth == 2)
                {
                    if (curIsAutoLogin  && curPersona != null) bestPersona   = curPersona;
                    if (curIsMostRecent && curPersona != null) recentPersona = curPersona;
                    curPersona = null; curIsAutoLogin = false; curIsMostRecent = false;
                }
                depth--;
                continue;
            }
            if (depth != 2) continue;
            var m = kvRe.Match(line);
            if (!m.Success) continue;
            string key = m.Groups[1].Value, val = m.Groups[2].Value;
            if (key.Equals("PersonaName", StringComparison.OrdinalIgnoreCase)) curPersona = val;
            if (key.Equals("MostRecent",  StringComparison.OrdinalIgnoreCase) && val == "1") curIsMostRecent = true;
            if (key.Equals("AccountName", StringComparison.OrdinalIgnoreCase)
                && autoLogin != null && val.Equals(autoLogin, StringComparison.OrdinalIgnoreCase))
                curIsAutoLogin = true;
        }

        string? result = bestPersona ?? recentPersona;
        Console.WriteLine($"[Steam] PersonaName = {result ?? "(not found)"}");
        return result;
    }
    catch (Exception ex) { Console.WriteLine($"[Steam] Error: {ex.Message}"); }
    return null;
}

Console.WriteLine("=== KCD2 Multiplayer Client Agent ===");
Console.WriteLine($"Server   : {config.ServerHost}:{config.ServerPort}");
Console.WriteLine($"Name     : {config.PlayerName}");
Console.WriteLine($"Game     : {config.GameApiBase}");
Console.WriteLine($"Voice    : {(config.VoiceChatEnabled ? "on" : "off")}");
Console.WriteLine($"Protocol : v{Protocol.Version}");
Console.WriteLine();

using var cts = new CancellationTokenSource();

// Graceful shutdown on Ctrl+C or window close — gives finally blocks time to clean up ghosts.
Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };
AppDomain.CurrentDomain.ProcessExit += (_, _) => { cts.Cancel(); Thread.Sleep(500); };

var bridge = new GameBridge(config);
await bridge.RunAsync(cts.Token);
return 0;
