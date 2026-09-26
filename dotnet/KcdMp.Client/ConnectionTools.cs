using System.Diagnostics;
using System.Text;
using KcdMp.Steam;
using KcdMp.Wire;

namespace KcdMp.Client;

/// <summary>
/// WO-127 Phase 2: the agent's connection state in plain words, for the
/// launcher (GET /connection-status on the version IPC port). The sentence and
/// next step come from <see cref="PlainConnectionError"/>; the raw detail is
/// printed to agent.log (MP-CONN lines) and never served.
/// </summary>
public static class AgentConnectionStatus
{
    private static readonly object Lock = new();
    private static string _state = "starting";   // starting | waiting-for-game | connecting | connected | failed
    private static string _via = "direct";
    private static ConnectionTrouble _kind = ConnectionTrouble.None;
    private static string _message = "", _next = "";
    private static bool _fatal;
    private static int _failures;

    public static string State { get { lock (Lock) return _state; } }

    public static void Set(string state, string via, string message = "", string next = "")
    {
        lock (Lock)
        {
            _state = state; _via = via; _message = message; _next = next;
            if (state == "connected") { _kind = ConnectionTrouble.None; _failures = 0; _fatal = false; }
        }
    }

    /// <summary>A failure: one plain sentence + next step (Steam failures in the WO-127 fallback wording).</summary>
    public static void Fail(string via, ConnectionTrouble kind, string detail, bool fatal, string? theirs = null, string? mine = null)
    {
        var plain = PlainConnectionError.For(kind, theirs, mine);
        string message = via == "steam" ? PlainConnectionError.SteamFallback(kind, theirs, mine) : plain.Sentence;
        string next = via == "steam" ? "" : plain.NextStep;
        lock (Lock)
        {
            _state = "failed"; _via = via; _kind = kind; _message = message; _next = next; _fatal = fatal; _failures++;
        }
        Console.WriteLine($"MP-CONN fail via={via} kind={kind} fatal={(fatal ? 1 : 0)} detail=\"{SteamLogScrub.Scrub(detail)}\"");
    }

    public static string Json()
    {
        lock (Lock)
            return "{" + Js.Str("state", _state) + "," + Js.Str("via", _via) + "," + Js.Str("kind", _kind.ToString()) + ","
                 + Js.Str("message", _message) + "," + Js.Str("next", _next) + ",\"fatal\":" + (_fatal ? "true" : "false")
                 + ",\"failures\":" + _failures + "}";
    }
}

/// <summary>Hand-rolled JSON (WO-58: the agent avoids System.Text.Json on its IPC paths).</summary>
internal static class Js
{
    public static string Esc(string s)
    {
        var sb = new StringBuilder(s.Length + 8);
        foreach (char c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                default:
                    if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                    else sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    public static string Str(string key, string? value) => $"\"{key}\":" + (value is null ? "null" : $"\"{Esc(value)}\"");
}

/// <summary>
/// WO-127 Phase 2: the joiner's Test connection button. Reaches the host on
/// either path and reports reachable / version match / round-trip ms without
/// starting a session: the Handshake carries
/// <see cref="Protocol.ConnectionTestRelease"/>, which every relay answers
/// with 0x3D and a close (ProtocolWo127.cs). Run as
/// <c>KcdMpClient.exe --test-connection (--host h --port p | --steam CODE --steam-app N)</c>;
/// prints one <c>TEST-CONNECTION {json}</c> line.
/// </summary>
public static class ConnectionTest
{
    public sealed record Result(bool Reachable, string Via, int RttMs, int ConnectMs, string? HostRelease, bool VersionMatch,
        bool? HostConnected, int Players, ConnectionTrouble Kind, string Message, string Next, int SteamPingMs, bool? Relayed, string Detail)
    {
        public string ToJson() => "{" + $"\"reachable\":{(Reachable ? "true" : "false")}," + Js.Str("via", Via) + ","
            + $"\"rttMs\":{RttMs},\"connectMs\":{ConnectMs}," + Js.Str("hostRelease", HostRelease) + ","
            + Js.Str("myRelease", ReleaseVersionInfo.Current) + ","
            + $"\"versionMatch\":{(VersionMatch ? "true" : "false")},\"hostConnected\":{(HostConnected is bool h ? (h ? "true" : "false") : "null")},"
            + $"\"players\":{Players}," + Js.Str("kind", Kind.ToString()) + "," + Js.Str("message", Message) + "," + Js.Str("next", Next) + ","
            + $"\"steamPingMs\":{SteamPingMs},\"relayed\":{(Relayed is bool r ? (r ? "true" : "false") : "null")}," + Js.Str("detail", Detail) + "}";
    }

    public static async Task<Result> RunAsync(ClientConfig config, CancellationToken ct)
    {
        bool steam = !string.IsNullOrWhiteSpace(config.SteamCode);
        string via = steam ? "steam" : "direct";
        var sw = Stopwatch.StartNew();
        RelayLink link;
        try
        {
            link = steam
                ? await RelayConnector.ConnectSteamAsync(config.SteamCode!, config.SteamAppId, config.SteamGameExe, PlainConnectionError.SteamRouteTimeout, ct)
                : await RelayConnector.ConnectTcpAsync(config.ServerHost, config.ServerPort, TimeSpan.FromSeconds(6), ct);
        }
        catch (RelayConnectException ex)
        {
            return Failed(via, ex.Kind, ex.Detail, ex.Theirs, ex.Mine);
        }
        int connectMs = (int)sw.ElapsedMilliseconds;
        using (link)
        {
            try
            {
                using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                cts.CancelAfter(TimeSpan.FromSeconds(8));
                var rtt = Stopwatch.StartNew();
                await link.Stream.WriteAsync(RelayConnector.BuildHandshake("connection-test", Protocol.ConnectionTestRelease), cts.Token);
                var (type, body) = await RelayConnector.ReadFrameAsync(link.Stream, cts.Token);
                int rttMs = (int)rtt.ElapsedMilliseconds;
                int steamPing = link.Steam?.PingMs ?? -1;
                bool? relayed = link.Steam is { } sc ? (sc.InfoFlags() & 16) != 0 : null;
                if (type == Protocol.VersionMismatch && body.Length >= 1)
                {
                    var p = PlainConnectionError.For(ConnectionTrouble.ProtocolMismatch, $"protocol v{body[0]}", $"protocol v{Protocol.Version}");
                    return new Result(true, via, rttMs, connectMs, null, false, null, -1, ConnectionTrouble.ProtocolMismatch, p.Sentence, p.NextStep, steamPing, relayed, $"relay protocol v{body[0]}");
                }
                if (type != Protocol.ReleaseVersionMismatch)
                    return Failed(via, ConnectionTrouble.Unknown, $"unexpected reply 0x{type:X2} to a connection test");
                var reply = ConnectionTestReply.Decode(body);
                bool match = reply.Release == ReleaseVersionInfo.Current;
                if (!match)
                {
                    var p = PlainConnectionError.For(ConnectionTrouble.VersionMismatch, reply.Release, ReleaseVersionInfo.Current);
                    return new Result(true, via, rttMs, connectMs, reply.Release, false, reply.HasDetail ? reply.HostConnected : null, reply.Ready,
                        ConnectionTrouble.VersionMismatch, p.Sentence, p.NextStep, steamPing, relayed, "release differs");
                }
                if (reply.HasDetail && !reply.HostConnected)
                {
                    var p = PlainConnectionError.For(ConnectionTrouble.HostNotRunning);
                    return new Result(true, via, rttMs, connectMs, reply.Release, true, false, reply.Ready,
                        ConnectionTrouble.HostNotRunning, p.Sentence, p.NextStep, steamPing, relayed, "relay up, no host agent");
                }
                string ok = $"The host is reachable{(steam ? " through Steam" : "")} and runs the same version ({reply.Release}). Round trip {rttMs} ms.";
                return new Result(true, via, rttMs, connectMs, reply.Release, true, reply.HasDetail ? reply.HostConnected : null, reply.Ready,
                    ConnectionTrouble.None, ok, "", steamPing, relayed, "");
            }
            catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
            {
                return Failed(via, ex is OperationCanceledException ? ConnectionTrouble.TimedOut : PlainConnectionError.Classify(ex),
                    $"test handshake failed: {ex.GetType().Name}: {ex.Message}");
            }
        }
    }

    private static Result Failed(string via, ConnectionTrouble kind, string detail, string? theirs = null, string? mine = null)
    {
        var p = PlainConnectionError.For(kind, theirs, mine);
        string msg = via == "steam" ? PlainConnectionError.SteamFallback(kind, theirs, mine) : p.Sentence;
        return new Result(false, via, -1, -1, null, false, null, -1, kind, msg, via == "steam" ? "" : p.NextStep, -1, null, SteamLogScrub.Scrub(detail));
    }
}

/// <summary>
/// WO-127 Phase 1: the launcher's "pick a Steam friend who is hosting". Run as
/// <c>KcdMpClient.exe --steam-friends --steam-app N</c>; prints one
/// <c>STEAM-FRIENDS {json}</c> line with each hosting friend's persona name,
/// join code and release, for the launcher's screen only. Nothing here is
/// written to a log. Works only where Steam shows rich presence, i.e. both
/// players under the same app id.
/// </summary>
public static class SteamFriendsList
{
    public static async Task<string> RunAsync(ClientConfig config)
    {
        SteamSession s;
        try { s = RelayConnector.StartSession(config.SteamAppId, config.SteamGameExe, null); }
        catch (RelayConnectException ex)
        {
            var p = PlainConnectionError.For(ex.Kind, ex.Theirs, ex.Mine);
            return "{" + Js.Str("state", "failed") + "," + Js.Str("message", p.Sentence) + "," + Js.Str("next", p.NextStep) + ",\"friends\":[]}";
        }
        using (s)
        {
            s.FriendsInThisApp(SteamApps.PresenceKey);   // asks Steam for every friend's presence
            await Task.Delay(2000);                        // the answers arrive as callbacks
            var sb = new StringBuilder();
            sb.Append('{').Append(Js.Str("state", "ok")).Append(',').Append(Js.Str("app", SteamApps.Name(config.SteamAppId))).Append(",\"friends\":[");
            bool first = true;
            foreach (var (id, persona, value) in s.FriendsWithPresence(SteamApps.PresenceKey))
            {
                if (!value.StartsWith("host;", StringComparison.Ordinal)) continue;
                if (!first) sb.Append(',');
                first = false;
                sb.Append('{').Append(Js.Str("name", persona)).Append(',')
                  .Append(Js.Str("code", SteamJoinCode.Encode(id, config.SteamAppId))).Append(',')
                  .Append(Js.Str("release", value[5..])).Append('}');
            }
            sb.Append("]}");
            return sb.ToString();
        }
    }
}
