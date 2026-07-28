using System.Net.Http;
using System.Net.Http.Json;
using KCDMP_launcher.Models;

namespace KCDMP_launcher.Services
{
    /// <summary>
    /// Polls the agent's local dice IPC endpoint (dotnet/KcdMp.Client/DiceIpcServer.cs)
    /// and raises <see cref="SnapshotChanged"/> whenever it changes, so a Razor
    /// component just subscribes and calls StateHasChanged -- the same shape as
    /// UiService's OnShowError.
    ///
    /// Polling rather than pushing: the agent may not even be running yet when
    /// the launcher starts (or may already be running when the launcher is the
    /// one that starts later), and a poll loop needs nothing from either side
    /// beyond "is something answering on this port right now".
    /// </summary>
    public sealed class DiceIpcClient : IDisposable
    {
        private const int PollIntervalMs = 700;

        private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(2) };
        private readonly PeriodicTimer _timer = new(TimeSpan.FromMilliseconds(PollIntervalMs));
        private readonly CancellationTokenSource _cts = new();
        private readonly Task _pollLoop;

        private int _port = 5901;
        private DiceIpcSnapshot? _last;

        /// <summary>Fires whenever a poll returns a snapshot that differs from the last one (or the agent becomes unreachable).</summary>
        public event Action<DiceIpcSnapshot?>? SnapshotChanged;

        public DiceIpcClient()
        {
            _pollLoop = PollLoopAsync(_cts.Token);
        }

        /// <summary>Points the poller at the agent's configured port. Safe to call any time; takes effect on the next tick.</summary>
        public void SetPort(int port) => _port = port;

        public DiceIpcSnapshot? Current => _last;

        public async Task<bool> RespondAsync(bool accept)
        {
            try
            {
                var res = await _http.PostAsJsonAsync($"http://localhost:{_port}/dice/respond", new { accept });
                return res.IsSuccessStatusCode;
            }
            catch (Exception ex)
            {
                Log.Error(ex, "[dice-ipc] respond failed");
                return false;
            }
        }

        public Task<bool> RollAsync() => SendIntentAsync("roll");
        public Task<bool> KeepAsync(byte mask) => SendIntentAsync("keep", mask);
        public Task<bool> BankAsync() => SendIntentAsync("bank");
        public Task<bool> ForfeitAsync() => SendIntentAsync("forfeit");

        private async Task<bool> SendIntentAsync(string type, byte? mask = null)
        {
            try
            {
                var res = await _http.PostAsJsonAsync($"http://localhost:{_port}/dice/intent", new { type, mask });
                return res.IsSuccessStatusCode;
            }
            catch (Exception ex)
            {
                Log.Error(ex, $"[dice-ipc] intent '{type}' failed");
                return false;
            }
        }

        private async Task PollLoopAsync(CancellationToken ct)
        {
            try
            {
                while (await _timer.WaitForNextTickAsync(ct))
                {
                    DiceIpcSnapshot? snapshot = null;
                    try
                    {
                        snapshot = await _http.GetFromJsonAsync<DiceIpcSnapshot>($"http://localhost:{_port}/dice", ct);
                    }
                    catch (OperationCanceledException) { throw; }
                    catch
                    {
                        // Agent not running, or not up yet -- not an error worth
                        // logging every 700ms. No dice UI to show either way.
                    }

                    if (!SnapshotsEqual(snapshot, _last))
                    {
                        _last = snapshot;
                        SnapshotChanged?.Invoke(snapshot);
                    }
                }
            }
            catch (OperationCanceledException) { }
        }

        private static bool SnapshotsEqual(DiceIpcSnapshot? a, DiceIpcSnapshot? b)
        {
            if (a is null && b is null) return true;
            if (a is null || b is null) return false;

            return a.Invite?.SessionId == b.Invite?.SessionId
                && a.Session?.SessionId == b.Session?.SessionId
                && a.Session?.CurrentPlayerRole == b.Session?.CurrentPlayerRole
                && a.Session?.TurnTotal == b.Session?.TurnTotal
                && a.Session?.Phase == b.Session?.Phase
                && (a.Session?.FreeFaces ?? []).SequenceEqual(b.Session?.FreeFaces ?? [])
                && (a.Session?.KeptFaces ?? []).SequenceEqual(b.Session?.KeptFaces ?? [])
                && a.Session?.LastError == b.Session?.LastError
                && a.Session?.Result?.Outcome == b.Session?.Result?.Outcome;
        }

        public void Dispose()
        {
            _cts.Cancel();
            try { _pollLoop.Wait(TimeSpan.FromSeconds(1)); } catch { }
            _timer.Dispose();
            _cts.Dispose();
            _http.Dispose();
        }
    }
}
