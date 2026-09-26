using System.Diagnostics;
using KcdMp.Steam;
using KcdMp.SteamProbe;

// WO-120 Phase 0: does a Steam route connect two machines on two different
// internet connections? One Steam app id per process is Steam's rule, so the
// parent runs one child process per candidate app id and collects what they
// print into a report file. Nothing identifying reaches the file: no Steam
// ids, no names, no addresses. Lines starting CONSOLE: stay on screen only.

const string ProbeVersion = "wo120-probe-1";
uint[] defaultApps = [2429020, 480, 1771300]; // Modding Tools (the game's own), Spacewar, retail KCD2

var argList = args.ToList();
string? Opt(string name) { int i = argList.IndexOf(name); return i >= 0 && i + 1 < argList.Count ? argList[i + 1] : null; }
bool Flag(string name) => argList.Contains(name);

if (Opt("--child") is { } childRole)
    return await ChildAsync(childRole);

if (Flag("--selftest"))
    return SelfTest();

string role;
string? code = Opt("--code");
if (argList.Count > 0 && argList[0] is "host" or "join" or "check")
{
    role = argList[0];
    if (role == "join" && code is null && argList.Count > 1 && !argList[1].StartsWith("--")) code = argList[1];
}
else
{
    Console.WriteLine("KCD2 Multiplayer - Steam connection test");
    Console.WriteLine();
    Console.WriteLine("  1) I'm hosting (my friend will join me)");
    Console.WriteLine("  2) I'm joining (my friend gave me a code)");
    Console.WriteLine("  3) Just check this computer");
    Console.WriteLine();
    Console.Write("Type 1, 2 or 3 and press Enter: ");
    role = Console.ReadLine()?.Trim() switch { "1" => "host", "2" => "join", _ => "check" };
}

if (role == "join")
{
    while (!FriendCode.TryDecode(code, out _))
    {
        if (code is not null) Console.WriteLine("That code isn't right. It looks like ABCD-EFG.");
        Console.Write("Type the code your friend sent you: ");
        code = Console.ReadLine();
        if (code is null) return 1;
    }
}

var apps = (Opt("--apps") ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries).Select(uint.Parse).ToArray();
if (apps.Length == 0) apps = defaultApps;
int seconds = int.TryParse(Opt("--seconds"), out var sec) ? sec : 60;
string api = Opt("--api") ?? "all";

string stamp = DateTime.UtcNow.ToString("yyyyMMdd-HHmmss");
string reportPath = Path.Combine(AppContext.BaseDirectory, $"wo120-probe-{role}-{stamp}.txt");
using var report = new StreamWriter(reportPath) { AutoFlush = true };
void Both(string line) { Console.WriteLine(line); report.WriteLine(line); }

Both($"WO120 report probe={ProbeVersion} role={role} utc={stamp} os={Environment.OSVersion.Version} apps={string.Join(',', apps)} game_seconds={seconds} api={api}");
Both($"WO120 game_running_at_start={(GameRunning() ? 1 : 0)} steam_dll={(SteamLibraryLocator.Find() is null ? "missing" : "found")}");

if (role == "host")
{
    // Show the code first, from whichever app id starts (the code is the same under all of them).
    foreach (var app in apps)
        if (await RunChildAsync(["--child", "whoami", "--app", app.ToString()], Both) == 0) break;
    Console.WriteLine();
    Console.WriteLine("Send the code above to your friend. Leave this window open.");
    Console.WriteLine();
}

int passes = 0;
foreach (var app in apps)
{
    Both("");
    Both($"WO120 ---- app {app} ----");
    string[] childArgs = role switch
    {
        "host" => ["--child", "host", "--app", app.ToString(), "--wait", Opt("--wait") ?? "300"],
        "join" => ["--child", "join", "--app", app.ToString(), "--code", code!, "--seconds", seconds.ToString(), "--api", api],
        _      => ["--child", "check", "--app", app.ToString()],
    };
    if (await RunChildAsync(childArgs, Both) == 0) passes++;
}

Both("");
Both($"WO120 summary role={role} apps_ok={passes}/{apps.Length}");
Console.WriteLine();
Console.WriteLine("Finished. Please send this file to the maintainer:");
Console.WriteLine("  " + reportPath);
if (argList.Count == 0) { Console.WriteLine("Press Enter to close."); Console.ReadLine(); }
return 0;

// ---------------------------------------------------------------------------

// Offline: the friend code and the log scrubber, on random ids generated here
// (no real or example Steam id is written down anywhere, per the WO-120 privacy rule).
static int SelfTest()
{
    var rng = new Random();
    const string alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    int roundTrip = 0, typoCaught = 0, typos = 0, failures = 0;
    for (int i = 0; i < 100_000; i++)
    {
        uint account = (uint)rng.NextInt64(1, uint.MaxValue);
        ulong id = 0x0110000100000000UL | account;
        string c = FriendCode.Encode(id);
        if (FriendCode.TryDecode(c, out var back) && back == id && FriendCode.TryDecode(c.ToLowerInvariant().Replace("-", " "), out back) && back == id) roundTrip++;
        else failures++;
        var chars = c.Replace("-", "").ToCharArray();
        int pos = rng.Next(7);
        char orig = chars[pos];
        do chars[pos] = alphabet[rng.Next(32)]; while (chars[pos] == orig);
        typos++;
        if (!FriendCode.TryDecode(new string(chars), out var t) || t == id) typoCaught++;
        string ip = $"{rng.Next(1, 255)}.{rng.Next(256)}.{rng.Next(256)}.{rng.Next(1, 255)}";
        string line = $"P2P steamid:{id} timed out via {ip}:{rng.Next(1024, 65535)} [U:1:{account}] {id}";
        string scrubbed = SteamLogScrub.Scrub(line);
        if (scrubbed.Contains(account.ToString()) || scrubbed.Contains(ip)) failures++;
    }
    Console.WriteLine($"WO120 selftest round_trip={roundTrip}/100000 single_char_typos_caught={typoCaught}/{typos} ({100.0 * typoCaught / typos:0.0}%) scrub_leaks_or_failures={failures}");
    Console.WriteLine($"WO120 selftest scrub_sample=\"{SteamLogScrub.Scrub($"P2P steamid:{new string('9', 17)} timed out via {string.Join('.', Enumerable.Repeat(rng.Next(1, 255), 4))}:27015")}\"");
    return failures == 0 ? 0 : 1;
}

static bool GameRunning() => Process.GetProcessesByName("KingdomCome").Length > 0;

static async Task<int> RunChildAsync(string[] childArgs, Action<string> both)
{
    var psi = new ProcessStartInfo(Environment.ProcessPath!) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
    foreach (var a in childArgs) psi.ArgumentList.Add(a);
    using var p = Process.Start(psi)!;
    var err = p.StandardError.ReadToEndAsync();
    string? line;
    while ((line = await p.StandardOutput.ReadLineAsync()) is not null)
    {
        if (line.StartsWith("CODE:")) { Console.WriteLine(); Console.WriteLine("    Your code:  " + line[5..]); continue; }
        if (line.StartsWith("CONSOLE:")) { Console.WriteLine(line[8..]); continue; }
        both(line);
    }
    await p.WaitForExitAsync();
    string e = (await err).Trim();
    if (e.Length > 0) both("WO120 child_stderr " + SteamLogScrub.Scrub(e.Replace(Environment.NewLine, " | ")));
    both($"WO120 child={childArgs[1]} app={childArgs[3]} exit={p.ExitCode}");
    return p.ExitCode;
}

async Task<int> ChildAsync(string childRole)
{
    uint app = uint.Parse(Opt("--app") ?? "2429020");
    var session = SteamSession.TryStart(app, out var failure, out var detail);
    if (session is null)
    {
        Out.Line($"WO120 {childRole} app={app} init=FAIL failure={failure} detail=\"{SteamLogScrub.Scrub(detail)}\"");
        return 2;
    }
    using var s = session;
    s.Log += l => Out.Line("WO120 steam_log " + l);
    Out.Line($"WO120 {childRole} app={app} init=OK reported_app={s.AppId} game_running={(GameRunning() ? 1 : 0)}");

    if (childRole == "whoami")
    {
        Out.Line("CODE:" + FriendCode.Encode(s.LocalSteamId));
        return 0;
    }

    var ready = Stopwatch.StartNew();
    bool ok = await s.WaitNetworkReadyAsync(TimeSpan.FromSeconds(30), CancellationToken.None);
    int relay = s.RelayAvailability(out string relayDebug);
    Out.Line($"WO120 {childRole} app={app} network_ready={(ok ? 1 : 0)} ready_ms={ready.ElapsedMilliseconds} relay={SteamSession.AvailabilityName(relay)} auth={SteamSession.AvailabilityName(s.AuthenticationAvailability())}{(ok ? "" : $" relay_debug=\"{relayDebug}\"")}");

    switch (childRole)
    {
        case "check":
        {
            using var l = s.Listen(F.VirtualPort);
            Out.Line($"WO120 check app={app} listen=OK friends_bucket={(s.FriendCount() switch { 0 => "0", < 10 => "1-9", < 50 => "10-49", _ => "50+" })}");
            // WO-127 Phase 0: rich presence round trip on this account (set, read our own key back).
            bool rpSet = s.SetRichPresence("kcdmp", "check");
            await Task.Delay(500);
            string? rpBack = s.OwnRichPresence("kcdmp");
            Out.Line($"WO120 check app={app} rich_presence_set={(rpSet ? 1 : 0)} read_back={(rpBack == "check" ? "match" : rpBack is null ? "empty" : "other")}");
            s.ClearRichPresence();
            return ok ? 0 : 5;
        }
        case "host":
            return await ProbeHost.RunAsync(s, TimeSpan.FromSeconds(int.Parse(Opt("--wait") ?? "300")), CancellationToken.None);
        case "join":
        {
            ulong host;
            if (Flag("--self")) host = s.LocalSteamId;
            else if (!FriendCode.TryDecode(Opt("--code"), out host)) { Out.Line("WO120 join bad_code"); return 1; }
            return await ProbeJoin.RunAsync(s, host, int.Parse(Opt("--seconds") ?? "60"), Opt("--api") ?? "all", CancellationToken.None);
        }
    }
    return 1;
}
