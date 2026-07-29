using System.Net;
using System.Text.Json;

namespace KcdMp.Client;

/// <summary>
/// A localhost debug mirror of this agent's dice state.
///
/// WO-6 NOTE ON ITS ROLE. This was built as the channel to KCDMP_launcher's
/// dice window; that window is gone (dice is played in game now, see
/// docs/WO-6-overlay-design.md) and nothing in the launcher polls this any
/// more. It is deliberately KEPT rather than deleted, for one concrete reason:
/// it is the only way to observe a real agent's dice state without a running
/// game, and that is exactly how WO-5 verified the agent-side dice code with
/// two real KcdMpClient processes and a synthetic wire peer (WO-5-dice.md,
/// "What was verified"). Deleting it would delete a proven headless test
/// surface to save an idle HttpListener on loopback.
///
/// So: not half-wired, deliberately unwired on the launcher side. If it ever
/// needs to go, the WO-5 IPC smoke test goes with it.
///
/// The original rationale for the shape below, unchanged:
///
/// Nothing connected the two processes before WO-5: the launcher starts the
/// agent as a bare subprocess and
/// never reads or writes anything from it afterward, and the two are meant to
/// work when started completely independently too ("a manually started
/// launcher beside a manually started agent"), which rules out anything
/// riding the parent/child relationship (piped stdio, inherited handles).
///
/// A local HTTP listener, polled the same way the launcher already polls the
/// relay's own /api/information (see NetService.GetDedicatedServerInfoAsync),
/// is the smallest thing that fits both constraints: no new dependency (
/// HttpListener is BCL), works regardless of start order, and reuses a
/// request/response shape the launcher's HttpClient already speaks.
///
/// GET  /dice          -> current DiceIpcSnapshotDto
/// POST /dice/respond  -> { "accept": bool }
/// POST /dice/intent   -> { "type": "roll"|"keep"|"bank"|"forfeit", "mask": byte? }
/// </summary>
public sealed class DiceIpcServer(DiceIpcState state, int port)
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

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
            Console.WriteLine($"[dice-ipc] Could not listen on port {port}: {ex.Message}. " +
                               "The launcher's dice window will not be able to reach this agent.");
            return;
        }

        Console.WriteLine($"[dice-ipc] Listening on http://localhost:{port}/ for the launcher.");
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
            catch (Exception ex) { Console.WriteLine($"[dice-ipc] listener error: {ex.Message}"); continue; }

            _ = HandleAsync(ctx);
        }
    }

    private async Task HandleAsync(HttpListenerContext ctx)
    {
        try
        {
            var req = ctx.Request;
            var res = ctx.Response;

            if (req.HttpMethod == "GET" && req.Url?.AbsolutePath == "/dice")
            {
                await WriteJsonAsync(res, 200, state.GetSnapshot());
                return;
            }

            if (req.HttpMethod == "POST" && req.Url?.AbsolutePath == "/dice/respond")
            {
                var body = await JsonSerializer.DeserializeAsync<RespondRequest>(req.InputStream, JsonOptions);
                if (body is null) { await WriteJsonAsync(res, 400, new { error = "bad request" }); return; }
                bool ok = await state.RespondAsync(body.Accept);
                await WriteJsonAsync(res, 200, new { ok });
                return;
            }

            if (req.HttpMethod == "POST" && req.Url?.AbsolutePath == "/dice/intent")
            {
                var body = await JsonSerializer.DeserializeAsync<IntentRequest>(req.InputStream, JsonOptions);
                if (body?.Type is null) { await WriteJsonAsync(res, 400, new { error = "bad request" }); return; }

                switch (body.Type.ToLowerInvariant())
                {
                    case "roll": await state.RollAsync(); break;
                    case "keep": await state.KeepAsync(body.Mask ?? 0); break;
                    case "bank": await state.BankAsync(); break;
                    case "forfeit": await state.ForfeitAsync(); break;
                    default:
                        await WriteJsonAsync(res, 400, new { error = $"unknown intent '{body.Type}'" });
                        return;
                }
                await WriteJsonAsync(res, 200, new { ok = true });
                return;
            }

            res.StatusCode = 404;
            res.Close();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[dice-ipc] request failed: {ex.Message}");
            try { ctx.Response.StatusCode = 500; ctx.Response.Close(); } catch { }
        }
    }

    private static async Task WriteJsonAsync(HttpListenerResponse res, int statusCode, object body)
    {
        res.StatusCode = statusCode;
        res.ContentType = "application/json";
        var bytes = JsonSerializer.SerializeToUtf8Bytes(body);
        res.ContentLength64 = bytes.Length;
        await res.OutputStream.WriteAsync(bytes);
        res.Close();
    }

    private sealed class RespondRequest { public bool Accept { get; set; } }
    private sealed class IntentRequest { public string? Type { get; set; } public byte? Mask { get; set; } }
}
