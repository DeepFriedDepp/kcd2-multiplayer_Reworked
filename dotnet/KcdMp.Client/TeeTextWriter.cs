using System.Text;

namespace KcdMp.Client;

/// <summary>
/// Duplicates console output into a file (WO-39, item K -- the tester
/// diagnostics bundle). The agent's console is where all game-side telemetry
/// prints, and WO-38's real test round proved nobody ever sees it: the only
/// logs the testers sent contained zero game telemetry. This keeps the
/// console exactly as it was and adds a persistent copy.
///
/// Write failures are swallowed after disabling the file half: diagnostics
/// must never take the agent down, and a full disk or locked file just
/// degrades back to console-only.
/// </summary>
public sealed class TeeTextWriter(TextWriter primary, TextWriter secondary) : TextWriter
{
    private bool _secondaryDead;

    // WO-98 Phase 6: every file line also carries a monotonic stamp (ms since
    // the agent started, immune to wall-clock steps) and the current relay
    // clock offset from GameBridge's estimator ("off=?" until the first
    // sample). Cross-machine correlation of the 2026-09-15 logs was only
    // possible because story beats happened to appear on both sides; with
    // the offset on every line it is arithmetic.
    private static readonly System.Diagnostics.Stopwatch Mono = System.Diagnostics.Stopwatch.StartNew();

    /// <summary>Relay clock minus this machine's clock, ms; NaN until measured.</summary>
    public static double ClockOffsetMs = double.NaN;

    /// <summary>Milliseconds since the agent process started (monotonic).</summary>
    public static long MonotonicMs => Mono.ElapsedMilliseconds;

    /// <summary>Lines written so far (both halves); the MP-SUMMARY line rate is derived from it.</summary>
    public static long LinesWritten;

    public override Encoding Encoding => primary.Encoding;

    public override void Write(char value)
    {
        primary.Write(value);
        if (_secondaryDead) return;
        try { secondary.Write(value); }
        catch { _secondaryDead = true; }
    }

    public override void Write(string? value)
    {
        primary.Write(value);
        if (_secondaryDead) return;
        try { secondary.Write(value); }
        catch { _secondaryDead = true; }
    }

    public override void WriteLine(string? value)
    {
        System.Threading.Interlocked.Increment(ref LinesWritten);
        primary.WriteLine(value);
        if (_secondaryDead) return;
        try
        {
            // Timestamp the file copy only -- the console stays byte-identical
            // to what it always printed, but a log without times is much less
            // useful when correlating against kcd.log and app.log.
            // Format (docs/WO-98-log-format.md): "HH:mm:ss.fff m=<mono ms> off=<+ms|?> <text>".
            double off = ClockOffsetMs;
            string offText = double.IsNaN(off) ? "?" : off.ToString("+0;-0", System.Globalization.CultureInfo.InvariantCulture);
            secondary.WriteLine($"{DateTime.Now:HH:mm:ss.fff} m={Mono.ElapsedMilliseconds} off={offText} {value}");
        }
        catch { _secondaryDead = true; }
    }

    public override void Flush()
    {
        primary.Flush();
        if (_secondaryDead) return;
        try { secondary.Flush(); }
        catch { _secondaryDead = true; }
    }
}
