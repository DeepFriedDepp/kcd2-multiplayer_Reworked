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
        primary.WriteLine(value);
        if (_secondaryDead) return;
        try
        {
            // Timestamp the file copy only -- the console stays byte-identical
            // to what it always printed, but a log without times is much less
            // useful when correlating against kcd.log and app.log.
            secondary.WriteLine($"{DateTime.Now:HH:mm:ss.fff} {value}");
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
