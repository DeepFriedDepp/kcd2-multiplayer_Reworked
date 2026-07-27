using System.Diagnostics;

namespace KcdMp.Client;

/// <summary>
/// Measures the game-to-agent channel: the WO-1 baseline that any replacement
/// has to beat.
///
/// Reports latency percentiles rather than averages. The mean is the wrong
/// summary here -- the sync loop's smoothness is set by how bad the slow ticks
/// are, and an occasional 200 ms stall is what players actually see, so p95 and
/// p99 are the numbers that matter.
///
/// Run with: KcdMpClient.exe --benchmark
/// </summary>
public static class TransportBenchmark
{
    private sealed record Result(string Label, string Unit, List<double> Samples, int Failures)
    {
        public double P(double q)
        {
            if (Samples.Count == 0) return double.NaN;
            var s = Samples.OrderBy(v => v).ToList();
            int i = (int)Math.Ceiling(q / 100.0 * s.Count) - 1;
            return s[Math.Clamp(i, 0, s.Count - 1)];
        }
        public double Min  => Samples.Count == 0 ? double.NaN : Samples.Min();
        public double Max  => Samples.Count == 0 ? double.NaN : Samples.Max();
        public double Mean => Samples.Count == 0 ? double.NaN : Samples.Average();
    }

    public static async Task<int> RunAsync(ClientConfig config, CancellationToken ct = default)
    {
        Console.WriteLine("=== KCD2-MP transport benchmark (WO-1 baseline) ===");
        Console.WriteLine($"Game API : {config.GameApiBase}");
        Console.WriteLine();

        await using var transport = new HttpGameTransport(config.GameApiBase);

        // The very first request pays TCP connect and can take seconds against a
        // busy game -- measured at ~2.2 s cold versus ~40 ms warm -- which blows
        // the transport's 800 ms per-call timeout. Retry rather than declaring
        // the game absent, the same way the agent's 3 s poll loop rides it out.
        Console.Write("Checking the game is up with a save loaded... ");
        bool ready = false;
        for (int attempt = 1; attempt <= 5 && !ready && !ct.IsCancellationRequested; attempt++)
        {
            ready = await transport.IsGameReadyAsync(ct);
            if (!ready)
            {
                Console.Write($"[retry {attempt}] ");
                await Task.Delay(1000, ct);
            }
        }
        if (!ready)
        {
            Console.WriteLine("NO");
            Console.WriteLine();
            Console.WriteLine("The benchmark needs KCD2 running through the Modding Tools entry");
            Console.WriteLine("with a save loaded (the debug API returns nothing on the main menu).");
            return 1;
        }
        Console.WriteLine("yes");
        Console.WriteLine();

        // Warm up so the cold-connect cost does not land in the samples as a
        // fake outlier.
        for (int i = 0; i < 5; i++)
            await transport.ReadPositionOnlyAsync(ct);

        var results = new List<Result>();

        results.Add(await MeasureAsync("noop ExecuteString", "ms", 100, ct,
            async () => { await transport.ExecuteAsync("local _=1", ct); return true; }));

        results.Add(await MeasureAsync("position read (1 RT)", "ms", 100, ct,
            async () => await transport.ReadPositionOnlyAsync(ct) is not null));

        results.Add(await MeasureAsync("rot+ride CVar cycle (2 RT)", "ms", 100, ct,
            async () => await transport.ReadRotStateAsync(ct) is not null));

        results.Add(await MeasureAsync("full state, uncached (3 RT)", "ms", 60, ct,
            async () => await transport.ReadPlayerStateUncachedAsync(ct) is not null));

        // What the agent actually does: position each tick, yaw and mount state
        // from the background loop. Start that loop so this is the real path.
        await transport.StartAsync(ct);
        await Task.Delay(200, ct);
        results.Add(await MeasureAsync("full state, cached rot (1 RT)", "ms", 100, ct,
            async () => await transport.ReadPlayerStateAsync(ct) is not null));

        // Option (d): does coalescing N statements into one ExecuteString beat
        // N separate calls? This is the cheap fallback the work order names, so
        // it is worth knowing what it actually buys before building anything.
        foreach (int batch in new[] { 5, 20 })
        {
            string joined = string.Join(" ", Enumerable.Repeat("local _=1", batch));
            results.Add(await MeasureAsync($"batched ExecuteString x{batch}", "ms", 40, ct,
                async () => { await transport.ExecuteAsync(joined, ct); return true; }));
        }

        Report(results, transport);

        // Sustained rate: how many full state reads per second the channel
        // supports back to back. The position loop currently ticks at 10 ms,
        // so anything under 100/s means the loop is transport-bound.
        Console.WriteLine();
        Console.Write("Measuring sustained state-read rate for 5 s... ");
        int ok = 0, fail = 0;
        var sw = Stopwatch.StartNew();
        while (sw.Elapsed < TimeSpan.FromSeconds(5) && !ct.IsCancellationRequested)
        {
            if (await transport.ReadPlayerStateAsync(ct) is not null) ok++; else fail++;
        }
        sw.Stop();
        Console.WriteLine("done");
        Console.WriteLine($"  full state reads : {ok / sw.Elapsed.TotalSeconds:F1}/s  ({ok} ok, {fail} failed)");
        Console.WriteLine($"  implied ceiling  : {ok / sw.Elapsed.TotalSeconds * 3:F0} HTTP round trips/s");

        double httpRate = ok / sw.Elapsed.TotalSeconds;
        double httpP50 = results.First(r => r.Label.StartsWith("full state, cached")).P(50);

        await RunLogTailAsync(transport, httpRate, httpP50, ct);
        return 0;
    }

    /// <summary>
    /// Measures the log-tail transport and puts it beside the HTTP baseline.
    ///
    /// Skips cleanly when the mod is not loaded or the emitter is absent: the
    /// pak has to be rebuilt for KCD2MP_StartEmitter to exist, so a missing
    /// emitter is an expected state rather than a failure.
    /// </summary>
    private static async Task RunLogTailAsync(
        HttpGameTransport http, double httpRate, double httpP50, CancellationToken ct)
    {
        Console.WriteLine();
        Console.WriteLine("=== log-tail transport ===");

        LogTailGameTransport tail;
        try
        {
            tail = LogTailGameTransport.Create(http);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"  skipped: {ex.Message}");
            return;
        }

        Console.WriteLine($"  tailing {tail.LogPath}");
        await using (tail)
        {
            await tail.StartAsync(ct);

            Console.Write("  waiting for the emitter to produce frames... ");
            var deadline = DateTime.UtcNow.AddSeconds(5);
            while (tail.FramesReceived == 0 && DateTime.UtcNow < deadline && !ct.IsCancellationRequested)
                await Task.Delay(50, ct);

            if (tail.FramesReceived == 0)
            {
                Console.WriteLine("none");
                Console.WriteLine();
                Console.WriteLine("  The emitter is not running. KCD2MP_StartEmitter needs the rebuilt");
                Console.WriteLine("  pak loaded (or the functions injected via the console).");
                return;
            }
            Console.WriteLine("yes");

            // Read latency: this should be a cache read, not a round trip.
            long before = tail.FramesReceived;
            var readSamples = new List<double>(200);
            for (int i = 0; i < 200 && !ct.IsCancellationRequested; i++)
            {
                var s = Stopwatch.StartNew();
                _ = await tail.ReadPlayerStateAsync(ct);
                s.Stop();
                readSamples.Add(s.Elapsed.TotalMilliseconds);
            }
            var sorted = readSamples.OrderBy(v => v).ToList();

            // Frame rate actually delivered by the emitter over a fixed window.
            long start = tail.FramesReceived;
            long droppedStart = tail.FramesDropped;
            var w = Stopwatch.StartNew();
            await Task.Delay(5000, ct);
            w.Stop();
            double frames = tail.FramesReceived - start;
            double drops = tail.FramesDropped - droppedStart;
            double tailRate = frames / w.Elapsed.TotalSeconds;

            Console.WriteLine();
            Console.WriteLine($"  state read latency  p50 {sorted[sorted.Count / 2]:F4} ms   "
                            + $"p95 {sorted[(int)(sorted.Count * 0.95)]:F4} ms   (cached, {tail.RoundTripsPerStateRead} round trips)");
            Console.WriteLine($"  frames delivered    {tailRate:F1}/s over {w.Elapsed.TotalSeconds:F1}s");
            Console.WriteLine($"  frames dropped      {drops:F0}"
                            + (drops > 0 ? "  <-- emitter outpacing the tailer or the log dropping lines" : ""));

            Console.WriteLine();
            Console.WriteLine("=== comparison ===");
            Console.WriteLine($"{"",-22} {"http-debug-api",18} {"kcd-log-tail",18}");
            Console.WriteLine(new string('-', 60));
            Console.WriteLine($"{"round trips / read",-22} {1,18} {0,18}");
            Console.WriteLine($"{"state read p50 (ms)",-22} {httpP50,18:F1} {sorted[sorted.Count / 2],18:F4}");
            Console.WriteLine($"{"samples / second",-22} {httpRate,18:F1} {tailRate,18:F1}");
            if (httpRate > 0)
                Console.WriteLine($"{"throughput gain",-22} {"",18} {tailRate / httpRate,17:F1}x");
        }
    }

    private static async Task<Result> MeasureAsync(
        string label, string unit, int iterations, CancellationToken ct, Func<Task<bool>> action)
    {
        Console.Write($"  {label,-32} ");
        var samples = new List<double>(iterations);
        int failures = 0;

        for (int i = 0; i < iterations && !ct.IsCancellationRequested; i++)
        {
            var sw = Stopwatch.StartNew();
            bool ok;
            try { ok = await action(); }
            catch { ok = false; }
            sw.Stop();

            if (ok) samples.Add(sw.Elapsed.TotalMilliseconds);
            else failures++;
        }

        Console.WriteLine($"{samples.Count} samples, {failures} failed");
        return new Result(label, unit, samples, failures);
    }

    private static void Report(List<Result> results, IGameTransport transport)
    {
        Console.WriteLine();
        Console.WriteLine($"=== {transport.Name} — latency (ms) ===");
        Console.WriteLine($"{"operation",-32} {"min",7} {"p50",7} {"p95",7} {"p99",7} {"max",7} {"mean",7}");
        Console.WriteLine(new string('-', 32 + 6 * 8));
        foreach (var r in results)
        {
            Console.WriteLine($"{r.Label,-32} {r.Min,7:F1} {r.P(50),7:F1} {r.P(95),7:F1} {r.P(99),7:F1} {r.Max,7:F1} {r.Mean,7:F1}");
        }
    }
}
