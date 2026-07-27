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

        Console.Write("Checking the game is up with a save loaded... ");
        if (!await transport.IsGameReadyAsync(ct))
        {
            Console.WriteLine("NO");
            Console.WriteLine();
            Console.WriteLine("The benchmark needs KCD2 running through the Modding Tools entry");
            Console.WriteLine("with a save loaded (the debug API returns nothing on the main menu).");
            return 1;
        }
        Console.WriteLine("yes");
        Console.WriteLine();

        // Warm up: first call pays TCP connect and JIT, which would otherwise
        // land in the samples as a fake outlier.
        for (int i = 0; i < 5; i++)
            await transport.ReadPositionOnlyAsync(ct);

        var results = new List<Result>();

        results.Add(await MeasureAsync("noop ExecuteString", "ms", 100, ct,
            async () => { await transport.ExecuteAsync("local _=1", ct); return true; }));

        results.Add(await MeasureAsync("position read (1 RT)", "ms", 100, ct,
            async () => await transport.ReadPositionOnlyAsync(ct) is not null));

        results.Add(await MeasureAsync("rot+ride CVar cycle (2 RT)", "ms", 100, ct,
            async () => await transport.ReadRotStateAsync(ct) is not null));

        results.Add(await MeasureAsync("full player state (3 RT)", "ms", 60, ct,
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

        Console.WriteLine();
        Console.WriteLine("Baseline captured. Re-run against a replacement transport to compare.");
        return 0;
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
