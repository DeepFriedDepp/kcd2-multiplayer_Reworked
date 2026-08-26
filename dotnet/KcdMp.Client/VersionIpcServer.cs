using System.Net;
using System.Text;

namespace KcdMp.Client;

/// <summary>
/// WO-19. A local HTTP mirror of this agent's own release version plus
/// whatever release versions have arrived for connected peers, so the
/// launcher can show a friendly "you're behind" notification.
///
/// Built on the same reasoning DiceIpcServer's own doc records: nothing
/// connects the launcher and the agent process after the launcher starts it
/// (see LAUNCHING.md), and the two must still work started independently, so
/// a polled loopback HTTP listener -- the launcher's HttpClient already
/// speaks this, see NetService.GetDedicatedServerInfoAsync -- is the smallest
/// thing that fits. A second listener rather than an extra route on
/// DiceIpcServer, because that one is explicitly a kept-for-testing survivor
/// (see its own doc comment) and this is a live, load-bearing feature.
///
/// GET /version-status -> { "myReleaseVersion": "0.9.5", "peers": [{"ghostId":1,"releaseVersion":"0.9.4"}] }
/// </summary>
public sealed class VersionIpcServer(Func<KeyValuePair<byte, string>[]> getPeers, int port)
{
    private readonly HttpListener _listener = new();
    private CancellationTokenSource? _cts;
    private Task? _loop;

    public void Start()
    {
        _cts = new CancellationTokenSource();
        _listener.Prefixes.Add($"http://localhost:{port}/");
        try
        {
            _listener.Start();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[version-ipc] Could not listen on port {port}: {ex.Message}. " +
                               "The launcher will not be able to show a version-mismatch notice.");
            return;
        }

        Console.WriteLine($"[version-ipc] Listening on http://localhost:{port}/ for the launcher.");
        _loop = RunAsync(_cts.Token);
    }

    public void Stop()
    {
        _cts?.Cancel();
        try { _listener.Stop(); } catch { }
    }

    private async Task RunAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            HttpListenerContext ctx;
            try { ctx = await _listener.GetContextAsync(); }
            catch (Exception) when (ct.IsCancellationRequested) { break; }
            catch (Exception ex) { Console.WriteLine($"[version-ipc] listener error: {ex.Message}"); continue; }

            _ = HandleAsync(ctx);
        }
    }

    /// <summary>Minimal JSON string escaping for our own version strings.</summary>
    private static string JsonEscape(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (char c in s)
        {
            switch (c)
            {
                case '"':  sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                default:
                    if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                    else sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    private async Task HandleAsync(HttpListenerContext ctx)
    {
        try
        {
            var req = ctx.Request;
            var res = ctx.Response;

            if (req.HttpMethod == "GET" && req.Url?.AbsolutePath == "/version-status")
            {
                // WO-58: hand-rolled JSON, deliberately not System.Text.Json.
                // Both testers' shipped 0.17.1 installs failed EVERY request
                // here with "Could not load file or assembly
                // 'System.IO.Pipelines, Version=10.0.0.0'" -- the release
                // folder mixes the launcher's and the agent's self-contained
                // publishes (tools/Publish-Release.ps1 flattens them into one
                // directory, the WO-46 "partial publish" class), so the agent
                // resolves the launcher's System.Text.Json 10 but not its
                // dependency chain. The launcher polled this endpoint every
                // 3 s and got a 500 every time, all session, on both
                // machines: the version-mismatch notice has never worked in
                // the field. The payload is two fields and a flat array;
                // building it by hand removes the failing dependency edge
                // entirely instead of betting on the deploy layout.
                var sb = new StringBuilder(128);
                sb.Append("{\"MyReleaseVersion\":\"").Append(JsonEscape(ReleaseVersionInfo.Current)).Append("\",\"Peers\":[");
                bool first = true;
                foreach (var kv in getPeers())
                {
                    if (!first) sb.Append(',');
                    first = false;
                    sb.Append("{\"GhostId\":").Append(kv.Key)
                      .Append(",\"ReleaseVersion\":\"").Append(JsonEscape(kv.Value)).Append("\"}");
                }
                sb.Append("]}");

                res.StatusCode = 200;
                res.ContentType = "application/json";
                var bytes = Encoding.UTF8.GetBytes(sb.ToString());
                res.ContentLength64 = bytes.Length;
                await res.OutputStream.WriteAsync(bytes);
                res.Close();
                return;
            }

            res.StatusCode = 404;
            res.Close();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[version-ipc] request failed: {ex.Message}");
            try { ctx.Response.StatusCode = 500; ctx.Response.Close(); } catch { }
        }
    }
}

public sealed record VersionStatusDto(string MyReleaseVersion, PeerVersionDto[] Peers);
public sealed record PeerVersionDto(byte GhostId, string ReleaseVersion);
