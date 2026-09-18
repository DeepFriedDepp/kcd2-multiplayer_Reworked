using System.Globalization;

namespace KcdMp.Client;

/// <summary>
/// WO-102 Phase 1: sample-to-sample interval statistics for one position
/// source. The comparison between the log-tail path and the native pipe path
/// is the phase's deliverable, so both are measured with the same class and
/// reported on the same line shape:
///
///   MP-POSCADENCE path=log|native n= mean_ms= p50_ms= p95_ms= max_ms= window_s=
///
/// Intervals are bucketed at 1 ms up to <see cref="MaxMs"/> (anything longer
/// lands in the last bucket and is reported as ">=2000"), so p50/p95 are exact
/// to the millisecond without keeping every sample. A window is reset by each
/// <see cref="Report"/>; the lifetime distribution is kept for the summary.
///
/// <see cref="Break"/> marks a suspension (menu, load, the toggle flipping)
/// so the gap across it is not counted as an interval -- it is not the
/// cadence of anything.
/// </summary>
public sealed class CadenceStats
{
    public const int MaxMs = 2000;
    private readonly int[] _win = new int[MaxMs + 1];
    private readonly int[] _life = new int[MaxMs + 1];
    private long _winN, _lifeN;
    private double _winSum, _lifeSum, _winMax, _lifeMax;
    private double _lastMs = double.NaN;
    private double _winStartMs = double.NaN;

    public long WindowCount => _winN;
    public long LifetimeCount => _lifeN;

    /// <summary>One fresh sample at <paramref name="nowMs"/> (any monotonic ms clock).</summary>
    public void Sample(double nowMs)
    {
        if (double.IsNaN(_winStartMs)) _winStartMs = nowMs;
        if (!double.IsNaN(_lastMs))
        {
            double ms = nowMs - _lastMs;
            if (ms >= 0) Add(ms);
        }
        _lastMs = nowMs;
    }

    /// <summary>The next sample starts a new run; the gap to it is not an interval.</summary>
    public void Break() => _lastMs = double.NaN;

    /// <summary>Forget everything (a toggle flip).</summary>
    public void Reset()
    {
        Array.Clear(_win); Array.Clear(_life);
        _winN = _lifeN = 0; _winSum = _lifeSum = _winMax = _lifeMax = 0;
        _lastMs = double.NaN; _winStartMs = double.NaN;
    }

    private void Add(double ms)
    {
        int b = (int)Math.Min(MaxMs, Math.Round(ms));
        _win[b]++; _life[b]++;
        _winN++; _lifeN++;
        _winSum += ms; _lifeSum += ms;
        if (ms > _winMax) _winMax = ms;
        if (ms > _lifeMax) _lifeMax = ms;
    }

    /// <summary>The value at quantile <paramref name="q"/> (0..1) of a bucketed distribution, or -1 when empty.</summary>
    public static int Percentile(int[] hist, long n, double q)
    {
        if (n <= 0) return -1;
        long target = (long)Math.Ceiling(q * n);
        if (target < 1) target = 1;
        long seen = 0;
        for (int i = 0; i < hist.Length; i++)
        {
            seen += hist[i];
            if (seen >= target) return i;
        }
        return hist.Length - 1;
    }

    /// <summary>Formats the current window and resets it. Null when the window holds nothing.</summary>
    public string? Report(string path, double nowMs)
    {
        if (_winN == 0) { _winStartMs = nowMs; return null; }
        double windowS = double.IsNaN(_winStartMs) ? 0 : (nowMs - _winStartMs) / 1000.0;
        string line = Format(path, _win, _winN, _winSum, _winMax, windowS);
        Array.Clear(_win); _winN = 0; _winSum = 0; _winMax = 0; _winStartMs = nowMs;
        return line;
    }

    /// <summary>Lifetime line for MP-SUMMARY; null when nothing was ever sampled.</summary>
    public string? Summary(string path) =>
        _lifeN == 0 ? null : Format(path, _life, _lifeN, _lifeSum, _lifeMax, -1);

    private static string Format(string path, int[] hist, long n, double sum, double max, double windowS)
    {
        int p50 = Percentile(hist, n, 0.50), p95 = Percentile(hist, n, 0.95);
        return string.Format(CultureInfo.InvariantCulture,
            "MP-POSCADENCE path={0} n={1} mean_ms={2:F1} p50_ms={3} p95_ms={4} max_ms={5:F0}{6}",
            path, n, sum / n, p50 >= MaxMs ? ">=2000" : p50.ToString(CultureInfo.InvariantCulture),
            p95 >= MaxMs ? ">=2000" : p95.ToString(CultureInfo.InvariantCulture), max,
            windowS < 0 ? " scope=session" : string.Format(CultureInfo.InvariantCulture, " window_s={0:F0}", windowS));
    }
}
